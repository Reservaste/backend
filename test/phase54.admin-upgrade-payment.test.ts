// Integration tests for Phase 54 (ADR-0050, Issue #4): admin_upgrade_payment()
// shortens a PAID period payment and inserts the upgraded one in a single
// transaction, without relaxing payment_service_coverage_no_overlap.
// Requires a running Supabase instance (see test/helpers.ts) with this
// phase's migration already applied.
//
// Periods are fixed calendar dates (November 2026: the 1st is a Sunday, 30
// days) so the proration arithmetic is deterministic; a payment's period is
// plain admin data entry and does not need to contain "today".

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  SUPABASE_URL,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  insertOccurrenceLaterToday,
  makeServicePaid,
  payFor,
  type SignedInUser,
} from "./helpers";
import { createClient } from "@supabase/supabase-js";
import { Client } from "pg";

const DIRECT_DB_URL = process.env.SUPABASE_DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

const createdUserIds: string[] = [];

const P_START = "2026-11-01";
const P_END = "2026-11-30";
const EFFECTIVE = "2026-11-16";

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

async function setupOrg(prefix: string) {
  const owner = await newUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
    .select()
    .single();
  await makeServicePaid(owner, service!.id);

  const planOnce = await createServicePlan(owner, {
    organizationId: org.id,
    serviceId: service!.id,
    name: "1x semana",
    planKind: "WEEKLY_QUOTA",
    weeklyQuota: 1,
    price: 1000,
  });
  const planTwice = await createServicePlan(owner, {
    organizationId: org.id,
    serviceId: service!.id,
    name: "2x semana",
    planKind: "WEEKLY_QUOTA",
    weeklyQuota: 2,
    price: 2000,
  });
  const planUnlimited = await createServicePlan(owner, {
    organizationId: org.id,
    serviceId: service!.id,
    name: "Libre",
    planKind: "UNLIMITED",
    price: 3000,
  });

  return { owner, org, service: service!, planOnce, planTwice, planUnlimited };
}

type Ctx = Awaited<ReturnType<typeof setupOrg>>;

async function newCustomer(ctx: Ctx) {
  const { data, error } = await ctx.owner.client.rpc("create_managed_customer", {
    p_organization_id: ctx.org.id,
    p_display_name: `Cliente ${Math.random().toString(36).slice(2, 8)}`,
    p_phone: null,
  });
  expect(error).toBeNull();
  return (data as { id: string }).id;
}

/** A customer with a PAID 1x/week payment for the whole of P_START..P_END. */
async function customerWithPayment(ctx: Ctx, planId = ctx.planOnce, amount = 1000) {
  const customerId = await newCustomer(ctx);
  const { data, error } = await payFor(ctx.owner, {
    organizationId: ctx.org.id,
    customerId,
    serviceId: ctx.service.id,
    from: P_START,
    to: P_END,
    servicePlanId: planId,
    amount,
  });
  expect(error).toBeNull();
  return { customerId, paymentId: (data as { id: string }).id };
}

async function readPayment(id: string) {
  const { data } = await admin.from("payments").select("*").eq("id", id).single();
  return data as {
    id: string;
    status: string;
    amount: string | null;
    notes: string | null;
    period_start: string;
    period_end: string;
    service_plan_id: string;
    created_by: string | null;
    customer_id: string;
  };
}

async function upgrade(
  user: SignedInUser,
  args: {
    paymentId: string;
    planId: string;
    date?: string | null;
    amount?: number | null;
    notes?: string | null;
  },
) {
  return user.client.rpc("admin_upgrade_payment", {
    p_payment_id: args.paymentId,
    p_new_plan_id: args.planId,
    p_effective_date: args.date === undefined ? EFFECTIVE : args.date,
    p_amount: args.amount ?? null,
    p_notes: args.notes ?? null,
  });
}

/** The occurrence of a rule at 12:00Z of `date` (09:00 local): the generator may already have made it. */
async function occurrenceAt(ctx: Ctx, ruleId: string, resourceId: string, date: string): Promise<string> {
  const startAt = `${date}T12:00:00Z`;
  const { data: existing } = await admin
    .from("slot_occurrences")
    .select("id")
    .eq("schedule_rule_id", ruleId)
    .eq("start_at", startAt)
    .maybeSingle();
  if (existing) return existing.id as string;
  const { data, error } = await admin
    .from("slot_occurrences")
    .insert({
      organization_id: ctx.org.id,
      schedule_rule_id: ruleId,
      service_id: ctx.service.id,
      resource_id: resourceId,
      start_at: startAt,
      end_at: `${date}T13:00:00Z`,
      generated_timezone: "America/Montevideo",
      capacity: 10,
    })
    .select("id")
    .single();
  expect(error).toBeNull();
  return data!.id as string;
}

