-- Phase 14: billing config on Service, attendance on Booking, schedule
-- rule groups. Ref: docs/decisions.md ADR-0022.
--
-- Deliberately additive. Nothing in the booking decision path changes
-- here -- this migration only puts the columns in place and backfills
-- them from what ServiceEntitlement means today, so that the next phase
-- can move the decision itself without also inventing the data.

-- ============================================================
-- Enums
-- ============================================================

create type public.billing_type as enum ('FREE', 'ONE_TIME', 'MONTHLY');

-- The two ways a month is counted. CALENDAR_MONTH: paying on the 15th
-- still covers the 1st to the 30th. ROLLING_MONTH: paying on the 15th
-- covers through the 14th of the next month. Neither is "the right one"
-- -- a gym uses the first, personal training tends to use the second.
create type public.billing_cycle as enum ('CALENDAR_MONTH', 'ROLLING_MONTH');

-- Attendance is deliberately NOT a booking status (ADR-0022): "reserved
-- and did not show up" is a real, valid combination that a single status
-- column cannot express.
create type public.attendance_status as enum ('PENDING', 'PRESENT', 'ABSENT');

-- ============================================================
-- services: economic configuration
-- ============================================================

alter table public.services
  add column if not exists billing_type public.billing_type not null default 'FREE',
  add column if not exists billing_cycle public.billing_cycle,
  add column if not exists price numeric(12, 2),
  add column if not exists payment_required boolean not null default false,
  -- Used by the calendar to tell services apart at a glance. Same format
  -- rule as the organization brand colour (ADR-0020): it lands in a CSS
  -- custom property, so a free-form string here is a style injection.
  add column if not exists color text;

comment on column public.services.payment_required is
  'Whether booking requires a Payment covering the slot date. Replaces service_entitlements.requires_active_payment (ADR-0022).';

-- ============================================================
-- payments: anchored to the service, not to an entitlement
-- ============================================================
-- ADR-0013 tied a Payment to a ServiceEntitlement. With manual
-- enablement gone (ADR-0022) that indirection has nothing left to point
-- at, and "which service is this payment for" becomes unanswerable --
-- which is exactly what the payments screens have to show.

alter table public.payments
  add column if not exists service_id uuid references public.services (id) on delete cascade;

alter table public.payments
  alter column service_entitlement_id drop not null;

comment on column public.payments.service_entitlement_id is
  'DEPRECATED (ADR-0022). Kept so existing rows retain their provenance; new payments set service_id instead.';

-- ============================================================
-- bookings: attendance
-- ============================================================

alter table public.bookings
  add column if not exists attendance_status public.attendance_status not null default 'PENDING',
  add column if not exists attendance_marked_at timestamptz,
  add column if not exists attendance_marked_by uuid references public.profiles (id);

comment on column public.bookings.attendance_status is
  'Whether the person actually showed up. Independent of status: a CONFIRMED booking with ABSENT attendance is the normal no-show case (ADR-0022).';

-- ============================================================
-- schedule_rules: grouping
-- ============================================================
-- One rule per weekday stays (ADR-0022): a weekdays[] column would break
-- ScheduleException, which is keyed by rule + date, and the cascade in
-- discontinue_schedule_rule. The group is what makes "Mon/Wed/Fri 09:00"
-- one thing in the UI without the model pretending it is one row.
--
-- Every rule gets a group, existing ones included: a nullable "ungrouped"
-- case would mean every read path needs a branch for it.

alter table public.schedule_rules
  add column if not exists group_id uuid;

update public.schedule_rules set group_id = gen_random_uuid() where group_id is null;

alter table public.schedule_rules
  alter column group_id set not null,
  alter column group_id set default gen_random_uuid();

create index if not exists schedule_rules_group_idx on public.schedule_rules (group_id);

-- ============================================================
-- Backfill
-- ============================================================
-- A faithful translation of what each service means today, so behaviour
-- is unchanged when the next phase switches the decision over: a service
-- that had any payment-gated entitlement becomes a paid monthly service,
-- anything else becomes free to book.

update public.services s
set billing_type = 'MONTHLY',
    billing_cycle = 'CALENDAR_MONTH',
    payment_required = true
where exists (
  select 1 from public.service_entitlements se
  where se.service_id = s.id and se.requires_active_payment and se.is_active
);

update public.payments p
set service_id = se.service_id
from public.service_entitlements se
where p.service_entitlement_id = se.id and p.service_id is null;

-- A payment whose entitlement is gone has nothing to attach to. There
-- should be none (the FK cascades), and failing loudly here beats a
-- silently orphaned payment.
alter table public.payments
  alter column service_id set not null;

-- Transitional bridge: callers that still insert a payment the old way
-- (entitlement only) keep working, because this phase promised to change
-- no behaviour. Without it, making service_id NOT NULL breaks every
-- existing insert path at once, which is the opposite of a two-step
-- migration. Removed in the phase that drops the entitlement path.
create or replace function public.fill_payment_service_from_entitlement()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if new.service_id is null and new.service_entitlement_id is not null then
    select se.service_id into new.service_id
      from public.service_entitlements se
      where se.id = new.service_entitlement_id;
  end if;
  return new;
end;
$BODY$;

create trigger payments_fill_service_id
  before insert or update on public.payments
  for each row
  execute function public.fill_payment_service_from_entitlement();

-- ============================================================
-- Constraints, after the backfill so existing rows are judged by the
-- values they were just given rather than by their defaults
-- ============================================================

alter table public.services
  add constraint services_billing_cycle_matches_type check (
    (billing_type = 'MONTHLY' and billing_cycle is not null)
    or (billing_type <> 'MONTHLY' and billing_cycle is null)
  ),
  add constraint services_price_non_negative check (price is null or price >= 0),
  add constraint services_color_format check (color is null or color ~ '^#[0-9a-f]{6}$'),
  -- A free service that requires payment is not a configuration, it is a
  -- dead end: nobody could ever book it.
  add constraint services_payment_requires_priced_type check (
    not payment_required or billing_type <> 'FREE'
  );

alter table public.bookings
  add constraint bookings_attendance_marked_consistently check (
    (attendance_status = 'PENDING' and attendance_marked_at is null)
    or (attendance_status <> 'PENDING' and attendance_marked_at is not null)
  );

-- The double-charge rule of ADR-0013 survives the move, re-anchored:
-- overlapping PAID periods for the same customer and service mean the
-- same month was charged twice.
alter table public.payments
  drop constraint if exists payments_no_overlapping_paid;

alter table public.payments
  add constraint payments_no_overlapping_paid exclude using gist (
    customer_id with =,
    service_id with =,
    daterange(period_start, period_end, '[]') with &&
  ) where (status = 'PAID');

create index if not exists payments_customer_service_idx
  on public.payments (customer_id, service_id, period_start, period_end)
  where status = 'PAID';

-- ============================================================
-- Colour normalization, same rule as organization branding
-- ============================================================

create or replace function public.normalize_service_color()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  new.color := nullif(lower(trim(new.color)), '');
  return new;
end;
$BODY$;

create trigger services_normalize_color
  before insert or update on public.services
  for each row
  execute function public.normalize_service_color();

comment on table public.service_entitlements is
  'DEPRECATED (ADR-0022). Manual per-customer service enablement was removed from the product; the table is kept for historical provenance and is no longer consulted when booking.';
