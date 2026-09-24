-- ============================================================
-- Phase 31 -- ciclos de facturación más largos que el mes + prorrateo del
-- primer período (ADR-0031)
-- ============================================================
-- Ref: docs/decisions.md ADR-0031 (seis resoluciones del Orchestrator),
-- docs/proposals/adr-0031-prorrateo-ciclos-largos.md.
--
-- Qué NO hace esta migración, y es lo primero que hay que saber para
-- leerla: no toca el motor de reservas. evaluate_payment_coverage() sigue
-- preguntando "¿la fecha local del turno cae dentro del período pago?"
-- (ADR-0013) y un período de tres meses o de un año responde esa pregunta
-- sin una línea nueva. Todo lo de acá vive del lado de *escribir* un pago:
-- qué período compra un pago hecho hoy, y cuánto sugiere cobrar.
--
-- Las dos decisiones de diseño que explican la forma del archivo:
--
-- 1. El período NO se recorta (resolución 2). El cliente que entra el 15
--    de septiembre en un plan trimestral jul-sep compra el trimestre
--    jul-sep y su cobertura empieza el 1 de julio. Recortar period_start
--    desalinearía el EXCLUDE de solapamiento y rompería la propiedad
--    "todos los clientes del plan renuevan el mismo día", que es el único
--    motivo para elegir un ciclo calendario. **Lo que se prorratea es el
--    precio.**
-- 2. El prorrateo es una COTIZACIÓN, no un cobro. quote_service_plan_period()
--    es de sólo lectura y payments.amount sigue libre (ADR-0024
--    resolución 5): el mostrador ve la cuenta y registra el monto que
--    quiera. Nada en la base aplica el prorrateo por su cuenta, así que un
--    descuento comercial no se pelea con la función.
--
-- Aditivo y sin migración de datos: billing_period_months nulo se lee como
-- 1, CALENDAR_MONTH/ROLLING_MONTH no se tocan ni se deprecan, y ningún
-- plan ni pago existente cambia de comportamiento el día del deploy
-- (mismo patrón que el UNLIMITED de ADR-0024 y el makeup_credits_enabled
-- de ADR-0025).

-- ============================================================
-- 1. Dos valores nuevos de billing_cycle
-- ============================================================
-- Generalizaciones, no reemplazos: CALENDAR_MONTH es exactamente
-- CALENDAR_PERIOD con billing_period_months = 1, y es el 100% de los datos
-- existentes. Agregar valores en vez de reescribir los viejos es el mismo
-- patrón que no rompió nada en ADR-0022 ni en ADR-0024.
--
-- Cuidado de implementación: un valor de enum agregado en esta misma
-- transacción no puede usarse como literal de ese tipo hasta que commitee.
-- Por eso todo lo que compara más abajo lo hace sobre `::text` -- igual
-- que el OVER_PLAN_QUOTA de la Fase 17.
alter type public.billing_cycle add value if not exists 'CALENDAR_PERIOD';
alter type public.billing_cycle add value if not exists 'ROLLING_PERIOD';

-- ============================================================
-- 2. service_plans: cada cuántos meses se cobra, y desde qué mes
-- ============================================================
alter table public.service_plans
  add column if not exists billing_period_months int,
  add column if not exists billing_anchor_month int;

comment on column public.service_plans.billing_period_months is
  'Cada cuántos meses cobra este plan. NULL = 1 = el comportamiento de siempre (ADR-0031). Inmutable una vez que el plan tiene pagos no-VOID, por el mismo criterio que plan_kind/weekly_quota: es un término que hay que poder resolver hacia atrás desde un pago vigente.';

comment on column public.service_plans.billing_anchor_month is
  'Mes (1..12) en el que arranca el ciclo calendario largo: 1 + trimestral = ene-mar, abr-jun, jul-sep, oct-dic, iguales para todos los clientes del plan. NULL = el ciclo arranca en el mes de la compra (y entonces nunca hay nada que prorratear). Sólo para CALENDAR_PERIOD.';

