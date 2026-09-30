-- Phase 42: exclusive Resources -- database-level anti-overlap
-- Ref: docs/decisions.md ADR-0044
--
-- Problem (see ADR-0044 for the full audit): nothing, at any level,
-- stops the same Resource (e.g. a single barber, a single consulting
-- room) from being double-booked at the same time across two different
-- Services. book_slot()/can_customer_book() only validate the capacity
-- of the SlotOccurrence being booked, and generate_slot_occurrences_for_rule()
-- never looks at any other ScheduleRule on the same Resource. This
-- migration adds a generic "is_exclusive" flag (never gym/barber-specific
-- wording) backed by a real exclusion constraint -- not just an RPC-level
-- check, because the generator and the daily cron insert
-- slot_occurrences on their own, outside any single entry point.

-- ============================================================
-- 1. resources.is_exclusive
-- ============================================================

alter table public.resources
  add column is_exclusive boolean not null default false;

comment on column public.resources.is_exclusive is
  'Occupied one booking at a time -- no two ACTIVE SlotOccurrence rows for '
  'this Resource may overlap in time. Generic: applies equally to a single '
  'professional, a 1-on-1 court, a consulting room. Ref: ADR-0044.';

-- ============================================================
-- 2. slot_occurrences.resource_is_exclusive (denormalized)
-- ============================================================
-- An EXCLUDE constraint cannot look at another table, so the flag has to
-- live on slot_occurrences itself, kept in sync by the two triggers below.

alter table public.slot_occurrences
  add column resource_is_exclusive boolean not null default false;

comment on column public.slot_occurrences.resource_is_exclusive is
  'Denormalized copy of resources.is_exclusive at the time this row was '
  'generated/last pointed at its Resource, kept in sync by '
  'slot_occurrences_set_resource_is_exclusive and '
  'resources_propagate_is_exclusive. Backs '
  'slot_occurrences_exclusive_resource_no_overlap. Ref: ADR-0044.';

-- Populates resource_is_exclusive from resources.is_exclusive whenever a
-- row is inserted, or its resource_id changes (moving an occurrence to a
-- different Resource must re-evaluate the flag for the new Resource, not
-- keep stale data from the old one). SECURITY DEFINER so it behaves the
-- same regardless of which privileged path is doing the insert
-- (generate_slot_occurrences_for_rule, the cron job, or a service-role
-- fixture) -- same defensive reasoning as
-- apply_schedule_exception_to_existing_occurrence in Phase 3.
create or replace function public.slot_occurrences_set_resource_is_exclusive()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  select r.is_exclusive into new.resource_is_exclusive
    from public.resources r
    where r.id = new.resource_id;

  return new;
end;
$BODY$;

create trigger slot_occurrences_set_resource_is_exclusive
  before insert or update of resource_id on public.slot_occurrences
  for each row execute function public.slot_occurrences_set_resource_is_exclusive();

-- Propagates a change to resources.is_exclusive onto already-materialized
-- occurrences -- but only future, ACTIVE ones. The past is never
-- revisited (nothing to protect retroactively), and BLOCKED/CANCELLED
-- occurrences are not part of the invariant this flag backs.
create or replace function public.resources_propagate_is_exclusive()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.is_exclusive is distinct from old.is_exclusive then
    update public.slot_occurrences
      set resource_is_exclusive = new.is_exclusive
      where resource_id = new.id
        and status = 'ACTIVE'
        and start_at >= now();
  end if;

  return new;
end;
$BODY$;

create trigger resources_propagate_is_exclusive
  after update of is_exclusive on public.resources
  for each row execute function public.resources_propagate_is_exclusive();

