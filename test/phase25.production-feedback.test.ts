// Integration tests for Phase 25 -- los cinco reportes del primer cliente
// en producción. Requiere un Supabase local corriendo (`npx supabase start`).
//
// Cada test de acá está escrito como "el test que habría atrapado el bug":
// no prueba la corrección, prueba el síntoma que el cliente describió.
//
//   1. "Falta el pago" con el mes al día  -> upcoming_unpaid acotado al
//      período vigente, y el motor confirmado sano (OK para toda fecha
//      dentro del período, incluida la frontera de timezone).
//   2. Dos pagos iguales                  -> PAYMENT_DUPLICATE_PERIOD /
//      PAYMENT_DUPLICATE_OCCURRENCE, el hueco de los pagos no-PAID.
//   3. Un pago de un mes bloquea otro mes -> NO es el EXCLUDE: se prueba
//      explícitamente que meses distintos nunca chocan, y que un plan
//      multi-servicio (ADR-0029) puede cobrarse, que sí estaba roto.
//   4. Liberar cupo sin crédito           -> el interruptor de ADR-0025
//      está en `false` por defecto y nada lo encendía.
//   5. Crédito en cualquier turno         -> ya funcionaba; queda fijado,
//      junto con la RPC que lo hace visible antes de gastarlo.

import { afterAll, describe, expect, it } from "vitest";
import { createClient } from "@supabase/supabase-js";
import {
  admin,
  ANON_KEY,
  SUPABASE_URL,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

function firstOfMonth(offsetMonths = 0): string {
  const d = new Date();
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offsetMonths, 1)).toISOString().slice(0, 10);
}

function lastOfMonth(offsetMonths = 0): string {
  const d = new Date();
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + offsetMonths + 1, 0))
    .toISOString()
    .slice(0, 10);
}

interface Fixture {
  owner: SignedInUser;
  org: { id: string; slug: string };
  service: { id: string };
  resource: { id: string };
  planId: string;
}

async function setupPaidService(
  prefix: string,
  opts: { quota?: number; makeupCredits?: boolean } = {},
): Promise<Fixture> {
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
    weeklyQuota: opts.quota ?? 1,
    price: 1800,
  });

  if (opts.makeupCredits) {
    await owner.client
      .from("organizations")
      .update({ makeup_credits_enabled: true, release_deadline_hours: 12 })
      .eq("id", org.id);
  }

  return { owner, org, service: service as { id: string }, resource: resource as { id: string }, planId };
}

