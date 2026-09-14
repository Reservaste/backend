// Integration tests for Phase 8 (admin operations): the capacity guard
// domain.md always specified, enrolling customers/staff by email, the
// last-owner protection, and staff booking on a customer's behalf.
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

async function setupOrg(prefix: string, capacity = 10) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "CrossFit", created_by: owner.id })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  const weekday = (new Date().getUTCDay() + 2) % 7;
  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service!.id,
      resource_id: resource!.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity,
      created_by: owner.id,
    })
    .select()
    .single();

  const { data: occurrences } = await owner.client
    .from("slot_occurrences")
    .select("id, start_at")
    .eq("schedule_rule_id", rule!.id)
    .order("start_at", { ascending: true })
    .limit(1);

  return { owner, org, service: service!, rule: rule!, occurrence: occurrences![0]! };
}

async function enrollWithEntitlement(owner: SignedInUser, org: { id: string }, serviceId: string, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();

  await owner.client.from("service_entitlements").insert({
    organization_id: org.id,
    customer_id: customerRow!.id,
    service_id: serviceId,
    entitlement_type: "TIME",
    valid_from: "2020-01-01",
    requires_active_payment: false,
    created_by: owner.id,
  });

  return { customer, customerRow: customerRow! };
}

describe("Phase 8: admin operations", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("domain.md invariant: capacity cannot be lowered below the confirmed bookings already taken", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p8-capacity", 10);
    createdUserIds.push(owner.id);

    const a = await enrollWithEntitlement(owner, org, service.id, "p8-capacity-a");
    const b = await enrollWithEntitlement(owner, org, service.id, "p8-capacity-b");
    createdUserIds.push(a.customer.id, b.customer.id);

    await a.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    await b.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });

    // Down to 5 is fine (2 booked), down to 1 is not.
    const ok = await owner.client.from("slot_occurrences").update({ capacity: 5 }).eq("id", occurrence.id);
    expect(ok.error).toBeNull();

    const tooLow = await owner.client.from("slot_occurrences").update({ capacity: 1 }).eq("id", occurrence.id);
    expect(tooLow.error).not.toBeNull();
    expect(tooLow.error?.message).toContain("CAPACITY_BELOW_ACTIVE_BOOKINGS");

    // Raising it is always allowed.
    const raised = await owner.client.from("slot_occurrences").update({ capacity: 20 }).eq("id", occurrence.id);
    expect(raised.error).toBeNull();
  });

  it("enrolls a customer by email, and re-enrolling a removed one reactivates instead of duplicating", async () => {
    const { owner, org } = await setupOrg("p8-enroll");
    createdUserIds.push(owner.id);

    const person = await createSignedInUser("p8-enroll-person");
    createdUserIds.push(person.id);
    const { data: personProfile } = await admin.auth.admin.getUserById(person.id);
    const email = personProfile.user!.email!;

    const first = await owner.client.rpc("enroll_customer_by_email", {
      p_organization_id: org.id,
      p_email: email,
    });
    expect(first.error).toBeNull();
    expect(first.data.is_active).toBe(true);

    await owner.client.from("customers").update({ is_active: false }).eq("id", first.data.id);

    const second = await owner.client.rpc("enroll_customer_by_email", {
      p_organization_id: org.id,
      p_email: email.toUpperCase(), // case-insensitive lookup
    });
    expect(second.error).toBeNull();
    expect(second.data.id).toBe(first.data.id);
    expect(second.data.is_active).toBe(true);
  });

  it("refuses to enroll an email with no account, and refuses a non-member caller", async () => {
    const { owner, org } = await setupOrg("p8-enroll-guard");
    createdUserIds.push(owner.id);

    const missing = await owner.client.rpc("enroll_customer_by_email", {
      p_organization_id: org.id,
      p_email: "nobody-with-this-address@example.com",
    });
    expect(missing.error?.message).toContain("PROFILE_NOT_FOUND");

    const outsider = await createSignedInUser("p8-enroll-outsider");
    createdUserIds.push(outsider.id);
    const { data: outsiderUser } = await admin.auth.admin.getUserById(outsider.id);

    const unauthorized = await outsider.client.rpc("enroll_customer_by_email", {
      p_organization_id: org.id,
      p_email: outsiderUser.user!.email!,
    });
    expect(unauthorized.error?.message).toContain("NOT_AUTHORIZED");
  });

  it("invites staff (OWNER only) and refuses to revoke the last OWNER", async () => {
    const { owner, org } = await setupOrg("p8-team");
    createdUserIds.push(owner.id);

    const staffPerson = await createSignedInUser("p8-team-staff");
    createdUserIds.push(staffPerson.id);
    const { data: staffUser } = await admin.auth.admin.getUserById(staffPerson.id);

    const invited = await owner.client.rpc("invite_member_by_email", {
      p_organization_id: org.id,
      p_email: staffUser.user!.email!,
      p_role: "STAFF",
    });
    expect(invited.error).toBeNull();
    expect(invited.data.role).toBe("STAFF");

    // STAFF cannot invite others -- that's OWNER-only.
    const outsider = await createSignedInUser("p8-team-outsider");
    createdUserIds.push(outsider.id);
    const { data: outsiderUser } = await admin.auth.admin.getUserById(outsider.id);

    const staffTryingToInvite = await staffPerson.client.rpc("invite_member_by_email", {
      p_organization_id: org.id,
      p_email: outsiderUser.user!.email!,
      p_role: "STAFF",
    });
    expect(staffTryingToInvite.error?.message).toContain("NOT_AUTHORIZED");

    // Revoking the STAFF member is fine.
    const revokedStaff = await owner.client.rpc("revoke_member", { p_member_id: invited.data.id });
    expect(revokedStaff.error).toBeNull();
    expect(revokedStaff.data.is_active).toBe(false);

    // Revoking the only OWNER would leave the org unadministrable.
    const { data: team } = await owner.client.rpc("organization_team", { p_organization_id: org.id });
    const ownerRow = team.find((m: { role: string }) => m.role === "OWNER");
    const lastOwner = await owner.client.rpc("revoke_member", { p_member_id: ownerRow.member_id });
    expect(lastOwner.error?.message).toContain("LAST_OWNER");
  });

  it("staff books a customer into a slot, with the same entitlement rules as self-service", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p8-adminbook");
    createdUserIds.push(owner.id);

    // No entitlement yet -- staff sees the same reason a customer would.
    const bare = await createSignedInUser("p8-adminbook-bare");
    createdUserIds.push(bare.id);
    const { data: bareCustomer } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: bare.id, created_by: owner.id })
      .select()
      .single();

    const refused = await owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence.id,
      p_customer_id: bareCustomer!.id,
    });
    expect(refused.data.status).toBe("NO_ENTITLEMENT");

    const { customer, customerRow } = await enrollWithEntitlement(owner, org, service.id, "p8-adminbook-ok");
    createdUserIds.push(customer.id);

    const booked = await owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence.id,
      p_customer_id: customerRow.id,
    });
    expect(booked.data.status).toBe("OK");
    expect(booked.data.booking.customer_id).toBe(customerRow.id);

    // Booking the same customer twice is still rejected.
    const again = await owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence.id,
      p_customer_id: customerRow.id,
    });
    expect(again.data.status).toBe("ALREADY_BOOKED");
  });

  it("agenda_occurrences and occurrence_bookings are membership-gated and return occupancy", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p8-agenda");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollWithEntitlement(owner, org, service.id, "p8-agenda-customer");
    createdUserIds.push(customer.id);

    await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });

    const from = new Date(Date.now() - 86_400_000).toISOString();
    const to = new Date(Date.now() + 30 * 86_400_000).toISOString();

    const agenda = await owner.client.rpc("agenda_occurrences", {
      p_organization_id: org.id,
      p_from: from,
      p_to: to,
    });
    expect(agenda.error).toBeNull();
    const row = agenda.data.find((o: { id: string }) => o.id === occurrence.id);
    expect(row.service_name).toBe("CrossFit");
    expect(row.resource_name).toBe("Sala");
    expect(row.confirmed_count).toBe(1);

    const attendees = await owner.client.rpc("occurrence_bookings", { p_slot_occurrence_id: occurrence.id });
    expect(attendees.data).toHaveLength(1);
    expect(attendees.data[0].customer_id).toBe(customerRow.id);

    // An outsider gets nothing from either, despite them being SECURITY
    // DEFINER functions -- the membership check is inside the query.
    const outsider = await createSignedInUser("p8-agenda-outsider");
    createdUserIds.push(outsider.id);

    const outsiderAgenda = await outsider.client.rpc("agenda_occurrences", {
      p_organization_id: org.id,
      p_from: from,
      p_to: to,
    });
    expect(outsiderAgenda.data).toEqual([]);

    const outsiderAttendees = await outsider.client.rpc("occurrence_bookings", {
      p_slot_occurrence_id: occurrence.id,
    });
    expect(outsiderAttendees.data).toEqual([]);
  });
});
