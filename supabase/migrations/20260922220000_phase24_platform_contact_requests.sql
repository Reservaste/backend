-- ============================================================
-- Phase 24 -- landing contact requests (ADR-0030, resolution 2)
-- ============================================================
-- The landing's primary CTA moves from a self-service "empezar gratis"
-- (organization creation is invite-gated, ADR-0017) to a `/contacto` form.
-- This migration is the minimal capture mechanism for that form's
-- submissions: a small, isolated table, visible only to the platform
-- admin from `/admin`. It does not touch organizations, plans, services,
-- booking or any existing table -- purely additive.
--
-- Access model, same shape as customer_activations (Phase 21):
-- RLS enabled with zero policies denies every row to anon/authenticated
-- outright -- this alone is sufficient and is what's actually tested
-- below (Supabase DOES grant default table privileges to anon/
-- authenticated on new tables; nothing in this repo revokes them at the
-- table level, so RLS-with-zero-policies is the real and only defence
-- here, not an absence of grants). The only doors onto this table are
-- the SECURITY DEFINER RPCs below, which read/write it as the function
-- owner and bypass RLS entirely.
--
-- Rate limiting: two tiers, both real. `origin_ip` is the primary
-- boundary (5/hour per origin, see submit_platform_contact_request()),
-- the platform-wide count is a generous backstop (200/hour) against a
-- distributed flood, not the enforcement boundary. This replaces an
-- earlier version of this migration that only had a single global
-- count(*) (20/hour, 100/day, no origin dimension) -- that was a
-- security-review finding: a single anonymous script making one request
-- every few minutes exhausts the shared hourly quota for every visitor
-- on the planet, and the only public commercial entry point left after
-- ADR-0030 resolution 2 (organization signup stays invite-gated, per
-- ADR-0017) is this exact form.
--
-- IP header, verified against `supabase start` locally (not assumed):
-- a SECURITY DEFINER RPC can read `current_setting('request.headers',
-- true)::json` and it does carry request headers set by the gateway in
-- front of PostgREST. Confirmed empirically that the local gateway (Kong)
-- (a) always sets `x-real-ip` to its own view of the TCP peer and
-- OVERWRITES any client-supplied `x-real-ip`, and (b) APPENDS its own
-- view of the peer as the last entry of `x-forwarded-for`, after any
-- client-supplied values -- a client can prepend fake entries to
-- `x-forwarded-for` but cannot control the last one. Both were tested by
-- sending spoofed values for each header directly to the local RPC and
-- inspecting what the database session actually saw. `x-real-ip` is used
-- as the primary source, the last hop of `x-forwarded-for` as fallback,
-- for defence against either header being absent in a given deployment.
--
-- Known limitation of the current deployment (ADR-0021): the `/contacto`
-- form is submitted through a Next.js server action
-- (frontend/app/actions/contact.ts), which calls this RPC server-side
-- from the droplet -- not from the visitor's browser directly. That
-- means all traffic relayed through our own frontend shares one apparent
-- origin (the droplet's outbound IP) as seen by Supabase, while a script
-- hammering this RPC directly (it's public/anon, reachable with the
-- anon key embedded in the frontend bundle) shows its own real IP. This
-- still closes the concrete attack described above (one script, one
-- origin, direct calls) without touching the frontend, and at this
-- product's current traffic volume (single-digit customers) legitimate
-- frontend-relayed submissions sharing one bucket is not a realistic
-- false-positive risk. Precisely isolating each browser visitor would
-- require the frontend to forward the real visitor IP explicitly (out of
-- scope here -- no frontend changes this round; flagged as a follow-up
-- if this table ever sees meaningful organic volume).

create table public.platform_contact_requests (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  phone text,
  business_type text,
  message text not null,
  created_at timestamptz not null default now(),
  -- Origin of the request as derived server-side by
  -- submit_platform_contact_request() from request headers -- never a
  -- caller-supplied parameter (nothing invokes an INSERT directly, RLS
  -- blocks that). 'unknown' when neither x-real-ip nor x-forwarded-for
  -- is present, which should not happen in practice but must not
  -- silently skip rate-limit scoping if it does. Retained on the row
  -- (not just used transiently) so the rate limit can look back at
  -- prior requests from the same origin.
  origin_ip text not null default 'unknown',
  -- Optional triage: the platform admin marks a lead as followed up.
  -- Nullable pair, no separate "handled by whom without a timestamp"
  -- state -- same auditing shape as cancelledAt/cancelledBy elsewhere,
  -- minus cancellation semantics (there is nothing to cancel here).
  handled_at timestamptz,
  handled_by uuid references public.profiles (id),
  constraint platform_contact_requests_name_length
    check (length(trim(name)) between 1 and 200),
  -- "Mínimamente razonable" per the task, not full RFC 5322 -- this is a
  -- lead capture form, not an account signup.
  constraint platform_contact_requests_email_format
    check (length(email) <= 320 and email ~* '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  -- Same E.164 shape as customers.phone (Phase 21).
  constraint platform_contact_requests_phone_e164
    check (phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'),
  constraint platform_contact_requests_message_length
    check (length(trim(message)) between 1 and 4000),
  constraint platform_contact_requests_business_type_length
    check (business_type is null or length(trim(business_type)) <= 120),
  constraint platform_contact_requests_handled_by_needs_handled_at
    check (handled_by is null or handled_at is not null)
);

comment on table public.platform_contact_requests is
  'ADR-0030: anonymous submissions from the public landing /contacto form. Insert-only from the public side (submit_platform_contact_request()); readable/markable only by is_platform_admin() (platform_contact_requests(), mark_contact_request_handled()).';
comment on column public.platform_contact_requests.business_type is
  'Free text ("consultorio", "estudio de pilates", ...), never a closed enum -- the product is generic (CLAUDE.md).';
comment on column public.platform_contact_requests.handled_at is
  'Set by mark_contact_request_handled(). Null means the platform admin has not followed up yet.';
comment on column public.platform_contact_requests.origin_ip is
  'Derived server-side from request headers (x-real-ip, falling back to the last hop of x-forwarded-for) by submit_platform_contact_request(). Scopes the per-origin rate limit -- see the migration header comment for how it was verified and its known limitation under the current deployment.';

-- Backs the global rate-limit count(*) query and the admin listing's
-- `order by created_at desc`.
create index platform_contact_requests_created_idx
  on public.platform_contact_requests (created_at);

-- Backs the per-origin rate-limit count(*) query.
create index platform_contact_requests_origin_created_idx
  on public.platform_contact_requests (origin_ip, created_at);

alter table public.platform_contact_requests enable row level security;
-- Deliberately zero policies -- RLS with no policies denies every row to
-- every role outright, regardless of Supabase's default table grants to
-- anon/authenticated (which exist and are not revoked here). See the
-- header comment above.

-- ============================================================
-- submit_platform_contact_request() -- PUBLIC, anonymous
-- ============================================================
create or replace function public.submit_platform_contact_request(
  p_name text,
  p_email text,
  p_message text,
  p_phone text default null,
  p_business_type text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_email text;
  v_phone text;
  v_message text;
  v_business_type text;
  v_headers json;
  v_ip text;
  v_count int;
  v_id uuid;
begin
  v_name := nullif(trim(coalesce(p_name, '')), '');
  if v_name is null or length(v_name) > 200 then
    raise exception 'INVALID_NAME';
  end if;

  v_email := nullif(lower(trim(coalesce(p_email, ''))), '');
  if v_email is null or length(v_email) > 320 or v_email !~* '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'INVALID_EMAIL';
  end if;

  v_message := nullif(trim(coalesce(p_message, '')), '');
  if v_message is null or length(v_message) > 4000 then
    raise exception 'INVALID_MESSAGE';
  end if;

  -- Same normalization as create_managed_customer() (Phase 21): strip
  -- everything but digits/+, prepend + if missing, then enforce E.164.
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if v_phone is not null then
    if left(v_phone, 1) <> '+' then
      v_phone := '+' || v_phone;
    end if;
    if v_phone !~ '^\+[1-9][0-9]{6,14}$' then
      raise exception 'INVALID_PHONE';
    end if;
  end if;

  v_business_type := nullif(trim(coalesce(p_business_type, '')), '');
  if v_business_type is not null and length(v_business_type) > 120 then
    raise exception 'INVALID_BUSINESS_TYPE';
  end if;

  -- Origin (see header comment for verification evidence and the known
  -- limitation of the current deployment). x-real-ip first: the gateway
  -- overwrites it with its own view of the TCP peer on every request, a
  -- client cannot forge it. Falls back to the last hop of
  -- x-forwarded-for (also gateway-appended, also unforgeable, unlike
  -- earlier entries in that same header). 'unknown' if neither is set.
  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_ip := coalesce(
    nullif(trim(v_headers ->> 'x-real-ip'), ''),
    nullif(trim(split_part(v_headers ->> 'x-forwarded-for', ',', -1)), ''),
    'unknown'
  );

  -- Serializes the whole check-then-insert critical section below so the
  -- thresholds can never be raced past under concurrency -- same pattern
  -- as book_slot() (ADR-0004), adapted to a table with no parent row to
  -- lock. A single global key rather than one keyed by v_ip: at this
  -- table's expected volume (a landing contact form) the extra
  -- serialization across unrelated origins is immaterial, and a
  -- per-origin-only lock would leave the *global* threshold below
  -- racy under a burst spread across many distinct origins. Revisit if
  -- this table ever sees real concurrent load from unrelated legitimate
  -- origins.
  perform pg_advisory_xact_lock(hashtext('platform_contact_requests_rate_limit'));

  -- Real limit: per origin. 5/hour is generous for one person submitting
  -- the form (including a retry after a typo), tight enough to stop a
  -- single-origin script. Both branches below raise the same exception
  -- string on purpose -- distinguishing "hit your own per-origin limit"
  -- from "hit the platform-wide ceiling" would let an anonymous caller
  -- infer lead volume by probing which one trips first.
  select count(*) into v_count
    from public.platform_contact_requests
    where created_at > now() - interval '1 hour'
      and origin_ip = v_ip;
  if v_count >= 5 then
    raise exception 'RATE_LIMITED';
  end if;

  -- Backstop: platform-wide, generous, not the enforcement boundary --
  -- guards against a flood distributed across many origins rather than
  -- one script from one origin.
  select count(*) into v_count
    from public.platform_contact_requests
    where created_at > now() - interval '1 hour';
  if v_count >= 200 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into public.platform_contact_requests (name, email, phone, business_type, message, origin_ip)
  values (v_name, v_email, v_phone, v_business_type, v_message, v_ip)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.submit_platform_contact_request(text, text, text, text, text) is
  'ADR-0030: public insert for the /contacto form. No auth required by design (anonymous landing visitors). Validates format/length, then applies a two-tier rate limit (per-origin real limit + platform-wide backstop) under a single advisory lock before writing. See the migration header comment for the origin-IP derivation and its verification.';

revoke execute on function public.submit_platform_contact_request(text, text, text, text, text) from public;
grant execute on function public.submit_platform_contact_request(text, text, text, text, text) to anon, authenticated;

-- ============================================================
-- platform_contact_requests() -- ADMIN read, same pattern as
-- platform_organizations()/platform_invites() (Phase 10)
-- ============================================================
create or replace function public.platform_contact_requests()
returns setof public.platform_contact_requests
language sql
stable
security definer
set search_path = public
as $$
  select * from public.platform_contact_requests
  where public.is_platform_admin()
  order by created_at desc;
$$;

revoke execute on function public.platform_contact_requests() from public, anon;
grant execute on function public.platform_contact_requests() to authenticated;

-- ============================================================
-- mark_contact_request_handled() -- ADMIN write
-- ============================================================
create or replace function public.mark_contact_request_handled(p_id uuid)
returns public.platform_contact_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.platform_contact_requests;
begin
  if not public.is_platform_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Idempotent: re-marking an already-handled row keeps its original
  -- handled_at/handled_by instead of overwriting who/when.
  update public.platform_contact_requests
    set handled_at = coalesce(handled_at, now()),
        handled_by = coalesce(handled_by, auth.uid())
    where id = p_id
    returning * into v_row;

  if not found then
    raise exception 'CONTACT_REQUEST_NOT_FOUND';
  end if;

  return v_row;
end;
$$;

revoke execute on function public.mark_contact_request_handled(uuid) from public, anon;
grant execute on function public.mark_contact_request_handled(uuid) to authenticated;
