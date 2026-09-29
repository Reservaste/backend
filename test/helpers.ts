// Shared helpers for integration tests against a real (local) Supabase
// instance. See test/rls.cross-tenant.test.ts for why the default
// credentials below are safe to hardcode: they are the fixed demo values
// `supabase start` prints for a local project, never valid remotely.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const SUPABASE_URL = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
export const ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";
export const SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

export const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
const PASSWORD = "cross-tenant-test-password-123";

export interface SignedInUser {
  id: string;
  /**
   * The address this session authenticates as. Exposed because ADR-0034's
   * team invitation canje compares the session's email with the invited
   * one, so a test has to be able to talk about it.
   */
  email: string;
  client: SupabaseClient;
}

/**
 * `explicitEmail` exists for the ADR-0034 flow: the point of a team
 * invitation is that it is issued to an address that has no account yet, so
 * a test needs to invite first and create the account with that exact
 * address afterwards.
 */
export async function createSignedInUser(
  emailPrefix: string,
  explicitEmail?: string,
): Promise<SignedInUser> {
  const email =
    explicitEmail ??
    `${emailPrefix}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
  });
  if (error || !data.user) {
    throw new Error(`failed to create test user ${email}: ${error?.message}`);
  }

  const client = createClient(SUPABASE_URL, ANON_KEY);
  const { error: signInError } = await client.auth.signInWithPassword({ email, password: PASSWORD });
  if (signInError) {
    throw new Error(`failed to sign in test user ${email}: ${signInError.message}`);
  }

  return { id: data.user.id, email, client };
}

/**
 * Creating an organization is invite-gated (Phase 10). Tests mint their
 * own invite through the service-role client -- which is what the
 * platform owner's console does with an authenticated admin -- and
 * default to the unlimited plan so plan limits only apply where a test
 * asks for them.
 */
export async function createInvite(planCode = "full", overrides: Record<string, unknown> = {}) {
  const code = `T${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
  const { error } = await admin
    .from("organization_invites")
    .insert({ code, plan_code: planCode, ...overrides });
  if (error) {
    throw new Error(`failed to create invite: ${error.message}`);
  }
  return code;
}

export async function createOrganization(
  owner: SignedInUser,
  slugPrefix: string,
  planCode = "full",
) {
  const slug = `${slugPrefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const inviteCode = await createInvite(planCode);

  const { data, error } = await owner.client.rpc("create_organization_with_owner", {
    p_slug: slug,
    p_name: slug,
    p_timezone: "America/Montevideo",
    p_invite_code: inviteCode,
  });
  if (error || !data) {
    throw new Error(`failed to create organization ${slug}: ${error?.message}`);
  }
  return data as { id: string; slug: string };
}

/**
 * Creates a ServicePlan for a service (ADR-0024). Since Phase 17 a
 * Payment is anchored to a plan, so a service that is charged for needs
 * a price list before anyone can pay for it -- the same thing the
 * payments UI now has to do.
 *
 * ADR-0029: `service_plans.service_id` is gone -- a plan's covered
 * services live in `service_plan_services` (or are resolved live from
 * `applies_to_all_services`), and `validate_service_plan_scope()` is a
 * DEFERRED constraint trigger that fires at end-of-transaction. Two
 * separate PostgREST requests (insert the plan, then insert the link row)
 * are two separate transactions -- the first would commit, and INSIDE
 * that same commit the deferred check sees a plan with zero covered
 * services and rejects it with SERVICE_PLAN_SCOPE_EMPTY before a second
 * request ever gets a chance to run (confirmed against the real database,
 * not just reasoned about). That is exactly why production creates a
 * scoped plan through the `create_service_plan` RPC instead of a plain
 * insert (ADR-0004's "two `.from()` calls are two transactions" applied to
 * this new cross-table invariant) -- this helper goes through the same
 * RPC, reproducing the one-service PER_SERVICE case every existing test
 * wants. The public `args.serviceId` shape is unchanged, so none of the
 * ~30 call sites need to change.
 */
export async function createServicePlan(
  owner: SignedInUser,
  args: {
    organizationId: string;
    serviceId: string;
    name?: string;
    planKind?: "DROP_IN" | "WEEKLY_QUOTA" | "UNLIMITED";
    weeklyQuota?: number;
    price?: number;
    cycle?: "CALENDAR_MONTH" | "ROLLING_MONTH";
  },
): Promise<string> {
  const planKind = args.planKind ?? "UNLIMITED";
  const isDropIn = planKind === "DROP_IN";
  const { data, error } = await owner.client.rpc("create_service_plan", {
    p_organization_id: args.organizationId,
    p_name: args.name ?? (isDropIn ? "Clase suelta" : `Plan ${planKind} ${Math.random().toString(36).slice(2, 8)}`),
    p_description: null,
    p_price: args.price ?? 2000,
    p_plan_kind: planKind,
    p_weekly_quota: planKind === "WEEKLY_QUOTA" ? (args.weeklyQuota ?? 1) : null,
    p_billing_type: isDropIn ? "ONE_TIME" : "MONTHLY",
    p_billing_cycle: isDropIn ? null : (args.cycle ?? "CALENDAR_MONTH"),
    p_sort_order: 0,
    p_applies_to_all_services: false,
    p_service_ids: [args.serviceId],
    p_quota_scope: planKind === "WEEKLY_QUOTA" ? "PER_SERVICE" : null,
  });
  if (error || !data) throw new Error(`failed to create service plan: ${error?.message}`);
  return (data as { id: string }).id;
}

/**
 * The UNLIMITED plan a payment falls back to when nothing else is
 * specified -- which is what the Phase 17 compatibility bridge looks for,
 * and what the backfill gave every pre-existing service. Idempotent so a
 * test can make a service paid and pay for it without ordering worries.
 */
async function ensureUnlimitedPlan(
  owner: SignedInUser,
  serviceId: string,
  cycle: "CALENDAR_MONTH" | "ROLLING_MONTH" = "CALENDAR_MONTH",
  price = 2000,
): Promise<string> {
  // ADR-0029: service_plans has no service_id column anymore -- filtering
  // "does an UNLIMITED plan cover this service" goes through the join
  // table (an embedded-resource filter, `!inner` so the embed also
  // restricts the parent rows instead of just annotating them).
  const { data: existing } = await owner.client
    .from("service_plans")
    .select("id, service_plan_services!inner(service_id)")
    .eq("service_plan_services.service_id", serviceId)
    .eq("plan_kind", "UNLIMITED")
    .eq("is_active", true)
    .limit(1);
  if (existing && existing.length > 0) return existing[0]!.id as string;

  const { data: service, error } = await owner.client
    .from("services")
    .select("id, organization_id, name")
    .eq("id", serviceId)
    .single();
  if (error || !service) throw new Error(`failed to read service ${serviceId}: ${error?.message}`);

  return createServicePlan(owner, {
    organizationId: service.organization_id as string,
    serviceId,
    name: `${service.name} mensual`,
    planKind: "UNLIMITED",
    price,
    cycle,
  });
}

/**
 * Makes a service payment-gated (ADR-0022) and gives it the UNLIMITED
 * plan that reproduces the pre-ADR-0024 behaviour. Returns the plan id
 * for the tests that need to talk about the plan itself.
 */
export async function makeServicePaid(
  owner: SignedInUser,
  serviceId: string,
  cycle: "CALENDAR_MONTH" | "ROLLING_MONTH" = "CALENDAR_MONTH",
  price = 2000,
): Promise<string> {
  const { error } = await owner.client
    .from("services")
    .update({
      billing_type: "MONTHLY",
      billing_cycle: cycle,
      price,
      payment_required: true,
    })
    .eq("id", serviceId);
  if (error) throw new Error(`failed to make service paid: ${error.message}`);

  return ensureUnlimitedPlan(owner, serviceId, cycle, price);
}

/** Days from today as an ISO date, for readable payment periods in tests. */
export function isoDate(offsetDays: number): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

/**
 * The org timezone every fixture in this file hardcodes (createOrganization()
 * above). Fixed offset, no DST: Uruguay does not observe it.
 */
const FIXTURE_ORG_UTC_OFFSET_HOURS = 3; // America/Montevideo = UTC-3

/**
 * A weekdayOffset (0-6) for `createRule(f, weekdayOffset)`-style test
 * helpers whose next occurrence is guaranteed to land within the CURRENT
 * calendar month, in the organization's local timezone -- for the tests
 * that specifically need that (asserting on `upcoming_unpaid` /
 * `upcoming_beyond_period` when the customer has no payment covering
 * today).
 *
 * Why this exists: `customer_billing_horizon()` (Fase 25,
 * 20260923120000_phase25_payment_duplicates_and_billing_horizon.sql) falls
 * back to "end of the CURRENT LOCAL calendar month" when a customer has no
 * PAID payment covering today. A fixed weekdayOffset (e.g. "in 2 days")
 * silently assumes there is always room left in the current month before
 * that fallback horizon -- false within the last few days of any month.
 * That broke CI for real on 2026-09-29
 * (test/phase25.production-feedback.test.ts, "un cliente que NO pagó el mes
 * en curso SÍ figura con fechas esperando pago" -- the offset landed on
 * 1/10, one day past the 30/09 fallback horizon). The same pattern was
 * already fixed once for test/phase11.standing-reservations.test.ts on
 * 2026-09-28 (see .claude/knowledge/curation-inbox.md) with a narrower,
 * file-local `weekdayWithinCurrentMonth()` that had a known, non-blocking
 * gap (it compared against the UTC calendar month, not the org's local
 * one). This is the general version, closing that gap too, used wherever
 * the same fragile assumption shows up.
 *
 * This walks the actual arithmetic the database uses instead of assuming a
 * fixed offset is safe:
 *
 *  - generate_slot_occurrences_for_rule() anchors the occurrence's calendar
 *    day on Postgres `current_date`, which runs in UTC on this stack
 *    (confirmed live: `show timezone` -> UTC) -- NOT the org's local
 *    timezone.
 *  - That UTC calendar day + local_start_time is then interpreted AS the
 *    org's local wall-clock time (`... AT TIME ZONE v_org.timezone`) to get
 *    `start_at`, so `slot_local_date()` (which converts `start_at` back via
 *    the same org timezone) always round-trips to that same UTC-anchored
 *    calendar day.
 *  - `customer_billing_horizon()`'s fallback instead compares against
 *    `now() AT TIME ZONE org.timezone` -- the org's LOCAL current date, not
 *    UTC's `current_date`. Near midnight UTC (00:00-03:00, since Montevideo
 *    is UTC-3) those two "todays" can be different calendar dates -- flagged
 *    as a non-blocking follow-up in curation-inbox.md (2026-09-28) and
 *    closed here by computing the local month-end from the org's actual
 *    local "today" instead of UTC's.
 *
 * Every fixture in this codebase hardcodes `p_timezone: "America/Montevideo"`
 * (createOrganization() above), so a fixed UTC-3 offset is enough here --
 * this does not need a general IANA-timezone resolver.
 *
 * Edge case: offset 0 (today) trivially lands within the current month, so
 * the only way NO offset in 0-6 qualifies is if TODAY is the org-local last
 * day of the month AND today's `localStartTime` has already passed locally
 * -- then every later offset is already next month. That is an unavoidable,
 * roughly 1-in-30 (and further narrowed to a specific hour range) residual
 * boundary, not something a fixture can route around without mocking the
 * clock -- not worth it for a test helper. The fallback below picks
 * tomorrow anyway and accepts that a test relying on this helper could fail
 * only inside that narrow window.
 */
export function nextWeekdayWithinCurrentMonth(localStartTime = "09:00"): number {
  const [hh, mm] = localStartTime.split(":").map(Number);
  const now = new Date();
  const nowMs = now.getTime();

  // The calendar day generate_slot_occurrences_for_rule() anchors on
  // (Postgres current_date, UTC).
  const todayUtcMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());

  // The org's LOCAL "today", which is what customer_billing_horizon()'s
  // fallback uses to compute "end of this calendar month".
  const localNow = new Date(nowMs - FIXTURE_ORG_UTC_OFFSET_HOURS * 3_600_000);
  const localMonthEndUtcMs = Date.UTC(localNow.getUTCFullYear(), localNow.getUTCMonth() + 1, 0);

  for (let offset = 0; offset <= 6; offset++) {
    const dayUtcMs = todayUtcMs + offset * 86_400_000;
    // start_at = (day + local_start_time) AT TIME ZONE org.timezone --
    // Montevideo local wall-clock -> UTC is a fixed "+3h" (no DST).
    const startAtMs = dayUtcMs + (hh + FIXTURE_ORG_UTC_OFFSET_HOURS) * 3_600_000 + mm * 60_000;

    const isStrictlyFuture = startAtMs > nowMs;
    // slot_local_date() round-trips back to this same calendar day.
    const withinLocalMonth = dayUtcMs <= localMonthEndUtcMs;

    if (isStrictlyFuture && withinLocalMonth) return offset;
  }

  // Residual boundary above -- see doc comment.
  return 1;
}

/**
 * Registers a payment covering [from, to] for a customer on a service.
 * Since ADR-0024 a payment is anchored to a ServicePlan: when the caller
 * does not name one, the service gets (or reuses) its UNLIMITED plan,
 * which is the plan the compatibility bridge resolves to and the one
 * that reproduces the old "the month is paid, book what you like"
 * behaviour. Pass `servicePlanId` to pay for a quota or drop-in plan.
 */
export async function payFor(
  owner: SignedInUser,
  args: {
    organizationId: string;
    customerId: string;
    serviceId: string;
    from: string;
    to: string;
    status?: "PAID" | "PENDING" | "OVERDUE" | "VOID";
    amount?: number;
    servicePlanId?: string;
    slotOccurrenceId?: string;
  },
) {
  const servicePlanId = args.servicePlanId ?? (await ensureUnlimitedPlan(owner, args.serviceId));

  const { data, error } = await owner.client
    .from("payments")
    .insert({
      organization_id: args.organizationId,
      customer_id: args.customerId,
      service_id: args.serviceId,
      service_plan_id: servicePlanId,
      slot_occurrence_id: args.slotOccurrenceId ?? null,
      period_start: args.from,
      period_end: args.to,
      status: args.status ?? "PAID",
      amount: args.amount ?? 2000,
      created_by: owner.id,
    })
    .select()
    .single();
  return { data, error };
}

/**
 * The first occurrence a booking RPC will actually accept: future ones.
 * Taking the earliest outright picks today's class when the rule's
 * weekday is today and its hour has passed, which made several tests
 * fail only on the right day of the week.
 */
export async function firstFutureOccurrence(owner: SignedInUser, scheduleRuleId: string) {
  const { data } = await owner.client
    .from("slot_occurrences")
    .select("id, start_at")
    .eq("schedule_rule_id", scheduleRuleId)
    .gte("start_at", new Date().toISOString())
    .order("start_at", { ascending: true })
    .limit(1);
  if (!data || data.length === 0) throw new Error("no future occurrence for rule");
  return data[0]! as { id: string; start_at: string };
}
