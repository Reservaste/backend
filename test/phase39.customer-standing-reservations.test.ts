// Integration tests for Phase 39 -- customer_standing_reservations() and
// customer_service_plan_quotas(): la ficha de un cliente (/org/[slug]/
// customers/[customerId]) necesita ver qué horarios fijos tiene agendados
// (sin importar a qué ScheduleRule/servicio pertenezca cada uno -- el
// inverso de schedule_rule_standing_reservations(), Fase 11/25) y cuánta
// cuota semanal le da su plan vigente hoy en cada servicio, para poder
// mostrar "N de M" en pantalla.
//
// Requiere un Supabase local corriendo (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  insertOccurrenceLaterToday,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

interface OrgFixture {
  owner: SignedInUser;
  org: { id: string; slug: string };
  resource: { id: string };
}

async function setupOrg(prefix: string): Promise<OrgFixture> {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  return { owner, org, resource: resource as { id: string } };
}

async function createService(f: OrgFixture, name: string) {
  const { data, error } = await f.owner.client
    .from("services")
    .insert({ organization_id: f.org.id, name, payment_required: true, created_by: f.owner.id })
    .select()
    .single();
  if (error) throw new Error(`failed to create service: ${error.message}`);
  return data as { id: string; name: string };
}

/**
 * Un weekday distinto por cada llamada (`n` 1..6) para que las reglas de
 * un mismo fixture nunca choquen entre sí, sin importar a qué servicio
 * pertenezcan -- mismo truco que test/phase38.
 */
async function createRule(
  f: OrgFixture,
  serviceId: string,
  weekdayOffset: number,
  capacity = 5,
): Promise<{ id: string }> {
  const weekday = (new Date().getUTCDay() + weekdayOffset) % 7;
  const { data, error } = await f.owner.client
    .from("schedule_rules")
    .insert({
      organization_id: f.org.id,
      service_id: serviceId,
      resource_id: f.resource.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity,
      created_by: f.owner.id,
    })
    .select()
    .single();
  if (error) throw new Error(`failed to create rule: ${error.message}`);
  return data as { id: string };
}

async function enroll(f: OrgFixture, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data, error } = await f.owner.client
    .from("customers")
    .insert({ organization_id: f.org.id, profile_id: customer.id, created_by: f.owner.id })
    .select()
    .single();
  if (error) throw new Error(`failed to enroll customer: ${error.message}`);
  return { customer, customerRow: data as { id: string } };
}

async function assignStanding(f: OrgFixture, scheduleRuleId: string, customerId: string) {
  const { data, error } = await f.owner.client.rpc("admin_create_recurring_booking", {
    p_schedule_rule_id: scheduleRuleId,
    p_customer_id: customerId,
  });
  if (error) throw new Error(`failed to create standing reservation: ${error.message}`);
  return data as { id: string };
}

interface StandingRow {
  recurring_booking_id: string;
  schedule_rule_id: string;
  service_id: string;
  service_name: string;
  weekday: number;
  local_start_time: string;
  duration_minutes: number;
  status: "ACTIVE" | "CANCELLED";
  created_at: string;
  upcoming_confirmed: number;
  upcoming_not_generated: number;
  upcoming_unpaid: number;
  upcoming_over_quota: number;
  upcoming_beyond_period: number;
}

interface QuotaRow {
  service_id: string;
  service_name: string;
  service_plan_id: string | null;
  plan_name: string | null;
  plan_kind: "DROP_IN" | "WEEKLY_QUOTA" | "UNLIMITED" | null;
  weekly_quota: number | null;
  quota_scope: "PER_SERVICE" | "SHARED_ACROSS_SERVICES" | null;
  assigned_count: number;
}

