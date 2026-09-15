-- Phase 10: plans, subscriptions and invite-gated organization creation
-- Ref: docs/decisions.md (ADR-0017 below), docs/domain.md
--
-- Same separation the domain already makes one level down: a
-- ServiceEntitlement is the right to use a service and a Payment is the
-- money, and they deliberately don't coincide 1:1 (courtesy, beca,
-- lapsed). An Organization needs exactly that shape for the platform
-- itself -- subscription_status is the right to operate, and how/whether
-- it was paid is a separate matter. Without it there'd be nowhere to
-- represent "I gave this gym three free months".
--
-- Limits live in `plans` as data, not in code: changing what the 20 USD
-- tier includes is an UPDATE, not a deploy.

-- ============================================================
-- plans
-- ============================================================

create table public.plans (
  code text primary key,
  name text not null,
  monthly_price_usd numeric(10, 2) not null,
  -- null means unlimited, everywhere.
  max_services int,
  max_resources int,
  max_customers int,
  max_team_members int,
  is_public boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.plans is
  'Subscription tiers. Limits are data so they can be changed without a deploy; null means unlimited.';

create trigger plans_set_updated_at
  before update on public.plans
  for each row execute function public.set_updated_at();

insert into public.plans (code, name, monthly_price_usd, max_services, max_resources, max_customers, max_team_members, sort_order)
values
  ('starter', 'Starter', 20, 3, 2, 50, 2, 1),
  ('pro', 'Pro', 40, 10, 5, 200, 5, 2),
  ('full', 'Full', 80, null, null, null, null, 3);

alter table public.plans enable row level security;

-- Anyone may read the plan catalogue (it's a pricing page), nobody may
-- write it through the API -- tiers change by migration or by the
-- platform owner in SQL.
create policy plans_select_all
  on public.plans for select
  using (true);

-- ============================================================
-- organizations: subscription state
-- ============================================================

create type public.subscription_status as enum ('TRIALING', 'ACTIVE', 'PAST_DUE', 'SUSPENDED');

alter table public.organizations
  add column plan_code text references public.plans (code),
  add column subscription_status public.subscription_status not null default 'SUSPENDED',
  add column trial_ends_at timestamptz,
  add column current_period_end timestamptz;

-- Organizations that already existed predate billing entirely; leaving
-- them SUSPENDED would lock out a working customer to introduce a
-- feature they never asked for.
update public.organizations
  set plan_code = 'full', subscription_status = 'ACTIVE'
  where plan_code is null;

create index organizations_subscription_idx on public.organizations (subscription_status);

-- ============================================================
-- platform_admins
-- ============================================================
-- The platform owner, as distinct from an organization's OWNER. Kept as
-- a table rather than a flag on profiles so granting it is an explicit,
-- auditable act.

create table public.platform_admins (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  note text
);

alter table public.platform_admins enable row level security;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_admins where profile_id = auth.uid());
$$;

-- Only a platform admin can see the list; nobody writes it through the
-- API (first admin is inserted directly, the rest by an existing admin
-- in SQL) -- there's no "promote yourself" path by construction.
create policy platform_admins_select_admin
  on public.platform_admins for select
  using (public.is_platform_admin());

-- ============================================================
-- organization_invites
-- ============================================================
-- Creating an organization is a paid action, so it isn't self-service:
-- the platform owner sells, generates a code carrying the plan, and the
-- buyer redeems it while creating their organization.

create table public.organization_invites (
  code text primary key,
  plan_code text not null references public.plans (code),
  -- Optional lock: if set, only this email may redeem the code.
  email text,
  trial_days int,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  redeemed_at timestamptz,
  redeemed_by uuid references public.profiles (id),
  redeemed_organization_id uuid references public.organizations (id),
  note text
);

create index organization_invites_redeemed_idx on public.organization_invites (redeemed_at);

alter table public.organization_invites enable row level security;

create policy organization_invites_select_admin
  on public.organization_invites for select
  using (public.is_platform_admin());

-- ============================================================
-- organization_can_operate()
-- ============================================================
-- "Can this organization still use the admin panel?" Deliberately not
-- "can its customers still book" -- a gym's members shouldn't lose their
-- bookings because the gym's card failed. PAST_DUE and SUSPENDED block
-- the panel; the public calendar and existing bookings keep working.

create or replace function public.organization_can_operate(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when o.subscription_status = 'ACTIVE' then true
      when o.subscription_status = 'TRIALING' then coalesce(o.trial_ends_at, now()) >= now()
      else false
    end
    from public.organizations o
    where o.id = p_organization_id
  ), false);
$$;

grant execute on function public.organization_can_operate(uuid) to authenticated;

