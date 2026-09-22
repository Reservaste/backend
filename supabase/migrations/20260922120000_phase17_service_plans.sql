-- Phase 17: ServicePlan -- a monthly payment buys slots, not unlimited access
-- Ref: docs/decisions.md ADR-0024 (+ the seven Orchestrator resolutions),
-- docs/proposals/adr-0024-service-plan.md (§2.1 .. §6, migration plan §4).
--
-- Until now payment_covers_slot() said: a PAID payment whose period
-- contains the slot's local date lets this customer book *any* number of
-- that service's slots in that period. The first real client sells the
-- opposite: 1800 for once a week, 2500 for twice, 800 for a single class.
-- What is bought is the *frequency*.
--
-- The inversion, in one line: "N times a week" IS "N RecurringBooking in
-- force", because every ScheduleRule is weekly by construction and one
-- series subscribes to exactly one rule. So no counter is persisted, and
-- availableCapacity = maxCapacity - activeBookings is untouched.
--
-- Additive, in the same order as ADR-0022 (Phase 14/15), which is the one
-- that did not break 16 tests at once: columns and data first, the
-- decision path last.
--
-- Two implementation traps this file works around on purpose:
--   * ALTER TYPE ... ADD VALUE + using that value in the same transaction
--     works inside a plpgsql body (evaluated after commit, the Phase 7
--     precedent) but fails in a CHECK, in DML, or in a *SQL*-language
--     function body (parsed at CREATE time). Where a new value is needed
--     in a SQL body below, it is compared as ::text.
--   * The backfill UPDATE on payments fires payments_reconcile_pending,
--     which walks the whole decision path. It runs *before* the functions
--     are redefined, and with that trigger disabled, so nothing can
--     return one of the brand-new enum values inside this transaction.

-- ============================================================
-- 0. organizations.currency (ADR-0024, resolution 2)
-- ============================================================
-- service_plans.price is money and had no currency, exactly like
-- services.price before it. It belongs to the organization, not to each
-- price row: a business quotes its whole price list in one currency.

alter table public.organizations
  add column if not exists currency text not null default 'UYU';

alter table public.organizations
  add constraint organizations_currency_format
  check (currency ~ '^[A-Z]{3}$');

comment on column public.organizations.currency is
  'ISO 4217 code used to render every price of this organization (ADR-0024). Format enforced here because the column is writable through PostgREST.';

-- ============================================================
-- 1. service_plans: the price list an organization offers its customers
-- ============================================================
-- Not public.plans -- those are the SaaS tiers the *organization* pays
-- (Phase 10). This table is what a Customer buys from the organization.

create type public.service_plan_kind as enum ('DROP_IN', 'WEEKLY_QUOTA', 'UNLIMITED');

comment on type public.service_plan_kind is
  'What a payment buys: a single class (DROP_IN), N fixed weekly slots (WEEKLY_QUOTA), or todays unrestricted behaviour (UNLIMITED). Ref: ADR-0024.';

create table public.service_plans (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  -- One plan belongs to exactly one Service (ADR-0024 §2.3): every money
  -- and decision path is wired per service, and a multi-service pass
  -- would make "which service is this payment for" unanswerable again --
  -- the regression ADR-0022 fixed by killing ServiceEntitlement.
  service_id uuid not null references public.services (id) on delete cascade,
  name text not null,
  description text,
  price numeric(12, 2) not null,
  plan_kind public.service_plan_kind not null,
  -- Only WEEKLY_QUOTA uses it. Coherence is the CHECK's job, not the UI's.
  weekly_quota int,
  -- The billing period moves up from the Service to the plan: one service
  -- now has one ONE_TIME plan and three MONTHLY ones, which a single
  -- column per service cannot express.
  billing_type public.billing_type not null,
  billing_cycle public.billing_cycle,
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),

  -- weekly_quota exists if and only if the plan is WEEKLY_QUOTA. No upper
  -- bound on purpose: a service can have two rules on the same weekday
  -- (Monday 09:00 and Monday 18:00), so <= 7 would be wrong.
  constraint service_plans_quota_matches_kind check (
    (plan_kind = 'WEEKLY_QUOTA' and weekly_quota is not null and weekly_quota >= 1)
    or (plan_kind <> 'WEEKLY_QUOTA' and weekly_quota is null)
  ),
  constraint service_plans_price_non_negative check (price >= 0),
  -- The three kind<->billing combinations the product supports today. A
  -- day pass (UNLIMITED + ONE_TIME) or a quarterly plan only need this
  -- CHECK relaxed, never a new plan_kind -- which is why the two columns
  -- are not collapsed into one.
  constraint service_plans_billing_matches_kind check (
    (plan_kind = 'DROP_IN' and billing_type = 'ONE_TIME' and billing_cycle is null)
    or (plan_kind in ('WEEKLY_QUOTA', 'UNLIMITED') and billing_type = 'MONTHLY' and billing_cycle is not null)
  ),
  constraint service_plans_cancellation_consistent check (
    (cancelled_at is null and cancelled_by is null)
    or (cancelled_at is not null and not is_active)
  )
);

comment on table public.service_plans is
  'The price list an Organization offers its Customers for one Service: a price, a billing period and a booking right (ADR-0024). Generic by design -- a single class, a fixed weekly slot, or an unrestricted pass. Never a rubro-specific concept.';

comment on column public.service_plans.weekly_quota is
  'How many RecurringBooking in force this plan allows for its service. Measured as series in force for the slot date, never as bookings inside a weekly window (ADR-0024).';

comment on column public.service_plans.is_active is
  'false means "no longer offered". It never invalidates a payment already made: payment_covers_slot() reads plan_kind without filtering by is_active (ADR-0024 §6.d).';

