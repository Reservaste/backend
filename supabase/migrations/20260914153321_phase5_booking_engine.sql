-- Phase 5: Booking Engine + cancellation + capacity
-- Ref: docs/decisions.md ADR-0004, ADR-0005, ADR-0010, ADR-0013; docs/domain.md
--
-- Reconciliation note: the Phase 0 planning conversation (ADR-0010)
-- sketched Booking.cancelledBy as a CUSTOMER|ORGANIZATION enum (who
-- category) separate from cancellationReason. Every migration actually
-- built since then (organization_members, customers, services,
-- schedule_rules, slot_occurrences) instead uses cancelled_by as a
-- profile FK (which specific person) with cancellation_reason carrying
-- the why -- and the reason values themselves (CUSTOMER_REQUEST vs.
-- SLOT_CANCELLED/RULE_DISCONTINUED) already make the actor category
-- recoverable. bookings follows that established, already-tested
-- pattern for consistency rather than the earlier sketch.

-- ============================================================
-- bookings
-- ============================================================

create type public.booking_status as enum ('CONFIRMED', 'CANCELLED');
create type public.booking_cancellation_reason as enum ('CUSTOMER_REQUEST', 'SLOT_CANCELLED', 'RULE_DISCONTINUED');

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  slot_occurrence_id uuid not null references public.slot_occurrences (id) on delete cascade,
  status public.booking_status not null default 'CONFIRMED',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.booking_cancellation_reason
);

comment on table public.bookings is
  'A Customer''s reservation of one SlotOccurrence. Never deleted, even when CANCELLED -- history is kept. Ref: docs/domain.md.';

create trigger bookings_set_updated_at
  before update on public.bookings
  for each row execute function public.set_updated_at();

create index bookings_organization_idx on public.bookings (organization_id);
create index bookings_customer_idx on public.bookings (customer_id);
create index bookings_slot_occurrence_idx on public.bookings (slot_occurrence_id);

-- ADR-0004: the real duplicate guard. A partial unique index (only over
-- CONFIRMED rows) so a customer can re-book a slot they previously
-- cancelled, but never hold two CONFIRMED bookings on the same occurrence
-- at once.
create unique index bookings_customer_occurrence_confirmed_idx
  on public.bookings (customer_id, slot_occurrence_id)
  where status = 'CONFIRMED';

-- ============================================================
-- can_customer_book(): the single source of truth for "may this person
-- reserve this occurrence" (ADR-0005, ADR-0013). Both the check endpoint
-- (ADR-0015) and book_slot() below call this -- never reimplemented
-- separately, so the rule can't drift between "preview" and "confirm".
-- ============================================================

create type public.can_book_reason as enum (
  'OK',
  'AUTH_REQUIRED',
  'NOT_A_CUSTOMER',
  'ORGANIZATION_INACTIVE',
  'SERVICE_INACTIVE',
  'OCCURRENCE_NOT_AVAILABLE',
  'NO_ENTITLEMENT',
  'SLOT_FULL',
  'ALREADY_BOOKED'
);

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
  v_has_entitlement boolean;
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
  -- caller-supplied customerId -- this is what makes IDOR impossible
  -- here, not a check on the caller's input.
  select * into v_customer from public.customers
    where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;
  if not found then
    return 'NOT_A_CUSTOMER';
  end if;

  select exists (
    select 1 from public.service_entitlements se
    where se.customer_id = v_customer.id
      and se.service_id = v_service.id
      and se.is_active
      and (
        (se.entitlement_type = 'TIME'
          and se.valid_from <= current_date
          and (se.valid_until is null or se.valid_until >= current_date))
        or
        (se.entitlement_type = 'CREDITS' and se.credits_remaining > 0)
      )
      -- TODO(Phase 7): when se.requires_active_payment is true, also
      -- require a Payment row (status='PAID') covering
      -- v_occurrence.start_at (ADR-0013). No Payment table exists yet, so
      -- this entitlement check is currently the whole gate regardless of
      -- requires_active_payment.
  ) into v_has_entitlement;

  if not v_has_entitlement then
    return 'NO_ENTITLEMENT';
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

grant execute on function public.can_customer_book(uuid) to authenticated;