-- ============================================================
-- Plan limits, enforced in the database
-- ============================================================
-- Hiding the button is not enforcement: the RPCs and PostgREST are
-- callable directly. One trigger function covers every limited table so
-- the rule can't drift between them.

create or replace function public.enforce_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := new.organization_id;
  v_plan public.plans;
  v_limit int;
  v_count int;
  v_label text;
begin
  if not public.organization_can_operate(v_org) then
    raise exception 'SUBSCRIPTION_INACTIVE';
  end if;

  select p.* into v_plan
    from public.organizations o
    join public.plans p on p.code = o.plan_code
    where o.id = v_org;

  if not found then
    return new;
  end if;

  if TG_TABLE_NAME = 'services' then
    v_label := 'servicios';
    v_limit := v_plan.max_services;
    select count(*) into v_count from public.services where organization_id = v_org and is_active;
  elsif TG_TABLE_NAME = 'resources' then
    v_label := 'recursos';
    v_limit := v_plan.max_resources;
    select count(*) into v_count from public.resources where organization_id = v_org and is_active;
  elsif TG_TABLE_NAME = 'customers' then
    v_label := 'clientes';
    v_limit := v_plan.max_customers;
    select count(*) into v_count from public.customers where organization_id = v_org and is_active;
  elsif TG_TABLE_NAME = 'organization_members' then
    v_label := 'personas en el equipo';
    v_limit := v_plan.max_team_members;
    select count(*) into v_count from public.organization_members where organization_id = v_org and is_active;
  else
    return new;
  end if;

  if v_limit is not null and v_count >= v_limit then
    raise exception 'PLAN_LIMIT_REACHED: % (%/%)', v_label, v_count, v_limit;
  end if;

  return new;
end;
$$;

-- INSERT only. An organization that stops paying keeps everything it
-- already has and can still cancel, edit and archive -- it just can't
-- grow. Blocking updates too would trap someone mid-fix.
create trigger services_plan_limit
  before insert on public.services
  for each row execute function public.enforce_plan_limit();

create trigger resources_plan_limit
  before insert on public.resources
  for each row execute function public.enforce_plan_limit();

create trigger customers_plan_limit
  before insert on public.customers
  for each row execute function public.enforce_plan_limit();

create trigger organization_members_plan_limit
  before insert on public.organization_members
  for each row execute function public.enforce_plan_limit();

-- Schedules aren't capped by a number, but a suspended organization
-- shouldn't be able to add new ones either.
create or replace function public.enforce_subscription_active()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.organization_can_operate(new.organization_id) then
    raise exception 'SUBSCRIPTION_INACTIVE';
  end if;
  return new;
end;
$$;

create trigger schedule_rules_subscription_active
  before insert on public.schedule_rules
  for each row execute function public.enforce_subscription_active();

create trigger service_entitlements_subscription_active
  before insert on public.service_entitlements
  for each row execute function public.enforce_subscription_active();

-- ============================================================
-- create_organization_with_owner(): now invite-gated
-- ============================================================
-- The old 3-argument version is dropped rather than left in place with a
-- default: an unguarded path that still exists is the bypass, whatever
-- the UI does (same lesson as the organizations INSERT policy in Phase 1).

drop function if exists public.create_organization_with_owner(text, text, text);