-- ============================================================
-- 3. The exclusion constraint itself
-- ============================================================
-- btree_gist already installed (Phase 7's payments_no_overlapping_paid).
-- '[)' (start inclusive, end exclusive) means two back-to-back occurrences
-- (10:00-10:30 and 10:30-11:00) do not count as overlapping.
-- BLOCKED/CANCELLED rows are outside the constraint, so cancelling an
-- occurrence immediately frees the Resource for that slot, same as every
-- other capacity invariant in this system.
--
-- No existing row can violate this at add-constraint time: every
-- resources.is_exclusive (and therefore every resource_is_exclusive) is
-- false until an organization opts in, and Postgres validates new/changed
-- rows against an EXCLUDE constraint added this way the same as a CHECK.
alter table public.slot_occurrences
  add constraint slot_occurrences_exclusive_resource_no_overlap
  exclude using gist (
    resource_id with =,
    tstzrange(start_at, end_at, '[)') with &&
  ) where (status = 'ACTIVE' and resource_is_exclusive);

-- ============================================================
-- 4. generate_slot_occurrences_for_rule(): skip conflicting occurrences
--    instead of aborting the whole regeneration
-- ============================================================
-- Same body as the Phase 19 version (tenant check + horizon clamp), with
-- the single insert now wrapped in its own sub-transaction: an
-- exclusion_violation (two ScheduleRules on the same exclusive Resource
-- landing on the same instant) skips just that one date. Without this, a
-- single organization's scheduling conflict would raise an unhandled
-- exception inside generate_all_slot_occurrences()'s per-rule loop and
-- stop the daily cron dead for every other organization sharing that
-- transaction-less loop.
create or replace function public.generate_slot_occurrences_for_rule(
  p_schedule_rule_id uuid,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_horizon_days int;
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

  if auth.uid() is not null and not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- ADR-0009's window is 90 days. Anything past a year is not a horizon,
  -- it is a way to make one call insert a few hundred thousand rows.
  v_horizon_days := least(greatest(coalesce(p_horizon_days, 90), 0), 365);

  select * into v_org from public.organizations where id = v_rule.organization_id;

  v_horizon_end := least(
    current_date + v_horizon_days,
    coalesce(v_rule.valid_until, current_date + v_horizon_days)
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

    v_new_occurrence_id := null;
    begin
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
    exception
      when exclusion_violation then
        -- ADR-0044: this Resource is exclusive and already has an
        -- overlapping ACTIVE occurrence from another ScheduleRule. Skip
        -- only this one date -- never abort the rest of the rule, and
        -- never abort the rest of the tenant's/cron's run.
        v_new_occurrence_id := null;
    end;

    -- Only for occurrences this call actually created -- ON CONFLICT
    -- skipping an insert (or the exclusion_violation above) leaves
    -- v_new_occurrence_id null, and an already-existing occurrence
    -- already had its recurring bookings generated the first time it was
    -- created.
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
$BODY$;

revoke execute on function public.generate_slot_occurrences_for_rule(uuid, int) from public, anon;
grant execute on function public.generate_slot_occurrences_for_rule(uuid, int) to authenticated, service_role;

-- ============================================================
-- 5. check_schedule_rule_conflicts(): pre-check before creating a rule
-- ============================================================
-- Projects each weekday x local_start_time combination 90 days forward
-- (same horizon as generation) and returns any ACTIVE occurrence already
-- on the same exclusive Resource that would overlap. This is a courtesy
-- that turns a conflict into a readable RESOURCE_SCHEDULE_CONFLICT before
-- ever attempting the insert -- slot_occurrences_exclusive_resource_no_overlap
-- above is the real, final backstop regardless of whether a caller
-- bothers to run this check first.
--
-- p_exclude_rule_id lets an edit-in-place caller exclude the very rule
-- being edited from counting as a conflict against itself (not used by
-- create_schedule_rule_group below, which only ever creates new rules,
-- but part of the function's contract for future callers -- e.g. an
-- update-rule RPC).
create or replace function public.check_schedule_rule_conflicts(
  p_resource_id uuid,
  p_weekday int[],
  p_local_start_time time[],
  p_duration_minutes int,
  p_exclude_rule_id uuid default null
)
returns table (
  weekday int,
  local_start_time time,
  conflict_start_at timestamptz,
  conflict_end_at timestamptz,
  existing_slot_occurrence_id uuid,
  existing_schedule_rule_id uuid
)
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
  v_org public.organizations;
  v_weekday int;
  v_local_start_time time;
  v_day date;
  v_horizon_end date;
  v_start_at timestamptz;
  v_end_at timestamptz;
begin
  select * into v_resource from public.resources where id = p_resource_id;
  if not found then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_resource.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Nothing to project for a non-exclusive resource -- overlap is allowed
  -- by design (ADR-0044), unchanged from before this migration.
  if not v_resource.is_exclusive then
    return;
  end if;

  if p_weekday is null or array_length(p_weekday, 1) is null
     or p_local_start_time is null or array_length(p_local_start_time, 1) is null then
    return;
  end if;

  select * into v_org from public.organizations where id = v_resource.organization_id;
  v_horizon_end := current_date + 90;

  foreach v_weekday in array p_weekday loop
    foreach v_local_start_time in array p_local_start_time loop
      v_day := current_date + ((v_weekday - extract(dow from current_date)::int + 7) % 7);

      while v_day <= v_horizon_end loop
        v_start_at := (v_day + v_local_start_time) at time zone v_org.timezone;
        v_end_at := v_start_at + make_interval(mins => p_duration_minutes);

        return query
          select v_weekday, v_local_start_time, so.start_at, so.end_at, so.id, so.schedule_rule_id
          from public.slot_occurrences so
          where so.resource_id = p_resource_id
            and so.status = 'ACTIVE'
            and so.resource_is_exclusive
            and (p_exclude_rule_id is null or so.schedule_rule_id <> p_exclude_rule_id)
            and tstzrange(so.start_at, so.end_at, '[)') && tstzrange(v_start_at, v_end_at, '[)');

        v_day := v_day + 7;
      end loop;
    end loop;
  end loop;
end;
$BODY$;

revoke execute on function public.check_schedule_rule_conflicts(uuid, int[], time[], int, uuid) from public, anon;
grant execute on function public.check_schedule_rule_conflicts(uuid, int[], time[], int, uuid) to authenticated, service_role;

-- ============================================================
-- 6. create_schedule_rule_group(): call the pre-check before inserting
-- ============================================================
-- Same body as Phase 16, with one addition: reject up front with
-- RESOURCE_SCHEDULE_CONFLICT when the Resource is exclusive and any of
-- the requested weekdays would overlap an existing occurrence, instead of
-- letting the first conflicting insert fail with a raw
-- exclusion_violation.
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
  v_conflict record;
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

  select * into v_conflict
    from public.check_schedule_rule_conflicts(
      p_resource_id, p_weekdays::int[], array[p_local_start_time]::time[], p_duration_minutes
    )
    limit 1;
  if found then
    raise exception 'RESOURCE_SCHEDULE_CONFLICT: weekday % at % conflicts with an existing occurrence starting %',
      v_conflict.weekday, v_conflict.local_start_time, v_conflict.conflict_start_at;
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

revoke execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) from public, anon;
grant execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) to authenticated;
