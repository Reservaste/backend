-- Phase 3: ScheduleRule + ScheduleException + SlotOccurrence
-- Ref: docs/decisions.md ADR-0003, ADR-0009, ADR-0010, ADR-0014; docs/domain.md
--
-- No booking yet (Phase 5) -- this is purely about generating the
-- reservable occurrences themselves. Every invariant below that mentions
-- "protect occurrences with bookings" is a TODO for Phase 5/6's
-- booking-engine work, not something enforced yet, because there is
-- nothing to protect: no Booking table exists until Phase 5.
--
-- Scope decision (Orchestrator): a ScheduleRule references exactly one
-- Resource, not an N:M set. domain.md's Service<->Resource N:M
-- (service_resources, Phase 2) is about which Resources a Service *can*
-- use in general; a ScheduleRule is a specific recurring booking slot,
-- and nothing today needs a single occurrence to occupy more than one
-- Resource at once. Extending to multiple resources per rule later is a
-- schema addition, not a breaking change.

-- ============================================================
-- schedule_rules
-- ============================================================

create type public.schedule_rule_cancellation_reason as enum ('DISCONTINUED_BY_ORGANIZATION');

create table public.schedule_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  resource_id uuid not null references public.resources (id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6), -- 0 = Sunday, matches JS Date#getDay()
  -- ADR-0014: wall-clock local time, converted to timestamptz at
  -- generation time via AT TIME ZONE -- never store an offset here.
  local_start_time time not null,
  duration_minutes int not null check (duration_minutes > 0),
  capacity int not null check (capacity > 0),
  valid_from date not null default current_date,
  valid_until date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.schedule_rule_cancellation_reason,
  constraint schedule_rules_valid_range check (valid_until is null or valid_until >= valid_from)
);

comment on table public.schedule_rules is
  'A recurring time slot: weekday + local time + duration + capacity for one Service/Resource pair. Ref: docs/domain.md.';

create trigger schedule_rules_set_updated_at
  before update on public.schedule_rules
  for each row execute function public.set_updated_at();

create index schedule_rules_organization_idx on public.schedule_rules (organization_id);
create index schedule_rules_service_idx on public.schedule_rules (service_id);

-- Same cross-tenant pairing guard as service_resources/service_entitlements
-- in the Phase 2 migration.
create or replace function public.check_schedule_rule_same_org()
returns trigger
language plpgsql
as $$
declare
  v_service_org uuid;
  v_resource_org uuid;
begin
  select organization_id into v_service_org from public.services where id = new.service_id;
  select organization_id into v_resource_org from public.resources where id = new.resource_id;

  if v_service_org is null or v_resource_org is null
     or v_service_org <> new.organization_id or v_resource_org <> new.organization_id then
    raise exception 'ScheduleRule organization_id must match its Service and Resource';
  end if;

  return new;
end;
$$;

create trigger schedule_rules_same_org
  before insert or update on public.schedule_rules
  for each row execute function public.check_schedule_rule_same_org();

-- ============================================================
-- schedule_exceptions
-- ============================================================

create type public.schedule_exception_type as enum ('CANCELLED', 'MODIFIED');

create table public.schedule_exceptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  schedule_rule_id uuid not null references public.schedule_rules (id) on delete cascade,
  exception_date date not null,
  exception_type public.schedule_exception_type not null,
  -- Only used when exception_type = 'MODIFIED'; null means "keep the rule's default".
  modified_local_start_time time,
  modified_duration_minutes int check (modified_duration_minutes is null or modified_duration_minutes > 0),
  modified_capacity int check (modified_capacity is null or modified_capacity > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  unique (schedule_rule_id, exception_date)
);

comment on table public.schedule_exceptions is
  'A one-off deviation from a ScheduleRule for a specific date: cancel that occurrence, or modify its time/duration/capacity. Ref: docs/domain.md.';

create trigger schedule_exceptions_set_updated_at
  before update on public.schedule_exceptions
  for each row execute function public.set_updated_at();

