-- ============================================================
-- Fase 34 -- Límites de permiso: dónde va la autorización
-- ============================================================
-- Cuatro hallazgos de la auditoría de ADR-0031/0032/0033 (~110 sondas de
-- explotación reales contra la base). Tres son bloqueantes de ADR-0033 y
-- uno es el residuo de `services.price` que quedaba pendiente de decidir.
--
-- El hilo común de los dos primeros es la misma regla, que esta
-- migración deja escrita para que no se vuelva a romper:
--
--   **La autorización de una operación va en el punto de entrada
--   público, nunca en un helper compartido que también corre como
--   efecto colateral interno de otra escritura.**
--
-- Poner el chequeo adentro del helper produce los dos errores opuestos:
--   * falso negativo -- el helper corre como consecuencia de una
--     escritura legítima y exige un permiso que no le corresponde al
--     actor de ESA escritura (Fix 1: el cajero no puede cobrar);
--   * falso positivo -- una entrada pública distinta comparte el helper
--     y hereda un chequeo más laxo que el suyo (Fix 2:
--     discontinue_schedule_rule se quedó en is_organization_member()
--     cuando su prima cancel_slot_occurrence() ya pedía
--     MANAGE_BOOKINGS).
--
-- ============================================================
-- 1. Fix 1 -- MANAGE_PAYMENTS sin MANAGE_BOOKINGS no podía cobrar
-- ============================================================
-- Síntoma exacto: un rol "Recepción" con can_manage_payments = true y
-- can_manage_bookings = false (el caso inverso de ADR-0033 resolución 4,
-- y a propósito: no queremos que el mostrador edite reservas) registra un
-- pago PAID de un cliente que tiene fechas NOT_GENERATED /
-- PAYMENT_REQUIRED de un horario fijo. Cascada:
--
--   insert payments (status PAID)
--     -> trigger payments_reconcile_pending (Fase 12)
--       -> reconcile_after_payment()
--         -> reconcile_pending_recurring_bookings()
--           -> retry_not_generated_booking()   <-- chequea MANAGE_BOOKINGS
--             -> raise NOT_AUTHORIZED
--   => el INSERT del pago entero se aborta.
--
-- Reconciliar no es "operar sobre la reserva de otra persona": es la
-- consecuencia automática del pago que el cajero sí tiene permiso de
-- registrar. El chequeo que la Fase 32 agregó a
-- retry_not_generated_booking() es correcto para la RPC (reintentar una
-- fecha ajena a mano sí es operar sobre la reserva de otro) y está mal
-- ubicado para el camino interno.
--
-- La misma cascada existe por services_reconcile_on_payment_not_required
-- (Fase 15): apagar payment_required es una edición de servicio que
-- cualquier miembro puede hacer, y también terminaba en NOT_AUTHORIZED.
--
-- Solución: partir en dos. El cuerpo real pasa a un helper interno sin
-- ningún chequeo (mismo patrón que audit_write(), Fase 30: revocado de
-- todos los roles, sólo alcanzable desde otras funciones SECURITY
-- DEFINER de este esquema). La RPC pública conserva nombre, firma,
-- grants y chequeo.

create or replace function public.internal_retry_not_generated_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_occurrence public.slot_occurrences;
  v_rb public.recurring_bookings;
  v_active_count int;
  v_coverage public.can_book_reason;
  v_reason public.not_generated_reason;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    return v_booking;
  end if;

  if v_booking.status <> 'NOT_GENERATED' or v_booking.recurring_booking_id is null then
    return v_booking;
  end if;

  select * into v_rb from public.recurring_bookings
    where id = v_booking.recurring_booking_id and status = 'ACTIVE';
  if not found then
    return v_booking;
  end if;

  -- Same lock as book_slot (ADR-0004).
  select * into v_occurrence from public.slot_occurrences
    where id = v_booking.slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.start_at < now() then
    return v_booking;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = v_occurrence.id and status = 'CONFIRMED';

  v_coverage := public.evaluate_payment_coverage(
    v_booking.customer_id, v_occurrence.service_id, v_occurrence.id, v_booking.recurring_booking_id, false
  );

  if v_coverage in ('OVER_PLAN_QUOTA', 'OUTSIDE_PLAN_QUOTA') then
    v_reason := 'OVER_PLAN_QUOTA';
  elsif v_coverage <> 'OK' then
    v_reason := 'PAYMENT_REQUIRED';
  elsif exists (
    select 1 from public.bookings
    where customer_id = v_booking.customer_id
      and slot_occurrence_id = v_occurrence.id
      and status = 'CONFIRMED'
  ) then
    v_reason := 'DUPLICATE';
  elsif v_active_count >= v_occurrence.capacity then
    v_reason := 'SLOT_FULL';
  else
    v_reason := null;
  end if;

  if v_reason is not null then
    if v_reason is distinct from v_booking.not_generated_reason then
      update public.bookings set not_generated_reason = v_reason
        where id = p_booking_id
        returning * into v_booking;
    end if;
    return v_booking;
  end if;

  update public.bookings
    set status = 'CONFIRMED', not_generated_reason = null
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

