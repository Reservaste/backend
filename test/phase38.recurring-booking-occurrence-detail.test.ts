// Integration tests for Phase 38 -- recurring_booking_occurrences(), el
// detalle fecha por fecha de un horario fijo YA ACTIVO (ver comentario en
// la migración de esta fase para por qué no se reusa
// admin_preview_recurring_booking(), que es prospectiva).
//
// El pedido del dueño era doble: (1) el frontend deja de mostrar un badge
// rojo "Falta el pago" pegado a una oración que habla de otra categoría
// de fechas (fix de frontend, sin backend) y (2) poder ver, fecha por
// fecha, qué está confirmado y qué no. Esto prueba (2): que
// recurring_booking_occurrences() devuelve, para una serie real, una fila
// por fecha con el estado real -- y que sumado por categoría coincide
// exactamente con lo que schedule_rule_standing_reservations() (el
// agregado, Fase 25) ya cuenta para esa misma serie. Son dos fuentes que
// tienen que coincidir en total: si divergen, alguna de las dos está mal.
//
// Requiere un Supabase local corriendo (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

interface Fixture {
  owner: SignedInUser;
  org: { id: string; slug: string };
  service: { id: string };
  resource: { id: string };
  planId: string;
}

async function setupWeeklyQuotaService(prefix: string, quota: number): Promise<Fixture> {
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

  const planId = await createServicePlan(owner, {
    organizationId: org.id,
    serviceId: (service as { id: string }).id,
    planKind: "WEEKLY_QUOTA",
    weeklyQuota: quota,
    price: 1800,
  });

  return { owner, org, service: service as { id: string }, resource: resource as { id: string }, planId };
}

/**
 * Un weekday distinto del de hoy, cuya primera ocurrencia futura cae
 * mañana -- weekdayOffset=1 desplaza el weekday de la regla en exactamente
 * un día respecto de hoy, así que la primera ocurrencia que matchea ese
 * weekday es, por construcción, la de mañana (siempre en el futuro, nunca
 * la de hoy). `n` deja crear varias reglas del mismo fixture sin que
 * choquen entre sí (offsets 1..6).
 */