create index schedule_exceptions_rule_idx on public.schedule_exceptions (schedule_rule_id);

-- ============================================================
-- slot_occurrences (ADR-0003: materialized, ADR-0009: rolling window)
-- ============================================================

create type public.slot_occurrence_status as enum ('ACTIVE', 'BLOCKED', 'CANCELLED');
create type public.slot_occurrence_cancellation_reason as enum ('SLOT_CANCELLED', 'RULE_DISCONTINUED');

create table public.slot_occurrences (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  schedule_rule_id uuid not null references public.schedule_rules (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  resource_id uuid not null references public.resources (id) on delete cascade,
  -- ADR-0014: timestamptz, always computed via AT TIME ZONE at generation
  -- time -- never a cached offset.
  start_at timestamptz not null,
  end_at timestamptz not null,
  -- Traceability only (ADR-0014) -- the instant above is already correct
  -- UTC regardless of this column; this records which zone was in effect
  -- when the row was generated, in case the Organization's timezone
  -- setting changes later.
  generated_timezone text not null,
  capacity int not null check (capacity > 0),
  status public.slot_occurrence_status not null default 'ACTIVE',
  schedule_exception_id uuid references public.schedule_exceptions (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- No created_by: generated by the rolling-window function/job, not a human action.
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.slot_occurrence_cancellation_reason,
  -- Idempotency for the generation function (ADR-0009): re-running it
  -- (daily cron, lazy fallback, concurrent trigger) must never duplicate
  -- an occurrence for the same rule + instant.
  unique (schedule_rule_id, start_at)
);

comment on table public.slot_occurrences is
  'A concrete, reservable occurrence in time. Materialized with a rolling horizon (ADR-0003/ADR-0009). Ref: docs/domain.md.';

create trigger slot_occurrences_set_updated_at
  before update on public.slot_occurrences
  for each row execute function public.set_updated_at();

create index slot_occurrences_organization_idx on public.slot_occurrences (organization_id);
create index slot_occurrences_service_start_idx on public.slot_occurrences (service_id, start_at);
create index slot_occurrences_resource_start_idx on public.slot_occurrences (resource_id, start_at);
create index slot_occurrences_rule_idx on public.slot_occurrences (schedule_rule_id);

-- ============================================================
-- Generation (ADR-0009: pg_cron primary + sync-on-rule-change, both
-- calling this same idempotent function; ADR-0014: AT TIME ZONE conversion)
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

  -- Advance to the first matching weekday on or after v_day.
  v_day := v_day + ((v_rule.weekday - extract(dow from v_day)::int + 7) % 7);

  while v_day <= v_horizon_end loop
    select * into v_exception
      from public.schedule_exceptions
      where schedule_rule_id = p_schedule_rule_id and exception_date = v_day;

    if found and v_exception.exception_type = 'CANCELLED' then
      -- Deliberately generate nothing for this date -- there is no "skipped"
      -- SlotOccurrence row for a date that was never going to happen. This
      -- is different from Booking.NOT_GENERATED (ADR-0010), which marks a
      -- Booking that failed to be created for an occurrence that DID exist.
      v_day := v_day + 7;
      continue;
    end if;

    v_local_start_time := coalesce(
      (case when found then v_exception.modified_local_start_time end),
      v_rule.local_start_time
    );
    v_duration_minutes := coalesce(
      (case when found then v_exception.modified_duration_minutes end),
      v_rule.duration_minutes
    );
    v_capacity := coalesce(
      (case when found then v_exception.modified_capacity end),
      v_rule.capacity
    );

    -- The AT TIME ZONE conversion: combine the local date + local time as a
    -- naive timestamp, then interpret it in the Organization's IANA zone.
    -- Recomputed per date, per run -- this is what makes DST transitions
    -- (in orgs outside Uruguay) resolve correctly with no special-casing.
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
    on conflict (schedule_rule_id, start_at) do nothing;

    v_day := v_day + 7;
  end loop;
end;
$$;

create or replace function public.generate_all_slot_occurrences(p_horizon_days int default 90)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule_id uuid;
  v_lock_acquired boolean;
begin
  -- ADR-0009: guard against overlapping runs (daily cron + lazy fallback +
  -- concurrent rule edits) racing each other. A fixed arbitrary key scoped
  -- to this function; the per-row ON CONFLICT above is the real duplicate
  -- guard, this just avoids wasted concurrent work.
  select pg_try_advisory_xact_lock(hashtext('generate_all_slot_occurrences')) into v_lock_acquired;
  if not v_lock_acquired then
    return;
  end if;

  -- Batched per rule (not one giant cross-organization insert), so one
  -- slow/locked rule cannot block generation for every other tenant.
  for v_rule_id in select id from public.schedule_rules where is_active loop
    perform public.generate_slot_occurrences_for_rule(v_rule_id, p_horizon_days);
  end loop;
end;
$$;

-- Materialize a rule's horizon immediately when it's created, per ADR-0009.
create or replace function public.trigger_generate_on_schedule_rule_insert()
returns trigger
language plpgsql
as $$
begin
  perform public.generate_slot_occurrences_for_rule(new.id);
  return new;
end;
$$;

create trigger schedule_rules_generate_on_insert
  after insert on public.schedule_rules
  for each row execute function public.trigger_generate_on_schedule_rule_insert();

-- Editing a rule's schedule-affecting fields regenerates its future
-- occurrences. Safe to delete-and-regenerate unconditionally today because
-- no Booking exists yet (Phase 5) to protect -- Phase 5/6's booking-engine
-- work must revisit this to skip/handle occurrences that already have
-- bookings (see ADR-0010's "pinned occurrence" rule) instead of deleting
-- them.
create or replace function public.trigger_regenerate_on_schedule_rule_update()
returns trigger
language plpgsql
as $$
begin
  if (new.weekday, new.local_start_time, new.duration_minutes, new.capacity, new.resource_id, new.valid_until)
     is distinct from
     (old.weekday, old.local_start_time, old.duration_minutes, old.capacity, old.resource_id, old.valid_until)
  then
    delete from public.slot_occurrences
      where schedule_rule_id = new.id and start_at >= now();
    perform public.generate_slot_occurrences_for_rule(new.id);
  end if;
  return new;
end;
$$;

create trigger schedule_rules_regenerate_on_update
  after update on public.schedule_rules
  for each row execute function public.trigger_regenerate_on_schedule_rule_update();

-- pg_cron: extend every organization's rolling window daily. Requires the
-- pg_cron extension, available on Supabase (local and hosted) without
-- extra setup.
create extension if not exists pg_cron with schema pg_catalog;

select
  cron.schedule(
    'extend-slot-occurrence-window',
    '0 3 * * *',
    $$ select public.generate_all_slot_occurrences(90); $$
  )
where not exists (
  select 1 from cron.job where jobname = 'extend-slot-occurrence-window'
);

-- Reconcile an already-materialized SlotOccurrence when a
-- ScheduleException is created/edited for a date that was generated
-- before the exception existed. Without this, an exception only affects
-- generation of dates that haven't been materialized yet -- silently
-- doing nothing for the common case of "cancel next Monday's class" when
-- next Monday's occurrence already exists (it will, almost always,
-- because generation runs on rule creation and daily via cron).
-- SECURITY DEFINER so it can write status='CANCELLED', which
-- slot_occurrences_toggle_active_blocked below deliberately blocks for
-- direct client writes.
create or replace function public.apply_schedule_exception_to_existing_occurrence()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_occurrence public.slot_occurrences;
  v_new_start_at timestamptz;
  v_duration_minutes int;
  v_capacity int;
begin
  select * into v_rule from public.schedule_rules where id = new.schedule_rule_id;
  select * into v_org from public.organizations where id = v_rule.organization_id;

  select * into v_occurrence
    from public.slot_occurrences
    where schedule_rule_id = new.schedule_rule_id
      and (start_at at time zone v_org.timezone)::date = new.exception_date
      and status <> 'CANCELLED'
    limit 1;

  if not found then
    -- Not materialized yet (or already cancelled) -- generation will
    -- apply this exception itself when it reaches that date.
    return new;
  end if;

  if new.exception_type = 'CANCELLED' then
    update public.slot_occurrences
      set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
          cancellation_reason = 'SLOT_CANCELLED', schedule_exception_id = new.id
      where id = v_occurrence.id;
  else -- MODIFIED
    v_duration_minutes := coalesce(new.modified_duration_minutes, v_rule.duration_minutes);
    v_capacity := coalesce(new.modified_capacity, v_rule.capacity);
    v_new_start_at := (new.exception_date + coalesce(new.modified_local_start_time, v_rule.local_start_time))
      at time zone v_org.timezone;

    update public.slot_occurrences
      set start_at = v_new_start_at,
          end_at = v_new_start_at + make_interval(mins => v_duration_minutes),
          capacity = v_capacity,
          schedule_exception_id = new.id
      where id = v_occurrence.id;
  end if;

  return new;
end;
$$;

create trigger schedule_exceptions_apply_to_existing
  after insert or update on public.schedule_exceptions
  for each row execute function public.apply_schedule_exception_to_existing_occurrence();

-- ============================================================
-- cancel_slot_occurrence RPC
-- ============================================================
-- A single occurrence being cancelled by STAFF/OWNER (ADR-0010,
-- cancellation_reason = SLOT_CANCELLED -- distinct from RULE_DISCONTINUED,
-- which is the whole-rule cascade below). Phase 5/6's booking-engine must
-- extend this to also cancel any Booking rows on this occurrence when
-- that table exists -- there is nothing to cascade to yet.

create or replace function public.cancel_slot_occurrence(
  p_slot_occurrence_id uuid,
  p_reason public.slot_occurrence_cancellation_reason default 'SLOT_CANCELLED'
)
returns public.slot_occurrences
language plpgsql
security definer
set search_path = public
as $$
declare
  v_occurrence public.slot_occurrences;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found then
    raise exception 'SLOT_OCCURRENCE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_occurrence.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_slot_occurrence_id
    returning * into v_occurrence;

  return v_occurrence;
end;
$$;

grant execute on function public.cancel_slot_occurrence(uuid, public.slot_occurrence_cancellation_reason) to authenticated;

-- Discontinuing a whole ScheduleRule cascades to its future occurrences.
-- Ref: domain.md's cascade invariant (extended in ADR-0010 to also cover
-- any RecurringBooking once that exists -- Phase 6).
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
end;
$$;

grant execute on function public.discontinue_schedule_rule(uuid) to authenticated;

-- ============================================================
-- Row Level Security
-- ============================================================
-- No public/anonymous policy yet -- same reasoning as Phase 1/2 (Phase 4
-- adds a dedicated public view for the calendar).

alter table public.schedule_rules enable row level security;
alter table public.schedule_exceptions enable row level security;
alter table public.slot_occurrences enable row level security;

create policy schedule_rules_select_members
  on public.schedule_rules for select
  using (public.is_organization_member(organization_id));

create policy schedule_rules_write_staff
  on public.schedule_rules for all
  using (public.is_organization_member(organization_id));

create policy schedule_exceptions_select_members
  on public.schedule_exceptions for select
  using (public.is_organization_member(organization_id));

create policy schedule_exceptions_write_staff
  on public.schedule_exceptions for all
  using (public.is_organization_member(organization_id));

create policy slot_occurrences_select_members
  on public.slot_occurrences for select
  using (public.is_organization_member(organization_id));

-- STAFF/OWNER may toggle ACTIVE <-> BLOCKED directly (reversible,
-- low-risk), but can never write status = 'CANCELLED' through this path --
-- same lesson as ADR-0002's organizations INSERT fix: cancellation must
-- always go through cancel_slot_occurrence() so cancelled_at/by/reason are
-- set atomically together, never as a partial direct update.
create policy slot_occurrences_toggle_active_blocked
  on public.slot_occurrences for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id) and status <> 'CANCELLED');
