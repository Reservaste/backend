// Integration tests for Phase 30: `audit_log` (ADR-0032). Requiere un
// Supabase local corriendo (`npx supabase start`).
//
// Lo que estas pruebas cuidan, en orden de importancia:
// 1. El hecho se registra aunque la escritura NO pase por ninguna RPC
//    (INSERT/UPDATE directo de PostgREST) -- es el hallazgo que decidió el
//    diseño por trigger. Si esto se rompe, el log deja de cubrir justo lo
//    que se pidió auditar.
// 2. El actor es el correcto con un cliente gestionado (profile_id NULL):
//    se audita igual, con el actor del staff. Es la lógica de tres valores
//    que ya causó un bypass de autorización (Fase 19).
// 3. Inmutabilidad y quién lee: `authenticated` no escribe, STAFF no lee,
//    un OWNER no lee el log de otra organización.
// 4. Una cancelación hecha por el propio cliente NO es un hecho de staff.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

interface AuditRow {
  id: string;
  organization_id: string | null;
  actor_id: string | null;
  action: string;
  target_table: string;
  target_id: string;
  metadata: Record<string, unknown>;
  created_at: string;
}

/**
 * La lectura de las aserciones va por service_role (BYPASSRLS): el test
 * verifica el HECHO registrado, no la policy. Las policies tienen sus
 * propios casos más abajo, con clientes autenticados reales.
 */
async function auditFor(targetTable: string, targetId: string): Promise<AuditRow[]> {
  const { data, error } = await admin
    .from("audit_log")
    .select("*")
    .eq("target_table", targetTable)
    .eq("target_id", targetId)
    .order("created_at", { ascending: true });
  if (error) throw new Error(`failed to read audit_log: ${error.message}`);
  return (data ?? []) as AuditRow[];
}

async function setupOrg(prefix: string) {
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
      capacity: 10,
      created_by: owner.id,
    })
    .select()
    .single();

  return { owner, org, serviceId: service!.id as string, ruleId: rule!.id as string };
}

