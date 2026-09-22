// Emergency verification for ADR-0026 (Phase 21), written by the
// Orchestrator because the implementing agent had no shell access and
// left these as manual steps in the migration. Covers exactly the three
// non-negotiable checks: Hallazgo A for real (profile_id genuinely NULL),
// Hallazgo E (staff cannot hijack profile_id by direct PATCH), and the
// claim flow end-to-end including double-redeem.

import { describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser } from "./helpers";

describe("Phase 21 -- managed customers (ADR-0026), emergency verification", () => {
  it("Hallazgo A: a stranger from another organization cannot cancel a managed customer's booking", async () => {
    const ownerA = await createSignedInUser("owner-a-managed");
    const orgA = await createOrganization(ownerA, "org-a-managed");
    const ownerB = await createSignedInUser("owner-b-stranger");
    await createOrganization(ownerB, "org-b-stranger");

    const { data: customerRow0, error: createErr } = await ownerA.client.rpc("create_managed_customer", {
      p_organization_id: orgA.id,
      p_display_name: "Cliente Gestionado",
      p_phone: null,
    });
    expect(createErr).toBeNull();
    const customerId = customerRow0?.id;
    expect(customerId).toBeTruthy();

    const { data: customerRow } = await admin
      .from("customers")
      .select("profile_id")
      .eq("id", customerId)
      .single();
    expect(customerRow?.profile_id).toBeNull();

    // Give the org a free service + rule + occurrence so we can book without
    // payment machinery, then book the managed customer into it as staff.
    const { data: resource } = await ownerA.client
      .from("resources")
      .insert({ organization_id: orgA.id, name: "Sala" })
      .select()
      .single();
    const { data: service } = await ownerA.client
      .from("services")
      .insert({ organization_id: orgA.id, name: "Libre", payment_required: false })
      .select()
      .single();
    const { data: rule } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: service!.id,
        resource_id: resource!.id,
        weekday: new Date().getDay(),
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 3,
        valid_from: new Date().toISOString().slice(0, 10),
      })
      .select()
      .single();
    expect(rule).toBeTruthy();

    const { data: occurrence } = await admin
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule!.id)
      .gte("start_at", new Date().toISOString())
      .order("start_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    expect(occurrence).toBeTruthy();

    const { data: bookingResult, error: bookErr } = await ownerA.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence!.id,
      p_customer_id: customerId,
    });
    expect(bookErr).toBeNull();
    // Compound verdict shape from ADR-0025 (status, booking, makeup_credit_id).
    expect((bookingResult as { status?: string })?.status).toBe("OK");
    const bookingId = (bookingResult as { booking?: { id?: string } })?.booking?.id;
    expect(bookingId).toBeTruthy();

    // The attack: ownerB is a member of a different organization entirely,
    // not this customer's org, and this customer has no profile_id at all.
    // Migration 19's fix must still hold: elsif <member of THIS org> --
    // ownerB matches neither branch and must fall to the else raise.
    const { error: attackErr } = await ownerB.client.rpc("cancel_booking", {
      p_booking_id: bookingId,
    });
    expect(attackErr).not.toBeNull();
    expect(attackErr!.message).toMatch(/NOT_AUTHORIZED/);

    const { data: bookingAfter } = await admin
      .from("bookings")
      .select("status")
      .eq("id", bookingId)
      .single();
    expect(bookingAfter?.status).toBe("CONFIRMED");
  });

  it("Hallazgo E: staff cannot hijack profile_id of a managed customer via direct PATCH", async () => {
    const owner = await createSignedInUser("owner-hallazgo-e");
    const org = await createOrganization(owner, "org-hallazgo-e");
    const attacker = await createSignedInUser("staff-attacker");

    // Make the attacker a STAFF member of the same org -- customers_write_staff
    // authorizes by organization_id alone, which is exactly hallazgo E.
    const { data: attackerCustomerCheck } = await admin
      .from("organization_members")
      .insert({ organization_id: org.id, profile_id: attacker.id, role: "STAFF" })
      .select()
      .single();
    expect(attackerCustomerCheck).toBeTruthy();

    const { data: customerRow1 } = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Otro Gestionado",
      p_phone: null,
    });
    const customerId = customerRow1?.id;
    expect(customerId).toBeTruthy();

    // Direct PATCH via PostgREST semantics (the anon/authenticated client
    // going straight at the table, bypassing every RPC), same as the
    // migration's own manual-verification comment describes.
    const { error: patchErr } = await attacker.client
      .from("customers")
      .update({ profile_id: attacker.id })
      .eq("id", customerId);

    expect(patchErr).not.toBeNull();
    expect(patchErr!.message).toMatch(/PROFILE_LINK_NOT_ALLOWED/);

    const { data: after } = await admin.from("customers").select("profile_id").eq("id", customerId).single();
    expect(after?.profile_id).toBeNull();
  });

  it("claim flow end-to-end: activation binds profile_id once, a second claim is rejected", async () => {
    const owner = await createSignedInUser("owner-claim-flow");
    const org = await createOrganization(owner, "org-claim-flow");
    const claimant = await createSignedInUser("claimant-real");
    const secondClaimant = await createSignedInUser("claimant-second");

    const { data: customerRow2 } = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Para Activar",
      p_phone: "+59899000000",
    });
    const customerId = customerRow2?.id;
    expect(customerId).toBeTruthy();

    // `returns table (...)` comes back through PostgREST as an array of rows.
    const { data: issued, error: issueErr } = await owner.client.rpc("issue_customer_activation", {
      p_customer_id: customerId,
    });
    expect(issueErr).toBeNull();
    const issuedRow = Array.isArray(issued) ? issued[0] : issued;
    const plainToken = issuedRow?.token;
    expect(plainToken).toBeTruthy();

    const { error: claimErr } = await claimant.client.rpc("claim_customer_activation", {
      p_token: plainToken,
    });
    expect(claimErr).toBeNull();

    const { data: linked } = await admin.from("customers").select("profile_id, claimed_at").eq("id", customerId).single();
    expect(linked?.profile_id).toBe(claimant.id);
    expect(linked?.claimed_at).toBeTruthy();

    const { error: secondClaimErr } = await secondClaimant.client.rpc("claim_customer_activation", {
      p_token: plainToken,
    });
    expect(secondClaimErr).not.toBeNull();
    expect(secondClaimErr!.message).toMatch(/ALREADY_REDEEMED|NOT_FOUND|EXPIRED/);

    // Second claim must never have moved the link away from the real claimant.
    const { data: stillLinked } = await admin.from("customers").select("profile_id").eq("id", customerId).single();
    expect(stillLinked?.profile_id).toBe(claimant.id);
  });
});