create trigger service_plans_set_updated_at
  before update on public.service_plans
  for each row execute function public.set_updated_at();

create index service_plans_organization_idx on public.service_plans (organization_id);
create index service_plans_service_idx on public.service_plans (service_id, sort_order);

-- Two active plans with the same name on one service is a data-entry
-- error, not an option.
create unique index service_plans_active_name_idx
  on public.service_plans (service_id, lower(name))
  where is_active;

-- One active DROP_IN per service: it is the price the "pay for this
-- class" flow charges automatically, and two make that choice ambiguous.
create unique index service_plans_one_active_drop_in_idx
  on public.service_plans (service_id)
  where is_active and plan_kind = 'DROP_IN';

-- One active UNLIMITED per service: it is what the compatibility bridge
-- below anchors a payment with no explicit plan to, and what makes that
-- bridge deterministic.
create unique index service_plans_one_active_unlimited_idx
  on public.service_plans (service_id)
  where is_active and plan_kind = 'UNLIMITED';

-- Cross-table invariant, so it cannot be a CHECK -- and the table is
-- writable through PostgREST, so Zod in the form is not a defence.
create or replace function public.check_service_plan_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_service_org uuid;
begin
  select organization_id into v_service_org from public.services where id = new.service_id;

  if v_service_org is null or v_service_org <> new.organization_id then
    raise exception 'ServicePlan organization_id must match its Service';
  end if;

  return new;
end;
$BODY$;

create trigger service_plans_same_org
  before insert or update on public.service_plans
  for each row execute function public.check_service_plan_same_org();

-- ADR-0024, resolution 6: a quota plan on a service that requires no
-- payment is inapplicable and would look valid. payment_covers_slot()
-- returns true at step 1 for a free service, so the quota never runs.
create or replace function public.check_service_plan_requires_paid_service()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_payment_required boolean;
begin
  if new.plan_kind = 'WEEKLY_QUOTA' and new.is_active then
    select payment_required into v_payment_required from public.services where id = new.service_id;
    if not coalesce(v_payment_required, false) then
      raise exception 'SERVICE_NOT_PAYMENT_REQUIRED';
    end if;
  end if;

  return new;
end;
$BODY$;

create trigger service_plans_require_paid_service
  before insert or update on public.service_plans
  for each row execute function public.check_service_plan_requires_paid_service();

