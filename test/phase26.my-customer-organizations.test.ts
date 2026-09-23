// Integration tests for Phase 26: my_customer_organizations() -- the
// businesses where a profile is already an active Customer, even with no
// active service or booking to show yet. Requires a running local
// Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

describe("Phase 26: my_customer_organizations", () => {
  const createdUserIds: string[] = [];
  let owner: SignedInUser;
  let org: { id: string; slug: string; name?: string };
  let customer: SignedInUser;

  beforeAll(async () => {
    owner = await createSignedInUser("p26-owner");
    createdUserIds.push(owner.id);
    org = await createOrganization(owner, "p26-org");

    // No service, no resource, no schedule rule -- exactly the case
    // getMyServices()/my_services() can't cover: a Customer with nothing
    // bookable published yet.
    customer = await createSignedInUser("p26-customer");
    createdUserIds.push(customer.id);
    await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id });
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("returns the organization for an active customer with no services or bookings", async () => {
    const { data, error } = await customer.client.rpc("my_customer_organizations");
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data[0].organization_slug).toBe(org.slug);
  });

  it("a signed-in person who is nobody's customer gets an empty list, not an error", async () => {
    const stranger = await createSignedInUser("p26-stranger");
    createdUserIds.push(stranger.id);

    const { data, error } = await stranger.client.rpc("my_customer_organizations");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("stops listing the organization once the customer link is deactivated", async () => {
    await owner.client
      .from("customers")
      .update({ is_active: false, cancelled_at: new Date().toISOString(), cancellation_reason: "CUSTOMER_REQUEST" })
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id);

    const { data } = await customer.client.rpc("my_customer_organizations");
    expect(data).toEqual([]);

    // restore for isolation from any later test relying on this fixture
    await owner.client
      .from("customers")
      .update({ is_active: true, cancelled_at: null, cancellation_reason: null })
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id);
  });

  it("cannot be called anonymously", async () => {
    const { createClient } = await import("@supabase/supabase-js");
    const { SUPABASE_URL, ANON_KEY } = await import("./helpers");
    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { error } = await anon.rpc("my_customer_organizations");
    expect(error).not.toBeNull();
  });
});
