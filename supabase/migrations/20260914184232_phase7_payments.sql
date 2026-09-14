-- Phase 7: Payments
-- Ref: docs/decisions.md ADR-0013; docs/domain.md
--
-- Closes the TODO left in can_customer_book() by Phase 5: when a
-- ServiceEntitlement is TIME-based and requires_active_payment is true,
-- booking now also requires a PAID Payment whose period covers the
-- *slot's* local date -- never "today". That distinction is the single
-- easiest thing to implement wrong here (ADR-0013): reserving on 14/09 a
-- class that happens on 05/10 must check October's payment, not
-- September's.
--
-- Also implements credit consumption, which domain.md specified from the
-- start but no phase had built: a CREDITS entitlement is decremented when
-- a Booking is confirmed and restored when it's cancelled.

create extension if not exists btree_gist with schema public;

-- ============================================================
-- payments
-- ============================================================

create type public.payment_status as enum ('PAID', 'PENDING', 'OVERDUE', 'VOID');

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  -- ADR-0013: linked to the entitlement, not the service -- one
  -- entitlement can cover several services, and a single payment covers
  -- the entitlement rather than being duplicated per service.
  service_entitlement_id uuid not null references public.service_entitlements (id) on delete cascade,
  period_start date not null,
  period_end date not null,
  status public.payment_status not null default 'PAID',
  amount numeric(12, 2),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  constraint payments_valid_period check (period_end >= period_start),
  -- Gaps between periods are a valid, expected state (the customer simply
  -- didn't pay that stretch -- ADR-0013), so there is deliberately no
  -- constraint forcing continuous coverage. Overlapping PAID periods for
  -- the same entitlement are a different matter: that means a double
  -- charge was entered, so it is rejected.
  constraint payments_no_overlapping_paid exclude using gist (
    service_entitlement_id with =,
    daterange(period_start, period_end, '[]') with &&
  ) where (status = 'PAID')
);

comment on table public.payments is
  'An economic movement for a Customer''s ServiceEntitlement over a period. Separate from the right to use the service -- see docs/domain.md (pago != permiso).';

create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

create index payments_organization_idx on public.payments (organization_id);
create index payments_customer_idx on public.payments (customer_id);
create index payments_entitlement_period_idx on public.payments (service_entitlement_id, period_start, period_end);

create or replace function public.check_payment_same_org()
returns trigger
language plpgsql
as $$
declare
  v_customer_org uuid;
  v_entitlement record;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  select organization_id, customer_id into v_entitlement
    from public.service_entitlements where id = new.service_entitlement_id;

  if v_customer_org is null or v_entitlement.organization_id is null
     or v_customer_org <> new.organization_id
     or v_entitlement.organization_id <> new.organization_id then
    raise exception 'Payment organization_id must match its Customer and ServiceEntitlement';
  end if;

  if v_entitlement.customer_id <> new.customer_id then
    raise exception 'Payment customer_id must match the ServiceEntitlement it pays for';
  end if;

  return new;
end;
$$;

create trigger payments_same_org
  before insert or update on public.payments
  for each row execute function public.check_payment_same_org();

-- ============================================================
-- Entitlement resolution: which entitlement (if any) lets this customer
-- book this occurrence, and is it paid for?
-- ============================================================

