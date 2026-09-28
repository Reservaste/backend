// Integration test for Phase 37: my_payments() stopped silently dropping
// payments anchored to a multi-service plan (INNER JOIN against services
// on payments.service_id, which is NULL since ADR-0029 for any plan that
// covers more than one service) -- and now returns enough about the plan
// (plan_name/plan_kind/weekly_quota/plan_applies_to_all_services) for the
// customer to know what a payment actually bought.
//
// Phase 37b (20260925120000): also asserts `currency` (organizations.currency,
// ADR-0024) travels alongside amount -- a customer can have payments from
// several organizations, each with its own currency.
//
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

describe("Phase 37: my_payments() and multi-service plans (ADR-0029)", () => {
  const createdUserIds: string[] = [];
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let customer: SignedInUser;
  let customerId: string;

  beforeAll(async () => {
    owner = await createSignedInUser("p37-owner");
    createdUserIds.push(owner.id);
    org = await createOrganization(owner, "p37-org");

    customer = await createSignedInUser("p37-customer");
    createdUserIds.push(customer.id);
    const { data: customerRow, error: customerError } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
      .select()
      .single();
    if (customerError || !customerRow) {
      throw new Error(`failed to create customer: ${customerError?.message}`);
    }
    customerId = customerRow.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it(
    "returns a payment anchored to a multi-service (applies_to_all_services) plan -- " +
      "this is the bug: an INNER JOIN on services silently dropped it because " +
      "payments.service_id is NULL for this payment",
    async () => {
      const { data: serviceA, error: serviceAError } = await owner.client
        .from("services")
        .insert({ organization_id: org.id, name: "Aparatos", created_by: owner.id })
        .select()
        .single();
      expect(serviceAError).toBeNull();

      const { data: serviceB, error: serviceBError } = await owner.client
        .from("services")
        .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
        .select()
        .single();
      expect(serviceBError).toBeNull();

      const { data: globalPlan, error: globalPlanError } = await owner.client.rpc(
        "create_service_plan",
        {
          p_organization_id: org.id,
          p_name: "Pase libre",
          p_description: null,
          p_price: 3000,
          p_plan_kind: "UNLIMITED",
          p_weekly_quota: null,
          p_billing_type: "MONTHLY",
          p_billing_cycle: "CALENDAR_MONTH",
          p_sort_order: 0,
          p_applies_to_all_services: true,
          p_service_ids: null,
          p_quota_scope: null,
        },
      );
      expect(globalPlanError).toBeNull();
      const planId = (globalPlan as { id: string }).id;

      const { data: payment, error: paymentError } = await payFor(owner, {
        organizationId: org.id,
        customerId,
        // ADR-0029: payments_plan_consistency() (Fase 22) recalcula
        // service_id desde el plan y lo pisa a NULL porque el plan cubre
        // dos servicios -- el serviceA de acá es sólo lo que exige el
        // shape del helper, no lo que termina persistido.
        serviceId: serviceA!.id,
        servicePlanId: planId,
        from: isoDate(-1),
        to: isoDate(30),
        status: "PAID",
        amount: 3000,
      });
      expect(paymentError).toBeNull();
      expect(payment!.service_id).toBeNull();

      const { data, error } = await customer.client.rpc("my_payments");
      expect(error).toBeNull();

      const row = (data as Array<Record<string, unknown>>).find((p) => p.payment_id === payment!.id);
      // This is what was broken: the row simply wasn't there.
      expect(row).toBeDefined();
      expect(row!.service_name).toBe("Pase libre"); // coalesce(s.name, sp.name)
      expect(row!.plan_name).toBe("Pase libre");
      expect(row!.plan_kind).toBe("UNLIMITED");
      expect(row!.weekly_quota).toBeNull();
      expect(row!.plan_applies_to_all_services).toBe(true);
      expect(Number(row!.amount)).toBe(3000);
      // Fase 37b: currency viaja junto al monto -- un mismo cliente puede
      // tener pagos de varias organizaciones, cada una con su propia
      // moneda (ADR-0024, default UYU).
      expect(row!.currency).toBe("UYU");

      void serviceB;
    },
  );

  it("still returns a normal single-service payment, with its plan's shape alongside the service name", async () => {
    const { data: service, error: serviceError } = await owner.client
      .from("services")
      .insert({
        organization_id: org.id,
        name: "CrossFit",
        created_by: owner.id,
        // WEEKLY_QUOTA plans require the service to be payment-gated
        // (assert_service_plan_service_payment_required, Fase 22).
        billing_type: "MONTHLY",
        billing_cycle: "CALENDAR_MONTH",
        payment_required: true,
      })
      .select()
      .single();
    expect(serviceError).toBeNull();

    const planId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service!.id,
      name: "3 por semana",
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 3,
      price: 1800,
    });

    const { data: payment, error: paymentError } = await payFor(owner, {
      organizationId: org.id,
      customerId,
      serviceId: service!.id,
      servicePlanId: planId,
      from: isoDate(-1),
      to: isoDate(30),
      status: "PAID",
      amount: 1800,
    });
    expect(paymentError).toBeNull();
    expect(payment!.service_id).toBe(service!.id);

    const { data, error } = await customer.client.rpc("my_payments");
    expect(error).toBeNull();

    const row = (data as Array<Record<string, unknown>>).find((p) => p.payment_id === payment!.id);
    expect(row).toBeDefined();
    expect(row!.service_name).toBe("CrossFit");
    expect(row!.plan_name).toBe("3 por semana");
    expect(row!.plan_kind).toBe("WEEKLY_QUOTA");
    expect(row!.weekly_quota).toBe(3);
    expect(row!.plan_applies_to_all_services).toBe(false);
    expect(Number(row!.amount)).toBe(1800);
    expect(row!.currency).toBe("UYU");
  });

  it("my_payments stays organization-scoped and customer-scoped (ADR-0006, unaffected by this fix)", async () => {
    const stranger = await createSignedInUser("p37-stranger");
    createdUserIds.push(stranger.id);

    const { data, error } = await stranger.client.rpc("my_payments");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("anon no puede ejecutar my_payments -- es de la sesion, resuelta por auth.uid() (mismo criterio que ADR-0005/ADR-0028)", async () => {
    const { createClient } = await import("@supabase/supabase-js");
    const { SUPABASE_URL, ANON_KEY } = await import("./helpers");
    const anonClient = createClient(SUPABASE_URL, ANON_KEY);
    const { data, error } = await anonClient.rpc("my_payments");
    expect(error).not.toBeNull();
    expect(error?.code).toBe("42501");
    expect(data).toBeNull();
  });
});