-- The same rule from the other side: switching payment_required off on a
-- service that still sells quota plans leaves those plans pretending to
-- limit something.
create or replace function public.check_service_payment_required_vs_plans()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if exists (
    select 1 from public.service_plans sp
    where sp.service_id = new.id and sp.is_active and sp.plan_kind = 'WEEKLY_QUOTA'
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

-- ============================================================
-- 2. payments: the plan anchor and the single-class anchor
-- ============================================================

alter table public.payments
  add column if not exists service_plan_id uuid references public.service_plans (id) on delete restrict,
  add column if not exists slot_occurrence_id uuid references public.slot_occurrences (id) on delete restrict;

comment on column public.payments.service_plan_id is
  'The registration anchor (ADR-0024): what was bought. on delete restrict because plans are deactivated, never deleted.';

comment on column public.payments.slot_occurrence_id is
  'Set exactly for DROP_IN payments -- which class was paid. Stronger than a one-day period, which cannot tell two classes on the same day apart. ON DELETE RESTRICT, not CASCADE (correcting the proposal DDL): a payment is money and is never deleted, so deleting an occurrence must fail loudly instead of silently taking the economic record with it -- occurrences are cancelled, not deleted.';

comment on column public.payments.service_id is
  'Derived from service_plan_id and verified by trigger (ADR-0024 §2.6), not a second source of truth. Kept because the EXCLUDE, its indexes and four read functions of the payments module are wired per service.';

create index payments_service_plan_idx on public.payments (service_plan_id);
create index payments_slot_occurrence_idx on public.payments (slot_occurrence_id)
  where slot_occurrence_id is not null;

-- ============================================================
-- 3. Backfill: every existing payment becomes an UNLIMITED plan payment
-- ============================================================
-- Nobody changes behaviour on deploy day: step 5 of the new
-- payment_covers_slot() returns true for UNLIMITED, which is exactly what
-- today's rule does. Same additive pattern as ADR-0022.
--
-- The reconciliation trigger is switched off for the duration: updating a
-- PAID payment fires it, it walks retry_not_generated_booking() over the
-- customer's pending dates, and doing that mid-migration is both
-- pointless (nothing about coverage changed yet) and the one path that
-- could evaluate a brand-new enum value inside this transaction.

alter table public.payments disable trigger payments_reconcile_pending;

-- A service with payments but a null price is a real possibility (price
-- was nullable); 0 is the honest placeholder and the owner corrects it.
-- billing_type is forced to MONTHLY because the CHECK above only allows
-- UNLIMITED with a monthly cycle -- a service configured as ONE_TIME/FREE
-- that nevertheless has payments still gets a usable plan instead of
-- failing the migration.
insert into public.service_plans (
  organization_id, service_id, name, description, price,
  plan_kind, billing_type, billing_cycle, is_active, sort_order
)
select
  s.organization_id,
  s.id,
  s.name,
  'Plan creado automáticamente por la migración de ADR-0024 a partir de la configuración del servicio.',
  coalesce(s.price, 0),
  'UNLIMITED',
  'MONTHLY',
  coalesce(s.billing_cycle, 'CALENDAR_MONTH'),
  true,
  0
from public.services s
where s.payment_required
   or exists (select 1 from public.payments p where p.service_id = s.id);

update public.payments p
set service_plan_id = sp.id
from public.service_plans sp
where sp.service_id = p.service_id
  and sp.plan_kind = 'UNLIMITED'
  and sp.is_active
  and p.service_plan_id is null;

alter table public.payments enable trigger payments_reconcile_pending;

-- ============================================================
-- 4/5. Compatibility bridge, then NOT NULL
-- ============================================================
-- The payment form inserts into payments through PostgREST without
-- knowing about plans (frontend/app/actions/billing.ts). Same pattern as
-- fill_payment_service_from_entitlement() in Phase 14, with one
-- deliberate difference: when no UNLIMITED plan exists it *raises*.
-- A payment the decision path would have to read as "unlimited, just in
-- case" is the worse of the two options. This bridge dies in the phase
-- where the payments UI sends the plan explicitly.
--
-- It also derives the period of a single-class payment from the
-- occurrence, so a DROP_IN payment shows up in the right month in
-- organization_payment_summary() (which filters by period overlap)
-- without that function having to learn anything new.

create or replace function public.fill_payment_service_plan()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_local_date date;
begin
  if new.service_plan_id is null then
    select sp.id into new.service_plan_id
      from public.service_plans sp
      where sp.service_id = new.service_id
        and sp.is_active
        and sp.plan_kind = 'UNLIMITED'
      limit 1;

    if new.service_plan_id is null then
      raise exception 'PAYMENT_REQUIRES_PLAN';
    end if;
  end if;

  if new.slot_occurrence_id is not null then
    v_local_date := public.slot_local_date(new.slot_occurrence_id);
    if v_local_date is null then
      raise exception 'PAYMENT_OCCURRENCE_NOT_FOUND';
    end if;
    new.period_start := v_local_date;
    new.period_end := v_local_date;
  end if;

  return new;
end;
$BODY$;

create trigger payments_fill_service_plan
  before insert on public.payments
  for each row execute function public.fill_payment_service_plan();

-- Four invariants that cross tables, so none of them can be a CHECK
-- (ADR-0024 §2.6). Without the last one, a hand-crafted insert pays for
-- one service's class with a payment labelled to another.
create or replace function public.check_payment_plan_consistency()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_occurrence public.slot_occurrences;
begin
  select * into v_plan from public.service_plans where id = new.service_plan_id;
  if not found then
    raise exception 'PAYMENT_PLAN_NOT_FOUND';
  end if;

  if v_plan.organization_id <> new.organization_id then
    raise exception 'Payment organization_id must match its ServicePlan';
  end if;

  if v_plan.service_id <> new.service_id then
    raise exception 'Payment service_id must match its ServicePlan';
  end if;

  if (v_plan.plan_kind = 'DROP_IN') <> (new.slot_occurrence_id is not null) then
    raise exception 'PAYMENT_PLAN_KIND_REQUIRES_OCCURRENCE';
  end if;

  if new.slot_occurrence_id is not null then
    select * into v_occurrence from public.slot_occurrences where id = new.slot_occurrence_id;
    if not found
       or v_occurrence.organization_id <> new.organization_id
       or v_occurrence.service_id <> new.service_id then
      raise exception 'Payment slot_occurrence_id must belong to the same Organization and Service';
    end if;
  end if;

  return new;
end;
$BODY$;

-- Trigger name matters: triggers fire in alphabetical order, and this one
-- has to see the plan the bridge just filled in
-- (payments_fill_service_plan < payments_plan_consistency).
create trigger payments_plan_consistency
  before insert or update on public.payments
  for each row execute function public.check_payment_plan_consistency();

alter table public.payments
  alter column service_plan_id set not null;

-- ============================================================
-- 6. Immutability of the terms (ADR-0024, resolution 5)
-- ============================================================
-- plan_kind and weekly_quota are what the booking path reads: changing
-- them rewrites retroactively what everyone bought last month. price
-- stays free -- it only affects future charges, and each Payment records
-- its own amount. Fixing a typo = deactivate the plan and create another,
-- which does not cut anyone's coverage.

create or replace function public.check_service_plan_terms_immutable()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if (new.plan_kind is distinct from old.plan_kind
      or new.weekly_quota is distinct from old.weekly_quota)
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

create trigger service_plans_terms_immutable
  before update on public.service_plans
  for each row execute function public.check_service_plan_terms_immutable();

-- ============================================================
-- 7. Double charge: the EXCLUDE re-anchored, plus the half it was missing
-- ============================================================
-- Someone on a monthly plan who buys a single class falls inside their
-- own period and the insert was rejected. Period payments keep exactly
-- the protection they had; single-class payments would otherwise be left
-- with *none*, and paying the same class twice is a double charge of the
-- same gravity.

alter table public.payments
  drop constraint if exists payments_no_overlapping_paid;

alter table public.payments
  add constraint payments_no_overlapping_paid exclude using gist (
    customer_id with =,
    service_id with =,
    daterange(period_start, period_end, '[]') with &&
  ) where (status = 'PAID' and slot_occurrence_id is null);

create unique index payments_one_paid_per_occurrence_idx
  on public.payments (customer_id, slot_occurrence_id)
  where status = 'PAID' and slot_occurrence_id is not null;

-- ============================================================
-- 8. Reason codes
-- ============================================================
-- PAYMENT_REQUIRED does not cover these: it would tell someone who just
-- paid that they have to pay. Same error ADR-0018 corrected once with
-- not_generated_reason and Phase 12 corrected again.
--   OUTSIDE_PLAN_QUOTA -- the month is paid, but this booking is not one
--     of the fixed slots the plan bought (customer's problem: pay the
--     class, use a make-up credit, or wait).
--   OVER_PLAN_QUOTA    -- this *series* exceeds the plan's frequency
--     (front desk's problem: upgrade the plan or drop a series).
--   SERVICE_HAS_NO_PLAN -- the service demands payment and has no active
--     plan at all: an owner configuration error, not a customer one.
-- not_generated_reason only needs OVER_PLAN_QUOTA: a NOT_GENERATED date
-- always comes from a series.

alter type public.can_book_reason add value if not exists 'OUTSIDE_PLAN_QUOTA';
alter type public.can_book_reason add value if not exists 'OVER_PLAN_QUOTA';
alter type public.can_book_reason add value if not exists 'SERVICE_HAS_NO_PLAN';
alter type public.not_generated_reason add value if not exists 'OVER_PLAN_QUOTA';

-- ============================================================
-- 9. The quota, measured as series in force -- never as a weekly window
-- ============================================================
-- status = 'ACTIVE' alone over-counts: ADR-0010 left RecurringBooking's
-- status as an expression of intent, so a series that ended in June is
-- still ACTIVE in September. And the date is the slot's local date, never
-- now() -- the ADR-0013 lesson applied to the quota: a series starting
-- next month does not consume quota today, but it does for a slot next
-- month.

create or replace function public.customer_series_in_force_count(
  p_customer_id uuid,
  p_service_id uuid,
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
    and sr.service_id = p_service_id
    and rb.status = 'ACTIVE'
    and rb.start_date <= p_local_date
    and (rb.end_date is null or rb.end_date >= p_local_date);
$BODY$;

comment on function public.customer_series_in_force_count(uuid, uuid, date) is
  'How many RecurringBooking of this customer are in force for that date on that service. The quota is this number, because every ScheduleRule is weekly by construction (ADR-0024).';

-- The tie-break when there are more series in force than quota:
-- created_at asc, id asc. It has to be a *total* order -- created_at can
-- tie, and a non-total order would let preview and confirm disagree about
-- which series is inside the quota.
create or replace function public.customer_series_quota_position(
  p_customer_id uuid,
  p_service_id uuid,
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
      and sr.service_id = p_service_id
      and rb.status = 'ACTIVE'
      and rb.start_date <= p_local_date
      and (rb.end_date is null or rb.end_date >= p_local_date)
  ) ranked
  where ranked.id = p_recurring_booking_id;
$BODY$;

comment on function public.customer_series_quota_position(uuid, uuid, date, uuid) is
  'The 1-based position of a series among the customer series in force for that date, ordered created_at asc, id asc. Null when the series is not in force -- the first N contracted are the ones inside the quota (ADR-0024 §2.4c).';

-- "Does this customer already hold a standing reservation on this rule?"
-- -- as one definition instead of three copies of the same EXISTS. Both
-- create paths refuse a second series with it, and both previews use it
-- to notice that the series they would be creating already exists.
-- Same "in force" criterion as the quota, which is what makes the count
-- of series and the duplicate guard agree about what a live series is.
create or replace function public.customer_standing_series_on_rule(
  p_customer_id uuid,
  p_schedule_rule_id uuid,
  p_local_date date
)
returns uuid
language sql
stable
security definer
set search_path = public
as $BODY$
  select rb.id
  from public.recurring_bookings rb
  where rb.customer_id = p_customer_id
    and rb.schedule_rule_id = p_schedule_rule_id
    and rb.status = 'ACTIVE'
    and rb.start_date <= p_local_date
    and (rb.end_date is null or rb.end_date >= p_local_date)
  order by rb.created_at asc, rb.id asc
  limit 1;
$BODY$;

-- ============================================================
-- 10. Coverage, with its reason. One implementation, two entry points.
-- ============================================================
-- payment_covers_slot() keeps its boolean contract for the call sites
-- that only need yes/no; everything that has to *explain* the refusal
-- calls this. They are not two rules -- the boolean is literally this
-- function compared to 'OK' (ADR-0018: one decision function).

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
  v_payment public.payments;
  v_plan public.service_plans;
  v_position int;
begin
  select * into v_service from public.services where id = p_service_id;
  if not found then
    return 'SERVICE_INACTIVE';
  end if;

  -- 1. A service nobody has to pay for is always covered, and the quota
  -- cannot be faked on top of one (§6.i).
  if not v_service.payment_required then
    return 'OK';
  end if;

  -- 2. The date the business counts, in the organization's timezone.
  v_local_date := public.slot_local_date(p_slot_occurrence_id);
  if v_local_date is null then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  -- 3. The single-class payment is asked *first*, because it is the most
  -- specific: a paid class is paid, whatever any plan says.
  if exists (
    select 1 from public.payments p
    where p.customer_id = p_customer_id
      and p.slot_occurrence_id = p_slot_occurrence_id
      and p.status = 'PAID'
  ) then
    return 'OK';
  end if;

  -- 4. The period payment in force for that date. Resolution 1 keeps at
  -- most one of these per (customer, service) -- VOID and re-enter to
  -- change plan mid-period -- so the decision path never has to invent a
  -- precedence rule between two live payments.
  select * into v_payment
  from public.payments p
  where p.customer_id = p_customer_id
    and p.service_id = p_service_id
    and p.status = 'PAID'
    and p.slot_occurrence_id is null
    and p.period_start <= v_local_date
    and p.period_end >= v_local_date
  order by p.period_start desc, p.created_at desc
  limit 1;

  if not found then
    -- Nothing to sell is a different problem from nothing sold.
    if not exists (
      select 1 from public.service_plans sp
      where sp.service_id = p_service_id and sp.is_active
    ) then
      return 'SERVICE_HAS_NO_PLAN';
    end if;
    return 'PAYMENT_REQUIRED';
  end if;

  -- 5. Read the plan of that payment, deliberately WITHOUT filtering by
  -- is_active (§6.d): deactivating a plan means "not offered any more",
  -- never "the payments already made stop counting". A join with
  -- sp.is_active here would cut everyone's coverage the day the owner
  -- tidies up the price list.
  select * into v_plan from public.service_plans where id = v_payment.service_plan_id;
  if not found then
    return 'PAYMENT_REQUIRED';
  end if;

  if v_plan.plan_kind = 'UNLIMITED' then
    return 'OK';
  end if;

  -- Defensive: the CHECK makes a DROP_IN period payment impossible, so a
  -- row like that is corrupt data and must not entitle anything.
  if v_plan.plan_kind = 'DROP_IN' then
    return 'PAYMENT_REQUIRED';
  end if;

  -- WEEKLY_QUOTA: covered only for a booking that comes from one of the
  -- series the plan bought.
  if p_prospective_series then
    -- The series does not exist yet (preview): evaluated as the k+1-th
    -- in force. Without this, the preview of a standing reservation says
    -- "outside your frequency" on every date to the very customer whose
    -- plan allows it.
    v_position := public.customer_series_in_force_count(p_customer_id, p_service_id, v_local_date) + 1;
  elsif p_recurring_booking_id is not null then
    v_position := public.customer_series_quota_position(
      p_customer_id, p_service_id, v_local_date, p_recurring_booking_id
    );
  else
    -- A one-off booking under a quota plan is an extra by definition.
    return 'OUTSIDE_PLAN_QUOTA';
  end if;

  if v_position is null then
    -- The series exists but is not in force for that date, so this date
    -- is not one of the fixed slots that were bought.
    return 'OUTSIDE_PLAN_QUOTA';
  end if;

  if v_position <= v_plan.weekly_quota then
    return 'OK';
  end if;

  return 'OVER_PLAN_QUOTA';
end;
$BODY$;

comment on function public.evaluate_payment_coverage(uuid, uuid, uuid, uuid, boolean) is
  'Whether a payment covers this slot for this customer, and why not when it does not. The only implementation of the coverage rule (ADR-0024 §2.5). Never granted to authenticated: it takes a caller-supplied customer_id.';

-- The three-argument version has to go: an overload with a defaulted
-- fourth parameter would make every existing three-argument call
-- ambiguous rather than compatible.
drop function if exists public.payment_covers_slot(uuid, uuid, uuid);

create or replace function public.payment_covers_slot(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid,
  -- default null means literally "this booking does not come from a series"
  p_recurring_booking_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = public
as $BODY$
  select public.evaluate_payment_coverage(
    p_customer_id, p_service_id, p_slot_occurrence_id, p_recurring_booking_id, false
  ) = 'OK';
$BODY$;

-- ============================================================
-- 11. evaluate_customer_booking(): the same single decision function
-- ============================================================
-- Order: occurrence active and not finished -> organization -> service ->
-- is a customer -> coverage -> capacity -> duplicate. The coverage step
-- is the one that opens into four answers now.

drop function if exists public.evaluate_customer_booking(uuid, uuid);

create or replace function public.evaluate_customer_booking(
  p_slot_occurrence_id uuid,
  p_customer_id uuid,
  -- Series context, in its three forms: null/false = one-off booking;
  -- an id = an existing series; prospective = a series about to be
  -- created, evaluated as the k+1-th in force.
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
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_customer public.customers;
  v_coverage public.can_book_reason;
  v_active_count int;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  -- end_at rather than start_at on purpose, so the front desk can still
  -- add someone who walked in ten minutes late.
  if v_occurrence.end_at < now() then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  if not exists (select 1 from public.organizations where id = v_occurrence.organization_id and is_active) then
    return 'ORGANIZATION_INACTIVE';
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id and is_active;
  if not found then
    return 'SERVICE_INACTIVE';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id
      and organization_id = v_occurrence.organization_id
      and is_active;
  if not found then
    return 'NOT_A_CUSTOMER';
  end if;

  v_coverage := public.evaluate_payment_coverage(
    v_customer.id, v_service.id, p_slot_occurrence_id, p_recurring_booking_id, p_prospective_series
  );
  if v_coverage <> 'OK' then
    return v_coverage;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';
  if v_active_count >= v_occurrence.capacity then
    return 'SLOT_FULL';
  end if;

  if exists (
    select 1 from public.bookings
    where customer_id = v_customer.id and slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED'
  ) then
    return 'ALREADY_BOOKED';
  end if;

  return 'OK';
end;
$BODY$;

-- ============================================================
-- 12. book_slot() -- the lock is untouched (ADR-0004)
-- ============================================================

create or replace function public.book_slot(p_slot_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_reason public.can_book_reason;
  v_coverage public.can_book_reason;
  v_occurrence public.slot_occurrences;
  v_customer public.customers;
  v_active_count int;
  v_booking public.bookings;
begin
  v_reason := public.can_customer_book(p_slot_occurrence_id);
  if v_reason <> 'OK' then
    return jsonb_build_object('status', v_reason);
  end if;

  -- ADR-0004: the row lock is what makes two simultaneous bookings for
  -- the last seat resolve to exactly one winner. Unchanged.
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;

  select * into v_customer from public.customers
    where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  if v_active_count >= v_occurrence.capacity then
    return jsonb_build_object('status', 'SLOT_FULL');
  end if;

  -- Re-checked under the lock: staff could have voided the payment
  -- between can_customer_book() and here. A self-service booking never
  -- carries series context, so a quota plan answers OUTSIDE_PLAN_QUOTA.
  v_coverage := public.evaluate_payment_coverage(
    v_customer.id, v_occurrence.service_id, p_slot_occurrence_id, null, false
  );
  if v_coverage <> 'OK' then
    return jsonb_build_object('status', v_coverage);
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, status, created_by
  )
  values (
    v_occurrence.organization_id, v_customer.id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
  )
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  return jsonb_build_object('status', 'OK', 'booking', to_jsonb(v_booking));
end;
$BODY$;

-- ============================================================
-- 13. admin_book_for_customer(): the front desk sees the same reason
-- ============================================================

create or replace function public.admin_book_for_customer(
  p_slot_occurrence_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_customer public.customers;
  v_coverage public.can_book_reason;
  v_active_count int;
  v_booking public.bookings;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return jsonb_build_object('status', 'OCCURRENCE_NOT_AVAILABLE');
  end if;

  if not public.is_organization_member(v_occurrence.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_occurrence.organization_id and is_active;
  if not found then
    return jsonb_build_object('status', 'NOT_A_CUSTOMER');
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';
  if v_active_count >= v_occurrence.capacity then
    return jsonb_build_object('status', 'SLOT_FULL');
  end if;

  if exists (
    select 1 from public.bookings
    where customer_id = p_customer_id and slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED'
  ) then
    return jsonb_build_object('status', 'ALREADY_BOOKED');
  end if;

  -- "Their month is not paid" and "that class is outside their plan" are
  -- different sentences at the counter, with different remedies.
  v_coverage := public.evaluate_payment_coverage(
    p_customer_id, v_occurrence.service_id, p_slot_occurrence_id, null, false
  );
  if v_coverage <> 'OK' then
    return jsonb_build_object('status', v_coverage);
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, status, created_by
  )
  values (
    v_occurrence.organization_id, p_customer_id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
  )
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  return jsonb_build_object('status', 'OK', 'booking', to_jsonb(v_booking));
end;
$BODY$;

-- ============================================================
-- 14. Generation: the hard, per-date quota gate
-- ============================================================
-- This is the only gate that can be exact, because only here does "which
-- plan paid for that month" have a defined answer. A date outside the
-- quota is kept as NOT_GENERATED / OVER_PLAN_QUOTA, exactly like an
-- unpaid month is kept as NOT_GENERATED / PAYMENT_REQUIRED: a pending
-- date, not a decided one (ADR-0019), so it confirms itself if the
-- customer upgrades.

create or replace function public.generate_recurring_booking(
  p_recurring_booking_id uuid,
  p_slot_occurrence_id uuid
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rb public.recurring_bookings;
  v_occurrence public.slot_occurrences;
  v_active_count int;
  v_booking public.bookings;
  v_status public.booking_status;
  v_coverage public.can_book_reason;
  v_reason public.not_generated_reason;
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

  -- The series context is what lets a quota plan confirm this date at
  -- all: without it every date of a WEEKLY_QUOTA customer would read as
  -- an extra.
  v_coverage := public.evaluate_payment_coverage(
    v_rb.customer_id, v_occurrence.service_id, p_slot_occurrence_id, p_recurring_booking_id, false
  );

  -- Coverage is checked before capacity because it is the reason the
  -- customer can actually act on. OUTSIDE_PLAN_QUOTA collapses into
  -- OVER_PLAN_QUOTA here: a NOT_GENERATED date always comes from a
  -- series, so "this series does not fit the plan" is the whole story.
  if v_coverage = 'OK' then
    v_reason := case when v_active_count >= v_occurrence.capacity then 'SLOT_FULL' else null end;
  elsif v_coverage in ('OVER_PLAN_QUOTA', 'OUTSIDE_PLAN_QUOTA') then
    v_reason := 'OVER_PLAN_QUOTA';
  else
    v_reason := 'PAYMENT_REQUIRED';
  end if;

  v_status := case when v_reason is null then 'CONFIRMED' else 'NOT_GENERATED' end;

  begin
    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, recurring_booking_id,
      status, not_generated_reason, created_by
    )
    values (
      v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id,
      v_status, v_reason, v_rb.created_by
    )
    on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
    returning * into v_booking;
  exception
    when unique_violation then
      -- The customer already holds a CONFIRMED booking on this occurrence
      -- from elsewhere. Not a failure of the series.
      insert into public.bookings (
        organization_id, customer_id, slot_occurrence_id, recurring_booking_id,
        status, not_generated_reason, created_by
      )
      values (
        v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id,
        'NOT_GENERATED', 'DUPLICATE', v_rb.created_by
      )
      on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
      returning * into v_booking;
  end;

  return v_booking;
end;
$BODY$;

create or replace function public.retry_not_generated_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_occurrence public.slot_occurrences;
  v_rb public.recurring_bookings;
  v_active_count int;
  v_coverage public.can_book_reason;
  v_reason public.not_generated_reason;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found or v_booking.status <> 'NOT_GENERATED' or v_booking.recurring_booking_id is null then
    return v_booking;
  end if;

  select * into v_rb from public.recurring_bookings
    where id = v_booking.recurring_booking_id and status = 'ACTIVE';
  if not found then
    return v_booking;
  end if;

  -- Same lock as book_slot (ADR-0004).
  select * into v_occurrence from public.slot_occurrences
    where id = v_booking.slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.start_at < now() then
    return v_booking;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = v_occurrence.id and status = 'CONFIRMED';

  v_coverage := public.evaluate_payment_coverage(
    v_booking.customer_id, v_occurrence.service_id, v_occurrence.id, v_booking.recurring_booking_id, false
  );

  if v_coverage in ('OVER_PLAN_QUOTA', 'OUTSIDE_PLAN_QUOTA') then
    v_reason := 'OVER_PLAN_QUOTA';
  elsif v_coverage <> 'OK' then
    v_reason := 'PAYMENT_REQUIRED';
  elsif exists (
    select 1 from public.bookings
    where customer_id = v_booking.customer_id
      and slot_occurrence_id = v_occurrence.id
      and status = 'CONFIRMED'
  ) then
    v_reason := 'DUPLICATE';
  elsif v_active_count >= v_occurrence.capacity then
    v_reason := 'SLOT_FULL';
  else
    v_reason := null;
  end if;

  if v_reason is not null then
    -- Still blocked, possibly for a different reason than last time.
    -- Keep the recorded reason honest rather than stale.
    if v_reason is distinct from v_booking.not_generated_reason then
      update public.bookings set not_generated_reason = v_reason
        where id = p_booking_id
        returning * into v_booking;
    end if;
    return v_booking;
  end if;

  update public.bookings
    set status = 'CONFIRMED', not_generated_reason = null
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

-- ============================================================
-- 15. Previews: the prospective series form
-- ============================================================
-- The concrete regression this avoids: both previews used to evaluate
-- occurrence by occurrence in "one-off booking" form. Adding the quota
-- without threading the series context would make the preview of a
-- standing reservation say "outside your frequency" on every single date
-- to the customer who holds exactly the plan that allows it.

create or replace function public.preview_recurring_booking(
  p_schedule_rule_id uuid,
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
  v_customer_id uuid;
  v_identity_reason public.can_book_reason;
  v_existing_series uuid;
  v_rec record;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found then
    return;
  end if;

  -- ADR-0005: the customer comes from auth.uid(), never from the caller.
  -- Resolved once instead of per occurrence, which is what
  -- can_customer_book() was doing inside the loop.
  if auth.uid() is null then
    v_identity_reason := 'AUTH_REQUIRED';
  else
    select id into v_customer_id from public.customers
      where organization_id = v_rule.organization_id and profile_id = auth.uid() and is_active;
    if v_customer_id is null then
      v_identity_reason := 'NOT_A_CUSTOMER';
    else
      -- If the series already exists, previewing it as a *new* one would
      -- report the k+1-th position and answer OVER_PLAN_QUOTA to someone
      -- whose fixed slot this already is -- while the confirm would
      -- refuse with ALREADY_HAS_STANDING_RESERVATION. A preview showing
      -- the wrong reason is exactly what ADR-0018 exists to prevent, so
      -- the real state of the existing series is reported instead.
      v_existing_series := public.customer_standing_series_on_rule(
        v_customer_id, p_schedule_rule_id, current_date
      );
    end if;
  end if;

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
    can_book := coalesce(
      v_identity_reason,
      public.evaluate_customer_booking(
        v_rec.id,
        v_customer_id,
        v_existing_series,
        v_existing_series is null
      )
    );
    return next;
  end loop;
end;
$BODY$;

grant execute on function public.preview_recurring_booking(uuid, int) to authenticated;

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
  v_existing_series uuid;
  v_rec record;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found or not public.is_organization_member(v_rule.organization_id) then
    return;
  end if;

  -- Same correction as the customer-facing preview: when the customer
  -- already holds a standing reservation on this rule, the truth is "they
  -- already have their fixed slot here", not a quota error invented by
  -- counting the series twice. admin_create_recurring_booking() would
  -- refuse with ALREADY_HAS_STANDING_RESERVATION anyway, so a preview
  -- saying OVER_PLAN_QUOTA would send the front desk to upgrade a plan
  -- that has nothing to do with it.
  v_existing_series := public.customer_standing_series_on_rule(
    p_customer_id, p_schedule_rule_id, current_date
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
    -- No existing series: prospective, because this preview answers "can
    -- I set a standing reservation up here" and the series would be the
    -- k+1-th in force.
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

grant execute on function public.admin_preview_recurring_booking(uuid, uuid, int) to authenticated;

-- ============================================================
-- 16. The soft quota gate, when the series is created
-- ============================================================
-- Rejects the N+1 series *only* if the customer has a payment in force
-- whose plan has a quota. With no payment in force the creation is not
-- rejected: that is the front-desk flow of ADR-0018/0019 (set up the
-- standing reservation, charge afterwards) and breaking it would be a
-- regression.
--
-- It cannot be a constraint: it is an aggregate crossing
-- recurring_bookings -> schedule_rules -> services against a weekly_quota
-- reached through payments -> service_plans. Every write to
-- recurring_bookings goes through an RPC (its RLS is SELECT-only), so the
-- check here is enough; the day a plain INSERT is opened through
-- PostgREST it will also need a BEFORE INSERT trigger.

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
  v_payment public.payments;
  v_plan public.service_plans;
  v_in_force int;
begin
  select * into v_payment
  from public.payments p
  where p.customer_id = p_customer_id
    and p.service_id = p_service_id
    and p.status = 'PAID'
    and p.slot_occurrence_id is null
    and p.period_start <= p_local_date
    and p.period_end >= p_local_date
  order by p.period_start desc, p.created_at desc
  limit 1;

  if not found then
    return;
  end if;

  select * into v_plan from public.service_plans where id = v_payment.service_plan_id;
  if not found or v_plan.plan_kind <> 'WEEKLY_QUOTA' then
    return;
  end if;

  v_in_force := public.customer_series_in_force_count(p_customer_id, p_service_id, p_local_date);

  if v_in_force + 1 > v_plan.weekly_quota then
    raise exception 'OVER_PLAN_QUOTA';
  end if;
end;
$BODY$;

create or replace function public.create_recurring_booking(p_schedule_rule_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $BODY$
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

  -- One standing reservation per customer per rule, same as the
  -- front-desk path. Self-service never had this guard, and ADR-0024
  -- makes it load-bearing: "k series = k bookings a week" only holds if
  -- two series cannot follow the same weekly rule. Two of them would
  -- also generate a duplicate Booking for every occurrence.
  if public.customer_standing_series_on_rule(v_customer.id, p_schedule_rule_id, current_date) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  -- The series starts today (start_date defaults to current_date), so
  -- that is the date whose plan decides. The day these RPCs accept a
  -- start date, this becomes greatest(start_date, current_date).
  perform public.assert_series_within_plan_quota(v_customer.id, v_rule.service_id, current_date);

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
$BODY$;

grant execute on function public.create_recurring_booking(uuid) to authenticated;

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
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
  v_today date := current_date;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_rule.organization_id and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  -- One standing reservation per customer per rule: a second one would
  -- generate a duplicate Booking for every occurrence.
  --
  -- Bug fix (ADR-0024 §6.j): this used to ask only for status = 'ACTIVE'
  -- without looking at end_date, so a series that finished in June still
  -- blocked creating a new one in September. Aligned with the definition
  -- of "in force" the quota uses, which is also what makes
  -- customer_series_in_force_count() and this check agree about how many
  -- series a customer really has.
  if public.customer_standing_series_on_rule(p_customer_id, p_schedule_rule_id, v_today) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  perform public.assert_series_within_plan_quota(p_customer_id, v_rule.service_id, v_today);

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by)
  values (v_rule.organization_id, p_customer_id, p_schedule_rule_id, auth.uid())
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

grant execute on function public.admin_create_recurring_booking(uuid, uuid) to authenticated;

-- ============================================================
-- 17. billing_period_for(): the cycle now belongs to the plan
-- ============================================================
-- This is about *writing* a payment, not reading one: coverage is always
-- "is the slot's date inside the paid period" regardless of cycle. The
-- cycle only decides which period a payment made on a given day buys --
-- and that configuration moved from the Service to the plan, because one
-- service now has a ONE_TIME plan and three MONTHLY ones.

drop function if exists public.billing_period_for(uuid, date);

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
begin
  select * into v_plan from public.service_plans where id = p_service_plan_id;
  if not found then
    return;
  end if;

  if v_plan.billing_type = 'MONTHLY' and v_plan.billing_cycle = 'CALENDAR_MONTH' then
    -- Paying on the 15th still covers the 1st to the last day.
    period_start := date_trunc('month', p_from)::date;
    period_end := (date_trunc('month', p_from) + interval '1 month - 1 day')::date;
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

grant execute on function public.billing_period_for(uuid, date) to authenticated;

-- ============================================================
-- 18. The front desk has to see what it sold (§6.b)
-- ============================================================
-- Dropping a customer to a smaller plan cancels no series: the extra ones
-- self-limit into NOT_GENERATED / OVER_PLAN_QUOTA and ADR-0019 puts them
-- back if the customer upgrades again. Which is invisible unless this
-- screen counts them -- "this person has 3 series and their plan covers
-- 1" is the whole point.
--
-- Note the ::text comparison: OVER_PLAN_QUOTA was added to the enum in
-- this same transaction, and this is a SQL-language body (parsed at
-- CREATE time), so the literal cannot be resolved as an enum yet.

drop function if exists public.schedule_rule_standing_reservations(uuid);

create function public.schedule_rule_standing_reservations(p_schedule_rule_id uuid)
returns table (
  recurring_booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    rb.id,
    rb.customer_id,
    coalesce(p.full_name, 'Sin nombre'),
    rb.status,
    rb.created_at,
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'CONFIRMED' and so.start_at >= now()),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED' and so.start_at >= now()),
    -- Split out because it is the only one the front desk can fix by
    -- charging: "cobrale el mes".
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()),
    -- The fix for this one is different: upgrade the plan or drop a
    -- series. Charging the month again does nothing.
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason::text = 'OVER_PLAN_QUOTA' and so.start_at >= now())
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, p.full_name asc;
$BODY$;

grant execute on function public.schedule_rule_standing_reservations(uuid) to authenticated;

-- ============================================================
-- 19. Row Level Security: a price list is public
-- ============================================================
-- Same reasoning as public.plans (Phase 10): the business's public page
-- shows what it charges, and a visitor with no session has to be able to
-- read it. Nothing private joins from here -- a service_plan says what is
-- on sale, never who bought it; who bought it lives in payments, which
-- stays private (Phase 7).
-- Writes are organization members only, and there is deliberately no
-- DELETE policy: a plan is deactivated, never deleted (the payments FK is
-- ON DELETE RESTRICT for the same reason).

alter table public.service_plans enable row level security;

create policy service_plans_select_public
  on public.service_plans for select
  using (true);

create policy service_plans_insert_staff
  on public.service_plans for insert
  with check (public.is_organization_member(organization_id));

create policy service_plans_update_staff
  on public.service_plans for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

grant select on public.service_plans to anon, authenticated;
grant insert, update on public.service_plans to authenticated;

-- ============================================================
-- 20. Deprecations
-- ============================================================
-- Kept, no longer read by the decision or the charging path. Without
-- moving the billing period up to the plan there would be two sources of
-- truth for "what period does a payment buy", and they diverge the first
-- day one service has a calendar plan and another a rolling one.
-- services.payment_required is NOT deprecated: it is the "does this
-- service require payment at all" switch, not a price.

comment on column public.services.billing_type is
  'DEPRECATED (ADR-0024). The billing period belongs to service_plans; kept for historical rows and for the UNLIMITED plan the migration derived from it.';

comment on column public.services.billing_cycle is
  'DEPRECATED (ADR-0024). See service_plans.billing_cycle.';

comment on column public.services.price is
  'DEPRECATED (ADR-0024). A service has several simultaneous prices now; see service_plans.price.';

notify pgrst, 'reload schema';