comment on function public.internal_retry_not_generated_booking(uuid) is
  'Fase 34: el cuerpo real del reintento de una fecha NOT_GENERATED, SIN autorización. Helper interno (revocado de todos los roles, igual que audit_write()): sólo lo llaman funciones SECURITY DEFINER de este esquema. La autorización vive en la RPC pública retry_not_generated_booking(); reconcile_pending_recurring_bookings() llama a ESTE helper porque reconciliar es la consecuencia automática de un pago, no una acción del actor sobre la reserva.';

revoke execute on function public.internal_retry_not_generated_booking(uuid)
  from public, anon, authenticated, service_role;

-- La RPC pública: mismo nombre y misma firma que la Fase 32, así que
-- conserva el `revoke ... from public, anon, service_role` y el
-- `grant ... to authenticated` de la Fase 19 sin re-declararlos. Único
-- cambio: primero autoriza, después delega.
create or replace function public.retry_not_generated_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_customer public.customers;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    return v_booking;
  end if;

  select * into v_customer from public.customers where id = v_booking.customer_id;

  -- Mismo criterio que la Fase 32. La rama sin JWT es el job diario / el
  -- cliente service-role de los tests; después del revoke de la Fase 19
  -- los únicos roles que llegan acá son `authenticated` (siempre trae
  -- sub) y el dueño de la función.
  if auth.uid() is null then
    null;
  elsif v_customer.profile_id = auth.uid() then
    null;
  elsif public.has_org_permission(v_booking.organization_id, 'MANAGE_BOOKINGS') then
    null;
  else
    raise exception 'NOT_AUTHORIZED';
  end if;

  return public.internal_retry_not_generated_booking(p_booking_id);
end;
$BODY$;

comment on function public.retry_not_generated_booking(uuid) is
  'RPC pública: reintenta UNA fecha NOT_GENERATED. Autoriza (cliente dueño de la reserva, o miembro con MANAGE_BOOKINGS -- ADR-0033) y delega en internal_retry_not_generated_booking(). Fase 34: el chequeo vive acá y NO en el cuerpo, porque el cuerpo también corre como efecto colateral de registrar un pago.';

-- reconcile_pending_recurring_bookings() pasa a llamar al helper. Es el
-- único cambio de la función; sigue siendo el helper interno revocado de
-- todos los roles que dejó la Fase 19.
create or replace function public.reconcile_pending_recurring_bookings(
  p_customer_id uuid,
  p_service_id uuid default null
)
returns int
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking_id uuid;
  v_confirmed int := 0;
  v_result public.bookings;
begin
  -- Chronological order matters for a CREDITS entitlement: a customer
  -- with two credits and five pending Mondays gets the next two, not an
  -- arbitrary pair.
  for v_booking_id in
    select b.id
    from public.bookings b
    join public.slot_occurrences so on so.id = b.slot_occurrence_id
    join public.recurring_bookings rb on rb.id = b.recurring_booking_id
    where b.customer_id = p_customer_id
      and b.status = 'NOT_GENERATED'
      and rb.status = 'ACTIVE'
      and so.start_at >= now()
      and (p_service_id is null or so.service_id = p_service_id)
    order by so.start_at asc
  loop
    -- Fase 34: el helper interno, NO la RPC pública. Esta función corre
    -- dentro del trigger de payments/services: el actor es quien cobró o
    -- quien editó el servicio, y no tiene por qué tener MANAGE_BOOKINGS.
    v_result := public.internal_retry_not_generated_booking(v_booking_id);
    if v_result.status = 'CONFIRMED' then
      v_confirmed := v_confirmed + 1;
    end if;
  end loop;

  return v_confirmed;
end;
$BODY$;

