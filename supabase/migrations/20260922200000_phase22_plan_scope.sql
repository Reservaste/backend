-- Phase 22: configurable ServicePlan scope -- one, several, or all services
-- Ref: docs/decisions.md ADR-0029 (five Orchestrator resolutions + the new
-- sequencing note), docs/proposals/adr-0029-plan-scope.md.
--
-- This migration retrofits two tables that already carry real rows from the
-- first paying client: service_plans (Phase 17) and makeup_credits
-- (Phase 20). Every backfill below is written to preserve the exact
-- meaning of each existing row -- see the section headers for the
-- reasoning specific to each one. Nothing here is run against production
-- by this agent; it is written to be verified against a copy of the real
-- data first (ADR-0029, "restricción de secuenciación").
--
-- Two tables replace service_plans.service_id (1:N, dropped):
--   * service_plan_services (N:M) -- "this plan covers exactly these
--     services", closed and deliberate.
--   * service_plans.applies_to_all_services (flag) -- "this plan covers
--     every service the organization has, including ones created
--     tomorrow", resolved live against public.services, never
--     materialized (materializing it would need a trigger on every new
--     service, which collides with the immutability rule below).
--
-- quota_scope (PER_SERVICE | SHARED_ACROSS_SERVICES) generalizes "series in
-- force" from one service to a set, and is required exactly when
-- plan_kind = WEEKLY_QUOTA (proposal S3).
--
-- payments.service_id becomes nullable (populated only when the plan
-- covers exactly one service); payment_service_coverage is the new,
-- single source of truth for "does this payment cover that service in
-- that period", replacing the EXCLUDE that used to live directly on
-- payments (proposal S4.2: two separate EXCLUDEs on the same fact cannot
-- see each other).

-- ============================================================
-- 1. service_plan_services + applies_to_all_services + quota_scope
-- ============================================================

