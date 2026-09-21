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
  client: SupabaseClient;
}

export async function createSignedInUser(emailPrefix: string): Promise<SignedInUser> {
  const email = `${emailPrefix}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;
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

  return { id: data.user.id, client };
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
 * Makes a service payment-gated (ADR-0022). Replaces what a
 * ServiceEntitlement with requires_active_payment used to express, except
 * it now belongs to the service rather than to each customer.
 */
export async function makeServicePaid(
  owner: SignedInUser,
  serviceId: string,
  cycle: "CALENDAR_MONTH" | "ROLLING_MONTH" = "CALENDAR_MONTH",
  price = 2000,
) {
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
}

/** Days from today as an ISO date, for readable payment periods in tests. */
export function isoDate(offsetDays: number): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

/** Registers a payment covering [from, to] for a customer on a service. */
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
  },
) {
  const { data, error } = await owner.client
    .from("payments")
    .insert({
      organization_id: args.organizationId,
      customer_id: args.customerId,
      service_id: args.serviceId,
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
