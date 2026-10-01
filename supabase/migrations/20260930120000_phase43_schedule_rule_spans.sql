-- Phase 43: schedule rule generator by time-of-day span
-- Ref: docs/decisions.md ADR-0045
--
-- Problem (see ADR-0045 for the full context): loading the agenda of a
-- single-appointment business today means creating one ScheduleRule per
-- start time, one form submission at a time -- for a barbershop with 2
-- professionals, Monday-Saturday 10-20 with 30-minute slots, that is
-- roughly 40 submissions. create_schedule_rule_group() (ADR-0022) already
-- takes the cartesian product weekdays[] x ONE local_start_time; this
-- migration extends the same idea to weekdays[] x a whole
-- [range_start, range_end) span expanded by step_minutes, without
-- changing the ScheduleRule model (still one row per day+time, never a
-- range) -- ScheduleException's (rule, date) key, the discontinue
-- cascade, and RecurringBooking.schedule_rule_id all assume a punctual
-- rule, same reasoning already written up for ADR-0022
-- (docs/decisions.md:1154-1161).
--
-- This migration also extracts the shared "expand + conflict-check +
-- insert, atomically" routine (create_schedule_rules_batch, internal
-- only -- not granted to any client role) so create_schedule_rule_group()
-- and the new create_schedule_rule_span() stop duplicating that logic.
-- create_schedule_rule_group()'s own signature and observable behaviour
-- are unchanged (see phase16/phase34 tests, still green against this
-- version).

-- ============================================================
-- 1. create_schedule_rules_batch(): shared internal routine
-- ============================================================
-- Not a public RPC -- revoked from public/anon/authenticated below.
-- Callable only from inside another SECURITY DEFINER function (which runs
-- as the function owner, bypassing the revoke), which is exactly how
-- create_schedule_rule_group() and create_schedule_rule_span() use it.
-- Both callers have already resolved+authorized the Service and deduped
-- weekdays/local_start_times before reaching here -- this routine's only
-- job is: one conflict check for the whole expanded grid
-- (check_schedule_rule_conflicts, ADR-0044), then insert every
-- weekday x local_start_time combination under one new group_id. The
-- conflict check runs to completion BEFORE any insert, so a rejected
-- batch never leaves partial rows behind -- atomic by construction, no
-- explicit transaction management needed beyond the implicit one every
-- function call already runs inside.
create or replace function public.create_schedule_rules_batch(
  p_organization_id uuid,
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays int[],
  p_local_start_times time[],
  p_duration_minutes int,
  p_capacity int
)
returns setof public.schedule_rules
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_group_id uuid := gen_random_uuid();
  v_weekday int;
  v_local_start_time time;
  v_rule public.schedule_rules;
  v_conflict record;
begin
  select * into v_conflict
    from public.check_schedule_rule_conflicts(
      p_resource_id, p_weekdays, p_local_start_times, p_duration_minutes
    )
    limit 1;
  if found then
    raise exception 'RESOURCE_SCHEDULE_CONFLICT: weekday % at % conflicts with an existing occurrence starting %',
      v_conflict.weekday, v_conflict.local_start_time, v_conflict.conflict_start_at;
  end if;

  foreach v_weekday in array p_weekdays loop
    foreach v_local_start_time in array p_local_start_times loop
      insert into public.schedule_rules (
        organization_id, service_id, resource_id, weekday, local_start_time,
        duration_minutes, capacity, group_id, created_by
      )
      values (
        p_organization_id, p_service_id, p_resource_id, v_weekday, v_local_start_time,
        p_duration_minutes, p_capacity, v_group_id, auth.uid()
      )
      returning * into v_rule;

      return next v_rule;
    end loop;
  end loop;
end;
$BODY$;

revoke execute on function public.create_schedule_rules_batch(uuid, uuid, uuid, int[], time[], int, int)
  from public, anon, authenticated;

-- ============================================================
-- 2. create_schedule_rule_group(): same signature, same behaviour,
--    now delegating to the shared routine above
-- ============================================================
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
  v_weekdays_distinct int[];
  v_weekday int;
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
  select array_agg(distinct w order by w) into v_weekdays_distinct from unnest(p_weekdays::int[]) w;

  foreach v_weekday in array v_weekdays_distinct loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;
  end loop;

  return query select * from public.create_schedule_rules_batch(
    v_service.organization_id, v_service.id, p_resource_id,
    v_weekdays_distinct, array[p_local_start_time]::time[], p_duration_minutes, p_capacity
  );
end;
$BODY$;

revoke execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) from public, anon;
grant execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) to authenticated;

