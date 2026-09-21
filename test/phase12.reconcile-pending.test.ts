// Integration tests for ADR-0019, re-anchored by ADR-0022: a date that
// could not be confirmed is pending, not decided.
//
// The trigger used to be entitlement changes. With entitlements gone, the
// writes that can widen what a customer may book are registering a
// payment and switching payment_required off on the service. Requires a
// running local Supabase.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  makeServicePaid,
  payFor,
  type SignedInUser,
} from "./helpers";

function isoDate(offsetDays: number) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

async function setupPilates(prefix: string, capacity = 10) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala reformer", created_by: owner.id })
    .select()
    .single();

  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service!.id,
      resource_id: resource!.id,
      weekday: 1,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity,
      created_by: owner.id,
    })
    .select()
    .single();

  return { owner, org, service: service!, rule: rule! };
}

async function enrollCustomer(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: customerRow! };
}

async function bookingsOf(owner: SignedInUser, recurringBookingId: string) {
  const { data } = await owner.client
    .from("bookings")
    .select("id, status, not_generated_reason, slot_occurrence_id, slot_occurrences(start_at)")
    .eq("recurring_booking_id", recurringBookingId);
  return data as Array<{
    id: string;
    status: string;
    not_generated_reason: string | null;
    slot_occurrence_id: string;
    slot_occurrences: { start_at: string };
  }>;
}

describe("Pending dates reconcile when the payment lands", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("registering the payment confirms the upcoming dates on its own", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-pay");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-pay-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const before = await bookingsOf(owner, rb.id);
    expect(before.length).toBeGreaterThan(0);
    expect(before.every((b) => b.status === "NOT_GENERATED")).toBe(true);
    expect(before.every((b) => b.not_generated_reason === "PAYMENT_REQUIRED")).toBe(true);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(200),
    });

    // Before this existed, the only way out was deleting the series and
    // recreating it.
    const after = await bookingsOf(owner, rb.id);
    expect(after.every((b) => b.status === "CONFIRMED")).toBe(true);
    expect(after.every((b) => b.not_generated_reason === null)).toBe(true);
  });

  it("only the dates the payment actually covers get confirmed", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-partial");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-partial-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    // One month paid, the rolling window holds about three: each date is
    // validated against its own date, not against today.
    const cutoff = isoDate(30);
    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: cutoff,
    });

    const after = await bookingsOf(owner, rb.id);
    const confirmed = after.filter((b) => b.status === "CONFIRMED");
    const pending = after.filter((b) => b.status === "NOT_GENERATED");

    expect(confirmed.length).toBeGreaterThan(0);
    expect(pending.length).toBeGreaterThan(0);
    for (const b of confirmed) {
      expect(b.slot_occurrences.start_at.slice(0, 10) <= cutoff).toBe(true);
    }
    for (const b of pending) {
      expect(b.slot_occurrences.start_at.slice(0, 10) > cutoff).toBe(true);
      expect(b.not_generated_reason).toBe("PAYMENT_REQUIRED");
    }
  });

  it("extending the paid period confirms the dates that were beyond it", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-extend");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-extend-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(10),
    });
    const partial = (await bookingsOf(owner, rb.id)).filter((b) => b.status === "NOT_GENERATED").length;
    expect(partial).toBeGreaterThan(0);

    // Paying the next month is an UPDATE on the same row here; the rule
    // is the same either way.
    await owner.client.from("payments").update({ period_end: isoDate(200) }).eq("id", payment!.id);

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });

  it("making the service free unblocks everyone waiting on payment", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-free");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-free-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "NOT_GENERATED")).toBe(true);

    // Widening access has to reconcile; narrowing it must never
    // retroactively cancel anything, which is why only this direction
    // fires the trigger.
    await owner.client.from("services").update({ payment_required: false }).eq("id", service.id);

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });

  it("a date that filled up while unpaid stays pending, with the reason updated", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-filled", 1);
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const standing = await enrollCustomer(owner, org, "p12-filled-standing");
    const walkIn = await enrollCustomer(owner, org, "p12-filled-walkin");
    createdUserIds.push(standing.customer.id, walkIn.customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: standing.customerRow.id,
    });

    // Someone else paid and took the only seat on the first date.
    const pending = await bookingsOf(owner, rb.id);
    const firstDate = pending.sort((a, b) =>
      a.slot_occurrences.start_at.localeCompare(b.slot_occurrences.start_at),
    )[0]!;
    await payFor(owner, {
      organizationId: org.id,
      customerId: walkIn.customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(200),
    });
    const taken = await walkIn.customer.client.rpc("book_slot", {
      p_slot_occurrence_id: firstDate.slot_occurrence_id,
    });
    expect(taken.data.status).toBe("OK");

    await payFor(owner, {
      organizationId: org.id,
      customerId: standing.customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(200),
    });

    const { data: stillPending } = await owner.client
      .from("bookings")
      .select("status, not_generated_reason")
      .eq("id", firstDate.id)
      .single();
    // Paying does not evict whoever already holds the seat -- but the
    // reason must stop saying "unpaid", because that is no longer true.
    expect(stillPending?.status).toBe("NOT_GENERATED");
    expect(stillPending?.not_generated_reason).toBe("SLOT_FULL");

    const others = (await bookingsOf(owner, rb.id)).filter((b) => b.id !== firstDate.id);
    expect(others.every((b) => b.status === "CONFIRMED")).toBe(true);
  });

  it("never revives a past date", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-past");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-past-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    // A class the customer missed because they had not paid. Built with
    // the service role because the rolling window only holds future dates,
    // and history is exactly what must not be rewritten.
    const past = new Date();
    past.setDate(past.getDate() - 14);
    const { data: pastOccurrence } = await admin
      .from("slot_occurrences")
      .insert({
        organization_id: org.id,
        service_id: service.id,
        resource_id: rule.resource_id,
        schedule_rule_id: rule.id,
        start_at: past.toISOString(),
        end_at: new Date(past.getTime() + 3600_000).toISOString(),
        generated_timezone: "America/Montevideo",
        capacity: 10,
      })
      .select()
      .single();

    const { data: pastBooking } = await admin
      .from("bookings")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        slot_occurrence_id: pastOccurrence!.id,
        recurring_booking_id: rb.id,
        status: "NOT_GENERATED",
        not_generated_reason: "PAYMENT_REQUIRED",
      })
      .select()
      .single();

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-60),
      to: isoDate(200),
    });

    const { data: pastAfter } = await admin
      .from("bookings")
      .select("status")
      .eq("id", pastBooking!.id)
      .single();
    expect(pastAfter?.status).toBe("NOT_GENERATED");
  });

  it("does not resurrect a cancelled series", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-cancelled");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-cancelled-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    await owner.client.rpc("cancel_recurring_booking", { p_recurring_booking_id: rb.id });

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(200),
    });

    const after = await bookingsOf(owner, rb.id);
    expect(after.some((b) => b.status === "CONFIRMED")).toBe(false);
  });

  it("a PENDING payment does not unblock anything", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-pendingpay");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p12-pendingpay-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-1),
      to: isoDate(200),
      status: "PENDING",
    });

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "NOT_GENERATED")).toBe(true);

    // Marking it PAID later is the moment it counts.
    await owner.client.from("payments").update({ status: "PAID" }).eq("id", payment!.id);

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });
});
