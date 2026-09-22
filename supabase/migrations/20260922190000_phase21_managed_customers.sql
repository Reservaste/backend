-- ============================================================
-- Phase 21 -- Managed customers + WhatsApp activation (ADR-0026)
-- ============================================================
-- Implements the shape and canje designed in
-- docs/proposals/adr-0026-managed-customers.md and accepted (with 8
-- resolutions) in docs/decisions.md ADR-0026.
--
-- Ownership boundary with the parallel Fase I work (makeup credits): this
-- migration does not touch bookings/recurring_bookings status columns,
-- makeup_credits, evaluate_customer_booking(), payment_covers_slot(), nor
-- any series-cancellation cascade. It only adds customers.* columns, the
-- customer_activations table, and the RPCs/trigger listed below.
--
-- Hallazgo A (cancel_booking() NULL-profile_id bypass) is NOT re-fixed
-- here: it already landed in migration 19 (20260922160000, ADR-0028),
-- deliberately before this migration makes profile_id nullable, so the
-- bypass condition never existed live. See "verification" comment at the
-- bottom of this file for how to check it for real now that the column
-- is actually nullable.
--
-- Hallazgo C (profile_id on delete cascade) is fixed as part of 2.1 below
-- -- it is a one-line consequence of making the column nullable, not a
-- separate change.
--
-- Hallazgos B and E from the proposal are blocking for this migration
-- (ADR-0026, resolution 6) and are fixed in sections 3 and 4.

-- ============================================================
-- 0. pgcrypto, for a real CSPRNG token (not random())
-- ============================================================
-- gen_random_bytes()/digest() live in pgcrypto. Supabase projects have it
-- pre-installed in the `extensions` schema; `if not exists` makes this a
-- no-op there. Every reference below is schema-qualified
-- (extensions.gen_random_bytes / extensions.digest) rather than relying
-- on search_path, per the proposal's explicit warning about
-- create_organization_invite()'s random() precedent (phase10:427).
create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- 1. organizations.customer_activation_enabled
-- ============================================================
-- Resolved outside the proposal, by the Orchestrator: a per-organization
-- kill switch for the whole mechanism. Default true so existing and new
-- organizations get the feature; a sensitive vertical (mental health,
-- addiction recovery) can turn it off without code changes.
alter table public.organizations
  add column customer_activation_enabled boolean not null default true;

comment on column public.organizations.customer_activation_enabled is
  'ADR-0026: whether staff can create managed customers / issue WhatsApp activation links for this organization. Default on; a business can opt out entirely.';

-- ============================================================
-- 2.1 customers: profile_id nullable, contact columns, unicidad, ON DELETE
-- ============================================================

alter table public.customers alter column profile_id drop not null;