describe("Phase 54: admin_upgrade_payment (ADR-0050)", () => {
  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("happy path: shortens the old payment, inserts the prorated new one, keeps coverage in sync", async () => {
    const ctx = await setupOrg("p54-happy");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const { data: newId, error } = await upgrade(ctx.owner, {
      paymentId,
      planId: ctx.planTwice,
      notes: "upgrade a 2x",
    });
    expect(error).toBeNull();
    expect(typeof newId).toBe("string");

    const oldP = await readPayment(paymentId);
    expect(oldP.period_start).toBe(P_START);
    expect(oldP.period_end).toBe("2026-11-15");
    expect(oldP.status).toBe("PAID");
    expect(Number(oldP.amount)).toBe(1000); // already charged, untouched
    expect(oldP.service_plan_id).toBe(ctx.planOnce);

    const newP = await readPayment(newId as string);
    expect(newP.customer_id).toBe(customerId);
    expect(newP.status).toBe("PAID");
    expect(newP.service_plan_id).toBe(ctx.planTwice);
    expect(newP.period_start).toBe(EFFECTIVE);
    expect(newP.period_end).toBe(P_END);
    // No series yet: calendar-day proportion, 15 of 30 days of a 2000 plan.
    expect(Number(newP.amount)).toBe(1000);
    expect(newP.notes).toBe("upgrade a 2x");
    expect(newP.created_by).toBe(ctx.owner.id);

    // payment_service_coverage mirrors the partition, one live payment per date.
    const { data: coverage } = await admin
      .from("payment_service_coverage")
      .select("payment_id, period_start, period_end, status")
      .eq("customer_id", customerId)
      .eq("service_id", ctx.service.id)
      .order("period_start");
    expect(coverage).toEqual([
      { payment_id: paymentId, period_start: P_START, period_end: "2026-11-15", status: "PAID" },
      { payment_id: newId, period_start: EFFECTIVE, period_end: P_END, status: "PAID" },
    ]);
  });

  it("security: p_amount = 'NaN' is rejected (NaN < 0 is false and numeric(12,2) accepts it)", async () => {
    const ctx = await setupOrg("p54-nan");
    const { paymentId } = await customerWithPayment(ctx);
    // JSON.stringify(NaN) is null, so send the literal string PostgREST casts to numeric.
    const { error } = await ctx.owner.client.rpc("admin_upgrade_payment", {
      p_payment_id: paymentId,
      p_new_plan_id: ctx.planTwice,
      p_effective_date: EFFECTIVE,
      p_amount: "NaN",
      p_notes: null,
    });
    expect(error?.message).toContain("PAYMENT_UPGRADE_INVALID_AMOUNT");
    const oldP = await readPayment(paymentId);
    expect(oldP.period_end).toBe(P_END);
  });

  it("audit: the new payment's PAYMENT_CREATED records which payment was shortened and how", async () => {
    const ctx = await setupOrg("p54-audit");
    const { paymentId } = await customerWithPayment(ctx);
    const { data: newId, error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();

    const { data: rows } = await admin
      .from("audit_log")
      .select("action, actor_id, metadata")
      .eq("target_table", "payments")
      .eq("target_id", newId as string);
    expect(rows).toHaveLength(1);
    expect(rows![0].action).toBe("PAYMENT_CREATED");
    expect(rows![0].actor_id).toBe(ctx.owner.id);
    const note = (rows![0].metadata as { note?: string }).note ?? "";
    expect(note).toContain(paymentId);
    expect(note).toContain(`${P_END} -> 2026-11-15`);
  });

  it("the EXCLUDE is not relaxed: a manual overlapping PAID payment is still rejected afterwards", async () => {
    const ctx = await setupOrg("p54-exclude");
    const { customerId, paymentId } = await customerWithPayment(ctx);
    const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();

    const { error: overlapError } = await payFor(ctx.owner, {
      organizationId: ctx.org.id,
      customerId,
      serviceId: ctx.service.id,
      from: "2026-11-10",
      to: "2026-11-20",
      servicePlanId: ctx.planUnlimited,
    });
    expect(overlapError).not.toBeNull();
  });

  it("prorates by remaining sessions when the customer has as many series as the new plan's frequency", async () => {
    const ctx = await setupOrg("p54-sessions");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const { data: resource } = await ctx.owner.client
      .from("resources")
      .insert({ organization_id: ctx.org.id, name: "Sala", created_by: ctx.owner.id })
      .select()
      .single();

    // Monday and Wednesday series. November 2026: 5 Mondays (2,9,16,23,30)
    // + 4 Wednesdays (4,11,18,25) = 9 sessions; from the 16th on: 3 + 2 = 5.
    for (const weekday of [1, 3]) {
      const { data: rule, error: ruleError } = await ctx.owner.client
        .from("schedule_rules")
        .insert({
          organization_id: ctx.org.id,
          service_id: ctx.service.id,
          resource_id: resource!.id,
          weekday,
          local_start_time: "09:00",
          duration_minutes: 60,
          capacity: 10,
          created_by: ctx.owner.id,
        })
        .select()
        .single();
      expect(ruleError).toBeNull();
      const { error: rbError } = await admin.from("recurring_bookings").insert({
        organization_id: ctx.org.id,
        customer_id: customerId,
        schedule_rule_id: rule!.id,
        status: "ACTIVE",
        start_date: "2026-10-01",
        created_by: ctx.owner.id,
      });
      expect(rbError).toBeNull();
    }

    const { data: newId, error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();
    const newP = await readPayment(newId as string);
    expect(Number(newP.amount)).toBe(1111.11); // round(2000 * 5 / 9, 2)
  });

  it("an explicit p_amount overrides the proration; an UNLIMITED target plan is a valid upgrade", async () => {
    const ctx = await setupOrg("p54-amount");
    const { paymentId } = await customerWithPayment(ctx);

    const { data: newId, error } = await upgrade(ctx.owner, {
      paymentId,
      planId: ctx.planUnlimited,
      amount: 777.5,
    });
    expect(error).toBeNull();
    const newP = await readPayment(newId as string);
    expect(Number(newP.amount)).toBe(777.5);
    expect(newP.service_plan_id).toBe(ctx.planUnlimited);
  });

  it("chained upgrades work: the new payment can itself be upgraded later", async () => {
    const ctx = await setupOrg("p54-chain");
    const { paymentId } = await customerWithPayment(ctx);
    const { data: secondId } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    const { data: thirdId, error } = await upgrade(ctx.owner, {
      paymentId: secondId as string,
      planId: ctx.planUnlimited,
      date: "2026-11-23",
    });
    expect(error).toBeNull();
    expect((await readPayment(secondId as string)).period_end).toBe("2026-11-22");
    expect((await readPayment(thirdId as string)).period_start).toBe("2026-11-23");
  });

  it("is atomic: when the insert fails, the old payment is left exactly as it was", async () => {
    const ctx = await setupOrg("p54-atomic");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    // numeric(12,2) overflow: fails at the INSERT, after the old payment was
    // already shortened inside the function.
    const { error } = await upgrade(ctx.owner, {
      paymentId,
      planId: ctx.planTwice,
      amount: 1e13,
    });
    expect(error).not.toBeNull();

    const oldP = await readPayment(paymentId);
    expect(oldP.period_end).toBe(P_END);
    const { data: coverage } = await admin
      .from("payment_service_coverage")
      .select("payment_id, period_end")
      .eq("customer_id", customerId);
    expect(coverage).toEqual([{ payment_id: paymentId, period_end: P_END }]);
    const { count } = await admin
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerId);
    expect(count).toBe(1);
  });

  it("an already-charged renewal of the next period is left untouched by the upgrade", async () => {
    const ctx = await setupOrg("p54-renewal");
    const { customerId, paymentId } = await customerWithPayment(ctx);
    // Renewal already charged for December: does not overlap, so the upgrade
    // of November still works and leaves December alone.
    await payFor(ctx.owner, {
      organizationId: ctx.org.id,
      customerId,
      serviceId: ctx.service.id,
      from: "2026-12-01",
      to: "2026-12-31",
      servicePlanId: ctx.planOnce,
    });
    const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();
    const { data: dec } = await admin
      .from("payments")
      .select("period_start, period_end, service_plan_id")
      .eq("customer_id", customerId)
      .eq("period_start", "2026-12-01")
      .single();
    expect(dec).toEqual({ period_start: "2026-12-01", period_end: "2026-12-31", service_plan_id: ctx.planOnce });
  });

  it("two concurrent upgrades of the same payment: exactly one wins", async () => {
    const ctx = await setupOrg("p54-race");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const results = await Promise.all([
      upgrade(ctx.owner, { paymentId, planId: ctx.planTwice }),
      upgrade(ctx.owner, { paymentId, planId: ctx.planUnlimited }),
    ]);
    const ok = results.filter((r) => !r.error);
    const failed = results.filter((r) => r.error);
    expect(ok).toHaveLength(1);
    expect(failed).toHaveLength(1);
    expect(failed[0]!.error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");

    const { count } = await admin
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerId);
    expect(count).toBe(2);
  });

  it("double upgrade over the same payment with the same date is rejected", async () => {
    const ctx = await setupOrg("p54-double");
    const { paymentId } = await customerWithPayment(ctx);
    const first = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(first.error).toBeNull();

    const second = await upgrade(ctx.owner, { paymentId, planId: ctx.planUnlimited });
    expect(second.error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");
    const third = await upgrade(ctx.owner, { paymentId, planId: ctx.planUnlimited, date: "2026-11-20" });
    expect(third.error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");
  });

  it("rejects an effective date outside (period_start, period_end], or null", async () => {
    const ctx = await setupOrg("p54-dates");
    const { paymentId } = await customerWithPayment(ctx);
    for (const date of [P_START, "2026-10-20", "2026-12-01", null]) {
      const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice, date });
      expect(error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");
    }
    // The last day itself is allowed.
    const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice, date: P_END });
    expect(error).toBeNull();
    expect((await readPayment(paymentId)).period_end).toBe("2026-11-29");
  });

  it("rejects the same plan, an equal-frequency plan, a lower plan, and any plan from UNLIMITED", async () => {
    const ctx = await setupOrg("p54-notup");
    const planOnceB = await createServicePlan(ctx.owner, {
      organizationId: ctx.org.id,
      serviceId: ctx.service.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 1,
    });

    const one = await customerWithPayment(ctx, ctx.planOnce);
    expect((await upgrade(ctx.owner, { paymentId: one.paymentId, planId: ctx.planOnce })).error!.message)
      .toContain("PAYMENT_UPGRADE_SAME_PLAN");
    expect((await upgrade(ctx.owner, { paymentId: one.paymentId, planId: planOnceB })).error!.message)
      .toContain("PAYMENT_UPGRADE_NOT_HIGHER_PLAN");

    const two = await customerWithPayment(ctx, ctx.planTwice);
    expect((await upgrade(ctx.owner, { paymentId: two.paymentId, planId: ctx.planOnce })).error!.message)
      .toContain("PAYMENT_UPGRADE_NOT_HIGHER_PLAN");

    const unl = await customerWithPayment(ctx, ctx.planUnlimited);
    expect((await upgrade(ctx.owner, { paymentId: unl.paymentId, planId: ctx.planTwice })).error!.message)
      .toContain("PAYMENT_UPGRADE_NOT_HIGHER_PLAN");

    // Nothing moved.
    expect((await readPayment(one.paymentId)).period_end).toBe(P_END);
    expect((await readPayment(two.paymentId)).period_end).toBe(P_END);
    expect((await readPayment(unl.paymentId)).period_end).toBe(P_END);
  });

  it("rejects a DROP_IN target plan and a DROP_IN (occurrence) payment", async () => {
    const ctx = await setupOrg("p54-dropin");
    const dropInPlan = await createServicePlan(ctx.owner, {
      organizationId: ctx.org.id,
      serviceId: ctx.service.id,
      planKind: "DROP_IN",
      price: 500,
    });
    const { paymentId, customerId } = await customerWithPayment(ctx);
    expect((await upgrade(ctx.owner, { paymentId, planId: dropInPlan })).error!.message)
      .toContain("PAYMENT_UPGRADE_PLAN_DROP_IN");

    const { data: resource } = await ctx.owner.client
      .from("resources")
      .insert({ organization_id: ctx.org.id, name: "Sala DI", created_by: ctx.owner.id })
      .select()
      .single();
    const { data: rule } = await ctx.owner.client
      .from("schedule_rules")
      .insert({
        organization_id: ctx.org.id,
        service_id: ctx.service.id,
        resource_id: resource!.id,
        weekday: 2,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 5,
        created_by: ctx.owner.id,
      })
      .select()
      .single();
    const occurrence = await insertOccurrenceLaterToday(rule!, {
      organizationId: ctx.org.id,
      serviceId: ctx.service.id,
      resourceId: resource!.id,
    });
    const { data: dropInPayment, error: dropInError } = await payFor(ctx.owner, {
      organizationId: ctx.org.id,
      customerId,
      serviceId: ctx.service.id,
      from: occurrence.start_at.slice(0, 10),
      to: occurrence.start_at.slice(0, 10),
      servicePlanId: dropInPlan,
      slotOccurrenceId: occurrence.id,
      amount: 500,
    });
    expect(dropInError).toBeNull();
    const { error } = await upgrade(ctx.owner, {
      paymentId: (dropInPayment as { id: string }).id,
      planId: ctx.planTwice,
      date: occurrence.start_at.slice(0, 10),
    });
    expect(error!.message).toContain("PAYMENT_UPGRADE_NOT_PERIOD_PAYMENT");
  });

  it("rejects an inactive plan, a non-PAID payment, a negative amount and a different service scope", async () => {
    const ctx = await setupOrg("p54-misc");
    const { paymentId } = await customerWithPayment(ctx);

    const inactive = await createServicePlan(ctx.owner, {
      organizationId: ctx.org.id,
      serviceId: ctx.service.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 3,
    });
    await ctx.owner.client.from("service_plans").update({ is_active: false }).eq("id", inactive);
    expect((await upgrade(ctx.owner, { paymentId, planId: inactive })).error!.message)
      .toContain("PAYMENT_UPGRADE_PLAN_INACTIVE");

    expect((await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice, amount: -1 })).error!.message)
      .toContain("PAYMENT_UPGRADE_INVALID_AMOUNT");

    const { data: otherService } = await ctx.owner.client
      .from("services")
      .insert({ organization_id: ctx.org.id, name: "Yoga", created_by: ctx.owner.id })
      .select()
      .single();
    await makeServicePaid(ctx.owner, otherService!.id);
    const otherPlan = await createServicePlan(ctx.owner, {
      organizationId: ctx.org.id,
      serviceId: otherService!.id,
      planKind: "UNLIMITED",
    });
    expect((await upgrade(ctx.owner, { paymentId, planId: otherPlan })).error!.message)
      .toContain("PAYMENT_UPGRADE_SCOPE_MISMATCH");

    const pending = await customerWithPayment(ctx);
    await admin.from("payments").update({ status: "PENDING" }).eq("id", pending.paymentId);
    expect((await upgrade(ctx.owner, { paymentId: pending.paymentId, planId: ctx.planTwice })).error!.message)
      .toContain("PAYMENT_UPGRADE_NOT_PAID");
    await admin.from("payments").update({ status: "VOID" }).eq("id", pending.paymentId);
    expect((await upgrade(ctx.owner, { paymentId: pending.paymentId, planId: ctx.planTwice })).error!.message)
      .toContain("PAYMENT_UPGRADE_NOT_PAID");

    expect((await readPayment(paymentId)).period_end).toBe(P_END);
  });

  it("cross-tenant: another organization's owner gets the same error as for a payment that does not exist", async () => {
    const ctxA = await setupOrg("p54-xt-a");
    const ctxB = await setupOrg("p54-xt-b");
    const { paymentId } = await customerWithPayment(ctxA);

    const foreign = await upgrade(ctxB.owner, { paymentId, planId: ctxB.planTwice });
    const missing = await upgrade(ctxB.owner, {
      paymentId: "00000000-0000-4000-8000-000000000000",
      planId: ctxB.planTwice,
    });
    expect(foreign.error!.message).toContain("PAYMENT_UPGRADE_NOT_AUTHORIZED");
    expect(missing.error!.message).toContain("PAYMENT_UPGRADE_NOT_AUTHORIZED");
    expect(foreign.error!.message).toBe(missing.error!.message);
    expect((await readPayment(paymentId)).period_end).toBe(P_END);

    // The caller's own org + a plan from another org: plan not found.
    const planFromB = await upgrade(ctxA.owner, { paymentId, planId: ctxB.planTwice });
    expect(planFromB.error!.message).toContain("PAYMENT_UPGRADE_PLAN_NOT_FOUND");
    expect((await readPayment(paymentId)).period_end).toBe(P_END);
  });

  it("a STAFF role without MANAGE_PAYMENTS cannot upgrade; one with it can", async () => {
    const ctx = await setupOrg("p54-roles");
    const { paymentId } = await customerWithPayment(ctx);

    const addStaff = async (prefix: string, canManage: boolean) => {
      const staff = await newUser(prefix);
      const { data: member, error: memberError } = await ctx.owner.client
        .from("organization_members")
        .insert({
          organization_id: ctx.org.id,
          profile_id: staff.id,
          role: "STAFF",
          created_by: ctx.owner.id,
        })
        .select()
        .single();
      expect(memberError).toBeNull();
      const { data: role, error: roleError } = await ctx.owner.client.rpc("create_organization_role", {
        p_organization_id: ctx.org.id,
        p_name: `Rol ${prefix} ${Math.random().toString(36).slice(2, 8)}`,
        p_can_view_payments: true,
        p_can_manage_payments: canManage,
        p_can_manage_bookings: true,
        p_can_manage_customers: true,
        p_can_manage_attendance: true,
      });
      expect(roleError).toBeNull();
      const { error: assignError } = await ctx.owner.client.rpc("set_member_role", {
        p_member_id: (member as { id: string }).id,
        p_role_id: (role as { id: string }).id,
      });
      expect(assignError).toBeNull();
      return staff;
    };

    const noPay = await addStaff("p54-nopay", false);
    const denied = await upgrade(noPay, { paymentId, planId: ctx.planTwice });
    expect(denied.error!.message).toContain("PAYMENT_UPGRADE_NOT_AUTHORIZED");
    expect((await readPayment(paymentId)).period_end).toBe(P_END);

    const canPay = await addStaff("p54-canpay", true);
    const allowed = await upgrade(canPay, { paymentId, planId: ctx.planTwice });
    expect(allowed.error).toBeNull();
    expect((await readPayment(paymentId)).period_end).toBe("2026-11-15");
  });

  it("effective date = period_end: the new payment covers exactly the last day and the old one ends the day before", async () => {
    const ctx = await setupOrg("p54-lastday");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const { data: newId, error } = await upgrade(ctx.owner, {
      paymentId,
      planId: ctx.planUnlimited,
      date: P_END,
      amount: 100,
    });
    expect(error).toBeNull();

    const oldP = await readPayment(paymentId);
    expect(oldP.period_start).toBe(P_START);
    expect(oldP.period_end).toBe("2026-11-29");
    const newP = await readPayment(newId as string);
    expect(newP.period_start).toBe(P_END);
    expect(newP.period_end).toBe(P_END);
    expect(newP.status).toBe("PAID");

    // Default proration for a one-day tail: 1 of 30 calendar days of a 2000 plan.
    const second = await customerWithPayment(ctx);
    const { data: tailId, error: tailError } = await upgrade(ctx.owner, {
      paymentId: second.paymentId,
      planId: ctx.planTwice,
      date: P_END,
    });
    expect(tailError).toBeNull();
    expect(Number((await readPayment(tailId as string)).amount)).toBe(66.67); // round(2000 / 30, 2)

    // One live payment per date: no overlap in the coverage mirror.
    const { data: coverage } = await admin
      .from("payment_service_coverage")
      .select("payment_id, period_start, period_end")
      .eq("customer_id", customerId)
      .order("period_start");
    expect(coverage).toEqual([
      { payment_id: paymentId, period_start: P_START, period_end: "2026-11-29" },
      { payment_id: newId, period_start: P_END, period_end: P_END },
    ]);

    // A one-day payment cannot be upgraded again: (start, end] is empty.
    const again = await upgrade(ctx.owner, { paymentId: newId as string, planId: ctx.planTwice, date: P_END });
    expect(again.error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");
  });

  it("an already-voided payment cannot be upgraded, and voiding afterwards only affects the payment you void", async () => {
    const ctx = await setupOrg("p54-voided");
    const voided = await customerWithPayment(ctx);
    const { error: voidError } = await ctx.owner.client.rpc("set_payment_status", {
      p_payment_id: voided.paymentId,
      p_status: "VOID",
    });
    expect(voidError).toBeNull();

    const rejected = await upgrade(ctx.owner, { paymentId: voided.paymentId, planId: ctx.planTwice });
    expect(rejected.error!.message).toContain("PAYMENT_UPGRADE_NOT_PAID");
    const { count: untouched } = await admin
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", voided.customerId);
    expect(untouched).toBe(1);
    expect((await readPayment(voided.paymentId)).period_end).toBe(P_END);

    // Upgrade, then void the NEW (tail) payment: it cannot be upgraded again
    // and the shortened old one stays PAID with its shortened period.
    const live = await customerWithPayment(ctx);
    const { data: newId, error } = await upgrade(ctx.owner, { paymentId: live.paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();
    await ctx.owner.client.rpc("set_payment_status", { p_payment_id: newId as string, p_status: "VOID" });
    const afterVoid = await upgrade(ctx.owner, { paymentId: newId as string, planId: ctx.planUnlimited, date: "2026-11-20" });
    expect(afterVoid.error!.message).toContain("PAYMENT_UPGRADE_NOT_PAID");
    const oldP = await readPayment(live.paymentId);
    expect(oldP.status).toBe("PAID");
    expect(oldP.period_end).toBe("2026-11-15");
  });

  it("concurrent upgrades with DIFFERENT dates and plans on the same payment: serialized, always a gap-free partition", async () => {
    const ctx = await setupOrg("p54-race2");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const results = await Promise.all([
      upgrade(ctx.owner, { paymentId, planId: ctx.planTwice, date: "2026-11-10" }),
      upgrade(ctx.owner, { paymentId, planId: ctx.planUnlimited, date: "2026-11-20" }),
      upgrade(ctx.owner, { paymentId, planId: ctx.planTwice, date: "2026-11-25" }),
    ]);
    // Which of them wins depends on lock order: an earlier date still fits
    // inside the old payment once a later upgrade already shortened it, so
    // 1..3 may succeed. A later date after an earlier one cannot: it falls
    // outside the already shortened period.
    const ok = results.filter((r) => !r.error);
    expect(ok.length).toBeGreaterThanOrEqual(1);
    for (const r of results.filter((r) => r.error)) {
      expect(r.error!.message).toContain("PAYMENT_UPGRADE_INVALID_DATE");
    }

    const { data: payments } = await admin
      .from("payments")
      .select("id, period_start, period_end, status")
      .eq("customer_id", customerId)
      .order("period_start");
    expect(payments).toHaveLength(1 + ok.length);
    // Partition: contiguous, no gap, no overlap, ends at the original end.
    expect(payments![0]!.period_start).toBe(P_START);
    expect(payments![payments!.length - 1]!.period_end).toBe(P_END);
    for (let i = 0; i < payments!.length; i++) {
      expect(payments![i]!.status).toBe("PAID");
      if (i === 0) continue;
      const dayAfter = new Date(`${payments![i - 1]!.period_end}T00:00:00Z`);
      dayAfter.setUTCDate(dayAfter.getUTCDate() + 1);
      expect(dayAfter.toISOString().slice(0, 10)).toBe(payments![i]!.period_start);
    }
  });

  it("concurrent upgrade vs. VOID of the same payment leaves a consistent state", async () => {
    const ctx = await setupOrg("p54-race-void");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const [up, voidRes] = await Promise.all([
      upgrade(ctx.owner, { paymentId, planId: ctx.planTwice }),
      ctx.owner.client.rpc("set_payment_status", { p_payment_id: paymentId, p_status: "VOID" }),
    ]);
    expect(voidRes.error).toBeNull();

    const { data: payments } = await admin
      .from("payments")
      .select("id, period_start, period_end, status")
      .eq("customer_id", customerId)
      .order("period_start");
    const live = payments!.filter((p) => p.status === "PAID");
    // No two PAID payments overlap, whichever order the two calls serialized in.
    for (let i = 0; i < live.length; i++) {
      for (let j = i + 1; j < live.length; j++) {
        expect(live[i]!.period_end < live[j]!.period_start || live[j]!.period_end < live[i]!.period_start).toBe(true);
      }
    }
    if (up.error) {
      // VOID won: the upgrade saw a non-PAID payment and changed nothing.
      expect(up.error.message).toContain("PAYMENT_UPGRADE_NOT_PAID");
      expect(payments).toHaveLength(1);
      expect(live).toHaveLength(0);
    } else {
      // Upgrade won: the old (shortened) payment was then voided; only the tail stays PAID.
      expect(payments).toHaveLength(2);
      expect(live.map((p) => p.id)).toEqual([up.data]);
    }
  });

  it("series and bookings keep resolving the plan per date: old plan before the effective date, new plan from it on, series untouched", async () => {
    const ctx = await setupOrg("p54-series");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const { data: resource } = await ctx.owner.client
      .from("resources")
      .insert({ organization_id: ctx.org.id, name: "Sala S", created_by: ctx.owner.id })
      .select()
      .single();

    // Two standing series (created in order, so the quota position is 1 and 2).
    const series: { id: string; ruleId: string }[] = [];
    for (const weekday of [1, 3]) {
      const { data: rule, error: ruleError } = await ctx.owner.client
        .from("schedule_rules")
        .insert({
          organization_id: ctx.org.id,
          service_id: ctx.service.id,
          resource_id: resource!.id,
          weekday,
          local_start_time: "09:00",
          duration_minutes: 60,
          capacity: 10,
          created_by: ctx.owner.id,
        })
        .select()
        .single();
      expect(ruleError).toBeNull();
      const { data: rb, error: rbError } = await admin
        .from("recurring_bookings")
        .insert({
          organization_id: ctx.org.id,
          customer_id: customerId,
          schedule_rule_id: rule!.id,
          status: "ACTIVE",
          start_date: "2026-10-01",
          created_by: ctx.owner.id,
        })
        .select()
        .single();
      expect(rbError).toBeNull();
      series.push({ id: rb!.id as string, ruleId: rule!.id as string });
    }

    const occurrenceOn = (ruleId: string, date: string) => occurrenceAt(ctx, ruleId, resource!.id, date);
    // evaluate_payment_coverage() is internal (never granted to API roles), so
    // it is queried over a direct connection, same as phase41.
    const pgClient = new Client({ connectionString: DIRECT_DB_URL });
    await pgClient.connect();
    const verdict = async (seriesIdx: number, occurrenceId: string) => {
      const { rows } = await pgClient.query(
        "select public.evaluate_payment_coverage($1, $2, $3, $4, false)::text as v",
        [customerId, ctx.service.id, occurrenceId, series[seriesIdx]!.id],
      );
      return rows[0].v as string;
    };

    const s2BeforeEffective = await occurrenceOn(series[1]!.ruleId, "2026-11-11");
    const s2LastOldDay = await occurrenceOn(series[1]!.ruleId, "2026-11-15");
    const s2OnEffective = await occurrenceOn(series[1]!.ruleId, EFFECTIVE);
    const s2AfterEffective = await occurrenceOn(series[1]!.ruleId, "2026-11-18");
    const s1BeforeEffective = await occurrenceOn(series[0]!.ruleId, "2026-11-09");
    const s1AfterEffective = await occurrenceOn(series[0]!.ruleId, "2026-11-23");

    // Before the upgrade: 1x/week covers series #1 only.
    expect(await verdict(0, s1BeforeEffective)).toBe("OK");
    expect(await verdict(1, s2BeforeEffective)).toBe("OVER_PLAN_QUOTA");
    expect(await verdict(1, s2OnEffective)).toBe("OVER_PLAN_QUOTA");

    const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();

    // After: the same occurrences resolve per date. Old plan up to the 15th...
    expect(await verdict(0, s1BeforeEffective)).toBe("OK");
    expect(await verdict(1, s2BeforeEffective)).toBe("OVER_PLAN_QUOTA");
    expect(await verdict(1, s2LastOldDay)).toBe("OVER_PLAN_QUOTA");
    // ...new plan from the effective date (inclusive) on.
    expect(await verdict(1, s2OnEffective)).toBe("OK");
    expect(await verdict(1, s2AfterEffective)).toBe("OK");
    expect(await verdict(0, s1AfterEffective)).toBe("OK");

    // The series themselves are neither cancelled nor recreated.
    const { data: rbs } = await admin
      .from("recurring_bookings")
      .select("id, status")
      .eq("customer_id", customerId)
      .order("created_at");
    expect(rbs).toEqual(series.map((s) => ({ id: s.id, status: "ACTIVE" })));
    await pgClient.end();
  });

  it("an existing CONFIRMED booking before the effective date survives the upgrade and keeps its slot", async () => {
    const ctx = await setupOrg("p54-booking");
    const { customerId, paymentId } = await customerWithPayment(ctx);

    const { data: resource } = await ctx.owner.client
      .from("resources")
      .insert({ organization_id: ctx.org.id, name: "Sala B", created_by: ctx.owner.id })
      .select()
      .single();
    const { data: rule } = await ctx.owner.client
      .from("schedule_rules")
      .insert({
        organization_id: ctx.org.id,
        service_id: ctx.service.id,
        resource_id: resource!.id,
        weekday: 1,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: ctx.owner.id,
      })
      .select()
      .single();
    const occ = { id: await occurrenceAt(ctx, rule!.id, resource!.id, "2026-11-09") };
    const { data: booking, error: bookError } = await admin
      .from("bookings")
      .insert({
        organization_id: ctx.org.id,
        customer_id: customerId,
        slot_occurrence_id: occ!.id,
        status: "CONFIRMED",
        created_by: ctx.owner.id,
      })
      .select("id")
      .single();
    expect(bookError).toBeNull();

    const { error } = await upgrade(ctx.owner, { paymentId, planId: ctx.planTwice });
    expect(error).toBeNull();

    const { data: after } = await admin
      .from("bookings")
      .select("status, cancelled_at")
      .eq("id", booking!.id)
      .single();
    expect(after).toEqual({ status: "CONFIRMED", cancelled_at: null });
  });

  it("is not executable by anon", async () => {
    const ctx = await setupOrg("p54-anon");
    const { paymentId } = await customerWithPayment(ctx);
    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { error } = await anon.rpc("admin_upgrade_payment", {
      p_payment_id: paymentId,
      p_new_plan_id: ctx.planTwice,
      p_effective_date: EFFECTIVE,
    });
    expect(error).not.toBeNull();
    expect((await readPayment(paymentId)).period_end).toBe(P_END);
  });
});
