// Integration tests for payments and booking coverage (ADR-0022, which
// supersedes most of ADR-0013).
//
// The rule that survived the move intact is the one that matters: a
// payment is validated against the SLOT's date, never against "today".
// A payment that is current right now says nothing about a class three
// weeks out, and that is the easy mistake to make.
//
// What changed: coverage is keyed on (customer, service) instead of on a
// ServiceEntitlement, and whether payment is required at all is a
// property of the Service. Requires a running local Supabase.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  makeServicePaid,
  payFor,
  type SignedInUser,
} from "./helpers";

/** ISO date N days from today, in UTC terms. */
function isoDate(offsetDays: number): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

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

  // Two days out, so the occurrence is comfortably in the future.
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

  const occurrence = await firstFutureOccurrence(owner, rule!.id);

  return { owner, org, service: service!, rule: rule!, occurrence };
}

/**
 * Enrolling is the whole requirement now (ADR-0022): there is no second,
 * per-service permission for staff to grant.
 */
async function enrollCustomer(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: customerRow! };
}

describe("Payments and booking coverage", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("a service that does not require payment books with no payment at all", async () => {
    const { owner, org, occurrence } = await setupOrg("p7-free");
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, "p7-free-customer");
    createdUserIds.push(customer.id);

    // Nobody enabled anything for this person: this is what removing
    // manual enablement buys.
    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("OK");
  });

  it("requires a covering payment when the service requires it", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-gated");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-gated-customer");
    createdUserIds.push(customer.id);

    const unpaid = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(unpaid.data.status).toBe("PAYMENT_REQUIRED");

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-30),
      to: isoDate(30),
    });

    const paid = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(paid.data.status).toBe("OK");
  });

  it("the payment must cover the SLOT's date, not the date the booking is made", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-slotdate");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-slotdate-customer");
    createdUserIds.push(customer.id);

    // A period that covers TODAY but ends before the class happens. A
    // naive "is there a payment valid now?" would wrongly allow this.
    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-30),
      to: isoDate(0),
    });

    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("PAYMENT_REQUIRED");
  });

  it("a PENDING or OVERDUE payment does not count as paid", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-pending");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-pending-customer");
    createdUserIds.push(customer.id);

    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-30),
      to: isoDate(30),
      status: "PENDING",
    });

    expect((await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id })).data.status).toBe(
      "PAYMENT_REQUIRED",
    );

    await owner.client.from("payments").update({ status: "OVERDUE" }).eq("id", payment!.id);
    expect((await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id })).data.status).toBe(
      "PAYMENT_REQUIRED",
    );

    // Only registering it as actually paid changes the answer.
    await owner.client.from("payments").update({ status: "PAID" }).eq("id", payment!.id);
    expect((await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id })).data.status).toBe("OK");
  });

  it("CALENDAR_MONTH: paying mid-month covers from the 1st to the last day", async () => {
    const { owner, org, service } = await setupOrg("p7-calendar");
    createdUserIds.push(owner.id);
    // ADR-0024: the billing cycle moved from the Service to the plan, so
    // this function is asked about the plan now. Same two cycles, same
    // arithmetic -- only the anchor changed.
    const planId = await makeServicePaid(owner, service.id, "CALENDAR_MONTH");

    const { data } = await owner.client.rpc("billing_period_for", {
      p_service_plan_id: planId,
      p_from: "2026-09-15",
    });

    expect(data[0].period_start).toBe("2026-09-01");
    expect(data[0].period_end).toBe("2026-09-30");
  });

  it("ROLLING_MONTH: paying on the 15th covers through the 14th of the next month", async () => {
    const { owner, org, service } = await setupOrg("p7-rolling");
    createdUserIds.push(owner.id);
    const planId = await makeServicePaid(owner, service.id, "ROLLING_MONTH");

    const { data } = await owner.client.rpc("billing_period_for", {
      p_service_plan_id: planId,
      p_from: "2026-09-15",
    });

    expect(data[0].period_start).toBe("2026-09-15");
    expect(data[0].period_end).toBe("2026-10-14");

    // Month-end is where a naive "+30 days" goes wrong: paying on 31 Jan
    // has to land on the end of February, whatever length it has.
    const { data: endOfMonth } = await owner.client.rpc("billing_period_for", {
      p_service_plan_id: planId,
      p_from: "2026-01-31",
    });
    expect(endOfMonth[0].period_end).toBe("2026-02-27");
  });

  it("rejects overlapping PAID periods for the same customer and service, but allows gaps", async () => {
    const { owner, org, service } = await setupOrg("p7-overlap");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-overlap-customer");
    createdUserIds.push(customer.id);

    const base = {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
    };

    const first = await payFor(owner, { ...base, from: "2026-01-01", to: "2026-01-31" });
    expect(first.error).toBeNull();

    // Same month charged twice. ADR-0029 moved this EXCLUDE off payments
    // and onto payment_service_coverage (S4.2) -- same rule, new name.
    const overlapping = await payFor(owner, { ...base, from: "2026-01-15", to: "2026-02-15" });
    expect(overlapping.error?.message).toContain("payment_service_coverage_no_overlap");

    // A gap is a valid, expected state: the customer simply did not pay
    // February. Deliberately not a constraint violation.
    const afterGap = await payFor(owner, { ...base, from: "2026-03-01", to: "2026-03-31" });
    expect(afterGap.error).toBeNull();
  });

  it("the same period for a different service is not a double charge", async () => {
    const { owner, org, service } = await setupOrg("p7-twoservices");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-twoservices-customer");
    createdUserIds.push(customer.id);

    const { data: other } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
      .select()
      .single();

    const base = { organizationId: org.id, customerId: customerRow.id, from: "2026-01-01", to: "2026-01-31" };
    expect((await payFor(owner, { ...base, serviceId: service.id })).error).toBeNull();
    // Paying two services for the same month is normal, not a duplicate.
    expect((await payFor(owner, { ...base, serviceId: other!.id })).error).toBeNull();
  });

  it("keeps payments private: the customer sees their own, another org's owner sees nothing", async () => {
    const { owner, org, service } = await setupOrg("p7-privacy");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-privacy-customer");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-30),
      to: isoDate(30),
    });

    const mine = await customer.client.from("payments").select("id");
    expect(mine.data).toHaveLength(1);

    const otherOwner = await createSignedInUser("p7-privacy-other");
    createdUserIds.push(otherOwner.id);
    await createOrganization(otherOwner, "p7-privacy-other-org");

    const theirs = await otherOwner.client.from("payments").select("id").eq("organization_id", org.id);
    expect(theirs.data).toEqual([]);
  });

  it("never deletes a payment -- it is voided instead", async () => {
    const { owner, org, service } = await setupOrg("p7-void");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-void-customer");
    createdUserIds.push(customer.id);

    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-30),
      to: isoDate(30),
    });

    await owner.client.from("payments").delete().eq("id", payment!.id);

    const { data: stillThere } = await owner.client.from("payments").select("id").eq("id", payment!.id);
    expect(stillThere).toHaveLength(1);

    const voided = await owner.client
      .from("payments")
      .update({ status: "VOID" })
      .eq("id", payment!.id)
      .select()
      .single();
    expect(voided.data?.status).toBe("VOID");
  });

  it("a recurring series stops confirming dates once the payment no longer covers them", async () => {
    const { owner, org, service, rule } = await setupOrg("p7-recurring");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-recurring-customer");
    createdUserIds.push(customer.id);

    // One month paid; the rolling window holds far more weekly dates, so
    // the series self-limits instead of booking indefinitely.
    const cutoff = isoDate(20);
    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: cutoff,
    });

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { count: confirmed } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("recurring_booking_id", rb.id)
      .eq("status", "CONFIRMED");
    expect(confirmed).toBeGreaterThan(0);

    const { count: notGenerated } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("recurring_booking_id", rb.id)
      .eq("status", "NOT_GENERATED");
    expect(notGenerated).toBeGreaterThan(0);
  });
});
