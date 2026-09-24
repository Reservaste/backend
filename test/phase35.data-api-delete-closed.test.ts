// Integration tests for Fase 35 -- ADR-0036: el DELETE de la Data API
// queda cerrado en las siete tablas con hijos en cascada.
//
// El hallazgo de `security-engineer`, en una línea: **la cascada de FK no
// evalúa RLS**. Postgres aplica las policies a la fila que el comando
// nombra; las filas que la integridad referencial arrastra detrás se van
// sin que nadie las mire. Así, un `DELETE /rest/v1/schedule_rules` borraba
// Bookings CONFIRMED (no las cancelaba: las borraba, sin cancelled_at, sin
// MakeupCredit, sin audit_log) y un `DELETE /rest/v1/services` borraba
// pagos PAID.
//
// Por eso el actor de estos tests es el **OWNER**: es el rol más
// privilegiado que existe fuera del platform admin. Si el OWNER no puede,
// nadie de la organización puede, y no hace falta repetir la matriz de
// roles de ADR-0033 tabla por tabla.
//
// Cómo se ve un DELETE denegado por RLS: **no da error**. Postgres no
// encuentra filas que el actor pueda borrar, PostgREST responde 204 con
// `[]` y la fila sigue ahí. Por eso cada caso afirma las dos mitades:
// la respuesta no borró nada Y la fila sobrevive. Afirmar sólo un código
// de error daría un falso verde si mañana alguien reabre el DELETE.
//
// Requiere una instancia local de Supabase corriendo.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

const createdUserIds: string[] = [];

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

/**
 * Afirma que una fila sigue existiendo, mirándola con el cliente de
 * service role: si la policy de SELECT cambiara, un `.select()` vacío del
 * OWNER no distinguiría "no la veo" de "la borré". Acá la pregunta es
 * literalmente si la fila está en la tabla.
 */
async function rowExists(table: string, filter: Record<string, string>) {
  let query = admin.from(table).select("*", { count: "exact", head: true });
  for (const [column, value] of Object.entries(filter)) {
    query = query.eq(column, value);
  }
  const { count, error } = await query;
  expect(error).toBeNull();
  return (count ?? 0) > 0;
}