-- Hallazgo C: was ON DELETE CASCADE. Deleting an auth.users row cascaded
-- through profiles -> customers -> bookings/payments, against domain.md
-- ("a cancelled Booking is never deleted", "a Payment is voided, never
-- deleted"). With profile_id nullable, someone deleting their account now
-- becomes exactly what this ADR defines as a managed customer: history
-- intact, no identity. The four FKs *from* bookings/payments/
-- recurring_bookings/service_entitlements to customers stay ON DELETE
-- CASCADE unchanged -- they no longer matter for this path, because the
-- customer row itself is never deleted anymore, only unlinked.
alter table public.customers drop constraint customers_profile_id_fkey;
alter table public.customers
  add constraint customers_profile_id_fkey
  foreign key (profile_id) references public.profiles (id) on delete set null;

alter table public.customers
  add column display_name text,
  add column phone text,
  add column claimed_at timestamptz,
  add column merged_into_customer_id uuid references public.customers (id);

comment on column public.customers.display_name is
  'ADR-0026: name for a managed customer (profile_id is null), or a name override kept after activation. profiles.full_name is not overwritten by activation -- two names, two owners.';
comment on column public.customers.phone is
  'ADR-0026: E.164 with leading +. Normalized by create_managed_customer(), never trusted from a raw PostgREST write (customers is staff-writable directly).';
comment on column public.customers.claimed_at is
  'ADR-0026: when/whether this row went from managed to activated via claim_customer_activation().';
comment on column public.customers.merged_into_customer_id is
  'ADR-0026 Sec 2.5: set by merge_customers() on the source row. Lets a stale/inactive managed row be traced to the account it was folded into, instead of looking like an unexplained ghost.';

-- A customer with no profile has to have a visible name -- otherwise the
-- counter is charging an anonymous row.
alter table public.customers
  add constraint customers_identity_or_name check (
    profile_id is not null
    or (display_name is not null and length(trim(display_name)) > 0)
  );

-- Normalized E.164. Without this, "099 123 456", "+59899123456" and
-- "59899123456" are three different customers.
alter table public.customers
  add constraint customers_phone_e164 check (
    phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'
  );

-- claimed_at only makes sense once there is an identity to claim into.
alter table public.customers
  add constraint customers_claimed_requires_profile check (
    claimed_at is null or profile_id is not null
  );

-- Unicidad #2 (unicidad #1, unique(organization_id, profile_id), already
-- exists from Phase 1 and needs no change -- NULLs are distinct from each
-- other by default, which is exactly what lets N managed customers share
-- an organization). This is what stops two managed rows for the same
-- phone within one organization.
create unique index customers_organization_phone_idx
  on public.customers (organization_id, phone)
  where phone is not null;

-- ============================================================
-- 2.2 customer_activations -- the token
-- ============================================================

create table public.customer_activations (
  id uuid primary key default gen_random_uuid(),
  -- Redundant with customers.organization_id on purpose: lets RLS/RPCs
  -- filter this table by tenant without a join, same defense-in-depth
  -- reasoning as ADR-0006.
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  -- sha256(token), never the token itself. An index-backed exact lookup,
  -- without the "can't search a salted hash" problem -- this is not a
  -- password, it's an unguessable 256-bit secret, so a slow KDF buys
  -- nothing and costs latency on the redemption path.
  token_hash bytea not null unique,
  phone text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles (id),
  redeemed_at timestamptz,
  redeemed_profile_id uuid references public.profiles (id),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id)
);

comment on table public.customer_activations is
  'ADR-0026: one-time, 72h-expiring token that lets a customer.profile_id be linked from outside the panel. token_hash is sha256 of a 256-bit CSPRNG value; the clear token exists only in the return value of issue_customer_activation(). Ref: docs/proposals/adr-0026-managed-customers.md Sec 2.2.';

-- Only one live (not redeemed, not revoked) link per customer. Reissuing
-- has to revoke whatever was live first (done inside
-- issue_customer_activation()) or this index rejects the insert -- which
-- is exactly the point: a resend is what invalidates the possibly
-- wrong-number link, not a second one existing alongside it.
create unique index customer_activations_one_live_idx
  on public.customer_activations (customer_id)
  where redeemed_at is null and revoked_at is null;

create index customer_activations_organization_idx
  on public.customer_activations (organization_id);
create index customer_activations_customer_idx
  on public.customer_activations (customer_id);
-- Backs the emission rate limit's two count(*) queries.
create index customer_activations_org_created_idx
  on public.customer_activations (organization_id, created_at);

alter table public.customer_activations enable row level security;
-- Deliberately no policy at all, and no `grant select`/`insert`/etc to
-- anon or authenticated (Sec 5.2 of the proposal). RLS with zero policies
-- denies every row to anon/authenticated regardless of grants, and there
-- is no grant anyway -- the only door onto this table for a PostgREST
-- request is the SECURITY DEFINER RPCs below, which read/write it as the
-- function owner and bypass RLS entirely. (service_role, which does
-- bypass RLS by design, is never used by this application's client code
-- -- only the anon/authenticated keys reach PostgREST -- so it is not a
-- door this table needs to defend against here.)

