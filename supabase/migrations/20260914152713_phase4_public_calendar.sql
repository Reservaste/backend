-- Phase 4: Public calendar
-- Ref: docs/decisions.md ADR-0008, docs/security.md, docs/domain.md
--
-- Anonymous users may see: Organization (safe fields only), its Service
-- list, and availability -- shaped by publicAvailabilityDisplay. They may
-- never see Customer, Booking, Payment, ServiceEntitlement, or any
-- personal data. No Booking table exists yet (Phase 5), so
-- active_bookings is hardcoded to 0 below -- see the TODO on
-- get_public_availability.

-- ============================================================
-- organizations_public / services_public
-- ============================================================
-- Plain views (not security_invoker) run with the privileges of their
-- owner, not the querying role -- so these intentionally bypass the base
-- tables' member-only RLS, but only expose the columns listed here. This
-- is the "dedicated public view" every earlier migration's RLS comments
-- promised instead of ever widening organizations/services' own SELECT
-- policy: a mistake in this view only leaks these specific safe columns,
-- never billing/internal config by accident.

create view public.organizations_public as
select id, slug, name, timezone
from public.organizations
where is_active;

grant select on public.organizations_public to anon, authenticated;

create view public.services_public as
select id, organization_id, name, description
from public.services
where is_active;

grant select on public.services_public to anon, authenticated;

-- ============================================================
-- get_public_availability RPC
-- ============================================================
-- Deliberately an RPC, not a view granted to anon: the disclosure rule of
-- ADR-0008 (never expose the exact remaining count unless the effective
-- mode is EXACT) has to be enforced *in the database*, not trusted to the
-- Next.js layer remembering to strip fields -- a view exposing raw
-- capacity/remaining columns would let anyone bypass that by querying
-- PostgREST directly instead of going through the app.

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
        -- TODO(Phase 5): subtract real active Booking count once that
        -- table exists. Every occurrence is fully available until then.
        so.capacity - 0 as remaining,
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

grant execute on function public.get_public_availability(text, uuid, timestamptz, timestamptz) to anon, authenticated;
