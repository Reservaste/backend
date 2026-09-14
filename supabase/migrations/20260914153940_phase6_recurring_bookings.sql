-- Phase 6: Recurring Bookings
-- Ref: docs/decisions.md ADR-0010, ADR-0011, ADR-0012; docs/domain.md
--
-- The Mathias/CrossFit case from planning: RecurringBooking RB1 generates
-- individual Booking rows, one per matching SlotOccurrence, all pointing
-- back to RB1. Cancelling one date cancels only that Booking -- RB1 stays
-- ACTIVE. Cancelling the whole series cancels RB1 and cascades to its
-- future CONFIRMED bookings only; past history is never touched.

-- ============================================================
-- recurring_bookings
-- ============================================================

create type public.recurring_booking_status as enum ('ACTIVE', 'CANCELLED');
create type public.recurring_booking_cancellation_reason as enum ('CUSTOMER_REQUEST', 'ORGANIZATION_REMOVED');

create table public.recurring_bookings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  -- FK to the rule, never a copy of its weekday/time -- one source of
  -- truth for the schedule (ADR-0010).
  schedule_rule_id uuid not null references public.schedule_rules (id) on delete cascade,
  status public.recurring_booking_status not null default 'ACTIVE',
  start_date date not null default current_date,
  end_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.recurring_booking_cancellation_reason,
  constraint recurring_bookings_valid_range check (end_date is null or end_date >= start_date)
);

comment on table public.recurring_bookings is
  'A customer''s subscription to a ScheduleRule. Stays ACTIVE even if every generated Booking is individually cancelled -- it expresses intent, not an aggregate of its children. Ref: docs/domain.md.';

create trigger recurring_bookings_set_updated_at
  before update on public.recurring_bookings
  for each row execute function public.set_updated_at();

create index recurring_bookings_organization_idx on public.recurring_bookings (organization_id);
create index recurring_bookings_customer_idx on public.recurring_bookings (customer_id);
create index recurring_bookings_rule_idx on public.recurring_bookings (schedule_rule_id);

create or replace function public.check_recurring_booking_same_org()
returns trigger
language plpgsql
as $$
declare
  v_customer_org uuid;
  v_rule_org uuid;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  select organization_id into v_rule_org from public.schedule_rules where id = new.schedule_rule_id;

  if v_customer_org is null or v_rule_org is null
     or v_customer_org <> new.organization_id or v_rule_org <> new.organization_id then
    raise exception 'RecurringBooking organization_id must match its Customer and ScheduleRule';
  end if;

  return new;
end;
$$;

create trigger recurring_bookings_same_org
  before insert or update on public.recurring_bookings
  for each row execute function public.check_recurring_booking_same_org();

-- ============================================================
-- bookings: add recurring_booking_id + NOT_GENERATED status (ADR-0010,
-- ADR-0011)
-- ============================================================

alter table public.bookings
  add column recurring_booking_id uuid references public.recurring_bookings (id);

create index bookings_recurring_booking_idx on public.bookings (recurring_booking_id);

-- ADR-0011: idempotency for the recurring-generation job -- never more
-- than one Booking per (series, occurrence), regardless of status. This
-- is a *different* guard from bookings_customer_occurrence_confirmed_idx
-- (Phase 5): that one stops the same customer holding two CONFIRMED
-- bookings on one occurrence; this one stops the generation job itself
-- from double-inserting on a retry/overlap.
create unique index bookings_recurring_occurrence_idx
  on public.bookings (recurring_booking_id, slot_occurrence_id)
  where recurring_booking_id is not null;

alter type public.booking_status add value 'NOT_GENERATED';

-- ============================================================
-- generate_recurring_booking(): sister RPC to book_slot() (ADR-0011), not
-- a plain insert -- a customer can be in two different RecurringBooking
-- series that land on the same SlotOccurrence, which the Phase 5 unique
-- index (customer_id, slot_occurrence_id) WHERE CONFIRMED would reject.
-- Falls back to NOT_GENERATED instead of raising when that happens.
-- ============================================================