-- ============================================================
-- 2.3/3 Trigger: only claim/unlink/merge may write customers.profile_id
-- ============================================================
-- Hallazgo E: customers_write_staff (Phase 1) is `for all using
-- (is_organization_member(organization_id))` with no separate `with
-- check`, so a PATCH to an arbitrary row in the same organization can set
-- any column -- including profile_id. With profile_id NOT NULL this was
-- already a way to steal an existing customer's identity; with managed
-- rows sitting there with profile_id = null waiting to be claimed, it
-- becomes the obvious way to skip the token entirely:
--
--   PATCH /rest/v1/customers?id=eq.<managed_row>
--   { "profile_id": "<attacker's own uuid>" }
--
-- The guard is a trigger, not a convention, for the same reason
-- set_updated_at (Phase 1) and check_slot_capacity_not_below_bookings
-- (Phase 8) are triggers: several write paths exist (PostgREST direct,
-- and three different RPCs), and a trigger is the one place that covers
-- all of them, including any future one.
create or replace function public.guard_customers_profile_link()
returns trigger
language plpgsql
as $$
begin
  if new.profile_id is distinct from old.profile_id
     and coalesce(current_setting('app.allow_profile_link', true), 'off') <> 'on' then
    raise exception 'PROFILE_LINK_NOT_ALLOWED';
  end if;
  return new;
end;
$$;

comment on function public.guard_customers_profile_link() is
  'ADR-0026 Hallazgo E: rejects any UPDATE that changes customers.profile_id unless the transaction has set_config(''app.allow_profile_link'', ''on'', true) -- done only inside claim_customer_activation(), unlink_customer_profile() and merge_customers().';

create trigger customers_profile_link_guard
  before update on public.customers
  for each row execute function public.guard_customers_profile_link();

-- ============================================================
-- 4. create_managed_customer() -- STAFF
-- ============================================================
-- Same gate as enroll_customer_by_email() (Phase 8): enrolling a customer
-- is day-to-day counter work, not a power over the tenant.
create or replace function public.create_managed_customer(
  p_organization_id uuid,
  p_display_name text,
  p_phone text default null
)
returns public.customers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers;
  v_name text;
  v_phone text;
