-- Phase 16: schedule rule groups, attendance, and the payments overview
-- Ref: docs/decisions.md ADR-0022, ADR-0023
--
-- Backend for three screens that share nothing except needing the data
-- to exist: multi-day schedules, taking attendance, and "who paid".

-- ============================================================
-- C. Schedule rule groups
-- ============================================================
-- One rule per weekday stays the model (ADR-0022). These two functions
-- are what let the UI treat "Mon/Wed/Fri 09:00" as a single action
-- without the schema pretending it is a single row.

create or replace function public.create_schedule_rule_group(
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays smallint[],
  p_local_start_time time,
  p_duration_minutes int,
  p_capacity int
)
returns setof public.schedule_rules
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_group_id uuid := gen_random_uuid();
  v_weekday smallint;
  v_rule public.schedule_rules;
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_service.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if p_weekdays is null or array_length(p_weekdays, 1) is null then
    raise exception 'NO_WEEKDAYS';
  end if;

  -- Distinct and ordered: picking Monday twice in the UI must not create
  -- two identical rules that then both generate occurrences.
  for v_weekday in select distinct unnest(p_weekdays) order by 1 loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;

    insert into public.schedule_rules (
      organization_id, service_id, resource_id, weekday, local_start_time,
      duration_minutes, capacity, group_id, created_by
    )
    values (
      v_service.organization_id, p_service_id, p_resource_id, v_weekday, p_local_start_time,
      p_duration_minutes, p_capacity, v_group_id, auth.uid()
    )
    returning * into v_rule;

    return next v_rule;
  end loop;
end;
$BODY$;

grant execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) to authenticated;