async function createRule(
  f: Fixture,
  weekdayOffset: number,
  localStartTime = "09:00",
  capacity = 5,
): Promise<{ id: string }> {
  const weekday = (new Date().getUTCDay() + weekdayOffset) % 7;
  const { data, error } = await f.owner.client
    .from("schedule_rules")
    .insert({
      organization_id: f.org.id,
      service_id: f.service.id,
      resource_id: f.resource.id,
      weekday,
      local_start_time: localStartTime,
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

describe("Phase 25: feedback del primer cliente en producción", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ============================================================
  // Reporte 1 -- "falta pago" con el mes ya cubierto
  // ============================================================

  it("reporte 1: con el mes en curso pago, una reserva fija NO figura con fechas esperando pago", async () => {
    const f = await setupPaidService("p25-unpaid");
    createdUserIds.push(f.owner.id);

    const rule = await createRule(f, 2);
    const { customer, customerRow } = await enroll(f, "p25-unpaid-cust");
    createdUserIds.push(customer.id);

    // Exactamente el mes en curso: ni un día más.
    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: f.planId,
    });

    await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: rows, error } = await f.owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    expect(error).toBeNull();
    expect(rows).toHaveLength(1);

    const row = rows![0] as {
      upcoming_confirmed: number;
      upcoming_not_generated: number;
      upcoming_unpaid: number;
      upcoming_beyond_period: number;
    };

    // El bug: la ventana rodante son 90 días (ADR-0009) y un pago mensual
    // cubre uno, así que ANTES esto contaba las ~12 fechas de los meses
    // siguientes como impagas y la etiqueta roja "Falta el pago" no se
    // apagaba jamás, ni para alguien al día.
    expect(row.upcoming_unpaid).toBe(0);
    // Siguen existiendo y siguen sin confirmar: no son una deuda, todavía
    // no se facturan.
    expect(row.upcoming_not_generated).toBeGreaterThan(0);
    expect(row.upcoming_beyond_period).toBe(row.upcoming_not_generated);
  });

  it("reporte 1: un cliente que NO pagó el mes en curso SÍ figura con fechas esperando pago", async () => {
    const f = await setupPaidService("p25-really-unpaid");
    createdUserIds.push(f.owner.id);

    const rule = await createRule(f, 2);
    const { customer, customerRow } = await enroll(f, "p25-really-unpaid-cust");
    createdUserIds.push(customer.id);

    await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_customer_id: customerRow.id,
    });

    const { data: rows } = await f.owner.client.rpc("schedule_rule_standing_reservations", {
      p_schedule_rule_id: rule.id,
    });
    const row = rows![0] as { upcoming_unpaid: number; upcoming_beyond_period: number };

    // Acotar el horizonte no puede apagar el aviso real: sin ningún pago,
    // las fechas de este mes son exactamente lo que hay que cobrar.
    expect(row.upcoming_unpaid).toBeGreaterThan(0);
  });

  it("reporte 1: el motor no es el problema -- toda fecha dentro del período cubierto da OK, incluida la frontera de timezone", async () => {
    const f = await setupPaidService("p25-engine");
    createdUserIds.push(f.owner.id);

    // 21:00 en Montevideo del último día del mes es 00:00 UTC del 1 del mes
    // siguiente: si la cobertura se evaluara en UTC, esta clase caería
    // fuera del mes pago (ADR-0014).
    const last = new Date(`${lastOfMonth(0)}T12:00:00Z`);
    const weekday = last.getUTCDay();
    const { data: rule } = await f.owner.client
      .from("schedule_rules")
      .insert({
        organization_id: f.org.id,
        service_id: f.service.id,
        resource_id: f.resource.id,
        weekday,
        local_start_time: "21:00",
        duration_minutes: 60,
        capacity: 5,
        created_by: f.owner.id,
      })
      .select()
      .single();

    const { customer, customerRow } = await enroll(f, "p25-engine-cust");
    createdUserIds.push(customer.id);

    // Plan UNLIMITED a propósito: lo que se prueba acá es la cobertura
    // por fecha, no la cuota. Con un plan de cuota, una reserva suelta da
    // OUTSIDE_PLAN_QUOTA por diseño (ADR-0024) y taparía el resultado.
    const unlimited = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: f.service.id,
      planKind: "UNLIMITED",
      price: 2600,
    });

    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: unlimited,
    });

    const { data: occurrences } = await f.owner.client
      .from("slot_occurrences")
      .select("id, start_at")
      .eq("schedule_rule_id", (rule as { id: string }).id)
      .gte("start_at", new Date().toISOString())
      .lte("start_at", `${lastOfMonth(0)}T23:59:59Z`)
      .order("start_at");

    // Toda ocurrencia cuya fecha LOCAL cae en el mes pago tiene que dar OK,
    // aunque su start_at en UTC ya sea del mes siguiente. Se pregunta por
    // el camino del cliente: evaluate_customer_booking() es un helper
    // interno, revocado de authenticated desde la Fase 19.
    const occurrenceRows = (occurrences ?? []) as { id: string; start_at: string }[];
    expect(occurrenceRows.length).toBeGreaterThan(0);

    for (const occ of occurrenceRows) {
      const { data: canBook } = await customer.client.rpc("can_customer_book", {
        p_slot_occurrence_id: occ.id,
      });
      expect(canBook, `ocurrencia ${occ.start_at}`).toBe("OK");
    }
  });

  // ============================================================
  // Reporte 2 -- pagos duplicados
  // ============================================================

  it("reporte 2: dos pagos PENDING idénticos (mismo cliente, servicio y período) se rechazan", async () => {
    const f = await setupPaidService("p25-dup");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-dup-cust");
    createdUserIds.push(customer.id);

    const base = {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: f.planId,
    };

    const first = await payFor(f.owner, { ...base, status: "PENDING" });
    expect(first.error).toBeNull();

    // El EXCLUDE de ADR-0024 filtra por status = 'PAID', así que ANTES
    // este segundo pendiente entraba sin ninguna protección: dos deudas
    // por el mismo mes, y el que las cobrara cobraba dos veces.
    const second = await payFor(f.owner, { ...base, status: "PENDING" });
    expect(second.error?.message).toContain("PAYMENT_DUPLICATE_PERIOD");

    // Y tampoco se cuela mezclando estados.
    const third = await payFor(f.owner, { ...base, status: "OVERDUE" });
    expect(third.error?.message).toContain("PAYMENT_DUPLICATE_PERIOD");

    // La protección a prueba de carreras de ADR-0024 sigue intacta.
    const paid = await payFor(f.owner, { ...base, status: "PAID" });
    expect(paid.error).not.toBeNull();
  });

  it("reporte 2: bajo concurrencia, de N cargas simultáneas del mismo pago duplicado sólo una entra (TOCTOU check)", async () => {
    // check_payment_no_duplicate() hacía un SELECT sin lock: bajo Read
    // Committed, dos INSERT simultáneos del mismo pago PENDING leen los
    // dos "todavía no hay conflicto" y pasan los dos -- verificado
    // empíricamente con dos transacciones psql concurrentes reales,
    // mismo TOCTOU que ADR-0004 cazó en book_slot(). El fix serializa por
    // Customer con un advisory lock (`pg_advisory_xact_lock(hashtext(...))`)
    // antes del SELECT, así que las inserciones concurrentes se serializan
    // en vez de leer el mismo estado "todavía vacío". Un `select ... for
    // update` real sobre la fila del Customer se probó primero y
    // deadlockeaba: el trigger corre AFTER INSERT, así que el chequeo de FK
    // de payments.customer_id ya sostiene un FOR KEY SHARE sobre esa fila
    // en la misma transacción, y pedir después un FOR UPDATE es un upgrade
    // de lock que, con varias transacciones concurrentes en la misma
    // situación, forma una espera circular.
    const f = await setupPaidService("p25-dup-concurrent");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-dup-concurrent-cust");
    createdUserIds.push(customer.id);

    const base = {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: f.planId,
      status: "PENDING" as const,
    };

    const CONCURRENT_INSERTS = 6;

    const results = await Promise.all(
      Array.from({ length: CONCURRENT_INSERTS }, () => payFor(f.owner, base)),
    );

    const succeeded = results.filter((r) => r.error === null);
    const rejected = results.filter((r) => r.error?.message.includes("PAYMENT_DUPLICATE_PERIOD"));

    expect(succeeded).toHaveLength(1);
    expect(rejected).toHaveLength(CONCURRENT_INSERTS - 1);

    const { count: actualRows } = await admin
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .neq("status", "VOID");
    expect(actualRows).toBe(1);
  });

  it("reporte 2: un pago anulado (VOID) deja volver a cargar el período -- corregir un error de carga sigue siendo posible", async () => {
    const f = await setupPaidService("p25-void");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-void-cust");
    createdUserIds.push(customer.id);

    const base = {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: f.planId,
    };

    const wrong = await payFor(f.owner, { ...base, status: "PENDING", amount: 999 });
    expect(wrong.error).toBeNull();

    await f.owner.client
      .from("payments")
      .update({ status: "VOID" })
      .eq("id", (wrong.data as { id: string }).id);

    const corrected = await payFor(f.owner, { ...base, status: "PAID", amount: 1800 });
    expect(corrected.error).toBeNull();
  });

  it("reporte 2: revivir un pago VOID a PENDING no evade la protección de duplicados", async () => {
    // check_payment_no_duplicate() sólo corría en INSERT: un pago se podía
    // insertar como VOID (aceptado, correcto -- lo prueba el test
    // anterior) y después volver a PENDING vía set_payment_status() o un
    // PATCH directo, dejando un duplicado del mismo período sin que nada
    // lo note. El trigger ahora también corre en UPDATE cuando el estado
    // anterior era VOID.
    const f = await setupPaidService("p25-resurrect");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-resurrect-cust");
    createdUserIds.push(customer.id);

    const base = {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: firstOfMonth(0),
      to: lastOfMonth(0),
      servicePlanId: f.planId,
    };

    // Se inserta directamente como VOID: el trigger no corre para VOID,
    // así que esto entra sin ningún chequeo.
    const voided = await payFor(f.owner, { ...base, status: "VOID" });
    expect(voided.error).toBeNull();

    // El pago real (no duplicado, todavía) del mismo período.
    const real = await payFor(f.owner, { ...base, status: "PENDING" });
    expect(real.error).toBeNull();

    // Revivir el VOID a PENDING ahora choca con el real -- antes del fix,
    // el trigger sólo miraba INSERT y este UPDATE pasaba sin que nada lo
    // rechazara.
    const { error: resurrectError } = await f.owner.client
      .from("payments")
      .update({ status: "PENDING" })
      .eq("id", (voided.data as { id: string }).id);
    expect(resurrectError?.message).toContain("PAYMENT_DUPLICATE_PERIOD");

    // Y una transición normal (PENDING -> PAID) de un pago que nunca fue
    // VOID sigue funcionando: el WHEN no debe tocar este camino.
    const { error: normalTransitionError } = await f.owner.client
      .from("payments")
      .update({ status: "PAID" })
      .eq("id", (real.data as { id: string }).id);
    expect(normalTransitionError).toBeNull();
  });

  it("reporte 2: dos pagos de turno suelto sobre la misma ocurrencia se rechazan aunque no estén PAID (hueco anotado por ADR-0027)", async () => {
    const f = await setupPaidService("p25-dropin");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-dropin-cust");
    createdUserIds.push(customer.id);

    const dropInPlan = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: f.service.id,
      planKind: "DROP_IN",
      price: 800,
    });

    const rule = await createRule(f, 2);
    const occ = await firstFutureOccurrence(f.owner, rule.id);

    const base = {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(0),
      to: isoDate(0),
      servicePlanId: dropInPlan,
      slotOccurrenceId: occ.id,
    };

    const first = await payFor(f.owner, { ...base, status: "PENDING" });
    expect(first.error).toBeNull();

    const second = await payFor(f.owner, { ...base, status: "PENDING" });
    expect(second.error?.message).toContain("PAYMENT_DUPLICATE_OCCURRENCE");
  });

  // ============================================================
  // Reporte 3 -- un pago de un mes bloqueando otro mes
  // ============================================================

  it("reporte 3: un pago del mes en curso NUNCA bloquea uno de otro mes -- el EXCLUDE está acotado al período, no abierto", async () => {
    const f = await setupPaidService("p25-months");
    createdUserIds.push(f.owner.id);
    const { customer, customerRow } = await enroll(f, "p25-months-cust");
    createdUserIds.push(customer.id);

    const at = (offset: number, status: "PAID" | "PENDING") =>
      payFor(f.owner, {
        organizationId: f.org.id,
        customerId: customerRow.id,
        serviceId: f.service.id,
        from: firstOfMonth(offset),
        to: lastOfMonth(offset),
        status,
        servicePlanId: f.planId,
      });

    expect((await at(0, "PAID")).error).toBeNull();
    expect((await at(1, "PENDING")).error).toBeNull();
    expect((await at(2, "PENDING")).error).toBeNull();
    expect((await at(3, "PAID")).error).toBeNull();

    // Y marcar pagado el de un mes distinto tampoco choca con el de este.
    const { data: next } = await f.owner.client
      .from("payments")
      .select("id")
      .eq("customer_id", customerRow.id)
      .eq("period_start", firstOfMonth(1))
      .single();
    const { error: flipError } = await f.owner.client
      .from("payments")
      .update({ status: "PAID" })
      .eq("id", (next as { id: string }).id);
    expect(flipError).toBeNull();
  });

  it("reporte 3: un plan que cubre varios servicios (ADR-0029) puede cobrarse -- antes ningún pago suyo entraba", async () => {
    const owner = await createSignedInUser("p25-multi");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p25-multi-org");

    const mkService = async (name: string) => {
      const { data } = await owner.client
        .from("services")
        .insert({ organization_id: org.id, name, payment_required: true, created_by: owner.id })
        .select()
        .single();
      return data as { id: string };
    };
    const pilates = await mkService("Pilates");
    const yoga = await mkService("Yoga");

    const { data: plan, error: planError } = await owner.client.rpc("create_service_plan", {
      p_organization_id: org.id,
      p_name: "Pase libre",
      p_description: null,
      p_price: 3400,
      p_plan_kind: "UNLIMITED",
      p_weekly_quota: null,
      p_billing_type: "MONTHLY",
      p_billing_cycle: "CALENDAR_MONTH",
      p_sort_order: 0,
      p_applies_to_all_services: true,
      p_service_ids: null,
      p_quota_scope: null,
    });
    expect(planError).toBeNull();

    const cust = await createSignedInUser("p25-multi-cust");
    createdUserIds.push(cust.id);
    const { data: customer } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: cust.id, created_by: owner.id })
      .select()
      .single();

    // service_id va en null a propósito: check_payment_plan_consistency()
    // lo deriva y sólo lo completa si el plan cubre exactamente uno
    // (ADR-0029 §4.1). check_payment_same_org() lo rechazaba por nulo, así
    // que un plan multi-servicio era invendible.
    const { error } = await owner.client.from("payments").insert({
      organization_id: org.id,
      customer_id: (customer as { id: string }).id,
      service_id: null,
      service_plan_id: (plan as { id: string }).id,
      period_start: firstOfMonth(0),
      period_end: lastOfMonth(0),
      status: "PAID",
      amount: 3400,
      created_by: owner.id,
    });
    expect(error).toBeNull();

    // Y cubre los dos servicios, que es todo el punto del plan.
    const { data: coverage } = await admin
      .from("payment_service_coverage")
      .select("service_id")
      .eq("customer_id", (customer as { id: string }).id);
    const covered = (coverage ?? []).map((r: { service_id: string }) => r.service_id).sort();
    expect(covered).toEqual([pilates.id, yoga.id].sort());

    // Y se ve en la pantalla de pagos: un pago invisible es
    // indistinguible de uno que no se registró.
    const { data: detail } = await owner.client.rpc("customer_payment_detail", {
      p_customer_id: (customer as { id: string }).id,
      p_period_start: firstOfMonth(0),
      p_period_end: lastOfMonth(0),
    });
    expect(detail).toHaveLength(1);
    expect((detail as { service_name: string }[])[0]!.service_name).toBe("Pase libre");
  });

  // ============================================================
  // Reporte 4 -- liberar cupo no genera crédito
  // ============================================================

  it("reporte 4: una organización recién creada tiene el crédito de recupero APAGADO, y por eso liberar no emite nada", async () => {
    // Éste es el test que faltaba: todos los de la Fase 20 encienden el
    // interruptor en el setup, así que ninguno notaba que el camino real
    // (crear la organización desde la app) lo deja en false y que nada en
    // el producto lo podía encender.
    const f = await setupPaidService("p25-switch-off"); // sin makeupCredits
    createdUserIds.push(f.owner.id);

    const { data: org } = await f.owner.client
      .from("organizations")
      .select("makeup_credits_enabled")
      .eq("id", f.org.id)
      .single();
    expect((org as { makeup_credits_enabled: boolean }).makeup_credits_enabled).toBe(false);

    const rule = await createRule(f, 2);
    const { customer, customerRow } = await enroll(f, "p25-switch-off-cust");
    createdUserIds.push(customer.id);

    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: f.planId,
    });
    await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const occ = await firstFutureOccurrence(f.owner, rule.id);
    const { data: booking } = await f.owner.client
      .from("bookings")
      .select("id, status")
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id)
      .single();
    expect((booking as { status: string }).status).toBe("CONFIRMED");

    const released = await customer.client.rpc("release_my_booking", {
      p_booking_id: (booking as { id: string }).id,
    });
    expect(released.error).toBeNull();
    expect((released.data as { makeup_credit: unknown }).makeup_credit).toBeNull();

    const { data: credits } = await customer.client.rpc("my_makeup_credits");
    expect(credits).toHaveLength(0);
  });

  it("reporte 4: encendido el interruptor, el mismo flujo de liberar cupo sí emite el crédito", async () => {
    const f = await setupPaidService("p25-switch-on", { makeupCredits: true });
    createdUserIds.push(f.owner.id);

    const rule = await createRule(f, 2);
    const { customer, customerRow } = await enroll(f, "p25-switch-on-cust");
    createdUserIds.push(customer.id);

    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: f.planId,
    });
    await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: rule.id });

    const occ = await firstFutureOccurrence(f.owner, rule.id);
    const { data: booking } = await f.owner.client
      .from("bookings")
      .select("id")
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id)
      .single();

    const released = await customer.client.rpc("release_my_booking", {
      p_booking_id: (booking as { id: string }).id,
    });
    expect(released.error).toBeNull();
    expect((released.data as { makeup_credit: { id: string } | null }).makeup_credit).not.toBeNull();
  });

  // ============================================================
  // Fix de revisión -- el piso de anticipación de liberación es 1, no 0
  // ============================================================

  it("release_deadline_hours no puede ponerse en 0 directo por PostgREST -- el CHECK exige al menos 1h", async () => {
    // updateOrganizationSettings (frontend) valida 1-720, pero organizations
    // es editable directo por el OWNER vía PostgREST
    // (organizations_update_owner, ADR-0013): sin subir el piso del CHECK,
    // un OWNER podía poner 0 sin pasar por el action, dejando la política
    // de ADR-0025 sin sentido (el crédito se emitiría cancelando en la
    // puerta del salón).
    const f = await setupPaidService("p25-deadline-floor");
    createdUserIds.push(f.owner.id);

    const zero = await f.owner.client
      .from("organizations")
      .update({ release_deadline_hours: 0 })
      .eq("id", f.org.id);
    expect(zero.error).not.toBeNull();

    const one = await f.owner.client
      .from("organizations")
      .update({ release_deadline_hours: 1 })
      .eq("id", f.org.id);
    expect(one.error).toBeNull();
  });

  it("services.release_deadline_hours_override tampoco puede ponerse en 0 -- mismo piso que organizations", async () => {
    // El CHECK de Fase 20 (services_release_deadline_hours_override_range)
    // seguía en 0-720 después de que #6 subió el piso de organizations a
    // 1-720 -- el mismo hueco, un nivel más abajo.
    const f = await setupPaidService("p25-deadline-floor-svc");
    createdUserIds.push(f.owner.id);

    const zero = await f.owner.client
      .from("services")
      .update({ release_deadline_hours_override: 0 })
      .eq("id", f.service.id);
    expect(zero.error).not.toBeNull();

    const one = await f.owner.client
      .from("services")
      .update({ release_deadline_hours_override: 1 })
      .eq("id", f.service.id);
    expect(one.error).toBeNull();
  });

  // ============================================================
  // Fix de revisión -- los overrides de política de crédito en services
  // son de OWNER, no de cualquier STAFF
  // ============================================================

  it("un STAFF no puede tocar los overrides de política de crédito de un Service; un OWNER sí", async () => {
    // services_write_staff deja escribir cualquier columna a cualquier
    // member -- correcto para nombre/capacidad/etc, pero estas cuatro
    // columnas son política de negocio (ADR-0025 resolución 3: opt-in
    // explícito del dueño). Sin el trigger, un STAFF con su propio JWT
    // podía prender el crédito de recupero para este Service aunque el
    // OWNER lo tuviera apagado a nivel organización, y vaciar la
    // anticipación con un release_deadline_hours_override en 1.
    const f = await setupPaidService("p25-override-owner");
    createdUserIds.push(f.owner.id);

    const staff = await createSignedInUser("p25-override-owner-staff");
    createdUserIds.push(staff.id);
    await admin.from("organization_members").insert({
      organization_id: f.org.id,
      profile_id: staff.id,
      role: "STAFF",
      created_by: f.owner.id,
    });

    const asStaffEnabled = await staff.client
      .from("services")
      .update({ makeup_credits_enabled_override: true })
      .eq("id", f.service.id);
    expect(asStaffEnabled.error?.message).toContain("NOT_AUTHORIZED");

    const asStaffDeadline = await staff.client
      .from("services")
      .update({ release_deadline_hours_override: 1 })
      .eq("id", f.service.id);
    expect(asStaffDeadline.error?.message).toContain("NOT_AUTHORIZED");

    const asStaffExpiry = await staff.client
      .from("services")
      .update({ makeup_credit_expiry_override: "END_OF_MONTH" })
      .eq("id", f.service.id);
    expect(asStaffExpiry.error?.message).toContain("NOT_AUTHORIZED");

    const asStaffExpiryDays = await staff.client
      .from("services")
      .update({ makeup_credit_expiry_days_override: 5 })
      .eq("id", f.service.id);
    expect(asStaffExpiryDays.error?.message).toContain("NOT_AUTHORIZED");

    // Una columna operativa (no de política) sigue editable por STAFF.
    const asStaffName = await staff.client
      .from("services")
      .update({ name: "Pilates avanzado" })
      .eq("id", f.service.id);
    expect(asStaffName.error).toBeNull();

    const asOwner = await f.owner.client
      .from("services")
      .update({
        makeup_credits_enabled_override: true,
        release_deadline_hours_override: 6,
        makeup_credit_expiry_override: "END_OF_MONTH",
        makeup_credit_expiry_days_override: 5,
      })
      .eq("id", f.service.id);
    expect(asOwner.error).toBeNull();
  });

  // ============================================================
  // Reporte 5 -- el crédito vale para cualquier turno del servicio
  // ============================================================

  it("reporte 5: el crédito sirve para CUALQUIER turno del mismo servicio, no sólo el que se liberó -- y se puede saber antes de gastarlo", async () => {
    const f = await setupPaidService("p25-anyslot", { makeupCredits: true });
    createdUserIds.push(f.owner.id);

    // Dos días de semana distintos: el crédito nace en uno y se usa en el
    // otro, que es literalmente el pedido del cliente.
    const ruleMon = await createRule(f, 2);
    const ruleWed = await createRule(f, 4);

    const { customer, customerRow } = await enroll(f, "p25-anyslot-cust");
    createdUserIds.push(customer.id);

    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: f.planId,
    });
    await customer.client.rpc("create_recurring_booking", { p_schedule_rule_id: ruleMon.id });

    const occMon = await firstFutureOccurrence(f.owner, ruleMon.id);
    const { data: seriesBooking } = await f.owner.client
      .from("bookings")
      .select("id")
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occMon.id)
      .single();

    const released = await customer.client.rpc("release_my_booking", {
      p_booking_id: (seriesBooking as { id: string }).id,
    });
    const credit = (released.data as { makeup_credit: { id: string; expires_on: string } }).makeup_credit;
    expect(credit).not.toBeNull();

    const occWed = await firstFutureOccurrence(f.owner, ruleWed.id);

    // Lo que el portal necesita para avisar ANTES de gastarlo: el motor ya
    // decía OK, pero el crédito viajaba invisible y se consumía en
    // silencio.
    const { data: detail, error: detailError } = await customer.client.rpc("can_customer_book_detail", {
      p_slot_occurrence_id: occWed.id,
    });
    expect(detailError).toBeNull();
    const detailRow = (Array.isArray(detail) ? detail[0] : detail) as {
      reason: string;
      makeup_credit_id: string | null;
      makeup_credit_expires_on: string | null;
    };
    expect(detailRow.reason).toBe("OK");
    expect(detailRow.makeup_credit_id).toBe(credit.id);
    expect(detailRow.makeup_credit_expires_on).toBe(credit.expires_on);

    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occWed.id });
    expect(booked.data.status).toBe("OK");
    expect(booked.data.makeup_credit_id).toBe(credit.id);
  });

  it("reporte 5: un OK que no necesita crédito no informa ninguno -- nunca se gasta si otra cobertura alcanzaba", async () => {
    const f = await setupPaidService("p25-nocredit", { makeupCredits: true });
    createdUserIds.push(f.owner.id);

    const unlimited = await createServicePlan(f.owner, {
      organizationId: f.org.id,
      serviceId: f.service.id,
      planKind: "UNLIMITED",
      price: 2600,
    });

    const rule = await createRule(f, 3);
    const occ = await firstFutureOccurrence(f.owner, rule.id);

    const { customer, customerRow } = await enroll(f, "p25-nocredit-cust");
    createdUserIds.push(customer.id);

    await payFor(f.owner, {
      organizationId: f.org.id,
      customerId: customerRow.id,
      serviceId: f.service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: unlimited,
    });
    await f.owner.client.rpc("grant_manual_makeup_credit", {
      p_customer_id: customerRow.id,
      p_service_id: f.service.id,
      p_expires_on: isoDate(60),
      p_note: "No deberia informarse ni gastarse",
    });

    const { data: detail } = await customer.client.rpc("can_customer_book_detail", {
      p_slot_occurrence_id: occ.id,
    });
    const row = (Array.isArray(detail) ? detail[0] : detail) as {
      reason: string;
      makeup_credit_id: string | null;
    };
    expect(row.reason).toBe("OK");
    expect(row.makeup_credit_id).toBeNull();
  });

  it("can_customer_book_detail es de la sesión: anon no la puede ejecutar (ADR-0028)", async () => {
    const anonClient = createClient(SUPABASE_URL, ANON_KEY);
    const anonResult = await anonClient.rpc("can_customer_book_detail", {
      p_slot_occurrence_id: "00000000-0000-0000-0000-000000000000",
    });
    expect(anonResult.error).not.toBeNull();
  });
});
