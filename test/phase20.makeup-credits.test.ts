// Integration tests for Phase 20 (MakeupCredit, ADR-0025). Requires a
// running local Supabase (`npx supabase start`).
//
// The test the ADR itself flagged as the one that actually matters: two
// simultaneous bookings of the SAME customer on two DIFFERENT occurrences,
// with one credit available, must resolve to exactly one winner. A test
// written against the *same* occurrence would be rejected by capacity or
// ALREADY_BOOKED before the credit is ever consulted -- see ADR-0025 §0.1.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

async function setupOrgWithPaidQuotaService(prefix: string) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", payment_required: true, created_by: owner.id })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  const planId = await createServicePlan(owner, {
    organizationId: org.id,
    serviceId: service!.id,
    planKind: "WEEKLY_QUOTA",
    weeklyQuota: 1,
    price: 1800,
  });

  await owner.client
    .from("organizations")
    .update({ makeup_credits_enabled: true, release_deadline_hours: 12 })
    .eq("id", org.id);

  return { owner, org, service: service!, resource: resource!, planId };
}

async function createRule(
  owner: SignedInUser,
  org: { id: string },
  service: { id: string },
  resource: { id: string },
  weekdayOffset: number,
  capacity: number,
) {
  const weekday = (new Date().getUTCDay() + weekdayOffset) % 7;
  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service.id,
      resource_id: resource.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity,
      created_by: owner.id,
    })
    .select()
    .single();
  return rule! as { id: string };
}

async function enroll(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: row } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: row! as { id: string } };
}

