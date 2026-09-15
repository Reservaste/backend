-- Phase 9: Customer portal
-- Ref: docs/decisions.md ADR-0015; docs/domain.md; docs/security.md
--
-- A customer can read their own bookings/entitlements/payments (RLS
-- allows it), but cannot read slot_occurrences, services or
-- organizations -- those are member-only by design, and Phase 4's public
-- views deliberately expose only the public shape. So "my bookings, with
-- what and when" can't be a join from the client: it needs these RPCs,
-- which run as definer and return exactly the customer's own rows joined
-- to the names that make them legible.

create or replace function public.my_bookings(p_include_past boolean default false)
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
  is_recurring boolean
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
    b.recurring_booking_id is not null
  from public.bookings b
  join public.customers c on c.id = b.customer_id and c.profile_id = auth.uid()
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  join public.services s on s.id = so.service_id
  join public.organizations o on o.id = b.organization_id
  where p_include_past or so.start_at >= now()
  order by so.start_at asc;
$$;

grant execute on function public.my_bookings(boolean) to authenticated;

create or replace function public.my_entitlements()
returns table (
  entitlement_id uuid,
  organization_slug text,
  organization_name text,
  service_name text,
  entitlement_type public.entitlement_type,
  valid_from date,
  valid_until date,
  credits_remaining int,
  credits_total int,
  requires_active_payment boolean,
  is_active boolean,
  -- Whether a PAID period covers today. The customer's actual question
  -- is "can I book?", and an entitlement that looks active but has no
  -- current payment is the confusing case worth surfacing directly
  -- rather than leaving them to discover it at booking time.
  paid_today boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    se.id,
    o.slug,
    o.name,
    s.name,
    se.entitlement_type,
    se.valid_from,
    se.valid_until,
    se.credits_remaining,
    se.credits_total,
    se.requires_active_payment,
    se.is_active,
    public.entitlement_payment_satisfied(se.id, (now() at time zone o.timezone)::date)
  from public.service_entitlements se
  join public.customers c on c.id = se.customer_id and c.profile_id = auth.uid()
  join public.services s on s.id = se.service_id
  join public.organizations o on o.id = se.organization_id
  order by se.is_active desc, s.name asc;
$$;

grant execute on function public.my_entitlements() to authenticated;

create or replace function public.my_payments()
returns table (
  payment_id uuid,
  organization_name text,
  service_name text,
  period_start date,
  period_end date,
  status public.payment_status,
  amount numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, o.name, s.name, p.period_start, p.period_end, p.status, p.amount
  from public.payments p
  join public.customers c on c.id = p.customer_id and c.profile_id = auth.uid()
  join public.service_entitlements se on se.id = p.service_entitlement_id
  join public.services s on s.id = se.service_id
  join public.organizations o on o.id = p.organization_id
  order by p.period_start desc;
$$;

grant execute on function public.my_payments() to authenticated;

-- ============================================================
-- public_slot_detail(): one slot, for the confirmation screen
-- ============================================================
-- ADR-0015's post-login step has to re-render *what is about to be
-- booked* before the person confirms. That summary is public data
-- (service, time, availability shape), so it reuses the same disclosure
-- rules as the calendar rather than exposing the raw occurrence.

create or replace function public.public_slot_detail(p_slot_occurrence_id uuid)
returns table (
  slot_occurrence_id uuid,
  organization_slug text,
  organization_name text,
  organization_timezone text,
  service_id uuid,
  service_name text,
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
  v_slug text;
begin
  select o.slug into v_slug
    from public.slot_occurrences so
    join public.organizations o on o.id = so.organization_id
    where so.id = p_slot_occurrence_id and so.status = 'ACTIVE' and o.is_active;

  if v_slug is null then
    return;
  end if;

  return query
    select
      a.slot_occurrence_id,
      o.slug,
      o.name,
      o.timezone,
      a.service_id,
      s.name,
      a.start_at,
      a.end_at,
      a.mode,
      a.status,
      a.remaining,
      a.capacity
    from public.get_public_availability(v_slug, null, now() - interval '1 day', now() + interval '2 years') a
    join public.services s on s.id = a.service_id
    join public.organizations o on o.slug = v_slug
    where a.slot_occurrence_id = p_slot_occurrence_id;
end;
$$;

grant execute on function public.public_slot_detail(uuid) to anon, authenticated;