-- ADR-0013: a CREDITS entitlement is self-evidently paid (the package was
-- bought up front), and requires_active_payment = false is the
-- courtesy/beca case. Only a TIME entitlement that demands payment has to
-- find a covering PAID period.
create or replace function public.entitlement_payment_satisfied(
  p_entitlement_id uuid,
  p_local_date date
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ent public.service_entitlements;
begin
  select * into v_ent from public.service_entitlements where id = p_entitlement_id;
  if not found then
    return false;
  end if;

  if v_ent.entitlement_type = 'CREDITS' or not v_ent.requires_active_payment then
    return true;
  end if;

  return exists (
    select 1 from public.payments p
    where p.service_entitlement_id = v_ent.id
      and p.status = 'PAID'
      and p.period_start <= p_local_date
      and p.period_end >= p_local_date
  );
end;
$$;

-- Returns the entitlement that should be used to book this occurrence, or
-- null if none qualifies. TIME entitlements are preferred over CREDITS so
-- an active membership is used before eating into a prepaid class pack --
-- an MVP product choice, documented here because it is a choice, not a
-- law of the domain.
create or replace function public.resolve_bookable_entitlement(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_local_date date;
  v_ent public.service_entitlements;
begin
  -- The slot's calendar date as the business sees it (ADR-0013 +
  -- ADR-0014): the organization's timezone decides which day a 23:30
  -- class belongs to, not UTC.
  select (so.start_at at time zone o.timezone)::date
    into v_local_date
    from public.slot_occurrences so
    join public.organizations o on o.id = so.organization_id
    where so.id = p_slot_occurrence_id;

  if v_local_date is null then
    return null;
  end if;

  for v_ent in
    select * from public.service_entitlements se
    where se.customer_id = p_customer_id
      and se.service_id = p_service_id
      and se.is_active
      and (
        (se.entitlement_type = 'TIME'
          and se.valid_from <= v_local_date
          and (se.valid_until is null or se.valid_until >= v_local_date))
        or
        (se.entitlement_type = 'CREDITS' and se.credits_remaining > 0)
      )
    order by case when se.entitlement_type = 'TIME' then 0 else 1 end, se.created_at asc
  loop
    if public.entitlement_payment_satisfied(v_ent.id, v_local_date) then
      return v_ent.id;
    end if;
  end loop;

  return null;
end;
$$;

-- ============================================================
-- can_customer_book(): now distinguishes "you don't have this service"
-- from "your payment doesn't cover that date" -- the customer-facing
-- difference between those two is the whole point of separating
-- entitlement from payment (docs/domain.md).
-- ============================================================

alter type public.can_book_reason add value 'PAYMENT_REQUIRED';

create or replace function public.can_customer_book(p_slot_occurrence_id uuid)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_customer public.customers;
  v_entitlement_id uuid;
  v_local_date date;
  v_has_any_entitlement boolean;
  v_active_count int;
begin
  if auth.uid() is null then
    return 'AUTH_REQUIRED';
  end if;

  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  if not exists (select 1 from public.organizations where id = v_occurrence.organization_id and is_active) then
    return 'ORGANIZATION_INACTIVE';
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id and is_active;
  if not found then
    return 'SERVICE_INACTIVE';
  end if;

  -- ADR-0005: resolved from (organization_id, auth.uid()), never a
  -- caller-supplied customerId.
  select * into v_customer from public.customers
    where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;
  if not found then
    return 'NOT_A_CUSTOMER';
  end if;

  v_entitlement_id := public.resolve_bookable_entitlement(v_customer.id, v_service.id, p_slot_occurrence_id);

  if v_entitlement_id is null then
    select (so.start_at at time zone o.timezone)::date
      into v_local_date
      from public.slot_occurrences so
      join public.organizations o on o.id = so.organization_id
      where so.id = p_slot_occurrence_id;

    select exists (
      select 1 from public.service_entitlements se
      where se.customer_id = v_customer.id
        and se.service_id = v_service.id
        and se.is_active
        and (
          (se.entitlement_type = 'TIME'
            and se.valid_from <= v_local_date
            and (se.valid_until is null or se.valid_until >= v_local_date))
          or
          (se.entitlement_type = 'CREDITS' and se.credits_remaining > 0)
        )
    ) into v_has_any_entitlement;

    -- Had a live entitlement but none of them were paid up for that date.
    return case when v_has_any_entitlement then 'PAYMENT_REQUIRED' else 'NO_ENTITLEMENT' end;
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
$$;

-- ============================================================
-- bookings.service_entitlement_id: which entitlement was consumed.
-- Without recording it, restoring a credit on cancellation would be
-- guesswork when a customer holds more than one entitlement for the
-- same service.
-- ============================================================

alter table public.bookings
  add column service_entitlement_id uuid references public.service_entitlements (id);

create index bookings_service_entitlement_idx on public.bookings (service_entitlement_id);

-- ============================================================
-- book_slot(): record the entitlement used and spend a credit when it is
-- a CREDITS entitlement (docs/domain.md).
-- ============================================================

create or replace function public.book_slot(p_slot_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason public.can_book_reason;
  v_occurrence public.slot_occurrences;
  v_customer public.customers;
  v_entitlement public.service_entitlements;
  v_entitlement_id uuid;
  v_active_count int;
  v_booking public.bookings;
begin
  v_reason := public.can_customer_book(p_slot_occurrence_id);
  if v_reason <> 'OK' then
    return jsonb_build_object('status', v_reason);
  end if;

  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;

  select * into v_customer from public.customers
    where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  if v_active_count >= v_occurrence.capacity then
    return jsonb_build_object('status', 'SLOT_FULL');
  end if;

  v_entitlement_id := public.resolve_bookable_entitlement(v_customer.id, v_occurrence.service_id, p_slot_occurrence_id);
  if v_entitlement_id is null then
    -- Re-resolved under the lock: an admin could have revoked the
    -- entitlement (or its payment) between can_customer_book() and here.
    return jsonb_build_object('status', 'NO_ENTITLEMENT');
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, service_entitlement_id, status, created_by
  )
  values (
    v_occurrence.organization_id, v_customer.id, p_slot_occurrence_id, v_entitlement_id, 'CONFIRMED', auth.uid()
  )
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  select * into v_entitlement from public.service_entitlements where id = v_entitlement_id for update;
  if v_entitlement.entitlement_type = 'CREDITS' then
    update public.service_entitlements
      set credits_remaining = credits_remaining - 1
      where id = v_entitlement_id;
  end if;

  return jsonb_build_object('status', 'OK', 'booking', to_jsonb(v_booking));
end;
$$;

-- ============================================================
-- cancel_booking(): give the credit back. MVP policy is "always restore"
-- -- domain.md mentions restoring "dentro de la política de la
-- organización" (e.g. not within N hours of the class), but no such
-- policy field exists yet, so encoding one now would be inventing a
-- requirement nobody has stated.
-- ============================================================

create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason public.booking_cancellation_reason default 'CUSTOMER_REQUEST'
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_customer public.customers;
  v_was_confirmed boolean;
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

  v_was_confirmed := v_booking.status = 'CONFIRMED';

  update public.bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_booking_id
    returning * into v_booking;

  -- Only a CONFIRMED booking ever spent a credit; a NOT_GENERATED one
  -- never did, so cancelling it must not hand one back.
  if v_was_confirmed and v_booking.service_entitlement_id is not null then
    update public.service_entitlements
      set credits_remaining = least(credits_remaining + 1, credits_total)
      where id = v_booking.service_entitlement_id and entitlement_type = 'CREDITS';
  end if;

  return v_booking;
end;
$$;

-- ============================================================
-- generate_recurring_booking(): also check the entitlement, not just
-- capacity. Without this a series kept confirming dates for a customer
-- whose membership had lapsed or whose credits had run out -- a real hole
-- left open by Phase 6.
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
  v_entitlement_id uuid;
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

  v_entitlement_id := public.resolve_bookable_entitlement(v_rb.customer_id, v_occurrence.service_id, p_slot_occurrence_id);

  -- No usable entitlement (lapsed membership, unpaid period, credits
  -- exhausted) is recorded the same way as "the slot was full": the date
  -- is kept as NOT_GENERATED so the customer can be told why, rather than
  -- silently skipped.
  v_status := case
    when v_entitlement_id is null then 'NOT_GENERATED'
    when v_active_count >= v_occurrence.capacity then 'NOT_GENERATED'
    else 'CONFIRMED'
  end;

  begin
    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, recurring_booking_id,
      service_entitlement_id, status, created_by
    )
    values (
      v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id,
      case when v_status = 'CONFIRMED' then v_entitlement_id else null end, v_status, v_rb.created_by
    )
    on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
    returning * into v_booking;
  exception
    when unique_violation then
      insert into public.bookings (
        organization_id, customer_id, slot_occurrence_id, recurring_booking_id, status, created_by
      )
      values (
        v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id,
        'NOT_GENERATED', v_rb.created_by
      )
      on conflict (recurring_booking_id, slot_occurrence_id) where recurring_booking_id is not null do nothing
      returning * into v_booking;
  end;

  if v_booking.id is not null and v_booking.status = 'CONFIRMED' and v_entitlement_id is not null then
    update public.service_entitlements
      set credits_remaining = credits_remaining - 1
      where id = v_entitlement_id and entitlement_type = 'CREDITS';
  end if;

  return v_booking;
end;
$$;

-- ============================================================
-- Row Level Security -- payments are private (docs/security.md): the
-- customer sees their own, STAFF/OWNER see their organization's, nobody
-- else sees anything. Writes go through normal staff inserts here (a
-- payment is manual admin data entry in the MVP, with no atomicity
-- requirement like booking has), but VOID-instead-of-delete is the rule.
-- ============================================================

alter table public.payments enable row level security;

create policy payments_select_self_or_staff
  on public.payments for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = payments.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );

create policy payments_insert_staff
  on public.payments for insert
  with check (public.is_organization_member(organization_id));

create policy payments_update_staff
  on public.payments for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- Deliberately no DELETE policy: a mis-entered payment is marked VOID,
-- never deleted (same rule as a cancelled Booking -- history is kept).
-- Leaving DELETE unpoliced means it is denied by default, so this can't
-- be forgotten at the call site the way a convention could.