-- Una sola representación por configuración: los dos ciclos "_PERIOD"
-- exigen la cantidad de meses, y los dos "_MONTH" (y el ONE_TIME, que no
-- tiene ciclo) la prohíben. Sin esto, CALENDAR_PERIOD con NULL sería un
-- segundo nombre de CALENDAR_MONTH.
--
-- coalesce(...,'') y no `billing_cycle::text in (...)` a secas: con
-- billing_cycle NULL la comparación da NULL, el CHECK no falla con NULL, y
-- un DROP_IN podría colar un billing_period_months que no significa nada.
alter table public.service_plans
  add constraint service_plans_billing_period_months_matches_cycle check (
    (coalesce(billing_cycle::text, '') in ('CALENDAR_PERIOD', 'ROLLING_PERIOD'))
    = (billing_period_months is not null)
  );

-- Tope de 12 meses (un año es el ciclo más largo que el producto vende) y,
-- para los ciclos calendario, divisor de 12: si los bloques no tapizan el
-- año exacto (N = 5, por ejemplo) el trimestre "equivalente" se corre de
-- año en año y el anclaje deja de significar lo que la pantalla promete.
-- Un ciclo rodante no tiene esa restricción porque no se ancla a nada.
alter table public.service_plans
  add constraint service_plans_billing_period_months_range check (
    billing_period_months is null
    or (
      billing_period_months between 1 and 12
      and (coalesce(billing_cycle::text, '') <> 'CALENDAR_PERIOD' or 12 % billing_period_months = 0)
    )
  );

-- El anclaje sólo existe para el ciclo calendario largo. En un ciclo
-- rodante el período arranca el día de la compra (no hay nada que anclar)
-- y en CALENDAR_MONTH el bloque es de un mes (el anclaje sería siempre el
-- mes de la compra).
alter table public.service_plans
  add constraint service_plans_billing_anchor_month_matches_cycle check (
    billing_anchor_month is null
    or (
      billing_anchor_month between 1 and 12
      and coalesce(billing_cycle::text, '') = 'CALENDAR_PERIOD'
    )
  );

-- service_plans_billing_matches_kind (Fase 17) no se toca: ya dice
-- "MONTHLY exige billing_cycle no nulo", sin enumerar cuáles, así que los
-- dos valores nuevos entran sin reescribirlo.

-- ============================================================
-- 3. Inmutabilidad de los términos, extendida a las dos columnas nuevas
-- ============================================================
-- ADR-0024 resolución 5, misma lista y mismo motivo:
-- billing_period_for()/quote_service_plan_period() leen estos términos en
-- vivo desde el plan, nunca de una copia congelada por pago, así que
-- cambiarlos con pagos vivos reinterpretaría hacia atrás lo que alguien
-- compró. El anclaje entra en la lista porque moverlo desalinea de golpe a
-- todos los clientes del plan (riesgo 2 de la propuesta). El precio sigue
-- libre: sólo afecta cobros futuros y cada Payment guarda su monto.
create or replace function public.check_service_plan_terms_immutable()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if (new.plan_kind is distinct from old.plan_kind
      or new.weekly_quota is distinct from old.weekly_quota
      or new.quota_scope is distinct from old.quota_scope
      or new.applies_to_all_services is distinct from old.applies_to_all_services
      or new.billing_period_months is distinct from old.billing_period_months
      or new.billing_anchor_month is distinct from old.billing_anchor_month)
     and exists (
       select 1 from public.payments p
       where p.service_plan_id = old.id and p.status <> 'VOID'
     )
  then
    raise exception 'SERVICE_PLAN_TERMS_IMMUTABLE';
  end if;

  return new;
end;
$BODY$;

-- ============================================================
-- 4. billing_period_for(): dos ramas nuevas, las tres viejas intactas
-- ============================================================
-- Se extiende, no se duplica (§3.2 de la propuesta): una función "sólo
-- para el primer pago de un ciclo largo" obligaría a cada llamador a saber
-- si el pago que está creando es el primero -- un dato que la base no
-- tiene a mano sin interpretar el historial -- y serían dos fuentes de
-- verdad sobre qué período compra un pago.
create or replace function public.billing_period_for(
  p_service_plan_id uuid,
  p_from date
)
returns table (period_start date, period_end date)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_cycle text;
  v_months int;
  v_anchor int;
  v_offset int;