describe("Phase 30: audit_log (ADR-0032)", () => {
  const createdUserIds: string[] = [];

  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceId: string;
  let ruleId: string;
  let planId: string;
  let staff: SignedInUser;
  let managedCustomerId: string;

  beforeAll(async () => {
    const f = await setupOrg("p30");
    owner = f.owner;
    org = f.org;
    serviceId = f.serviceId;
    ruleId = f.ruleId;
    createdUserIds.push(owner.id);

    staff = await createSignedInUser("p30-staff");
    createdUserIds.push(staff.id);
    await admin.from("organization_members").insert({
      organization_id: org.id,
      profile_id: staff.id,
      role: "STAFF",
      created_by: owner.id,
    });

    planId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Pilates mensual",
      planKind: "UNLIMITED",
      price: 2500,
    });

    const { data: managed } = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Cliente Gestionado",
      p_phone: null,
    });
    managedCustomerId = managed!.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ============================================================
  // 1. El hecho se registra sin pasar por ninguna RPC
  // ============================================================

  it("registra el alta de pago aunque sea un INSERT directo de PostgREST", async () => {
    // Exactamente lo que hace frontend/app/actions/billing.ts: insert en
    // `payments`, sin RPC de por medio. Un insert explícito de auditoría
    // dentro de una función no vería nunca esta escritura.
    const { data: payment, error } = await payFor(owner, {
      organizationId: org.id,
      customerId: managedCustomerId,
      serviceId,
      from: isoDate(0),
      to: isoDate(30),
      servicePlanId: planId,
      amount: 2500,
    });
    expect(error).toBeNull();

    const rows = await auditFor("payments", payment!.id as string);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.action).toBe("PAYMENT_CREATED");
    expect(rows[0]!.organization_id).toBe(org.id);
    expect(rows[0]!.actor_id).toBe(owner.id);
    expect(rows[0]!.metadata).toMatchObject({
      customer_id: managedCustomerId,
      service_plan_id: planId,
      status: "PAID",
    });
    // Nunca datos personales: sólo ids, montos y fechas.
    expect(Object.keys(rows[0]!.metadata)).not.toContain("display_name");
  });

  it("registra la anulación de un pago hecha con UPDATE directo, con el from/to", async () => {
    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: managedCustomerId,
      serviceId,
      from: isoDate(60),
      to: isoDate(90),
      servicePlanId: planId,
      status: "PENDING",
    });
    const paymentId = payment!.id as string;

    // El camino real de voidPayment(): UPDATE de PostgREST, no RPC.
    const { error } = await owner.client
      .from("payments")
      .update({ status: "VOID" })
      .eq("id", paymentId);
    expect(error).toBeNull();

    const rows = await auditFor("payments", paymentId);
    expect(rows.map((r) => r.action)).toEqual(["PAYMENT_CREATED", "PAYMENT_STATUS_CHANGED"]);
    expect(rows[1]!.metadata.status).toEqual({ from: "PENDING", to: "VOID" });
    expect(rows[1]!.actor_id).toBe(owner.id);
  });

  it("no registra un UPDATE de pago que no cambia el estado", async () => {
    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: managedCustomerId,
      serviceId,
      from: isoDate(120),
      to: isoDate(150),
      servicePlanId: planId,
      status: "PENDING",
    });
    const paymentId = payment!.id as string;

    await owner.client.from("payments").update({ notes: "cobrado en efectivo" }).eq("id", paymentId);

    const rows = await auditFor("payments", paymentId);
    expect(rows.map((r) => r.action)).toEqual(["PAYMENT_CREATED"]);
  });

  it("registra el cambio de precio y la desactivación de un plan (dos UPDATE directos, dos hechos)", async () => {
    const localPlanId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Plan a retocar",
      planKind: "UNLIMITED",
      price: 2500,
    });

    // create_service_plan() sí es RPC, pero el alta se audita igual.
    let rows = await auditFor("service_plans", localPlanId);
    expect(rows.map((r) => r.action)).toEqual(["SERVICE_PLAN_CREATED"]);

    // Los dos caminos de service-plans.ts: UPDATE directo de PostgREST.
    await owner.client
      .from("service_plans")
      .update({ price: 3400, name: "Plan retocado" })
      .eq("id", localPlanId);
    await owner.client.from("service_plans").update({ is_active: false }).eq("id", localPlanId);

    rows = await auditFor("service_plans", localPlanId);
    expect(rows.map((r) => r.action)).toEqual([
      "SERVICE_PLAN_CREATED",
      "SERVICE_PLAN_UPDATED",
      "SERVICE_PLAN_DEACTIVATED",
    ]);
    expect(rows[1]!.metadata.price).toEqual({ from: 2500, to: 3400 });
    expect(rows[1]!.metadata.name).toEqual({ from: "Plan a retocar", to: "Plan retocado" });
    expect(rows[2]!.metadata.is_active).toEqual({ from: true, to: false });
  });

  // ============================================================
  // 2. El actor con cliente gestionado (profile_id NULL)
  // ============================================================

  it("audita la reserva de mostrador de un cliente gestionado con el actor del staff", async () => {
    // profile_id es NULL (ADR-0026): con `<>` en vez de `is distinct from`
    // la comparación daría NULL, el `if` no entraría y este hecho -- que
    // por definición lo hizo el mostrador -- no quedaría registrado.
    const { data: managedRow } = await admin
      .from("customers")
      .select("profile_id")
      .eq("id", managedCustomerId)
      .single();
    expect(managedRow!.profile_id).toBeNull();

    const occ = await firstFutureOccurrence(owner, ruleId);
    const booked = await staff.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: managedCustomerId,
    });
    expect(booked.data.status).toBe("OK");
    const bookingId = booked.data.booking.id as string;

    let rows = await auditFor("bookings", bookingId);
    expect(rows.map((r) => r.action)).toEqual(["BOOKING_CREATED_BY_STAFF"]);
    expect(rows[0]!.actor_id).toBe(staff.id);
    expect(rows[0]!.metadata).toMatchObject({
      customer_id: managedCustomerId,
      slot_occurrence_id: occ.id,
    });

    // Y la cancelación desde el mostrador, también con el actor del staff.
    const cancelled = await staff.client.rpc("cancel_booking", { p_booking_id: bookingId });
    expect(cancelled.data.status).toBe("CANCELLED");

    rows = await auditFor("bookings", bookingId);
    expect(rows.map((r) => r.action)).toEqual([
      "BOOKING_CREATED_BY_STAFF",
      "BOOKING_CANCELLED_BY_STAFF",
    ]);
    expect(rows[1]!.actor_id).toBe(staff.id);
    expect(rows[1]!.metadata.status).toEqual({ from: "CONFIRMED", to: "CANCELLED" });
  });

  // ============================================================
  // 3. Lo que NO es un hecho de staff
  // ============================================================

  it("una reserva y una cancelación hechas por el propio cliente no generan ninguna fila", async () => {
    const customer = await createSignedInUser("p30-self");
    createdUserIds.push(customer.id);
    const { error: enrollErr } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id });
    expect(enrollErr).toBeNull();

    const occ = await firstFutureOccurrence(owner, ruleId);
    const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(booked.data.status).toBe("OK");
    const bookingId = booked.data.booking.id as string;

    expect(await auditFor("bookings", bookingId)).toHaveLength(0);

    const cancelled = await customer.client.rpc("cancel_booking", { p_booking_id: bookingId });
    expect(cancelled.data.status).toBe("CANCELLED");

    // Lo importante: ni una fila de BOOKING_CANCELLED_BY_STAFF. El cliente
    // no es staff, y su propia cancelación ya vive en la Booking
    // (cancelled_at/cancelled_by, ADR-0010).
    const rows = await auditFor("bookings", bookingId);
    expect(rows).toHaveLength(0);
  });

  // ============================================================
  // 4. Inmutabilidad
  // ============================================================

  it("`authenticated` no puede insertar, actualizar ni borrar filas de audit_log", async () => {
    const { data: existing } = await admin
      .from("audit_log")
      .select("id")
      .eq("organization_id", org.id)
      .limit(1);
    const existingId = existing![0]!.id as string;

    // INSERT: no hay policy de escritura y el grant está revocado.
    const inserted = await owner.client.from("audit_log").insert({
      organization_id: org.id,
      action: "PAYMENT_CREATED",
      target_table: "payments",
      target_id: existingId,
      metadata: {},
    });
    expect(inserted.error).not.toBeNull();

    // UPDATE: el OWNER sí ve la fila (policy de SELECT), así que el
    // rechazo tiene que venir del permiso/trigger, no de "no la encuentra".
    const updated = await owner.client
      .from("audit_log")
      .update({ metadata: { tampered: true } })
      .eq("id", existingId);
    expect(updated.error).not.toBeNull();

    const deleted = await owner.client.from("audit_log").delete().eq("id", existingId);
    expect(deleted.error).not.toBeNull();

    const { data: after } = await admin
      .from("audit_log")
      .select("id, metadata")
      .eq("id", existingId)
      .single();
    expect(after).not.toBeNull();
    expect((after!.metadata as Record<string, unknown>).tampered).toBeUndefined();
  });

  it("ni el service_role puede actualizar o borrar una fila: el trigger no exceptúa a nadie", async () => {
    const { data: existing } = await admin
      .from("audit_log")
      .select("id")
      .eq("organization_id", org.id)
      .limit(1);
    const existingId = existing![0]!.id as string;

    const updated = await admin
      .from("audit_log")
      .update({ metadata: { tampered: true } })
      .eq("id", existingId);
    expect(updated.error?.message).toContain("AUDIT_LOG_IMMUTABLE");

    const deleted = await admin.from("audit_log").delete().eq("id", existingId);
    expect(deleted.error?.message).toContain("AUDIT_LOG_IMMUTABLE");
  });

  // ============================================================
  // 5. Quién lee
  // ============================================================

  it("un STAFF no lee nada: ni la tabla ni la función", async () => {
    const { data, error } = await staff.client
      .from("audit_log")
      .select("id")
      .eq("organization_id", org.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);

    const rpc = await staff.client.rpc("organization_audit_log", { p_organization_id: org.id });
    expect(rpc.error?.message).toContain("NOT_AUTHORIZED");
  });

  it("un OWNER lee su log y no el de otra organización", async () => {
    const otherFixture = await setupOrg("p30-other");
    createdUserIds.push(otherFixture.owner.id);
    const otherPlan = await createServicePlan(otherFixture.owner, {
      organizationId: otherFixture.org.id,
      serviceId: otherFixture.serviceId,
      name: "Plan ajeno",
      planKind: "UNLIMITED",
      price: 1000,
    });

    // El log ajeno existe...
    expect(await auditFor("service_plans", otherPlan)).toHaveLength(1);

    // ...y no se ve desde acá, ni por la tabla ni por la función.
    const leak = await owner.client
      .from("audit_log")
      .select("id")
      .eq("organization_id", otherFixture.org.id);
    expect(leak.error).toBeNull();
    expect(leak.data).toEqual([]);

    const rpcLeak = await owner.client.rpc("organization_audit_log", {
      p_organization_id: otherFixture.org.id,
    });
    expect(rpcLeak.error?.message).toContain("NOT_AUTHORIZED");

    // Su propio log sí, con el nombre del actor resuelto cuando es del equipo.
    const mine = await owner.client.rpc("organization_audit_log", { p_organization_id: org.id });
    expect(mine.error).toBeNull();
    const rows = mine.data as Array<Record<string, unknown>>;
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.every((r) => r.target_table !== null)).toBe(true);
    const byStaff = rows.find((r) => r.actor_id === staff.id);
    expect(byStaff).toBeDefined();
    expect(byStaff!.actor_is_platform).toBe(false);
  });

  // ============================================================
  // 6. Suscripción de la organización + el contexto opcional de la RPC
  // ============================================================

  it("audita el cambio de suscripción con la nota de la RPC, y el OWNER lo ve sin la identidad del actor de plataforma", async () => {
    const platformOwner = await createSignedInUser("p30-platform");
    createdUserIds.push(platformOwner.id);
    await admin.from("platform_admins").insert({ profile_id: platformOwner.id, note: "test" });

    const res = await platformOwner.client.rpc("set_organization_subscription", {
      p_organization_id: org.id,
      p_plan_code: "full",
      p_status: "SUSPENDED",
    });
    expect(res.error).toBeNull();

    const rows = await auditFor("organizations", org.id);
    expect(rows.length).toBeGreaterThan(0);
    const last = rows[rows.length - 1]!;
    expect(last.action).toBe("ORGANIZATION_SUBSCRIPTION_CHANGED");
    expect(last.actor_id).toBe(platformOwner.id);
    // app.audit_note es opcional; cuando la RPC la setea, viaja en metadata.
    expect(last.metadata.note).toBe("PLATFORM_CONSOLE");
    expect(last.metadata.subscription_status).toMatchObject({ to: "SUSPENDED" });

    // ADR-0032 resolución 2: el dueño ve QUE pasó y CUÁNDO, no quién de
    // nuestro lado lo hizo.
    const asOwner = await owner.client.rpc("organization_audit_log", {
      p_organization_id: org.id,
    });
    expect(asOwner.error).toBeNull();
    const seen = (asOwner.data as Array<Record<string, unknown>>).find(
      (r) => r.action === "ORGANIZATION_SUBSCRIPTION_CHANGED",
    );
    expect(seen).toBeDefined();
    expect(seen!.actor_id).toBeNull();
    expect(seen!.actor_name).toBeNull();
    expect(seen!.actor_is_platform).toBe(true);

    // El platform admin sí ve el actor completo.
    const asPlatform = await platformOwner.client.rpc("organization_audit_log", {
      p_organization_id: org.id,
    });
    const seenByPlatform = (asPlatform.data as Array<Record<string, unknown>>).find(
      (r) => r.action === "ORGANIZATION_SUBSCRIPTION_CHANGED",
    );
    expect(seenByPlatform!.actor_id).toBe(platformOwner.id);
    expect(seenByPlatform!.actor_is_platform).toBe(false);

    // La nota es local a la transacción de la RPC: el siguiente hecho, en
    // otra transacción, no la arrastra.
    const { data: payment } = await payFor(owner, {
      organizationId: org.id,
      customerId: managedCustomerId,
      serviceId,
      from: isoDate(200),
      to: isoDate(230),
      servicePlanId: planId,
      status: "PENDING",
    });
    const paymentRows = await auditFor("payments", payment!.id as string);
    expect(paymentRows[0]!.metadata.note).toBeUndefined();
  });

  // ============================================================
  // 7. Lo que queda fuera de alcance a propósito
  // ============================================================

  it("las fechas de una serie no generan una fila por semana", async () => {
    // El job de horizonte (ADR-0009) materializa una Booking por fecha por
    // serie: auditarlas multiplicaría el volumen del log por dos órdenes de
    // magnitud sin registrar ninguna decisión nueva. El alta de la serie
    // vive en `recurring_bookings`.
    // Organización propia: el caso de suscripción de más arriba deja la
    // principal SUSPENDED, y una organización suspendida no acepta altas.
    const f = await setupOrg("p30-series");
    createdUserIds.push(f.owner.id);

    const customer = await createSignedInUser("p30-series-customer");
    createdUserIds.push(customer.id);
    const { data: customerRow, error: customerErr } = await f.owner.client
      .from("customers")
      .insert({ organization_id: f.org.id, profile_id: customer.id, created_by: f.owner.id })
      .select()
      .single();
    expect(customerErr).toBeNull();

    const created = await f.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: f.ruleId,
      p_customer_id: customerRow!.id,
    });
    expect(created.error).toBeNull();

    const { data: seriesBookings } = await admin
      .from("bookings")
      .select("id")
      .eq("customer_id", customerRow!.id)
      .not("recurring_booking_id", "is", null);
    expect((seriesBookings ?? []).length).toBeGreaterThan(0);

    for (const b of seriesBookings ?? []) {
      expect(await auditFor("bookings", b.id as string)).toHaveLength(0);
    }
  });
});
