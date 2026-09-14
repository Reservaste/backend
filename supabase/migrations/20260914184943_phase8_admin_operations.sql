-- Phase 8: admin operations the panel needs
-- Ref: docs/domain.md, docs/security.md; docs/roadmap.md Phase 8
--
-- Two RPCs for enrolling people by email (staff can't read profiles they
-- don't own, by design), plus a capacity guard that domain.md has
-- specified since day one but no phase had enforced.

-- ============================================================
-- Capacity can never drop below the seats already taken
-- ============================================================
-- domain.md: "Nunca permitir que la capacidad configurada de una
-- ocurrencia quede por debajo de las reservas activas que ya tiene."
-- Until now nothing stopped an admin setting capacity 12 -> 3 on a slot
-- with 8 confirmed bookings, which would leave availableCapacity
-- negative and silently break the central invariant. The check lives
-- here rather than in the admin UI because the UI is not the only way
-- rows get updated.

create or replace function public.check_slot_capacity_not_below_bookings()
returns trigger
language plpgsql
as $$
declare
  v_active_count int;
begin
  if new.capacity >= old.capacity then
    return new;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = new.id and status = 'CONFIRMED';

  if new.capacity < v_active_count then
    raise exception 'CAPACITY_BELOW_ACTIVE_BOOKINGS: % confirmed bookings, capacity %', v_active_count, new.capacity;
  end if;

  return new;
end;
$$;

create trigger slot_occurrences_capacity_guard
  before update on public.slot_occurrences
  for each row execute function public.check_slot_capacity_not_below_bookings();

-- ============================================================
-- enroll_customer_by_email()
-- ============================================================
-- Staff can't query profiles/auth.users directly (profiles RLS is
-- own-row-only, which is correct -- an org shouldn't be able to browse
-- the platform's user base). This RPC is the narrow, membership-gated
-- exception: it resolves one exact email to a profile and enrols it as a
-- Customer of the caller's own organization, returning nothing about the
-- person beyond the customer row itself.
--
-- MVP limitation: the person must already have an account. Sending an
-- invitation to a stranger's email is a separate feature (it needs email
-- delivery and a pending-invite state), deliberately not invented here.

create or replace function public.enroll_customer_by_email(
  p_organization_id uuid,
  p_email text
)
returns public.customers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
  v_customer public.customers;
