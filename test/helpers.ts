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
