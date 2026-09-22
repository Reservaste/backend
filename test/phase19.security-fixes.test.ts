// Integration tests for Phase 19 (security fixes). Four pre-existing
// holes, all of them about *who may call what*:
//
//  1. EXECUTE was never revoked from PUBLIC, so every RPC in the repo was
//     reachable by an anonymous PostgREST request.
//  2. cancel_booking() skipped authorization entirely when
//     customers.profile_id was NULL (three-valued logic). Not reachable
//     today because the column is NOT NULL -- proven here by temporarily
//     dropping the constraint from the test itself.
//  3. cancel_booking() let the caller choose the reason for their own
//     cancellation (ADR-0025 res. 1).
//  4. retry_not_generated_booking() had no authorization check at all.
//
// Requires a running local Supabase (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  SUPABASE_URL,
  type SignedInUser,
} from "./helpers";

async function setupOrgWithService(prefix: string, capacity = 10) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
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
  return { owner, org, service: service!, rule: rule!, occurrenceId };
}

async function enroll(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: customerRow! };
}

describe("Phase 19: security fixes", () => {
  const createdUserIds: string[] = [];
  const anon = createClient(SUPABASE_URL, ANON_KEY);

  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let occurrenceId: string;
  let customer: SignedInUser;
  let customerRowId: string;
  let bookingId: string;

  beforeAll(async () => {
    const setup = await setupOrgWithService("p19");
    owner = setup.owner;
    org = setup.org;
    occurrenceId = setup.occurrenceId;
    createdUserIds.push(owner.id);

    const enrolled = await enroll(owner, org, "p19-customer");
    customer = enrolled.customer;
    customerRowId = enrolled.customerRow.id as string;
    createdUserIds.push(customer.id);

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");
    bookingId = booked.data.booking.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ============================================================
  // 1. The anon surface
  // ============================================================

  it("does not let an anonymous client reach the booking engine or the admin RPCs", async () => {
    // Every one of these used to be callable without a session: the
    // `grant execute ... to authenticated` lines added a grant on top of
    // the PUBLIC default instead of replacing it.
    const forbidden: Array<[string, Record<string, unknown>]> = [
      ["book_slot", { p_slot_occurrence_id: occurrenceId }],
      ["cancel_booking", { p_booking_id: bookingId }],
      ["retry_not_generated_booking", { p_booking_id: bookingId }],
      ["agenda_occurrences", { p_organization_id: org.id }],
      ["organization_customers", { p_organization_id: org.id }],
      ["platform_organizations", {}],
      ["my_bookings", {}],
    ];

    for (const [fn, args] of forbidden) {
      const { error } = await anon.rpc(fn, args);
      expect(error, `anon should not be able to call ${fn}`).not.toBeNull();
    }
  });

  it("keeps the public calendar open to anonymous visitors", async () => {
    // ADR-0007: services, dates, times and availability need no login.
    const availability = await anon.rpc("get_public_availability", { p_organization_slug: org.slug });
    expect(availability.error).toBeNull();

    const detail = await anon.rpc("public_slot_detail", { p_slot_occurrence_id: occurrenceId });
    expect(detail.error).toBeNull();
    expect(detail.data).toHaveLength(1);
  });

  it("does not expose the internal decision helpers as RPCs", async () => {
    // These take a customer_id of any organization and answer whether
    // that person has paid and what plan they hold, with no
    // authorization of their own. They are building blocks for the
    // granted RPCs, not an API.
    const internal: Array<[string, Record<string, unknown>]> = [
      ["evaluate_payment_coverage", { p_customer_id: customerRowId, p_service_id: null, p_slot_occurrence_id: occurrenceId }],
      ["evaluate_customer_booking", { p_slot_occurrence_id: occurrenceId, p_customer_id: customerRowId }],
      ["customer_series_in_force_count", { p_customer_id: customerRowId, p_service_id: null, p_local_date: "2026-01-01" }],
      ["generate_recurring_booking", { p_recurring_booking_id: bookingId, p_slot_occurrence_id: occurrenceId }],
      ["generate_all_slot_occurrences", {}],
      ["reconcile_pending_recurring_bookings", { p_customer_id: customerRowId, p_service_id: null }],
    ];

    for (const [fn, args] of internal) {
      const asAnon = await anon.rpc(fn, args);
      expect(asAnon.error, `anon should not be able to call ${fn}`).not.toBeNull();
      const asUser = await customer.client.rpc(fn, args);
      expect(asUser.error, `authenticated should not be able to call ${fn}`).not.toBeNull();
    }
  });

  // ============================================================
  // 2 + 3. cancel_booking()
  // ============================================================

  it("no longer accepts a caller-supplied cancellation reason", async () => {
    // ADR-0025 res. 1: the two-argument overload is gone, so a customer
    // can no longer cancel ten minutes before the class claiming
    // SLOT_CANCELLED. PostgREST cannot resolve the old signature at all.
    const { error } = await customer.client.rpc("cancel_booking", {
      p_booking_id: bookingId,
      p_reason: "SLOT_CANCELLED",
    });
    expect(error).not.toBeNull();

    const { data: still } = await owner.client.from("bookings").select("status").eq("id", bookingId).single();
    expect(still!.status).toBe("CONFIRMED");
  });

  it("derives the reason from the actor, for the customer and for staff", async () => {
    const mine = await customer.client.rpc("cancel_booking", { p_booking_id: bookingId });
    expect(mine.error).toBeNull();
    expect(mine.data.status).toBe("CANCELLED");
    expect(mine.data.cancellation_reason).toBe("CUSTOMER_REQUEST");
    expect(mine.data.cancelled_by).toBe(customer.id);

    // Staff cancelling from the counter: still CUSTOMER_REQUEST (that is
    // what it is -- the customer asked), and cancelled_by records which
    // profile actually did it.
    const second = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(second.data.status).toBe("OK");
    const asStaff = await owner.client.rpc("cancel_booking", { p_booking_id: second.data.booking.id });
    expect(asStaff.error).toBeNull();
    expect(asStaff.data.cancellation_reason).toBe("CUSTOMER_REQUEST");
    expect(asStaff.data.cancelled_by).toBe(owner.id);
  });

  it("refuses a stranger's cancellation", async () => {
    const stranger = await createSignedInUser("p19-stranger");
    createdUserIds.push(stranger.id);

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");

    const { error } = await stranger.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });
    expect(error?.message).toContain("NOT_AUTHORIZED");

    await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });
  });

  // ============================================================
  // 4. retry_not_generated_booking()
  // ============================================================

  it("refuses retry_not_generated_booking() from someone unrelated to the booking", async () => {
    const stranger = await createSignedInUser("p19-retry-stranger");
    createdUserIds.push(stranger.id);

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
    expect(booked.data.status).toBe("OK");

    // Before Phase 19 this returned the booking row happily: SECURITY
    // DEFINER, a write, and not one line of authorization.
    const { error } = await stranger.client.rpc("retry_not_generated_booking", {
      p_booking_id: booked.data.booking.id,
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");

    // The booking's own customer and the organization still get through.
    const asCustomer = await customer.client.rpc("retry_not_generated_booking", {
      p_booking_id: booked.data.booking.id,
    });
    expect(asCustomer.error).toBeNull();
    const asOwner = await owner.client.rpc("retry_not_generated_booking", {
      p_booking_id: booked.data.booking.id,
    });
    expect(asOwner.error).toBeNull();

    await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });
  });

  // ============================================================
  // Cross-tenant writes through generate_slot_occurrences_for_rule()
  // ============================================================

  it("refuses to materialize another organization's rule", async () => {
    const other = await setupOrgWithService("p19-other");
    createdUserIds.push(other.owner.id);

    const { error } = await customer.client.rpc("generate_slot_occurrences_for_rule", {
      p_schedule_rule_id: other.rule.id,
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");
  });
});
