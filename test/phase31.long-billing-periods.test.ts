// Integration tests for Phase 31: ciclos de facturación más largos que el
// mes y prorrateo del primer período (ADR-0031). Requiere un Supabase
// local corriendo (`npx supabase start`).
//
// Lo que estas pruebas cuidan, en orden de importancia:
// 1. El período NUNCA se recorta (resolución 2): quien entra el 15 de
//    septiembre en un trimestral jul-sep compra el trimestre entero. Lo que
//    se prorratea es el precio.
// 2. El prorrateo es por meses enteros contando el mes de alta como
//    completo (resolución 1), y SÓLO al entrar a mitad de un ciclo
//    calendario largo: un ciclo rodante arranca el día de la compra y no
//    tiene nada que prorratear.
// 3. quote_service_plan_period() cotiza, no cobra: es función pura de
//    (plan, fecha), no mira ni un pago, así que no puede descontar un
//    cambio de plan (resolución 3) ni reconocer lo no consumido
//    (resolución 4).
// 4. billing_period_months/billing_anchor_month son términos: inmutables
//    con pagos no-VOID, igual que plan_kind/weekly_quota (ADR-0024 res. 5).
// 5. En un plan de ciclo largo el crédito de recupero vence a fin de MES,
//    no a fin de período (resolución 6).

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

interface Quote {
  period_start: string;
  period_end: string;
  full_price: number | string;
  prorated_price: number | string;
  prorated: boolean;
  units_charged: number;
  units_total: number;
}

/** Un plan con los dos parámetros nuevos, vía la RPC (ADR-0029/ADR-0031). */
async function createPlan(
  owner: SignedInUser,
  args: {
    organizationId: string;
    serviceId: string;
    name: string;
    price: number;
    planKind?: "WEEKLY_QUOTA" | "UNLIMITED";
    weeklyQuota?: number;
    cycle: "CALENDAR_MONTH" | "ROLLING_MONTH" | "CALENDAR_PERIOD" | "ROLLING_PERIOD";
    periodMonths?: number | null;
    anchorMonth?: number | null;
  },
): Promise<{ id: string | null; error: { message: string } | null }> {
  const planKind = args.planKind ?? "UNLIMITED";
  const { data, error } = await owner.client.rpc("create_service_plan", {
    p_organization_id: args.organizationId,
    p_name: args.name,
    p_description: null,
    p_price: args.price,
    p_plan_kind: planKind,
    p_weekly_quota: planKind === "WEEKLY_QUOTA" ? (args.weeklyQuota ?? 1) : null,
    p_billing_type: "MONTHLY",
    p_billing_cycle: args.cycle,
    p_sort_order: 0,
    p_applies_to_all_services: false,
    p_service_ids: [args.serviceId],
    p_quota_scope: planKind === "WEEKLY_QUOTA" ? "PER_SERVICE" : null,
    p_billing_period_months: args.periodMonths ?? null,
    p_billing_anchor_month: args.anchorMonth ?? null,
  });
  return { id: (data as { id: string } | null)?.id ?? null, error };
}

async function quote(owner: SignedInUser, planId: string, from: string): Promise<Quote> {
  const { data, error } = await owner.client.rpc("quote_service_plan_period", {
    p_service_plan_id: planId,
    p_from: from,
  });
  expect(error).toBeNull();
  const rows = data as Quote[];
  expect(rows).toHaveLength(1);
  return rows[0]!;
}

async function setupOrg(prefix: string) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", payment_required: true, created_by: owner.id })
    .select()
    .single();

  return { owner, org, serviceId: service!.id as string };
}

/** La fecha local (tz de la organización) de una ocurrencia, y el fin de su mes. */
function localDate(startAt: string, timeZone = "America/Montevideo"): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(startAt));
}

function endOfMonth(isoDay: string): string {
  const [y, m] = isoDay.split("-").map(Number);
  // Día 0 del mes siguiente = último día de éste, sin depender del largo.
  const d = new Date(Date.UTC(y!, m!, 0));
  return d.toISOString().slice(0, 10);
}