describe("Fase 35 -- ADR-0036: DELETE cerrado en la Data API", () => {
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceId: string;
  let resourceId: string;
  let ruleId: string;
  let exceptionId: string;
  let customerId: string;
  let entitlementId: string;
  let occurrenceId: string;
  let bookingId: string;
  let paymentId: string;

  beforeAll(async () => {
    owner = await newUser("p35-owner");
    org = await createOrganization(owner, "p35-org");

    const { data: service, error: serviceError } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
      .select()
      .single();
    expect(serviceError).toBeNull();
    serviceId = service!.id as string;

    const { data: resource, error: resourceError } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
      .select()
      .single();
    expect(resourceError).toBeNull();
    resourceId = resource!.id as string;

    const { error: linkError } = await owner.client
      .from("service_resources")
      .insert({ service_id: serviceId, resource_id: resourceId });
    expect(linkError).toBeNull();

    const { data: rule, error: ruleError } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceId,
        resource_id: resourceId,
        weekday: 3,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(ruleError).toBeNull();
    ruleId = rule!.id as string;

    // Fecha lejana a propósito: la excepción tiene que existir como fila,
    // no alterar la ocurrencia que después se reserva.
    const { data: exception, error: exceptionError } = await owner.client
      .from("schedule_exceptions")
      .insert({
        organization_id: org.id,
        schedule_rule_id: ruleId,
        exception_date: isoDate(400),
        exception_type: "CANCELLED",
        created_by: owner.id,
      })
      .select()
      .single();
    expect(exceptionError).toBeNull();
    exceptionId = exception!.id as string;

    const customerUser = await newUser("p35-cust");
    const { data: customer, error: customerError } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customerUser.id, created_by: owner.id })
      .select()
      .single();
    expect(customerError).toBeNull();
    customerId = customer!.id as string;

    const { data: entitlement, error: entitlementError } = await owner.client
      .from("service_entitlements")
      .insert({
        organization_id: org.id,
        customer_id: customerId,
        service_id: serviceId,
        entitlement_type: "TIME",
        valid_from: isoDate(-1),
        created_by: owner.id,
      })
      .select()
      .single();
    expect(entitlementError).toBeNull();
    entitlementId = entitlement!.id as string;

    occurrenceId = (await firstFutureOccurrence(owner, ruleId)).id;

    const booked = await customerUser.client.rpc("book_slot", {
      p_slot_occurrence_id: occurrenceId,
    });
    expect(booked.error).toBeNull();
    expect(booked.data.status).toBe("OK");
    bookingId = booked.data.booking.id as string;

    // El pago PAID del segundo escenario de `security-engineer`.
    const paid = await payFor(owner, {
      organizationId: org.id,
      customerId,
      serviceId,
      from: isoDate(-1),
      to: isoDate(30),
      status: "PAID",
    });
    expect(paid.error).toBeNull();
    paymentId = (paid.data as { id: string }).id;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ================================================================
  // 1. Los dos escenarios exactos que reprodujo `security-engineer`
  // ================================================================

  it("DELETE schedule_rules con reservas CONFIRMED abajo: rechazado, y las reservas siguen CONFIRMED", async () => {
    // Estado de partida: la cascada que existía era
    // schedule_rules -> slot_occurrences -> bookings.
    const { data: before } = await admin
      .from("bookings")
      .select("id, status")
      .eq("id", bookingId)
      .single();
    expect(before!.status).toBe("CONFIRMED");

    const { data: deleted, error } = await owner.client
      .from("schedule_rules")
      .delete()
      .eq("id", ruleId)
      .select();

    expect(error).toBeNull();
    expect(deleted ?? []).toHaveLength(0);

    expect(await rowExists("schedule_rules", { id: ruleId })).toBe(true);
    expect(await rowExists("slot_occurrences", { id: occurrenceId })).toBe(true);

    const { data: after } = await admin
      .from("bookings")
      .select("id, status, cancelled_at")
      .eq("id", bookingId)
      .single();
    expect(after).not.toBeNull();
    expect(after!.status).toBe("CONFIRMED");
    expect(after!.cancelled_at).toBeNull();
  });

  it("DELETE services con un pago PAID abajo: rechazado, y el pago sigue existiendo", async () => {
    const { data: before } = await admin
      .from("payments")
      .select("id, status")
      .eq("id", paymentId)
      .single();
    expect(before!.status).toBe("PAID");

    const { data: deleted, error } = await owner.client
      .from("services")
      .delete()
      .eq("id", serviceId)
      .select();

    expect(error).toBeNull();
    expect(deleted ?? []).toHaveLength(0);

    expect(await rowExists("services", { id: serviceId })).toBe(true);

    const { data: after } = await admin
      .from("payments")
      .select("id, status")
      .eq("id", paymentId)
      .single();
    expect(after).not.toBeNull();
    expect(after!.status).toBe("PAID");
  });

  // ================================================================
  // 2. Las siete tablas, una por una, con el OWNER como actor
  // ================================================================

  it("un OWNER no puede borrar un schedule_rule por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("schedule_rules")
      .delete()
      .eq("id", ruleId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("schedule_rules", { id: ruleId })).toBe(true);
  });

  it("un OWNER no puede borrar un service por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("services")
      .delete()
      .eq("id", serviceId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("services", { id: serviceId })).toBe(true);
  });

  it("un OWNER no puede borrar un resource por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("resources")
      .delete()
      .eq("id", resourceId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("resources", { id: resourceId })).toBe(true);
  });

  it("un OWNER no puede borrar un customer por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("customers")
      .delete()
      .eq("id", customerId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("customers", { id: customerId })).toBe(true);
    // La cascada customers -> bookings/payments tampoco corrió.
    expect(await rowExists("bookings", { id: bookingId })).toBe(true);
    expect(await rowExists("payments", { id: paymentId })).toBe(true);
  });

  it("un OWNER no puede borrar un schedule_exception por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("schedule_exceptions")
      .delete()
      .eq("id", exceptionId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("schedule_exceptions", { id: exceptionId })).toBe(true);
  });

  it("un OWNER no puede borrar un service_entitlement por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("service_entitlements")
      .delete()
      .eq("id", entitlementId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(await rowExists("service_entitlements", { id: entitlementId })).toBe(true);
  });

  it("un OWNER no puede borrar un service_resource por PostgREST", async () => {
    const { data, error } = await owner.client
      .from("service_resources")
      .delete()
      .eq("service_id", serviceId)
      .eq("resource_id", resourceId)
      .select();
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);
    expect(
      await rowExists("service_resources", { service_id: serviceId, resource_id: resourceId }),
    ).toBe(true);
  });

  // ================================================================
  // 3. Lo que NO se rompió: SELECT / INSERT / UPDATE siguen igual
  // ================================================================
  // Reemplazar una policy `ALL` por `INSERT` + `UPDATE` explícitos es
  // exactamente el tipo de cambio que puede cerrar de más sin que nadie
  // se entere hasta producción. Estas afirmaciones son el contrapeso.

  it("el OWNER sigue pudiendo leer, insertar y actualizar en las siete tablas", async () => {
    // SELECT
    const { data: readable, error: readError } = await owner.client
      .from("services")
      .select("id")
      .eq("id", serviceId);
    expect(readError).toBeNull();
    expect(readable).toHaveLength(1);

    const { data: readableCustomers, error: readCustomersError } = await owner.client
      .from("customers")
      .select("id")
      .eq("id", customerId);
    expect(readCustomersError).toBeNull();
    expect(readableCustomers).toHaveLength(1);

    const { data: readableLinks, error: readLinksError } = await owner.client
      .from("service_resources")
      .select("service_id")
      .eq("service_id", serviceId);
    expect(readLinksError).toBeNull();
    expect(readableLinks).toHaveLength(1);

    // UPDATE (el camino real de "dar de baja": is_active, no DELETE)
    const { data: deactivated, error: deactivateError } = await owner.client
      .from("services")
      .update({ is_active: false })
      .eq("id", serviceId)
      .select();
    expect(deactivateError).toBeNull();
    expect(deactivated).toHaveLength(1);
    await owner.client.from("services").update({ is_active: true }).eq("id", serviceId);

    const { data: renamed, error: renameError } = await owner.client
      .from("resources")
      .update({ name: "Sala grande" })
      .eq("id", resourceId)
      .select();
    expect(renameError).toBeNull();
    expect(renamed).toHaveLength(1);

    const { data: customerUpdated, error: customerUpdateError } = await owner.client
      .from("customers")
      .update({ display_name: "Cliente al día" })
      .eq("id", customerId)
      .select();
    expect(customerUpdateError).toBeNull();
    expect(customerUpdated).toHaveLength(1);

    const { data: entitlementUpdated, error: entitlementUpdateError } = await owner.client
      .from("service_entitlements")
      .update({ valid_until: isoDate(90) })
      .eq("id", entitlementId)
      .select();
    expect(entitlementUpdateError).toBeNull();
    expect(entitlementUpdated).toHaveLength(1);

    const { data: exceptionUpdated, error: exceptionUpdateError } = await owner.client
      .from("schedule_exceptions")
      .update({ exception_type: "MODIFIED", modified_capacity: 5 })
      .eq("id", exceptionId)
      .select();
    expect(exceptionUpdateError).toBeNull();
    expect(exceptionUpdated).toHaveLength(1);

    const { data: ruleUpdated, error: ruleUpdateError } = await owner.client
      .from("schedule_rules")
      .update({ capacity: 12 })
      .eq("id", ruleId)
      .select();
    expect(ruleUpdateError).toBeNull();
    expect(ruleUpdated).toHaveLength(1);

    // INSERT
    const { data: newResource, error: newResourceError } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Sala 2", created_by: owner.id })
      .select()
      .single();
    expect(newResourceError).toBeNull();

    const { error: newLinkError } = await owner.client
      .from("service_resources")
      .insert({ service_id: serviceId, resource_id: newResource!.id });
    expect(newLinkError).toBeNull();

    const { error: newServiceError } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Yoga", created_by: owner.id });
    expect(newServiceError).toBeNull();
  });

  // ================================================================
  // 4. El camino legítimo sigue abierto
  // ================================================================
  // ADR-0036 se apoya en que nadie necesita DELETE porque dar de baja un
  // horario ya tiene su RPC. Si eso dejara de ser cierto, el ADR entero
  // se cae -- así que se afirma acá y no se asume.

  it("discontinue_schedule_rule() sigue funcionando: cancela y libera, no borra", async () => {
    const { error } = await owner.client.rpc("discontinue_schedule_rule", {
      p_schedule_rule_id: ruleId,
    });
    expect(error).toBeNull();

    // La regla sigue existiendo (desactivada), la ocurrencia también, y
    // la reserva quedó CANCELLED con su rastro -- no borrada.
    const { data: rule } = await admin
      .from("schedule_rules")
      .select("id, is_active")
      .eq("id", ruleId)
      .single();
    expect(rule!.is_active).toBe(false);

    const { data: booking } = await admin
      .from("bookings")
      .select("id, status, cancelled_at")
      .eq("id", bookingId)
      .single();
    expect(booking).not.toBeNull();
    expect(booking!.status).toBe("CANCELLED");
    expect(booking!.cancelled_at).not.toBeNull();
  });
});
