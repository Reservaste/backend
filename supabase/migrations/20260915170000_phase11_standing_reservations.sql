-- Phase 11: standing reservations from the front desk
-- Ref: docs/decisions.md ADR-0010, ADR-0011, ADR-0012; docs/domain.md
--
-- The case this exists for: a client pays monthly for a fixed slot --
-- every Monday 09:00 Pilates. The engine for that shipped in Phase 6
-- (RecurringBooking generating one Booking per occurrence) but only as
-- customer self-service: create_recurring_booking resolves the customer
-- from auth.uid(), so staff had no way to set one up on someone's
-- behalf. That's the gap this closes.

-- ============================================================
-- Split the booking rule from the identity resolution
-- ============================================================
-- can_customer_book() answers "may *I* book this", which is the wrong
-- question when the front desk asks on someone else's behalf. The rule
-- itself is extracted so both paths share it -- duplicating it is
-- exactly how "preview said yes, confirm said no" happens.

create or replace function public.evaluate_customer_booking(
  p_slot_occurrence_id uuid,
  p_customer_id uuid
)
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

  select * into v_customer from public.customers
    where id = p_customer_id
      and organization_id = v_occurrence.organization_id
      and is_active;
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

-- can_customer_book() is now just "resolve me, then apply the rule".
-- ADR-0005 still holds: the customer comes from auth.uid(), never from
-- the caller.
create or replace function public.can_customer_book(p_slot_occurrence_id uuid)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_customer_id uuid;
begin
  if auth.uid() is null then
    return 'AUTH_REQUIRED';
  end if;

  select organization_id into v_org from public.slot_occurrences where id = p_slot_occurrence_id;
  if v_org is null then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  select id into v_customer_id from public.customers
    where organization_id = v_org and profile_id = auth.uid() and is_active;
  if v_customer_id is null then
    return 'NOT_A_CUSTOMER';
  end if;

  return public.evaluate_customer_booking(p_slot_occurrence_id, v_customer_id);
end;
$$;

-- ============================================================
-- Why a date did not confirm
-- ============================================================
-- NOT_GENERATED collapsed two very different situations: the class was
-- full, or the customer's month was not paid. The portal was showing
-- "sin lugar" for both, which is a lie in the second case -- and the
-- second case is the whole point of a standing reservation. Record it.

create type public.not_generated_reason as enum ('SLOT_FULL', 'NO_ENTITLEMENT', 'DUPLICATE');

alter table public.bookings
  add column if not exists not_generated_reason public.not_generated_reason;

comment on column public.bookings.not_generated_reason is
  'Why a recurring date could not be confirmed. Null for every other status.';

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

  v_entitlement_id := public.resolve_bookable_entitlement(v_rb.customer_id, v_occurrence.service_id, p_slot_occurrence_id);

  -- No usable entitlement (lapsed membership, unpaid period, credits
  -- exhausted) is recorded the same way as "the slot was full": the date
  -- is kept as NOT_GENERATED so the customer can be told why, rather than
  -- silently skipped. Entitlement is checked first because it is the
  -- reason the customer can actually act on.
  v_reason := case
    when v_entitlement_id is null then 'NO_ENTITLEMENT'
    when v_active_count >= v_occurrence.capacity then 'SLOT_FULL'
    else null
  end;
  v_status := case when v_reason is null then 'CONFIRMED' else 'NOT_GENERATED' end;

  begin
    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, recurring_booking_id,
      service_entitlement_id, status, not_generated_reason, created_by
    )
    values (
      v_occurrence.organization_id, v_rb.customer_id, p_slot_occurrence_id, p_recurring_booking_id,
      case when v_status = 'CONFIRMED' then v_entitlement_id else null end, v_status, v_reason, v_rb.created_by
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

  -- Spending the credit belongs with the insert that used it (Phase 7):
  -- without this a CREDITS entitlement would confirm every date in the
  -- rolling window instead of self-limiting to what was paid for.
  if v_booking.id is not null and v_booking.status = 'CONFIRMED' and v_entitlement_id is not null then
    update public.service_entitlements
      set credits_remaining = credits_remaining - 1
      where id = v_entitlement_id and entitlement_type = 'CREDITS';
  end if;

  return v_booking;
end;
$$;

-- my_bookings(): carry the reason through to the portal, so an unpaid
-- month reads as "tu pago no cubre esta fecha" instead of the class
-- quietly vanishing from the customer's list.
-- Dropped rather than replaced: CREATE OR REPLACE cannot change a
-- function's OUT parameters, and this adds a column to the result.
drop function if exists public.my_bookings(boolean);

create function public.my_bookings(p_include_past boolean default false)
returns table (
  booking_id uuid,
  status public.booking_status,
  organization_slug text,
  organization_name text,
  organization_timezone text,
  service_name text,
  start_at timestamptz,
  end_at timestamptz,
  occurrence_status public.slot_occurrence_status,
  cancellation_reason public.booking_cancellation_reason,
  is_recurring boolean,
  not_generated_reason public.not_generated_reason
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.status,
    o.slug,
    o.name,
    o.timezone,
    s.name,
    so.start_at,
    so.end_at,
    so.status,
    b.cancellation_reason,
    b.recurring_booking_id is not null,
    b.not_generated_reason
  from public.bookings b
  join public.customers c on c.id = b.customer_id and c.profile_id = auth.uid()
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  join public.services s on s.id = so.service_id
  join public.organizations o on o.id = b.organization_id
  where p_include_past or so.start_at >= now()
  order by so.start_at asc;
$$;

grant execute on function public.my_bookings(boolean) to authenticated;

-- ============================================================
-- admin_preview_recurring_booking()
-- ============================================================
-- ADR-0012: show the conflicts before committing, never book partially
-- in silence. Same preview the customer-facing flow gets, asked on
-- someone else's behalf.

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
as $$
declare
  v_rule public.schedule_rules;
  v_rec record;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found or not public.is_organization_member(v_rule.organization_id) then
    return;
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
    can_book := public.evaluate_customer_booking(v_rec.id, p_customer_id);
    return next;
  end loop;
end;
$$;

grant execute on function public.admin_preview_recurring_booking(uuid, uuid, int) to authenticated;

-- ============================================================
-- admin_create_recurring_booking()
-- ============================================================

create or replace function public.admin_create_recurring_booking(
  p_schedule_rule_id uuid,
  p_customer_id uuid
)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.schedule_rules;
  v_customer public.customers;
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  -- Authorization here is organization membership, not ownership of the
  -- booking -- the front-desk counterpart of ADR-0005's rule.
  if not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_rule.organization_id and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  -- One standing reservation per customer per rule: a second one would
  -- generate a duplicate Booking for every occurrence, which the Phase 5
  -- unique index would then turn into a stream of NOT_GENERATED rows.
  if exists (
    select 1 from public.recurring_bookings
    where schedule_rule_id = p_schedule_rule_id
      and customer_id = p_customer_id
      and status = 'ACTIVE'
  ) then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

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
$$;

grant execute on function public.admin_create_recurring_booking(uuid, uuid) to authenticated;

-- ============================================================
-- schedule_rule_standing_reservations()
-- ============================================================
-- Who holds a standing spot on this rule, and whether their next dates
-- are actually being confirmed -- a series whose payment lapsed keeps
-- existing but starts producing NOT_GENERATED, and the front desk needs
-- to see that without reading the bookings table.

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
as $$
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
        and b.not_generated_reason = 'NO_ENTITLEMENT' and so.start_at >= now())
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, p.full_name asc;
$$;

grant execute on function public.schedule_rule_standing_reservations(uuid) to authenticated;
