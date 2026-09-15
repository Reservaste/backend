// Integration tests for Phase 9 (customer portal): a customer can see
// their own bookings/entitlements/payments with enough context to be
// legible, and nothing belonging to anyone else -- including other
// customers of the same organization, which is the case ADR-0006 exists
// for. Requires a running local Supabase (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, ANON_KEY, createOrganization, createSignedInUser, SUPABASE_URL, type SignedInUser } from "./helpers";

describe("Phase 9: customer portal", () => {
  const createdUserIds: string[] = [];
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let service: { id: string; name: string };
  let occurrenceId: string;
  let customerA: SignedInUser;
  let customerB: SignedInUser;
  let entitlementA: { id: string };

  beforeAll(async () => {
    owner = await createSignedInUser("p9-owner");
    createdUserIds.push(owner.id);
    org = await createOrganization(owner, "p9-org");

    const { data: svc } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "CrossFit", created_by: owner.id })
      .select()
      .single();
    service = svc!;

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
        service_id: service.id,
        resource_id: resource!.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: owner.id,
      })
      .select()
      .single();

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule!.id)
      .order("start_at", { ascending: true })
      .limit(1);
    occurrenceId = occurrences![0]!.id;

    // Customer A: enrolled, entitled, paid, booked.
    customerA = await createSignedInUser("p9-customer-a");
    createdUserIds.push(customerA.id);
    const { data: customerARow } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customerA.id, created_by: owner.id })
      .select()
      .single();

    const { data: ent } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerARow!.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: true,
        created_by: owner.id,
      })
      .select()
      .single();
    entitlementA = ent!;

    await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: customerARow!.id,
      service_entitlement_id: entitlementA.id,
      period_start: "2020-01-01",
      period_end: "2030-12-31",
      status: "PAID",
      amount: 1500,
      created_by: owner.id,
    });

    await customerA.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });

    // Customer B: same organization, own entitlement and booking.
    customerB = await createSignedInUser("p9-customer-b");
    createdUserIds.push(customerB.id);
    const { data: customerBRow } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customerB.id, created_by: owner.id })
      .select()
      .single();

    await owner.client.from("service_entitlements").insert({
      organization_id: org.id,
      customer_id: customerBRow!.id,
      service_id: service.id,
      entitlement_type: "CREDITS",
      credits_total: 5,
      credits_remaining: 5,
      created_by: owner.id,
    });

    await customerB.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("my_bookings returns the customer's own booking with the context needed to read it", async () => {
    const { data, error } = await customerA.client.rpc("my_bookings");
    expect(error).toBeNull();
    expect(data).toHaveLength(1);

    const booking = data[0];
    expect(booking.organization_slug).toBe(org.slug);
    expect(booking.service_name).toBe("CrossFit");
    expect(booking.organization_timezone).toBe("America/Montevideo");
    expect(booking.status).toBe("CONFIRMED");
    expect(booking.is_recurring).toBe(false);
  });

  it("my_bookings never returns another customer's booking on the same slot", async () => {
    const a = await customerA.client.rpc("my_bookings");
    const b = await customerB.client.rpc("my_bookings");

    expect(a.data).toHaveLength(1);
    expect(b.data).toHaveLength(1);
    expect(a.data[0].booking_id).not.toBe(b.data[0].booking_id);
  });

  it("my_entitlements reports whether a payment covers today, not just that the entitlement is active", async () => {
    const { data, error } = await customerA.client.rpc("my_entitlements");
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data[0].service_name).toBe("CrossFit");
    expect(data[0].requires_active_payment).toBe(true);
    expect(data[0].paid_today).toBe(true);

    // Voiding the only covering payment flips paid_today without touching
    // the entitlement itself -- the distinction the portal has to show.
    const { data: payments } = await owner.client.from("payments").select("id").eq("service_entitlement_id", entitlementA.id);
    await owner.client.from("payments").update({ status: "VOID" }).eq("id", payments![0]!.id);

    const after = await customerA.client.rpc("my_entitlements");
    expect(after.data[0].is_active).toBe(true);
    expect(after.data[0].paid_today).toBe(false);
  });

  it("my_payments shows the customer's own payments and nobody else's", async () => {
    const mine = await customerA.client.rpc("my_payments");
    expect(mine.data).toHaveLength(1);
    expect(mine.data[0].service_name).toBe("CrossFit");

    const theirs = await customerB.client.rpc("my_payments");
    expect(theirs.data).toEqual([]);
  });

  it("public_slot_detail works anonymously and respects the disclosure mode", async () => {
    const anon = createClient(SUPABASE_URL, ANON_KEY);

    const { data, error } = await anon.rpc("public_slot_detail", { p_slot_occurrence_id: occurrenceId });
    expect(error).toBeNull();
    expect(data).toHaveLength(1);

    const slot = data[0];
    expect(slot.organization_slug).toBe(org.slug);
    expect(slot.service_name).toBe("CrossFit");
    // Organization default is EXACT, and two seats are taken.
    expect(slot.mode).toBe("EXACT");
    expect(slot.capacity).toBe(10);
    expect(slot.remaining).toBe(8);
  });

  it("public_slot_detail hides the count when the service overrides to BOOLEAN", async () => {
    await owner.client
      .from("services")
      .update({ public_availability_display_override: "BOOLEAN" })
      .eq("id", service.id);

    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { data } = await anon.rpc("public_slot_detail", { p_slot_occurrence_id: occurrenceId });

    expect(data[0].mode).toBe("BOOLEAN");
    expect(data[0].remaining).toBeNull();
    expect(data[0].capacity).toBeNull();
    expect(data[0].status).toBe("AVAILABLE");

    await owner.client
      .from("services")
      .update({ public_availability_display_override: null })
      .eq("id", service.id);
  });

  it("a signed-in person who is nobody's customer gets empty portal data, not an error", async () => {
    const stranger = await createSignedInUser("p9-stranger");
    createdUserIds.push(stranger.id);

    const bookings = await stranger.client.rpc("my_bookings");
    const entitlements = await stranger.client.rpc("my_entitlements");
    const payments = await stranger.client.rpc("my_payments");

    expect(bookings.error).toBeNull();
    expect(bookings.data).toEqual([]);
    expect(entitlements.data).toEqual([]);
    expect(payments.data).toEqual([]);
  });

  it("cancelling from the portal frees the seat and shows up as cancelled", async () => {
    const { data: before } = await customerB.client.rpc("my_bookings");
    const bookingId = before[0].booking_id;

    await customerB.client.rpc("cancel_booking", { p_booking_id: bookingId });

    const { data: after } = await customerB.client.rpc("my_bookings");
    expect(after[0].status).toBe("CANCELLED");
    expect(after[0].cancellation_reason).toBe("CUSTOMER_REQUEST");

    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { data: slot } = await anon.rpc("public_slot_detail", { p_slot_occurrence_id: occurrenceId });
    expect(slot[0].remaining).toBe(9);
  });
});
