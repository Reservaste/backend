// Integration tests for Phase 4 (public calendar). The central question:
// can a genuinely anonymous client (no session at all, not even a signed-in
// test user) see what the public calendar needs, and nothing else?
// Requires a running local Supabase (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, ANON_KEY, createOrganization, createSignedInUser, SUPABASE_URL, type SignedInUser } from "./helpers";

describe("Phase 4: public calendar", () => {
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceExact: { id: string };
  let serviceBoolean: { id: string };
  let serviceLowCapacity: { id: string };
  const anon = createClient(SUPABASE_URL, ANON_KEY);
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    owner = await createSignedInUser("p4-owner");
    createdUserIds.push(owner.id);

    org = await createOrganization(owner, "p4-org");
    // Organization default is EXACT (schema default) -- confirmed by the
    // serviceExact test below, which relies on that default rather than
    // setting it explicitly.

    const { data: svcExact } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "CrossFit", created_by: owner.id })
      .select()
      .single();
    serviceExact = svcExact!;

    const { data: svcBoolean } = await owner.client
      .from("services")
      .insert({
        organization_id: org.id,
        name: "Terapia individual",
        public_availability_display_override: "BOOLEAN",
        created_by: owner.id,
      })
      .select()
      .single();
    serviceBoolean = svcBoolean!;

    const { data: svcLow } = await owner.client
      .from("services")
      .insert({
        organization_id: org.id,
        name: "Yoga chico",
        public_availability_display_override: "LIMITED",
        created_by: owner.id,
      })
      .select()
      .single();
    serviceLowCapacity = svcLow!;

    const { data: resource } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
      .select()
      .single();

    const weekday = (new Date().getUTCDay() + 2) % 7;

    for (const [serviceId, capacity] of [
      [serviceExact.id, 12],
      [serviceBoolean.id, 1],
      // threshold = min(fixedCap=3, ceil(capacity * 20% / 100)) -- at
      // capacity 1 that's min(3, ceil(0.2))=min(3,1)=1, and
      // remaining(1) <= threshold(1) => LOW. The fixed cap alone isn't
      // the threshold; it's whichever of the two caps is smaller.
      [serviceLowCapacity.id, 1],
    ] as const) {
      await owner.client.from("schedule_rules").insert({
        organization_id: org.id,
        service_id: serviceId,
        resource_id: resource!.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity,
        created_by: owner.id,
      });
    }
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("lets an anonymous client read the organization's public shape", async () => {
    const { data, error } = await anon.from("organizations_public").select("*").eq("slug", org.slug).single();
    expect(error).toBeNull();
    expect(data?.name).toBeTruthy();
    // Only the safe columns exist on this view at all -- not a filtering
    // question, there is no billing/internal-config column to leak. Any
    // addition here has to be a deliberate edit to this list: brand_color
    // and logo_path were added in Phase 13 because branding renders for
    // visitors with no session (ADR-0020).
    expect(Object.keys(data ?? {}).sort()).toEqual(
      ["brand_color", "id", "logo_path", "name", "slug", "timezone"].sort(),
    );
  });

  it("lets an anonymous client list the organization's public services", async () => {
    const { data, error } = await anon.from("services_public").select("*").eq("organization_id", org.id);
    expect(error).toBeNull();
    expect(data?.length).toBe(3);
  });

  it("blocks an anonymous client from the base organizations/services/slot_occurrences tables", async () => {
    const orgs = await anon.from("organizations").select("id").eq("id", org.id);
    expect(orgs.data).toEqual([]);

    const services = await anon.from("services").select("id").eq("organization_id", org.id);
    expect(services.data).toEqual([]);

    const occurrences = await anon.from("slot_occurrences").select("id").eq("organization_id", org.id);
    expect(occurrences.data).toEqual([]);
  });

  it("blocks an anonymous client from customers/organization_members entirely", async () => {
    const customers = await anon.from("customers").select("id");
    expect(customers.data).toEqual([]);

    const members = await anon.from("organization_members").select("id");
    expect(members.data).toEqual([]);
  });

  it("EXACT mode: get_public_availability exposes the real remaining/capacity", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceExact.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    const slot = data[0];
    expect(slot.mode).toBe("EXACT");
    expect(slot.capacity).toBe(12);
    expect(slot.remaining).toBe(12);
    expect(slot.status).toBeNull();
  });

  it("BOOLEAN mode: never exposes remaining/capacity, only AVAILABLE/FULL", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceBoolean.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    const slot = data[0];
    expect(slot.mode).toBe("BOOLEAN");
    expect(slot.remaining).toBeNull();
    expect(slot.capacity).toBeNull();
    expect(slot.status).toBe("AVAILABLE");
  });

  it("LIMITED mode: a low-capacity slot reports LOW, not the number", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceLowCapacity.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    const slot = data[0];
    expect(slot.mode).toBe("LIMITED");
    expect(slot.remaining).toBeNull();
    expect(slot.capacity).toBeNull();
    expect(slot.status).toBe("LOW");
  });

  it("returns nothing for an organization slug that does not exist, instead of erroring", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: "this-org-does-not-exist",
    });
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });
});
