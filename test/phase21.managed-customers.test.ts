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

    const { data: claimed, error: claimErr } = await claimant.client.rpc("claim_customer_activation", {
      p_token: plainToken,
    });
    expect(claimErr).toBeNull();

    // El canje tiene que decir de QUÉ negocio era la invitación: es lo
    // único que permite aterrizar a la persona en la agenda del negocio
    // que la invitó (ADR-0023) en vez de en un portal genérico y vacío
    // -- el callejón sin salida que reportó el feedback de producción
    // ("cuando me invitan como usuario no veo la agenda como para
    // comprar o reservar"). El slug sale del token adentro de la RPC, el
    // caller nunca lo elige.
    expect((claimed as { status: string }).status).toBe("OK");
    expect((claimed as { organization_slug: string }).organization_slug).toBe(org.slug);

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

  /**
   * Regression guard for the production bug reported on 2026-09-23: "el
   * primer intento de abrir el link ya dice que está expirado".
   *
   * The expiry itself was never wrong -- these tests pin that down -- but
   * 72h is a number the frontend has to mirror, because the clear token
   * survives only in the cookie the activation route hands out (the
   * database keeps a SHA-256 and nothing else). That cookie was living 15
   * minutes. Anything that asserts the TTL has to assert it on both
   * sides: here, and in `frontend/app/activar/[token]/route.test.ts`,
   * which requires the cookie to outlive whatever this window is.
   */
  describe("activation window (ADR-0026 resolution 8: 72h)", () => {
    async function issueFor(displayName: string) {
      const owner = await createSignedInUser("owner-ttl");
      const org = await createOrganization(owner, "org-ttl");
      const { data: customer, error: createErr } = await owner.client.rpc("create_managed_customer", {
        p_organization_id: org.id,
        p_display_name: displayName,
        // Unique per call: `customers_organization_phone_idx` is per
        // organization, but a shared literal makes reruns confusing.
        p_phone: `+5989${Math.floor(1000000 + Math.random() * 8999999)}`,
      });
      expect(createErr).toBeNull();

      const { data: issued, error: issueErr } = await owner.client.rpc("issue_customer_activation", {
        p_customer_id: customer!.id,
      });
      expect(issueErr).toBeNull();
      const row = Array.isArray(issued) ? issued[0] : issued;
      return { owner, org, customerId: customer!.id as string, activationId: row.activation_id as string, token: row.token as string };
    }

    it("issues a token that lasts exactly 72h and is claimable immediately", async () => {
      const { activationId, token } = await issueFor("TTL Recién Emitido");

      const { data: row } = await admin
        .from("customer_activations")
        .select("created_at, expires_at")
        .eq("id", activationId)
        .single();

      const ttlHours =
        (new Date(row!.expires_at as string).getTime() - new Date(row!.created_at as string).getTime()) / 3_600_000;
      expect(ttlHours).toBe(72);
      // Both columns are timestamptz and both come from the same now():
      // a fresh link can never read as already expired, whatever the
      // server's or the organization's timezone is.
      expect(new Date(row!.expires_at as string).getTime()).toBeGreaterThan(Date.now());

      const claimant = await createSignedInUser("claimant-immediate");
      const { data: result, error } = await claimant.client.rpc("claim_customer_activation", { p_token: token });
      expect(error).toBeNull();
      expect((result as { status?: string })?.status).toBe("OK");
    });

    it("still claims at the far edge of the window, and only fails past it", async () => {
      const edge = await issueFor("TTL Casi Vencido");
      await admin
        .from("customer_activations")
        .update({ expires_at: new Date(Date.now() + 5_000).toISOString() })
        .eq("id", edge.activationId);

      const edgeClaimant = await createSignedInUser("claimant-edge");
      const { error: edgeErr } = await edgeClaimant.client.rpc("claim_customer_activation", { p_token: edge.token });
      expect(edgeErr).toBeNull();

      const past = await issueFor("TTL Vencido");
      await admin
        .from("customer_activations")
        .update({ expires_at: new Date(Date.now() - 1_000).toISOString() })
        .eq("id", past.activationId);

      const lateClaimant = await createSignedInUser("claimant-late");
      const { error: lateErr } = await lateClaimant.client.rpc("claim_customer_activation", { p_token: past.token });
      expect(lateErr).not.toBeNull();
      expect(lateErr!.message).toMatch(/ACTIVATION_EXPIRED/);

      // An expired link is not a consumed link: it stays unredeemed, so
      // reissuing is what fixes it (and the customer keeps no profile).
      const { data: after } = await admin
        .from("customer_activations")
        .select("redeemed_at")
        .eq("id", past.activationId)
        .single();
      expect(after?.redeemed_at).toBeNull();
    });
  });
});
