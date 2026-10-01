-- Phase 46: fix schedule_rule_groups() for spans with multiple start times
-- Ref: docs/decisions.md ADR-0022 (original grouping), ADR-0045 (span
-- generator), ADR-0050 (this fix).
--
-- Bug: schedule_rule_groups() (Phase 16, ADR-0022) was written when a
-- group_id could only ever contain rules that share ONE local_start_time
-- (create_schedule_rule_group() iterated weekdays[] against a single
-- p_local_start_time -- one row per weekday, always a distinct weekday per
-- row). Its aggregate collapsed the non-grouped columns with min(...),
-- which was lossless for that shape: min(sr.local_start_time) is trivially
-- correct when every row in the group already has the same value.
--
-- create_schedule_rule_span() (Phase 43, ADR-0045) breaks that assumption
-- on purpose: one group_id can now hold weekdays[] x local_start_times[],
-- so the *same* weekday appears in several rows with *different*
-- local_start_time values (e.g. one weekday, 09:00/09:30/10:00/10:30 under
-- one group). min(sr.local_start_time) silently collapses all of them to
-- the earliest one, and the frontend's positional zip of
-- weekdays[index]/ruleIds[index] has no way to recover which rule actually
-- starts at which time -- every row in that group renders with the same
-- (wrong) label. See docs/decisions.md ADR-0050 for the shape decided here
-- and the bug report that found this (frontend-engineer, while building
-- the span UI for ADR-0045).
--
-- Fix: return one `items` jsonb array per group, each element the exact
-- (ruleId, weekday, localStartTime) triple for one ScheduleRule row --
-- never collapsed, never positionally zipped against a second array.
-- `duration_minutes`/`capacity`/`resource_id`/`resource_name` keep using
-- min()/first-value collapsing: those ARE always constant within one
-- group_id by construction, in every insert path that exists --
-- create_schedule_rules_batch() (Phase 43) takes a single
-- p_duration_minutes/p_capacity/p_resource_id per call and stamps every row
-- of the batch with it under one freshly-generated group_id; the ad-hoc
-- single-rule insert (createScheduleRule, frontend/app/actions/schedule.ts)
-- never sets a group_id explicitly, so it always gets its own fresh
-- one-row group via the column default. No insert path appends a row to an
-- *existing* group_id with a different resource/duration/capacity -- only
-- weekday and local_start_time ever vary within a group, which is exactly
-- what `items` now expresses per-row instead of collapsing.

drop function if exists public.schedule_rule_groups(uuid);

create function public.schedule_rule_groups(p_service_id uuid)
returns table (
  group_id uuid,
  resource_id uuid,
  resource_name text,
  duration_minutes int,
  capacity int,
  items jsonb
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
    min(sr.duration_minutes),
    min(sr.capacity),
    jsonb_agg(
      jsonb_build_object(
        'ruleId', sr.id,
        'weekday', sr.weekday,
        'localStartTime', sr.local_start_time
      )
      order by sr.weekday, sr.local_start_time, sr.id
    )
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