describe("Phase 39: customer_standing_reservations() / customer_service_plan_quotas()", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("un cliente con horarios fijos en 2 servicios (cuotas distintas) y uno por debajo de su cuota: el detalle y la cuota por servicio coinciden", async () => {
    const f = await setupOrg("p39-multi");
    createdUserIds.push(f.owner.id);

    // Servicio A: cuota 2, el cliente tiene sus 2 series -- al día.
    const serviceA = await createService(f, "Pilates Reformer");
    const planA = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: serviceA.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      price: 2500,
    });
    const ruleA1 = await createRule(f, serviceA.id, 1);
    const ruleA2 = await createRule(f, serviceA.id, 2);

    // Servicio B: cuota 1, el cliente tiene su única serie -- al día.
    const serviceB = await createService(f, "Yoga");
    const planB = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: serviceB.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 1,
      price: 1800,
    });
    const ruleB1 = await createRule(f, serviceB.id, 3);

    // Servicio C: cuota 2, el cliente sólo tiene 1 serie -- le falta 1.
    const serviceC = await createService(f, "Funcional");
    const planC = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: serviceC.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      price: 2200,
    });
    const ruleC1 = await createRule(f, serviceC.id, 4);

    const { customer, customerRow } = await enroll(f, "p39-multi-cust");
    createdUserIds.push(customer.id);

    // Pagos vigentes HOY para los tres servicios -- resolve_covering_service_plan()
    // sólo resuelve un plan cuando hay un Payment PAID que cubre la fecha local de
    // hoy (ADR-0029 §4.3).
    for (const { serviceId, planId } of [
      { serviceId: serviceA.id, planId: planA },
      { serviceId: serviceB.id, planId: planB },
      { serviceId: serviceC.id, planId: planC },
    ]) {
      const { error } = await payFor(f.owner, {
        organizationId: f.org.id,
        customerId: customerRow.id,
        serviceId,
        from: isoDate(-5),
        to: isoDate(25),
        servicePlanId: planId,
      });
      expect(error).toBeNull();
    }

    // Una ocurrencia real por regla, insertada directamente en vez de
    // confiar en que el weekday elegido por createRule() caiga dentro del
    // mes calendario vigente (borde de fin de mes, ver curation-inbox.md
    // 2026-09-29/30) -- admin_create_recurring_booking() sólo genera un
    // Booking si ya existe una SlotOccurrence real que matchee la regla.
    const ctxA = { organizationId: f.org.id, serviceId: serviceA.id, resourceId: f.resource.id };
    const ctxB = { organizationId: f.org.id, serviceId: serviceB.id, resourceId: f.resource.id };
    const ctxC = { organizationId: f.org.id, serviceId: serviceC.id, resourceId: f.resource.id };
    await insertOccurrenceLaterToday(ruleA1, ctxA);
    await insertOccurrenceLaterToday(ruleA2, ctxA);
    await insertOccurrenceLaterToday(ruleB1, ctxB);
    await insertOccurrenceLaterToday(ruleC1, ctxC);

    const rbA1 = await assignStanding(f, ruleA1.id, customerRow.id);
    const rbA2 = await assignStanding(f, ruleA2.id, customerRow.id);
    const rbB1 = await assignStanding(f, ruleB1.id, customerRow.id);
    const rbC1 = await assignStanding(f, ruleC1.id, customerRow.id);

    // ---- customer_standing_reservations(): las 4 series, sin importar servicio ----
    const { data: standingRows, error: standingError } = await f.owner.client.rpc(
      "customer_standing_reservations",
      { p_customer_id: customerRow.id },
    );
    expect(standingError).toBeNull();
    const standing = standingRows as StandingRow[];
    expect(standing).toHaveLength(4);

    const byRb = (id: string) => standing.find((r) => r.recurring_booking_id === id);
    expect(byRb(rbA1.id)?.service_id).toBe(serviceA.id);
    expect(byRb(rbA2.id)?.service_id).toBe(serviceA.id);
    expect(byRb(rbB1.id)?.service_id).toBe(serviceB.id);
    expect(byRb(rbC1.id)?.service_id).toBe(serviceC.id);
    // Fue armado para confirmarse ya mismo: sirve como control de que el
    // conteo compartido con schedule_rule_standing_reservations() corrió.
    for (const row of standing) {
      expect(row.status).toBe("ACTIVE");
      expect(row.upcoming_confirmed).toBeGreaterThan(0);
    }

    // El mismo agregado que ya devuelve schedule_rule_standing_reservations()
    // para cada regla tiene que coincidir con la fila de acá -- misma función
    // compartida, no puede divergir.
    const { data: aggregateA1 } = await f.owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: ruleA1.id,
    });
    const aggregateRowA1 = (
      aggregateA1 as { recurring_booking_id: string; upcoming_confirmed: number }[]
    ).find((r) => r.recurring_booking_id === rbA1.id)!;
    expect(byRb(rbA1.id)?.upcoming_confirmed).toBe(aggregateRowA1.upcoming_confirmed);

    // ---- customer_service_plan_quotas(): cuota por servicio, no global ----
    const { data: quotaRows, error: quotaError } = await f.owner.client.rpc(
      "customer_service_plan_quotas",
      { p_customer_id: customerRow.id },
    );
    expect(quotaError).toBeNull();
    const quotas = quotaRows as QuotaRow[];
    expect(quotas).toHaveLength(3);

    const byService = (id: string) => quotas.find((r) => r.service_id === id)!;

    const quotaA = byService(serviceA.id);
    expect(quotaA.plan_kind).toBe("WEEKLY_QUOTA");
    expect(quotaA.weekly_quota).toBe(2);
    expect(quotaA.assigned_count).toBe(2);
    expect(quotaA.service_plan_id).toBe(planA);

    const quotaB = byService(serviceB.id);
    expect(quotaB.weekly_quota).toBe(1);
    expect(quotaB.assigned_count).toBe(1);

    // El caso que el pedido del dueño necesita: 1 de 2, el frontend puede
    // calcular "le falta 1".
    const quotaC = byService(serviceC.id);
    expect(quotaC.weekly_quota).toBe(2);
    expect(quotaC.assigned_count).toBe(1);
    expect(quotaC.weekly_quota! - quotaC.assigned_count).toBe(1);
  });

  it("un servicio sin plan vigente hoy: weekly_quota/plan_kind vienen null pero assigned_count viaja igual", async () => {
    const f = await setupOrg("p39-noplan");
    createdUserIds.push(f.owner.id);

    const service = await createService(f, "Pilates");
    // Plan de cuota creado pero nunca pagado -- ningún Payment PAID cubre hoy.
    await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: service.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 3,
      price: 2000,
    });
    const rule = await createRule(f, service.id, 1);
    // Mismo motivo que en el test anterior: una ocurrencia real, no
    // depender de que el weekday caiga dentro del mes vigente.
    await insertOccurrenceLaterToday(rule, {
      organizationId: f.org.id,
      serviceId: service.id,
      resourceId: f.resource.id,
    });

    const { customer, customerRow } = await enroll(f, "p39-noplan-cust");
    createdUserIds.push(customer.id);

    await assignStanding(f, rule.id, customerRow.id);

    const { data: quotaRows, error } = await f.owner.client.rpc("customer_service_plan_quotas", {
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    const quotas = quotaRows as QuotaRow[];
    expect(quotas).toHaveLength(1);
    expect(quotas[0]!.service_plan_id).toBeNull();
    expect(quotas[0]!.plan_kind).toBeNull();
    expect(quotas[0]!.weekly_quota).toBeNull();
    // La serie existe igual, con o sin plan vigente para compararla.
    expect(quotas[0]!.assigned_count).toBe(1);
  });

  it("un no-miembro de la organización no ve las reservas fijas ni la cuota de un cliente ajeno", async () => {
    const f = await setupOrg("p39-notmember");
    createdUserIds.push(f.owner.id);

    const service = await createService(f, "Pilates");
    await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: service.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      price: 2000,
    });
    const rule = await createRule(f, service.id, 1);
    const { customer, customerRow } = await enroll(f, "p39-notmember-cust");
    createdUserIds.push(customer.id);
    await assignStanding(f, rule.id, customerRow.id);

    const outsider = await createSignedInUser("p39-notmember-outsider");
    createdUserIds.push(outsider.id);

    const { data: standingData, error: standingError } = await outsider.client.rpc(
      "customer_standing_reservations",
      { p_customer_id: customerRow.id },
    );
    expect(standingError).toBeNull();
    expect(standingData).toEqual([]);

    const { data: quotaData, error: quotaError } = await outsider.client.rpc(
      "customer_service_plan_quotas",
      { p_customer_id: customerRow.id },
    );
    expect(quotaError).toBeNull();
    expect(quotaData).toEqual([]);
  });

  it("anon no puede ejecutar ninguna de las dos RPC", async () => {
    const f = await setupOrg("p39-anon");
    createdUserIds.push(f.owner.id);
    const service = await createService(f, "Pilates");
    await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: service.id,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      price: 2000,
    });
    const rule = await createRule(f, service.id, 1);
    const { customer, customerRow } = await enroll(f, "p39-anon-cust");
    createdUserIds.push(customer.id);
    await assignStanding(f, rule.id, customerRow.id);

    const { createClient } = await import("@supabase/supabase-js");
    const { SUPABASE_URL, ANON_KEY } = await import("./helpers");
    const anonClient = createClient(SUPABASE_URL, ANON_KEY);

    const { error: standingError } = await anonClient.rpc("customer_standing_reservations", {
      p_customer_id: customerRow.id,
    });
    expect(standingError).not.toBeNull();

    const { error: quotaError } = await anonClient.rpc("customer_service_plan_quotas", {
      p_customer_id: customerRow.id,
    });
    expect(quotaError).not.toBeNull();
  });
});
