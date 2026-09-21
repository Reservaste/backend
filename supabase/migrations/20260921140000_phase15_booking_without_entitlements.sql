-- Phase 15: booking decided by payment coverage, not by manual enablement
-- Ref: docs/decisions.md ADR-0022 (supersedes most of ADR-0013)
--
-- Phase 14 put the columns in place without changing any decision. This
-- one moves the decision: a customer of the organization may book an
-- active service, and the only thing that can stop them (besides
-- capacity and duplicates) is a service that requires payment with no
-- payment covering that slot's date.

-- ============================================================
-- Reason codes
-- ============================================================
-- not_generated_reason said NO_ENTITLEMENT for what was always, in
-- practice, "the month is not paid". Renaming rather than adding keeps
-- existing rows meaningful instead of stranding them on a dead value.

alter type public.not_generated_reason rename value 'NO_ENTITLEMENT' to 'PAYMENT_REQUIRED';

-- can_book_reason keeps its NO_ENTITLEMENT value: dropping an enum value
-- means recreating the type and every function that returns it, for no
-- behavioural gain. It is simply never emitted again.
comment on type public.can_book_reason is
  'NO_ENTITLEMENT is deprecated and no longer emitted (ADR-0022); PAYMENT_REQUIRED covers that case.';

-- ============================================================
-- The slot's date, as the business counts it
-- ============================================================
-- ADR-0014: the organization's timezone decides which calendar day a
-- 23:30 class belongs to, not UTC. Extracted because payment coverage,
-- booking and the payments screens all need the same answer.

create or replace function public.slot_local_date(p_slot_occurrence_id uuid)
returns date
language sql
stable
security definer
set search_path = public
as $BODY$
  select (so.start_at at time zone o.timezone)::date
  from public.slot_occurrences so
  join public.organizations o on o.id = so.organization_id
  where so.id = p_slot_occurrence_id;
$BODY$;

-- ============================================================
-- billing_period_for(): where the two monthly cycles actually live
-- ============================================================
-- Note this is about *writing* a payment, not reading one. Coverage is
-- always "is the slot's date inside the paid period" regardless of cycle;
-- the cycle only decides which period a payment made on a given day
-- buys. Keeping that distinction is what stops the booking path from
-- having to know about billing modes at all.

create or replace function public.billing_period_for(
  p_service_id uuid,
  p_from date
)
returns table (period_start date, period_end date)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
begin
  select * into v_service from public.services where id = p_service_id;
  if not found then
    return;
  end if;

  if v_service.billing_type = 'MONTHLY' and v_service.billing_cycle = 'CALENDAR_MONTH' then
    -- Paying on the 15th still covers the 1st to the last day.
    period_start := date_trunc('month', p_from)::date;
    period_end := (date_trunc('month', p_from) + interval '1 month - 1 day')::date;
  elsif v_service.billing_type = 'MONTHLY' then
    -- ROLLING_MONTH: paying on the 15th covers through the 14th of next
    -- month. Postgres clamps 31 Jan + 1 month to 28 Feb on its own, which
    -- is the behaviour a person would expect.
    period_start := p_from;
    period_end := (p_from + interval '1 month - 1 day')::date;
  else
    -- ONE_TIME and FREE have no recurring period; a payment covers the
    -- single day it was made for unless the caller says otherwise.
    period_start := p_from;
    period_end := p_from;
  end if;

  return next;
end;
$BODY$;

grant execute on function public.billing_period_for(uuid, date) to authenticated;

-- ============================================================
-- payment_covers_slot(): the single source of truth for point 15
-- ============================================================
-- Validated against the SLOT's date, never against "today" -- the one
-- part of ADR-0013 that survives intact, because it is the easy mistake:
-- a payment that is current right now says nothing about a class three
-- weeks out.