begin
  select * into v_plan from public.service_plans where id = p_service_plan_id;
  if not found then
    return;
  end if;

  -- ::text y no el enum: los valores nuevos se agregan en esta misma
  -- transacción (§1). Además deja el `coalesce` trivial para el ONE_TIME,
  -- que no tiene ciclo.
  v_cycle := coalesce(v_plan.billing_cycle::text, '');
  v_months := coalesce(v_plan.billing_period_months, 1);

  if v_plan.billing_type = 'MONTHLY' and v_cycle = 'CALENDAR_MONTH' then
    -- Paying on the 15th still covers the 1st to the last day.
    period_start := date_trunc('month', p_from)::date;
    period_end := (date_trunc('month', p_from) + interval '1 month - 1 day')::date;

  elsif v_plan.billing_type = 'MONTHLY' and v_cycle = 'CALENDAR_PERIOD' then
    -- El bloque de v_months meses, anclado en billing_anchor_month, que
    -- contiene a p_from. Sin anclaje el bloque arranca en el mes de la
    -- compra (offset 0), que es lo que hace que un plan sin anclaje nunca
    -- tenga nada que prorratear.
    --
    -- El módulo se calcula sólo con el mes del año y es correcto porque
    -- service_plans_billing_period_months_range garantiza que v_months
    -- divide a 12: los bloques tapizan el año y se repiten idénticos año a
    -- año. El doble `% v_months` es para que un offset negativo (p_from
    -- antes del mes de anclaje) vuelva al rango [0, v_months).
    v_anchor := coalesce(v_plan.billing_anchor_month, extract(month from p_from)::int);
    v_offset := (((extract(month from p_from)::int - v_anchor) % v_months) + v_months) % v_months;

    period_start := (date_trunc('month', p_from) - make_interval(months => v_offset))::date;
    period_end := (period_start + make_interval(months => v_months) - interval '1 day')::date;

  elsif v_plan.billing_type = 'MONTHLY' and v_cycle = 'ROLLING_PERIOD' then
    -- Arranca el día de la compra: no hay fracción que descontar, así que
    -- un ciclo rodante no prorratea NUNCA (§3.1). Postgres recorta
    -- 31-ene + 1 mes a 28-feb solo, igual que en ROLLING_MONTH.
    period_start := p_from;
    period_end := (p_from + make_interval(months => v_months) - interval '1 day')::date;

  elsif v_plan.billing_type = 'MONTHLY' then
    -- ROLLING_MONTH: paying on the 15th covers through the 14th of next
    -- month. Postgres clamps 31 Jan + 1 month to 28 Feb on its own.
    period_start := p_from;
    period_end := (p_from + interval '1 month - 1 day')::date;

  else
    -- ONE_TIME (a DROP_IN plan) covers the single day it was bought for;
    -- for those the payment is anchored to the occurrence anyway.
    period_start := p_from;
    period_end := p_from;
  end if;

  return next;
end;
$BODY$;

comment on function public.billing_period_for(uuid, date) is
  'Qué período compra un pago de este plan hecho el día p_from. ADR-0031 le agrega CALENDAR_PERIOD (bloque de billing_period_months meses anclado en billing_anchor_month) y ROLLING_PERIOD (N meses desde la compra); CALENDAR_MONTH/ROLLING_MONTH/ONE_TIME se comportan exactamente como antes. El período nunca se recorta a la fecha de alta -- lo que se prorratea es el precio (quote_service_plan_period).';