create table public.service_plan_services (
  service_plan_id uuid not null references public.service_plans (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  primary key (service_plan_id, service_id)
);

comment on table public.service_plan_services is
  'ADR-0029: the explicit, closed selection of services a plan covers. Never grows on its own -- the opposite of applies_to_all_services. Immutable once the plan has a non-VOID payment (service_plan_services_immutable).';

create index service_plan_services_service_idx on public.service_plan_services (service_id);

alter table public.service_plans
  add column applies_to_all_services boolean not null default false;

comment on column public.service_plans.applies_to_all_services is
  'ADR-0029: resolved live against services.organization_id/is_active every time it is read, never materialized -- a pass sold as "all services" has to start covering a service created after the sale. The boolean itself is immutable once the plan has payments; what it resolves to is not.';

create type public.plan_quota_scope as enum ('PER_SERVICE', 'SHARED_ACROSS_SERVICES');

comment on type public.plan_quota_scope is
  'ADR-0029: only meaningful for WEEKLY_QUOTA. PER_SERVICE -- the quota applies independently to each covered service (todays behaviour, generalized). SHARED_ACROSS_SERVICES -- one pool of N series total, spent on any combination of the covered services.';

alter table public.service_plans
  add column quota_scope public.plan_quota_scope;

-- Backfill before the CHECK below: every WEEKLY_QUOTA plan that exists
-- today behaves exactly like PER_SERVICE already did (it only ever had one
-- service to be "per"), so this assigns a value with no behaviour change,
-- not a business decision.
update public.service_plans set quota_scope = 'PER_SERVICE' where plan_kind = 'WEEKLY_QUOTA';

alter table public.service_plans
  add constraint service_plans_quota_scope_matches_kind check (
    (plan_kind = 'WEEKLY_QUOTA' and quota_scope is not null)
    or (plan_kind <> 'WEEKLY_QUOTA' and quota_scope is null)
  );

-- Cross-table org check for the join table (mirrors check_service_plan_same_org).
create or replace function public.check_service_plan_service_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_plan_org uuid;
  v_service_org uuid;
begin
  select organization_id into v_plan_org from public.service_plans where id = new.service_plan_id;
  select organization_id into v_service_org from public.services where id = new.service_id;

  if v_plan_org is null or v_service_org is null or v_plan_org <> v_service_org then
    raise exception 'ServicePlanServices organization_id must match its ServicePlan and Service';
  end if;

  return new;
end;
$BODY$;

create trigger service_plan_services_same_org
  before insert or update on public.service_plan_services
  for each row execute function public.check_service_plan_service_same_org();

-- Deferred cross-table coherence (proposal S1): a plan is either
-- "explicit selection" XOR "all services", and an explicit-selection plan
-- always covers at least one service. Deferred to end-of-statement/
-- transaction because the two tables are written by two separate INSERTs
-- even inside the same RPC (see create_service_plan() below) -- a plain
-- (non-deferred) trigger would reject the intermediate state between
-- those two statements.
create or replace function public.validate_service_plan_scope()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_plan_id uuid;
  v_applies_all boolean;
  v_has_rows boolean;
begin
  if tg_table_name = 'service_plans' then
    v_plan_id := new.id;
  else
    v_plan_id := coalesce(new.service_plan_id, old.service_plan_id);
  end if;

  select applies_to_all_services into v_applies_all
    from public.service_plans where id = v_plan_id;
  if v_applies_all is null then
    -- The plan itself is gone (cascaded delete): nothing left to validate.
    return null;
  end if;

  select exists (
    select 1 from public.service_plan_services where service_plan_id = v_plan_id
  ) into v_has_rows;

  if v_applies_all and v_has_rows then
    raise exception 'SERVICE_PLAN_SCOPE_EXCLUSIVE';
  end if;
  if not v_applies_all and not v_has_rows then
    raise exception 'SERVICE_PLAN_SCOPE_EMPTY';
  end if;

  return null;
end;
$BODY$;

create constraint trigger service_plans_scope_valid
  after insert or update of applies_to_all_services on public.service_plans
  deferrable initially deferred
  for each row execute function public.validate_service_plan_scope();

create constraint trigger service_plan_services_scope_valid
  after insert or delete or update on public.service_plan_services
  deferrable initially deferred
  for each row execute function public.validate_service_plan_scope();

-- Immutable once the plan has a real payment (same criterion as
-- check_service_plan_terms_immutable): adding/removing a covered service
-- from a plan that customers already paid for would rewrite retroactively
-- what those payments bought.
create or replace function public.check_service_plan_services_immutable()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_plan_id uuid := coalesce(new.service_plan_id, old.service_plan_id);
begin
  if exists (
    select 1 from public.payments p where p.service_plan_id = v_plan_id and p.status <> 'VOID'
  ) then
    raise exception 'SERVICE_PLAN_TERMS_IMMUTABLE';
  end if;

  return coalesce(new, old);
end;
$BODY$;

create trigger service_plan_services_immutable
  before insert or delete or update on public.service_plan_services
  for each row execute function public.check_service_plan_services_immutable();

-- ============================================================
-- 2. Helper: "what does this plan cover, right now" -- one definition
-- ============================================================
-- SECURITY DEFINER and revoked from every request role on purpose: it
-- resolves applies_to_all_services against ALL of an organization's
-- services regardless of who is asking, which is exactly the disclosure
-- ADR-0026 resolution 7 closed for inactive plans. Every internal caller
-- below that needs it is itself SECURITY DEFINER (owner-to-owner calls
-- need no grant, same pattern as issue_makeup_credit() calling
-- resolve_makeup_credits_policy()). It must never become directly
-- reachable from PostgREST.

create or replace function public.service_plan_covered_service_ids(p_service_plan_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $BODY$
  select service_id from public.service_plan_services where service_plan_id = p_service_plan_id
  union
  select s.id
  from public.service_plans sp
  join public.services s on s.organization_id = sp.organization_id and s.is_active
  where sp.id = p_service_plan_id and sp.applies_to_all_services;
$BODY$;

comment on function public.service_plan_covered_service_ids(uuid) is
  'ADR-0029: the single definition of "what this plan covers today". Every reader (coverage chain, quota, makeup credits, admin UI) goes through this instead of repeating the union. Revoked from every request role -- see comment above.';

revoke execute on function public.service_plan_covered_service_ids(uuid)
  from public, anon, authenticated, service_role;

-- Resolves the service set a quota is measured against: the whole covered
-- set under SHARED_ACROSS_SERVICES, just the one service under
-- PER_SERVICE (identical to the pre-ADR-0029 behaviour, generalized to a
-- one-element array). One function, two ways to call it -- same pattern
-- evaluate_payment_coverage() already uses for series context.
create or replace function public.service_plan_quota_service_ids(p_service_plan_id uuid, p_service_id uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $BODY$
  select case
    when sp.quota_scope = 'SHARED_ACROSS_SERVICES'
      then array(select public.service_plan_covered_service_ids(sp.id))
    else array[p_service_id]
  end
  from public.service_plans sp
  where sp.id = p_service_plan_id;
$BODY$;

revoke execute on function public.service_plan_quota_service_ids(uuid, uuid)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 3. Backfill service_plan_services, then drop service_plans.service_id
-- ============================================================
-- One row per existing plan, exactly the service it already had. No plan
-- changes scope on deploy day -- this is the historical record, not a
-- reinterpretation (proposal S2).

insert into public.service_plan_services (service_plan_id, service_id)
select id, service_id from public.service_plans;

-- Triggers that read the column being dropped have to go (or be rewritten)
-- before the column itself does; relying on CASCADE would only catch the
-- indexes below, not these plpgsql bodies.
drop trigger if exists service_plans_same_org on public.service_plans;
drop function if exists public.check_service_plan_same_org();

drop trigger if exists service_plans_require_paid_service on public.service_plans;
drop trigger if exists services_payment_required_vs_plans on public.services;

drop index if exists public.service_plans_service_idx;
drop index if exists public.service_plans_active_name_idx;
drop index if exists public.service_plans_one_active_drop_in_idx;
-- Confirmed dead by the proposal (S4.4) and the Orchestrator (resolution
-- 1): it only ever anchored fill_payment_service_plan()'s non-deterministic
-- "the" UNLIMITED plan, and Phase H's payments UI has sent service_plan_id
-- explicitly since before this migration. Two overlapping UNLIMITED plans
-- are now legitimate catalog, not a conflict.
drop index if exists public.service_plans_one_active_unlimited_idx;

alter table public.service_plans drop column service_id;

-- Two active plans with the same name was a data-entry guard scoped to
-- "one service" before this ADR; a plan no longer has exactly one, so the
-- natural generalization is "within the organization" instead of dropping
-- the guard outright. Same index name on purpose: the frontend's error
-- mapping already matches on it and needs no change.
create unique index service_plans_active_name_idx
  on public.service_plans (organization_id, lower(name))
  where is_active;

-- DROP_IN keeps exactly the old guarantee (proposal S1.1: multi-service
-- DROP_IN stays out of scope on purpose), just re-anchored on the join
-- since there is no longer a service_id column to build a partial unique
-- index on. A partial unique index cannot express a condition that
-- crosses tables, so this is a trigger instead -- same reasoning as
-- validate_service_plan_scope() above.
create or replace function public.check_one_active_drop_in_per_service()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if exists (
    select 1
    from public.service_plan_services sps
    join public.service_plans sp on sp.id = sps.service_plan_id
    where sp.plan_kind = 'DROP_IN' and sp.is_active
    group by sps.service_id
    having count(distinct sp.id) > 1
  ) then
    raise exception 'SERVICE_PLAN_DROP_IN_ALREADY_EXISTS';
  end if;

  return new;
end;
$BODY$;

comment on function public.check_one_active_drop_in_per_service() is
  'ADR-0029 S1.1: one active DROP_IN per service, re-anchored from service_plans_one_active_drop_in_idx onto the join table. A partial unique index cannot express "count distinct plans per service", so this scans -- cheap, DROP_IN plans are rare.';

create trigger service_plan_services_one_active_drop_in
  after insert or update on public.service_plan_services
  for each row execute function public.check_one_active_drop_in_per_service();

create trigger service_plans_one_active_drop_in
  after update of plan_kind, is_active on public.service_plans
  for each row execute function public.check_one_active_drop_in_per_service();

-- SERVICE_NOT_PAYMENT_REQUIRED, generalized to the covered set (ADR-0024
-- resolution 6, extended). Runs per linked row on service_plan_services
-- (which is where the plan can be validated at *creation* time, since
-- create_service_plan() below inserts the plan row before its
-- service_plan_services rows in the same transaction) and again on
-- service_plans for the case that reactivates/changes kind on an
-- already-linked plan. applies_to_all_services is checked against the
-- organization's *current* active services -- a service created later
-- without payment_required is a gap this cannot see at write time, same
-- as any other "resolved live" consequence of that flag (S6).
create or replace function public.assert_service_plan_service_payment_required(p_service_plan_id uuid, p_service_id uuid)
returns void
language plpgsql
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_payment_required boolean;
begin
  select * into v_plan from public.service_plans where id = p_service_plan_id;
  if not found or v_plan.plan_kind <> 'WEEKLY_QUOTA' or not v_plan.is_active then
    return;
  end if;

  select payment_required into v_payment_required from public.services where id = p_service_id;
  if not coalesce(v_payment_required, false) then
    raise exception 'SERVICE_NOT_PAYMENT_REQUIRED';
  end if;
end;
$BODY$;

create or replace function public.check_service_plan_services_requires_paid_service()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  perform public.assert_service_plan_service_payment_required(new.service_plan_id, new.service_id);
  return new;
end;
$BODY$;

create trigger service_plan_services_require_paid_service
  before insert or update on public.service_plan_services
  for each row execute function public.check_service_plan_services_requires_paid_service();

create or replace function public.check_service_plan_requires_paid_service()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_service_id uuid;
begin
  if new.plan_kind = 'WEEKLY_QUOTA' and new.is_active then
    for v_service_id in
      select service_id from public.service_plan_services where service_plan_id = new.id
    loop
      perform public.assert_service_plan_service_payment_required(new.id, v_service_id);
    end loop;

    if new.applies_to_all_services then
      for v_service_id in
        select id from public.services where organization_id = new.organization_id and is_active
      loop
        perform public.assert_service_plan_service_payment_required(new.id, v_service_id);
      end loop;
    end if;
  end if;

  return new;
end;
$BODY$;

create trigger service_plans_require_paid_service
  before insert or update on public.service_plans
  for each row execute function public.check_service_plan_requires_paid_service();

-- The mirror rule (ADR-0024 resolution 6, from the service side): turning
-- payment_required off while an active WEEKLY_QUOTA plan still covers this
-- service (explicitly, or through applies_to_all_services) leaves that
-- plan pretending to limit something nobody has to pay for.
create or replace function public.check_service_payment_required_vs_plans()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if exists (
    select 1 from public.service_plans sp
    join public.service_plan_services sps on sps.service_plan_id = sp.id
    where sps.service_id = new.id and sp.is_active and sp.plan_kind = 'WEEKLY_QUOTA'
  ) or exists (
    select 1 from public.service_plans sp
    where sp.organization_id = new.organization_id
      and sp.applies_to_all_services
      and sp.is_active
      and sp.plan_kind = 'WEEKLY_QUOTA'
  ) then
    raise exception 'SERVICE_HAS_ACTIVE_QUOTA_PLANS';
  end if;

  return new;
end;
$BODY$;

create trigger services_payment_required_vs_plans
  before update on public.services
  for each row
  when (old.payment_required and not new.payment_required)
  execute function public.check_service_payment_required_vs_plans();

-- Terms immutable with payments (ADR-0024 resolution 5), extended to the
-- two new columns -- same argument as plan_kind/weekly_quota:
-- evaluate_payment_coverage() reads them live from the plan, never from a
-- frozen copy per payment.
create or replace function public.check_service_plan_terms_immutable()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if (new.plan_kind is distinct from old.plan_kind
      or new.weekly_quota is distinct from old.weekly_quota
      or new.quota_scope is distinct from old.quota_scope
      or new.applies_to_all_services is distinct from old.applies_to_all_services)
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
-- 4. create_service_plan(): the RPC a scoped plan now requires
-- ============================================================
-- service_plans and service_plan_services are written in two separate
-- INSERTs even for a brand-new plan, and validate_service_plan_scope() is
-- deferred to end-of-transaction, not end-of-statement -- so a plain
-- PostgREST insert into service_plans (its own transaction) can only ever
-- succeed for applies_to_all_services = true (nothing else needs
-- inserting). A plan with an explicit service list needs both inserts in
-- one transaction, same reasoning ADR-0004 already established for
-- book_slot(): supabase-js talks to PostgREST, and two separate `.from()`
-- calls are two separate transactions. Authorization mirrors
-- service_plans_insert_staff exactly (is_organization_member, not
-- OWNER-only -- OWNER-only is a product policy the frontend applies, per
-- the existing comment in app/actions/service-plans.ts).
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
  p_quota_scope public.plan_quota_scope default null
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
    billing_type, billing_cycle, sort_order, applies_to_all_services, quota_scope, created_by
  ) values (
    p_organization_id, p_name, p_description, p_price, p_plan_kind, p_weekly_quota,
    p_billing_type, p_billing_cycle, p_sort_order, p_applies_to_all_services, p_quota_scope, auth.uid()
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
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope
) is
  'ADR-0029: the only way to create a plan with an explicit service selection -- service_plans and service_plan_services are two INSERTs that need one transaction for validate_service_plan_scope() (deferred) to see a consistent end state. A plain PostgREST insert into service_plans still works for applies_to_all_services = true, which needs no second table.';

revoke execute on function public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope
) from public, anon;
grant execute on function public.create_service_plan(
  uuid, text, text, numeric, public.service_plan_kind, int, public.billing_type,
  public.billing_cycle, int, boolean, uuid[], public.plan_quota_scope
) to authenticated;

-- ============================================================
-- 5. RLS: service_plan_services, and the ADR-0026 resolution-7 acotamiento
-- ============================================================
-- ADR-0026 resolution 7 deferred this exact change to "the same migration
-- that implements ADR-0029" instead of touching service_plans twice.

drop policy if exists service_plans_select_public on public.service_plans;

create policy service_plans_select_public
  on public.service_plans for select
  using (is_active or public.is_organization_member(organization_id));

alter table public.service_plan_services enable row level security;

create policy service_plan_services_select_public
  on public.service_plan_services for select
  using (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id
      and (sp.is_active or public.is_organization_member(sp.organization_id))
  ));

