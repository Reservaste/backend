-- Phase 12: pending dates reconcile themselves when the payment lands
-- Ref: docs/decisions.md ADR-0013, ADR-0018, ADR-0019
--
-- Phase 11 made a standing reservation self-limiting: an unpaid month
-- leaves each upcoming date as NOT_GENERATED instead of confirming it.
-- The other half was missing. Nothing re-evaluated those dates, so
-- registering the payment left them pending forever and the front desk
-- had to delete and recreate the series to unblock it.
--
-- The rule: a date that could not be confirmed is a *pending* date, not a
-- decided one. Anything that changes whether the customer may book --
-- a payment, a renewed membership, a credit top-up -- re-asks the
-- question for every upcoming pending date of that customer.

-- ============================================================
-- retry_not_generated_booking()
-- ============================================================
-- Deliberately an UPDATE of the existing row rather than a new insert:
-- generate_recurring_booking() is idempotent via ON CONFLICT DO NOTHING,
-- so re-running it over an already-recorded date is a no-op and would
-- never revisit its status. The date keeps its identity -- the customer
-- sees the same Monday change from pending to confirmed.

create or replace function public.retry_not_generated_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_occurrence public.slot_occurrences;
  v_rb public.recurring_bookings;
  v_entitlement_id uuid;
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

  -- Same lock as book_slot (ADR-0004): the capacity check below decides
  -- whether a seat is taken, so it cannot race another booking.
  select * into v_occurrence from public.slot_occurrences
    where id = v_booking.slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.start_at < now() then
    return v_booking;
  end if;

  v_entitlement_id := public.resolve_bookable_entitlement(
    v_booking.customer_id, v_occurrence.service_id, v_occurrence.id
  );

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = v_occurrence.id and status = 'CONFIRMED';

  v_reason := case
    when v_entitlement_id is null then 'NO_ENTITLEMENT'
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
    -- Still blocked, but possibly for a different reason than last time
    -- (the month got paid and meanwhile the class filled up). Keep the
    -- recorded reason honest rather than stale.
    if v_reason is distinct from v_booking.not_generated_reason then
      update public.bookings set not_generated_reason = v_reason
        where id = p_booking_id
        returning * into v_booking;
    end if;
    return v_booking;
  end if;

  update public.bookings
    set status = 'CONFIRMED',
        service_entitlement_id = v_entitlement_id,
        not_generated_reason = null
    where id = p_booking_id
    returning * into v_booking;

  if v_entitlement_id is not null then
    update public.service_entitlements
      set credits_remaining = credits_remaining - 1
      where id = v_entitlement_id and entitlement_type = 'CREDITS';
  end if;

  return v_booking;
end;
$$;

-- ============================================================
-- reconcile_pending_recurring_bookings()
-- ============================================================

create or replace function public.reconcile_pending_recurring_bookings(
  p_customer_id uuid,
  p_service_id uuid default null
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_confirmed int := 0;
  v_result public.bookings;
begin
  -- Chronological order matters for a CREDITS entitlement: a customer
  -- with two credits and five pending Mondays gets the next two, not an
  -- arbitrary pair.
  for v_booking_id in
    select b.id
    from public.bookings b
    join public.slot_occurrences so on so.id = b.slot_occurrence_id
    join public.recurring_bookings rb on rb.id = b.recurring_booking_id
    where b.customer_id = p_customer_id
      and b.status = 'NOT_GENERATED'
      and rb.status = 'ACTIVE'
      and so.start_at >= now()
      and (p_service_id is null or so.service_id = p_service_id)
    order by so.start_at asc
  loop
    v_result := public.retry_not_generated_booking(v_booking_id);
    if v_result.status = 'CONFIRMED' then
      v_confirmed := v_confirmed + 1;
    end if;
  end loop;

  return v_confirmed;
end;
$$;

-- ============================================================
-- Triggers: the two writes that can unblock a pending date
-- ============================================================

create or replace function public.reconcile_after_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ent public.service_entitlements;
begin
  select * into v_ent from public.service_entitlements where id = new.service_entitlement_id;
  if found then
    perform public.reconcile_pending_recurring_bookings(v_ent.customer_id, v_ent.service_id);
  end if;
  return null;
end;
$$;

create trigger payments_reconcile_pending
  after insert or update on public.payments
  for each row
  when (new.status = 'PAID')
  execute function public.reconcile_after_payment();

create or replace function public.reconcile_after_entitlement_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.reconcile_pending_recurring_bookings(new.customer_id, new.service_id);
  return null;
end;
$$;

-- Only fires on changes that can *widen* what the customer may book.
-- Spending a credit narrows it (credits_remaining decreases) and is
-- excluded here -- that is what stops retry_not_generated_booking() from
-- re-entering itself through its own credit update.
create trigger service_entitlements_reconcile_pending
  after update on public.service_entitlements
  for each row
  when (
    (new.is_active and not old.is_active)
    or new.credits_remaining > old.credits_remaining
    or new.valid_until is distinct from old.valid_until
    or new.valid_from is distinct from old.valid_from
  )
  execute function public.reconcile_after_entitlement_change();

-- Granting the entitlement is the other way a blocked series gets
-- unblocked: the front desk sets up the standing reservation first and
-- enables the service afterwards, which leaves every date NO_ENTITLEMENT
-- until this runs.
create trigger service_entitlements_reconcile_on_grant
  after insert on public.service_entitlements
  for each row
  when (new.is_active)
  execute function public.reconcile_after_entitlement_change();

-- ============================================================
-- Freed capacity is deliberately NOT reconciled here
-- ============================================================
-- When someone cancels and a seat opens up, deciding who gets it --
-- the standing reservation that was bumped, or whoever books first --
-- is a fairness policy, not a bug fix. It needs its own decision
-- (ADR-0019 records this as open). Today the seat simply returns to the
-- public calendar, first come first served, which is the behaviour the
-- booking engine has had since Phase 5.
