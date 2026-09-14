-- Phase 2: Services + Resources + Entitlements
-- Ref: docs/decisions.md ADR-0006, ADR-0008, ADR-0010, ADR-0013; docs/domain.md
--
-- No booking yet (Phase 5). This lays down what a Service is, what
-- Resource(s) it needs, and what it means for a Customer to have the
-- right to use it (ServiceEntitlement), independent of payment.
--
-- Scope decision (Orchestrator): ServiceEntitlement.service_id is a
-- required FK to a single Service for now, not the nullable + N:M
-- "covers several services" shape domain.md flagged as a future
-- possibility. Nothing today needs a multi-service package, and
-- domain.md already documents the nullable+N:M shape as the way to
-- extend this later without a breaking change -- adding it now would be
-- designing for a requirement nobody has yet.

-- ============================================================
-- resources
-- ============================================================

create type public.resource_cancellation_reason as enum ('DISCONTINUED_BY_ORGANIZATION');

create table public.resources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.resource_cancellation_reason
);

comment on table public.resources is
  'What gets occupied to deliver a Service: a room, a professional, a court, equipment. Generic -- ref: docs/domain.md.';

create trigger resources_set_updated_at
  before update on public.resources
  for each row execute function public.set_updated_at();

create index resources_organization_idx on public.resources (organization_id);

-- ============================================================
-- services
-- ============================================================

create type public.service_cancellation_reason as enum ('DISCONTINUED_BY_ORGANIZATION');

create table public.services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  description text,
  -- ADR-0008: null means "use the Organization's default".
  public_availability_display_override text
    check (public_availability_display_override in ('EXACT', 'LIMITED', 'BOOLEAN')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.service_cancellation_reason
);

comment on table public.services is
  'What an Organization offers and can be booked. Never Gym/Class-specific -- ref: docs/domain.md, CLAUDE.md.';

create trigger services_set_updated_at
  before update on public.services
  for each row execute function public.set_updated_at();

create index services_organization_idx on public.services (organization_id);

-- ============================================================
-- service_resources (Service <-> Resource, N:M)
-- ============================================================

create table public.service_resources (
  service_id uuid not null references public.services (id) on delete cascade,
  resource_id uuid not null references public.resources (id) on delete cascade,
  primary key (service_id, resource_id)
);

comment on table public.service_resources is
  'A Service can require one or more Resources; a Resource can serve several Services. Ref: docs/domain.md.';

-- A Service can only be paired with a Resource from the same Organization
-- -- this is a real data-integrity rule (cross-tenant pairing would be a
-- silent multi-tenancy bug), enforced here rather than trusted to
-- application code.
create or replace function public.check_service_resource_same_org()
returns trigger
language plpgsql
as $$
declare
  v_service_org uuid;
  v_resource_org uuid;
begin
  select organization_id into v_service_org from public.services where id = new.service_id;
  select organization_id into v_resource_org from public.resources where id = new.resource_id;

  if v_service_org is null or v_resource_org is null or v_service_org <> v_resource_org then
    raise exception 'Service and Resource must belong to the same Organization';
  end if;

  return new;
end;
$$;

create trigger service_resources_same_org
  before insert or update on public.service_resources
  for each row execute function public.check_service_resource_same_org();

-- ============================================================
-- service_entitlements
-- ============================================================

create type public.entitlement_type as enum ('TIME', 'CREDITS');
create type public.entitlement_cancellation_reason as enum ('CUSTOMER_REQUEST', 'ORGANIZATION_REVOKED');

create table public.service_entitlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  service_id uuid not null references public.services (id) on delete cascade,
  entitlement_type public.entitlement_type not null,
  -- ADR-0013: whether canCustomerBook() (Phase 7) must also find a
  -- Payment covering the reservation date, or whether this entitlement
  -- alone is enough (courtesy/comp access).
  requires_active_payment boolean not null default true,
  -- TIME vigencia
  valid_from date,
  valid_until date,
  -- CREDITS vigencia
  credits_total int,
  credits_remaining int,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.entitlement_cancellation_reason,
  constraint service_entitlements_vigencia_matches_type check (
    (entitlement_type = 'TIME' and valid_from is not null and credits_total is null and credits_remaining is null)
    or
    (entitlement_type = 'CREDITS' and credits_total is not null and credits_remaining is not null and valid_from is null and valid_until is null)
  ),
  constraint service_entitlements_credits_non_negative check (
    credits_remaining is null or (credits_remaining >= 0 and credits_remaining <= credits_total)
  ),
  constraint service_entitlements_valid_range check (
    valid_until is null or valid_from is null or valid_until >= valid_from
  )
);

comment on table public.service_entitlements is
  'The right of a Customer to use a Service -- independent of Payment. Ref: docs/domain.md, ADR-0013.';

create trigger service_entitlements_set_updated_at
  before update on public.service_entitlements
  for each row execute function public.set_updated_at();

create index service_entitlements_organization_idx on public.service_entitlements (organization_id);
create index service_entitlements_customer_idx on public.service_entitlements (customer_id);
create index service_entitlements_service_idx on public.service_entitlements (service_id);

-- A Service, Customer and their ServiceEntitlement must all agree on
-- Organization -- same cross-tenant pairing guard as service_resources.
create or replace function public.check_entitlement_same_org()
returns trigger
language plpgsql
as $$
declare
  v_customer_org uuid;
  v_service_org uuid;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  select organization_id into v_service_org from public.services where id = new.service_id;

  if v_customer_org is null or v_service_org is null
     or v_customer_org <> new.organization_id or v_service_org <> new.organization_id then
    raise exception 'ServiceEntitlement organization_id must match its Customer and Service';
  end if;

  return new;
end;
$$;

create trigger service_entitlements_same_org
  before insert or update on public.service_entitlements
  for each row execute function public.check_entitlement_same_org();

-- ============================================================
-- Row Level Security
-- ============================================================
-- No public/anonymous policy yet for services/resources -- Phase 4
-- (public calendar) adds a dedicated public view, same reasoning as
-- organizations in the Phase 1 migration: never let the base table's RLS
-- be the only thing standing between an anonymous request and a column
-- that later turns out to be private.

alter table public.resources enable row level security;
alter table public.services enable row level security;
alter table public.service_resources enable row level security;
alter table public.service_entitlements enable row level security;

create policy resources_select_members
  on public.resources for select
  using (public.is_organization_member(organization_id));

create policy resources_write_staff
  on public.resources for all
  using (public.is_organization_member(organization_id));

create policy services_select_members
  on public.services for select
  using (public.is_organization_member(organization_id));

create policy services_write_staff
  on public.services for all
  using (public.is_organization_member(organization_id));

create policy service_resources_select_members
  on public.service_resources for select
  using (
    exists (
      select 1 from public.services s
      where s.id = service_resources.service_id
        and public.is_organization_member(s.organization_id)
    )
  );

create policy service_resources_write_staff
  on public.service_resources for all
  using (
    exists (
      select 1 from public.services s
      where s.id = service_resources.service_id
        and public.is_organization_member(s.organization_id)
    )
  );

-- service_entitlements: ADR-0006 two layers, same shape as customers --
-- a CUSTOMER sees only their own entitlements, STAFF/OWNER see every
-- entitlement in their organization.
create policy service_entitlements_select_self_or_staff
  on public.service_entitlements for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = service_entitlements.customer_id
        and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );

create policy service_entitlements_write_staff
  on public.service_entitlements for all
  using (public.is_organization_member(organization_id));
