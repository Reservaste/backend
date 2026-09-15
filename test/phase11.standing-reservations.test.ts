// Integration tests for Phase 11 (standing reservations from the front
// desk): the "client pays monthly for every Monday 09:00 Pilates" case,
// set up by staff on the customer's behalf rather than by the customer.
// Phase 6 covered the engine; what is tested here is the admin path into
// it, and that opening that path did not open a hole. Requires a running
// local Supabase (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

function isoDate(offsetDays: number) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

async function setupPilates(prefix: string, capacity: number) {
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

  // Monday 09:00-10:00, the user's actual example.
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
  options: { entitlement?: boolean; requiresPayment?: boolean } = {},
) {
  const { entitlement = true, requiresPayment = false } = options;
  const customer = await createSignedInUser(prefix);

  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();

  let entitlementRow: { id: string } | null = null;
  if (entitlement) {
    const { data } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerRow!.id,
        service_id: serviceId,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: requiresPayment,
        created_by: owner.id,
      })
      .select()
      .single();
    entitlementRow = data;
  }

  return { customer, customerRow: customerRow!, entitlement: entitlementRow };
}

describe("Phase 11: standing reservations", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("the front desk can give a named customer a standing Monday 09:00 slot", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-standing", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p11-standing-customer");
    createdUserIds.push(customer.id);

    const { data: rb, error } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    expect(rb.status).toBe("ACTIVE");
    expect(rb.customer_id).toBe(customerRow.id);

    const { data: bookings } = await owner.client
      .from("bookings")
      .select("status, customer_id")
      .eq("recurring_booking_id", rb.id);

    expect(bookings!.length).toBeGreaterThan(0);
    for (const b of bookings!) {
      expect(b.status).toBe("CONFIRMED");
      expect(b.customer_id).toBe(customerRow.id);
    }

    // The customer sees it as their own booking, not as something opaque
    // the gym did to their account.
    const { data: mine } = await customer.client.rpc("my_bookings");
    expect(mine.length).toBeGreaterThan(0);
  });

  it("preview on someone's behalf reports the same reasons and books nothing", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-preview", 10);
    createdUserIds.push(owner.id);
    const withEnt = await enrollCustomer(owner, org, service.id, "p11-preview-ok");
    const withoutEnt = await enrollCustomer(owner, org, service.id, "p11-preview-noent", {
      entitlement: false,
    });
    createdUserIds.push(withEnt.customer.id, withoutEnt.customer.id);

    const ok = await owner.client.rpc("admin_preview_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: withEnt.customerRow.id,
      p_count: 4,
    });
    expect(ok.error).toBeNull();
    expect(ok.data.length).toBeGreaterThan(0);
    expect(ok.data.every((r: { can_book: string }) => r.can_book === "OK")).toBe(true);

    const blocked = await owner.client.rpc("admin_preview_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: withoutEnt.customerRow.id,
      p_count: 4,
    });
    expect(blocked.data.every((r: { can_book: string }) => r.can_book === "NO_ENTITLEMENT")).toBe(true);

    const { count } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org.id);
    expect(count).toBe(0);
  });

  it("an unpaid month keeps the series alive but stops confirming dates", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-unpaid", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p11-unpaid-customer", {
      requiresPayment: true,
    });
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    // This is the self-limiting property the business model depends on:
    // no payment covering those dates means no confirmed classes, without
    // anyone having to remember to switch the series off.
    const { data: bookings } = await owner.client
      .from("bookings")
      .select("status, not_generated_reason")
      .eq("recurring_booking_id", rb.id);
    expect(bookings!.length).toBeGreaterThan(0);
    expect(bookings!.every((b: { status: string }) => b.status === "NOT_GENERATED")).toBe(true);
    // The reason has to say "unpaid", not "full" -- the customer can act
    // on one of those and not the other.
    expect(
      bookings!.every((b: { not_generated_reason: string }) => b.not_generated_reason === "NO_ENTITLEMENT"),
    ).toBe(true);

    const { data: rows } = await owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    const row = rows.find((r: { recurring_booking_id: string }) => r.recurring_booking_id === rb.id);
    expect(row.status).toBe("ACTIVE");
    expect(row.upcoming_confirmed).toBe(0);
    expect(row.upcoming_not_generated).toBeGreaterThan(0);
    expect(row.upcoming_unpaid).toBe(row.upcoming_not_generated);

    // And the customer is told, instead of the class disappearing.
    const { data: mine } = await customer.client.rpc("my_bookings");
    const pending = mine.filter((b: { status: string }) => b.status === "NOT_GENERATED");
    expect(pending.length).toBeGreaterThan(0);
    expect(pending[0].not_generated_reason).toBe("NO_ENTITLEMENT");
  });

  it("a full class is recorded as SLOT_FULL, not as an unpaid month", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-fullreason", 1);
    createdUserIds.push(owner.id);
    const holder = await enrollCustomer(owner, org, service.id, "p11-fullreason-holder");
    const late = await enrollCustomer(owner, org, service.id, "p11-fullreason-late");
    createdUserIds.push(holder.customer.id, late.customer.id);

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule.id)
      .order("start_at", { ascending: true })
      .limit(1);
    const occurrenceId = occurrences![0]!.id;

    const filled = await holder.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(filled.data.status).toBe("OK");

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: late.customerRow.id,
    });

    const { data: blockedDate } = await owner.client
      .from("bookings")
      .select("status, not_generated_reason")
      .eq("recurring_booking_id", rb.id)
      .eq("slot_occurrence_id", occurrenceId)
      .single();
    expect(blockedDate?.status).toBe("NOT_GENERATED");
    expect(blockedDate?.not_generated_reason).toBe("SLOT_FULL");

    const { data: rows } = await owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    const row = rows.find((r: { recurring_booking_id: string }) => r.recurring_booking_id === rb.id);
    expect(row.upcoming_unpaid).toBe(0);
  });

  it("paying the month makes the following dates confirm again", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-paid", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow, entitlement } = await enrollCustomer(
      owner,
      org,
      service.id,
      "p11-paid-customer",
      { requiresPayment: true },
    );
    createdUserIds.push(customer.id);

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      service_entitlement_id: entitlement!.id,
      period_start: isoDate(-1),
      period_end: isoDate(120),
      status: "PAID",
      amount: 2000,
      created_by: owner.id,
    });

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: rows } = await owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    const row = rows.find((r: { recurring_booking_id: string }) => r.recurring_booking_id === rb.id);
    expect(row.upcoming_confirmed).toBeGreaterThan(0);
    expect(row.upcoming_not_generated).toBe(0);
  });

  it("refuses a second standing reservation for the same customer on the same rule", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-dupe", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p11-dupe-customer");
    createdUserIds.push(customer.id);

    const first = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(first.error).toBeNull();

    const second = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(second.error?.message).toContain("ALREADY_HAS_STANDING_RESERVATION");
  });

  it("refuses a customer who belongs to another organization", async () => {
    const a = await setupPilates("p11-xorg-a", 10);
    const b = await setupPilates("p11-xorg-b", 10);
    createdUserIds.push(a.owner.id, b.owner.id);
    const foreign = await enrollCustomer(b.owner, b.org, b.service.id, "p11-xorg-customer");
    createdUserIds.push(foreign.customer.id);

    const res = await a.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: a.rule.id,
      p_customer_id: foreign.customerRow.id,
    });
    expect(res.error?.message).toContain("NOT_A_CUSTOMER");
  });

  it("blocks a non-member from booking a standing slot on someone else's rule", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-outsider", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p11-outsider-customer");
    createdUserIds.push(customer.id);

    // The obvious abuse of an on-behalf-of RPC: call it yourself for
    // someone else's rule. Membership is checked in SQL, so no UI is
    // involved in stopping this.
    const outsider = await createSignedInUser("p11-outsider-attacker");
    createdUserIds.push(outsider.id);
    await createOrganization(outsider, "p11-outsider-org");

    const res = await outsider.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(res.error?.message).toContain("NOT_AUTHORIZED");

    // Same for the customer themself: enrolled, but not staff.
    const asCustomer = await customer.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(asCustomer.error?.message).toContain("NOT_AUTHORIZED");

    // And the listing leaks nothing to a non-member.
    const listing = await outsider.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    expect(listing.data).toEqual([]);

    const preview = await outsider.client.rpc("admin_preview_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(preview.data).toEqual([]);
  });

  it("the front desk can cancel a standing reservation it created", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-cancel", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p11-cancel-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const cancelled = await owner.client.rpc("cancel_recurring_booking", { p_recurring_booking_id: rb.id });
    expect(cancelled.error).toBeNull();
    expect(cancelled.data.status).toBe("CANCELLED");
    expect(cancelled.data.cancellation_reason).toBe("ORGANIZATION_REMOVED");
  });

  it("regression: can_customer_book still resolves the customer from the session, not the caller", async () => {
    const { owner, org, service, rule } = await setupPilates("p11-regression", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p11-regression-customer");
    createdUserIds.push(customer.id);

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule.id)
      .order("start_at", { ascending: true })
      .limit(1);
    const occurrenceId = occurrences![0]!.id;

    const asCustomer = await customer.client.rpc("can_customer_book", { p_slot_occurrence_id: occurrenceId });
    expect(asCustomer.data).toBe("OK");

    // The owner is staff, not an enrolled customer: refactoring the rule
    // out into evaluate_customer_booking() must not have made this answer
    // for whoever happens to ask.
    const asOwner = await owner.client.rpc("can_customer_book", { p_slot_occurrence_id: occurrenceId });
    expect(asOwner.data).toBe("NOT_A_CUSTOMER");
  });
});