create policy service_plan_services_write_staff
  on public.service_plan_services for all
  using (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_member(sp.organization_id)
  ));

grant select on public.service_plan_services to anon, authenticated;
grant insert, update, delete on public.service_plan_services to authenticated;

-- ============================================================
-- 6. payments.service_id becomes derived-and-nullable; payment_service_coverage
-- ============================================================
-- payments.service_plan_id (ADR-0024) stays the real anchor. service_id
-- stays populated -- by the same trigger pattern as before, "derived and
-- verified", never client-trusted -- but only when the plan covers
-- exactly one service. When it covers several there is no "the" service
-- for a single column to hold; payment_service_coverage is the complete
-- answer (proposal S4.1).

alter table public.payments alter column service_id drop not null;

comment on column public.payments.service_id is
  'Derived from service_plan_id and verified by trigger, populated only when the plan covers exactly one service (ADR-0029 S4.1). NULL for a multi-service plan payment -- see payment_service_coverage for its full coverage.';

create table public.payment_service_coverage (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete cascade,
  -- Redundant with a join to payments, same ADR-0006 defense-in-depth
  -- reasoning as every other two-layer-RLS table in this schema.
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  -- Mirrored from payments.status by trigger, purely so the EXCLUDE below
  -- can filter on it without a join (EXCLUDE constraints cannot reference
  -- another table).
  status public.payment_status not null,
  period_start date not null,
  period_end date not null
);

