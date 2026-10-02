// Integration tests for Phase 53 (ADR-0052): organization_id is immutable
// on resources/services (two BEFORE UPDATE triggers), plus the related
// check_schedule_rule_conflicts() RESOURCE_NOT_FOUND/NOT_AUTHORIZED
// unification bundled in the same migration. Requires a running Supabase
// instance (see test/helpers.ts) with this phase's migration already
// applied.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

function weekdayInTwoDays(): number {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 2);
  return d.getUTCDay();
}

describe("Phase 53: organization_id immutable on resources/services (ADR-0052)", () => {
  let ownerA: SignedInUser;
  let ownerB: SignedInUser;
  let orgA: { id: string; slug: string };
  let orgB: { id: string; slug: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerA = await createSignedInUser("p53-owner-a");
    createdUserIds.push(ownerA.id);
    orgA = await createOrganization(ownerA, "p53-org-a");

    ownerB = await createSignedInUser("p53-owner-b");
    createdUserIds.push(ownerB.id);
    orgB = await createOrganization(ownerB, "p53-org-b");

    // ownerA becomes a member of orgB too (STAFF is enough -- the update
    // policies on resources/services only check is_organization_member,
    // not role), so ownerA's session legitimately passes RLS's
    // is_organization_member() for BOTH organizations. This isolates the
    // trigger as the only thing standing between "member of both orgs"
    // and actually moving a row from one to the other.
    const { error: memberError } = await ownerB.client
      .from("organization_members")
      .insert({
        organization_id: orgB.id,
        profile_id: ownerA.id,
        role: "STAFF",
        created_by: ownerB.id,
      });
    expect(memberError).toBeNull();
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("(a) rejects moving a Resource from orgA to orgB, even for a member of both", async () => {
    const { data: resource, error: insertError } = await ownerA.client
      .from("resources")
      .insert({ organization_id: orgA.id, name: "Sala A", created_by: ownerA.id })
      .select()
      .single();
    expect(insertError).toBeNull();

    const { error: updateError } = await ownerA.client
      .from("resources")
      .update({ organization_id: orgB.id })
      .eq("id", resource!.id);
    expect(updateError).not.toBeNull();
    expect(updateError!.message).toContain("ORGANIZATION_ID_IS_IMMUTABLE");

    const { data: reread } = await admin
      .from("resources")
      .select("organization_id")
      .eq("id", resource!.id)
      .single();
    expect(reread!.organization_id).toBe(orgA.id);
  });

  it("(b) rejects moving a Service from orgA to orgB, even for a member of both", async () => {
    const { data: service, error: insertError } = await ownerA.client
      .from("services")
      .insert({ organization_id: orgA.id, name: "Corte", created_by: ownerA.id })
      .select()
      .single();
    expect(insertError).toBeNull();

    const { error: updateError } = await ownerA.client
      .from("services")
      .update({ organization_id: orgB.id })
      .eq("id", service!.id);
    expect(updateError).not.toBeNull();
    expect(updateError!.message).toContain("ORGANIZATION_ID_IS_IMMUTABLE");

    const { data: reread } = await admin
      .from("services")
      .select("organization_id")
      .eq("id", service!.id)
      .single();
    expect(reread!.organization_id).toBe(orgA.id);
  });

  it("(c) a normal update that does not touch organization_id still works", async () => {
    const { data: resource, error: insertError } = await ownerA.client
      .from("resources")
      .insert({ organization_id: orgA.id, name: "Sala vieja", created_by: ownerA.id })
      .select()
      .single();
    expect(insertError).toBeNull();

    const { data: updated, error: updateError } = await ownerA.client
      .from("resources")
      .update({ name: "Sala nueva" })
      .eq("id", resource!.id)
      .select()
      .single();
    expect(updateError).toBeNull();
    expect(updated!.name).toBe("Sala nueva");
    expect(updated!.organization_id).toBe(orgA.id);

    const { data: service, error: svcInsertError } = await ownerA.client
      .from("services")
      .insert({ organization_id: orgA.id, name: "Afeitado viejo", created_by: ownerA.id })
      .select()
      .single();
    expect(svcInsertError).toBeNull();

    const { data: updatedService, error: svcUpdateError } = await ownerA.client
      .from("services")
      .update({ name: "Afeitado nuevo" })
      .eq("id", service!.id)
      .select()
      .single();
    expect(svcUpdateError).toBeNull();
    expect(updatedService!.name).toBe("Afeitado nuevo");
    expect(updatedService!.organization_id).toBe(orgA.id);
  });

  // ADR-0052's bundled fix: check_schedule_rule_conflicts() used to
  // distinguish RESOURCE_NOT_FOUND (does not exist) from NOT_AUTHORIZED
  // (exists, but the caller is not a member of its organization) -- a minor
  // existence oracle across tenants. A caller who is a member of orgA only,
  // passing a real Resource id that belongs to orgB, must now see the same
  // RESOURCE_NOT_FOUND it would see for a resource that does not exist at
  // all, same non-oracle criterion create_schedule_rules_batch() already
  // applies (Phase 48).
  it("(d) check_schedule_rule_conflicts returns RESOURCE_NOT_FOUND (not NOT_AUTHORIZED) for a Resource in another org", async () => {
    const { data: resourceB, error: resourceBError } = await ownerB.client
      .from("resources")
      .insert({ organization_id: orgB.id, name: "Recurso de B", created_by: ownerB.id })
      .select()
      .single();
    expect(resourceBError).toBeNull();

    const staffOnlyA = await createSignedInUser("p53-staff-only-a");
    createdUserIds.push(staffOnlyA.id);
    const { error: memberError } = await ownerA.client
      .from("organization_members")
      .insert({
        organization_id: orgA.id,
        profile_id: staffOnlyA.id,
        role: "STAFF",
        created_by: ownerA.id,
      });
    expect(memberError).toBeNull();

    const { data, error } = await staffOnlyA.client.rpc("check_schedule_rule_conflicts", {
      p_resource_id: (resourceB as { id: string }).id,
      p_weekday: [weekdayInTwoDays()],
      p_local_start_time: ["09:00"],
      p_duration_minutes: 30,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toContain("RESOURCE_NOT_FOUND");
    expect(error!.message).not.toContain("NOT_AUTHORIZED");
  });
});