begin
  if not public.is_organization_member(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  v_name := nullif(trim(p_display_name), '');
  if v_name is null then
    raise exception 'DISPLAY_NAME_REQUIRED';
  end if;

  -- Normalize to E.164 here, in the RPC, not in the form -- customers is
  -- staff-writable directly by PostgREST (same reasoning as ADR-0020's
  -- brand color and ADR-0025's recovery policy), so the CHECK constraint
  -- is the real defense and this is just a better error message than a
  -- raw constraint violation.
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if v_phone is not null then
    if left(v_phone, 1) <> '+' then
      v_phone := '+' || v_phone;
    end if;
    if v_phone !~ '^\+[1-9][0-9]{6,14}$' then
      raise exception 'INVALID_PHONE';
    end if;
  end if;

  if v_phone is not null then
    select * into v_customer
      from public.customers
      where organization_id = p_organization_id and phone = v_phone;

    if found then
      -- Same behaviour as enroll_customer_by_email() re-enrolling by
      -- email (Phase 8): a repeat alta reactivates rather than splitting
      -- history into two rows, which the unique index would reject
      -- anyway.
      if not v_customer.is_active then
        update public.customers
          set is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
          where id = v_customer.id
          returning * into v_customer;
      end if;
      return v_customer;
    end if;
  end if;

  insert into public.customers (organization_id, display_name, phone, created_by)
  values (p_organization_id, v_name, v_phone, auth.uid())
  returning * into v_customer;

  return v_customer;
end;
$$;

revoke execute on function public.create_managed_customer(uuid, text, text) from public, anon;
grant execute on function public.create_managed_customer(uuid, text, text) to authenticated;

-- ============================================================
-- 5. issue_customer_activation() -- STAFF, emit / reenviar
-- ============================================================
create or replace function public.issue_customer_activation(
  p_customer_id uuid
)
returns table (activation_id uuid, token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers;
  v_org public.organizations;
  v_token text;
  v_hash bytea;
  v_expires timestamptz;
  v_count int;
  v_activation_id uuid;
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_customer.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_org from public.organizations where id = v_customer.organization_id;

  if not v_org.customer_activation_enabled then
    raise exception 'ACTIVATION_DISABLED';
  end if;

  if not v_customer.is_active then
    raise exception 'CUSTOMER_INACTIVE';
  end if;

  if v_customer.profile_id is not null then
    raise exception 'ALREADY_ACTIVATED';
  end if;

  if v_customer.phone is null then
    raise exception 'CUSTOMER_HAS_NO_PHONE';
  end if;

  -- Rate limiting, resolved inside the RPC per the Orchestrator's
  -- resolution 4 (no new infrastructure): emission only. Redemption
  -- brute force is an accepted residual risk (256 bits makes it
  -- computationally moot; ADR-0026 Sec 2.2).
  select count(*) into v_count
    from public.customer_activations
    where organization_id = v_customer.organization_id
      and created_at > now() - interval '1 hour';
  if v_count >= 30 then
    raise exception 'RATE_LIMITED_HOURLY';
  end if;

  select count(*) into v_count
    from public.customer_activations
    where organization_id = v_customer.organization_id
      and created_at > now() - interval '1 day';
  if v_count >= 200 then
    raise exception 'RATE_LIMITED_DAILY';
  end if;

  -- Resend invalidates whatever was live -- the partial unique index
  -- would reject the insert below otherwise, and a stale link is exactly
  -- the one that may have gone to the wrong number.
  update public.customer_activations
    set revoked_at = now(), revoked_by = auth.uid()
    where customer_id = p_customer_id
      and redeemed_at is null
      and revoked_at is null;

  -- 256 bits of CSPRNG, base64url without padding so it drops cleanly
  -- into a path segment / query param with no re-encoding surprises.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_hash := extensions.digest(v_token, 'sha256');
  v_expires := now() + interval '72 hours';

  insert into public.customer_activations (
    organization_id, customer_id, token_hash, phone, expires_at, created_by
  ) values (
    v_customer.organization_id, p_customer_id, v_hash, v_customer.phone, v_expires, auth.uid()
  )
  returning id into v_activation_id;

  return query select v_activation_id, v_token, v_expires;
end;
$$;

comment on function public.issue_customer_activation(uuid) is
  'ADR-0026: returns the clear token exactly once. Losing it before sending the WhatsApp message means reissuing (which revokes the old one), not recovering it -- token_hash cannot be reversed.';

revoke execute on function public.issue_customer_activation(uuid) from public, anon;
grant execute on function public.issue_customer_activation(uuid) to authenticated;

-- ============================================================
-- 6. revoke_customer_activation() -- STAFF
-- ============================================================
create or replace function public.revoke_customer_activation(p_activation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.customer_activations;
begin
  select * into v_act from public.customer_activations where id = p_activation_id;
  if not found then
    return;
  end if;

  if not public.is_organization_member(v_act.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_act.redeemed_at is not null or v_act.revoked_at is not null then
    return;
  end if;

  update public.customer_activations
    set revoked_at = now(), revoked_by = auth.uid()
    where id = p_activation_id;
end;
$$;

revoke execute on function public.revoke_customer_activation(uuid) from public, anon;
grant execute on function public.revoke_customer_activation(uuid) to authenticated;

-- ============================================================
-- 7. customer_activation_status() -- read model for the panel
-- ============================================================
-- Sec 5.2 of the proposal: customer_activations has no grant select for
-- anyone. This is the one door, and it never returns token_hash.
create or replace function public.customer_activation_status(p_customer_id uuid)
returns table (
  activation_id uuid,
  phone text,
  created_at timestamptz,
  expires_at timestamptz,
  redeemed_at timestamptz,
  revoked_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select ca.id, ca.phone, ca.created_at, ca.expires_at, ca.redeemed_at, ca.revoked_at
  from public.customer_activations ca
  join public.customers c on c.id = ca.customer_id
  where ca.customer_id = p_customer_id
    and public.is_organization_member(c.organization_id)
  order by ca.created_at desc
  limit 1;
$$;

revoke execute on function public.customer_activation_status(uuid) from public, anon;
grant execute on function public.customer_activation_status(uuid) to authenticated;

-- ============================================================
-- 8. claim_customer_activation() -- the canje, authenticated only
-- ============================================================
-- ADR-0005 applied literally: one parameter, the token. It does not name
-- any customer row -- the destination comes entirely from the token, the
-- identity entirely from auth.uid(). There is no IDOR surface because
-- there is no input that points at a row.
create or replace function public.claim_customer_activation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.customer_activations;
  v_customer public.customers;
  v_org public.organizations;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'INVALID_TOKEN';
  end if;

  select * into v_act
    from public.customer_activations
    where token_hash = extensions.digest(trim(p_token), 'sha256')
    for update;

  if not found then
    raise exception 'INVALID_TOKEN';
  end if;

  if v_act.revoked_at is not null then
    raise exception 'ACTIVATION_REVOKED';
  end if;

  -- Double-tap idempotency: the same profile hitting claim twice (a
  -- double click) gets OK again instead of an error; a different profile
  -- gets ALREADY_REDEEMED and nothing is touched.
  if v_act.redeemed_at is not null then
    if v_act.redeemed_profile_id = auth.uid() then
      select * into v_org from public.organizations where id = v_act.organization_id;
      return jsonb_build_object(
        'status', 'OK',
        'organization_slug', v_org.slug,
        'customer_id', v_act.customer_id
      );
    end if;
    raise exception 'ALREADY_REDEEMED';
  end if;

  if v_act.expires_at <= now() then
    raise exception 'ACTIVATION_EXPIRED';
  end if;

  select * into v_customer from public.customers where id = v_act.customer_id;
  if not found or not v_customer.is_active then
    raise exception 'CUSTOMER_UNAVAILABLE';
  end if;

  select * into v_org from public.organizations where id = v_act.organization_id;
  if not found or not v_org.is_active then
    raise exception 'CUSTOMER_UNAVAILABLE';
  end if;

  -- Conflict: this profile is already a customer of this organization
  -- under its own row. The canje never fusiona automatically -- the
  -- owner resolves it with merge_customers(); the token is not consumed,
  -- so the same link keeps working once that is done.
  if exists (
    select 1 from public.customers
    where organization_id = v_act.organization_id
      and profile_id = auth.uid()
      and id <> v_act.customer_id
  ) then
    raise exception 'ALREADY_CUSTOMER_OF_ORGANIZATION';
  end if;

  perform set_config('app.allow_profile_link', 'on', true);

  -- The `and profile_id is null` guard, on top of the `for update` above,
  -- is what gives two concurrent claims of the same token exactly one
  -- winner even if the row lock somehow did not serialize them.
  update public.customers
    set profile_id = auth.uid(), claimed_at = now()
    where id = v_act.customer_id
      and profile_id is null;

  if not found then
    raise exception 'ALREADY_CLAIMED';
  end if;

  update public.customer_activations
    set redeemed_at = now(), redeemed_profile_id = auth.uid()
    where id = v_act.id
      and redeemed_at is null;

  return jsonb_build_object(
    'status', 'OK',
    'organization_slug', v_org.slug,
    'customer_id', v_act.customer_id
  );
end;
$$;

comment on function public.claim_customer_activation(text) is
  'ADR-0026 Sec 2.4. Never anon: linking auth.uid() to a row requires a session to exist in the first place.';

revoke execute on function public.claim_customer_activation(text) from public, anon;
grant execute on function public.claim_customer_activation(text) to authenticated;

-- ============================================================
-- 9. unlink_customer_profile() -- OWNER, undo a wrong claim
-- ============================================================
create or replace function public.unlink_customer_profile(p_customer_id uuid)
returns public.customers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers;
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  if not public.is_organization_owner(v_customer.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_customer.profile_id is null then
    return v_customer;
  end if;

  perform set_config('app.allow_profile_link', 'on', true);

  update public.customers
    set profile_id = null, claimed_at = null
    where id = p_customer_id
    returning * into v_customer;

  return v_customer;
end;
$$;

comment on function public.unlink_customer_profile(uuid) is
  'ADR-0026 Sec 2.2 mitigation 4: undoes an incorrect claim (wrong number, wrong person confirmed anyway). History is untouched -- only profile_id/claimed_at are cleared.';

revoke execute on function public.unlink_customer_profile(uuid) from public, anon;
grant execute on function public.unlink_customer_profile(uuid) to authenticated;

-- ============================================================
-- 10. merge_customers() -- OWNER, the feo case, never automatic
-- ============================================================
-- ADR-0026 Sec 2.5. Moves history from a managed row into the row that
-- has profile_id (the one the customer portal already shows). Never
-- fusiona automatically: whatever would collide with a real constraint on
-- the target stays on the source row, listed in the return value, rather
-- than guessed at. Bookings/payments are moved one at a time and let the
-- database's own constraints (the CONFIRMED-per-slot unique index, the
-- ADR-0024 EXCLUDE on overlapping PAID periods, the drop-in per-slot
-- unique index) be the source of truth for what collides -- catching the
-- exception per row is more reliable than re-deriving those same rules
-- here and risking the two definitions drifting apart.
create or replace function public.merge_customers(
  p_target_customer_id uuid,
  p_source_customer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.customers;
  v_source public.customers;
  v_row record;
  v_moved_bookings int := 0;
  v_skipped_bookings int := 0;
  v_moved_payments int := 0;
  v_skipped_payments int := 0;
  v_moved_recurring int := 0;
  v_skipped_recurring int := 0;
  v_moved_entitlements int := 0;
begin
  if p_target_customer_id = p_source_customer_id then
    raise exception 'SAME_CUSTOMER';
  end if;

  select * into v_target from public.customers where id = p_target_customer_id for update;
  if not found then
    raise exception 'TARGET_NOT_FOUND';
  end if;

  select * into v_source from public.customers where id = p_source_customer_id for update;
  if not found then
    raise exception 'SOURCE_NOT_FOUND';
  end if;

  if v_target.organization_id <> v_source.organization_id then
    raise exception 'DIFFERENT_ORGANIZATION';
  end if;

  if not public.is_organization_owner(v_target.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_target.profile_id is null then
    raise exception 'TARGET_MUST_HAVE_PROFILE';
  end if;

  -- Both rows already have their own account: there is no managed/gestionado
  -- side to fold here, this is not the conflict this function resolves.
  if v_source.profile_id is not null then
    raise exception 'ALREADY_CUSTOMER_OF_ORGANIZATION';
  end if;

  -- Bookings: try each one; the CONFIRMED-per-(customer, slot) unique
  -- index (ADR-0004/0011) is the real judge of what collides.
  for v_row in select id from public.bookings where customer_id = p_source_customer_id loop
    begin
      update public.bookings set customer_id = p_target_customer_id where id = v_row.id;
      v_moved_bookings := v_moved_bookings + 1;
    exception
      when unique_violation then
        v_skipped_bookings := v_skipped_bookings + 1;
    end;
  end loop;

  -- Payments: try each one; the ADR-0024 EXCLUDE on overlapping PAID
  -- periods per (customer, service) and the drop-in per-slot unique index
  -- are the real judges.
  for v_row in select id from public.payments where customer_id = p_source_customer_id loop
    begin
      update public.payments set customer_id = p_target_customer_id where id = v_row.id;
      v_moved_payments := v_moved_payments + 1;
    exception
      when unique_violation or exclusion_violation then
        v_skipped_payments := v_skipped_payments + 1;
    end;
  end loop;

  -- Recurring bookings: no DB constraint enforces "one active standing
  -- reservation per (customer, rule)" (ADR-0018 checks it in the RPC, not
  -- a unique index), so this is an explicit pre-check rather than a
  -- caught exception.
  for v_row in select id, schedule_rule_id from public.recurring_bookings where customer_id = p_source_customer_id loop
    if exists (
      select 1 from public.recurring_bookings
      where customer_id = p_target_customer_id
        and schedule_rule_id = v_row.schedule_rule_id
        and status = 'ACTIVE'
    ) then
      v_skipped_recurring := v_skipped_recurring + 1;
    else
      update public.recurring_bookings set customer_id = p_target_customer_id where id = v_row.id;
      v_moved_recurring := v_moved_recurring + 1;
    end if;
  end loop;

  -- Deprecated (ADR-0022/0024) and no longer read on any decision path:
  -- move all of it, there is no conflicting-window rule left to enforce.
  update public.service_entitlements
    set customer_id = p_target_customer_id
    where customer_id = p_source_customer_id;
  get diagnostics v_moved_entitlements = row_count;

  -- The phone moves to the target, freeing (organization_id, phone) on
  -- the source row -- otherwise the source keeps a phone nobody can
  -- reissue an activation to, and a future alta with that same number
  -- would collide with a ghost.
  if v_source.phone is not null then
    update public.customers set phone = null where id = p_source_customer_id;
    if v_target.phone is null then
      update public.customers set phone = v_source.phone where id = p_target_customer_id;
    end if;
  end if;

  update public.customers
    set is_active = false,
        cancelled_at = now(),
        cancelled_by = auth.uid(),
        cancellation_reason = 'ORGANIZATION_REMOVED',
        merged_into_customer_id = p_target_customer_id
    where id = p_source_customer_id;

  -- Any activation still pending on the source no longer points anywhere
  -- useful -- revoke it rather than leave a link that would try to claim
  -- an inactive, already-merged row.
  update public.customer_activations
    set revoked_at = now(), revoked_by = auth.uid()
    where customer_id = p_source_customer_id
      and redeemed_at is null
      and revoked_at is null;

  return jsonb_build_object(
    'moved_bookings', v_moved_bookings,
    'remaining_bookings_on_source', v_skipped_bookings,
    'moved_payments', v_moved_payments,
    'remaining_payments_on_source', v_skipped_payments,
    'moved_recurring_bookings', v_moved_recurring,
    'remaining_recurring_on_source', v_skipped_recurring,
    'moved_entitlements', v_moved_entitlements
  );
end;
$$;

comment on function public.merge_customers(uuid, uuid) is
  'ADR-0026 Sec 2.5. OWNER-only. Never fusiona automatically -- rows that would violate a real constraint on the target stay on the (now inactive) source row and are reported back, never guessed at or dropped.';

revoke execute on function public.merge_customers(uuid, uuid) from public, anon;
grant execute on function public.merge_customers(uuid, uuid) to authenticated;

-- ============================================================
-- 3. Hallazgo B -- LEFT JOIN so a managed customer stops being invisible
-- ============================================================
-- All four functions below had `join public.profiles p on p.id =
-- c.profile_id`: with profile_id nullable that INNER JOIN silently drops
-- every managed customer's row from the result set. A managed customer
-- with bookings and payments would be invisible on every one of these
-- screens -- the roster, the roll call, the collections summary, the
-- standing-reservations list. customer_payment_detail() (phase16:422) was
-- checked and does NOT join profiles at all (it joins services, and takes
-- customer_id directly with no name column), so it needs no fix -- this
-- closes the "sin confirmar" note in the ADR.

-- 3.1 organization_customers() -- phase8:392
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
  select
    c.id,
    c.profile_id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    c.is_active,
    c.created_at
  from public.customers c
  left join public.profiles p on p.id = c.profile_id
  where c.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  order by coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$$;

grant execute on function public.organization_customers(uuid) to authenticated;

-- 3.2 occurrence_bookings() -- phase16:232
create or replace function public.occurrence_bookings(p_slot_occurrence_id uuid)
returns table (
  booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.booking_status,
  attendance_status public.attendance_status,
  attendance_marked_at timestamptz,
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
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    b.status,
    b.attendance_status,
    b.attendance_marked_at,
    b.created_at
  from public.bookings b
  join public.customers c on c.id = b.customer_id
  left join public.profiles p on p.id = c.profile_id
  where b.slot_occurrence_id = p_slot_occurrence_id
    and public.is_organization_member(b.organization_id)
  order by coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$$;

grant execute on function public.occurrence_bookings(uuid) to authenticated;

-- 3.3 organization_payment_summary() -- phase16:372
create or replace function public.organization_payment_summary(
  p_organization_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  customer_id uuid,
  customer_name text,
  is_active boolean,
  services_count int,
  total numeric,
  paid numeric,
  pending numeric,
  rollup_status text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    c.is_active,
    count(distinct pay.service_id)::int,
    coalesce(sum(pay.amount) filter (where pay.status <> 'VOID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status = 'PAID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status in ('PENDING', 'OVERDUE')), 0),
    case
      when count(pay.id) filter (where pay.status <> 'VOID') = 0 then 'NO_PAYMENTS'
      when count(pay.id) filter (where pay.status = 'OVERDUE') > 0 then 'OVERDUE'
      when count(pay.id) filter (where pay.status in ('PENDING', 'OVERDUE')) = 0 then 'PAID'
      when count(pay.id) filter (where pay.status = 'PAID') = 0 then 'PENDING'
      else 'PARTIAL'
    end
  from public.customers c
  left join public.profiles p on p.id = c.profile_id
  left join public.payments pay
    on pay.customer_id = c.id
   and pay.period_start <= p_period_end
   and pay.period_end >= p_period_start
  where c.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  group by c.id, c.display_name, p.full_name, c.is_active
  order by coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$$;

grant execute on function public.organization_payment_summary(uuid, date, date) to authenticated;

-- 3.4 schedule_rule_standing_reservations() -- phase17:1511
create or replace function public.schedule_rule_standing_reservations(p_schedule_rule_id uuid)
returns table (
  recurring_booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    rb.id,
    rb.customer_id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    rb.status,
    rb.created_at,
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'CONFIRMED' and so.start_at >= now()),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED' and so.start_at >= now()),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason::text = 'OVER_PLAN_QUOTA' and so.start_at >= now())
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  left join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$$;

grant execute on function public.schedule_rule_standing_reservations(uuid) to authenticated;

-- ============================================================
-- Manual verification (no automated pgTAP harness exists in this repo --
-- run this against a freshly `supabase db reset`-ed database before the
-- demo; it is not executed by this migration):
--
--   -- Hallazgo A, for real this time (profile_id genuinely nullable):
--   -- 1. Create org A (owner_a), org B (owner_b, unrelated).
--   -- 2. As owner_a: create_managed_customer(org_a, 'Cliente Gestionado', null),
--   --    book it into a slot via admin_book_for_customer (needs a payment/plan
--   --    set up per ADR-0024, or a service with payment_required = false).
--   -- 3. As owner_b (a different auth.uid(), member of org B only, NOT a
--   --    member of org A): call cancel_booking(<that booking's id>).
--   -- 4. Expect: exception NOT_AUTHORIZED. If it silently succeeds, the
--   --    Hallazgo A fix from migration 19 regressed.
--
--   -- Hallazgo E:
--   -- PATCH .../customers?id=eq.<managed_row_id> { profile_id: <any uuid> }
--   -- as a STAFF/OWNER of that same organization via PostgREST directly.
--   -- Expect: PROFILE_LINK_NOT_ALLOWED.
--
--   -- Canje end-to-end:
--   -- issue_customer_activation() -> claim_customer_activation(token) as a
--   -- second, unrelated authenticated user -> customers.profile_id set,
--   -- customer_activations.redeemed_at set, second claim with the same
--   -- token from a third user -> ALREADY_REDEEMED.
-- ============================================================