create or replace function public.generate_recurring_booking(
  p_recurring_booking_id uuid,
  p_slot_occurrence_id uuid
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rb public.recurring_bookings;
  v_occurrence public.slot_occurrences;
  v_active_count int;
  v_booking public.bookings;
  v_status public.booking_status;
begin
  select * into v_rb from public.recurring_bookings where id = p_recurring_booking_id and status = 'ACTIVE';
  if not found then
    return null;
  end if;

  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return null;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  v_status := case when v_active_count < v_occurrence.capacity then 'CONFIRMED' else 'NOT_GENERATED' end;

  begin
    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, recurring_booking_id, status, created_by
    )
    values (
      v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id, v_status, v_rb.created_by
    )
    on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
    returning * into v_booking;
  exception
    when unique_violation then
      -- Hit bookings_customer_occurrence_confirmed_idx: this customer
      -- already holds a CONFIRMED booking on this occurrence from
      -- elsewhere (a manual booking, or a second RecurringBooking landing
      -- on the same date). Record the attempt as NOT_GENERATED rather
      -- than losing it silently or raising to the caller.
      insert into public.bookings (
        organization_id, customer_id, slot_occurrence_id, recurring_booking_id, status, created_by
      )
      values (
        v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id, 'NOT_GENERATED', v_rb.created_by
      )
      on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
      returning * into v_booking;
  end;

  return v_booking;
end;
$$;

-- ============================================================
-- Hook recurring generation into the rolling-window job (ADR-0009,
-- ADR-0011): whenever generation actually inserts a new SlotOccurrence
-- (not a no-op from ON CONFLICT), materialize Bookings for every ACTIVE
-- RecurringBooking following that same rule.
-- ============================================================