describe("Phase 31: ciclos largos y prorrateo (ADR-0031)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("cotiza el trimestre COMPLETO y prorratea el precio por meses enteros al entrar a mitad de ciclo", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-quote");
    createdUserIds.push(owner.id);

    // Trimestral anclado en enero: ene-mar, abr-jun, jul-sep, oct-dic,
    // iguales para todos los clientes del plan.
    const { id: planId, error } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral 3000",
      price: 3000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });
    expect(error).toBeNull();

    // Alta el 15 de septiembre: 1 mes de 3. El período NO se recorta --
    // arranca el 1 de julio (resolución 2).
    const q1 = await quote(owner, planId!, "2026-09-15");
    expect(q1.period_start).toBe("2026-07-01");
    expect(q1.period_end).toBe("2026-09-30");
    expect(Number(q1.full_price)).toBe(3000);
    expect(q1.units_charged).toBe(1);
    expect(q1.units_total).toBe(3);
    expect(Number(q1.prorated_price)).toBe(1000);
    expect(q1.prorated).toBe(true);

    // Alta el 2 de agosto: 2 de 3 (el mes de alta cuenta completo).
    const q2 = await quote(owner, planId!, "2026-08-02");
    expect(q2.period_start).toBe("2026-07-01");
    expect(q2.units_charged).toBe(2);
    expect(Number(q2.prorated_price)).toBe(2000);
    expect(q2.prorated).toBe(true);

    // Alta el primer día del trimestre: no hay nada que prorratear.
    const q3 = await quote(owner, planId!, "2026-07-01");
    expect(q3.units_charged).toBe(3);
    expect(Number(q3.prorated_price)).toBe(3000);
    expect(q3.prorated).toBe(false);

    // Redondeo a la unidad entera de moneda, half-up: 1000/3 = 333.33 -> 333,
    // 2/3 de 1000 = 666.67 -> 667. Nunca por encima del precio de lista.
    const { id: oddPlanId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral 1000",
      price: 1000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });
    expect(Number((await quote(owner, oddPlanId!, "2026-09-15")).prorated_price)).toBe(333);
    expect(Number((await quote(owner, oddPlanId!, "2026-08-02")).prorated_price)).toBe(667);
  });

  it("un ciclo rodante nunca prorratea, y el borde de mes no lo rompe", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-rolling");
    createdUserIds.push(owner.id);

    const { id: annualId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Anual rodante",
      price: 12000,
      cycle: "ROLLING_PERIOD",
      periodMonths: 12,
    });

    // Arranca el día de la compra: no hay fracción que descontar.
    for (const from of ["2026-09-15", "2026-02-10", "2026-07-01"]) {
      const q = await quote(owner, annualId!, from);
      expect(q.period_start).toBe(from);
      expect(q.units_charged).toBe(12);
      expect(q.units_total).toBe(12);
      expect(Number(q.prorated_price)).toBe(12000);
      expect(q.prorated).toBe(false);
    }

    // Borde de mes: Postgres recorta 31-ene + 12 meses solo, igual que en
    // ROLLING_MONTH -- y el período sigue siendo "un año menos un día".
    const edge = await quote(owner, annualId!, "2026-01-31");
    expect(edge.period_start).toBe("2026-01-31");
    expect(edge.period_end).toBe("2027-01-30");
    expect(edge.prorated).toBe(false);

    // Y el mensual de siempre sigue exactamente igual que antes del ADR:
    // sin columnas nuevas, sin prorrateo, período de un mes calendario.
    const { id: monthlyId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Mensual de siempre",
      price: 1500,
      cycle: "CALENDAR_MONTH",
    });
    const m = await quote(owner, monthlyId!, "2026-09-15");
    expect(m.period_start).toBe("2026-09-01");
    expect(m.period_end).toBe("2026-09-30");
    expect(m.units_total).toBe(1);
    expect(Number(m.prorated_price)).toBe(1500);
    expect(m.prorated).toBe(false);
  });

  it("borde de mes en un ciclo calendario: el último día del período cobra un mes, el primero del siguiente cobra completo", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-edge");
    createdUserIds.push(owner.id);

    const { id: quarterId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral borde",
      price: 3000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });

    const last = await quote(owner, quarterId!, "2026-03-31");
    expect(last.period_start).toBe("2026-01-01");
    expect(last.period_end).toBe("2026-03-31");
    expect(last.units_charged).toBe(1);
    expect(Number(last.prorated_price)).toBe(1000);

    const next = await quote(owner, quarterId!, "2026-04-01");
    expect(next.period_start).toBe("2026-04-01");
    expect(next.period_end).toBe("2026-06-30");
    expect(next.units_charged).toBe(3);
    expect(next.prorated).toBe(false);

    // Un anual anclado en marzo cruza el año: el bloque que contiene al
    // 31-ene-2026 es mar-2025..feb-2026, y quedan 2 meses (ene y feb).
    const { id: annualId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Anual anclado marzo",
      price: 12000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 12,
      anchorMonth: 3,
    });
    const crossing = await quote(owner, annualId!, "2026-01-31");
    expect(crossing.period_start).toBe("2025-03-01");
    expect(crossing.period_end).toBe("2026-02-28");
    expect(crossing.units_charged).toBe(2);
    expect(crossing.units_total).toBe(12);
    expect(Number(crossing.prorated_price)).toBe(2000);

    // Sin anclaje, el ciclo arranca en el mes de la compra: entonces nunca
    // hay nada que prorratear (y el período tampoco se recorta al día).
    const { id: floatingId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral sin anclaje",
      price: 3000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
    });
    const floating = await quote(owner, floatingId!, "2026-09-15");
    expect(floating.period_start).toBe("2026-09-01");
    expect(floating.period_end).toBe("2026-11-30");
    expect(floating.units_charged).toBe(3);
    expect(floating.prorated).toBe(false);
  });

  it("la base rechaza las combinaciones incoherentes de ciclo, meses y anclaje", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-checks");
    createdUserIds.push(owner.id);

    // CALENDAR_PERIOD sin cantidad de meses sería un segundo nombre de
    // CALENDAR_MONTH.
    const noMonths = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Sin meses",
      price: 100,
      cycle: "CALENDAR_PERIOD",
    });
    expect(noMonths.error?.message).toContain("service_plans_billing_period_months_matches_cycle");

    // Y un mensual con cantidad de meses, lo mismo al revés.
    const monthlyWithMonths = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Mensual con meses",
      price: 100,
      cycle: "CALENDAR_MONTH",
      periodMonths: 3,
    });
    expect(monthlyWithMonths.error?.message).toContain("service_plans_billing_period_months_matches_cycle");

    // 5 no divide a 12: los bloques no tapizarían el año y el anclaje
    // dejaría de significar lo que la pantalla promete.
    const fiveMonths = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Cinco meses",
      price: 100,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 5,
      anchorMonth: 1,
    });
    expect(fiveMonths.error?.message).toContain("service_plans_billing_period_months_range");

    // 5 meses SÍ es válido en un ciclo rodante: no se ancla a nada.
    const fiveRolling = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Cinco meses rodante",
      price: 100,
      cycle: "ROLLING_PERIOD",
      periodMonths: 5,
    });
    expect(fiveRolling.error).toBeNull();

    // El anclaje sólo existe en el ciclo calendario largo.
    const anchoredRolling = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Rodante anclado",
      price: 100,
      cycle: "ROLLING_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });
    expect(anchoredRolling.error?.message).toContain("service_plans_billing_anchor_month_matches_cycle");
  });

  it("billing_period_months y billing_anchor_month son inmutables una vez que el plan tiene pagos no-VOID; el precio no", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-immutable");
    createdUserIds.push(owner.id);

    const { id: planId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral con pagos",
      price: 3000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });

    // Sin pagos todavía: se puede corregir.
    const beforeAnyPayment = await owner.client
      .from("service_plans")
      .update({ billing_period_months: 6 })
      .eq("id", planId!);
    expect(beforeAnyPayment.error).toBeNull();
    await owner.client.from("service_plans").update({ billing_period_months: 3 }).eq("id", planId!);

    const { data: customer } = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Cliente trimestral",
      p_phone: null,
    });

    const paid = await payFor(owner, {
      organizationId: org.id,
      customerId: customer!.id,
      serviceId,
      from: "2026-07-01",
      to: "2026-09-30",
      amount: 3000,
      servicePlanId: planId!,
    });
    expect(paid.error).toBeNull();

    const changeMonths = await owner.client
      .from("service_plans")
      .update({ billing_period_months: 12 })
      .eq("id", planId!);
    expect(changeMonths.error?.message).toContain("SERVICE_PLAN_TERMS_IMMUTABLE");

    const changeAnchor = await owner.client
      .from("service_plans")
      .update({ billing_anchor_month: 4 })
      .eq("id", planId!);
    expect(changeAnchor.error?.message).toContain("SERVICE_PLAN_TERMS_IMMUTABLE");

    // El precio sigue libre: sólo afecta cobros futuros y cada Payment
    // guarda el monto que se le cobró (ADR-0024 resolución 5).
    const changePrice = await owner.client
      .from("service_plans")
      .update({ price: 3500 })
      .eq("id", planId!);
    expect(changePrice.error).toBeNull();

    // Y la cotización sigue leyendo los términos en vivo desde el plan.
    const q = await quote(owner, planId!, "2026-08-02");
    expect(Number(q.full_price)).toBe(3500);
    expect(q.units_charged).toBe(2);
  });

  it("el cambio de plan a mitad de trimestre se recarga COMPLETO: la cotización no mira ningún pago", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-planchange");
    createdUserIds.push(owner.id);

    const { id: smallId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral 1x",
      price: 3000,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 1,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });
    const { id: bigId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral 2x",
      price: 5000,
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });

    const { data: customer } = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Cliente que sube de plan",
      p_phone: null,
    });

    // La cotización del plan grande ANTES de que el cliente exista/pague.
    const before = await quote(owner, bigId!, "2026-07-01");

    // El cliente compró el trimestre jul-sep del plan chico.
    const first = await payFor(owner, {
      organizationId: org.id,
      customerId: customer!.id,
      serviceId,
      from: "2026-07-01",
      to: "2026-09-30",
      amount: 3000,
      servicePlanId: smallId!,
    });
    expect(first.error).toBeNull();

    // Cambio de plan a mitad del trimestre: VOID + recargar (ADR-0024
    // resolución 1). El pago nuevo cubre el MISMO trimestre.
    await owner.client.from("payments").update({ status: "VOID" }).eq("id", (first.data as { id: string }).id);

    // Cotizar el plan nuevo para el período que se está recargando: el
    // trimestre entero, sin prorratear. No hay nota de crédito por lo no
    // consumido del plan anterior (resolución 4) ni descuento automático.
    const recharge = await quote(owner, bigId!, "2026-07-01");
    expect(recharge.period_start).toBe("2026-07-01");
    expect(recharge.period_end).toBe("2026-09-30");
    expect(recharge.units_charged).toBe(3);
    expect(recharge.prorated).toBe(false);
    expect(Number(recharge.prorated_price)).toBe(5000);

    // Y es exactamente la misma respuesta que antes de que existiera un
    // solo pago: la función es pura (plan, fecha) -- no puede descontar un
    // cambio de plan ni reconocer lo ya pagado (resolución 3).
    expect(recharge).toEqual(before);

    const second = await payFor(owner, {
      organizationId: org.id,
      customerId: customer!.id,
      serviceId,
      from: "2026-07-01",
      to: "2026-09-30",
      amount: 5000,
      servicePlanId: bigId!,
    });
    expect(second.error).toBeNull();
    expect(Number((second.data as { amount: number }).amount)).toBe(5000);
  });

  it("el crédito de recupero de un plan trimestral vence a fin de MES; el de un mensual sigue venciendo a fin del período pago", async () => {
    // Un crédito que vive tres meses multiplica por tres el riesgo que
    // ADR-0025 dejó anotado como abierto (ADR-0031 resolución 6).
    const quarterly = await setupOrgWithCredits("p31-credit-q", "CALENDAR_PERIOD", 3);
    createdUserIds.push(quarterly.owner.id, quarterly.customer.id);

    expect(quarterly.credit.expires_on).toBe(endOfMonth(quarterly.releasedLocalDate));
    expect(quarterly.credit.expiry_basis).toBe("END_OF_MONTH");
    // La diferencia es observable: el período pago termina mucho después.
    expect(quarterly.credit.expires_on < quarterly.periodEnd).toBe(true);

    // Control: en un plan mensual END_OF_BILLING_PERIOD no cambia nada de
    // lo ya aceptado en ADR-0025.
    const monthly = await setupOrgWithCredits("p31-credit-m", "CALENDAR_MONTH", null);
    createdUserIds.push(monthly.owner.id, monthly.customer.id);

    expect(monthly.credit.expires_on).toBe(monthly.periodEnd);
    expect(monthly.credit.expiry_basis).toBe("END_OF_BILLING_PERIOD");
  }, 30_000);

  it("cotizar es una operación de mostrador: nadie de otra organización puede hacerlo", async () => {
    const { owner, org, serviceId } = await setupOrg("p31-authz");
    createdUserIds.push(owner.id);

    const { id: planId } = await createPlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Trimestral ajeno",
      price: 3000,
      cycle: "CALENDAR_PERIOD",
      periodMonths: 3,
      anchorMonth: 1,
    });

    const stranger = await createSignedInUser("p31-stranger");
    createdUserIds.push(stranger.id);

    const { error } = await stranger.client.rpc("quote_service_plan_period", {
      p_service_plan_id: planId!,
      p_from: "2026-09-15",
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");
  });
});

