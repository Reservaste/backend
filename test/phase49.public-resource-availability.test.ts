// Integration tests for Phase 49 (ADR-0048): get_public_availability()
// exposing resource_id/resource_name, opt-in per organization via
// organizations.public_resource_names. Requires a running local Supabase
// (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, ANON_KEY, createOrganization, createSignedInUser, SUPABASE_URL, type SignedInUser } from "./helpers";

describe("Phase 49: public resource availability (ADR-0048)", () => {
  let ownerOff: SignedInUser;
  let ownerOn: SignedInUser;
  let orgOff: { id: string; slug: string };
  let orgOn: { id: string; slug: string };
  let serviceOff: { id: string };
  let serviceOn: { id: string };
  let resourceOff: { id: string; name: string };
  let resourceOn: { id: string; name: string };
  const anon = createClient(SUPABASE_URL, ANON_KEY);
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerOff = await createSignedInUser("p49-owner-off");
    ownerOn = await createSignedInUser("p49-owner-on");
    createdUserIds.push(ownerOff.id, ownerOn.id);

    // Organization with the flag at its default (false) -- confirms the
    // opt-in truly starts off without any explicit update.
    orgOff = await createOrganization(ownerOff, "p49-org-off");

    // Organization with the flag explicitly turned on -- confirms
    // per-organization disclosure, not a global toggle.
    orgOn = await createOrganization(ownerOn, "p49-org-on");
    const { error: flagError } = await admin
      .from("organizations")
      .update({ public_resource_names: true })
      .eq("id", orgOn.id);
    if (flagError) throw new Error(`failed to set public_resource_names: ${flagError.message}`);

    const { data: svcOff } = await ownerOff.client
      .from("services")
      .insert({ organization_id: orgOff.id, name: "Corte", created_by: ownerOff.id })
      .select()
      .single();
    serviceOff = svcOff!;

    const { data: svcOn } = await ownerOn.client
      .from("services")
      .insert({ organization_id: orgOn.id, name: "Corte", created_by: ownerOn.id })
      .select()
      .single();
    serviceOn = svcOn!;

    const { data: resOff } = await ownerOff.client
      .from("resources")
      .insert({ organization_id: orgOff.id, name: "Juan", created_by: ownerOff.id })
      .select()
      .single();
    resourceOff = resOff!;

    const { data: resOn } = await ownerOn.client
      .from("resources")
      .insert({ organization_id: orgOn.id, name: "Pedro", created_by: ownerOn.id })
      .select()
      .single();
    resourceOn = resOn!;

    const weekday = (new Date().getUTCDay() + 2) % 7;

    await ownerOff.client.from("schedule_rules").insert({
      organization_id: orgOff.id,
      service_id: serviceOff.id,
      resource_id: resourceOff.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 5,
      created_by: ownerOff.id,
    });

    await ownerOn.client.from("schedule_rules").insert({
      organization_id: orgOn.id,
      service_id: serviceOn.id,
      resource_id: resourceOn.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 5,
      created_by: ownerOn.id,
    });
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("flag off (default): resource_id is always present, resource_name is always null, for an anonymous caller", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: orgOff.slug,
      p_service_id: serviceOff.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    for (const slot of data) {
      expect(slot.resource_id).toBe(resourceOff.id);
      expect(slot.resource_name).toBeNull();
    }
  });

  it("flag on: resource_name carries the real resource name, for an anonymous caller", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: orgOn.slug,
      p_service_id: serviceOn.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    for (const slot of data) {
      expect(slot.resource_id).toBe(resourceOn.id);
      expect(slot.resource_name).toBe("Pedro");
    }
  });

  it("cross-tenant: one organization's flag=true never leaks another organization's resource name (own v_org per row, not a shared value)", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: orgOff.slug,
      p_service_id: serviceOff.id,
    });
    expect(error).toBeNull();
    expect(data.length).toBeGreaterThan(0);
    for (const slot of data) {
      expect(slot.resource_name).toBeNull();
      expect(slot.resource_name).not.toBe(resourceOn.name);
    }
  });
});