-- ============================================================
-- book_slot(): the atomic RPC (ADR-0004). Everything above is a
-- fast-path business-rule check without locking; the FOR UPDATE below is
-- what actually makes the capacity check race-free -- two concurrent
-- callers both passing can_customer_book() and racing for the last seat
-- serialize here, and the second one re-reads a capacity that now
-- reflects the first one's insert.
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

  insert into public.bookings (organization_id, customer_id, slot_occurrence_id, status, created_by)
  values (v_occurrence.organization_id, v_customer.id, p_slot_occurrence_id, 'CONFIRMED', auth.uid())
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  return jsonb_build_object('status', 'OK', 'booking', to_jsonb(v_booking));
end;
$$;

grant execute on function public.book_slot(uuid) to authenticated;

-- ============================================================
-- cancel_booking(): CUSTOMER cancels their own, or STAFF/OWNER cancels on
-- behalf. Idempotent -- cancelling an already-cancelled booking just
-- returns it unchanged rather than erroring, so a retried request never
-- fails.
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

  update public.bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$$;

grant execute on function public.cancel_booking(uuid, public.booking_cancellation_reason) to authenticated;

-- ============================================================
-- Close the Phase 3 TODOs: cancelling a SlotOccurrence, or discontinuing
-- a ScheduleRule, must now also cascade-cancel any CONFIRMED bookings on
-- the affected occurrences (domain.md's cascade invariant) -- there was
-- nothing to cascade to before this migration.
-- ============================================================

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
  v_booking_reason public.booking_cancellation_reason;
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

  v_booking_reason := case p_reason
    when 'SLOT_CANCELLED' then 'SLOT_CANCELLED'::public.booking_cancellation_reason
    else 'RULE_DISCONTINUED'::public.booking_cancellation_reason
  end;

  update public.bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_booking_reason
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  return v_occurrence;
end;
$$;

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

  update public.bookings b
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'RULE_DISCONTINUED'
    from public.slot_occurrences so
    where b.slot_occurrence_id = so.id
      and so.schedule_rule_id = p_schedule_rule_id
      and so.start_at >= now()
      and b.status = 'CONFIRMED';
end;
$$;

-- ============================================================
-- Close the Phase 4 TODO: get_public_availability() can now count real
-- active bookings instead of hardcoding 0.
-- ============================================================

create or replace function public.get_public_availability(
  p_organization_slug text,
  p_service_id uuid default null,
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns table (
  slot_occurrence_id uuid,
  service_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  mode text,
  status text,
  remaining int,
  capacity int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  select * into v_org from public.organizations where slug = p_organization_slug and is_active;
  if not found then
    return;
  end if;

  return query
    select
      so.id,
      so.service_id,
      so.start_at,
      so.end_at,
      effective.mode,
      case
        when effective.mode = 'EXACT' then null
        when effective.remaining <= 0 then 'FULL'
        when effective.mode = 'LIMITED' and effective.remaining <= effective.low_threshold then 'LOW'
        else 'AVAILABLE'
      end as status,
      case when effective.mode = 'EXACT' then effective.remaining end as remaining,
      case when effective.mode = 'EXACT' then so.capacity end as capacity
    from public.slot_occurrences so
    join public.services s on s.id = so.service_id and s.is_active
    cross join lateral (
      select
        coalesce(s.public_availability_display_override, v_org.public_availability_display) as mode,
        (so.capacity - (
          select count(*) from public.bookings b
          where b.slot_occurrence_id = so.id and b.status = 'CONFIRMED'
        ))::int as remaining,
        greatest(
          1,
          least(
            coalesce(v_org.low_availability_fixed_cap, so.capacity),
            ceil(so.capacity * v_org.low_availability_percentage / 100.0)::int
          )
        ) as low_threshold
    ) as effective
    where so.organization_id = v_org.id
      and so.status = 'ACTIVE'
      and so.start_at >= p_from
      and so.start_at <= p_to
      and (p_service_id is null or so.service_id = p_service_id)
    order by so.start_at asc;
end;
$$;

-- ============================================================
-- Row Level Security
-- ============================================================
-- Deliberately SELECT-only. Every write (create, cancel) goes through
-- the RPCs above -- same reasoning as organizations' missing INSERT
-- policy and slot_occurrences' CANCELLED write-check: a raw client
-- insert would bypass can_customer_book()/the capacity lock entirely,
-- and a raw cancel would skip setting cancelled_at/by/reason together.

alter table public.bookings enable row level security;

create policy bookings_select_self_or_staff
  on public.bookings for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = bookings.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );
