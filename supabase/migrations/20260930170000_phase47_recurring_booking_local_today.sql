-- Phase 47: admin_create_recurring_booking() y create_recurring_booking()
-- usaban current_date (fecha UTC del servidor) como "hoy" para el chequeo
-- de serie duplicada, el chequeo de cupo de plan y el start_date de la
-- RecurringBooking. Entre las 00:00 y 03:00 UTC, una organizacion en un
-- timezone detras de UTC (America/Montevideo, UTC-3) todavia esta en el
-- dia local anterior: la serie quedaba creada con start_date = manana
-- (servidor), posterior a "hoy local", e invisible para
-- customer_service_plan_quotas() y cualquier otra lectura que compare
-- contra la fecha local de la organizacion. Unico cambio: resolver v_org
-- y calcular v_today como (now() at time zone v_org.timezone)::date,
-- igual que ya hace customer_service_plan_quotas(), y pasar ese valor
-- explicito como start_date en el INSERT en vez de depender del default
-- de columna (current_date del servidor).

create or replace function public.admin_create_recurring_booking(
  p_schedule_rule_id uuid,
  p_customer_id uuid
)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_customer public.customers;
  v_org public.organizations;
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
  v_today date;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_rule.organization_id, 'MANAGE_BOOKINGS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_rule.organization_id and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  select * into v_org from public.organizations where id = v_rule.organization_id;
  v_today := (now() at time zone v_org.timezone)::date;

  if public.customer_standing_series_on_rule(p_customer_id, p_schedule_rule_id, v_today) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  perform public.assert_series_within_plan_quota(p_customer_id, v_rule.service_id, v_today);

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by, start_date)
  values (v_rule.organization_id, p_customer_id, p_schedule_rule_id, auth.uid(), v_today)
  returning * into v_rb;

  for v_occurrence_id in
    select id from public.slot_occurrences
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE' and start_at >= now()
  loop
    perform public.generate_recurring_booking(v_rb.id, v_occurrence_id);
  end loop;

  return v_rb;
end;
$BODY$;

revoke execute on function public.admin_create_recurring_booking(uuid, uuid) from public, anon;
grant execute on function public.admin_create_recurring_booking(uuid, uuid) to authenticated;

create or replace function public.create_recurring_booking(p_schedule_rule_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_customer public.customers;
  v_org public.organizations;
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
  v_today date;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers
    where organization_id = v_rule.organization_id and profile_id = auth.uid() and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  -- ADR-0047, correccion post-gate: un Customer SELF_SERVICE nunca puede
  -- armar una serie recurrente -- vedado de entrada, antes de cualquier
  -- otro chequeo (duplicado de serie, cupo de plan). El staff lo
  -- destraba pasando source a STAFF (UPDATE directo, customers_update_staff
  -- ya lo permite, sin RPC nueva).
  if v_customer.source = 'SELF_SERVICE' then
    raise exception 'SELF_SERVICE_CANNOT_CREATE_RECURRING';
  end if;

  select * into v_org from public.organizations where id = v_rule.organization_id;
  v_today := (now() at time zone v_org.timezone)::date;

  -- One standing reservation per customer per rule, same as the
  -- front-desk path. Self-service never had this guard, and ADR-0024
  -- makes it load-bearing: "k series = k bookings a week" only holds if
  -- two series cannot follow the same weekly rule. Two of them would
  -- also generate a duplicate Booking for every occurrence.
  if public.customer_standing_series_on_rule(v_customer.id, p_schedule_rule_id, v_today) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  -- The series starts today (local date of the organization), so that is
  -- the date whose plan decides. The day these RPCs accept a start date,
  -- this becomes greatest(start_date, v_today).
  perform public.assert_series_within_plan_quota(v_customer.id, v_rule.service_id, v_today);

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by, start_date)
  values (v_rule.organization_id, v_customer.id, p_schedule_rule_id, auth.uid(), v_today)
  returning * into v_rb;

  for v_occurrence_id in
    select id from public.slot_occurrences
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE' and start_at >= now()
  loop
    perform public.generate_recurring_booking(v_rb.id, v_occurrence_id);
  end loop;

  return v_rb;
