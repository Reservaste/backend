// Integration tests for Phase 45 (ADR-0047): reserva abierta -- alta de
// Customer en el momento de reservar, detras de organizations.
// open_booking_enabled. Requires the Supabase project configured via
// SUPABASE_URL/SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY (see
// test/helpers.ts) with this phase's migration already applied.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  type SignedInUser,
} from "./helpers";

async function setupOrgWithService(prefix: string, paymentRequired: boolean, planCode = "full") {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`, planCode);

  const { data: service } = await owner.client
    .from("services")
    .insert({
      organization_id: org.id,
      name: "Consulta",
      payment_required: paymentRequired,
      created_by: owner.id,
    })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  return { owner, org, service: service! as { id: string }, resource: resource! as { id: string } };
}

async function createRule(
  owner: SignedInUser,
  org: { id: string },
  service: { id: string },
  resource: { id: string },
  weekdayOffset: number,
  capacity: number,
) {
  const weekday = (new Date().getUTCDay() + weekdayOffset) % 7;
  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service.id,
      resource_id: resource.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity,
      created_by: owner.id,
    })
    .select()
    .single();
  return rule! as { id: string };
}

async function enableOpenBooking(owner: SignedInUser, org: { id: string }) {
  const { error } = await owner.client
    .from("organizations")
    .update({ open_booking_enabled: true })
    .eq("id", org.id);
  expect(error).toBeNull();
}

/** Enrolls an existing signed-in user as a normal (STAFF-enrolled) Customer. */
async function enroll(owner: SignedInUser, org: { id: string }, customer: SignedInUser) {
  const { data: row, error } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  expect(error).toBeNull();
  return row! as { id: string; source: string; is_active: boolean };
}

/**
 * A throwaway Organization with no owner/invite machinery, only to host
 * filler rows. Bypassing create_organization_with_owner() also bypasses its
 * subscription setup, and organizations.subscription_status defaults to
 * 'SUSPENDED' (Phase 10) -- left at the default, the customers_plan_limit
 * trigger's organization_can_operate() check would reject every filler
 * Customer insert with SUBSCRIPTION_INACTIVE, which has nothing to do with
 * this test's rate-limit assertion. ACTIVE (no plan_code) matches what
 * every other passing fixture in this file gets via createOrganization().
 */
async function createBareOrganization(slugPrefix: string) {
  const slug = `${slugPrefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const { data, error } = await admin
    .from("organizations")
    .insert({ slug, name: slug, subscription_status: "ACTIVE" })
    .select()
    .single();
  if (error || !data) throw new Error(`failed to create bare organization ${slug}: ${error?.message}`);
  return data as { id: string };
}

async function countCustomers(orgId: string, profileId: string | null): Promise<number> {
  let query = admin
    .from("customers")
    .select("id", { count: "exact", head: true })
    .eq("organization_id", orgId);
  query = profileId === null ? query.is("profile_id", null) : query.eq("profile_id", profileId);
  const { count } = await query;
  return count ?? 0;
}

describe("Phase 45: reserva abierta (ADR-0047)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("(a) flag apagado (default): NOT_A_CUSTOMER identico a hoy, tanto en can_customer_book como en book_slot -- no crea nada", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-a", false);
    createdUserIds.push(owner.id);
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const customer = await createSignedInUser("p45-a-cust");
    createdUserIds.push(customer.id);

    const { data: reason, error: reasonError } = await customer.client.rpc("can_customer_book", {
      p_slot_occurrence_id: occ.id,
    });
    expect(reasonError).toBeNull();
    expect(reason).toBe("NOT_A_CUSTOMER");

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("NOT_A_CUSTOMER");

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(b) flag prendido: una cuenta sin Customer reserva exitosamente -- queda un Customer nuevo source=SELF_SERVICE y la Booking CONFIRMED", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-b", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 2, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const customer = await createSignedInUser("p45-b-cust");
    createdUserIds.push(customer.id);

    const { data: reason, error: reasonError } = await customer.client.rpc("can_customer_book", {
      p_slot_occurrence_id: occ.id,
    });
    expect(reasonError).toBeNull();
    expect(reason).toBe("OK_OPEN_BOOKING");

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("OK");
    expect(data.booking.status).toBe("CONFIRMED");

    const { data: rows } = await admin
      .from("customers")
      .select("id, profile_id, source, is_active, organization_id")
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id);
    expect(rows).toHaveLength(1);
    expect(rows![0]!.source).toBe("SELF_SERVICE");
    expect(rows![0]!.is_active).toBe(true);
    expect(data.booking.customer_id).toBe(rows![0]!.id);
  });

  it("(c) si la reserva falla despues del alta (SLOT_FULL), el Customer NO queda huerfano -- rollback completo", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-c", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 3, 1); // capacity 1
    const occ = await firstFutureOccurrence(owner, rule.id);

    // Llena el unico cupo con un cliente ya enrolado de siempre (STAFF).
    const filler = await createSignedInUser("p45-c-filler");
    createdUserIds.push(filler.id);
    await enroll(owner, org, filler);
    const { data: fillData, error: fillError } = await filler.client.rpc("book_slot", {
      p_slot_occurrence_id: occ.id,
    });
    expect(fillError).toBeNull();
    expect(fillData.status).toBe("OK");

    const customer = await createSignedInUser("p45-c-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("SLOT_FULL");

    // La pieza critica de ADR-0047: el rollback de la reserva fallida se
    // lleva puesto el alta -- cero filas, no una fila huerfana.
    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(d) un Customer INACTIVO con ese profile_id NO se reactiva -- sigue sin poder reservar, ni via can_customer_book ni via book_slot", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-d", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 4, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const customer = await createSignedInUser("p45-d-cust");
    createdUserIds.push(customer.id);
    const customerRow = await enroll(owner, org, customer);
    // El staff da de baja al cliente (mismo shape que cancel_customer()).
    const { error: cancelError } = await owner.client
      .from("customers")
      .update({
        is_active: false,
        cancelled_at: new Date().toISOString(),
        cancelled_by: owner.id,
        cancellation_reason: "ORGANIZATION_REMOVED",
      })
      .eq("id", customerRow.id);
    expect(cancelError).toBeNull();

    const { data: reason, error: reasonError } = await customer.client.rpc("can_customer_book", {
      p_slot_occurrence_id: occ.id,
    });
    expect(reasonError).toBeNull();
    expect(reason).toBe("NOT_A_CUSTOMER");

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("NOT_A_CUSTOMER");

    const { count } = await admin
      .from("customers")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id);
    expect(count).toBe(1); // sigue siendo la misma fila inactiva, nunca una segunda.

    const { data: stillInactive } = await admin
      .from("customers")
      .select("is_active")
      .eq("id", customerRow.id)
      .single();
    expect(stillInactive!.is_active).toBe(false);
  });

  it("(e) concurrencia: dos reservas simultaneas del mismo auth.uid() sin Customer previo, en ocurrencias DISTINTAS, no duplican el Customer", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-e", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule1 = await createRule(owner, org, service, resource, 1, 5);
    const rule2 = await createRule(owner, org, service, resource, 4, 5);
    const occ1 = await firstFutureOccurrence(owner, rule1.id);
    const occ2 = await firstFutureOccurrence(owner, rule2.id);

    const customer = await createSignedInUser("p45-e-cust");
    createdUserIds.push(customer.id);

    const [res1, res2] = await Promise.all([
      customer.client.rpc("book_slot", { p_slot_occurrence_id: occ1.id }),
      customer.client.rpc("book_slot", { p_slot_occurrence_id: occ2.id }),
    ]);
    expect(res1.error).toBeNull();
    expect(res2.error).toBeNull();
    expect(res1.data.status).toBe("OK");
    expect(res2.data.status).toBe("OK");

    expect(await countCustomers(org.id, customer.id)).toBe(1);

    const { count: bookingCount } = await admin
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org.id)
      .in("slot_occurrence_id", [occ1.id, occ2.id])
      .eq("status", "CONFIRMED");
    expect(bookingCount).toBe(2);
  });

  it("(f) rate limit diario por auth.uid() (global, no por organizacion): 5 altas SELF_SERVICE en 24h agotan el cupo", async () => {
    const customer = await createSignedInUser("p45-f-cust");
    createdUserIds.push(customer.id);

    // 5 altas SELF_SERVICE "de relleno" repartidas en 5 organizaciones
    // distintas -- el limite diario es por auth.uid(), no por
    // organizacion, asi que no hace falta que compartan tenant.
    for (let i = 0; i < 5; i++) {
      const fillerOrg = await createBareOrganization(`p45-f-filler-${i}`);
      const { error } = await admin.from("customers").insert({
        organization_id: fillerOrg.id,
        profile_id: customer.id,
        display_name: "Relleno",
        is_active: true,
        source: "SELF_SERVICE",
      });
      expect(error).toBeNull();
    }

    const { owner, org, service, resource } = await setupOrgWithService("p45-f", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 2, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("RATE_LIMITED_DAILY");

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(g) rate limit horario por organizacion: 10 altas SELF_SERVICE en la ultima hora agotan el cupo de ESA organizacion (bajado de 50 a 10 en la correccion post-gate)", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-g", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 3, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    // 10 filas de relleno con profile_id null (customers_identity_or_name
    // exige display_name en ese caso) -- el limite horario cuenta
    // cualquier alta SELF_SERVICE de la organizacion, sin importar quien.
    // unique(organization_id, profile_id) no las rechaza: varios NULL no
    // colisionan entre si.
    const fillers = Array.from({ length: 10 }, (_, i) => ({
      organization_id: org.id,
      profile_id: null,
      display_name: `Relleno ${i}`,
      is_active: true,
      source: "SELF_SERVICE",
    }));
    const { error: fillError } = await admin.from("customers").insert(fillers);
    expect(fillError).toBeNull();

    const customer = await createSignedInUser("p45-g-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("RATE_LIMITED_HOURLY");

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(g2) rate limit diario por organizacion (nuevo en la correccion post-gate): 30 altas SELF_SERVICE en las ultimas 24h, pero fuera de la ventana horaria, agotan el cupo diario de ESA organizacion", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-g2", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 3, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    // 30 filas de relleno con created_at hace 2 horas -- fuera de la
    // ventana horaria (1h) para no confundirse con (g), pero dentro de la
    // ventana diaria (24h). Sin esto el tope horario (10) dispararia
    // primero y esta prueba no aislaria el contador diario nuevo.
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
    const fillers = Array.from({ length: 30 }, (_, i) => ({
      organization_id: org.id,
      profile_id: null,
      display_name: `Relleno diario ${i}`,
      is_active: true,
      source: "SELF_SERVICE",
      created_at: twoHoursAgo,
    }));
    const { error: fillError } = await admin.from("customers").insert(fillers);
    expect(fillError).toBeNull();

    const customer = await createSignedInUser("p45-g2-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("RATE_LIMITED_DAILY");

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(h) CRITICO: preview_recurring_booking() con el flag prendido y sin Customer previo NO crea ningun Customer -- es solo lectura", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-h", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 1, 5);

    const customer = await createSignedInUser("p45-h-cust");
    createdUserIds.push(customer.id);

    const before = await countCustomers(org.id, customer.id);
    expect(before).toBe(0);

    const { data: preview, error } = await customer.client.rpc("preview_recurring_booking", {
      p_schedule_rule_id: rule.id,
      p_count: 5,
    });
    expect(error).toBeNull();
    expect(preview!.length).toBeGreaterThan(0);
    // preview_recurring_booking() resuelve la identidad del cliente por su
    // cuenta (no pasa por can_customer_book()), sin cambios en esta fase --
    // sigue devolviendo NOT_A_CUSTOMER. La propiedad bajo prueba aca no es
    // el reason en si, es que no haya NINGUN side-effect.
    for (const row of preview as Array<{ can_book: string }>) {
      expect(row.can_book).toBe("NOT_A_CUSTOMER");
    }

    const after = await countCustomers(org.id, customer.id);
    expect(after).toBe(0);
  });

  it("(i) un Customer ya activo (alta de mostrador de siempre) reserva exactamente igual, el flag no le cambia nada", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-i", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 5, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const customer = await createSignedInUser("p45-i-cust");
    createdUserIds.push(customer.id);
    const customerRow = await enroll(owner, org, customer);
    expect(customerRow.source).toBe("STAFF");

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("OK");
    expect(data.booking.customer_id).toBe(customerRow.id);

    const { data: refreshed } = await admin
      .from("customers")
      .select("source")
      .eq("id", customerRow.id)
      .single();
    expect(refreshed!.source).toBe("STAFF");
  });

  // ============================================================
  // Correccion post-gate de seguridad (docs/decisions.md, ADR-0047
  // "Correccion post-gate de seguridad"): tests nuevos para los 2 ALTO y
  // el MEDIO. (g2) de arriba tambien es parte de esta correccion.
  // ============================================================

  it("(j) fix ALTO #1: tope de 2 reservas CONFIRMED futuras para un Customer SELF_SERVICE -- la 3ra se rechaza, y el staff la destraba pasando source a STAFF", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-j", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule1 = await createRule(owner, org, service, resource, 1, 5);
    const rule2 = await createRule(owner, org, service, resource, 2, 5);
    const rule3 = await createRule(owner, org, service, resource, 3, 5);
    const occ1 = await firstFutureOccurrence(owner, rule1.id);
    const occ2 = await firstFutureOccurrence(owner, rule2.id);
    const occ3 = await firstFutureOccurrence(owner, rule3.id);

    const customer = await createSignedInUser("p45-j-cust");
    createdUserIds.push(customer.id);

    const first = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ1.id });
    expect(first.error).toBeNull();
    expect(first.data.status).toBe("OK");

    const second = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ2.id });
    expect(second.error).toBeNull();
    expect(second.data.status).toBe("OK");

    const third = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ3.id });
    expect(third.error).toBeNull();
    expect(third.data.status).toBe("SELF_SERVICE_BOOKING_LIMIT_REACHED");

    const { data: customerRow } = await admin
      .from("customers")
      .select("id, source")
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id)
      .single();
    expect(customerRow!.source).toBe("SELF_SERVICE");

    // El staff "verifica" al cliente -- UPDATE directo de source, via la
    // policy customers_update_staff que ya existia, sin RPC nueva.
    const { error: verifyError } = await owner.client
      .from("customers")
      .update({ source: "STAFF" })
      .eq("id", customerRow!.id);
    expect(verifyError).toBeNull();

    // Desde ahi el tope deja de aplicarle -- la misma ocurrencia que antes
    // rebotaba ahora se confirma.
    const afterVerify = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ3.id });
    expect(afterVerify.error).toBeNull();
    expect(afterVerify.data.status).toBe("OK");
  });

  it("(k) fix ALTO #1: create_recurring_booking() rechaza de entrada a un Customer SELF_SERVICE -- el staff lo destraba igual que el tope de reservas", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-k", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const customer = await createSignedInUser("p45-k-cust");
    createdUserIds.push(customer.id);

    // Alta on-the-fly via una reserva suelta primero -- deja source=SELF_SERVICE.
    const { data: bookData, error: bookError } = await customer.client.rpc("book_slot", {
      p_slot_occurrence_id: occ.id,
    });
    expect(bookError).toBeNull();
    expect(bookData.status).toBe("OK");

    const { data: customerRow } = await admin
      .from("customers")
      .select("id, source")
      .eq("organization_id", org.id)
      .eq("profile_id", customer.id)
      .single();
    expect(customerRow!.source).toBe("SELF_SERVICE");

    const { error: recurringError } = await customer.client.rpc("create_recurring_booking", {
      p_schedule_rule_id: rule.id,
    });
    expect(recurringError).not.toBeNull();
    expect(recurringError!.message).toMatch(/SELF_SERVICE_CANNOT_CREATE_RECURRING/);

    // El staff lo verifica -- desde ahi puede armar la serie normalmente.
    const { error: verifyError } = await owner.client
      .from("customers")
      .update({ source: "STAFF" })
      .eq("id", customerRow!.id);
    expect(verifyError).toBeNull();

    const { data: rb, error: rbError } = await customer.client.rpc("create_recurring_booking", {
      p_schedule_rule_id: rule.id,
    });
    expect(rbError).toBeNull();
    expect((rb as { id: string }).id).toBeDefined();
  });

  it("(l) fix ALTO #2: PLAN_LIMIT_REACHED del trigger de planes (Fase 10) no filtra el detalle crudo del alta on-the-fly -- book_slot() devuelve un status opaco", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-l", false, "starter");
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    // El plan starter tiene max_customers=50 (Fase 10). 50 clientes STAFF
    // de relleno agotan el cupo sin tocar el tope de altas SELF_SERVICE
    // (10/hora, 30/dia) -- son source=STAFF, un contador totalmente
    // distinto dentro de book_slot().
    const fillers = Array.from({ length: 50 }, (_, i) => ({
      organization_id: org.id,
      profile_id: null,
      display_name: `Relleno plan ${i}`,
      is_active: true,
      source: "STAFF",
    }));
    const { error: fillError } = await admin.from("customers").insert(fillers);
    expect(fillError).toBeNull();

    const customer = await createSignedInUser("p45-l-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("ORGANIZATION_NOT_ACCEPTING_NEW_CUSTOMERS");
    // La propiedad bajo prueba: NUNCA el mensaje crudo del trigger, que
    // trae el conteo de clientes del tenant (ej. "clientes (50/50)").
    expect(JSON.stringify(data)).not.toMatch(/PLAN_LIMIT_REACHED/);
    expect(JSON.stringify(data)).not.toMatch(/clientes/);

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(m) fix ALTO #2: SUBSCRIPTION_INACTIVE del trigger de planes no filtra el detalle crudo del alta on-the-fly", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-m", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    // La organizacion deja de poder operar (ej. tarjeta rechazada) --
    // organization_can_operate() empieza a devolver false, y el trigger
    // enforce_plan_limit() aborta cualquier INSERT en customers con
    // SUBSCRIPTION_INACTIVE antes de mirar el plan.
    const { error: suspendError } = await admin
      .from("organizations")
      .update({ subscription_status: "SUSPENDED" })
      .eq("id", org.id);
    expect(suspendError).toBeNull();

    const customer = await createSignedInUser("p45-m-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occ.id });
    expect(error).toBeNull();
    expect(data.status).toBe("ORGANIZATION_NOT_ACCEPTING_NEW_CUSTOMERS");
    expect(JSON.stringify(data)).not.toMatch(/SUBSCRIPTION_INACTIVE/);

    expect(await countCustomers(org.id, customer.id)).toBe(0);
  });

  it("(n) fix MEDIO: el tope horario por organizacion ahora serializa bajo concurrencia real -- de 14 altas SELF_SERVICE disparadas en paralelo contra un tope de 10, exactamente 10 pasan", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p45-n", false);
    createdUserIds.push(owner.id);
    await enableOpenBooking(owner, org);

    // Ocurrencias DISTINTAS, una por Customer -- a proposito, no una sola
    // ocurrencia compartida. book_slot() ya toma FOR UPDATE sobre la fila
    // de slot_occurrences como lo primero que hace (ADR-0004): si las 14
    // llamadas apuntaran a la MISMA ocurrencia, ese lock por si solo ya
    // las serializaria una por una y el race del rate limit (lo que este
    // test tiene que probar) nunca se manifestaria -- exactamente como
    // reprodujo el gate originalmente (concurrencia entre ocurrencias
    // distintas, ver tambien el test (e) de arriba). Reusa el mismo
    // weekday varias veces (createRule ya soporta rules repetidas sobre el
    // mismo dia/hora, distinguidas por su propio schedule_rule_id) para no
    // depender de que haya 14 dias de la semana.
    const occurrences: Array<{ id: string }> = [];
    for (let i = 0; i < 14; i++) {
      const rule = await createRule(owner, org, service, resource, i, 5);
      const occ = await firstFutureOccurrence(owner, rule.id);
      occurrences.push(occ);
    }

    // Las cuentas se crean secuencialmente (signInWithPassword ya tiene su
    // propio rate limit por IP, ver helpers.ts) -- la concurrencia real
    // bajo prueba es la de las 14 llamadas a book_slot(), disparadas todas
    // juntas con Promise.all.
    const customers: SignedInUser[] = [];
    for (let i = 0; i < 14; i++) {
      const c = await createSignedInUser(`p45-n-cust-${i}`);
      createdUserIds.push(c.id);
      customers.push(c);
    }

    const results = await Promise.all(
      customers.map((c, i) => c.client.rpc("book_slot", { p_slot_occurrence_id: occurrences[i]!.id })),
    );

    for (const r of results) {
      expect(r.error).toBeNull();
    }
    const statuses = results.map((r) => r.data.status as string);
    const okCount = statuses.filter((s) => s === "OK").length;
    const rateLimitedCount = statuses.filter((s) => s === "RATE_LIMITED_HOURLY").length;

    // La pieza critica del fix: exactamente 10 pasan, nunca mas (antes del
    // pg_advisory_xact_lock, varias llamadas concurrentes leian el mismo
    // conteo "viejo" y pasaban todas juntas -- reproducido en vivo por el
    // gate con 7 altas contra un tope de 5).
    expect(okCount).toBe(10);
    expect(rateLimitedCount).toBe(4);
    expect(okCount + rateLimitedCount).toBe(14);

    const { count: selfServiceCount } = await admin
      .from("customers")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", org.id)
      .eq("source", "SELF_SERVICE");
    expect(selfServiceCount).toBe(10);
  });
});
