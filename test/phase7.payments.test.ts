// Integration tests for Phase 7 (Payments): the ADR-0013 rule that a
// payment is validated against the *slot's* date and never "today",
// entitlement-vs-payment separation (courtesy access needs no payment),
// credit consumption and restoration, and payment privacy.
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

/** ISO date (YYYY-MM-DD) N days from today, in UTC terms. */
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

  const { data: occurrences } = await owner.client
    .from("slot_occurrences")
    .select("id, start_at")
    .eq("schedule_rule_id", rule!.id)
    .order("start_at", { ascending: true })
    .limit(1);

  return { owner, org, service: service!, rule: rule!, occurrence: occurrences![0]! };
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

describe("Phase 7: payments and entitlement consumption", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("requires a covering payment when the entitlement demands one", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-needspay");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-needspay-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: true,
        created_by: owner.id,
      })
      .select()
      .single();

    // Entitlement is live but unpaid -- the customer-facing difference
    // between "you don't have this service" and "your payment lapsed".
    const unpaid = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(unpaid.data.status).toBe("PAYMENT_REQUIRED");

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      period_start: isoDate(-30),
      period_end: isoDate(30),
      status: "PAID",
      amount: 1500,
      created_by: owner.id,
    });

    const paid = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(paid.data.status).toBe("OK");
  });

  it("ADR-0013: the payment must cover the SLOT's date, not the date the booking is made", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-slotdate");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-slotdate-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: true,
        created_by: owner.id,
      })
      .select()
      .single();

    // A period that covers TODAY but ends before the class happens. A
    // naive implementation checking "is there a payment valid now?" would
    // wrongly allow this -- the class is 2 days out, the payment ends
    // yesterday+1.
    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      period_start: isoDate(-30),
      period_end: isoDate(0),
      status: "PAID",
      created_by: owner.id,
    });

    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("PAYMENT_REQUIRED");
  });

  it("a PENDING or OVERDUE payment does not count as paid", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-pending");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-pending-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: true,
        created_by: owner.id,
      })
      .select()
      .single();

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      period_start: isoDate(-30),
      period_end: isoDate(30),
      status: "PENDING",
      created_by: owner.id,
    });

    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("PAYMENT_REQUIRED");
  });

  it("courtesy access: requires_active_payment = false books with no Payment at all (pago != permiso)", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-courtesy");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-courtesy-customer");
    createdUserIds.push(customer.id);

    await owner.client.from("service_entitlements").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_id: service.id,
      entitlement_type: "TIME",
      valid_from: "2020-01-01",
      requires_active_payment: false,
      created_by: owner.id,
    });

    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("OK");
  });

  it("spends a credit on booking and gives it back on cancellation", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-credits");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-credits-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "CREDITS",
        credits_total: 10,
        credits_remaining: 10,
        requires_active_payment: true, // credits imply the pack was paid (ADR-0013)
        created_by: owner.id,
      })
      .select()
      .single();

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(booked.data.status).toBe("OK");
    expect(booked.data.booking.service_entitlement_id).toBe(entitlement!.id);

    const { data: afterBooking } = await owner.client
      .from("service_entitlements")
      .select("credits_remaining")
      .eq("id", entitlement!.id)
      .single();
    expect(afterBooking?.credits_remaining).toBe(9);

    await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });

    const { data: afterCancel } = await owner.client
      .from("service_entitlements")
      .select("credits_remaining")
      .eq("id", entitlement!.id)
      .single();
    expect(afterCancel?.credits_remaining).toBe(10);
  });

  it("a CREDITS entitlement with zero credits left blocks booking", async () => {
    const { owner, org, service, occurrence } = await setupOrg("p7-nocredits");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-nocredits-customer");
    createdUserIds.push(customer.id);

    await owner.client.from("service_entitlements").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_id: service.id,
      entitlement_type: "CREDITS",
      credits_total: 5,
      credits_remaining: 0,
      created_by: owner.id,
    });

    const res = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(res.data.status).toBe("NO_ENTITLEMENT");
  });

  it("rejects overlapping PAID periods for the same entitlement (double charge), but allows gaps", async () => {
    const { owner, org, service } = await setupOrg("p7-overlap");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-overlap-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        created_by: owner.id,
      })
      .select()
      .single();

    const base = {
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      status: "PAID" as const,
      created_by: owner.id,
    };

    const first = await owner.client
      .from("payments")
      .insert({ ...base, period_start: "2026-09-01", period_end: "2026-09-30" });
    expect(first.error).toBeNull();

    const overlapping = await owner.client
      .from("payments")
      .insert({ ...base, period_start: "2026-09-15", period_end: "2026-10-15" });
    expect(overlapping.error).not.toBeNull();

    // A gap (skipping October entirely) is a legitimate state: the
    // customer simply didn't pay that stretch.
    const withGap = await owner.client
      .from("payments")
      .insert({ ...base, period_start: "2026-11-01", period_end: "2026-11-30" });
    expect(withGap.error).toBeNull();
  });

  it("keeps payments private: the customer sees their own, another org's owner sees nothing", async () => {
    const { owner, org, service } = await setupOrg("p7-privacy");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-privacy-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        created_by: owner.id,
      })
      .select()
      .single();

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      period_start: isoDate(-10),
      period_end: isoDate(20),
      status: "PAID",
      amount: 2000,
      created_by: owner.id,
    });

    const ownView = await customer.client.from("payments").select("id");
    expect(ownView.data).toHaveLength(1);

    const otherOwner = await createSignedInUser("p7-privacy-other");
    createdUserIds.push(otherOwner.id);
    await createOrganization(otherOwner, "p7-privacy-other-org");

    const crossView = await otherOwner.client.from("payments").select("id").eq("organization_id", org.id);
    expect(crossView.data).toEqual([]);
  });

  it("never deletes a payment -- it is voided instead", async () => {
    const { owner, org, service } = await setupOrg("p7-void");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-void-customer");
    createdUserIds.push(customer.id);

    const { data: entitlement } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        created_by: owner.id,
      })
      .select()
      .single();

    const { data: payment } = await owner.client
      .from("payments")
      .insert({
        organization_id: org.id,
        customer_id: customerRow.id,
        service_entitlement_id: entitlement!.id,
        period_start: isoDate(-10),
        period_end: isoDate(20),
        status: "PAID",
        created_by: owner.id,
      })
      .select()
      .single();

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

  it("a recurring series stops confirming dates once the entitlement can no longer cover them", async () => {
    const { owner, org, service, rule } = await setupOrg("p7-recurring");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, "p7-recurring-customer");
    createdUserIds.push(customer.id);

    // Two credits, but the rolling window holds far more weekly dates --
    // so the series self-limits instead of booking indefinitely.
    await owner.client.from("service_entitlements").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_id: service.id,
      entitlement_type: "CREDITS",
      credits_total: 2,
      credits_remaining: 2,
      created_by: owner.id,
    });

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { count: confirmed } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("recurring_booking_id", rb.id)
      .eq("status", "CONFIRMED");
    expect(confirmed).toBe(2);

    const { count: notGenerated } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("recurring_booking_id", rb.id)
      .eq("status", "NOT_GENERATED");
    expect(notGenerated).toBeGreaterThan(0);
  });
});