-- ============================================================
-- 3. create_schedule_rule_span(): the new entry point
-- ============================================================
-- Returns just the shared group_id (uuid), not the rows -- per ADR-0045's
-- signature. Uses array_agg(...) (no LIMIT) over create_schedule_rules_batch
-- to force full consumption of that set-returning function: a bare
-- "select ... limit 1" over a SRF risks Postgres stopping after the first
-- produced row, which here would mean only the first ScheduleRule in the
-- batch actually gets inserted. array_agg has no such short-circuit -- it
-- must exhaust the function to aggregate, so the whole batch is always
-- either fully inserted or, on conflict, not inserted at all.
create or replace function public.create_schedule_rule_span(
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays int[],
  p_range_start time,
  p_range_end time,
  p_step_minutes int,
  p_duration_minutes int,
  p_capacity int
)
returns uuid
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_resource public.resources;
  v_weekdays_distinct int[];
  v_weekday int;
  v_start_times time[];
  v_num_starts int;
  v_total int;
  v_group_ids uuid[];
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  -- Same permission check as create_schedule_rule_group (ADR-0022/ADR-0045):
  -- any member of the Service's organization, no narrower permission.
  if not public.is_organization_member(v_service.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if not found then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  if p_duration_minutes is null or p_duration_minutes <= 0 then
    raise exception 'INVALID_DURATION';
  end if;

  -- ADR-0045's defensive floor: below this, a single call to this RPC
  -- could expand into tens of thousands of SlotOccurrence rows once the
  -- generator's 90-day horizon multiplies each ScheduleRule out -- a
  -- storage DoS vector, not a real scheduling need.
  if p_step_minutes is null or p_step_minutes < 5 then
    raise exception 'STEP_TOO_SHORT: step_minutes must be at least 5 minutes, got %', p_step_minutes;
  end if;

  -- ADR-0044: an exclusive Resource is occupied one booking at a time. A
  -- step shorter than the duration would generate ScheduleRules whose own
  -- occurrences overlap each other from the very first regeneration --
  -- reject before touching the database at all, not after the exclusion
  -- constraint (or check_schedule_rule_conflicts) catches it mid-insert.
  if v_resource.is_exclusive and p_step_minutes < p_duration_minutes then
    raise exception 'SPAN_SELF_OVERLAP_ON_EXCLUSIVE_RESOURCE: step_minutes (%) is shorter than duration_minutes (%) on an exclusive Resource -- generated occurrences would overlap each other',
      p_step_minutes, p_duration_minutes;
  end if;

  -- ADR-0044: capacity > 1 on an exclusive Resource is a contradiction --
  -- an exclusive Resource is, by definition, occupied one booking at a time.
  if v_resource.is_exclusive and coalesce(p_capacity, 1) > 1 then
    raise exception 'EXCLUSIVE_RESOURCE_CAPACITY_MUST_BE_ONE';
  end if;

  if p_range_start is null or p_range_end is null or p_range_end <= p_range_start then
    raise exception 'INVALID_RANGE';
  end if;

  if p_weekdays is null or array_length(p_weekdays, 1) is null then
    raise exception 'NO_WEEKDAYS';
  end if;

  -- Only 7 weekdays exist -- anything claiming more entries up front is
  -- already bogus input, duplicates or not.
  if array_length(p_weekdays, 1) > 7 then
    raise exception 'INVALID_WEEKDAY: too many weekday entries';
  end if;

  select array_agg(distinct w order by w) into v_weekdays_distinct from unnest(p_weekdays) w;

  foreach v_weekday in array v_weekdays_distinct loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;
  end loop;

  -- Expand local_start_time over [range_start, range_end), keeping only
  -- starts where start + duration_minutes <= range_end. generate_series
  -- has no overload for plain `time`, so this anchors both bounds to an
  -- arbitrary fixed date (pure time-of-day arithmetic, never a real
  -- calendar date -- the actual date/timezone conversion happens later,
  -- per occurrence, in generate_slot_occurrences_for_rule).
  select array_agg(gs::time order by gs) into v_start_times
    from generate_series(
      date '2000-01-01' + p_range_start,
      date '2000-01-01' + p_range_end - make_interval(mins => p_duration_minutes),
      make_interval(mins => p_step_minutes)
    ) as gs;

  if v_start_times is null or array_length(v_start_times, 1) is null then
    raise exception 'RANGE_TOO_SHORT: no start time fits duration_minutes inside [range_start, range_end)';
  end if;

  v_num_starts := array_length(v_start_times, 1);
  -- ADR-0045's defensive cap on start times generated for a single day.
  if v_num_starts > 96 then
    raise exception 'TOO_MANY_START_TIMES: % start times requested for one day, max 96', v_num_starts;
  end if;

  v_total := array_length(v_weekdays_distinct, 1) * v_num_starts;
  -- ADR-0045's defensive cap on ScheduleRules created by a single call
  -- (7 weekdays x 96 starts/day).
  if v_total > 672 then
    raise exception 'TOO_MANY_SCHEDULE_RULES: % rules requested (% weekdays x % start times), max 672 per call',
      v_total, array_length(v_weekdays_distinct, 1), v_num_starts;
  end if;

  select array_agg(group_id) into v_group_ids
    from public.create_schedule_rules_batch(
      v_service.organization_id, v_service.id, p_resource_id,
      v_weekdays_distinct, v_start_times, p_duration_minutes, p_capacity
    );

  if v_group_ids is null or array_length(v_group_ids, 1) is null then
    raise exception 'NO_RULES_CREATED';
  end if;

  return v_group_ids[1];
end;
$BODY$;

revoke execute on function public.create_schedule_rule_span(uuid, uuid, int[], time, time, int, int, int) from public, anon;
grant execute on function public.create_schedule_rule_span(uuid, uuid, int[], time, time, int, int, int) to authenticated;