comment on table public.payment_service_coverage is
  'ADR-0029: one row per (payment, service it covers), with its own period. The sole anti-double-charge mechanism for period-anchored payments -- replaces the EXCLUDE that used to live directly on payments, which could not see a single-service payment and a multi-service payment collide on the same service (S4.2). DROP_IN (turno suelto) payments never get rows here; they keep payments_one_paid_per_occurrence_idx unchanged.';

create index payment_service_coverage_payment_idx on public.payment_service_coverage (payment_id);
create index payment_service_coverage_lookup_idx
  on public.payment_service_coverage (customer_id, service_id, period_start, period_end);

-- Backfill (production-data-safe): this table is brand new, so without
-- this step every payment made before this migration would have zero
-- rows here -- and resolve_covering_service_plan() below reads coverage
-- exclusively from this table, so every customer who paid before today
-- would look uncovered (PAYMENT_REQUIRED) the moment this migration lands.
-- Every existing period-anchored payment still has its original,
-- untouched service_id at this point in the migration (no multi-service
-- plan can exist yet -- see S11 below for why that also makes the
-- makeup_credits backfill safe), so this is a direct 1:1 copy, not a
-- reconstruction: one coverage row per existing payment, for the one
-- service it already covered.
insert into public.payment_service_coverage (
  payment_id, organization_id, customer_id, service_id, status, period_start, period_end
)
select p.id, p.organization_id, p.customer_id, p.service_id, p.status, p.period_start, p.period_end
from public.payments p
where p.slot_occurrence_id is null;

create extension if not exists btree_gist;

-- Added after the backfill so it validates the copied rows against the
-- new constraint: the old payments_no_overlapping_paid EXCLUDE (identical
-- shape, dropped right below) already guaranteed none of them overlap.
alter table public.payment_service_coverage
  add constraint payment_service_coverage_no_overlap
  exclude using gist (
    customer_id with =,
    service_id with =,
    daterange(period_start, period_end, '[]') with &&
  ) where (status = 'PAID');

alter table public.payments drop constraint if exists payments_no_overlapping_paid;

-- Populates payment_service_coverage for every period-anchored payment
-- (slot_occurrence_id is null), one row per service_plan_covered_service_ids()
-- -- one row even for a single-service plan, so there is exactly one place
-- that ever enforces the overlap rule. SECURITY DEFINER: it calls the
-- revoked service_plan_covered_service_ids() helper, and it has to write
-- into payment_service_coverage, which -- like makeup_credits -- carries
-- no INSERT policy for authenticated on purpose (every write is a
-- consequence of a payments write, never a direct one).
create or replace function public.fill_payment_service_coverage()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_service_id uuid;
begin
  if new.slot_occurrence_id is not null then
    return null;
  end if;

  for v_service_id in select public.service_plan_covered_service_ids(new.service_plan_id) loop
    insert into public.payment_service_coverage (
      payment_id, organization_id, customer_id, service_id, status, period_start, period_end
    ) values (
      new.id, new.organization_id, new.customer_id, v_service_id, new.status, new.period_start, new.period_end
    );
  end loop;

  return null;
end;
$BODY$;

create trigger payments_fill_service_coverage
  after insert on public.payments
  for each row execute function public.fill_payment_service_coverage();