-- ============================================================
-- 5. quote_service_plan_period(): la cotización
-- ============================================================
-- Separada de billing_period_for() a propósito (§3.3): esa función es
-- `stable` y la llaman cuatro caminos de lectura del motor; meterle precio
-- la convertiría en la función que todos llaman para todo. Esta la
-- envuelve, no la reimplementa.
--
-- Prorrateo por MESES ENTEROS contando el mes de alta como completo
-- (resolución 1): es lo que el mostrador puede explicar en una frase ("te
-- cobro un mes del trimestre"), no depende de cuántos días tiene el mes, y
-- coincide con el grano del resto del producto. Un modo PRORATE_DAILY
-- podría agregarse después como columna `proration_mode` sin tocar nada de
-- esto; hoy nadie lo pidió.
--
-- Redondeo a la unidad entera de moneda, half-up (round() de Postgres
-- sobre numeric ya lo es). organizations.currency_minor_units queda
-- diferido a ADR-0027 (resolución 5): hoy no hay consumidor que necesite
-- el centavo.
create or replace function public.quote_service_plan_period(
  p_service_plan_id uuid,
  p_from date
)
returns table (
  period_start date,
  period_end date,
  full_price numeric,
  prorated_price numeric,
  prorated boolean,
  units_charged int,
  units_total int
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_cycle text;
  v_months int;
  v_period record;
  v_raw numeric;
begin
  select * into v_plan from public.service_plans where id = p_service_plan_id;
  if not found then
    return;
  end if;

  -- El precio de un plan es público (service_plans_select_public), pero
  -- cotizar es una operación de mostrador: se gatea como todo lo demás de
  -- la caja, por membresía, no por tenencia del uuid del plan.
  if not public.is_organization_member(v_plan.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select bp.period_start, bp.period_end into v_period
    from public.billing_period_for(p_service_plan_id, p_from) bp;

  period_start := v_period.period_start;
  period_end := v_period.period_end;
  full_price := v_plan.price;

  v_cycle := coalesce(v_plan.billing_cycle::text, '');
  v_months := coalesce(v_plan.billing_period_months, 1);

  units_total := case when v_plan.billing_type = 'MONTHLY' then v_months else 1 end;

  if v_plan.billing_type = 'MONTHLY' and v_cycle = 'CALENDAR_PERIOD' and v_months > 1 then
    -- Meses del bloque que todavía no arrancaron cuando el cliente entra,
    -- contando el suyo como completo: del mes de p_from al último mes del
    -- período, inclusive. Trimestre jul-sep con alta el 15-sep -> 1 de 3;
    -- con alta el 2-ago -> 2 de 3; con alta en julio -> 3 de 3 (no
    -- prorratea).
    units_charged := units_total - (
      (extract(year from p_from)::int * 12 + extract(month from p_from)::int)
      - (extract(year from period_start)::int * 12 + extract(month from period_start)::int)
    );
  else
    -- Todo lo demás cobra completo, sin excepción: CALENDAR_MONTH y
    -- ROLLING_MONTH (un mes es el mes), ROLLING_PERIOD (arranca el día de
    -- la compra) y ONE_TIME (un día).
    units_charged := units_total;
  end if;

  if units_charged < units_total then
    v_raw := round(full_price * units_charged::numeric / units_total::numeric, 0);
    -- Nunca más que el precio de lista ni menos que 0. Va acá y no como
    -- CHECK porque el monto del pago es libre a propósito (ADR-0024
    -- resolución 5): lo que se acota es la SUGERENCIA.
    prorated_price := least(greatest(v_raw, 0::numeric), full_price);
  else
    -- Cobra completo: se devuelve el precio de lista TAL CUAL, sin pasar
    -- por round(). Redondear acá convertiría un plan de 1500.50 en 1501 y
    -- marcaría como "prorrateado" un pago que no lo está.
    prorated_price := full_price;
  end if;

  prorated := prorated_price is distinct from full_price;

  return next;
end;
$BODY$;

comment on function public.quote_service_plan_period(uuid, date) is
  'ADR-0031: cotiza (sólo lectura) el período completo que compra un pago de este plan hecho el día p_from -- fecha LOCAL de la organización, nunca la UTC del servidor -- y el monto sugerido. Prorratea por meses enteros, contando el mes de alta como completo, y SÓLO al entrar a mitad de un CALENDAR_PERIOD de más de un mes: un ciclo rodante arranca el día de la compra y no tiene nada que prorratear. No cobra nada: payments.amount sigue libre y el mostrador puede ignorar la sugerencia.';

revoke execute on function public.quote_service_plan_period(uuid, date) from public, anon;
grant execute on function public.quote_service_plan_period(uuid, date) to authenticated;

-- ============================================================
-- 6. create_service_plan(): dos parámetros más
-- ============================================================
-- drop + create y no un segundo `create or replace` con más argumentos:
-- dos firmas coexistiendo serían una sobrecarga que PostgREST tendría que
-- desambiguar por nombre de argumento. Los dos nuevos tienen default NULL,
-- así que todo llamador existente (incluidos los tests) sigue funcionando
-- sin cambios y crea exactamente lo que creaba antes.
drop function if exists public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope
);

create or replace function public.create_service_plan(
  p_organization_id uuid,
  p_name text,
  p_description text,
  p_price numeric,
  p_plan_kind public.service_plan_kind,
  p_weekly_quota int,
  p_billing_type public.billing_type,
  p_billing_cycle public.billing_cycle,
  p_sort_order int,
  p_applies_to_all_services boolean,
  p_service_ids uuid[],
  p_quota_scope public.plan_quota_scope default null,
  p_billing_period_months int default null,
  p_billing_anchor_month int default null
)
returns public.service_plans
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_service_id uuid;
begin
  if not public.is_organization_member(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if not p_applies_to_all_services
     and (p_service_ids is null or array_length(p_service_ids, 1) is null) then
    raise exception 'SERVICE_PLAN_SCOPE_EMPTY';
  end if;

  if p_applies_to_all_services
     and p_service_ids is not null and array_length(p_service_ids, 1) is not null then
    raise exception 'SERVICE_PLAN_SCOPE_EXCLUSIVE';
  end if;

  insert into public.service_plans (
    organization_id, name, description, price, plan_kind, weekly_quota,
    billing_type, billing_cycle, billing_period_months, billing_anchor_month,
    sort_order, applies_to_all_services, quota_scope, created_by
  ) values (
    p_organization_id, p_name, p_description, p_price, p_plan_kind, p_weekly_quota,
    p_billing_type, p_billing_cycle, p_billing_period_months, p_billing_anchor_month,
    p_sort_order, p_applies_to_all_services, p_quota_scope, auth.uid()
  )
  returning * into v_plan;

  if not p_applies_to_all_services then
    foreach v_service_id in array p_service_ids loop
      insert into public.service_plan_services (service_plan_id, service_id)
      values (v_plan.id, v_service_id);
    end loop;
  end if;

  return v_plan;
end;
$BODY$;

comment on function public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope, int, int
) is
  'ADR-0029: la única forma de crear un plan con selección explícita de servicios -- service_plans y service_plan_services son dos INSERT que necesitan una transacción para validate_service_plan_scope() (deferred). ADR-0031 le agrega billing_period_months/billing_anchor_month, con default NULL = el comportamiento mensual de siempre.';

revoke execute on function public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope, int, int
) from public, anon;
grant execute on function public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope, int, int
) to authenticated;