comment on function public.reconcile_pending_recurring_bookings(uuid, uuid) is
  'Helper interno (revocado de todos los roles, Fase 19): recorre en orden cronológico las fechas NOT_GENERATED de un cliente y las reintenta. Lo llaman los triggers de payments (PAID) y de services (payment_required apagado). Fase 34: llama a internal_retry_not_generated_booking(), no a la RPC pública, para no exigirle MANAGE_BOOKINGS al cajero.';

-- ============================================================
-- 2. Fix 2 -- discontinue_schedule_rule() evadía MANAGE_BOOKINGS
-- ============================================================
-- Seguía gateada en is_organization_member() desde la Fase 3, pero
-- cancela en masa todas las slot_occurrences futuras de la regla, todas
-- las bookings CONFIRMED de esas ocurrencias y la serie recurrente
-- entera. Su prima cancel_slot_occurrence(), que hace exactamente lo
-- mismo para UNA fecha, ya exige MANAGE_BOOKINGS desde la Fase 32: un
-- STAFF con los cinco permisos en false no podía cancelar una clase y sí
-- podía cancelarle las reservas a toda la organización.
--
-- Decisión de producto (Orchestrator): la cancelación en masa requiere
-- MANAGE_BOOKINGS. **Editar** un horario (crear o modificar la regla en
-- sí, sin cancelar nada) sigue siendo de cualquier miembro -- las
-- funciones de edición pura no llevan gate. La frontera es "esto cancela
-- reservas de clientes", no "esto toca schedule_rules".
--
-- discontinue_schedule_rule_group() hereda el gate: llama a esta función
-- una vez por regla, y el raise aborta la transacción completa, así que
-- no hay cancelación parcial posible.

