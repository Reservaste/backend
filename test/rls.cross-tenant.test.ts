// Integration test for ADR-0006 (RLS, two layers: tenant + row ownership).
// Requires a running local Supabase (`npx supabase start` in this repo).
// The defaults below are the fixed demo credentials `supabase start` prints
// for a local project -- never valid against a real Supabase project, so
// hardcoding them here as a local-dev fallback is safe. Override via env
// vars to point at a different local stack.
//
// This is the test the Phase 0 closing summary flagged as a real risk:
// "RLS de dos capas... necesita tests de cross-tenant explícitos antes de
// cerrar Phase 1, no solo revisión de código."

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const SUPABASE_URL = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";
const SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
const PASSWORD = "cross-tenant-test-password-123";

async function createSignedInUser(emailPrefix: string) {
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

describe("ADR-0006: RLS two-layer cross-tenant isolation", () => {
  let ownerA: { id: string; client: SupabaseClient };
  let ownerB: { id: string; client: SupabaseClient };
  let customerA: { id: string; client: SupabaseClient };
  let orgA: { id: string; slug: string };
  let orgB: { id: string; slug: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerA = await createSignedInUser("owner-a");
    ownerB = await createSignedInUser("owner-b");
    customerA = await createSignedInUser("customer-a");
    createdUserIds.push(ownerA.id, ownerB.id, customerA.id);

    const slugSuffix = Date.now();

    const { data: orgAData, error: orgAError } = await ownerA.client.rpc("create_organization_with_owner", {
      p_slug: `org-a-${slugSuffix}`,
      p_name: "Organization A",
      p_timezone: "America/Montevideo",
    });
    if (orgAError || !orgAData) throw new Error(`failed to create Org A: ${orgAError?.message}`);
    orgA = { id: orgAData.id, slug: orgAData.slug };

    const { data: orgBData, error: orgBError } = await ownerB.client.rpc("create_organization_with_owner", {
      p_slug: `org-b-${slugSuffix}`,
      p_name: "Organization B",
      p_timezone: "America/Montevideo",
    });
    if (orgBError || !orgBData) throw new Error(`failed to create Org B: ${orgBError?.message}`);
    orgB = { id: orgBData.id, slug: orgBData.slug };

    // Owner A enrolls customerA as a Customer of Org A.
    const { error: customerInsertError } = await ownerA.client.from("customers").insert({
      organization_id: orgA.id,
      profile_id: customerA.id,
      created_by: ownerA.id,
    });
    if (customerInsertError) {
      throw new Error(`failed to create customer row: ${customerInsertError.message}`);
    }
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("lets an OWNER see their own organization", async () => {
    const { data, error } = await ownerA.client.from("organizations").select("id").eq("id", orgA.id);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
  });

  it("blocks an OWNER from seeing a different tenant's organization row", async () => {
    const { data, error } = await ownerB.client.from("organizations").select("id").eq("id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("blocks an OWNER from seeing a different tenant's membership roster", async () => {
    const { data, error } = await ownerB.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("lets STAFF/OWNER see every customer row of their own organization", async () => {
    const { data, error } = await ownerA.client
      .from("customers")
      .select("id, profile_id")
      .eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data?.[0]?.profile_id).toBe(customerA.id);
  });

  it("blocks an OWNER of a different org from seeing another org's customer rows -- the exact bug ADR-0006 fixes", async () => {
    // Filtering by organization_id alone (single-layer RLS) would have let
    // Owner B read Org A's customers if the policy only checked tenant.
    const { data, error } = await ownerB.client
      .from("customers")
      .select("id")
      .eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("lets a CUSTOMER see their own customer row", async () => {
    const { data, error } = await customerA.client
      .from("customers")
      .select("id, organization_id")
      .eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
  });

  it("blocks a CUSTOMER from seeing the organization_members roster (not staff)", async () => {
    const { data, error } = await customerA.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("blocks a non-OWNER from writing to organization_members", async () => {
    const { error } = await customerA.client.from("organization_members").insert({
      organization_id: orgA.id,
      profile_id: customerA.id,
      role: "STAFF",
    });
    expect(error).not.toBeNull();
  });
});