begin
  if not public.is_organization_member(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select id into v_profile_id from auth.users where lower(email) = lower(trim(p_email));
  if v_profile_id is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers
    where organization_id = p_organization_id and profile_id = v_profile_id;

  if found then
    -- Re-enrolling someone who was removed reactivates them rather than
    -- creating a second customer row (the unique constraint would reject
    -- that anyway) -- and keeps their booking history attached.
    if not v_customer.is_active then
      update public.customers
        set is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
        where id = v_customer.id
        returning * into v_customer;
    end if;
    return v_customer;
  end if;

  insert into public.customers (organization_id, profile_id, created_by)
  values (p_organization_id, v_profile_id, auth.uid())
  returning * into v_customer;

  return v_customer;
end;
$$;

grant execute on function public.enroll_customer_by_email(uuid, text) to authenticated;

-- ============================================================
-- invite_member_by_email(): same idea for STAFF/OWNER, OWNER-gated
-- ============================================================

create or replace function public.invite_member_by_email(
  p_organization_id uuid,
  p_email text,
  p_role public.organization_member_role default 'STAFF'
)
returns public.organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
  v_member public.organization_members;
begin
  -- Adding staff is an OWNER-only action, unlike enrolling customers
  -- (which any active member does as part of day-to-day work).
  if not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select id into v_profile_id from auth.users where lower(email) = lower(trim(p_email));
  if v_profile_id is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;

  select * into v_member from public.organization_members
    where organization_id = p_organization_id and profile_id = v_profile_id;

  if found then
    update public.organization_members
      set role = p_role, is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
      where id = v_member.id
      returning * into v_member;
    return v_member;
  end if;

  insert into public.organization_members (organization_id, profile_id, role, created_by)
  values (p_organization_id, v_profile_id, p_role, auth.uid())
  returning * into v_member;

  return v_member;
end;
$$;

grant execute on function public.invite_member_by_email(uuid, text, public.organization_member_role) to authenticated;

-- ============================================================
-- revoke_member(): an OWNER can't be left with no owners
-- ============================================================

create or replace function public.revoke_member(p_member_id uuid)
returns public.organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member public.organization_members;
  v_remaining_owners int;
begin
  select * into v_member from public.organization_members where id = p_member_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if not public.is_organization_owner(v_member.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_member.role = 'OWNER' then
    select count(*) into v_remaining_owners
      from public.organization_members
      where organization_id = v_member.organization_id and role = 'OWNER' and is_active and id <> p_member_id;

    -- An organization with no active OWNER is unadministrable: nobody
    -- could ever add one back, since adding owners is itself
    -- OWNER-gated.
    if v_remaining_owners = 0 then
      raise exception 'LAST_OWNER';
    end if;
  end if;

  update public.organization_members
    set is_active = false, cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'REVOKED_BY_ORGANIZATION'
    where id = p_member_id
    returning * into v_member;

  return v_member;
end;
$$;

grant execute on function public.revoke_member(uuid) to authenticated;

-- ============================================================
-- admin_book_for_customer(): staff books a customer into a slot
-- ============================================================
-- book_slot() resolves the customer from auth.uid() by design (ADR-0005),
-- so it can't serve the front-desk case of "add this person to the 09:00
-- class". This is the staff-side equivalent: same capacity lock and same
-- entitlement rules, but the customer is named explicitly and
-- authorization comes from organization membership instead of ownership
-- of the booking.

create or replace function public.admin_book_for_customer(
  p_slot_occurrence_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_occurrence public.slot_occurrences;
  v_customer public.customers;
  v_entitlement_id uuid;
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

  v_entitlement_id := public.resolve_bookable_entitlement(p_customer_id, v_occurrence.service_id, p_slot_occurrence_id);
  if v_entitlement_id is null then
    -- Staff sees the same distinction a customer would, so the front desk
    -- can tell someone "your payment lapsed" rather than a generic error.
    return jsonb_build_object(
      'status',
      case when exists (
        select 1 from public.service_entitlements se
        where se.customer_id = p_customer_id and se.service_id = v_occurrence.service_id and se.is_active
      ) then 'PAYMENT_REQUIRED' else 'NO_ENTITLEMENT' end
    );
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, service_entitlement_id, status, created_by
  )
  values (
    v_occurrence.organization_id, p_customer_id, p_slot_occurrence_id, v_entitlement_id, 'CONFIRMED', auth.uid()
  )
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  update public.service_entitlements
    set credits_remaining = credits_remaining - 1
    where id = v_entitlement_id and entitlement_type = 'CREDITS';

  return jsonb_build_object('status', 'OK', 'booking', to_jsonb(v_booking));
end;
$$;

grant execute on function public.admin_book_for_customer(uuid, uuid) to authenticated;

-- ============================================================
-- agenda_occurrences(): one query for the admin Agenda
-- ============================================================
-- The Agenda needs occurrence + occupancy + service/resource names in one
-- go. Doing it as an RPC keeps the N+1 out of the UI layer and puts the
-- "confirmed bookings" count next to the capacity it has to be compared
-- against, which is the number the whole screen is about.

create or replace function public.agenda_occurrences(
  p_organization_id uuid,
  p_from timestamptz,
  p_to timestamptz
)
returns table (
  id uuid,
  service_id uuid,
  service_name text,
  resource_id uuid,
  resource_name text,
  start_at timestamptz,
  end_at timestamptz,
  capacity int,
  confirmed_count int,
  status public.slot_occurrence_status
)
language sql
stable
security definer
set search_path = public
as $$
  select
    so.id,
    so.service_id,
    s.name,
    so.resource_id,
    r.name,
    so.start_at,
    so.end_at,
    so.capacity,
    (select count(*) from public.bookings b
      where b.slot_occurrence_id = so.id and b.status = 'CONFIRMED')::int,
    so.status
  from public.slot_occurrences so
  join public.services s on s.id = so.service_id
  join public.resources r on r.id = so.resource_id
  where so.organization_id = p_organization_id
    and public.is_organization_member(so.organization_id)
    and so.start_at >= p_from
    and so.start_at < p_to
  order by so.start_at asc;
$$;

grant execute on function public.agenda_occurrences(uuid, timestamptz, timestamptz) to authenticated;

-- ============================================================
-- occurrence_bookings(): who is booked into one slot, for the Agenda
-- detail panel. Returns the customer's name -- private data, so it is
-- membership-gated like everything else here.
-- ============================================================

create or replace function public.occurrence_bookings(p_slot_occurrence_id uuid)
returns table (
  booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.booking_status,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.customer_id,
    coalesce(p.full_name, 'Sin nombre'),
    b.status,
    b.created_at
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  join public.profiles p on p.id = c.profile_id
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  where b.slot_occurrence_id = p_slot_occurrence_id
    and public.is_organization_member(so.organization_id)
  order by b.created_at asc;
$$;

grant execute on function public.occurrence_bookings(uuid) to authenticated;

-- ============================================================
-- organization_customers(): customer list with names, for the Clientes
-- screen. Same membership gate.
-- ============================================================

create or replace function public.organization_customers(p_organization_id uuid)
returns table (
  customer_id uuid,
  profile_id uuid,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.profile_id, coalesce(p.full_name, 'Sin nombre'), c.is_active, c.created_at
  from public.customers c
  join public.profiles p on p.id = c.profile_id
  where c.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  order by p.full_name asc;
$$;

grant execute on function public.organization_customers(uuid) to authenticated;

-- ============================================================
-- organization_team(): member list with names, for the Equipo screen.
-- ============================================================

create or replace function public.organization_team(p_organization_id uuid)
returns table (
  member_id uuid,
  profile_id uuid,
  full_name text,
  role public.organization_member_role,
  is_active boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select om.id, om.profile_id, coalesce(p.full_name, 'Sin nombre'), om.role, om.is_active
  from public.organization_members om
  join public.profiles p on p.id = om.profile_id
  where om.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  order by om.role asc, p.full_name asc;
$$;

grant execute on function public.organization_team(uuid) to authenticated;
