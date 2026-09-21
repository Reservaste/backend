// Integration tests for Phase 5 (Booking Engine): can_customer_book()'s
// reason codes, capacity enforcement, the ADR-0004 concurrency guarantee
// (the actual reason this whole RPC exists), cancellation freeing
// capacity, and the cross-tenant/cascade rules. Requires a running local
// Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  makeServicePaid,
  type SignedInUser,
} from "./helpers";

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

  const occurrenceId = (await firstFutureOccurrence(owner, rule!.id)).id;

  return { owner, org, service: service!, occurrenceId };
}

// ADR-0022: being an active Customer of the organization is the whole
// requirement now. There is no second, per-service permission to grant.
async function enrollCustomerWithEntitlement(owner: SignedInUser, org: { id: string }, serviceId: string, prefix: string) {
  void serviceId;
  const customer = await createSignedInUser(prefix);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();

  return { customer, customerRow: customerRow! };
}

describe("Phase 5: booking engine", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("rejects booking a paid service when no payment covers the slot's date", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-unpaid", 10);
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);

    const customer = await createSignedInUser("p5-unpaid-customer");
    createdUserIds.push(customer.id);
    await owner.client.from("customers").insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id });

    // Being a customer is no longer the question (ADR-0022); the month is.
    const { data } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(data.status).toBe("PAYMENT_REQUIRED");
  });

  it("lets any active customer book a service that does not require payment", async () => {
    const { owner, org, occurrenceId } = await setupOrgWithService("p5-free", 10);
    createdUserIds.push(owner.id);

    // The point of removing manual enablement: nobody had to switch
    // anything on for this person.
    const customer = await createSignedInUser("p5-free-customer");
    createdUserIds.push(customer.id);
    await owner.client.from("customers").insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id });

    const { data } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(data.status).toBe("OK");
  });

  it("refuses to book a class that already ended", async () => {
    const { owner, org } = await setupOrgWithService("p5-past", 10);
    createdUserIds.push(owner.id);

    const customer = await createSignedInUser("p5-past-customer");
    createdUserIds.push(customer.id);
    const { data: customerRow } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
      .select()
      .single();
    void customerRow;

    const { data: services } = await owner.client.from("services").select("id").eq("organization_id", org.id).limit(1);
    const { data: resources } = await owner.client.from("resources").select("id").eq("organization_id", org.id).limit(1);
    const past = new Date();
    past.setDate(past.getDate() - 7);
    const { data: rules } = await owner.client.from("schedule_rules").select("id").eq("organization_id", org.id).limit(1);

    const { data: pastOccurrence } = await admin
      .from("slot_occurrences")
      .insert({
        organization_id: org.id,
        service_id: services![0]!.id,
        resource_id: resources![0]!.id,
        schedule_rule_id: rules![0]!.id,
        start_at: past.toISOString(),
        end_at: new Date(past.getTime() + 3600_000).toISOString(),
        generated_timezone: "America/Montevideo",
        capacity: 10,
      })
      .select()
      .single();

    // Booking a class that already happened is not a reservation, it is
    // backdated attendance.
    const { data } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: pastOccurrence!.id });
    expect(data.status).toBe("OCCURRENCE_NOT_AVAILABLE");
    void isoDate;
  });

  it("books successfully with a valid entitlement, then rejects a duplicate booking of the same slot", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-happy", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-happy-customer");
    createdUserIds.push(customer.id);

    const first = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(first.data.status).toBe("OK");
    expect(first.data.booking.customer_id).toBe(customerRow.id);
    expect(first.data.booking.status).toBe("CONFIRMED");

    const second = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(second.data.status).toBe("ALREADY_BOOKED");
  });

  it("rejects booking once the occurrence is at capacity", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-full", 1);
    createdUserIds.push(owner.id);

    const a = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-full-a");
    const b = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-full-b");
    createdUserIds.push(a.customer.id, b.customer.id);

    const first = await a.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(first.data.status).toBe("OK");

    const second = await b.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(second.data.status).toBe("SLOT_FULL");
  });

  it(
    "ADR-0004: under real concurrency, capacity 1 with two simultaneous bookers, exactly one wins",
    async () => {
      const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-race", 1);
      createdUserIds.push(owner.id);

      const a = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-race-a");
      const b = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-race-b");
      createdUserIds.push(a.customer.id, b.customer.id);

      // Genuinely concurrent: both RPC calls fired without awaiting
      // between them. If book_slot()'s FOR UPDATE lock (ADR-0004) didn't
      // actually serialize these, this test would be flaky -- both could
      // read capacity=1/active=0 before either commits and both succeed.
      const [resA, resB] = await Promise.all([
        a.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId }),
        b.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId }),
      ]);

      const statuses = [resA.data.status, resB.data.status].sort();
      expect(statuses).toEqual(["OK", "SLOT_FULL"]);

      const { count } = await owner.client
        .from("bookings")
        .select("id", { count: "exact", head: true })
        .eq("slot_occurrence_id", occurrenceId)
        .eq("status", "CONFIRMED");
      expect(count).toBe(1);
    },
    20_000,
  );

  it("cancelling a booking frees the seat for a new booker", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-cancel", 1);
    createdUserIds.push(owner.id);

    const a = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-cancel-a");
    const b = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-cancel-b");
    createdUserIds.push(a.customer.id, b.customer.id);

    const booked = await a.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");

    const blockedForB = await b.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(blockedForB.data.status).toBe("SLOT_FULL");

    const cancelled = await a.customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });
    expect(cancelled.data.status).toBe("CANCELLED");
    expect(cancelled.data.cancellation_reason).toBe("CUSTOMER_REQUEST");

    const nowForB = await b.customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(nowForB.data.status).toBe("OK");
  });

  it("cancelling a SlotOccurrence cascades to cancel its CONFIRMED bookings", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-cascade", 5);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-cascade-customer");
    createdUserIds.push(customer.id);

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");

    const { error } = await owner.client.rpc("cancel_slot_occurrence", { p_slot_occurrence_id: occurrenceId });
    expect(error).toBeNull();

    const { data: bookingAfter } = await owner.client
      .from("bookings")
      .select("status, cancellation_reason")
      .eq("id", booked.data.booking.id)
      .single();
    expect(bookingAfter?.status).toBe("CANCELLED");
    expect(bookingAfter?.cancellation_reason).toBe("SLOT_CANCELLED");
  });

  it("get_public_availability reflects real confirmed bookings, not a hardcoded count", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-public", 3);
    createdUserIds.push(owner.id);
    const { customer } = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-public-customer");
    createdUserIds.push(customer.id);

    const before = await owner.client.rpc("get_public_availability", {
      p_organization_slug: org.slug,
      p_service_id: service.id,
    });
    expect(before.data.find((s: { slot_occurrence_id: string }) => s.slot_occurrence_id === occurrenceId)?.remaining).toBe(3);

    await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });

    const after = await owner.client.rpc("get_public_availability", {
      p_organization_slug: org.slug,
      p_service_id: service.id,
    });
    expect(after.data.find((s: { slot_occurrence_id: string }) => s.slot_occurrence_id === occurrenceId)?.remaining).toBe(2);
  });

  it("blocks direct client writes to bookings -- must go through book_slot/cancel_booking", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-directwrite", 10);
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-directwrite-customer");
    createdUserIds.push(customer.id);

    const { error } = await customer.client.from("bookings").insert({
      organization_id: org.id,
      customer_id: customerRow.id,
      slot_occurrence_id: occurrenceId,
      status: "CONFIRMED",
    });
    expect(error).not.toBeNull();
  });

  it("blocks a customer of a different org from booking, and lets STAFF see all bookings in their org while the customer sees only their own", async () => {
    const { owner, org, service, occurrenceId } = await setupOrgWithService("p5-cross", 10);
    createdUserIds.push(owner.id);
    const otherOwner = await createSignedInUser("p5-cross-other-owner");
    createdUserIds.push(otherOwner.id);
    await createOrganization(otherOwner, "p5-cross-other-org");

    const { data: crossOrgBook } = await otherOwner.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(crossOrgBook.status).toBe("NOT_A_CUSTOMER");

    const { customer } = await enrollCustomerWithEntitlement(owner, org, service.id, "p5-cross-customer");
    createdUserIds.push(customer.id);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");

    const staffView = await owner.client.from("bookings").select("id").eq("organization_id", org.id);
    expect(staffView.data).toHaveLength(1);

    const otherOwnerView = await otherOwner.client.from("bookings").select("id").eq("organization_id", org.id);
    expect(otherOwnerView.data).toEqual([]);
  });
});
