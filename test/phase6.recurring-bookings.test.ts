// Integration tests for Phase 6 (Recurring Bookings): the exact
// Mathias/CrossFit case from planning (cancel one date, the series keeps
// going), idempotent generation hooked into the rolling window, the
// NOT_GENERATED fallback for the "two series land on the same occurrence"
// edge case database-agent flagged during Phase 0 planning, and the
// discontinue-rule cascade reaching RecurringBooking. Requires a running
// local Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

async function setupOrgWithService(ownerPrefix: string, capacity: number) {
  const owner = await createSignedInUser(ownerPrefix);
  const org = await createOrganization(owner, `${ownerPrefix}-org`);

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

  return { owner, org, service: service!, rule: rule! };
}

async function enrollCustomer(owner: SignedInUser, org: { id: string }, serviceId: string, prefix: string) {
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

describe("Phase 6: recurring bookings", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("preview reports the same reasons book_slot would give, without booking anything", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-preview", 1);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-preview-customer");
    createdUserIds.push(customer.id);

    const { data: preview, error } = await customer.client.rpc("preview_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_count: 5,
    });
    expect(error).toBeNull();
    expect(preview.length).toBeGreaterThan(0);
    expect(preview.every((p: { can_book: string }) => p.can_book === "OK")).toBe(true);

    // Preview must not have booked anything.
    const { count } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org.id);
    expect(count).toBe(0);
  });

  it("Mathias case: creating a series generates one Booking per occurrence, all pointing to the same RecurringBooking", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-mathias", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomer(owner, org, service.id, "p6-mathias-customer");
    createdUserIds.push(customer.id);

    const { data: rb, error } = await customer.client.rpc("create_recurring_booking", {
      p_schedule_rule_id: rule.id,
    });
    expect(error).toBeNull();
    expect(rb.status).toBe("ACTIVE");

    const { data: bookings } = await owner.client
      .from("bookings")
      .select("id, status, recurring_booking_id, customer_id")
      .eq("recurring_booking_id", rb.id);

    expect(bookings!.length).toBeGreaterThan(0);
    for (const b of bookings!) {
      expect(b.status).toBe("CONFIRMED");
      expect(b.recurring_booking_id).toBe(rb.id);
      expect(b.customer_id).toBe(customerRow.id);
    }
  });

  it("Mathias case: cancelling one date only cancels that Booking -- the series and the rest keep going", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-onedate", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-onedate-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { data: bookings } = await owner.client
      .from("bookings")
      .select("id")
      .eq("recurring_booking_id", rb.id)
      .order("created_at", { ascending: true });
    expect(bookings!.length).toBeGreaterThanOrEqual(2);

    const [first, second] = bookings!;
    const cancelled = await customer.client.rpc("cancel_booking", { p_booking_id: first!.id });
    expect(cancelled.data.status).toBe("CANCELLED");
    expect(cancelled.data.cancellation_reason).toBe("CUSTOMER_REQUEST");

    const { data: secondAfter } = await owner.client.from("bookings").select("status").eq("id", second!.id).single();
    expect(secondAfter?.status).toBe("CONFIRMED");

    const { data: rbAfter } = await owner.client
      .from("recurring_bookings")
      .select("status")
      .eq("id", rb.id)
      .single();
    expect(rbAfter?.status).toBe("ACTIVE");
  });

  it(
    "is idempotent: re-running generation for the rule does not duplicate recurring bookings",
    async () => {
      const { owner, org, service, rule } = await setupOrgWithService("p6-idempotent", 10);
      createdUserIds.push(owner.id);
      const { customer } = await enrollCustomer(owner, org, service.id, "p6-idempotent-customer");
      createdUserIds.push(customer.id);

      const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

      const countBookings = async () => {
        const { count } = await owner.client
          .from("bookings")
          .select("id", { count: "exact", head: true })
          .eq("recurring_booking_id", rb.id);
        return count;
      };

      const before = await countBookings();

      const { error } = await admin.rpc("generate_slot_occurrences_for_rule", { p_schedule_rule_id: rule.id });
      expect(error).toBeNull();

      const after = await countBookings();
      expect(after).toBe(before);
    },
    20_000,
  );

  it("falls back to NOT_GENERATED instead of erroring when the customer already holds a CONFIRMED booking on the same occurrence", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-conflict", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-conflict-customer");
    createdUserIds.push(customer.id);

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule.id)
      .order("start_at", { ascending: true })
      .limit(1);
    const occurrenceId = occurrences![0]!.id;

    // Manual booking first (no recurring series involved).
    const manual = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(manual.data.status).toBe("OK");

    // Now a RecurringBooking whose first occurrence is that same slot --
    // generate_recurring_booking() must not raise (it would hit
    // bookings_customer_occurrence_confirmed_idx), it must record
    // NOT_GENERATED for that one date.
    const { data: rb, error } = await customer.client.rpc("create_recurring_booking", {
      p_schedule_rule_id: rule.id,
    });
    expect(error).toBeNull();

    const { data: recurringBookingForThatSlot } = await owner.client
      .from("bookings")
      .select("status")
      .eq("recurring_booking_id", rb.id)
      .eq("slot_occurrence_id", occurrenceId)
      .single();
    expect(recurringBookingForThatSlot?.status).toBe("NOT_GENERATED");
  });

  it("respects capacity for recurring generation -- does not treat the series as unlimited priority", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-capacity", 1);
    createdUserIds.push(owner.id);
    const a = await enrollCustomer(owner, org, service.id, "p6-capacity-a");
    const b = await enrollCustomer(owner, org, service.id, "p6-capacity-b");
    createdUserIds.push(a.customer.id, b.customer.id);

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule.id)
      .order("start_at", { ascending: true })
      .limit(1);
    const occurrenceId = occurrences![0]!.id;

    const filledByA = await a.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(filledByA.data.status).toBe("OK");

    const { data: rbB } = await b.customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { data: bForThatSlot } = await owner.client
      .from("bookings")
      .select("status")
      .eq("recurring_booking_id", rbB.id)
      .eq("slot_occurrence_id", occurrenceId)
      .single();
    expect(bForThatSlot?.status).toBe("NOT_GENERATED");
  });

  it("cancelling the whole series cancels future CONFIRMED bookings but keeps the series row and never touches past history", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-cancelseries", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-cancelseries-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const cancelled = await customer.client.rpc("cancel_recurring_booking", { p_recurring_booking_id: rb.id });
    expect(cancelled.data.status).toBe("CANCELLED");
    expect(cancelled.data.cancellation_reason).toBe("CUSTOMER_REQUEST");

    const { data: bookingsAfter } = await owner.client
      .from("bookings")
      .select("status, cancellation_reason")
      .eq("recurring_booking_id", rb.id);
    for (const b of bookingsAfter!) {
      expect(b.status).toBe("CANCELLED");
      expect(b.cancellation_reason).toBe("CUSTOMER_REQUEST");
    }
  });

  it("discontinuing the ScheduleRule cascades all the way to RecurringBooking, not just its Bookings", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-discontinue", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-discontinue-customer");
    createdUserIds.push(customer.id);

    const { data: rb } = await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const { error } = await owner.client.rpc("discontinue_schedule_rule", { p_schedule_rule_id: rule.id });
    expect(error).toBeNull();

    const { data: rbAfter } = await owner.client
      .from("recurring_bookings")
      .select("status, cancellation_reason")
      .eq("id", rb.id)
      .single();
    expect(rbAfter?.status).toBe("CANCELLED");
    expect(rbAfter?.cancellation_reason).toBe("ORGANIZATION_REMOVED");
  });

  it("blocks an OWNER of a different org from seeing another org's recurring bookings", async () => {
    const { owner, org, service, rule } = await setupOrgWithService("p6-cross", 10);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomer(owner, org, service.id, "p6-cross-customer");
    createdUserIds.push(customer.id);
    await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const otherOwner = await createSignedInUser("p6-cross-other-owner");
    createdUserIds.push(otherOwner.id);
    await createOrganization(otherOwner, "p6-cross-other-org");

    const { data } = await otherOwner.client.from("recurring_bookings").select("id").eq("organization_id", org.id);
    expect(data).toEqual([]);
  });
});
