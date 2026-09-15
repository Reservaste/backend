// Integration tests for Phase 12: a date that could not be confirmed is
// pending, not decided. Registering the payment has to unblock the
// upcoming dates of a standing reservation by itself -- before this, the
// front desk had to delete and recreate the series. Requires a running
// local Supabase (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

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

async function enrollCustomer(
  owner: SignedInUser,
  org: { id: string },
  serviceId: string,
  prefix: string,
  entitlement: Record<string, unknown>,
) {
  const customer = await createSignedInUser(prefix);

  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();

  const { data: entitlementRow } = await owner.client
    .from("service_entitlements")
    .insert({
      organization_id: org.id,
      customer_id: customerRow!.id,
      service_id: serviceId,
      created_by: owner.id,
      // The column defaults to true; these tests are explicit about which
      // entitlements are payment-gated, because that is what they measure.
      requires_active_payment: false,
      ...entitlement,
    })
    .select()
    .single();

  return { customer, customerRow: customerRow!, entitlement: entitlementRow! };
}

async function bookingsOf(owner: SignedInUser, recurringBookingId: string) {
  const { data } = await owner.client
    .from("bookings")
    .select("id, status, not_generated_reason, slot_occurrence_id, slot_occurrences(start_at)")
    .eq("recurring_booking_id", recurringBookingId)
    .order("slot_occurrence_id", { ascending: true });
  return data as Array<{
    id: string;
    status: string;
    not_generated_reason: string | null;
    slot_occurrence_id: string;
    slot_occurrences: { start_at: string };
  }>;
}