/**
 * Organización con crédito de recupero encendido y vencimiento
 * END_OF_BILLING_PERIOD, un plan de cuota (trimestral o mensual) pagado con
 * un período largo, una serie y una fecha liberada a tiempo -- que es lo
 * que acuña el crédito (ADR-0025).
 */
async function setupOrgWithCredits(
  prefix: string,
  cycle: "CALENDAR_MONTH" | "CALENDAR_PERIOD",
  periodMonths: number | null,
) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", payment_required: true, created_by: owner.id })
    .select()
    .single();
  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  await owner.client
    .from("organizations")
    .update({
      makeup_credits_enabled: true,
      release_deadline_hours: 12,
      makeup_credit_expiry: "END_OF_BILLING_PERIOD",
    })
    .eq("id", org.id);

  const { id: planId, error: planError } = await createPlan(owner, {
    organizationId: org.id,
    serviceId: service!.id,
    name: `Cuota ${cycle}`,
    price: 3000,
    planKind: "WEEKLY_QUOTA",
    weeklyQuota: 1,
    cycle,
    periodMonths,
    anchorMonth: cycle === "CALENDAR_PERIOD" ? 1 : null,
  });
  expect(planError).toBeNull();

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
      capacity: 5,
      created_by: owner.id,
    })
    .select()
    .single();

  const customer = await createSignedInUser(`${prefix}-cust`);
  const { data: customerRow } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();

  // Un período pago largo y explícito: así "fin del período" y "fin del
  // mes" son fechas distintas y el test puede distinguirlas.
  const periodEnd = isoDate(150);
  const paid = await payFor(owner, {
    organizationId: org.id,
    customerId: customerRow!.id,
    serviceId: service!.id,
    from: isoDate(-2),
    to: periodEnd,
    amount: 3000,
    servicePlanId: planId!,
  });
  expect(paid.error).toBeNull();

  const { error: rbError } = await customer.client.rpc("create_recurring_booking", {
    p_schedule_rule_id: rule!.id,
  });
  expect(rbError).toBeNull();

  const occ = await firstFutureOccurrence(owner, rule!.id);
  const { data: booking } = await owner.client
    .from("bookings")
    .select("id")
    .eq("customer_id", customerRow!.id)
    .eq("slot_occurrence_id", occ.id)
    .single();

  const released = await customer.client.rpc("cancel_booking", { p_booking_id: booking!.id });
  expect(released.data.status).toBe("CANCELLED");

  const { data: credit } = await admin
    .from("makeup_credits")
    .select("expires_on, expiry_basis")
    .eq("source_booking_id", booking!.id)
    .single();
  expect(credit).not.toBeNull();

  return {
    owner,
    customer,
    periodEnd,
    releasedLocalDate: localDate(occ.start_at),
    credit: credit as { expires_on: string; expiry_basis: string },
  };
}