create or replace function public.generate_slot_occurrences_for_rule(
  p_schedule_rule_id uuid,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_horizon_end date;
  v_day date;
  v_exception public.schedule_exceptions;
  v_local_start_time time;
  v_duration_minutes int;
  v_capacity int;
  v_start_at timestamptz;
  v_new_occurrence_id uuid;
  v_recurring_booking_id uuid;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    return;
  end if;

  select * into v_org from public.organizations where id = v_rule.organization_id;

  v_horizon_end := least(
    current_date + p_horizon_days,
    coalesce(v_rule.valid_until, current_date + p_horizon_days)
  );

  v_day := greatest(v_rule.valid_from, current_date);
  v_day := v_day + ((v_rule.weekday - extract(dow from v_day)::int + 7) % 7);

  while v_day <= v_horizon_end loop
    select * into v_exception
      from public.schedule_exceptions
      where schedule_rule_id = p_schedule_rule_id and exception_date = v_day;

    if found and v_exception.exception_type = 'CANCELLED' then
      v_day := v_day + 7;
      continue;
    end if;

    v_local_start_time := coalesce((case when found then v_exception.modified_local_start_time end), v_rule.local_start_time);
    v_duration_minutes := coalesce((case when found then v_exception.modified_duration_minutes end), v_rule.duration_minutes);
    v_capacity := coalesce((case when found then v_exception.modified_capacity end), v_rule.capacity);

    v_start_at := (v_day + v_local_start_time) at time zone v_org.timezone;

    insert into public.slot_occurrences (
      organization_id, schedule_rule_id, service_id, resource_id,
      start_at, end_at, generated_timezone, capacity,
      schedule_exception_id
    )
    values (
      v_rule.organization_id, v_rule.id, v_rule.service_id, v_rule.resource_id,
      v_start_at, v_start_at + make_interval(mins => v_duration_minutes), v_org.timezone, v_capacity,
      case when found then v_exception.id else null end
    )
    on conflict (schedule_rule_id, start_at) do nothing
    returning id into v_new_occurrence_id;

    -- Only for occurrences this call actually created -- ON CONFLICT
    -- skipping an insert leaves v_new_occurrence_id null, and an
    -- already-existing occurrence already had its recurring bookings
    -- generated the first time it was created.
    if v_new_occurrence_id is not null then
      for v_recurring_booking_id in
        select id from public.recurring_bookings
        where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE'
      loop
        perform public.generate_recurring_booking(v_recurring_booking_id, v_new_occurrence_id);
      end loop;
    end if;

    v_day := v_day + 7;
  end loop;
end;
$$;

-- ============================================================
-- preview_recurring_booking(): read-only, no locking, no writes
-- (ADR-0012). For each of the next N already-materialized occurrences of
-- a rule, reports whether this customer could book it right now --
-- reusing can_customer_book() so preview and confirm can never disagree
-- about the rule itself.
-- ============================================================

create or replace function public.preview_recurring_booking(p_schedule_rule_id uuid, p_count int default 12)
returns table (slot_occurrence_id uuid, start_at timestamptz, can_book public.can_book_reason)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rec record;
begin
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
    can_book := public.can_customer_book(v_rec.id);
    return next;
  end loop;
end;
$$;

grant execute on function public.preview_recurring_booking(uuid, int) to authenticated;

-- ============================================================
-- create_recurring_booking(): the confirm step (ADR-0012). No silent
-- partial booking -- the client is expected to have shown the caller
-- preview_recurring_booking()'s result first, but this itself will
-- happily create the series and let generate_recurring_booking() record
-- NOT_GENERATED for whichever already-materialized occurrences are full,
-- exactly like the preview said it would.
-- ============================================================

create or replace function public.create_recurring_booking(p_schedule_rule_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.schedule_rules;
  v_customer public.customers;
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
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

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by)
  values (v_rule.organization_id, v_customer.id, p_schedule_rule_id, auth.uid())
  returning * into v_rb;

  for v_occurrence_id in
    select id from public.slot_occurrences
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE' and start_at >= now()
  loop
    perform public.generate_recurring_booking(v_rb.id, v_occurrence_id);
  end loop;

  return v_rb;
end;
$$;

grant execute on function public.create_recurring_booking(uuid) to authenticated;

-- ============================================================
-- cancel_recurring_booking(): cancels the series and cascades to future
-- CONFIRMED bookings only (ADR-0010) -- cancelling one date of a series
-- is just cancel_booking() on that one Booking row, no new RPC needed.
-- ============================================================

create or replace function public.cancel_recurring_booking(p_recurring_booking_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rb public.recurring_bookings;
  v_customer public.customers;
  v_reason public.recurring_booking_cancellation_reason;
  v_booking_reason public.booking_cancellation_reason;
begin
  select * into v_rb from public.recurring_bookings where id = p_recurring_booking_id;
  if not found then
    raise exception 'RECURRING_BOOKING_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_rb.customer_id;

  if v_customer.profile_id = auth.uid() then
    v_reason := 'CUSTOMER_REQUEST';
    v_booking_reason := 'CUSTOMER_REQUEST';
  elsif public.is_organization_member(v_rb.organization_id) then
    v_reason := 'ORGANIZATION_REMOVED';
    v_booking_reason := 'RULE_DISCONTINUED';
  else
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_rb.status = 'CANCELLED' then
    return v_rb;
  end if;

  update public.recurring_bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_reason
    where id = p_recurring_booking_id
    returning * into v_rb;

  update public.bookings b
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_booking_reason
    from public.slot_occurrences so
    where b.slot_occurrence_id = so.id
      and b.recurring_booking_id = p_recurring_booking_id
      and so.start_at >= now()
      and b.status = 'CONFIRMED';

  return v_rb;
end;
$$;

grant execute on function public.cancel_recurring_booking(uuid) to authenticated;

-- ============================================================
-- Close the ADR-0010 gap: discontinuing a ScheduleRule must also cancel
-- any RecurringBooking following it, not just its Booking children --
-- otherwise the series stays ACTIVE pointing at a rule that no longer
-- generates anything.
-- ============================================================

create or replace function public.discontinue_schedule_rule(p_schedule_rule_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.schedule_rules;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_rule.organization_id) then
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

  update public.bookings b
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'RULE_DISCONTINUED'
    from public.slot_occurrences so
    where b.slot_occurrence_id = so.id
      and so.schedule_rule_id = p_schedule_rule_id
      and so.start_at >= now()
      and b.status = 'CONFIRMED';

  update public.recurring_bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'ORGANIZATION_REMOVED'
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE';
end;
$$;

-- ============================================================
-- Row Level Security -- SELECT-only, same reasoning as bookings: every
-- write goes through the RPCs above.
-- ============================================================

alter table public.recurring_bookings enable row level security;

create policy recurring_bookings_select_self_or_staff
  on public.recurring_bookings for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = recurring_bookings.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );
