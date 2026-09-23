-- ============================================================
-- Phase 27 -- CHECK constraint on organizations.slug (security-engineer finding)
-- ============================================================
-- organizations.slug has been `text not null unique` since Phase 1, with
-- format enforced only by organizationSlugSchema (Zod, backend/src/schemas.ts)
-- on the form/server-action path. create_organization_with_owner() inserts
-- p_slug as-is. An authenticated user can call
-- rpc/create_organization_with_owner directly via PostgREST, skipping Zod
-- entirely, with e.g. p_slug = '/evil.com'.
--
-- Concrete vector this closes: several frontend call sites render
-- href={`/${slug}`} without going through organizationPath() (which
-- validates before a redirect(), but is not used on plain <a>/<Link>
-- hrefs). A slug of '/evil.com' produces href="//evil.com" -- a
-- protocol-relative URL the browser treats as external. Combined with
-- ADR-0026 (managed customer activation), an attacker who gets a victim to
-- redeem one of their invites gets a link with the product's own styling
-- that actually navigates the victim off-site.
--
-- Fix: make the bad value impossible to store, not a patch on every href
-- that reads it -- same criterion already used for platform_contact_requests
-- (ADR-0030 Phase 2): validation that only lives in Zod is not a boundary,
-- because every RPC is reachable directly via PostgREST once
-- `grant execute ... to authenticated` exists (Phase 19 finding, still the
-- operating assumption for every RPC in this repo).
--
-- Pattern is an exact mirror of organizationSlugSchema
-- (backend/src/schemas.ts): lowercase letters/digits, hyphen-separated,
-- never starting/ending with a hyphen, never a double hyphen, 2-60 chars.
-- Not applied as NOT VALID + VALIDATE: the only INSERT path for this column
-- is create_organization_with_owner() (Phase 1, re-created as a 4-arg
-- invite-gated version in Phase 10 -- verified grepping every migration,
-- there is no UPDATE path for slug anywhere), and every organization in
-- this repo's history was created through the frontend form, which already
-- runs this exact Zod pattern before calling the RPC. Existing rows are
-- expected to already satisfy it; a plain CHECK (validated immediately)
-- catches the rare case where that assumption was wrong instead of
-- silently deferring validation to whenever someone happens to UPDATE a
-- row.

alter table public.organizations
  add constraint organizations_slug_format_check
  check (
    char_length(slug) between 2 and 60
    and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
  );

comment on constraint organizations_slug_format_check on public.organizations is
  'Mirrors organizationSlugSchema (backend/src/schemas.ts) in SQL so the format is enforced even against a direct PostgREST call to create_organization_with_owner(), not only the Zod-validated form path. Ref: docs/security.md.';

-- create_organization_with_owner(): translate the raw CHECK violation into
-- a clean error code instead of letting the client see Postgres' own
-- message ("new row for relation ... violates check constraint ..."), same
-- courtesy every other RPC in this repo extends its callers (SLOT_FULL,
-- INVITE_NOT_FOUND, etc. -- never a bare Postgres exception). The function
-- signature is unchanged (4 args, Phase 10's invite-gated version), so this
-- is `create or replace`, not a drop+recreate.
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
  v_constraint_name text;
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

  begin
    insert into public.organizations (
      slug, name, timezone, created_by, plan_code, subscription_status, trial_ends_at
    )
    values (p_slug, p_name, p_timezone, auth.uid(), v_invite.plan_code, v_status, v_trial_ends)
    returning * into v_org;
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = constraint_name;
      if v_constraint_name = 'organizations_slug_format_check' then
        raise exception 'INVALID_SLUG';
      end if;
      raise;
  end;

  insert into public.organization_members (organization_id, profile_id, role, created_by)
  values (v_org.id, auth.uid(), 'OWNER', auth.uid());

  update public.organization_invites
    set redeemed_at = now(), redeemed_by = auth.uid(), redeemed_organization_id = v_org.id
    where code = v_invite.code;

  return v_org;
end;
$$;

-- `create or replace` (not drop+create) preserves the existing grants --
-- `grant ... to authenticated` (Phase 10) and `revoke ... from public, anon`
-- (Phase 19, ADR-0028) both still apply unchanged; nothing to re-grant here.