-- ============================================================
-- 7. El crédito de recupero en un plan de ciclo largo vence a fin de mes
-- ============================================================
-- Resolución 6 del Orchestrator. END_OF_BILLING_PERIOD (ADR-0025
-- resolución 4) sigue igual para ciclos mensuales, pero en un plan
-- trimestral un crédito emitido el primer día del trimestre viviría tres
-- meses: multiplica por tres el riesgo que ADR-0025 ya dejó anotado como
-- abierto (cuántos créditos vivos tolera la capacidad real).
--
-- El acotamiento se aplica acá, en la emisión, y no en
-- resolve_makeup_credits_policy(): la política se resuelve por Service
-- (organización con override del servicio) y no sabe qué plan cubrió la
-- reserva liberada -- eso lo resuelve esta función, que ya tiene el plan
-- en la mano para decidir el alcance del crédito (ADR-0029).
--
-- La base efectiva es la que se guarda en la fila del crédito: si el
-- crédito vence a fin de mes, su expiry_basis tiene que decir END_OF_MONTH
-- o la auditoría no explicaría la fecha (y expires_on es inmutable, así
-- que no hay recálculo posterior que pudiera contradecirla).
create or replace function public.issue_makeup_credit(
  p_booking public.bookings,
  p_origin public.makeup_credit_origin,
  p_enforce_deadline boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_policy record;
  v_coverage public.can_book_reason;
  v_local_date date;
  v_period_end date;
  v_expires_on date;
  v_credit_id uuid;
  v_plan public.service_plans;
  v_covered_count int;
  v_credit_service_id uuid;
  v_expiry_basis public.makeup_credit_expiry_basis;
begin
  if p_booking.status <> 'CANCELLED' then
    return null;
  end if;

  select * into v_occurrence from public.slot_occurrences where id = p_booking.slot_occurrence_id;
  if not found then
    return null;
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id;
  if not found or not v_service.payment_required then
    return null;
  end if;

  select * into v_policy from public.resolve_makeup_credits_policy(v_service.id);
  if v_policy.enabled is not true then
    return null;
  end if;

  if exists (select 1 from public.makeup_credits where consumed_booking_id = p_booking.id) then
    return null;
  end if;

  v_local_date := public.slot_local_date(v_occurrence.id);
  if v_local_date is null then
    return null;
  end if;

  v_coverage := public.evaluate_payment_coverage(
    p_booking.customer_id, v_service.id, v_occurrence.id, p_booking.recurring_booking_id, false
  );
  if v_coverage <> 'OK' then
    return null;
  end if;

  if p_enforce_deadline and now() > (v_occurrence.start_at - (v_policy.deadline_hours * interval '1 hour')) then
    return null;
  end if;

  -- ADR-0029: resolve which plan actually covered this booking, to decide
  -- whether the credit it earns is anchored to this one service or usable
  -- across the plan's whole covered set.
  v_plan := public.resolve_covering_service_plan(p_booking.customer_id, v_service.id, v_local_date);
  if v_plan.id is null then
    -- DROP_IN: no payment_service_coverage row: fall back to the payment
    -- tied directly to the released occurrence.
    select sp.* into v_plan
      from public.payments p
      join public.service_plans sp on sp.id = p.service_plan_id
      where p.customer_id = p_booking.customer_id
        and p.slot_occurrence_id = v_occurrence.id
        and p.status = 'PAID'
      limit 1;
  end if;

  if v_plan.id is null then
    -- Coverage was OK yet no plan can be re-derived: should not happen
    -- given the check above, but a credit cannot be anchored to nothing.
    return null;
  end if;

  select count(*) into v_covered_count from public.service_plan_covered_service_ids(v_plan.id);

  -- Same generalization as check_makeup_credit_scope_matches_plan(): a
  -- single-service plan, or a WEEKLY_QUOTA plan declared PER_SERVICE,
  -- anchors the credit to this exact service. A SHARED_ACROSS_SERVICES
  -- plan, or a multi-service UNLIMITED plan (never rationed per service),
  -- issues a credit usable across the whole covered set.
  if v_covered_count <= 1 or coalesce(v_plan.quota_scope, 'SHARED_ACROSS_SERVICES') = 'PER_SERVICE' then
    v_credit_service_id := v_service.id;
  else
    v_credit_service_id := null;
  end if;

  -- ADR-0031 resolución 6: en un plan de ciclo largo, "fin del período de
  -- facturación" se acota a fin de mes.
  v_expiry_basis := v_policy.expiry_basis;
  if v_expiry_basis = 'END_OF_BILLING_PERIOD' and coalesce(v_plan.billing_period_months, 1) > 1 then
    v_expiry_basis := 'END_OF_MONTH';
  end if;

  if v_expiry_basis = 'END_OF_BILLING_PERIOD' then
    select psc.period_end into v_period_end
      from public.payments p
      join public.payment_service_coverage psc on psc.payment_id = p.id
      where psc.customer_id = p_booking.customer_id
        and psc.service_id = v_service.id
        and p.status = 'PAID'
        and psc.period_start <= v_local_date
        and psc.period_end >= v_local_date
      order by psc.period_start desc, p.created_at desc
      limit 1;
  end if;

  v_expires_on := public.compute_makeup_credit_expiry(
    v_expiry_basis, v_policy.expiry_days, v_local_date, v_period_end
  );

  insert into public.makeup_credits (
    organization_id, customer_id, service_id, service_plan_id, origin, source_booking_id, issued_by,
    expires_on, expiry_basis, expiry_basis_days
  )
  values (
    p_booking.organization_id, p_booking.customer_id, v_credit_service_id, v_plan.id, p_origin, p_booking.id, auth.uid(),
    v_expires_on, v_expiry_basis, v_policy.expiry_days
  )
  on conflict (source_booking_id) where source_booking_id is not null do nothing
  returning id into v_credit_id;

  return v_credit_id;
end;
$BODY$;

comment on function public.issue_makeup_credit(public.bookings, public.makeup_credit_origin, boolean) is
  'The only function that mints a MakeupCredit (ADR-0025). ADR-0029: resolves which plan covered the released booking, to decide whether the credit is anchored to that one service or shared across the plan''s covered set. ADR-0031 resolución 6: en un plan con billing_period_months > 1, END_OF_BILLING_PERIOD se acota a END_OF_MONTH (y la fila guarda esa base efectiva, no la de la política).';