/** The grouped shape the schedule screen renders: one row per group. */
create or replace function public.schedule_rule_groups(p_service_id uuid)
returns table (
  group_id uuid,
  resource_id uuid,
  resource_name text,
  local_start_time time,
  duration_minutes int,
  capacity int,
  weekdays smallint[],
  rule_ids uuid[]
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    sr.group_id,
    min(sr.resource_id::text)::uuid,
    min(r.name),
    min(sr.local_start_time),
    min(sr.duration_minutes),
    min(sr.capacity),
    array_agg(sr.weekday order by sr.weekday),
    array_agg(sr.id order by sr.weekday)
  from public.schedule_rules sr
  join public.resources r on r.id = sr.resource_id
  join public.services s on s.id = sr.service_id
  where sr.service_id = p_service_id
    and sr.is_active
    and public.is_organization_member(s.organization_id)
  group by sr.group_id
  order by min(sr.local_start_time) asc;
$BODY$;

grant execute on function public.schedule_rule_groups(uuid) to authenticated;

/** Discontinues every rule in a group, with the Phase 3 cascade each. */
create or replace function public.discontinue_schedule_rule_group(p_group_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule_id uuid;
  v_count int := 0;
begin
  for v_rule_id in
    select sr.id from public.schedule_rules sr
    join public.services s on s.id = sr.service_id
    where sr.group_id = p_group_id
      and sr.is_active
      and public.is_organization_member(s.organization_id)
  loop
    perform public.discontinue_schedule_rule(v_rule_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$BODY$;

grant execute on function public.discontinue_schedule_rule_group(uuid) to authenticated;

-- ============================================================
-- D. The public calendar needs the service's name
-- ============================================================

drop function if exists public.get_public_availability(text, uuid, timestamptz, timestamptz);

-- Body unchanged from Phase 5 except for the two new columns: the
-- disclosure rules of ADR-0008 are tested behaviour (EXACT discloses the
-- number and no status; LIMITED reports LOW against a threshold built
-- from the organization's percentage and fixed cap) and rewriting them
-- from memory is how they silently change.
create function public.get_public_availability(
  p_organization_slug text,
  p_service_id uuid default null,
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns table (
  slot_occurrence_id uuid,
  service_id uuid,
  service_name text,
  service_color text,
  start_at timestamptz,
  end_at timestamptz,
  mode text,
  status text,
  remaining int,
  capacity int
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org public.organizations;
begin
  select * into v_org from public.organizations where slug = p_organization_slug and is_active;
  if not found then
    return;
  end if;

  return query
    select
      so.id,
      so.service_id,
      s.name,
      s.color,
      so.start_at,
      so.end_at,
      effective.mode,
      case
        when effective.mode = 'EXACT' then null
        when effective.remaining <= 0 then 'FULL'
        when effective.mode = 'LIMITED' and effective.remaining <= effective.low_threshold then 'LOW'
        else 'AVAILABLE'
      end as status,
      case when effective.mode = 'EXACT' then effective.remaining end as remaining,
      case when effective.mode = 'EXACT' then so.capacity end as capacity
    from public.slot_occurrences so
    join public.services s on s.id = so.service_id and s.is_active
    cross join lateral (
      select
        coalesce(s.public_availability_display_override, v_org.public_availability_display) as mode,
        (so.capacity - (
          select count(*) from public.bookings b
          where b.slot_occurrence_id = so.id and b.status = 'CONFIRMED'
        ))::int as remaining,
        greatest(
          1,
          least(
            coalesce(v_org.low_availability_fixed_cap, so.capacity),
            ceil(so.capacity * v_org.low_availability_percentage / 100.0)::int
          )
        ) as low_threshold
    ) as effective
    where so.organization_id = v_org.id
      and so.status = 'ACTIVE'
      and so.start_at >= p_from
      and so.start_at <= p_to
      and (p_service_id is null or so.service_id = p_service_id)
    order by so.start_at asc;
end;
$BODY$;

grant execute on function public.get_public_availability(text, uuid, timestamptz, timestamptz) to anon, authenticated;

-- ============================================================
-- E. Attendance
-- ============================================================
-- Booking says the person reserved; attendance says they showed up
-- (ADR-0022). Cancelled bookings are excluded from the roll call but
-- keep whatever attendance was already recorded.

drop function if exists public.occurrence_bookings(uuid);

create function public.occurrence_bookings(p_slot_occurrence_id uuid)
returns table (
  booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.booking_status,
  attendance_status public.attendance_status,
  attendance_marked_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    b.id,
    b.customer_id,
    coalesce(p.full_name, 'Sin nombre'),
    b.status,
    b.attendance_status,
    b.attendance_marked_at,
    b.created_at
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.profiles p on p.id = c.profile_id
  where b.slot_occurrence_id = p_slot_occurrence_id
    and public.is_organization_member(b.organization_id)
  order by coalesce(p.full_name, 'Sin nombre') asc;
$BODY$;

grant execute on function public.occurrence_bookings(uuid) to authenticated;

create or replace function public.mark_attendance(
  p_booking_id uuid,
  p_status public.attendance_status
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'BOOKING_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_booking.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Taking attendance for someone who cancelled is a data-entry mistake,
  -- not a workflow: they are not in the room and not on the list.
  if v_booking.status <> 'CONFIRMED' then
    raise exception 'BOOKING_NOT_CONFIRMED';
  end if;

  update public.bookings
    set attendance_status = p_status,
        attendance_marked_at = case when p_status = 'PENDING' then null else now() end,
        attendance_marked_by = case when p_status = 'PENDING' then null else auth.uid() end
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

grant execute on function public.mark_attendance(uuid, public.attendance_status) to authenticated;

/** Reserved / present / absent / pending for one occurrence. */
create or replace function public.occurrence_attendance_summary(p_slot_occurrence_id uuid)
returns table (reserved int, present int, absent int, pending int)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    count(*) filter (where b.status = 'CONFIRMED')::int,
    count(*) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'PRESENT')::int,
    count(*) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'ABSENT')::int,
    count(*) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'PENDING')::int
  from public.bookings b
  where b.slot_occurrence_id = p_slot_occurrence_id
    and public.is_organization_member(b.organization_id);
$BODY$;

grant execute on function public.occurrence_attendance_summary(uuid) to authenticated;

/** Past occurrences of a service with their roll-call totals. */
create or replace function public.service_attendance_history(
  p_service_id uuid,
  p_limit int default 30
)
returns table (
  slot_occurrence_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  reserved int,
  present int,
  absent int,
  pending int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    so.id,
    so.start_at,
    so.end_at,
    count(b.id) filter (where b.status = 'CONFIRMED')::int,
    count(b.id) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'PRESENT')::int,
    count(b.id) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'ABSENT')::int,
    count(b.id) filter (where b.status = 'CONFIRMED' and b.attendance_status = 'PENDING')::int
  from public.slot_occurrences so
  join public.services s on s.id = so.service_id
  left join public.bookings b on b.slot_occurrence_id = so.id
  where so.service_id = p_service_id
    and so.start_at < now()
    and public.is_organization_member(s.organization_id)
  group by so.id, so.start_at, so.end_at
  order by so.start_at desc
  limit p_limit;
$BODY$;

grant execute on function public.service_attendance_history(uuid, int) to authenticated;

-- ============================================================
-- F. Payments overview
-- ============================================================
-- "Who paid and who did not", which is the question the screen exists to
-- answer. Rolled up per customer over a period; the detail function
-- breaks the same period down per service.

create or replace function public.organization_payment_summary(
  p_organization_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  customer_id uuid,
  customer_name text,
  is_active boolean,
  services_count int,
  total numeric,
  paid numeric,
  pending numeric,
  rollup_status text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    c.id,
    coalesce(p.full_name, 'Sin nombre'),
    c.is_active,
    count(distinct pay.service_id)::int,
    coalesce(sum(pay.amount) filter (where pay.status <> 'VOID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status = 'PAID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status in ('PENDING', 'OVERDUE')), 0),
    case
      when count(pay.id) filter (where pay.status <> 'VOID') = 0 then 'NO_PAYMENTS'
      when count(pay.id) filter (where pay.status = 'OVERDUE') > 0 then 'OVERDUE'
      when count(pay.id) filter (where pay.status in ('PENDING', 'OVERDUE')) = 0 then 'PAID'
      when count(pay.id) filter (where pay.status = 'PAID') = 0 then 'PENDING'
      else 'PARTIAL'
    end
  from public.customers c
  join public.profiles p on p.id = c.profile_id
  left join public.payments pay
    on pay.customer_id = c.id
   and pay.period_start <= p_period_end
   and pay.period_end >= p_period_start
  where c.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  group by c.id, p.full_name, c.is_active
  order by coalesce(p.full_name, 'Sin nombre') asc;
$BODY$;

grant execute on function public.organization_payment_summary(uuid, date, date) to authenticated;

/** The same period, broken down per service, for one customer. */
create or replace function public.customer_payment_detail(
  p_customer_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  payment_id uuid,
  service_id uuid,
  service_name text,
  period_start date,
  period_end date,
  status public.payment_status,
  amount numeric,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    pay.id,
    s.id,
    s.name,
    pay.period_start,
    pay.period_end,
    pay.status,
    pay.amount,
    pay.created_at
  from public.payments pay
  join public.services s on s.id = pay.service_id
  where pay.customer_id = p_customer_id
    and pay.period_start <= p_period_end
    and pay.period_end >= p_period_start
    and public.is_organization_member(pay.organization_id)
  order by s.name asc, pay.period_start desc;
$BODY$;

grant execute on function public.customer_payment_detail(uuid, date, date) to authenticated;

/** Flips a payment's status from the payments screen. */
create or replace function public.set_payment_status(
  p_payment_id uuid,
  p_status public.payment_status
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if not found then
    raise exception 'PAYMENT_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_payment.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.payments set status = p_status where id = p_payment_id
    returning * into v_payment;

  return v_payment;
end;
$BODY$;

grant execute on function public.set_payment_status(uuid, public.payment_status) to authenticated;
