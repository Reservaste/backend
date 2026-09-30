-- Phase 44: cobrar un turno suelto (DROP_IN) desde el mostrador -- ADR-0046
-- Ref: docs/decisions.md ADR-0046, docs/proposals/adr-0025-makeup-credits.md
-- S2.8 (diseno original nunca implementado -- esta migracion lo construye
-- tal cual, con las dos precisiones de ADR-0046: solo-mostrador, y "ya
-- anotado, falta cobrar").
--
-- Problema que cierra: un Service con DROP_IN + payment_required=true
-- queda con reservas bloqueadas sin ninguna salida -- evaluate_payment_
-- coverage() hace exactamente lo que tiene que hacer (un DROP_IN nunca
-- cubre por periodo), pero nunca se construyo la pieza que efectivamente
-- cobra ese turno suelto.
--
-- Dos RPC nuevas (quote_booking / book_slot_paying) + extension aditiva de
-- dos RPC de lectura existentes (agenda_occurrences / occurrence_bookings).
-- Ninguna reimplementa evaluate_payment_coverage()/evaluate_payment_
-- coverage_with_credit()/payment_covers_slot() (ADR-0018): las envuelve.
--
-- Nota de lectura importante sobre "ya cubierto" en book_slot_paying
-- (resolucion 2 de ADR-0046): un Service con payment_required=false
-- siempre da reason='OK' en evaluate_payment_coverage() por su paso 1
-- ("servicio sin pago requerido"), ANTES de mirar ningun plan/pago/
-- credito. Si esa via contara como "ya cubierto" para decidir si cobrar,
-- seria imposible cumplir el caso de negocio que la propia ADR-0046 cita
-- explicitamente ("un negocio con payment_required=false que igual
-- quiere dejar registro de un cobro hecho en efectivo despues del
-- servicio"). Por eso book_slot_paying solo re-evalua cobertura (y por lo
-- tanto solo puede devolver ALREADY_COVERED) cuando el servicio SI exige
-- pago -- ver el comentario puntual mas abajo, junto al codigo.

-- ============================================================
-- 1. booking_coverage_path: vocabulario de LECTURA (ADR-0025 S2.4.4),
--    nunca un valor nuevo de can_book_reason -- ese enum sigue
--    significando exclusivamente "se puede reservar / por que no".
-- ============================================================

create type public.booking_coverage_path as enum (
  'FREE_SERVICE',
  'DROP_IN_PAID',
  'PLAN_UNLIMITED',
  'PLAN_QUOTA',
  'MAKEUP_CREDIT',
  'NONE'
);

comment on type public.booking_coverage_path is
  'ADR-0025 S2.4.4 / ADR-0046: por que camino esta (o no) cubierto un turno, para el preview de quote_booking(). NONE = no hay cobertura, hay que pagar el DROP_IN. Nunca se mezcla con can_book_reason (ese enum sigue siendo exclusivamente el veredicto de reserva).';

-- ============================================================
-- 2. resolve_active_drop_in_plan(): el DROP_IN activo de un servicio,
--    mismo criterio de "unico por servicio" que garantiza el trigger
--    check_one_active_drop_in_per_service() (ADR-0029, phase22). Helper
--    interno, mismo patron que resolve_covering_service_plan().
-- ============================================================

create or replace function public.resolve_active_drop_in_plan(p_service_id uuid)
returns public.service_plans
language sql
stable
security definer
set search_path = public
as $BODY$
  -- Gate de seguridad ADR-0046: el plan tiene que ser de la MISMA
  -- organizacion que el servicio. Sin este filtro, un plan DROP_IN con
  -- applies_to_all_services=true de CUALQUIER otra organizacion matchea
  -- todos los servicios de la plataforma (verificado contra stg: el precio
  -- de otro tenant aparecia en agenda_occurrences/quote_booking y
  -- book_slot_paying abortaba con 'Payment organization_id must match its
  -- ServicePlan' -- DoS del cobro para todos los tenants). El ORDER BY hace
  -- determinista el caso (no cubierto por check_one_active_drop_in_per_
  -- service()) de un DROP_IN explicito + uno applies_to_all en la misma
  -- organizacion: gana el vinculo explicito, despues el mas antiguo.
  select sp.*
  from public.service_plans sp
  join public.services s on s.id = p_service_id
  where sp.is_active
    and sp.plan_kind = 'DROP_IN'
    and sp.organization_id = s.organization_id
    and (
      sp.applies_to_all_services
      or exists (
        select 1 from public.service_plan_services sps
        where sps.service_plan_id = sp.id and sps.service_id = p_service_id
      )
    )
  order by sp.applies_to_all_services asc, sp.created_at asc, sp.id asc
  limit 1;
$BODY$;

comment on function public.resolve_active_drop_in_plan(uuid) is
  'ADR-0046: el plan DROP_IN activo de un servicio (ADR-0029: resuelto via service_plan_services/applies_to_all_services, ya no hay service_plans.service_id). A lo sumo una fila por check_one_active_drop_in_per_service(). Helper interno, nunca invocado directo por PostgREST.';

revoke execute on function public.resolve_active_drop_in_plan(uuid)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 3. quote_booking(): lectura, sin side-effects. El preview del cliente,
--    del mostrador, y el que le dira a la pasarela de pago (ADR-0027,
--    postergada) cuanto cobrar. Envuelve evaluate_payment_coverage_
--    with_credit(), nunca la reimplementa.
-- ============================================================
-- Autorizacion en dos capas, resuelta ANTES de revelar nada del Customer:
-- staff con MANAGE_BOOKINGS de la organizacion de la ocurrencia, o el
-- propio cliente consultando su propia fila (profile_id = auth.uid()).
-- El chequeo de "es mio" se hace con un EXISTS independiente, sin volcar
-- antes la fila completa del customer -- asi nadie puede usar esta RPC
-- para sondear si un customer_id ajeno existe en otra organizacion.

create or replace function public.quote_booking(
  p_slot_occurrence_id uuid,
  p_customer_id uuid
)
returns table (
  can_book boolean,
  reason public.can_book_reason,
  coverage_path public.booking_coverage_path,
  price numeric,
  currency text,
  makeup_credit_id uuid,
  makeup_credit_expires_on date
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_org public.organizations;
  v_customer public.customers;
  v_coverage public.can_book_reason;
  v_credit_id uuid;
  v_plan public.service_plans;
  v_drop_in public.service_plans;
  v_local_date date;
  v_existing_paid_amount numeric;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.end_at < now() then
    can_book := false;
    reason := 'OCCURRENCE_NOT_AVAILABLE';
    coverage_path := 'NONE';
    price := null;
    currency := null;
    makeup_credit_id := null;
    makeup_credit_expires_on := null;
    return next;
    return;
  end if;

  if not (
    public.has_org_permission(v_occurrence.organization_id, 'MANAGE_BOOKINGS')
    or exists (
      select 1 from public.customers c
      where c.id = p_customer_id
        and c.organization_id = v_occurrence.organization_id
        and c.profile_id = auth.uid()
    )
  ) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_occurrence.organization_id and is_active;
  if not found then
    can_book := false;
    reason := 'NOT_A_CUSTOMER';
    coverage_path := 'NONE';
    price := null;
    currency := null;
    makeup_credit_id := null;
    makeup_credit_expires_on := null;
    return next;
    return;
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id;
  select * into v_org from public.organizations where id = v_occurrence.organization_id;
  currency := v_org.currency;

  v_local_date := public.slot_local_date(p_slot_occurrence_id);
  v_drop_in := public.resolve_active_drop_in_plan(v_service.id);

  select cov.reason, cov.makeup_credit_id into v_coverage, v_credit_id
  from public.evaluate_payment_coverage_with_credit(
    v_customer.id, v_service.id, p_slot_occurrence_id, null, false, true
  ) as cov;

  reason := v_coverage;
  can_book := v_coverage = 'OK';
  makeup_credit_id := v_credit_id;

  if makeup_credit_id is not null then
    select expires_on into makeup_credit_expires_on
      from public.makeup_credits where id = makeup_credit_id;
  else
    makeup_credit_expires_on := null;
  end if;

  if not v_service.payment_required then
    -- Paso 1 de evaluate_payment_coverage(): OK sin haber mirado plan ni
    -- pago. No hay nada que cobrar -- aunque exista un DROP_IN configurado
    -- (caso de un negocio que igual lo usa para registrar cobros
    -- opcionales, ADR-0046 resolucion 2), el preview de "cuanto cuesta
    -- reservar" es cero.
    coverage_path := 'FREE_SERVICE';
    price := null;
  elsif makeup_credit_id is not null then
    coverage_path := 'MAKEUP_CREDIT';
    price := 0;
  elsif v_coverage = 'OK' then
    select amount into v_existing_paid_amount
      from public.payments
      where customer_id = v_customer.id
        and slot_occurrence_id = p_slot_occurrence_id
        and status = 'PAID'
      limit 1;

    if v_existing_paid_amount is not null then
      coverage_path := 'DROP_IN_PAID';
      price := v_existing_paid_amount;
    else
      v_plan := public.resolve_covering_service_plan(v_customer.id, v_service.id, v_local_date);
      if v_plan.id is not null and v_plan.plan_kind = 'UNLIMITED' then
        coverage_path := 'PLAN_UNLIMITED';
      else
        coverage_path := 'PLAN_QUOTA';
      end if;
      price := 0;
    end if;
  else
    coverage_path := 'NONE';
    price := v_drop_in.price;
  end if;

  return next;
end;
$BODY$;

comment on function public.quote_booking(uuid, uuid) is
  'ADR-0046 (implementa ADR-0025 S2.8.1): preview de cobertura y precio de un turno, sin side-effects. Envuelve evaluate_payment_coverage_with_credit() -- nunca reimplementa ADR-0024/ADR-0025. Invocable por staff con MANAGE_BOOKINGS, o por el propio cliente consultando su propia cobertura (nunca la de otro customer_id -- la autorizacion se resuelve antes de tocar la fila de customers).';

revoke execute on function public.quote_booking(uuid, uuid) from public, anon;
grant execute on function public.quote_booking(uuid, uuid) to authenticated;

-- ============================================================
-- 4. book_slot_paying(): escritura, atomica. Solo-mostrador (ADR-0046
--    resolucion 1) -- el cliente no puede autodeclararse pagado sin
--    pasarela real (ADR-0027, postergada). Mismo orden de locks que
--    book_slot()/admin_book_for_customer(): FOR UPDATE de la ocurrencia
--    primero, siempre.
-- ============================================================

create or replace function public.book_slot_paying(
  p_slot_occurrence_id uuid,
  p_customer_id uuid,
  p_amount numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_customer public.customers;
  v_coverage public.can_book_reason;
  v_credit_id uuid;
  v_drop_in public.service_plans;
  v_local_date date;
  v_amount numeric;
  v_active_count int;
  v_booking public.bookings;
  v_payment public.payments;
begin
  -- ADR-0004/ADR-0046: mismo orden de locks que book_slot()/
  -- admin_book_for_customer() -- lockea la ocurrencia primero, siempre,
  -- para no generar deadlocks con una reserva concurrente.
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return jsonb_build_object('status', 'OCCURRENCE_NOT_AVAILABLE');
  end if;

  -- Gate de seguridad ADR-0046: esta funcion SIEMPRE escribe un Payment
  -- PAID, asi que exige MANAGE_PAYMENTS -- el mismo permiso que la policy
  -- payments_insert_staff (Fase 32) exige para insertar un pago. Con solo
  -- MANAGE_BOOKINGS, un rol configurado a proposito sin permiso de cobro
  -- (ADR-0033) registraba un PAID con p_amount=0 y esquivaba el
  -- PAYMENT_REQUIRED que admin_book_for_customer() le devuelve al mismo
  -- rol (verificado contra stg). MANAGE_BOOKINGS se exige ademas, mas
  -- abajo, solo si hay que CREAR la Booking (Fase 34: un cajero con
  -- MANAGE_PAYMENTS y sin MANAGE_BOOKINGS puede cobrar un turno ya
  -- anotado, pero no anotar).
  if not public.has_org_permission(v_occurrence.organization_id, 'MANAGE_PAYMENTS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- La frontera multi-tenant principal de esta pieza: el customer_id que
  -- manda el mostrador tiene que pertenecer a la MISMA organizacion que
  -- la ocurrencia que ya lockeamos (que sale de la ocurrencia, nunca de
  -- un input libre del caller).
  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_occurrence.organization_id and is_active;
  if not found then
    return jsonb_build_object('status', 'CUSTOMER_NOT_IN_ORG');
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id;
  v_local_date := public.slot_local_date(p_slot_occurrence_id);

  -- Re-evalua cobertura ANTES de cobrar -- pero solo cuando el servicio
  -- realmente exige pago. Ver la nota larga al inicio del archivo: el
  -- paso 1 de evaluate_payment_coverage() da 'OK' para todo servicio con
  -- payment_required=false sin haber mirado plan/pago/credito, y contar
  -- esa via como "ya cubierto" haria imposible el caso de negocio citado
  -- explicitamente por ADR-0046 resolucion 2 (registrar en efectivo un
  -- cobro opcional de un servicio gratuito). Para un servicio pago, en
  -- cambio, 'OK' aca SI significa dinero/credito ya puesto -- plan de
  -- periodo vigente, pago DROP_IN ya hecho para esta ocurrencia, o
  -- credito de recupero usable -- y cobrar de nuevo seria un doble cobro.
  if v_service.payment_required then
    select cov.reason, cov.makeup_credit_id into v_coverage, v_credit_id
    from public.evaluate_payment_coverage_with_credit(
      v_customer.id, v_service.id, p_slot_occurrence_id, null, false, true
    ) as cov;

    if v_coverage = 'OK' then
      return jsonb_build_object('status', 'ALREADY_COVERED');
    end if;
  end if;

  -- "Ya anotado, falta cobrar" (ADR-0046 resolucion 2): si la Booking ya
  -- existe, esta funcion solo registra el Payment -- nunca intenta
  -- reservar (ni chequea cupo) para una reserva que ya esta CONFIRMED.
  select * into v_booking from public.bookings
    where customer_id = p_customer_id and slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  if v_booking.id is null then
    if not public.has_org_permission(v_occurrence.organization_id, 'MANAGE_BOOKINGS') then
      raise exception 'NOT_AUTHORIZED';
    end if;

    select count(*) into v_active_count
      from public.bookings
      where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';
    if v_active_count >= v_occurrence.capacity then
      return jsonb_build_object('status', 'SLOT_FULL');
    end if;
  end if;

  v_drop_in := public.resolve_active_drop_in_plan(v_service.id);
  if v_drop_in.id is null then
    return jsonb_build_object('status', 'NO_DROP_IN_PLAN');
  end if;

  -- El plan y el precio no son input del cliente (ADR-0046/ADR-0025
  -- S2.8.1): el plan sale del DROP_IN activo; p_amount solo permite el
  -- descuento de mostrador que decide el STAFF que ya paso el gate de
  -- MANAGE_PAYMENTS mas arriba -- nunca lo decide quien reserva.
  v_amount := coalesce(p_amount, v_drop_in.price);
  -- 'NaN'::numeric < 0 es false en Postgres y numeric(12,2) acepta NaN:
  -- sin el chequeo explicito, un NaN quedaba como amount de un PAID
  -- (verificado contra stg) y envenena cualquier sum() de reportes.
  if v_amount is null or v_amount = 'NaN'::numeric or v_amount < 0 then
    return jsonb_build_object('status', 'INVALID_AMOUNT');
  end if;

  begin
    insert into public.payments (
      organization_id, customer_id, service_plan_id, slot_occurrence_id,
      period_start, period_end, status, amount, notes, created_by
    )
    values (
      v_occurrence.organization_id, v_customer.id, v_drop_in.id, p_slot_occurrence_id,
      v_local_date, v_local_date, 'PAID', v_amount,
      'Cobro de turno suelto por mostrador (book_slot_paying, ADR-0046).', auth.uid()
    )
    returning * into v_payment;
  exception
    when unique_violation then
      -- payments_one_paid_per_occurrence_idx (phase17): la red contra
      -- doble cobro concurrente de la MISMA ocurrencia para el MISMO
      -- cliente -- dos llamadas simultaneas a book_slot_paying(), una
      -- gana el insert y la otra cae aca.
      return jsonb_build_object('status', 'ALREADY_PAID');
  end;

  -- Cobrar y reservar son el mismo hecho (ADR-0025 S2.8.1): o quedan
  -- Payment PAID + Booking CONFIRMED juntos, o no queda nada. Desde aca
  -- en adelante cualquier fallo tiene que abortar TODA la transaccion
  -- (incluido el Payment recien insertado), asi que es el unico tramo de
  -- esta funcion que usa excepcion en vez de un status explicito --
  -- mismo criterio documentado en phase20 para MAKEUP_CREDIT_RACE_LOST.
  if v_booking.id is null then
    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, status, created_by
    )
    values (
      v_occurrence.organization_id, p_customer_id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
    )
    on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
    returning * into v_booking;

    if v_booking.id is null then
      raise exception 'BOOKING_RACE_LOST';
    end if;
  end if;

  return jsonb_build_object(
    'status', 'OK',
    'booking', to_jsonb(v_booking),
    'payment', to_jsonb(v_payment)
  );
end;
$BODY$;

comment on function public.book_slot_paying(uuid, uuid, numeric) is
  'ADR-0046 (implementa ADR-0025 S2.8.1): cobra y, si hace falta, reserva un turno suelto (DROP_IN) en una sola transaccion atomica. Solo-mostrador: exige MANAGE_PAYMENTS siempre (escribe un Payment, mismo permiso que payments_insert_staff) y ademas MANAGE_BOOKINGS si tiene que crear la Booking; el cliente nunca la invoca directo (sin pasarela real, ADR-0027 postergada). Mismo orden de locks que book_slot()/admin_book_for_customer(). CUSTOMER_NOT_IN_ORG es la frontera multi-tenant principal: el customer_id tiene que pertenecer a la organizacion de la ocurrencia ya lockeada.';

revoke execute on function public.book_slot_paying(uuid, uuid, numeric) from public, anon;
grant execute on function public.book_slot_paying(uuid, uuid, numeric) to authenticated;

-- ============================================================
-- 5. agenda_occurrences(): extension aditiva (drop + create, columnas
--    nuevas al final) -- el precio del DROP_IN activo de cada ocurrencia,
--    para que el panel pueda mostrar "Cobrar $X" sin una consulta aparte.
-- ============================================================

drop function if exists public.agenda_occurrences(uuid, timestamptz, timestamptz);

create function public.agenda_occurrences(
  p_organization_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns table (
  id uuid,
  service_id uuid,
  service_name text,
  resource_id uuid,
  resource_name text,
  start_at timestamptz,
  end_at timestamptz,
  capacity int,
  confirmed_count int,
  status public.slot_occurrence_status,
  drop_in_plan_id uuid,
  drop_in_price numeric,
  drop_in_currency text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    so.id,
    so.service_id,
    s.name,
    so.resource_id,
    r.name,
    so.start_at,
    so.end_at,
    so.capacity,
    (select count(*) from public.bookings b
      where b.slot_occurrence_id = so.id and b.status = 'CONFIRMED')::int,
    so.status,
    dip.id,
    dip.price,
    case when dip.id is not null then o.currency else null end
  from public.slot_occurrences so
  join public.services s on s.id = so.service_id
  join public.resources r on r.id = so.resource_id
  join public.organizations o on o.id = so.organization_id
  left join lateral (
    select (public.resolve_active_drop_in_plan(so.service_id)).*
  ) as dip on true
  where so.organization_id = p_organization_id
    and public.is_organization_member(so.organization_id)
    and so.start_at >= p_from
    and so.start_at < p_to
  order by so.start_at asc;
$$;

comment on function public.agenda_occurrences(uuid, timestamptz, timestamptz) is
  'Fase 8, extendida Fase 44 (ADR-0046): agrega drop_in_plan_id/drop_in_price/drop_in_currency por ocurrencia (null si el servicio no tiene un DROP_IN activo), patron aditivo al final del returns table.';

revoke execute on function public.agenda_occurrences(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.agenda_occurrences(uuid, timestamptz, timestamptz) to authenticated;

-- ============================================================
-- 6. occurrence_bookings(): extension aditiva -- por asistente,
--    is_covered (reusa payment_covers_slot(), nunca reimplementado) y
--    paid_payment_id (el Payment PAID anclado a esta ocurrencia para este
--    cliente, si lo hay).
-- ============================================================

drop function if exists public.occurrence_bookings(uuid);

create function public.occurrence_bookings(p_slot_occurrence_id uuid)
returns table (
  booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.booking_status,
  attendance_status public.attendance_status,
  attendance_marked_at timestamptz,
  created_at timestamptz,
  is_covered boolean,
  paid_payment_id uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.customer_id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    b.status,
    b.attendance_status,
    b.attendance_marked_at,
    b.created_at,
    public.payment_covers_slot(b.customer_id, so.service_id, so.id, b.recurring_booking_id, true),
    (select pay.id from public.payments pay
       where pay.customer_id = b.customer_id
         and pay.slot_occurrence_id = so.id
         and pay.status = 'PAID'
       limit 1)
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  left join public.profiles p on p.id = c.profile_id
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  where b.slot_occurrence_id = p_slot_occurrence_id
    and public.is_organization_member(so.organization_id)
  order by coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$$;

comment on function public.occurrence_bookings(uuid) is
  'Fase 8/16/21, extendida Fase 44 (ADR-0046): agrega is_covered (payment_covers_slot(), nunca reimplementado) y paid_payment_id (el Payment PAID de este cliente anclado a esta ocurrencia, si existe) por asistente.';

revoke execute on function public.occurrence_bookings(uuid) from public, anon;
grant execute on function public.occurrence_bookings(uuid) to authenticated;