describe("Phase 20: makeup credits (ADR-0025)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it(
    "ADR-0025 (the test that matters): two simultaneous bookings of the same customer on two DIFFERENT occurrences, one credit available -> exactly one consumes it",
    async () => {
      const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-race");
      createdUserIds.push(owner.id);

      const ruleA = await createRule(owner, org, service, resource, 2, 5);
      const ruleB = await createRule(owner, org, service, resource, 4, 5);
      const occA = await firstFutureOccurrence(owner, ruleA.id);
      const occB = await firstFutureOccurrence(owner, ruleB.id);

      const { customer, customerRow } = await enroll(owner, org, "p20-race-cust");
      createdUserIds.push(customer.id);

      // Paid month, WEEKLY_QUOTA 1, but NO RecurringBooking on either rule:
      // a one-off booking on occA or occB is, by definition, an "extra"
      // (OUTSIDE_PLAN_QUOTA) that only a makeup credit can rescue.
      await payFor(owner, {
        organizationId: org.id,
        customerId: customerRow.id,
        serviceId: service.id,
        from: isoDate(-2),
        to: isoDate(35),
        servicePlanId: planId,
      });

      const { data: credit, error: creditError } = await owner.client.rpc("grant_manual_makeup_credit", {
        p_customer_id: customerRow.id,
        p_service_id: service.id,
        p_expires_on: isoDate(60),
        p_note: "Cortesia de prueba",
      });
      expect(creditError).toBeNull();

      // Genuinely concurrent: neither call is awaited before the other
      // fires. book_slot()'s occurrence lock (ADR-0004) does NOT serialize
      // these two calls -- they lock two different SlotOccurrence rows.
      // Only the credit's own conditional UPDATE (ADR-0025 §0.1) can.
      const [resA, resB] = await Promise.all([
        customer.client.rpc("book_slot", { p_slot_occurrence_id: occA.id }),
        customer.client.rpc("book_slot", { p_slot_occurrence_id: occB.id }),
      ]);

      const results = [resA, resB];
      const winners = results.filter((r) => r.data?.status === "OK");
      const losers = results.filter((r) => r.data?.status !== "OK");

      expect(winners).toHaveLength(1);
      expect(losers).toHaveLength(1);
      expect(winners[0]!.data.makeup_credit_id).toBe(credit.id);

      // The loser never silently succeeded for free: either a clean
      // rejection (it re-evaluated with no credit left) or the race
      // exception -- never a second CONFIRMED booking.
      const { count } = await owner.client
        .from("bookings")
        .select("id", { count: "exact", head: true })
        .eq("customer_id", customerRow.id)
        .eq("status", "CONFIRMED");
      expect(count).toBe(1);

      const { data: creditRow } = await admin
        .from("makeup_credits")
        .select("status, consumed_booking_id")
        .eq("id", credit.id)
        .single();
      expect(creditRow!.status).toBe("CONSUMED");
      expect(creditRow!.consumed_booking_id).toBe(winners[0]!.data.booking.id);
    },
    20_000,
  );

  it("never spends a credit when another coverage already reaches OK", async () => {
    const { owner, org, service, resource } = await setupOrgWithPaidQuotaService("p20-unlimited");
    createdUserIds.push(owner.id);

    const unlimitedPlanId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "UNLIMITED",
      price: 2000,
    });

    const rule = await createRule(owner, org, service, resource, 3, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p20-unlimited-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: unlimitedPlanId,
    });

    const { data: credit } = await owner.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: service.id,
      p_expires_on: isoDate(60),
      p_note: "No deberia usarse",
    });

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(booked.data.status).toBe("OK");
    expect(booked.data.makeup_credit_id).toBeNull();

    const { data: creditRow } = await admin.from("makeup_credits").select("status").eq("id", credit.id).single();
    expect(creditRow!.status).toBe("AVAILABLE");
  });

  it("releasing a series date with enough anticipation issues a credit; returns it if the extra booking it paid for is later cancelled, and never mints a second one", async () => {
    const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-issue");
    createdUserIds.push(owner.id);

    const rule = await createRule(owner, org, service, resource, 2, 5);

    const { customer, customerRow } = await enroll(owner, org, "p20-issue-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: planId,
    });

    const { data: rb, error: rbError } = await customer.client.rpc("create_recurring_booking", {
      p_schedule_rule_id: rule.id,
    });
    expect(rbError).toBeNull();

    const occ = await firstFutureOccurrence(owner, rule.id);
    const { data: seriesBooking } = await owner.client
      .from("bookings")
      .select("id, status")
      .eq("recurring_booking_id", rb.id)
      .eq("slot_occurrence_id", occ.id)
      .single();
    expect(seriesBooking!.status).toBe("CONFIRMED");

    // The occurrence is days out and the deadline is 12h: releasing it now
    // clears the anticipation gate (condition 6) and coverage re-evaluates
    // OK (condition 4, it is still inside the plan's quota) -> emits.
    const released = await customer.client.rpc("cancel_booking", { p_booking_id: seriesBooking!.id });
    expect(released.data.status).toBe("CANCELLED");

    const { data: creditsAfterRelease } = await customer.client.rpc("my_makeup_credits");
    expect(creditsAfterRelease).toHaveLength(1);
    expect(creditsAfterRelease![0].origin).toBe("CUSTOMER_RELEASE");
    expect(creditsAfterRelease![0].status).toBe("AVAILABLE");
    const creditId = creditsAfterRelease![0].credit_id;

    // Use it on a fresh extra occurrence of the SAME service.
    const rule2 = await createRule(owner, org, service, resource, 5, 5);
    const occ2 = await firstFutureOccurrence(owner, rule2.id);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ2.id });
    expect(booked.data.status).toBe("OK");
    expect(booked.data.makeup_credit_id).toBe(creditId);

    // Cancel the extra booking the credit paid for: the credit comes back,
    // and cancelling it never mints a second one (ADR-0025 §2.5.3 / case 7).
    const cancelledExtra = await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });
    expect(cancelledExtra.data.status).toBe("CANCELLED");

    const { data: creditsFinal } = await customer.client.rpc("my_makeup_credits");
    expect(creditsFinal).toHaveLength(1);
    expect(creditsFinal![0].credit_id).toBe(creditId);
    expect(creditsFinal![0].status).toBe("AVAILABLE");
  });

  it("does not issue a credit when the release comes without enough anticipation", async () => {
    const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-late");
    createdUserIds.push(owner.id);

    // A deadline longer than the booking horizon: no future occurrence can
    // ever clear it, so this exercises "insufficient anticipation" without
    // needing to fabricate a same-day occurrence.
    await owner.client.from("organizations").update({ release_deadline_hours: 700 }).eq("id", org.id);

    const rule = await createRule(owner, org, service, resource, 2, 5);
    const { customer, customerRow } = await enroll(owner, org, "p20-late-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: planId,
    });

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });
    const occ = await firstFutureOccurrence(owner, rule.id);
    const { data: seriesBooking } = await owner.client
      .from("bookings")
      .select("id")
      .eq("recurring_booking_id", rb.id)
      .eq("slot_occurrence_id", occ.id)
      .single();

    const released = await customer.client.rpc("cancel_booking", { p_booking_id: seriesBooking!.id });
    expect(released.data.status).toBe("CANCELLED");

    const { data: credits } = await customer.client.rpc("my_makeup_credits");
    expect(credits).toHaveLength(0);
  });

  it("an organization-cancelled occurrence issues credits without requiring any anticipation", async () => {
    const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-orgcancel");
    createdUserIds.push(owner.id);

    // Same "impossible to clear" deadline as above -- proves the org path
    // does not check it at all.
    await owner.client.from("organizations").update({ release_deadline_hours: 700 }).eq("id", org.id);

    const rule = await createRule(owner, org, service, resource, 2, 5);
    const { customer, customerRow } = await enroll(owner, org, "p20-orgcancel-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: planId,
    });

    await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });
    const occ = await firstFutureOccurrence(owner, rule.id);

    await owner.client.rpc("cancel_slot_occurrence", {
      p_slot_occurrence_id: occ.id,
      p_reason: "SLOT_CANCELLED",
    });

    const { data: credits } = await owner.client.rpc("organization_customer_makeup_credits", {
      p_customer_id: customerRow.id,
    });
    expect(credits).toHaveLength(1);
    expect(credits![0].origin).toBe("ORGANIZATION_CANCELLED");
  });

  it("cancelling a whole series (the cascade) never issues a credit, no matter who asks", async () => {
    const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-cascade");
    createdUserIds.push(owner.id);

    const rule = await createRule(owner, org, service, resource, 2, 5);
    const { customer, customerRow } = await enroll(owner, org, "p20-cascade-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: planId,
    });

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { count: confirmedBefore } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("recurring_booking_id", rb.id)
      .eq("status", "CONFIRMED");
    expect(confirmedBefore).toBeGreaterThan(0);

    // ADR-0025 §0.3: the exploit this closes is cancel-the-series /
    // recreate-it-on-the-same-rule / repeat, printing one credit per
    // future date each time. If this ever emits, that exploit is back.
    const cancelled = await customer.client.rpc("cancel_recurring_booking", { p_recurring_booking_id: rb.id });
    expect(cancelled.data.status).toBe("CANCELLED");

    const { data: credits } = await owner.client.rpc("organization_customer_makeup_credits", {
      p_customer_id: customerRow.id,
    });
    expect(credits).toHaveLength(0);
  });

  it("MANUAL credits are OWNER-only, audited with a note, and visible to the customer", async () => {
    const { owner, org, service } = await setupOrgWithPaidQuotaService("p20-manual");
    createdUserIds.push(owner.id);

    const { customer, customerRow } = await enroll(owner, org, "p20-manual-cust");
    createdUserIds.push(customer.id);

    const staff = await createSignedInUser("p20-manual-staff");
    createdUserIds.push(staff.id);
    await admin.from("organization_members").insert({
      organization_id: org.id,
      profile_id: staff.id,
      role: "STAFF",
      created_by: owner.id,
    });

    const asStaff = await staff.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: service.id,
      p_expires_on: isoDate(30),
      p_note: "No deberia poder",
    });
    expect(asStaff.error).not.toBeNull();

    const withoutNote = await owner.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: service.id,
      p_expires_on: isoDate(30),
      p_note: "",
    });
    expect(withoutNote.error).not.toBeNull();

    const asOwner = await owner.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: service.id,
      p_expires_on: isoDate(30),
      p_note: "Cortesia por reclamo en el mostrador",
    });
    expect(asOwner.error).toBeNull();
    expect(asOwner.data.origin).toBe("MANUAL");

    const { data: mine } = await customer.client.rpc("my_makeup_credits");
    expect(mine).toHaveLength(1);
    expect(mine![0].origin).toBe("MANUAL");
  });

  it("get_public_availability: recently_released is a plain boolean, suppressed in BOOLEAN mode", async () => {
    const { owner, org, service, resource, planId } = await setupOrgWithPaidQuotaService("p20-public");
    createdUserIds.push(owner.id);

    const rule = await createRule(owner, org, service, resource, 2, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p20-public-cust");
    createdUserIds.push(customer.id);
    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: planId,
    });
    await owner.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: service.id,
      p_expires_on: isoDate(60),
      p_note: "para reservar y liberar",
    });

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(booked.data.status).toBe("OK");
    await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });

    const { data: rows, error } = await admin.rpc("get_public_availability", { p_organization_slug: org.slug });
    expect(error).toBeNull();
    const row = rows!.find((r: { slot_occurrence_id: string }) => r.slot_occurrence_id === occ.id);
    expect(row.recently_released).toBe(true);

    // BOOLEAN mode suppresses it entirely, same occurrence.
    await owner.client.from("organizations").update({ public_availability_display: "BOOLEAN" }).eq("id", org.id);
    const { data: rowsBoolean } = await admin.rpc("get_public_availability", { p_organization_slug: org.slug });
    const rowBoolean = rowsBoolean!.find((r: { slot_occurrence_id: string }) => r.slot_occurrence_id === occ.id);
    expect(rowBoolean.recently_released).toBeNull();
  });
});
