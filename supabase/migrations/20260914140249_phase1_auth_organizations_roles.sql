-- Phase 1: Auth + Organizations + Roles
-- Ref: docs/decisions.md ADR-0002, ADR-0005, ADR-0006, ADR-0010, ADR-0014
--
-- Entities: Profile, Organization, OrganizationMember, Customer.
-- RLS follows the two-layer model of ADR-0006 (tenant + row ownership).
-- No ORM: this migration is the single source of truth for the schema.
--
-- Table/type creation happens first, in dependency order; RLS policies are
-- added afterwards in their own section, because organizations' policies
-- reference organization_members and must not run before that table exists.

-- ============================================================
-- Generic helpers
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
-- profiles (1:1 with auth.users)
-- ============================================================

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Authenticated identity of a person, independent of role in any organization. Ref: docs/domain.md.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-create a profile row whenever a new Supabase Auth user is created
-- (email/password or Google OAuth both land here).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- organizations
-- ============================================================

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  -- ADR-0014: IANA timezone name, never a fixed offset.
  timezone text not null default 'America/Montevideo',
  -- ADR-0008: publicAvailabilityDisplay default for this organization.
  public_availability_display text not null default 'EXACT'
    check (public_availability_display in ('EXACT', 'LIMITED', 'BOOLEAN')),
  low_availability_percentage int not null default 20,
  low_availability_fixed_cap int default 3,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id)
);

comment on table public.organizations is
  'The tenant. Generic across verticals -- never a Gym/Member/Trainer/Class concept. Ref: docs/domain.md.';

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

create unique index organizations_slug_idx on public.organizations (slug);

-- ============================================================
-- organization_members (roles: OWNER | STAFF)
-- ============================================================

create type public.organization_member_role as enum ('OWNER', 'STAFF');
create type public.member_cancellation_reason as enum ('REVOKED_BY_ORGANIZATION', 'SELF_REMOVED');

create table public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role public.organization_member_role not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.member_cancellation_reason,
  unique (organization_id, profile_id)
);

comment on table public.organization_members is
  'OWNER/STAFF membership of a Profile in an Organization. Ref: docs/security.md roles.';

create trigger organization_members_set_updated_at
  before update on public.organization_members
  for each row execute function public.set_updated_at();

create index organization_members_organization_idx on public.organization_members (organization_id);
create index organization_members_profile_idx on public.organization_members (profile_id);

-- ============================================================
-- customers (a Profile as customer of an Organization)
-- ============================================================

create type public.customer_cancellation_reason as enum ('CUSTOMER_REQUEST', 'ORGANIZATION_REMOVED');

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_reason public.customer_cancellation_reason,
  unique (organization_id, profile_id)
);

comment on table public.customers is
  'A Profile in its capacity as customer of one Organization. A Profile can be Customer of several Organizations. Ref: docs/domain.md, ADR-0006.';

create trigger customers_set_updated_at
  before update on public.customers
  for each row execute function public.set_updated_at();

create index customers_organization_idx on public.customers (organization_id);
create index customers_profile_idx on public.customers (profile_id);

-- ============================================================
-- create_organization_with_owner RPC
-- ============================================================
-- Creating an Organization and granting its creator OWNER membership must
-- happen atomically: the organizations_select_members policy below means
-- the creator could not even see the organization they just created until
-- the OWNER membership row exists. A plain two-step insert from the client
-- risks a half-created organization with no owner if the second insert
-- fails.

create or replace function public.create_organization_with_owner(
  p_slug text,
  p_name text,
  p_timezone text default 'America/Montevideo'
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into public.organizations (slug, name, timezone, created_by)
  values (p_slug, p_name, p_timezone, auth.uid())
  returning * into v_org;

  insert into public.organization_members (organization_id, profile_id, role, created_by)
  values (v_org.id, auth.uid(), 'OWNER', auth.uid());

  return v_org;
end;
$$;

grant execute on function public.create_organization_with_owner(text, text, text) to authenticated;

-- ============================================================
-- Row Level Security (ADR-0006: tenant + row ownership, two layers)
-- ============================================================
--
-- Membership checks below go through the SECURITY DEFINER helper
-- functions further down (is_organization_member / is_organization_owner)
-- instead of an inline `exists (select 1 from organization_members ...)`
-- subquery. A subquery against organization_members inside a policy that
-- itself protects organization_members re-triggers that same policy for
-- the subquery, which Postgres detects as infinite recursion (this broke
-- the very first attempt at this migration -- caught by the ADR-0006
-- cross-tenant integration test, not by review). A SECURITY DEFINER
-- function bypasses RLS for that one narrow, safe check, breaking the
-- cycle.

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.organization_members om
    where om.organization_id = p_organization_id
      and om.profile_id = auth.uid()
      and om.is_active
  );
$$;

create or replace function public.is_organization_owner(p_organization_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.organization_members om
    where om.organization_id = p_organization_id
      and om.profile_id = auth.uid()
      and om.role = 'OWNER'
      and om.is_active
  );
$$;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.customers enable row level security;

-- profiles: a user can read/update only their own profile row
create policy profiles_select_own
  on public.profiles for select
  using (id = auth.uid());

create policy profiles_update_own
  on public.profiles for update
  using (id = auth.uid());

-- organizations: direct table SELECT is restricted to members (admin use).
-- Anonymous public browsing (Phase 4) goes through a dedicated public
-- view/RPC that only surfaces the public shape, never this table's RLS, so
-- private columns (billing, internal config) are never at risk of leaking
-- through a future policy mistake here.
create policy organizations_select_members
  on public.organizations for select
  using (public.is_organization_member(id));

-- Deliberately no INSERT policy here. create_organization_with_owner() is
-- SECURITY DEFINER and runs as the table owner, which bypasses RLS
-- entirely, so it does not need one -- and omitting it means no client can
-- ever create an Organization via a raw `.from('organizations').insert()`
-- and skip the atomic owner-membership insert that RPC guarantees. An
-- Organization with no OWNER is a broken state; this is what stops it at
-- the database level rather than relying on every future caller to
-- remember to use the RPC.

create policy organizations_update_owner
  on public.organizations for update
  using (public.is_organization_owner(id));

-- organization_members: two layers -- membership of the SAME organization
-- grants read of the whole roster; only an OWNER of that organization can
-- write to it.
create policy organization_members_select_same_org
  on public.organization_members for select
  using (public.is_organization_member(organization_id));

create policy organization_members_write_owner
  on public.organization_members for all
  using (public.is_organization_owner(organization_id));

-- customers: ADR-0006 two layers combined with OR:
--  - CUSTOMER: sees only their own row (profile_id = auth.uid()).
--  - OWNER/STAFF: sees every customer row of their organization.
-- This is the exact policy shape ADR-0006 was written to fix -- filtering
-- by organization_id alone would let any customer of an org see every
-- other customer's row in that same org.
create policy customers_select_self_or_staff
  on public.customers for select
  using (
    profile_id = auth.uid()
    or public.is_organization_member(organization_id)
  );

create policy customers_write_staff
  on public.customers for all
  using (public.is_organization_member(organization_id));
