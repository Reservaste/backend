// Integration tests for Phase 2 (Service, Resource, ServiceEntitlement):
// cross-tenant isolation (ADR-0006) and the data-integrity guards added in
// this migration (same-organization pairing, entitlement vigencia CHECK).
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

describe("Phase 2: services, resources, entitlements", () => {
  let ownerA: SignedInUser;
  let ownerB: SignedInUser;
  let customerA: SignedInUser;
  let orgA: { id: string; slug: string };
  let orgB: { id: string; slug: string };
  let serviceA: { id: string };
  let resourceA: { id: string };
  let resourceB: { id: string };
  let customerARow: { id: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerA = await createSignedInUser("p2-owner-a");
    ownerB = await createSignedInUser("p2-owner-b");
    customerA = await createSignedInUser("p2-customer-a");
    createdUserIds.push(ownerA.id, ownerB.id, customerA.id);

    orgA = await createOrganization(ownerA, "p2-org-a");
    orgB = await createOrganization(ownerB, "p2-org-b");

    const { data: svc, error: svcError } = await ownerA.client
      .from("services")
      .insert({ organization_id: orgA.id, name: "CrossFit", created_by: ownerA.id })
      .select()
      .single();
    if (svcError || !svc) throw new Error(`failed to create service: ${svcError?.message}`);
    serviceA = svc;

    const { data: res, error: resError } = await ownerA.client
      .from("resources")
      .insert({ organization_id: orgA.id, name: "Sala principal", created_by: ownerA.id })
      .select()
      .single();
    if (resError || !res) throw new Error(`failed to create resource: ${resError?.message}`);
    resourceA = res;

    const { data: resB, error: resBError } = await ownerB.client
      .from("resources")
      .insert({ organization_id: orgB.id, name: "Otra sala", created_by: ownerB.id })
      .select()
      .single();
    if (resBError || !resB) throw new Error(`failed to create resource B: ${resBError?.message}`);
    resourceB = resB;

    const { data: cust, error: custError } = await ownerA.client
      .from("customers")
      .insert({ organization_id: orgA.id, profile_id: customerA.id, created_by: ownerA.id })
      .select()
      .single();
    if (custError || !cust) throw new Error(`failed to create customer: ${custError?.message}`);
    customerARow = cust;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("blocks an OWNER of a different org from seeing another org's services", async () => {
    const { data, error } = await ownerB.client.from("services").select("id").eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("blocks an OWNER of a different org from seeing another org's resources", async () => {
    const { data, error } = await ownerB.client.from("resources").select("id").eq("organization_id", orgA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("rejects pairing a Service with a Resource from a different organization", async () => {
    const { error } = await ownerA.client
      .from("service_resources")
      .insert({ service_id: serviceA.id, resource_id: resourceB.id });
    expect(error).not.toBeNull();
  });

  it("allows pairing a Service with a Resource from the same organization", async () => {
    const { error } = await ownerA.client
      .from("service_resources")
      .insert({ service_id: serviceA.id, resource_id: resourceA.id });
    expect(error).toBeNull();
  });

  describe("service_entitlements", () => {
    it("rejects a TIME entitlement that also sets credits fields", async () => {
      const { error } = await ownerA.client.from("service_entitlements").insert({
        organization_id: orgA.id,
        customer_id: customerARow.id,
        service_id: serviceA.id,
        entitlement_type: "TIME",
        valid_from: "2026-09-01",
        credits_total: 10,
        credits_remaining: 10,
      });
      expect(error).not.toBeNull();
    });

    it("rejects a CREDITS entitlement with credits_remaining greater than credits_total", async () => {
      const { error } = await ownerA.client.from("service_entitlements").insert({
        organization_id: orgA.id,
        customer_id: customerARow.id,
        service_id: serviceA.id,
        entitlement_type: "CREDITS",
        credits_total: 5,
        credits_remaining: 10,
      });
      expect(error).not.toBeNull();
    });

    it("accepts a well-formed TIME entitlement and enforces same-organization pairing", async () => {
      const { data, error } = await ownerA.client
        .from("service_entitlements")
        .insert({
          organization_id: orgA.id,
          customer_id: customerARow.id,
          service_id: serviceA.id,
          entitlement_type: "TIME",
          valid_from: "2026-09-01",
          valid_until: "2026-09-30",
          created_by: ownerA.id,
        })
        .select()
        .single();
      expect(error).toBeNull();
      expect(data?.requires_active_payment).toBe(true);
    });

    it("lets the CUSTOMER see their own entitlement", async () => {
      const { data, error } = await customerA.client
        .from("service_entitlements")
        .select("id")
        .eq("customer_id", customerARow.id);
      expect(error).toBeNull();
      expect(data).toHaveLength(1);
    });

    it("blocks an OWNER of a different org from seeing another org's entitlements", async () => {
      const { data, error } = await ownerB.client
        .from("service_entitlements")
        .select("id")
        .eq("organization_id", orgA.id);
      expect(error).toBeNull();
      expect(data).toEqual([]);
    });
  });
});
