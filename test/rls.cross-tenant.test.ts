// Integration test for ADR-0006 (RLS, two layers: tenant + row ownership).
// Requires a running local Supabase (`npx supabase start` in this repo).
//
// This is the test the Phase 0 closing summary flagged as a real risk:
// "RLS de dos capas... necesita tests de cross-tenant explícitos antes de
// cerrar Phase 1, no solo revisión de código."

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

describe("ADR-0006: RLS two-layer cross-tenant isolation", () => {
  let ownerA: SignedInUser;
  let ownerB: SignedInUser;
  let customerA: SignedInUser;
  let orgA: { id: string; slug: string };
  let orgB: { id: string; slug: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerA = await createSignedInUser("owner-a");
    ownerB = await createSignedInUser("owner-b");
    customerA = await createSignedInUser("customer-a");
    createdUserIds.push(ownerA.id, ownerB.id, customerA.id);

    orgA = await createOrganization(ownerA, "org-a");
    orgB = await createOrganization(ownerB, "org-b");

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

  it("blocks creating an Organization via a raw insert, bypassing the atomic owner RPC", async () => {
    // Only create_organization_with_owner() may create an Organization --
    // a raw insert would produce one with no OWNER membership row, which
    // is a broken state. There is intentionally no INSERT policy for this.
    const { error } = await ownerA.client.from("organizations").insert({
      slug: `orphan-org-${Date.now()}`,
      name: "Orphan Org",
    });
    expect(error).not.toBeNull();
  });
});