create or replace function public.discontinue_schedule_rule(p_schedule_rule_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_cancelled_booking public.bookings;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  -- Fase 34: mismo gate que cancel_slot_occurrence(). Era
  -- is_organization_member().
  if not public.has_org_permission(v_rule.organization_id, 'MANAGE_BOOKINGS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.schedule_rules
    set is_active = false, cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'DISCONTINUED_BY_ORGANIZATION'
    where id = p_schedule_rule_id;

  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'RULE_DISCONTINUED'
    where schedule_rule_id = p_schedule_rule_id
      and start_at >= now()
      and status <> 'CANCELLED';

  for v_cancelled_booking in
    update public.bookings b
      set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
          cancellation_reason = 'RULE_DISCONTINUED'
      from public.slot_occurrences so
      where b.slot_occurrence_id = so.id
        and so.schedule_rule_id = p_schedule_rule_id
        and so.start_at >= now()
        and b.status = 'CONFIRMED'
      returning b.*
  loop
    update public.makeup_credits
      set status = 'AVAILABLE', consumed_at = null
      where consumed_booking_id = v_cancelled_booking.id and status = 'CONSUMED';

    perform public.issue_makeup_credit(v_cancelled_booking, 'ORGANIZATION_CANCELLED', false);
  end loop;

  update public.recurring_bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'ORGANIZATION_REMOVED'
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE';
end;
$BODY$;

comment on function public.discontinue_schedule_rule(uuid) is
  'Discontinúa una ScheduleRule y cascadea: ocurrencias futuras CANCELLED, bookings CONFIRMED futuras CANCELLED con MakeupCredit cada una (ADR-0025), serie recurrente CANCELLED. Fase 34: exige MANAGE_BOOKINGS (ADR-0033), igual que cancel_slot_occurrence() -- es la misma cancelación en masa. Editar una regla sin cancelar nada sigue siendo de cualquier miembro.';

-- ============================================================
-- 3. Fix 3 -- el OWNER se auto-reactivaba y se subía de plan
-- ============================================================
-- organizations_update_owner es `for update using
-- is_organization_owner(id)`, sin WITH CHECK y sin restricción de
-- columnas: un PATCH /rest/v1/organizations del propio OWNER podía
-- cambiar subscription_status, plan_code, trial_ends_at y
-- current_period_end. Eso salta la suspensión que un platform admin le
-- puso y lo sube de plan sin pasar por set_organization_subscription()
-- (que sí está cerrada a is_platform_admin()).
--
-- Igual que en services (Fase 25): la policy de UPDATE de la tabla no
-- puede pasar a platform-admin-only -- el OWNER sigue editando nombre,
-- timezone, branding y política de recupero de su organización. El
-- chequeo tiene que ser por columna, así que va en un trigger.
--
-- Las cuatro columnas son "estado de la suscripción", no "configuración
-- de la organización": su único escritor legítimo es
-- set_organization_subscription(). Esa función es SECURITY DEFINER pero
-- NO cambia auth.uid() (SECURITY DEFINER cambia privilegios, no la
-- sesión), así que el trigger la ve con el uid del platform admin real y
-- la deja pasar. auth.uid() null (migraciones de datos, jobs internos,
-- el backfill de la Fase 10) también pasa: no hay actor al que
-- autorizar, y ese camino no es alcanzable por PostgREST.

create or replace function public.check_organization_subscription_platform_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.subscription_status is distinct from old.subscription_status
     or new.plan_code is distinct from old.plan_code
     or new.trial_ends_at is distinct from old.trial_ends_at
     or new.current_period_end is distinct from old.current_period_end
  then
    if auth.uid() is not null and not public.is_platform_admin() then
      raise exception 'NOT_AUTHORIZED';
    end if;
  end if;

  return new;
end;
$BODY$;

comment on function public.check_organization_subscription_platform_only() is
  'Fase 34: subscription_status, plan_code, trial_ends_at y current_period_end son estado de suscripción, no configuración de la organización. Sólo los cambia un is_platform_admin() (vía set_organization_subscription(), que corre con el uid del admin real) o un camino sin JWT (migraciones/jobs). El OWNER ya no puede levantarse su propia suspensión ni subirse de plan con un PATCH directo. Por columna y no por policy porque esas columnas conviven con nombre/timezone/branding, que el OWNER sí edita (organizations_update_owner).';

drop trigger if exists organizations_subscription_platform_only on public.organizations;
create trigger organizations_subscription_platform_only
  before update on public.organizations
  for each row
  execute function public.check_organization_subscription_platform_only();

comment on trigger organizations_subscription_platform_only on public.organizations is
  'Fase 34: cierra el PATCH directo del OWNER sobre las cuatro columnas de suscripción. set_organization_subscription() (platform admin) sigue funcionando.';

-- ============================================================
-- 4. Fix 4 -- services.price editable por cualquier STAFF
-- ============================================================
-- Columna legada pre-ADR-0024: ninguna decisión de cobertura la lee
-- desde la Fase 17 (el precio real vive en service_plans.price), pero
-- seguía editable por cualquier miembro vía PATCH directo
-- (services_write_staff) mientras el precio del ServicePlan ya estaba
-- cerrado al OWNER (check_service_plan_write_owner). Es un número que la
-- organización publica: mismo criterio.
--
-- No se borra la columna: sacarla es un ADR aparte (hay lecturas
-- históricas y el backfill de la Fase 17 la usó como origen).
--
-- Se extiende el trigger que ya existe sobre esta misma tabla en vez de
-- agregar un segundo before-update que haría el mismo raise.

create or replace function public.check_service_billing_override_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.makeup_credits_enabled_override is distinct from old.makeup_credits_enabled_override
     or new.release_deadline_hours_override is distinct from old.release_deadline_hours_override
     or new.makeup_credit_expiry_override is distinct from old.makeup_credit_expiry_override
     or new.makeup_credit_expiry_days_override is distinct from old.makeup_credit_expiry_days_override
     -- Fase 34: el precio legado, mismo criterio que service_plans.price.
     or new.price is distinct from old.price
  then
    if not public.is_organization_owner(new.organization_id) then
      raise exception 'NOT_AUTHORIZED';
    end if;
  end if;

  return new;
end;
$BODY$;

comment on function public.check_service_billing_override_owner() is
  'Columnas de services que sólo puede tocar el OWNER: los cuatro overrides de politica de credito de recupero (makeup_credits_enabled_override, release_deadline_hours_override, makeup_credit_expiry_override, makeup_credit_expiry_days_override) y, desde la Fase 34, el precio legado price (pre-ADR-0024, mismo criterio que check_service_plan_write_owner sobre service_plans.price). El resto de columnas sigue editable por cualquier member (services_write_staff); el chequeo es por columna y no por policy porque esas dos cosas conviven en la misma tabla.';

comment on column public.services.price is
  'DEPRECATED (ADR-0024). A service has several simultaneous prices now; see service_plans.price. Fase 34: sólo el OWNER puede cambiarla (check_service_billing_override_owner), igual que service_plans.price.';
