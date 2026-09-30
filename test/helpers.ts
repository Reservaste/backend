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

  // Contra un proyecto hosteado (reservaste-stg, a diferencia de Docker
  // local que no tenia este limite), GoTrue rate-limitea signInWithPassword
  // por IP -- la suite entera corre desde la misma IP y crea cientos de
  // sesiones, asi que lo pisa seguido incluso con el limite del dashboard
  // subido. Reintento con backoff exponencial en vez de fallar duro: es un
  // 429 transitorio, no un error de logica del test.
  let signInError: { message: string } | null = null;
  for (let attempt = 0; attempt < 6; attempt++) {
    const result = await client.auth.signInWithPassword({
      email,
      password: PASSWORD,
      // ADR-0043 (correccion post-review, punto 5): Turnstile esta
      // habilitado (supabase/config.toml, [auth.captcha]) con la clave de
      // prueba "always passes" que Cloudflare publica para automatizar
      // tests sin navegador -- acepta cualquier token no vacio. Sin esto,
      // GoTrue devuelve `captcha_failed` (confirmado en vivo) porque el
      // grant `password` tambien pasa por la verificacion de captcha, no
      // solo el signup.
      options: { captchaToken: "test-suite-turnstile-token" },
    });
    signInError = result.error;
    if (!signInError) {
      return { id: data.user.id, email, client };
    }
    if (!signInError.message.toLowerCase().includes("rate limit")) {
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** attempt));
  }
  throw new Error(`failed to sign in test user ${email}: ${signInError?.message}`);
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
 * Inserts a `slot_occurrence` directly (service-role client, bypassing the
 * generator entirely) at a deterministic instant guaranteed to be
 * (a) strictly in the future and (b) within the organization's LOCAL
 * "today" -- which, by definition, is always on/before the local end of
 * the CURRENT calendar month, on literally any day of the month, including
 * the last one.
 *
 * Replaces the earlier `nextWeekdayWithinCurrentMonth()` (removed
 * 2026-09-30), which tried to find a weekday offset (0-6 days from today)
 * whose auto-generated occurrence would land within the current month. That
 * approach has a real, unavoidable hole baked into the requirement itself:
 * near the end of the month, NO offset > 0 can land within the current
 * month (tomorrow is already next month), and if the rule's local start
 * time has already passed today, offset 0 doesn't work either -- there is
 * no future weekday occurrence left "within this month" on the actual last
 * day of the month past its last slot's hour. That is not a fixture bug,
 * it is a real temporal fact, and it broke CI for real, twice: once for
 * test/phase25.production-feedback.test.ts and
 * test/phase11.standing-reservations.test.ts on 2026-09-29, and again on
 * 2026-09-30 itself -- the actual last day of the month -- which is the
 * one day the "pick a weekday offset" strategy can never solve, no matter
 * how it computes the offset (confirmed live: mocking `Date` client-side
 * does nothing, since the relevant "today" is computed by Postgres, via
 * `generate_slot_occurrences_for_rule()`'s `current_date` and
 * `customer_billing_horizon()`'s `now() at time zone org.timezone`, neither
 * of which the test process's clock can reach).
 *
 * The fix is to stop deriving the occurrence's date from "today plus an
 * offset" at all for the one data point that specifically needs to land
 * within the current calendar month (`upcoming_unpaid`, as opposed to
 * `upcoming_beyond_period`) -- and instead insert that occurrence directly,
 * at "later today". Today is the ONLY day-of-month value for which "within
 * the current calendar month" is true unconditionally, on every possible
 * day of every possible month -- which is exactly why offsets > 0 can never
 * fully close this, and offset 0 always can.
 *
 * `slot_occurrences` has no INSERT policy for regular members (Fase 3) --
 * occurrences are meant to come only from the generator -- so this uses the
 * service-role `admin` client, same as other direct-fixture-setup helpers
 * in this file. Nothing reads the row's relationship to the rule's own
 * `weekday`/`local_start_time` (`admin_create_recurring_booking()`,
 * `admin_preview_recurring_booking()` and `generate_recurring_booking()`
 * all query `slot_occurrences` directly by `schedule_rule_id` and
 * `start_at`, never by re-deriving the weekday), so the inserted row does
 * not need to match the rule's own weekday to be picked up correctly.
 *
 * Irreducible residual: if "now" (org-local) is within `bufferMinutes` of
 * local midnight on the actual last day of the month, there is no future
 * instant left today that both (a) gives the rest of the test enough time
 * to run before asserting `start_at >= now()` server-side and (b) is still
 * this month -- a real temporal impossibility, not a fixture bug. This
 * shrinks the old failure window from "the entire last day of the month"
 * (~1-in-30) down to the last minute of that day (~1-in-43200), which is as
 * close to zero as a fixture can get without controlling the server clock.
 */
export async function insertOccurrenceLaterToday(
  rule: { id: string },
  ctx: { organizationId: string; serviceId: string; resourceId: string },
  opts: { capacity?: number; durationMinutes?: number; bufferMinutes?: number } = {},
): Promise<{ id: string; start_at: string }> {
  const capacity = opts.capacity ?? 5;
  const durationMinutes = opts.durationMinutes ?? 60;
  const bufferMinutes = opts.bufferMinutes ?? 30;

  const nowMs = Date.now();
  // The org's local "now" (fixed UTC-3, no DST -- see the constant above).
  const localNowMs = nowMs - FIXTURE_ORG_UTC_OFFSET_HOURS * 3_600_000;
  const localNow = new Date(localNowMs);
  const localMidnightTonightMs = Date.UTC(
    localNow.getUTCFullYear(),
    localNow.getUTCMonth(),
    localNow.getUTCDate() + 1,
  );

  // Stay at least a minute clear of local midnight -- crossing it would
  // silently move the occurrence into tomorrow's calendar date, defeating
  // the whole point. Still aim for `bufferMinutes` of runway so the rest of
  // the test (several more RPC round-trips) has room before the occurrence
  // needs to still read as "future" server-side.
  const latestSafeLocalMs = localMidnightTonightMs - 60_000;
  const desiredLocalMs = Math.max(
    localNowMs + 1_000,
    Math.min(localNowMs + bufferMinutes * 60_000, latestSafeLocalMs),
  );

  const startAtMs = desiredLocalMs + FIXTURE_ORG_UTC_OFFSET_HOURS * 3_600_000;
  const startAt = new Date(startAtMs);
  const endAt = new Date(startAtMs + durationMinutes * 60_000);

  const { data, error } = await admin
    .from("slot_occurrences")
    .insert({
      organization_id: ctx.organizationId,
      schedule_rule_id: rule.id,
      service_id: ctx.serviceId,
      resource_id: ctx.resourceId,
      start_at: startAt.toISOString(),
      end_at: endAt.toISOString(),
      generated_timezone: "America/Montevideo",
      capacity,
    })
    .select("id, start_at")
    .single();
  if (error || !data) throw new Error(`failed to insert occurrence: ${error?.message}`);
  return data as { id: string; start_at: string };
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
