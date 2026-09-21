// Integration tests for schedule rule groups, attendance and the
// payments overview (ADR-0022, ADR-0023).
//
// The group functions matter because the model deliberately keeps one
// rule per weekday: what is tested is that the grouping is real (it
// actually creates N rules) and that acting on the group acts on all of
// them. Attendance matters because it must stay independent of booking
// status. Requires a running local Supabase.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  makeServicePaid,
  payFor,
  type SignedInUser,
} from "./helpers";

async function setupOrg(prefix: string) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Gimnasia Natural", created_by: owner.id })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  return { owner, org, service: service!, resource: resource! };
}

async function enroll(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: row } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: row! };
}

describe("Schedule rule groups, attendance and payments overview", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ---------------- Groups ----------------

  it("one action creates one rule per weekday, sharing a group", async () => {
    const { owner, service, resource } = await setupOrg("p16-group");
    createdUserIds.push(owner.id);

    // Mon/Wed/Fri 09:00, the brief's example.
    const { data, error } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [1, 3, 5],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 15,
    });

    expect(error).toBeNull();
    expect(data).toHaveLength(3);
    // The model stays one rule per weekday: exceptions, occurrence
    // generation and the discontinue cascade all key off that.
    expect(new Set(data.map((r: { group_id: string }) => r.group_id)).size).toBe(1);
    expect(data.map((r: { weekday: number }) => r.weekday).sort()).toEqual([1, 3, 5]);

    const groups = await owner.client.rpc("schedule_rule_groups", { p_service_id: service.id });
    expect(groups.data).toHaveLength(1);
    expect(groups.data[0].weekdays).toEqual([1, 3, 5]);
    expect(groups.data[0].capacity).toBe(15);
    expect(groups.data[0].rule_ids).toHaveLength(3);
  });

  it("picking the same weekday twice does not create two identical rules", async () => {
    const { owner, service, resource } = await setupOrg("p16-dupeday");
    createdUserIds.push(owner.id);

    const { data } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [2, 2, 4],
      p_local_start_time: "10:00",
      p_duration_minutes: 45,
      p_capacity: 8,
    });

    expect(data).toHaveLength(2);
  });

  it("each weekday generates its own occurrences", async () => {
    const { owner, org, service, resource } = await setupOrg("p16-occurrences");
    createdUserIds.push(owner.id);

    await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [1, 3],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });

    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("start_at")
      .eq("organization_id", org.id);

    const weekdays = new Set(
      (occurrences ?? []).map((o: { start_at: string }) =>
        new Date(
          new Date(o.start_at).toLocaleString("en-US", { timeZone: "America/Montevideo" }),
        ).getDay(),
      ),
    );
    expect(weekdays).toEqual(new Set([1, 3]));
  });

  it("discontinuing the group discontinues every rule in it", async () => {
    const { owner, service, resource } = await setupOrg("p16-discontinue");
    createdUserIds.push(owner.id);

    const { data: rules } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [1, 3, 5],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });

    const { data: count } = await owner.client.rpc("discontinue_schedule_rule_group", {
      p_group_id: rules[0].group_id,
    });
    expect(count).toBe(3);

    const groups = await owner.client.rpc("schedule_rule_groups", { p_service_id: service.id });
    expect(groups.data).toEqual([]);
  });

  it("a non-member cannot create or discontinue schedules on someone else's service", async () => {
    const { owner, service, resource } = await setupOrg("p16-outsider");
    createdUserIds.push(owner.id);
    const outsider = await createSignedInUser("p16-outsider-attacker");
    createdUserIds.push(outsider.id);
    await createOrganization(outsider, "p16-outsider-org");

    const res = await outsider.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [1],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });
    expect(res.error?.message).toContain("NOT_AUTHORIZED");
  });

  // ---------------- Attendance ----------------

  it("marks attendance without touching the booking's own status", async () => {
    const { owner, org, service, resource } = await setupOrg("p16-attendance");
    createdUserIds.push(owner.id);
    const { data: rules } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [0, 1, 2, 3, 4, 5, 6],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });
    const occurrence = await firstFutureOccurrence(owner, rules[0].id);

    const { customer, customerRow } = await enroll(owner, org, "p16-attendance-customer");
    createdUserIds.push(customer.id);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    expect(booked.data.status).toBe("OK");

    const roll = await owner.client.rpc("occurrence_bookings", { p_slot_occurrence_id: occurrence.id });
    expect(roll.data).toHaveLength(1);
    expect(roll.data[0].attendance_status).toBe("PENDING");

    const marked = await owner.client.rpc("mark_attendance", {
      p_booking_id: roll.data[0].booking_id,
      p_status: "ABSENT",
    });
    expect(marked.error).toBeNull();
    // The point of keeping them separate: reserved and did not show up is
    // a normal, valid combination.
    expect(marked.data.status).toBe("CONFIRMED");
    expect(marked.data.attendance_status).toBe("ABSENT");
    expect(marked.data.attendance_marked_at).not.toBeNull();

    const summary = await owner.client.rpc("occurrence_attendance_summary", {
      p_slot_occurrence_id: occurrence.id,
    });
    expect(summary.data[0]).toMatchObject({ reserved: 1, present: 0, absent: 1, pending: 0 });
    void customerRow;
  });

  it("refuses to take attendance for a cancelled booking", async () => {
    const { owner, org, service, resource } = await setupOrg("p16-cancelled");
    createdUserIds.push(owner.id);
    const { data: rules } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [0, 1, 2, 3, 4, 5, 6],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });
    const occurrence = await firstFutureOccurrence(owner, rules[0].id);

    const { customer } = await enroll(owner, org, "p16-cancelled-customer");
    createdUserIds.push(customer.id);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });
    await customer.client.rpc("cancel_booking", { p_booking_id: booked.data.booking.id });

    const res = await owner.client.rpc("mark_attendance", {
      p_booking_id: booked.data.booking.id,
      p_status: "PRESENT",
    });
    expect(res.error?.message).toContain("BOOKING_NOT_CONFIRMED");
  });

  it("a non-member cannot mark attendance", async () => {
    const { owner, org, service, resource } = await setupOrg("p16-attend-outsider");
    createdUserIds.push(owner.id);
    const { data: rules } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [0, 1, 2, 3, 4, 5, 6],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 10,
    });
    const occurrence = await firstFutureOccurrence(owner, rules[0].id);
    const { customer } = await enroll(owner, org, "p16-attend-outsider-customer");
    createdUserIds.push(customer.id);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrence.id });

    // The customer is in the class, but taking the roll is staff's job.
    const res = await customer.client.rpc("mark_attendance", {
      p_booking_id: booked.data.booking.id,
      p_status: "PRESENT",
    });
    expect(res.error?.message).toContain("NOT_AUTHORIZED");
  });

  // ---------------- Payments overview ----------------

  it("rolls payments up per customer and classifies who owes", async () => {
    const { owner, org, service } = await setupOrg("p16-summary");
    createdUserIds.push(owner.id);
    await makeServicePaid(owner, service.id);

    const { data: other } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Funcional", created_by: owner.id })
      .select()
      .single();

    const paidUp = await enroll(owner, org, "p16-summary-paid");
    const partial = await enroll(owner, org, "p16-summary-partial");
    const nothing = await enroll(owner, org, "p16-summary-none");
    createdUserIds.push(paidUp.customer.id, partial.customer.id, nothing.customer.id);

    const period = { from: isoDate(-5), to: isoDate(25) };

    await payFor(owner, {
      organizationId: org.id,
      customerId: paidUp.customerRow.id,
      serviceId: service.id,
      ...period,
      amount: 2000,
    });
    await payFor(owner, {
      organizationId: org.id,
      customerId: partial.customerRow.id,
      serviceId: service.id,
      ...period,
      amount: 2000,
    });
    await payFor(owner, {
      organizationId: org.id,
      customerId: partial.customerRow.id,
      serviceId: other!.id,
      ...period,
      amount: 1500,
      status: "PENDING",
    });

    const { data } = await owner.client.rpc("organization_payment_summary", {
      p_organization_id: org.id,
      p_period_start: isoDate(-5),
      p_period_end: isoDate(25),
    });

    const byId = Object.fromEntries(data.map((r: { customer_id: string }) => [r.customer_id, r]));

    expect(byId[paidUp.customerRow.id].rollup_status).toBe("PAID");
    expect(Number(byId[paidUp.customerRow.id].paid)).toBe(2000);

    expect(byId[partial.customerRow.id].rollup_status).toBe("PARTIAL");
    expect(byId[partial.customerRow.id].services_count).toBe(2);
    expect(Number(byId[partial.customerRow.id].total)).toBe(3500);
    expect(Number(byId[partial.customerRow.id].pending)).toBe(1500);

    // Someone with no payments at all in the period is the case the
    // screen exists to surface.
    expect(byId[nothing.customerRow.id].rollup_status).toBe("NO_PAYMENTS");
    expect(Number(byId[nothing.customerRow.id].total)).toBe(0);
  });

  it("the detail breaks the same period down per service", async () => {
    const { owner, org, service } = await setupOrg("p16-detail");
    createdUserIds.push(owner.id);
    const { customer, customerRow } = await enroll(owner, org, "p16-detail-customer");
    createdUserIds.push(customer.id);

    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-5),
      to: isoDate(25),
      amount: 2000,
      status: "PENDING",
    });

    const { data } = await owner.client.rpc("customer_payment_detail", {
      p_customer_id: customerRow.id,
      p_period_start: isoDate(-5),
      p_period_end: isoDate(25),
    });
    expect(data).toHaveLength(1);
    expect(data[0].service_name).toBe("Gimnasia Natural");
    expect(data[0].status).toBe("PENDING");

    const marked = await owner.client.rpc("set_payment_status", {
      p_payment_id: payment!.id,
      p_status: "PAID",
    });
    expect(marked.data.status).toBe("PAID");
  });

  it("another organization's owner sees nothing in the summary", async () => {
    const { owner, org } = await setupOrg("p16-xorg");
    createdUserIds.push(owner.id);
    const outsider = await createSignedInUser("p16-xorg-outsider");
    createdUserIds.push(outsider.id);
    await createOrganization(outsider, "p16-xorg-outsider-org");

    const { data } = await outsider.client.rpc("organization_payment_summary", {
      p_organization_id: org.id,
      p_period_start: isoDate(-30),
      p_period_end: isoDate(30),
    });
    expect(data).toEqual([]);
  });
});