create or replace function public.create_organization_with_owner(
  p_slug text,
  p_name text,
  p_timezone text,
  p_invite_code text
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.organization_invites;
  v_org public.organizations;
  v_email text;
  v_status public.subscription_status;
  v_trial_ends timestamptz;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_invite
    from public.organization_invites
    where code = upper(trim(p_invite_code))
    for update;

  if not found then
    raise exception 'INVITE_NOT_FOUND';
  end if;

  if v_invite.redeemed_at is not null then
    raise exception 'INVITE_ALREADY_USED';
  end if;

  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    raise exception 'INVITE_EXPIRED';
  end if;

  if v_invite.email is not null then
    select email into v_email from auth.users where id = auth.uid();
    if lower(v_email) <> lower(v_invite.email) then
      raise exception 'INVITE_WRONG_EMAIL';
    end if;
  end if;

  if v_invite.trial_days is not null then
    v_status := 'TRIALING';
    v_trial_ends := now() + make_interval(days => v_invite.trial_days);
  else
    v_status := 'ACTIVE';
  end if;

  insert into public.organizations (
    slug, name, timezone, created_by, plan_code, subscription_status, trial_ends_at
  )
  values (p_slug, p_name, p_timezone, auth.uid(), v_invite.plan_code, v_status, v_trial_ends)
  returning * into v_org;

  insert into public.organization_members (organization_id, profile_id, role, created_by)
  values (v_org.id, auth.uid(), 'OWNER', auth.uid());

  update public.organization_invites
    set redeemed_at = now(), redeemed_by = auth.uid(), redeemed_organization_id = v_org.id
    where code = v_invite.code;

  return v_org;
end;
$$;

grant execute on function public.create_organization_with_owner(text, text, text, text) to authenticated;

-- ============================================================
-- organization_usage(): what the settings screen shows
-- ============================================================

create or replace function public.organization_usage(p_organization_id uuid)
returns table (
  plan_code text,
  plan_name text,
  monthly_price_usd numeric,
  subscription_status public.subscription_status,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  services_used int,
  services_limit int,
  resources_used int,
  resources_limit int,
  customers_used int,
  customers_limit int,
  team_used int,
  team_limit int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    o.plan_code,
    p.name,
    p.monthly_price_usd,
    o.subscription_status,
    o.trial_ends_at,
    o.current_period_end,
    (select count(*)::int from public.services s where s.organization_id = o.id and s.is_active),
    p.max_services,
    (select count(*)::int from public.resources r where r.organization_id = o.id and r.is_active),
    p.max_resources,
    (select count(*)::int from public.customers c where c.organization_id = o.id and c.is_active),
    p.max_customers,
    (select count(*)::int from public.organization_members m where m.organization_id = o.id and m.is_active),
    p.max_team_members
  from public.organizations o
  left join public.plans p on p.code = o.plan_code
  where o.id = p_organization_id
    and public.is_organization_member(o.id);
$$;

grant execute on function public.organization_usage(uuid) to authenticated;

-- ============================================================
-- Platform admin operations
-- ============================================================

create or replace function public.create_organization_invite(
  p_plan_code text,
  p_email text default null,
  p_trial_days int default null,
  p_expires_in_days int default 30,
  p_note text default null
)
returns public.organization_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_invite public.organization_invites;
begin
  if not public.is_platform_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- These codes get read out over the phone, so the alphabet leaves out
  -- O/0/I/1/L rather than trying to substitute them afterwards. Built
  -- from random() instead of pgcrypto's gen_random_bytes, which lives in
  -- the extensions schema and isn't on this function's search_path.
  for attempt in 1..5 loop
    select string_agg(
      substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', floor(random() * 31)::int + 1, 1),
      ''
    )
    into v_code
    from generate_series(1, 10);

    begin
      insert into public.organization_invites (code, plan_code, email, trial_days, expires_at, created_by, note)
      values (
        v_code,
        p_plan_code,
        nullif(trim(coalesce(p_email, '')), ''),
        p_trial_days,
        case when p_expires_in_days is null then null else now() + make_interval(days => p_expires_in_days) end,
        auth.uid(),
        p_note
      )
      returning * into v_invite;

      return v_invite;
    exception
      when unique_violation then
        -- Astronomically unlikely at 31^10, but a collision here would
        -- surface as a failed sale, so it retries rather than erroring.
        null;
    end;
  end loop;

  raise exception 'COULD_NOT_GENERATE_INVITE_CODE';
end;
$$;

grant execute on function public.create_organization_invite(text, text, int, int, text) to authenticated;

create or replace function public.set_organization_subscription(
  p_organization_id uuid,
  p_plan_code text,
  p_status public.subscription_status,
  p_current_period_end timestamptz default null
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if not public.is_platform_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.organizations
    set plan_code = p_plan_code,
        subscription_status = p_status,
        current_period_end = p_current_period_end
    where id = p_organization_id
    returning * into v_org;

  if not found then
    raise exception 'ORGANIZATION_NOT_FOUND';
  end if;

  return v_org;
end;
$$;

grant execute on function public.set_organization_subscription(uuid, text, public.subscription_status, timestamptz) to authenticated;

-- The platform owner's own console: every organization, what it pays,
-- and how much of its plan it is using.
create or replace function public.platform_organizations()
returns table (
  organization_id uuid,
  slug text,
  name text,
  plan_code text,
  subscription_status public.subscription_status,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  services_used int,
  customers_used int,
  team_used int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    o.id, o.slug, o.name, o.plan_code, o.subscription_status, o.trial_ends_at, o.current_period_end,
    (select count(*)::int from public.services s where s.organization_id = o.id and s.is_active),
    (select count(*)::int from public.customers c where c.organization_id = o.id and c.is_active),
    (select count(*)::int from public.organization_members m where m.organization_id = o.id and m.is_active),
    o.created_at
  from public.organizations o
  where public.is_platform_admin()
  order by o.created_at desc;
$$;

grant execute on function public.platform_organizations() to authenticated;

create or replace function public.platform_invites()
returns setof public.organization_invites
language sql
stable
security definer
set search_path = public
as $$
  select * from public.organization_invites
  where public.is_platform_admin()
  order by created_at desc;
$$;

grant execute on function public.platform_invites() to authenticated;