async function createRule(f: Fixture, weekdayOffset: number, capacity = 5): Promise<{ id: string }> {
  const weekday = (new Date().getUTCDay() + weekdayOffset) % 7;
  const { data, error } = await f.owner.client
    .from("schedule_rules")
    .insert({
      organization_id: f.org.id,
      service_id: f.service.id,
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

async function enroll(f: Fixture, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data } = await f.owner.client
    .from("customers")
    .insert({ organization_id: f.org.id, profile_id: customer.id, created_by: f.owner.id })
    .select()
    .single();
  return { customer, customerRow: data as { id: string } };
}

interface AggregateRow {
  recurring_booking_id: string;
  upcoming_confirmed: number;
  upcoming_not_generated: number;
  upcoming_unpaid: number;
  upcoming_over_quota: number;
  upcoming_beyond_period: number;
}

interface OccurrenceRow {
  slot_occurrence_id: string;
  start_at: string;
  display_status: "CONFIRMED" | "UNPAID" | "OVER_QUOTA" | "BEYOND_PERIOD" | "UNAVAILABLE";
  booking_status: "CONFIRMED" | "NOT_GENERATED";
  not_generated_reason: string | null;
}

describe("Phase 38: recurring_booking_occurrences() -- detalle fecha por fecha", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("una serie con CONFIRMED, UNPAID y BEYOND_PERIOD: el detalle fecha por fecha suma igual que el agregado", async () => {
    const f = await setupWeeklyQuotaService("p38-detail", 3);
    createdUserIds.push(f.owner.id);

    const rule = await createRule(f, 1);
    const { customer, customerRow } = await enroll(f, "p38-detail-cust");
    createdUserIds.push(customer.id);

    // Cubre un tramo intermedio (día 6 a 30) sin cubrir HOY -- así
    // customer_billing_horizon() no toma la rama "vigente hoy" y cae a la
    // rama de fallback (fin del mes calendario), que es lo que separa
    // UNPAID (fecha de mañana, sin pago, dentro del horizonte) de
    // BEYOND_PERIOD (fechas más allá del día 30, sin pago, fuera del
    // horizonte) alrededor de la ventana pagada.
    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(6),
      to: isoDate(30),
      servicePlanId: f.planId,
    });

    const { data: rb, error: createError } = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });
    expect(createError).toBeNull();

    const { data: aggregateRows, error: aggregateError } = await f.owner.client.rpc(
      "schedule_rule_standing_reservations",
      { p_schedule_rule_id: rule.id },
    );
    expect(aggregateError).toBeNull();
    const aggregate = (aggregateRows as AggregateRow[]).find((r) => r.recurring_booking_id === rb.id)!;
    expect(aggregate).toBeDefined();

    // El fixture está armado para que, a lo largo de la ventana rodante de
    // 90 días, aparezcan las tres categorías -- si alguna quedara en cero
    // el resto de las aserciones (que comparan detalle vs. agregado)
    // seguirían siendo válidas pero no probarían lo que este test dice
    // probar.
    expect(aggregate.upcoming_confirmed).toBeGreaterThan(0);
    expect(aggregate.upcoming_unpaid).toBeGreaterThan(0);
    expect(aggregate.upcoming_beyond_period).toBeGreaterThan(0);

    const { data: detailRows, error: detailError } = await f.owner.client.rpc("recurring_booking_occurrences", {
      p_recurring_booking_id: rb.id,
    });
    expect(detailError).toBeNull();
    const detail = detailRows as OccurrenceRow[];
    expect(detail.length).toBe(aggregate.upcoming_confirmed + aggregate.upcoming_not_generated);

    const countBy = (status: OccurrenceRow["display_status"]) =>
      detail.filter((r) => r.display_status === status).length;

    expect(countBy("CONFIRMED")).toBe(aggregate.upcoming_confirmed);
    expect(countBy("UNPAID")).toBe(aggregate.upcoming_unpaid);
    expect(countBy("BEYOND_PERIOD")).toBe(aggregate.upcoming_beyond_period);
    expect(countBy("OVER_QUOTA")).toBe(aggregate.upcoming_over_quota);
    expect(countBy("OVER_QUOTA")).toBe(0);

    // Consistencia interna fila por fila: CONFIRMED siempre viene con
    // booking_status CONFIRMED y reason nulo; los otros tres siempre con
    // booking_status NOT_GENERATED.
    for (const row of detail) {
      if (row.display_status === "CONFIRMED") {
        expect(row.booking_status).toBe("CONFIRMED");
        expect(row.not_generated_reason).toBeNull();
      } else {
        expect(row.booking_status).toBe("NOT_GENERATED");
      }
      if (row.display_status === "UNPAID" || row.display_status === "BEYOND_PERIOD") {
        expect(row.not_generated_reason).toBe("PAYMENT_REQUIRED");
      }
    }

    // Ordenado por fecha: el mostrador lo puede pintar tal cual viene.
    const sorted = [...detail].sort((a, b) => a.start_at.localeCompare(b.start_at));
    expect(detail.map((r) => r.slot_occurrence_id)).toEqual(sorted.map((r) => r.slot_occurrence_id));
  });

  it("una segunda serie que excede la cuota del plan: OVER_QUOTA en el detalle, y también UNPAID/BEYOND_PERIOD fuera de la ventana pagada", async () => {
    const f = await setupWeeklyQuotaService("p38-overquota", 1);
    createdUserIds.push(f.owner.id);

    const ruleA = await createRule(f, 1);
    const ruleB = await createRule(f, 3);
    const { customer, customerRow } = await enroll(f, "p38-overquota-cust");
    createdUserIds.push(customer.id);

    // Un único pago, ni cubre hoy ni cubre todo el horizonte -- alcanza
    // para confirmar la primera serie (dentro de la cuota) y para que la
    // segunda, sobre las mismas fechas pagas, quede en OVER_PLAN_QUOTA en
    // vez de en PAYMENT_REQUIRED (evaluate_payment_coverage() sólo llega a
    // mirar la cuota cuando el plan resuelve, y el plan sólo resuelve si
    // hay un Payment PAID que cubre esa fecha puntual).
    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(6),
      to: isoDate(30),
      servicePlanId: f.planId,
    });

    // Series A primero: cuota 1, posición 1 -> dentro de la cuota.
    const { data: rbA, error: errorA } = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ruleA.id,
      p_customer_id: customerRow.id,
    });
    expect(errorA).toBeNull();

    // Series B segunda: misma cuota ya ocupada por A -> posición 2, excede
    // la cuota de 1. admin_create_recurring_booking() no la bloquea al
    // crearla porque el pago no cubre HOY (assert_series_within_plan_quota
    // sólo endurece el gate cuando hay un plan pago vigente hoy mismo).
    const { data: rbB, error: errorB } = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ruleB.id,
      p_customer_id: customerRow.id,
    });
    expect(errorB).toBeNull();

    const { data: aggregateRows } = await f.owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: ruleB.id,
    });
    const aggregateB = (aggregateRows as AggregateRow[]).find((r) => r.recurring_booking_id === rbB.id)!;
    expect(aggregateB).toBeDefined();
    expect(aggregateB.upcoming_over_quota).toBeGreaterThan(0);
    // Nadie de la serie B se confirma: todo lo que caería dentro de la
    // ventana paga lo bloquea la cuota, no el pago.
    expect(aggregateB.upcoming_confirmed).toBe(0);

    const { data: detailRowsB, error: detailErrorB } = await f.owner.client.rpc("recurring_booking_occurrences", {
      p_recurring_booking_id: rbB.id,
    });
    expect(detailErrorB).toBeNull();
    const detailB = detailRowsB as OccurrenceRow[];

    const countByB = (status: OccurrenceRow["display_status"]) =>
      detailB.filter((r) => r.display_status === status).length;

    expect(countByB("OVER_QUOTA")).toBe(aggregateB.upcoming_over_quota);
    expect(countByB("UNPAID")).toBe(aggregateB.upcoming_unpaid);
    expect(countByB("BEYOND_PERIOD")).toBe(aggregateB.upcoming_beyond_period);
    expect(countByB("CONFIRMED")).toBe(0);

    for (const row of detailB) {
      if (row.display_status === "OVER_QUOTA") {
        expect(row.not_generated_reason).toBe("OVER_PLAN_QUOTA");
      }
    }

    // Y la serie A, sobre las mismas fechas pagas, sí quedó CONFIRMED --
    // confirma que lo que distingue a B es la cuota, no el pago en sí.
    const { data: detailRowsA } = await f.owner.client.rpc("recurring_booking_occurrences", {
      p_recurring_booking_id: rbA.id,
    });
    const detailA = detailRowsA as OccurrenceRow[];
    expect(detailA.some((r) => r.display_status === "CONFIRMED")).toBe(true);
  });

  it("un no-miembro de la organización no ve el detalle de una serie ajena", async () => {
    const f = await setupWeeklyQuotaService("p38-notmember", 3);
    createdUserIds.push(f.owner.id);

    const rule = await createRule(f, 1);
    const { customer, customerRow } = await enroll(f, "p38-notmember-cust");
    createdUserIds.push(customer.id);

    const { data: rb } = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const outsider = await createSignedInUser("p38-notmember-outsider");
    createdUserIds.push(outsider.id);

    const { data, error } = await outsider.client.rpc("recurring_booking_occurrences", {
      p_recurring_booking_id: rb.id,
    });
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("un OWNER real de otra organizacion no ve el detalle de una serie ajena, aunque el id sea real y la serie tenga fechas", async () => {
    // Caso mas especifico que "un no-miembro de la organizacion" (arriba):
    // ahi el usuario no pertenece a NINGUNA organizacion. Aca el atacante
    // es un OWNER real de una organizacion distinta -- prueba que el
    // aislamiento es por organizationId, no solo "hace falta ser miembro
    // de algo".
    const orgB = await setupWeeklyQuotaService("p38-crosstenant-b", 3);
    createdUserIds.push(orgB.owner.id);
    const ruleB = await createRule(orgB, 1);
    const { customer: customerB, customerRow: customerRowB } = await enroll(orgB, "p38-crosstenant-b-cust");
    createdUserIds.push(customerB.id);

    const { data: rbB, error: rbError } = await orgB.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ruleB.id,
      p_customer_id: customerRowB.id,
    });
    expect(rbError).toBeNull();

    const orgA = await setupWeeklyQuotaService("p38-crosstenant-a", 3);
    createdUserIds.push(orgA.owner.id);

    // El OWNER de A, con el id real de una serie activa y con fechas de
    // B, no ve nada.
    const { data: dataFromA, error: errorFromA } = await orgA.owner.client.rpc(
      "recurring_booking_occurrences",
      { p_recurring_booking_id: rbB.id },
    );
    expect(errorFromA).toBeNull();
    expect(dataFromA).toEqual([]);

    // Control: el OWNER de B, con ese mismo id, SI ve filas -- confirma
    // que el [] de arriba es aislamiento cross-tenant, no un id mal
    // armado o una serie sin fechas.
    const { data: dataFromB, error: errorFromB } = await orgB.owner.client.rpc(
      "recurring_booking_occurrences",
      { p_recurring_booking_id: rbB.id },
    );
    expect(errorFromB).toBeNull();
    expect((dataFromB as unknown[]).length).toBeGreaterThan(0);
  });

  it("anon no puede ejecutar recurring_booking_occurrences", async () => {
    const f = await setupWeeklyQuotaService("p38-anon", 3);
    createdUserIds.push(f.owner.id);
    const rule = await createRule(f, 1);
    const { customer, customerRow } = await enroll(f, "p38-anon-cust");
    createdUserIds.push(customer.id);

    const { data: rb } = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { createClient } = await import("@supabase/supabase-js");
    const { SUPABASE_URL, ANON_KEY } = await import("./helpers");
    const anonClient = createClient(SUPABASE_URL, ANON_KEY);
    const { error } = await anonClient.rpc("recurring_booking_occurrences", {
      p_recurring_booking_id: rb.id,
    });
    expect(error).not.toBeNull();
  });
});