-- Propagates status *and* period changes -- a payment's period_start/
-- period_end are editable admin data entry (e.g. "extend this month's
-- payment to next month" is a plain UPDATE, not a VOID + re-insert), and
-- resolve_covering_service_plan()/the EXCLUDE both read the copy on
-- payment_service_coverage, never payments.period_* directly. Without
-- this, editing a payment's period would leave every already-covered
-- customer reading the stale period until the next full VOID/insert cycle.
create or replace function public.sync_payment_service_coverage_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.status is distinct from old.status
     or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end
  then
    update public.payment_service_coverage
      set status = new.status, period_start = new.period_start, period_end = new.period_end
      where payment_id = new.id;
  end if;
  return null;
end;
$BODY$;

-- Named to sort alphabetically before payments_reconcile_pending (Phase
-- 12): both are AFTER UPDATE triggers on this table, and reconciliation
-- has to see the already-synced coverage period, not the stale one --
-- same "trigger name matters" reasoning Phase 17 already documented for
-- payments_fill_service_plan / payments_plan_consistency.
create trigger payments_coverage_sync_status
  after update of status, period_start, period_end on public.payments
  for each row execute function public.sync_payment_service_coverage_status();

-- check_payment_plan_consistency(), rewritten: the plan no longer has a
-- single service_id to compare against, so (a) payments.service_id is
-- (re)derived here -- non-null only when the plan covers exactly one
-- service -- and (b) a DROP_IN payment's occurrence has to belong to one
-- of the plan's covered services, not "the" one. SECURITY DEFINER for the
-- same reason as fill_payment_service_coverage(): it calls the revoked
-- service_plan_covered_service_ids() helper.
create or replace function public.check_payment_plan_consistency()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_occurrence public.slot_occurrences;
  v_covered_count int;
  v_covered_ids uuid[];
begin
  select * into v_plan from public.service_plans where id = new.service_plan_id;
  if not found then
    raise exception 'PAYMENT_PLAN_NOT_FOUND';
  end if;

  if v_plan.organization_id <> new.organization_id then
    raise exception 'Payment organization_id must match its ServicePlan';
  end if;

  if (v_plan.plan_kind = 'DROP_IN') <> (new.slot_occurrence_id is not null) then
    raise exception 'PAYMENT_PLAN_KIND_REQUIRES_OCCURRENCE';
  end if;

  -- uuid has no default min()/max() aggregate, so the covered set is
  -- collected into an array instead: array_length gives the count, and
  -- element 1 is the only element when there is exactly one.
  select array_agg(covered) into v_covered_ids
    from public.service_plan_covered_service_ids(new.service_plan_id) as covered;
  v_covered_count := coalesce(array_length(v_covered_ids, 1), 0);

  new.service_id := case when v_covered_count = 1 then v_covered_ids[1] else null end;

  if new.slot_occurrence_id is not null then
    select * into v_occurrence from public.slot_occurrences where id = new.slot_occurrence_id;
    if not found
       or v_occurrence.organization_id <> new.organization_id
       or not exists (
         select 1 from public.service_plan_covered_service_ids(new.service_plan_id) as covered
         where covered = v_occurrence.service_id
       )
    then
      raise exception 'Payment slot_occurrence_id must belong to the same Organization and a Service covered by its ServicePlan';
    end if;
  end if;

  return new;
end;
$BODY$;

-- fill_payment_service_plan() (Phase 17): confirmed dead by the proposal
-- (S4.4/resolution 1) and by the Fase H closing note -- the payments form
-- has sent service_plan_id explicitly since before this migration, and
-- service_plan_id has been NOT NULL since Phase 17. Retired outright, not
-- deprecated: a payment insert with no plan now fails at the NOT NULL
-- constraint before any trigger runs, same end result with one less
-- moving part.
drop trigger if exists payments_fill_service_plan on public.payments;
drop function if exists public.fill_payment_service_plan();

-- Its only reason to be reachable by `authenticated` (a SECURITY INVOKER
-- caller needing slot_local_date()) is gone with it.
revoke execute on function public.slot_local_date(uuid) from authenticated;

-- ============================================================
-- 7. evaluate_payment_coverage(): the plan lookup changes source, not shape
-- ============================================================

create or replace function public.resolve_covering_service_plan(
  p_customer_id uuid,
  p_service_id uuid,
  p_local_date date
)
returns public.service_plans
language sql
stable
security definer
set search_path = public
as $BODY$
  select sp.*
  from public.payments p
  join public.payment_service_coverage psc on psc.payment_id = p.id
  join public.service_plans sp on sp.id = p.service_plan_id
  where psc.customer_id = p_customer_id
    and psc.service_id = p_service_id
    and p.status = 'PAID'
    and psc.period_start <= p_local_date
    and psc.period_end >= p_local_date
  order by psc.period_start desc, p.created_at desc
  limit 1;
$BODY$;

comment on function public.resolve_covering_service_plan(uuid, uuid, date) is
  'ADR-0029 S4.3: the period payment in force for (customer, service, date), resolved through payment_service_coverage instead of payments.service_id directly. Resolution 1 of ADR-0024 (one live payment per customer/service) still holds, so there is still at most one candidate.';

revoke execute on function public.resolve_covering_service_plan(uuid, uuid, date)
  from public, anon, authenticated, service_role;

create or replace function public.evaluate_payment_coverage(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid,
  p_recurring_booking_id uuid default null,
  p_prospective_series boolean default false
)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_local_date date;
  v_plan public.service_plans;
  v_position int;
  v_quota_service_ids uuid[];
begin
  select * into v_service from public.services where id = p_service_id;
  if not found then
    return 'SERVICE_INACTIVE';
  end if;

  if not v_service.payment_required then
    return 'OK';
  end if;

  v_local_date := public.slot_local_date(p_slot_occurrence_id);
  if v_local_date is null then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  if exists (
    select 1 from public.payments p
    where p.customer_id = p_customer_id
      and p.slot_occurrence_id = p_slot_occurrence_id
      and p.status = 'PAID'
  ) then
    return 'OK';
  end if;

  -- ADR-0029 S4.3: resolved via payment_service_coverage now, same
  -- "at most one live payment per (customer, service)" guarantee.
  v_plan := public.resolve_covering_service_plan(p_customer_id, p_service_id, v_local_date);

  if v_plan.id is null then
    if not exists (
      select 1 from public.service_plans sp
      where sp.is_active
        and (
          sp.applies_to_all_services
          or exists (
            select 1 from public.service_plan_services sps
            where sps.service_plan_id = sp.id and sps.service_id = p_service_id
          )
        )
    ) then
      return 'SERVICE_HAS_NO_PLAN';
    end if;
    return 'PAYMENT_REQUIRED';
  end if;

  if v_plan.plan_kind = 'UNLIMITED' then
    return 'OK';
  end if;

  if v_plan.plan_kind = 'DROP_IN' then
    return 'PAYMENT_REQUIRED';
  end if;

  -- WEEKLY_QUOTA: the set the quota is measured against generalizes from
  -- "this one service" to "the plan's covered set" only under
  -- SHARED_ACROSS_SERVICES (ADR-0029 S3.3) -- PER_SERVICE keeps counting
  -- exactly this service, identical to pre-ADR-0029 behaviour.
  v_quota_service_ids := public.service_plan_quota_service_ids(v_plan.id, p_service_id);

  if p_prospective_series then
    v_position := public.customer_series_in_force_count(p_customer_id, v_quota_service_ids, v_local_date) + 1;
  elsif p_recurring_booking_id is not null then
    v_position := public.customer_series_quota_position(
      p_customer_id, v_quota_service_ids, v_local_date, p_recurring_booking_id
    );
  else
    return 'OUTSIDE_PLAN_QUOTA';
  end if;

  if v_position is null then
    return 'OUTSIDE_PLAN_QUOTA';
  end if;

  if v_position <= v_plan.weekly_quota then
    return 'OK';
  end if;

  return 'OVER_PLAN_QUOTA';
end;
$BODY$;

comment on function public.evaluate_payment_coverage(uuid, uuid, uuid, uuid, boolean) is
  'Whether a payment covers this slot for this customer, and why not when it does not. ADR-0029: the plan is resolved via payment_service_coverage and its covered set can span several services; the decision shape is unchanged. Never granted to authenticated: it takes a caller-supplied customer_id.';

-- ============================================================
-- 8. customer_series_in_force_count() / customer_series_quota_position():
--    p_service_id -> p_service_ids uuid[] (ADR-0029 S3.3)
-- ============================================================
-- The array type changes the argument signature, so CREATE OR REPLACE
-- cannot keep the old three-argument (uuid, uuid, date) overload in place
-- -- it has to be dropped first, same reasoning applied throughout Phase
-- 20 whenever a parameter's type (not just its default) changed.

drop function if exists public.customer_series_in_force_count(uuid, uuid, date);

create function public.customer_series_in_force_count(
  p_customer_id uuid,
  p_service_ids uuid[],
  p_local_date date
)
returns int
language sql
stable
security definer
set search_path = public
as $BODY$
  select count(*)::int
  from public.recurring_bookings rb
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  where rb.customer_id = p_customer_id
    and sr.service_id = any(p_service_ids)
    and rb.status = 'ACTIVE'
    and rb.start_date <= p_local_date
    and (rb.end_date is null or rb.end_date >= p_local_date);
$BODY$;

comment on function public.customer_series_in_force_count(uuid, uuid[], date) is
  'How many RecurringBooking of this customer are in force for that date across this set of services. PER_SERVICE calls this with a one-element array (identical result to the pre-ADR-0029 signature); SHARED_ACROSS_SERVICES calls it once with the whole covered set (ADR-0029 S3.3).';

revoke execute on function public.customer_series_in_force_count(uuid, uuid[], date)
  from public, anon, authenticated, service_role;

drop function if exists public.customer_series_quota_position(uuid, uuid, date, uuid);

create function public.customer_series_quota_position(
  p_customer_id uuid,
  p_service_ids uuid[],
  p_local_date date,
  p_recurring_booking_id uuid
)
returns int
language sql
stable
security definer
set search_path = public
as $BODY$
  select ranked.quota_position
  from (
    select
      rb.id,
      (row_number() over (order by rb.created_at asc, rb.id asc))::int as quota_position
    from public.recurring_bookings rb
    join public.schedule_rules sr on sr.id = rb.schedule_rule_id
    where rb.customer_id = p_customer_id
      and sr.service_id = any(p_service_ids)
      and rb.status = 'ACTIVE'
      and rb.start_date <= p_local_date
      and (rb.end_date is null or rb.end_date >= p_local_date)
  ) ranked
  where ranked.id = p_recurring_booking_id;
$BODY$;

comment on function public.customer_series_quota_position(uuid, uuid[], date, uuid) is
  'The 1-based position of a series among the customer series in force for that date across this set of services, ordered created_at asc, id asc -- a single total order over the whole pool under SHARED_ACROSS_SERVICES (ADR-0029 S3.3), same tie-break rule as before.';

revoke execute on function public.customer_series_quota_position(uuid, uuid[], date, uuid)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 9. assert_series_within_plan_quota(): same signature, generalized body
-- ============================================================
-- Call sites (create_recurring_booking / admin_create_recurring_booking)
-- are untouched: they still pass one (customer, service, date), because
-- the *series being created* is always for one ScheduleRule of one
-- service -- the plan's quota_scope decides internally whether that
-- series is measured against just this service or the whole pool.

create or replace function public.assert_series_within_plan_quota(
  p_customer_id uuid,
  p_service_id uuid,
  p_local_date date
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_in_force int;
  v_quota_service_ids uuid[];
begin
  v_plan := public.resolve_covering_service_plan(p_customer_id, p_service_id, p_local_date);

  if v_plan.id is null or v_plan.plan_kind <> 'WEEKLY_QUOTA' then
    return;
  end if;

  v_quota_service_ids := public.service_plan_quota_service_ids(v_plan.id, p_service_id);
  v_in_force := public.customer_series_in_force_count(p_customer_id, v_quota_service_ids, p_local_date);

  if v_in_force + 1 > v_plan.weekly_quota then
    raise exception 'OVER_PLAN_QUOTA';
  end if;
end;
$BODY$;

revoke execute on function public.assert_series_within_plan_quota(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 10. generate_recurring_booking() / retry_not_generated_booking():
--     unchanged bodies -- they already call evaluate_payment_coverage()
--     and never touched service_id/quota internals directly. Re-created
--     here only where CREATE OR REPLACE is otherwise untouched by this
--     migration; both keep their exact Phase 20 shape.
-- ============================================================
-- (No redefinition needed: neither function reads service_plans.service_id
-- or calls customer_series_* directly -- both go through
-- evaluate_payment_coverage(), which is what this migration rewrote.)

-- ============================================================
-- 11. makeup_credits retrofit -- the table with real customer rows
-- ============================================================
-- service_id becomes nullable (a SHARED_ACROSS_SERVICES-origin credit has
-- no single service); service_plan_id is added NOT NULL, because
-- consuming a shared credit needs to know which plan's covered set it is
-- good for (ADR-0029 S5.2). Every existing row keeps its exact service_id
-- untouched by this migration -- nothing here reinterprets a PER_SERVICE
-- credit as shared. See the backfill comment below for exactly how
-- service_plan_id is filled in for rows that predate this column.

alter table public.makeup_credits alter column service_id drop not null;

comment on column public.makeup_credits.service_id is
  'ADR-0029 S5.2: non-null means this credit is anchored to that exact service (a PER_SERVICE-origin credit, or any credit from a single-service plan). NULL means it is usable on any service in service_plan_covered_service_ids(service_plan_id) -- a SHARED_ACROSS_SERVICES-origin credit. Existing rows keep their original, non-null service_id: this migration never reinterprets a PER_SERVICE credit as shared.';

alter table public.makeup_credits
  add column service_plan_id uuid references public.service_plans (id) on delete restrict;

comment on column public.makeup_credits.service_plan_id is
  'ADR-0029 S5.2: the plan whose coverage produced this credit. Governs what service_id = null resolves to at consumption time (service_plan_covered_service_ids(service_plan_id)), and is checked for consistency against service_id by makeup_credits_scope_matches_plan.';

-- Backfill (production-data-safe): every row that exists before this
-- migration was issued under the pre-ADR-0029 world, where a plan always
-- covered exactly one service -- so an exact "which plan was in force"
-- reconstruction and a "which plan covers this service" fallback land on
-- the same answer either way. Two passes:
--
--  1. CUSTOMER_RELEASE / ORGANIZATION_CANCELLED (have a source_booking_id):
--     re-derive the plan actually in force for (customer, service) on the
--     released slot's local date, from payments -- the same historical
--     fact evaluate_payment_coverage() would have used to grant OK at
--     issuance time.
--  2. Whatever pass 1 could not resolve, plus every MANUAL credit (which
--     has no booking/payment to anchor to by definition): the
--     organization's plan for that exact service, preferring an active
--     one, oldest first for a stable, reproducible choice.
--
-- Both passes can only ever land on a single-service plan at this point
-- in the migration: service_plan_services was just backfilled 1:1 above,
-- and no multi-service plan can exist yet (nobody has had the chance to
-- create one). That is what makes pass 2's "best guess" safe rather than
-- merely convenient -- it cannot accidentally scope a legacy credit to a
-- plan wider than the one it was actually issued under.
--
-- Neither pass ever touches service_id. A legacy credit's redemption path
-- (resolve_usable_makeup_credit, below) checks `service_id = p_service_id`
-- before it ever looks at service_plan_id, so this backfill's accuracy
-- only matters for the new scope-consistency trigger and for display --
-- it changes nothing about which bookings a pre-existing credit can pay
-- for.

update public.makeup_credits mc
set service_plan_id = (
  select p.service_plan_id
  from public.bookings b
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  join public.payments p on p.customer_id = mc.customer_id and p.service_id = mc.service_id
  where b.id = mc.source_booking_id
    and p.status = 'PAID'
    and p.slot_occurrence_id is null
    and p.period_start <= public.slot_local_date(so.id)
    and p.period_end >= public.slot_local_date(so.id)
  order by p.period_start desc, p.created_at desc
  limit 1
)
where mc.service_plan_id is null
  and mc.source_booking_id is not null;

update public.makeup_credits mc
set service_plan_id = (
  select sp.id
  from public.service_plans sp
  join public.service_plan_services sps on sps.service_plan_id = sp.id
  where sps.service_id = mc.service_id
    and sp.organization_id = mc.organization_id
  order by sp.is_active desc, sp.created_at asc
  limit 1
)
where mc.service_plan_id is null;

alter table public.makeup_credits alter column service_plan_id set not null;

-- Coherence: a credit's service_id nullability has to match what its
-- plan's scope actually was. Generalizes past "quota_scope" alone because
-- UNLIMITED has no quota_scope (always null) yet can still be
-- multi-service -- an UNLIMITED multi-service plan never rationed by
-- service in the first place, so a credit from it is shared exactly like
-- SHARED_ACROSS_SERVICES (coalesce below). A single-service plan is
-- PER_SERVICE in effect regardless of its declared quota_scope.
create or replace function public.check_makeup_credit_scope_matches_plan()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_covered_count int;
  v_quota_scope public.plan_quota_scope;
begin
  select count(*) into v_covered_count
    from public.service_plan_covered_service_ids(new.service_plan_id);
  select quota_scope into v_quota_scope from public.service_plans where id = new.service_plan_id;

  if v_covered_count <= 1 or coalesce(v_quota_scope, 'SHARED_ACROSS_SERVICES') = 'PER_SERVICE' then
    if new.service_id is null then
      raise exception 'MAKEUP_CREDIT_SCOPE_MISMATCH';
    end if;
  else
    if new.service_id is not null then
      raise exception 'MAKEUP_CREDIT_SCOPE_MISMATCH';
    end if;
  end if;

  return new;
end;
$BODY$;

comment on function public.check_makeup_credit_scope_matches_plan() is
  'ADR-0029 S5.2, generalized to cover UNLIMITED as well as WEEKLY_QUOTA (the proposal only worked through the WEEKLY_QUOTA case): a plan covering more than one service under SHARED_ACROSS_SERVICES, or any UNLIMITED plan (no quota_scope, never rationed per service to begin with), issues a shared (service_id null) credit. Everything else -- a single-service plan of any kind, or WEEKLY_QUOTA/PER_SERVICE -- issues a service_id-anchored one. SECURITY DEFINER: calls the revoked service_plan_covered_service_ids() helper.';

create trigger makeup_credits_scope_matches_plan
  before insert or update on public.makeup_credits
  for each row execute function public.check_makeup_credit_scope_matches_plan();

-- Cross-tenant check, extended: service_id is now optionally absent, and
-- service_plan_id is new.
create or replace function public.check_makeup_credit_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_customer_org uuid;
  v_service_org uuid;
  v_plan_org uuid;
  v_source_org uuid;
  v_consumed_org uuid;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  if v_customer_org is null or v_customer_org <> new.organization_id then
    raise exception 'MakeupCredit organization_id must match its Customer';
  end if;

  if new.service_id is not null then
    select organization_id into v_service_org from public.services where id = new.service_id;
    if v_service_org is null or v_service_org <> new.organization_id then
      raise exception 'MakeupCredit organization_id must match its Service';
    end if;
  end if;

  select organization_id into v_plan_org from public.service_plans where id = new.service_plan_id;
  if v_plan_org is null or v_plan_org <> new.organization_id then
    raise exception 'MakeupCredit organization_id must match its ServicePlan';
  end if;

  if new.source_booking_id is not null then
    select organization_id into v_source_org from public.bookings where id = new.source_booking_id;
    if v_source_org is null or v_source_org <> new.organization_id then
      raise exception 'MakeupCredit source_booking_id must belong to the same Organization';
    end if;
  end if;

  if new.consumed_booking_id is not null then
    select organization_id into v_consumed_org from public.bookings where id = new.consumed_booking_id;
    if v_consumed_org is null or v_consumed_org <> new.organization_id then
      raise exception 'MakeupCredit consumed_booking_id must belong to the same Organization';
    end if;
  end if;

  return new;
end;
$BODY$;

-- Immutable terms, extended with service_plan_id (service_id was already
-- covered).
create or replace function public.check_makeup_credit_immutable_terms()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if new.customer_id is distinct from old.customer_id
     or new.service_id is distinct from old.service_id
     or new.service_plan_id is distinct from old.service_plan_id
     or new.source_booking_id is distinct from old.source_booking_id
     or new.origin is distinct from old.origin
     or new.issued_at is distinct from old.issued_at
     or new.expires_on is distinct from old.expires_on
  then
    raise exception 'MAKEUP_CREDIT_TERMS_IMMUTABLE';
  end if;

  return new;
end;
$BODY$;

-- The hot-path index for a shared (service_id is null) credit lookup --
-- the existing makeup_credits_usable_idx (customer_id, service_id,
-- expires_on) only serves the exact-service branch.
create index makeup_credits_usable_shared_idx
  on public.makeup_credits (customer_id, expires_on)
  where status = 'AVAILABLE' and service_id is null;

-- ============================================================
-- 12. Credit resolution and emission -- multi-service aware
-- ============================================================

create or replace function public.resolve_usable_makeup_credit(
  p_customer_id uuid,
  p_service_id uuid,
  p_local_date date
)
returns uuid
language sql
stable
security definer
set search_path = public
as $BODY$
  select mc.id
  from public.makeup_credits mc
  where mc.customer_id = p_customer_id
    and mc.status = 'AVAILABLE'
    and mc.expires_on >= p_local_date
    and (
      mc.service_id = p_service_id
      or (
        mc.service_id is null
        and p_service_id in (select public.service_plan_covered_service_ids(mc.service_plan_id))
      )
    )
  order by mc.expires_on asc, mc.issued_at asc, mc.id asc
  limit 1;
$BODY$;

comment on function public.resolve_usable_makeup_credit(uuid, uuid, date) is
  'ADR-0029 S5.2: a service_id-anchored credit only covers that exact service (unchanged); a service_id-null credit covers any service in service_plan_covered_service_ids(service_plan_id). SECURITY DEFINER, revoked from every request role -- unchanged reachability.';

revoke execute on function public.resolve_usable_makeup_credit(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- Emission: condition 4 (coverage was OK) is unchanged, but the credit's
-- own scope now has to be derived from *which plan* actually covered the
-- released booking, not just "the" service. resolve_covering_service_plan()
-- answers this for a period payment; a DROP_IN (turno suelto) payment has
-- no payment_service_coverage row (S6 above), so it falls back to the
-- payment tied directly to the released occurrence.
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
    -- tied directly to this occurrence.
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

  if v_policy.expiry_basis = 'END_OF_BILLING_PERIOD' then
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
    v_policy.expiry_basis, v_policy.expiry_days, v_local_date, v_period_end
  );

  insert into public.makeup_credits (
    organization_id, customer_id, service_id, service_plan_id, origin, source_booking_id, issued_by,
    expires_on, expiry_basis, expiry_basis_days
  )
  values (
    p_booking.organization_id, p_booking.customer_id, v_credit_service_id, v_plan.id, p_origin, p_booking.id, auth.uid(),
    v_expires_on, v_policy.expiry_basis, v_policy.expiry_days
  )
  on conflict (source_booking_id) where source_booking_id is not null do nothing
  returning id into v_credit_id;

  return v_credit_id;
end;
$BODY$;

comment on function public.issue_makeup_credit(public.bookings, public.makeup_credit_origin, boolean) is
  'The only function that mints a MakeupCredit (ADR-0025). ADR-0029: additionally resolves which plan covered the released booking, to decide whether the credit is anchored to that one service or shared across the plans covered set (S5.1/S5.2).';

-- ============================================================
-- 13. Portal / admin reads: show the real scope of a shared credit
-- ============================================================

create or replace function public.my_makeup_credits()
returns table (
  credit_id uuid,
  organization_name text,
  service_name text,
  origin public.makeup_credit_origin,
  status public.makeup_credit_status,
  issued_at timestamptz,
  expires_on date,
  is_expired boolean,
  source_start_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    mc.id,
    o.name,
    coalesce(
      s.name,
      (
        select string_agg(sv.name, ' + ' order by sv.name)
        from public.services sv
        where sv.id in (select public.service_plan_covered_service_ids(mc.service_plan_id))
      )
    ),
    mc.origin,
    mc.status,
    mc.issued_at,
    mc.expires_on,
    mc.expires_on < current_date,
    so.start_at
  from public.makeup_credits mc
  join public.customers c on c.id = mc.customer_id and c.profile_id = auth.uid()
  join public.organizations o on o.id = mc.organization_id
  left join public.services s on s.id = mc.service_id
  left join public.bookings b on b.id = mc.source_booking_id
  left join public.slot_occurrences so on so.id = b.slot_occurrence_id
  order by (mc.status = 'AVAILABLE') desc, mc.expires_on asc;
$BODY$;

comment on function public.my_makeup_credits() is
  'ADR-0029: service_name now falls back to the plans full covered-service list ("Pilates + Musculación") for a shared credit (service_id null), instead of a blank/indefinite service.';

create or replace function public.organization_customer_makeup_credits(p_customer_id uuid)
returns table (
  credit_id uuid,
  service_name text,
  origin public.makeup_credit_origin,
  status public.makeup_credit_status,
  issued_at timestamptz,
  expires_on date,
  is_expired boolean,
  note text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    mc.id,
    coalesce(
      s.name,
      (
        select string_agg(sv.name, ' + ' order by sv.name)
        from public.services sv
        where sv.id in (select public.service_plan_covered_service_ids(mc.service_plan_id))
      )
    ),
    mc.origin, mc.status, mc.issued_at, mc.expires_on, mc.expires_on < current_date, mc.note
  from public.makeup_credits mc
  join public.customers c on c.id = mc.customer_id
  left join public.services s on s.id = mc.service_id
  where mc.customer_id = p_customer_id
    and public.is_organization_member(c.organization_id)
  order by (mc.status = 'AVAILABLE') desc, mc.expires_on asc;
$BODY$;

-- ============================================================
-- 14. grant_manual_makeup_credit(): anchoring a courtesy credit to a plan
-- ============================================================
-- MANUAL has no booking/payment behind it (by definition -- see
-- makeup_credits_manual_has_no_source), so there is no coverage decision
-- to re-derive: the OWNER already names the exact service. This picks the
-- organization's active plan that covers that service, preferring the
-- narrowest one (fewest covered services) so a courtesy credit stays
-- PER_SERVICE-shaped whenever a single-service plan for that service
-- exists, and only spills into a shared, multi-service credit when the
-- only plan on offer for that service is itself multi-service (a
-- deliberate extension of S5.2 the proposal did not spell out for MANUAL
-- -- flagged in the implementation report).
create or replace function public.grant_manual_makeup_credit(
  p_customer_id uuid,
  p_service_id uuid,
  p_expires_on date,
  p_note text
)
returns public.makeup_credits
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer public.customers;
  v_service public.services;
  v_credit public.makeup_credits;
  v_plan_id uuid;
  v_covered_count int;
  v_credit_service_id uuid;
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  if not public.is_organization_owner(v_customer.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_service from public.services
    where id = p_service_id and organization_id = v_customer.organization_id;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if p_note is null or btrim(p_note) = '' then
    raise exception 'MAKEUP_CREDIT_NOTE_REQUIRED';
  end if;

  if p_expires_on is null or p_expires_on < current_date then
    raise exception 'MAKEUP_CREDIT_EXPIRES_ON_INVALID';
  end if;

  select sp.id into v_plan_id
    from public.service_plans sp
    where sp.organization_id = v_customer.organization_id
      and sp.is_active
      and (
        sp.applies_to_all_services
        or exists (
          select 1 from public.service_plan_services sps
          where sps.service_plan_id = sp.id and sps.service_id = p_service_id
        )
      )
    order by (select count(*) from public.service_plan_covered_service_ids(sp.id)) asc, sp.created_at asc
    limit 1;

  if v_plan_id is null then
    raise exception 'SERVICE_HAS_NO_PLAN';
  end if;

  select count(*) into v_covered_count from public.service_plan_covered_service_ids(v_plan_id);
  v_credit_service_id := case when v_covered_count <= 1 then p_service_id else null end;

  insert into public.makeup_credits (
    organization_id, customer_id, service_id, service_plan_id, origin, source_booking_id, issued_by,
    expires_on, expiry_basis, expiry_basis_days, note
  )
  values (
    v_customer.organization_id, p_customer_id, v_credit_service_id, v_plan_id, 'MANUAL', null, auth.uid(),
    p_expires_on, 'DAYS_AFTER', greatest(p_expires_on - current_date, 1), p_note
  )
  returning * into v_credit;

  return v_credit;
end;
$BODY$;

comment on function public.grant_manual_makeup_credit(uuid, uuid, date, text) is
  'Courtesy credit (origin = MANUAL, ADR-0025 resolution 5). OWNER-only. ADR-0029: anchored to the narrowest active plan covering p_service_id, so it is service_id-specific whenever a single-service plan exists for that service; only becomes a shared credit if the only plan on offer for that service is itself multi-service.';

revoke execute on function public.grant_manual_makeup_credit(uuid, uuid, date, text) from public, anon;
grant execute on function public.grant_manual_makeup_credit(uuid, uuid, date, text) to authenticated;

-- ============================================================
-- 15. payment_service_coverage RLS -- private, same two-layer shape as payments
-- ============================================================

alter table public.payment_service_coverage enable row level security;

create policy payment_service_coverage_select_self_or_staff
  on public.payment_service_coverage for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = payment_service_coverage.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );

grant select on public.payment_service_coverage to authenticated;

-- Deliberately no write policy: every row is a consequence of a payments
-- write, produced by the two SECURITY DEFINER triggers above -- same
-- "zero write policies, RPC/trigger-only" shape as makeup_credits.

notify pgrst, 'reload schema';