create or replace function public.payment_covers_slot(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_local_date date;
begin
  select * into v_service from public.services where id = p_service_id;
  if not found then
    return false;
  end if;

  -- A service nobody has to pay for is always covered. This is what makes
  -- manual enablement unnecessary rather than merely optional.
  if not v_service.payment_required then
    return true;
  end if;

  v_local_date := public.slot_local_date(p_slot_occurrence_id);
  if v_local_date is null then
    return false;
  end if;

  return exists (
    select 1 from public.payments p
    where p.customer_id = p_customer_id
      and p.service_id = p_service_id
      and p.status = 'PAID'
      and p.period_start <= v_local_date
      and p.period_end >= v_local_date
  );
end;
$BODY$;

-- ============================================================
-- evaluate_customer_booking(): the rule, without the entitlement
-- ============================================================

create or replace function public.evaluate_customer_booking(
  p_slot_occurrence_id uuid,
  p_customer_id uuid
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
  v_active_count int;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  -- A class that already ended cannot take new bookings: that is not a
  -- reservation, it is backdating attendance. The cutoff is end_at rather
  -- than start_at on purpose, so the front desk can still add someone who
  -- walked in ten minutes late.
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

  if not public.payment_covers_slot(v_customer.id, v_service.id, p_slot_occurrence_id) then
    return 'PAYMENT_REQUIRED';
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
-- book_slot(): same concurrency guarantee, simpler decision
-- ============================================================

create or replace function public.book_slot(p_slot_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_reason public.can_book_reason;
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
  -- the last seat resolve to exactly one winner.
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
  -- between can_customer_book() and here.
  if not public.payment_covers_slot(v_customer.id, v_occurrence.service_id, p_slot_occurrence_id) then
    return jsonb_build_object('status', 'PAYMENT_REQUIRED');
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
-- cancel_booking(): no credits left to restore
-- ============================================================

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason public.booking_cancellation_reason default 'CUSTOMER_REQUEST'
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_customer public.customers;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'BOOKING_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_booking.customer_id;

  if v_customer.profile_id <> auth.uid() and not public.is_organization_member(v_booking.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_booking.status = 'CANCELLED' then
    return v_booking;
  end if;

  -- Attendance already marked is left alone: cancelling a booking after
  -- the fact does not un-happen someone having shown up (ADR-0022).
  update public.bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

-- ============================================================
-- generate_recurring_booking(): payment instead of entitlement
-- ============================================================

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

  -- Payment is checked before capacity because it is the reason the
  -- customer can actually act on.
  v_reason := case
    when not public.payment_covers_slot(v_rb.customer_id, v_occurrence.service_id, p_slot_occurrence_id)
      then 'PAYMENT_REQUIRED'
    when v_active_count >= v_occurrence.capacity then 'SLOT_FULL'
    else null
  end;
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
      -- from elsewhere. Not a failure of the series -- they are going to
      -- the class either way.
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

-- ============================================================
-- retry_not_generated_booking(): same, payment-anchored
-- ============================================================

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

  select * into v_occurrence from public.slot_occurrences
    where id = v_booking.slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.start_at < now() then
    return v_booking;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = v_occurrence.id and status = 'CONFIRMED';

  v_reason := case
    when not public.payment_covers_slot(v_booking.customer_id, v_occurrence.service_id, v_occurrence.id)
      then 'PAYMENT_REQUIRED'
    when exists (
      select 1 from public.bookings
      where customer_id = v_booking.customer_id
        and slot_occurrence_id = v_occurrence.id
        and status = 'CONFIRMED'
    ) then 'DUPLICATE'
    when v_active_count >= v_occurrence.capacity then 'SLOT_FULL'
    else null
  end;

  if v_reason is not null then
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
-- Reconciliation triggers (ADR-0019), re-anchored
-- ============================================================
-- The entitlement trigger goes away with the entitlement. Payments are
-- now the only write that can widen what a customer may book, plus
-- services.payment_required being switched off.

drop trigger if exists service_entitlements_reconcile_pending on public.service_entitlements;
drop trigger if exists service_entitlements_reconcile_on_grant on public.service_entitlements;
drop function if exists public.reconcile_after_entitlement_change();

create or replace function public.reconcile_after_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  perform public.reconcile_pending_recurring_bookings(new.customer_id, new.service_id);
  return null;
end;
$BODY$;

create or replace function public.reconcile_after_service_billing_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer_id uuid;
begin
  for v_customer_id in
    select distinct b.customer_id
    from public.bookings b
    join public.slot_occurrences so on so.id = b.slot_occurrence_id
    where so.service_id = new.id
      and b.status = 'NOT_GENERATED'
      and so.start_at >= now()
  loop
    perform public.reconcile_pending_recurring_bookings(v_customer_id, new.id);
  end loop;
  return null;
end;
$BODY$;

-- Only fires when the service stops requiring payment: the opposite
-- direction narrows access and must not retroactively cancel anything.
create trigger services_reconcile_on_payment_not_required
  after update on public.services
  for each row
  when (old.payment_required and not new.payment_required)
  execute function public.reconcile_after_service_billing_change();

-- ============================================================
-- Customer portal: services instead of entitlements
-- ============================================================

drop function if exists public.my_entitlements();

create or replace function public.my_services()
returns table (
  service_id uuid,
  service_name text,
  organization_slug text,
  organization_name text,
  billing_type public.billing_type,
  billing_cycle public.billing_cycle,
  price numeric,
  payment_required boolean,
  covered_until date,
  is_covered_today boolean
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    s.id,
    s.name,
    o.slug,
    o.name,
    s.billing_type,
    s.billing_cycle,
    s.price,
    s.payment_required,
    (select max(p.period_end) from public.payments p
      where p.customer_id = c.id and p.service_id = s.id and p.status = 'PAID'),
    not s.payment_required or exists (
      select 1 from public.payments p
      where p.customer_id = c.id and p.service_id = s.id and p.status = 'PAID'
        and p.period_start <= (now() at time zone o.timezone)::date
        and p.period_end >= (now() at time zone o.timezone)::date
    )
  from public.customers c
  join public.organizations o on o.id = c.organization_id
  join public.services s on s.organization_id = o.id and s.is_active
  where c.profile_id = auth.uid() and c.is_active
  order by o.name asc, s.name asc;
$BODY$;

grant execute on function public.my_services() to authenticated;

-- my_payments(): says which service, which is the whole point of the
-- payments screens.
drop function if exists public.my_payments();

create or replace function public.my_payments()
returns table (
  payment_id uuid,
  organization_name text,
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
    p.id,
    o.name,
    s.name,
    p.period_start,
    p.period_end,
    p.status,
    p.amount,
    p.created_at
  from public.payments p
  join public.customers c on c.id = p.customer_id and c.profile_id = auth.uid()
  join public.organizations o on o.id = p.organization_id
  join public.services s on s.id = p.service_id
  order by p.period_start desc;
$BODY$;

grant execute on function public.my_payments() to authenticated;

-- ============================================================
-- Retiring the entitlement path
-- ============================================================
-- The bridge from Phase 14 has nothing left to bridge, and the two
-- resolver functions are what the booking path used to call. The table
-- itself stays (ADR-0022): historical provenance, no longer consulted.

drop trigger if exists payments_fill_service_id on public.payments;
drop function if exists public.fill_payment_service_from_entitlement();
drop function if exists public.resolve_bookable_entitlement(uuid, uuid, uuid);
drop function if exists public.entitlement_payment_satisfied(uuid, date);

-- bookings.service_entitlement_id stops being written. Kept so existing
-- rows retain which entitlement paid for them.
comment on column public.bookings.service_entitlement_id is
  'DEPRECATED (ADR-0022). No longer written; kept for historical rows.';

-- ============================================================
-- Callers that still reached for the entitlement
-- ============================================================

-- The cross-tenant guard validated the payment against its entitlement's
-- organization. With the payment anchored to a service, the service is
-- what has to belong to the same organization -- otherwise a crafted
-- insert could attach one organization's payment to another's service.
create or replace function public.check_payment_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_customer_org uuid;
  v_service_org uuid;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  select organization_id into v_service_org from public.services where id = new.service_id;

  if v_customer_org is null or v_service_org is null
     or v_customer_org <> new.organization_id
     or v_service_org <> new.organization_id then
    raise exception 'Payment organization_id must match its Customer and Service';
  end if;

  return new;
end;
$BODY$;

-- admin_book_for_customer(): the front-desk counterpart. Same rule as
-- self-service, asked on someone else's behalf (ADR-0018); authorization
-- is organization membership, not ownership of the booking.
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

  -- Staff sees the same reason a customer would, so the front desk can
  -- say "their month is not paid" instead of a generic refusal.
  if not public.payment_covers_slot(p_customer_id, v_occurrence.service_id, p_slot_occurrence_id) then
    return jsonb_build_object('status', 'PAYMENT_REQUIRED');
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

-- schedule_rule_standing_reservations() counted the "waiting on payment"
-- dates by the old enum value, which the rename above left dangling --
-- the function compiled but failed at call time. Recreated with the
-- current name.
create or replace function public.schedule_rule_standing_reservations(p_schedule_rule_id uuid)
returns table (
  recurring_booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int
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
    -- Split out because it is the only one the front desk can fix, and
    -- the fix is "cobrale el mes".
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now())
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, p.full_name asc;
$BODY$;

grant execute on function public.schedule_rule_standing_reservations(uuid) to authenticated;
