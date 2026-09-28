-- Fase 39: ficha de cliente -- qué tiene agendado y qué cupo semanal le da su plan.
--
-- Pedido del dueño: en la ficha de un cliente (/org/[slug]/customers/[customerId])
-- hoy se ve "Pagos" y "Créditos de recupero", pero no hay forma de ver qué horarios
-- fijos (RecurringBooking ACTIVE) tiene asignados ni si le faltan para completar la
-- cuota semanal de su plan. Caso real (captura de pantalla): cliente con plan
-- "Pilates Reformer 2 x S" (weekly_quota=2) -- nada en la ficha dice si tiene 0, 1 o
-- 2 horarios fijos.
--
-- schedule_rule_standing_reservations() (Fase 11, extendida en Fase 25) ya resuelve
-- exactamente los 5 contadores de "próximas fechas" que hacen falta acá, pero
-- escaneada por ScheduleRule (todos los clientes de UN horario). Este pedido es lo
-- inverso: todos los horarios fijos de UN cliente, sin importar a qué ScheduleRule/
-- servicio pertenezca cada uno -- así que se extrae la parte que las dos consultas
-- necesitan igual (los 5 conteos de "próximas fechas" de una RecurringBooking
-- puntual, con el mismo desdoble unpaid/beyond_period vía customer_billing_horizon()
-- de la Fase 25) a una función compartida, en vez de repetir las cinco subconsultas
-- en un segundo lugar. schedule_rule_standing_reservations() se reescribe para
-- llamarla también -- mismo shape de salida, así que CREATE OR REPLACE alcanza, y el
-- test de integración de la Fase 25/38 (que compara este agregado contra el detalle
-- fecha por fecha) es la prueba de que el refactor no cambió el resultado.

-- ============================================================
-- 1. recurring_booking_upcoming_counts(): los 5 conteos de "próximas fechas"
--    de UNA RecurringBooking puntual, extraídos de schedule_rule_standing_
--    reservations() (Fase 11/25) para no repetirlos.
-- ============================================================
-- Helper interno (Fase 19): sólo lo llaman funciones security definer de este
-- mismo archivo, así que se revoca de todos los roles de request.

create or replace function public.recurring_booking_upcoming_counts(
  p_recurring_booking_id uuid,
  p_customer_id uuid,
  p_service_id uuid,
  p_organization_id uuid
)
returns table (
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int,
  upcoming_beyond_period int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  with org as (
    select timezone from public.organizations where id = p_organization_id
  )
  select
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = p_recurring_booking_id and b.status = 'CONFIRMED' and so.start_at >= now())
      as upcoming_confirmed,
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = p_recurring_booking_id and b.status = 'NOT_GENERATED' and so.start_at >= now())
      as upcoming_not_generated,
    -- Sólo las fechas dentro del período que el cliente ya compró (o el que
    -- compraría hoy). Más allá de eso no falta un pago: todavía no se factura.
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = p_recurring_booking_id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()
        and public.slot_local_date(so.id)
            <= public.customer_billing_horizon(p_customer_id, p_service_id, (now() at time zone org.timezone)::date))
      as upcoming_unpaid,
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = p_recurring_booking_id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason::text = 'OVER_PLAN_QUOTA' and so.start_at >= now())
      as upcoming_over_quota,
    -- Las de más adelante, contadas aparte: son información ("el horario sigue
    -- reservado para cuando pague noviembre"), no una deuda.
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = p_recurring_booking_id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()
        and public.slot_local_date(so.id)
            > public.customer_billing_horizon(p_customer_id, p_service_id, (now() at time zone org.timezone)::date))
      as upcoming_beyond_period
  from org;
$BODY$;

comment on function public.recurring_booking_upcoming_counts(uuid, uuid, uuid, uuid) is
  'Los 5 conteos de "próximas fechas" de una RecurringBooking puntual (CONFIRMED / NOT_GENERATED / unpaid vs. beyond_period dentro de NOT_GENERATED por PAYMENT_REQUIRED / over_quota), extraídos de schedule_rule_standing_reservations() (Fase 11/25) para que customer_standing_reservations() (Fase 39) no los reimplemente. Helper interno, nunca invocado directo por PostgREST.';

