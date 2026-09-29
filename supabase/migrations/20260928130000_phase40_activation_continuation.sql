-- ============================================================
-- Phase 40 -- Activation continuation nonce (ADR-0040)
-- ============================================================
-- Problem (production report, diagnosed live -- see ADR-0040): the
-- httpOnly activation_token cookie (ADR-0026 Sec 2.4) is written by
-- /activar/[token] in whatever browser context the person tapped the
-- WhatsApp link in. Confirming an email or finishing Google OAuth can
-- land them in a DIFFERENT context (Mail app, the system browser --
-- Google has blocked OAuth inside embedded WebViews since 2021), which
-- has its own cookie jar. /activar/continuar in that second context never
-- sees the cookie, even though the token is still valid for its full 72h.
--
-- Fix: a short-lived (30 min), single-use, opaque nonce that rides the
-- one channel that DOES survive the context switch -- the
-- emailRedirectTo/next querystring Supabase Auth already round-trips
-- through the email confirmation link or the OAuth callback. Redeeming
-- the nonce only ever hands back the real activation token to be replanted
-- as a cookie in the NEW context.
--
-- Corrected 2026-09-28 (post security-engineer review, see ADR-0040 "Corrección
-- post-review de seguridad"): claim_customer_activation() (Phase 21) does NOT
-- check that the session's email matches the invited customer -- it only
-- requires auth.uid() is not null. So the nonce is, in effect, equivalent to
-- the real token for the whole flow: whoever holds it can claim the customer.
-- This is accepted (same exposure model as the token itself, ADR-0026), not
-- mitigated by an email check that does not exist -- see the ADR for the
-- full residual-risk writeup.
--
-- Ownership boundary: this migration only adds
-- customer_activation_continuations and the two RPCs below. It does not
-- touch customer_activations, claim_customer_activation(), or anything
-- else from Phase 21/32/33.

-- ============================================================
-- 1. customer_activation_continuations
-- ============================================================
create table public.customer_activation_continuations (
  id uuid primary key default gen_random_uuid(),
  -- Which activation this continuation is for. Not itself a secret --
  -- just a row id -- so it needs no hashing, unlike the two columns below.
  activation_id uuid not null references public.customer_activations (id) on delete cascade,
  -- Corrected 2026-09-28 (security-engineer gate, ADR-0040 "Corrección
  -- post-review de seguridad"): the original design stored this in clear
  -- text (`activation_token text`), on the theory that the 30-min TTL
  -- bounded the exposure the same way customer_activations bounds its own
  -- token. That theory broke on a real path: if the nonce is never
  -- redeemed (e.g. the person logs back in with a password in the SAME
  -- browser context, which never touches /auth/callback), nothing ever
  -- nulls this column -- the row (and the clear token inside it) sits
  -- there past the 30 minutes, indefinitely, and the CHECK constraint
  -- below (which requires a non-null token while used_at is null) makes
  -- it impossible to null the column without deleting the row.
  --
  -- Fix: encrypt at rest with the nonce itself as the symmetric key
  -- (pgcrypto's pgp_sym_encrypt/pgp_sym_decrypt, AES-256), not the clear
  -- nonce -- issue_activation_continuation() only ever has the clear
  -- nonce in a local variable it returns to the caller, never persists it
  -- (same as customer_activations.token_hash: it stores sha256(nonce), so
  -- the nonce itself is not sitting anywhere in this database either).
  -- This gives the same guarantee as the sha256 hash elsewhere: no row, by
  -- itself, ever holds a combination of columns that reconstructs the
  -- secret -- decrypting requires the clear nonce, which only ever existed
  -- in the RPC return value and in whatever URL/email carried it
  -- client-side, never in a table this database can read back.
  --
  -- Still nullable, not `not null`: redeem_activation_continuation() nulls
  -- this out in the very update that sets used_at, so by design it holds a
  -- value before redemption and never again afterwards -- and now the
  -- purge-on-issue below (see issue_activation_continuation()) deletes any
  -- row that expired unused, so an abandoned nonce no longer leaves an
  -- encrypted blob sitting around forever either.
  activation_token_enc bytea,
  -- sha256(nonce), same reasoning as customer_activations.token_hash: an
  -- unguessable 256-bit value, not a password, so a slow KDF buys nothing
  -- and costs latency on the redemption path.
  nonce_hash bytea not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  used_at timestamptz,
  -- Mirrors customers_claimed_requires_profile's style (Phase 21): the
  -- encrypted token and "not yet used" are the same fact seen from two
  -- columns, so an insert/update that leaves them disagreeing is a bug,
  -- not valid data.
  constraint customer_activation_continuations_token_matches_used check (
    (used_at is null and activation_token_enc is not null)
    or (used_at is not null and activation_token_enc is null)
  )
);

comment on table public.customer_activation_continuations is
  'ADR-0040: one-time, 30-min nonce that lets an in-flight customer activation (ADR-0026) survive a browser-context switch during login/signup/OAuth. nonce_hash is sha256 of a 256-bit CSPRNG value, minted by new_activation_token() (Phase 34); the clear nonce exists only in the return value of issue_activation_continuation(). activation_token_enc is the real activation token (ADR-0026), encrypted at rest with the clear nonce as the symmetric key -- see column comment.';

comment on column public.customer_activation_continuations.activation_token_enc is
  'ADR-0040 (corrected post security-review): the real activation token (ADR-0026), symmetrically encrypted (pgp_sym_encrypt, AES-256) with the clear nonce as the key -- never the clear token itself, unlike the original design. Decrypted by redeem_activation_continuation() using the nonce the caller just proved possession of, and set to null in that same update. Never left non-null for an expired-unused row either: issue_activation_continuation() purges those before minting a new one.';

create index customer_activation_continuations_activation_idx
  on public.customer_activation_continuations (activation_id);

alter table public.customer_activation_continuations enable row level security;
-- Deliberately no policy at all, and no grant to anon/authenticated/
-- service_role -- identical reasoning to customer_activations (Phase 21):
-- RLS with zero policies denies every row regardless of grants, and the
-- only door onto this table for a PostgREST request is the two SECURITY
-- DEFINER RPCs below, which read/write it as the function owner and
-- bypass RLS entirely.

-- ============================================================
-- 2. issue_activation_continuation() -- reads the real token, mints a nonce
-- ============================================================
-- Called server-side (never given the token via a client-supplied
-- parameter that the client could tamper with -- the caller already read
-- it from the httpOnly cookie itself, same trust boundary as
-- claimActivation() in app/actions/activation.ts). Anon-callable on
-- purpose: this runs from /activar/continuar exactly in the branch where
-- there is NO Supabase session yet, so the PostgREST request necessarily
-- carries the anon key. Same threat model as the token itself (ADR-0026
-- Sec 2.2): possessing the 256-bit secret is the authorization, there is
-- no auth.uid()-based branch here to gate on.
create or replace function public.issue_activation_continuation(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_act public.customer_activations;
  v_nonce text;
  v_hash bytea;
  v_live_count int;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'INVALID_TOKEN';
  end if;

  -- `for update`: the whole purge-count-insert sequence below has to see a
  -- consistent picture of this activation's live continuations under
  -- concurrent calls (e.g. the person double-taps the link, or a retry
  -- races a real request) -- without the lock, two transactions could each
  -- count 9 live rows and both insert a 10th, blowing past the limit.
  select * into v_act
    from public.customer_activations
    where token_hash = extensions.digest(trim(p_token), 'sha256')
    for update;

  -- Same vocabulary claim_customer_activation() already uses for a token
  -- that does not resolve to a live activation -- no new error taxonomy.
  if not found then
    raise exception 'INVALID_TOKEN';
  end if;

  if v_act.revoked_at is not null then
    raise exception 'ACTIVATION_REVOKED';
  end if;

  if v_act.redeemed_at is not null then
    raise exception 'ALREADY_REDEEMED';
  end if;

  if v_act.expires_at <= now() then
    raise exception 'ACTIVATION_EXPIRED';
  end if;

  -- Purge expired-unused continuations for this activation before counting
  -- or inserting. Closes the same gap the encrypted column is meant to
  -- close (see column comment): a nonce nobody redeemed (e.g. the person
  -- logged back in with a password in the same browser context, never
  -- hitting /auth/callback) would otherwise sit here, encrypted blob and
  -- all, forever.
  delete from public.customer_activation_continuations
    where activation_id = v_act.id
      and used_at is null
      and expires_at < now();

  select count(*) into v_live_count
    from public.customer_activation_continuations
    where activation_id = v_act.id
      and used_at is null;

  if v_live_count >= 10 then
    raise exception 'TOO_MANY_CONTINUATIONS';
  end if;

  select t.token, t.token_hash into v_nonce, v_hash from public.new_activation_token() t;

  insert into public.customer_activation_continuations (
    activation_id, activation_token_enc, nonce_hash, expires_at
  ) values (
    v_act.id,
    -- The clear nonce is the symmetric key -- it is never itself persisted
    -- anywhere (only nonce_hash, sha256 of it, is), so encrypting with it
    -- gives the same "no row alone reconstructs the secret" guarantee as
    -- the sha256 hash does for customer_activations.token_hash.
    extensions.pgp_sym_encrypt(trim(p_token), v_nonce, 'cipher-algo=aes256'),
    v_hash,
    now() + interval '30 minutes'
  );

  return v_nonce;
end;
$$;

comment on function public.issue_activation_continuation(text) is
  'ADR-0040: called by /activar/continuar when the activation cookie exists but there is no session yet, right before redirecting through /login (and from there possibly /signup, email confirmation, or Google OAuth -- any of which can switch browser context and strand the httpOnly cookie). Returns a 30-min, one-time nonce meant to travel in emailRedirectTo/next as ?c=<nonce>; the real token is read here from the cookie server-side, encrypted with the nonce as key, and never returned to the client. Purges expired-unused continuations for this activation and caps live ones at 10 (TOO_MANY_CONTINUATIONS) before minting a new one.';

revoke execute on function public.issue_activation_continuation(text) from public;
grant execute on function public.issue_activation_continuation(text) to anon, authenticated;

-- ============================================================
-- 3. redeem_activation_continuation() -- the nonce buys back the token
-- ============================================================
-- Called from /auth/callback right after exchangeCodeForSession(), in
-- whatever browser context just finished authenticating. Deliberately
-- does not branch on auth.uid(): the nonce itself is the one-time secret
-- that authorizes this (same model as issue_activation_continuation()
-- above), and requiring a session here would only add a failure mode if
-- the just-exchanged session has not yet propagated to this exact
-- request's Supabase client. Redeeming does not activate anything by
-- itself -- it only lets the caller replant the cookie so the existing
-- claim_customer_activation() flow (session + explicit click) runs
-- unchanged from here.
create or replace function public.redeem_activation_continuation(p_nonce text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cont public.customer_activation_continuations;
  v_act_alive boolean;
  v_token text;
begin
  if p_nonce is null or length(trim(p_nonce)) = 0 then
    raise exception 'INVALID_CONTINUATION';
  end if;

  select * into v_cont
    from public.customer_activation_continuations
    where nonce_hash = extensions.digest(trim(p_nonce), 'sha256')
    for update;

  -- A single generic error for "does not exist" / "expired" / "already
  -- used" on purpose (unlike claim_customer_activation(), which can afford
  -- to be specific because reaching that point already required
  -- possessing the real token): distinguishing these three here would not
  -- inform an attacker who lacks the nonce any better, but would cost a
  -- one-line, low-value distinction in exchange for a new vocabulary this
  -- flow does not otherwise need.
  if not found or v_cont.used_at is not null or v_cont.expires_at <= now() then
    raise exception 'INVALID_CONTINUATION';
  end if;

  -- The nonce itself can be perfectly valid while the activation it points
  -- at has moved on underneath it (revoked by staff, already claimed from
  -- the original browser context, or simply expired past its 72h) --
  -- issue_activation_continuation() already checked this at mint time, but
  -- redemption can happen minutes later. Same generic error as above, for
  -- the same reason: which of the three it is does not need to leak here.
  select (revoked_at is null and redeemed_at is null and expires_at > now())
    into v_act_alive
    from public.customer_activations
    where id = v_cont.activation_id;

  if not coalesce(v_act_alive, false) then
    raise exception 'INVALID_CONTINUATION';
  end if;

  -- The nonce the caller just proved possession of (matched via nonce_hash
  -- above) is the decryption key -- see the column/table comments for why
  -- this gives the same "no row alone reconstructs the secret" guarantee
  -- as the sha256 hash elsewhere in this mechanism.
  v_token := extensions.pgp_sym_decrypt(v_cont.activation_token_enc, trim(p_nonce));

  -- Marks used AND wipes the encrypted token in the same statement -- the
  -- row keeps existing (used_at is the permanent record a continuation was
  -- issued and spent) but stops holding the encrypted secret in this table
  -- from the moment it has served its purpose. The `for update` lock above
  -- already serializes concurrent redemptions of the same nonce (a second
  -- transaction blocks until the first commits, then re-reads the now-used
  -- row and falls into the branch above); `and used_at is null` here is
  -- defense in depth on top of that, not the only guard.
  update public.customer_activation_continuations
    set used_at = now(), activation_token_enc = null
    where id = v_cont.id
      and used_at is null;

  if not found then
    raise exception 'INVALID_CONTINUATION';
  end if;

  return v_token;
end;
$$;

comment on function public.redeem_activation_continuation(text) is
  'ADR-0040: the ?c=<nonce> counterpart to issue_activation_continuation(). Valid, unused, unexpired nonce, whose underlying activation is still live (not revoked/claimed/expired) -> decrypts the token with the nonce as key, marks the row used (atomically, so a second attempt with the same nonce -- even immediately after -- fails), and returns the real activation token, meant to be replanted as the activation_token cookie by /auth/callback in this (new) browser context. Invalid/expired/already-used nonce and dead activation all raise the same INVALID_CONTINUATION, deliberately not distinguishing which.';

revoke execute on function public.redeem_activation_continuation(text) from public;
grant execute on function public.redeem_activation_continuation(text) to anon, authenticated;

-- ============================================================
-- 4. Defense in depth (non-blocking per security-engineer, applied anyway)
-- ============================================================
-- RLS with zero policies already denies every row to anon/authenticated
-- regardless of grants (same reasoning as customer_activations, Phase 21).
-- This is an explicit, redundant belt-and-suspenders: even if a future
-- migration ever added a policy here by mistake, no grant means PostgREST
-- still has no door onto this table for anon/authenticated -- only the two
-- SECURITY DEFINER RPCs above, which read/write as the function owner.
revoke all on table public.customer_activation_continuations from anon, authenticated;