end;
$BODY$;

comment on function public.create_recurring_booking(uuid) is
  'ADR-0024/ADR-0047: crea una reserva fija (RecurringBooking) self-service para el Customer autenticado sobre una ScheduleRule, y genera Bookings para toda ocurrencia futura ya materializada. Desde la correccion post-gate de la Fase 45 rechaza de entrada (SELF_SERVICE_CANNOT_CREATE_RECURRING) si el Customer tiene source=SELF_SERVICE -- evita que una cuenta auto-inscripta por reserva abierta vacie la agenda de una regla entera con una sola serie. Desde la Fase 47, "hoy" es la fecha local de la organizacion, no current_date del servidor.';

revoke execute on function public.create_recurring_booking(uuid) from public, anon;
grant execute on function public.create_recurring_booking(uuid) to authenticated;

-- admin_preview_recurring_booking() es de solo lectura (antesala de
-- admin_create_recurring_booking()), pero todavia resolvia
-- customer_standing_series_on_rule(..., current_date) con la fecha UTC
-- del servidor. En la misma ventana horaria del bug de arriba, el preview
-- podia decir "ya existe serie" (o "no existe") de forma inconsistente
-- con lo que hace la creacion real ya corregida en esta migracion. Mismo
-- cuerpo vigente de la Fase 32, unico cambio: resolver v_org y calcular
-- v_today como (now() at time zone v_org.timezone)::date, igual que las
-- otras dos funciones de esta migracion.
create or replace function public.admin_preview_recurring_booking(
  p_schedule_rule_id uuid,
  p_customer_id uuid,
  p_count int default 12
)
returns table (slot_occurrence_id uuid, start_at timestamptz, can_book public.can_book_reason)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_today date;
  v_existing_series uuid;
  v_rec record;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found or not public.has_org_permission(v_rule.organization_id, 'MANAGE_BOOKINGS') then
    return;
  end if;

  select * into v_org from public.organizations where id = v_rule.organization_id;
  v_today := (now() at time zone v_org.timezone)::date;

  v_existing_series := public.customer_standing_series_on_rule(
    p_customer_id, p_schedule_rule_id, v_today
  );

  for v_rec in
    select so.id, so.start_at as occ_start
    from public.slot_occurrences so
    where so.schedule_rule_id = p_schedule_rule_id
      and so.status = 'ACTIVE'
      and so.start_at >= now()
    order by so.start_at asc
    limit p_count
  loop
    slot_occurrence_id := v_rec.id;
    start_at := v_rec.occ_start;
    can_book := public.evaluate_customer_booking(
      v_rec.id,
      p_customer_id,
      v_existing_series,
      v_existing_series is null
    );
    return next;
  end loop;
end;
$BODY$;

revoke execute on function public.admin_preview_recurring_booking(uuid, uuid, int) from public, anon;
grant execute on function public.admin_preview_recurring_booking(uuid, uuid, int) to authenticated;

-- Backfill (una sola vez, dentro de esta misma migracion): series creadas
-- antes de este fix, durante la ventana 00:00-03:00 UTC en una
-- organizacion con timezone detras de UTC, pudieron quedar con
-- start_date = "manana" (fecha UTC del servidor, default de columna)
-- en vez de la fecha local real de creacion. Se corrige usando
-- created_at (hecho, no reinterpretable) como referencia de verdad.
-- Nunca sube start_date (solo lo baja o lo deja igual), asi que no puede
-- violar recurring_bookings_valid_range (end_date is null or end_date >=
-- start_date): bajar start_date nunca puede hacer que supere a un
-- end_date que ya lo cumplia, y en este repo end_date nunca tiene un
-- setter que lo escriba (siempre null en la practica).
update public.recurring_bookings rb
   set start_date = (rb.created_at at time zone o.timezone)::date
  from public.organizations o
 where o.id = rb.organization_id
   and rb.start_date > (rb.created_at at time zone o.timezone)::date;