revoke execute on function public.recurring_booking_upcoming_counts(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 2. schedule_rule_standing_reservations(): mismo shape de salida, ahora
--    llama al helper en vez de repetir las cinco subconsultas inline.
-- ============================================================

create or replace function public.schedule_rule_standing_reservations(p_schedule_rule_id uuid)
returns table (
  recurring_booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int,
  upcoming_beyond_period int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    rb.id,
    rb.customer_id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    rb.status,
    rb.created_at,
    counts.upcoming_confirmed,
    counts.upcoming_not_generated,
    counts.upcoming_unpaid,
    counts.upcoming_over_quota,
    counts.upcoming_beyond_period
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  left join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  cross join lateral public.recurring_booking_upcoming_counts(rb.id, rb.customer_id, sr.service_id, rb.organization_id) as counts
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$BODY$;

comment on function public.schedule_rule_standing_reservations(uuid) is
  'Las reservas fijas de una regla, con sus fechas futuras clasificadas. upcoming_unpaid es SOLO lo que se puede cobrar hoy; upcoming_beyond_period son las fechas mas alla del periodo vigente, que no son una deuda (la ventana rodante son 90 dias y un pago mensual cubre uno). Fase 39: los 5 conteos vienen de recurring_booking_upcoming_counts(), compartida con customer_standing_reservations() -- mismo resultado que antes del refactor, verificado por el test de la Fase 25/38 que compara este agregado contra el detalle fecha por fecha.';

-- Mismo objeto (CREATE OR REPLACE no cambia el OID ni el shape de retorno):
-- los grants de la Fase 25 siguen vigentes, no hace falta repetirlos.

-- ============================================================
-- 3. customer_standing_reservations(): todas las reservas fijas ACTIVAS de
--    UN cliente, sin importar a qué ScheduleRule/servicio pertenezca cada
--    una -- el inverso de schedule_rule_standing_reservations().
-- ============================================================

create or replace function public.customer_standing_reservations(p_customer_id uuid)
returns table (
  recurring_booking_id uuid,
  schedule_rule_id uuid,
  service_id uuid,
  service_name text,
  weekday smallint,
  local_start_time time,
  duration_minutes int,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int,
  upcoming_beyond_period int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    rb.id,
    sr.id,
    sr.service_id,
    s.name,
    sr.weekday,
    sr.local_start_time,
    sr.duration_minutes,
    rb.status,
    rb.created_at,
    counts.upcoming_confirmed,
    counts.upcoming_not_generated,
    counts.upcoming_unpaid,
    counts.upcoming_over_quota,
    counts.upcoming_beyond_period
  from public.recurring_bookings rb
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  join public.services s on s.id = sr.service_id
  cross join lateral public.recurring_booking_upcoming_counts(rb.id, rb.customer_id, sr.service_id, rb.organization_id) as counts
  where rb.customer_id = p_customer_id
    and rb.status = 'ACTIVE'
    and public.is_organization_member(rb.organization_id)
  order by sr.weekday asc, sr.local_start_time asc;
$BODY$;

comment on function public.customer_standing_reservations(uuid) is
  'Todos los horarios fijos ACTIVOS de un cliente puntual, sin importar el ScheduleRule/servicio de cada uno -- el inverso de schedule_rule_standing_reservations() (Fase 11/25), para la ficha del cliente. Los 5 conteos de "próximas fechas" son la misma función compartida (recurring_booking_upcoming_counts(), Fase 39), nunca reimplementados. Un no-miembro de la organización del cliente recibe [], no una excepción (mismo criterio que el resto de esta familia de funciones).';

revoke execute on function public.customer_standing_reservations(uuid) from public, anon;
grant execute on function public.customer_standing_reservations(uuid) to authenticated;

-- ============================================================
-- 4. customer_service_plan_quotas(): la cuota semanal que el plan vigente
--    de HOY le da al cliente, por servicio -- para poder decir "tiene N
--    asignados de M que le corresponden".
-- ============================================================
-- "Cuál es el plan vigente de este cliente para este servicio" no se
-- reinventa: es resolve_covering_service_plan() (ADR-0029, Fase 22), la
-- misma función que usa evaluate_payment_coverage() en el camino de
-- reserva. "Cuántas series ya ocupan esa cuota" tampoco: es
-- customer_series_in_force_count() con el mismo conjunto de servicios que
-- resuelve service_plan_quota_service_ids() -- así que un plan
-- SHARED_ACROSS_SERVICES (ADR-0029) cuenta el pool compartido entre los
-- servicios que cubre, no sólo el servicio de esta fila, aunque la
-- respuesta siga viniendo una fila por servicio (pedido explícito: "cuota
-- por servicio, no una sola cuota global").
--
-- Por servicio y no por plan: un cliente puede tener horarios fijos en más
-- de un servicio con planes de cuota distintos (o sin plan vigente en
-- alguno), y la ficha necesita poder mostrar cada combinación por separado.
--
-- weekly_quota/plan_kind/quota_scope salen null cuando: (a) el servicio no
-- tiene ningún Payment PAID vigente hoy para este cliente (plan lapsado o
-- nunca pagado), o (b) el plan vigente es UNLIMITED/DROP_IN -- ninguno de
-- los dos tiene un tope de series que mostrar. assigned_count SIEMPRE
-- viaja, con o sin plan vigente: son las RecurringBooking ACTIVE de este
-- cliente en vigencia hoy para ese servicio (o el pool completo si el plan
-- es SHARED_ACROSS_SERVICES), el mismo "N" que la ficha necesita mostrar
-- aunque hoy no haya "M" contra qué compararlo.

create or replace function public.customer_service_plan_quotas(p_customer_id uuid)
returns table (
  service_id uuid,
  service_name text,
  service_plan_id uuid,
  plan_name text,
  plan_kind public.service_plan_kind,
  weekly_quota int,
  quota_scope public.plan_quota_scope,
  assigned_count int
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_customer public.customers;
  v_org public.organizations;
  v_local_date date;
  v_rec record;
  v_plan public.service_plans;
  v_quota_ids uuid[];
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found or not public.is_organization_member(v_customer.organization_id) then
    return;
  end if;

  select * into v_org from public.organizations where id = v_customer.organization_id;
  v_local_date := (now() at time zone v_org.timezone)::date;

  for v_rec in
    select distinct sr.service_id as sid, s.name as sname
    from public.recurring_bookings rb
    join public.schedule_rules sr on sr.id = rb.schedule_rule_id
    join public.services s on s.id = sr.service_id
    where rb.customer_id = p_customer_id and rb.status = 'ACTIVE'
  loop
    service_id := v_rec.sid;
    service_name := v_rec.sname;

    v_plan := public.resolve_covering_service_plan(p_customer_id, v_rec.sid, v_local_date);

    if v_plan.id is null then
      service_plan_id := null;
      plan_name := null;
      plan_kind := null;
      quota_scope := null;
      weekly_quota := null;
      assigned_count := public.customer_series_in_force_count(p_customer_id, array[v_rec.sid], v_local_date);
    else
      service_plan_id := v_plan.id;
      plan_name := v_plan.name;
      plan_kind := v_plan.plan_kind;
      quota_scope := v_plan.quota_scope;

      if v_plan.plan_kind = 'WEEKLY_QUOTA' then
        weekly_quota := v_plan.weekly_quota;
        v_quota_ids := public.service_plan_quota_service_ids(v_plan.id, v_rec.sid);
        assigned_count := public.customer_series_in_force_count(p_customer_id, v_quota_ids, v_local_date);
      else
        -- UNLIMITED/DROP_IN: sin tope de series que mostrar.
        weekly_quota := null;
        assigned_count := public.customer_series_in_force_count(p_customer_id, array[v_rec.sid], v_local_date);
      end if;
    end if;

    return next;
  end loop;
end;
$BODY$;

comment on function public.customer_service_plan_quotas(uuid) is
  'La cuota semanal que el plan vigente HOY le da a este cliente, una fila por servicio donde tiene horarios fijos ACTIVE (ADR-0024/ADR-0029). Reusa resolve_covering_service_plan() y customer_series_in_force_count()/service_plan_quota_service_ids() -- misma resolución de "plan vigente" y "posición de cuota" que evaluate_payment_coverage() en el camino de reserva, nunca reimplementada. weekly_quota/plan_kind/quota_scope null cuando no hay plan vigente hoy o el plan no tiene tope (UNLIMITED/DROP_IN); assigned_count siempre viaja. Un no-miembro de la organización del cliente recibe [], no una excepción.';

revoke execute on function public.customer_service_plan_quotas(uuid) from public, anon;
grant execute on function public.customer_service_plan_quotas(uuid) to authenticated;