describe("Phase 12: pending dates reconcile when the payment lands", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("registering the payment confirms the upcoming dates on its own", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-pay");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-pay-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", requires_active_payment: true },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const before = await bookingsOf(owner, rb.id);
    expect(before.length).toBeGreaterThan(0);
    expect(before.every((b) => b.status === "NOT_GENERATED")).toBe(true);

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement.id,
      period_start: isoDate(-1),
      period_end: isoDate(200),
      status: "PAID",
      amount: 2000,
      created_by: owner.id,
    });

    const after = await bookingsOf(owner, rb.id);
    expect(after.every((b) => b.status === "CONFIRMED")).toBe(true);
    expect(after.every((b) => b.not_generated_reason === null)).toBe(true);
  });

  it("only the dates the payment actually covers get confirmed", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-partial");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-partial-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", requires_active_payment: true },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    // One month paid, the rolling window holds ~3. ADR-0013: each date is
    // validated against the class's own date, not against today.
    const cutoff = isoDate(30);
    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement.id,
      period_start: isoDate(-1),
      period_end: cutoff,
      status: "PAID",
      created_by: owner.id,
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
      expect(b.not_generated_reason).toBe("NO_ENTITLEMENT");
    }
  });

  it("a credit top-up confirms the next dates in order, not an arbitrary set", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-credits");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-credits-customer",
      { entitlement_type: "CREDITS", credits_total: 10, credits_remaining: 0 },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const before = await bookingsOf(owner, rb.id);
    expect(before.every((b) => b.status === "NOT_GENERATED")).toBe(true);
    expect(before.length).toBeGreaterThan(2);

    await owner.client
      .from("service_entitlements")
      .update({ credits_remaining: 2 })
      .eq("id", entitlement.id);

    const after = await bookingsOf(owner, rb.id);
    const confirmed = after
      .filter((b) => b.status === "CONFIRMED")
      .sort((a, b) => a.slot_occurrences.start_at.localeCompare(b.slot_occurrences.start_at));
    expect(confirmed).toHaveLength(2);

    // The two earliest dates, and the credits are spent exactly once each.
    const earliest = after
      .map((b) => b.slot_occurrences.start_at)
      .sort()
      .slice(0, 2);
    expect(confirmed.map((b) => b.slot_occurrences.start_at)).toEqual(earliest);

    const { data: entAfter } = await owner.client
      .from("service_entitlements")
      .select("credits_remaining")
      .eq("id", entitlement.id)
      .single();
    expect(entAfter?.credits_remaining).toBe(0);
  });

  it("reactivating a suspended entitlement brings the series back", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-reactivate");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-reactivate-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", is_active: false },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "NOT_GENERATED")).toBe(true);

    await owner.client.from("service_entitlements").update({ is_active: true }).eq("id", entitlement.id);

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });

  it("a date that filled up while unpaid stays pending, with the reason updated", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-filled", 1);
    createdUserIds.push(owner.id);
    const standing = await enrollCustomer(owner, org, service.id, "p12-filled-standing", {
      entitlement_type: "TIME",
      valid_from: "2020-01-01",
      requires_active_payment: true,
    });
    const walkIn = await enrollCustomer(owner, org, service.id, "p12-filled-walkin", {
      entitlement_type: "TIME",
      valid_from: "2020-01-01",
    });
    createdUserIds.push(standing.customer.id, walkIn.customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: standing.customerRow.id,
    });

    // While the month was unpaid, someone else took the only seat on the
    // first date.
    const pending = await bookingsOf(owner, rb.id);
    const firstDate = pending.sort((a, b) =>
      a.slot_occurrences.start_at.localeCompare(b.slot_occurrences.start_at),
    )[0]!;
    const taken = await walkIn.customer.client.rpc("book_slot", {
      p_slot_occurrence_id: firstDate.slot_occurrence_id,
    });
    expect(taken.data.status).toBe("OK");

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: standing.customerRow.id,
      service_entitlement_id: standing.entitlement.id,
      period_start: isoDate(-1),
      period_end: isoDate(200),
      status: "PAID",
      created_by: owner.id,
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
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-past-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", requires_active_payment: true },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    // A class the customer missed because they hadn't paid. Built with the
    // service role because the rolling window only ever holds future
    // dates, and history is exactly what must not be rewritten.
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
        not_generated_reason: "NO_ENTITLEMENT",
      })
      .select()
      .single();

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement.id,
      period_start: isoDate(-60),
      period_end: isoDate(200),
      status: "PAID",
      created_by: owner.id,
    });

    const { data: pastAfter } = await admin
      .from("bookings")
      .select("status")
      .eq("id", pastBooking!.id)
      .single();
    expect(pastAfter?.status).toBe("NOT_GENERATED");
  });

  it("granting the entitlement afterwards unblocks the series", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-grant");
    createdUserIds.push(owner.id);

    // The realistic order at a front desk: assign the fixed slot first,
    // enable the service second.
    const customer = await createSignedInUser("p12-grant-customer");
    createdUserIds.push(customer.id);
    const { data: customerRow } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
      .select()
      .single();

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow!.id,
    });
    const before = await bookingsOf(owner, rb.id);
    expect(before.length).toBeGreaterThan(0);
    expect(before.every((b) => b.status === "NOT_GENERATED")).toBe(true);
    expect(before.every((b) => b.not_generated_reason === "NO_ENTITLEMENT")).toBe(true);

    await owner.client.from("service_entitlements").insert({
      organization_id: org.id,
      customer_id: customerRow!.id,
      service_id: service.id,
      entitlement_type: "TIME",
      valid_from: "2020-01-01",
      requires_active_payment: false,
      created_by: owner.id,
    });

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });

  it("does not resurrect a cancelled series", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-cancelled");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-cancelled-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", requires_active_payment: true },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    await owner.client.rpc("cancel_recurring_booking", { p_recurring_booking_id: rb.id });

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement.id,
      period_start: isoDate(-1),
      period_end: isoDate(200),
      status: "PAID",
      created_by: owner.id,
    });

    const after = await bookingsOf(owner, rb.id);
    expect(after.some((b) => b.status === "CONFIRMED")).toBe(false);
  });

  it("a PENDING payment does not unblock anything", async () => {
    const { owner, org, service, rule } = await setupPilates("p12-pending-payment");
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p12-pending-payment-customer",
      { entitlement_type: "TIME", valid_from: "2020-01-01", requires_active_payment: true },
    );
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: payment } = await owner.client
      .from("payments")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_entitlement_id: entitlement.id,
        period_start: isoDate(-1),
        period_end: isoDate(200),
        status: "PENDING",
        created_by: owner.id,
      })
      .select()
      .single();

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "NOT_GENERATED")).toBe(true);

    // Marking it PAID later is the moment it counts.
    await owner.client.from("payments").update({ status: "PAID" }).eq("id", payment!.id);

    expect((await bookingsOf(owner, rb.id)).every((b) => b.status === "CONFIRMED")).toBe(true);
  });
});
