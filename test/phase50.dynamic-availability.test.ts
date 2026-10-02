// Integration tests for Phase 50 (ADR-0051, Fase 1): disponibilidad
// dinamica para Resources exclusivos, opt-in via resources.dynamic_availability.
// Requires a running Supabase instance (see test/helpers.ts) with this
// phase's migration already applied.

import { createClient } from "@supabase/supabase-js";
import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  createOrganization,
  createSignedInUser,
  SUPABASE_URL,
  type SignedInUser,
} from "./helpers";

const anon = createClient(SUPABASE_URL, ANON_KEY);

/** The local (America/Montevideo) calendar date `offsetDays` from today, as "YYYY-MM-DD". */
function futureLocalDate(offsetDays: number): string {
  const d = new Date(Date.now() + offsetDays * 86_400_000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Montevideo" }).format(d);
}

/**
 * The weekday (0=Sunday..6=Saturday) of a "YYYY-MM-DD" calendar date.
 * Parsing at noon UTC is deliberate: a calendar date's day-of-week is a
 * property of the date itself, not of any instant/timezone, and noon UTC
 * never risks crossing into the adjacent day for any real-world offset.
 */
function weekdayOf(dateStr: string): number {
  return new Date(`${dateStr}T12:00:00Z`).getUTCDay();
}

/**
 * The UTC instant for a given America/Montevideo local date + "HH:MM" local
 * time. Fixed UTC-3 offset, no DST (same assumption as
 * helpers.ts#insertOccurrenceLaterToday -- Montevideo does not observe DST).
 */
function localDateTimeToUtcIso(localDate: string, localTime: string): string {
  const naiveUtcMs = new Date(`${localDate}T${localTime}:00Z`).getTime();
  return new Date(naiveUtcMs + 3 * 3_600_000).toISOString();
}

/** The America/Montevideo local "HH:MM" of a UTC instant. */
function localTimeOf(iso: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Montevideo",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(new Date(iso));
}

describe("Phase 50: disponibilidad dinamica para Resources exclusivos (ADR-0051 Fase 1)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  /**
   * Organizacion con un Resource exclusivo + dinamico desde la creacion
   * (dynamic_availability=true no pasa por el trigger de toggle, que solo
   * mira UPDATE -- un INSERT con el flag ya prendido es trivialmente seguro,
   * no puede haber ScheduleRules todavia sobre un Resource que no existia),
   * mas dos Services de distinta duracion que ese Resource puede prestar
   * (el caso real de la ADR: Corte 30min / Combo 60min).
   */
  async function setupDynamicOrg(prefix: string) {
    const owner = await createSignedInUser(prefix);
    const org = await createOrganization(owner, `${prefix}-org`);

    const { data: resource, error: resourceError } = await owner.client
      .from("resources")
      .insert({
        organization_id: org.id,
        name: "Barbero",
        is_exclusive: true,
        dynamic_availability: true,
        created_by: owner.id,
      })
      .select()
      .single();
    if (resourceError) throw new Error(`failed to create dynamic resource: ${resourceError.message}`);

    const { data: serviceShort } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Corte", duration_minutes: 30, created_by: owner.id })
      .select()
      .single();

    const { data: serviceLong } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Combo", duration_minutes: 60, created_by: owner.id })
      .select()
      .single();

    const { error: pairingError } = await owner.client.from("service_resources").insert([
      { service_id: serviceShort!.id, resource_id: resource!.id },
      { service_id: serviceLong!.id, resource_id: resource!.id },
    ]);
    if (pairingError) throw new Error(`failed to pair service_resources: ${pairingError.message}`);

    return {
      owner,
      org: org as { id: string; slug: string },
      resource: resource! as { id: string },
      serviceShort: serviceShort! as { id: string },
      serviceLong: serviceLong! as { id: string },
    };
  }

  async function createWindow(
    owner: SignedInUser,
    resourceId: string,
    weekday: number,
    localStartTime = "09:00",
    localEndTime = "17:00",
  ) {
    return owner.client.rpc("create_resource_availability_window", {
      p_resource_id: resourceId,
      p_weekdays: [weekday],
      p_local_start_time: localStartTime,
      p_local_end_time: localEndTime,
    });
  }

  async function enrollCustomer(owner: SignedInUser, orgId: string, customer: SignedInUser) {
    const { data, error } = await owner.client
      .from("customers")
      .insert({ organization_id: orgId, profile_id: customer.id, created_by: owner.id })
      .select()
      .single();
    if (error) throw new Error(`failed to enroll customer: ${error.message}`);
    return data as { id: string };
  }

  it("(a) dynamic_availability no se puede prender sin is_exclusive=true (constraint)", async () => {
    const owner = await createSignedInUser("p50-a");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p50-a-org");

    const { error } = await owner.client.from("resources").insert({
      organization_id: org.id,
      name: "No exclusivo",
      is_exclusive: false,
      dynamic_availability: true,
      created_by: owner.id,
    });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/resources_dynamic_requires_exclusive/);
  });

  it("(b) el flag no se puede prender si el recurso tiene ScheduleRules activas", async () => {
    const owner = await createSignedInUser("p50-b");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p50-b-org");

    const { data: resource } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Barbero", is_exclusive: true, created_by: owner.id })
      .select()
      .single();
    const { data: service } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Corte", created_by: owner.id })
      .select()
      .single();

    const weekday = weekdayOf(futureLocalDate(2));
    const { data: rule } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: service!.id,
        resource_id: resource!.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 30,
        capacity: 1,
        created_by: owner.id,
      })
      .select()
      .single();

    const { error: toggleError } = await owner.client
      .from("resources")
      .update({ dynamic_availability: true })
      .eq("id", resource!.id);
    expect(toggleError).not.toBeNull();
    expect(toggleError!.message).toMatch(/RESOURCE_HAS_ACTIVE_SCHEDULE_RULES/);

    // Discontinuar la regla (flujo ya existente de ADR-0010/Fase 5) despeja
    // el camino -- nunca una cascada automatica de cancelacion como efecto
    // colateral del toggle.
    const { error: discontinueError } = await owner.client.rpc("discontinue_schedule_rule", {
      p_schedule_rule_id: rule!.id,
    });
    expect(discontinueError).toBeNull();

    const { error: secondToggleError } = await owner.client
      .from("resources")
      .update({ dynamic_availability: true })
      .eq("id", resource!.id);
    expect(secondToggleError).toBeNull();
  });

  it("(c) create_resource_availability_window crea correctamente y rechaza sobre un recurso no-dinamico", async () => {
    const { owner, org, resource } = await setupDynamicOrg("p50-c");
    const weekday = weekdayOf(futureLocalDate(3));

    const { data, error } = await createWindow(owner, resource.id, weekday);
    expect(error).toBeNull();
    expect(data!.length).toBe(1);
    expect(data![0].weekday).toBe(weekday);
    expect(data![0].resource_id).toBe(resource.id);

    const { data: plainResource } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
      .select()
      .single();

    const { error: rejectError } = await createWindow(owner, plainResource!.id, weekday);
    expect(rejectError).not.toBeNull();
    expect(rejectError!.message).toMatch(/RESOURCE_NOT_DYNAMIC/);
  });

  it("(d) get_dynamic_availability respeta la ventana y excluye lo ocupado (ACTIVE y HELD vigente), para dos duraciones distintas sobre el mismo recurso", async () => {
    const { owner, org, resource, serviceShort, serviceLong } = await setupDynamicOrg("p50-d");
    const futureDate = futureLocalDate(7);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    // Ocupa 09:00-09:30 con una ocurrencia ACTIVE insertada directamente
    // (simula una reserva ya confirmada, sin pasar por el flujo de hold).
    const { data: activeOcc, error: activeOccError } = await admin
      .from("slot_occurrences")
      .insert({
        organization_id: org.id,
        resource_id: resource.id,
        service_id: serviceShort.id,
        start_at: localDateTimeToUtcIso(futureDate, "09:00"),
        end_at: localDateTimeToUtcIso(futureDate, "09:30"),
        generated_timezone: "America/Montevideo",
        capacity: 1,
        status: "ACTIVE",
        schedule_rule_id: null,
      })
      .select()
      .single();
    expect(activeOccError).toBeNull();
    expect(activeOcc!.resource_is_exclusive).toBe(true);

    const { data: availShort, error: availShortError } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceShort.id,
      p_date: futureDate,
    });
    expect(availShortError).toBeNull();
    const timesShort = (availShort as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at));
    // Ocupado por la ocurrencia ACTIVE.
    expect(timesShort).not.toContain("09:00");
    // Back-to-back ('[)'): 09:30 no solapa 09:00-09:30.
    expect(timesShort).toContain("09:30");
    // Dentro de la ventana [09:00, 17:00) -- 16:30 es el ultimo inicio que
    // entra completo para un servicio de 30 minutos.
    expect(timesShort).toContain("16:30");
    // Nada antes de la apertura ni despues del cierre de la ventana.
    expect(timesShort.every((t) => t >= "09:00" && t <= "16:30")).toBe(true);

    const { data: availLong, error: availLongError } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceLong.id,
      p_date: futureDate,
    });
    expect(availLongError).toBeNull();
    const timesLong = (availLong as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at));
    // 09:00-10:00 solaparia la ocurrencia ACTIVE (09:00-09:30).
    expect(timesLong).not.toContain("09:00");
    // 09:30-10:30 no solapa (back-to-back).
    expect(timesLong).toContain("09:30");
    // Ultimo inicio que entra completo para 60 minutos dentro de [09:00,17:00).
    expect(timesLong).toContain("16:00");
    expect(timesLong).not.toContain("16:30");

    // HELD vigente tambien cuenta como ocupado.
    const customer = await createSignedInUser("p50-d-customer");
    createdUserIds.push(customer.id);
    const holdStart = localDateTimeToUtcIso(futureDate, "11:00");
    const { data: holdResult, error: holdError } = await customer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: holdStart,
    });
    expect(holdError).toBeNull();
    expect(holdResult.status).toBe("OK");

    const { data: availAfterHold } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceShort.id,
      p_date: futureDate,
    });
    expect((availAfterHold as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at))).not.toContain(
      "11:00",
    );

    // Un HELD vencido deja de contar como ocupado en la lectura (sin
    // side-effects -- get_dynamic_availability es stable, no lo limpia).
    await admin
      .from("slot_occurrences")
      .update({ held_until: new Date(Date.now() - 60_000).toISOString() })
      .eq("id", holdResult.slot_occurrence_id);

    const { data: availAfterExpiry } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceShort.id,
      p_date: futureDate,
    });
    expect((availAfterExpiry as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at))).toContain(
      "11:00",
    );
  });

  it("(e) hold_dynamic_slot: exito, TOO_MANY_ACTIVE_HOLDS (4to hold), SLOT_NO_LONGER_AVAILABLE (dos holds del mismo horario), AUTH_REQUIRED sin sesion", async () => {
    const { owner, resource, serviceShort } = await setupDynamicOrg("p50-e");
    const futureDate = futureLocalDate(6);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "12:00");
    expect(windowError).toBeNull();

    const customer = await createSignedInUser("p50-e-customer");
    createdUserIds.push(customer.id);

    const starts = ["09:00", "09:30", "10:00", "10:30"].map((t) => localDateTimeToUtcIso(futureDate, t));

    const statuses: string[] = [];
    for (const start of starts) {
      const { data, error } = await customer.client.rpc("hold_dynamic_slot", {
        p_resource_id: resource.id,
        p_service_id: serviceShort.id,
        p_start_at: start,
      });
      expect(error).toBeNull();
      statuses.push(data.status);
    }
    // Los primeros 3 holds (tope por perfil) tienen exito...
    expect(statuses.slice(0, 3)).toEqual(["OK", "OK", "OK"]);
    // ...y el 4to es rechazado sin tocar la base.
    expect(statuses[3]).toBe("TOO_MANY_ACTIVE_HOLDS");

    // Un segundo perfil intentando el PRIMER horario (ya HELD por el
    // primero) pierde la carrera -- el EXCLUDE ampliado es el backstop real.
    const otherCustomer = await createSignedInUser("p50-e-other");
    createdUserIds.push(otherCustomer.id);
    const { data: collideResult, error: collideError } = await otherCustomer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: starts[0],
    });
    expect(collideError).toBeNull();
    expect(collideResult.status).toBe("SLOT_NO_LONGER_AVAILABLE");

    // Sin sesion (auth.uid() null): se prueba con el cliente service-role,
    // el unico mecanismo disponible desde supabase-js para invocar la RPC
    // sin un JWT de usuario -- anon-key puro ni siquiera llega al cuerpo de
    // la funcion (no tiene GRANT EXECUTE), asi que no sirve para probar
    // este branch especifico.
    const { error: authError } = await admin.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: starts[0],
    });
    expect(authError).not.toBeNull();
    expect(authError!.message).toMatch(/AUTH_REQUIRED/);
  });

  it("(f) book_dynamic_slot: exito completo, hold vencido, HOLD_NOT_FOUND, reversion a CANCELLED cuando book_slot() interno falla", async () => {
    const { owner, org, resource, serviceShort } = await setupDynamicOrg("p50-f");
    const futureDate = futureLocalDate(8);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    // HOLD_NOT_FOUND: id inexistente.
    const { data: notFoundResult, error: notFoundError } = await owner.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: "00000000-0000-0000-0000-000000000000",
    });
    expect(notFoundError).toBeNull();
    expect(notFoundResult.status).toBe("HOLD_NOT_FOUND");

    // Exito completo: hold -> confirmar -> Booking creado.
    const customer = await createSignedInUser("p50-f-customer");
    createdUserIds.push(customer.id);
    const customerRow = await enrollCustomer(owner, org.id, customer);

    const { data: hold1 } = await customer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(hold1.status).toBe("OK");

    const { data: bookResult, error: bookError } = await customer.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: hold1.slot_occurrence_id,
    });
    expect(bookError).toBeNull();
    expect(bookResult.status).toBe("OK");
    expect(bookResult.booking.customer_id).toBe(customerRow.id);
    expect(bookResult.booking.status).toBe("CONFIRMED");

    const { data: occAfterBook } = await admin
      .from("slot_occurrences")
      .select("status, held_until")
      .eq("id", hold1.slot_occurrence_id)
      .single();
    expect(occAfterBook!.status).toBe("ACTIVE");
    expect(occAfterBook!.held_until).toBeNull();

    // Hold vencido: un segundo hold, forzado a vencido antes de confirmar.
    // Fase 50c (fix MEDIO-1): un hold vencido ya no tiene un status propio
    // ("HOLD_EXPIRED") distinguible de HOLD_NOT_FOUND -- mismo criterio de
    // no-oraculo que ya usa release_dynamic_hold().
    const { data: hold2 } = await customer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "10:00"),
    });
    expect(hold2.status).toBe("OK");
    await admin
      .from("slot_occurrences")
      .update({ held_until: new Date(Date.now() - 1_000).toISOString() })
      .eq("id", hold2.slot_occurrence_id);

    const { data: expiredResult, error: expiredError } = await customer.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: hold2.slot_occurrence_id,
    });
    expect(expiredError).toBeNull();
    expect(expiredResult.status).toBe("HOLD_NOT_FOUND");

    // Reversion a CANCELLED: un tercer hold, pero esta vez el Customer se
    // inactiva antes de confirmar -- can_customer_book() dentro de
    // book_slot() devuelve NOT_A_CUSTOMER (nunca OK_OPEN_BOOKING: la fila
    // de customers existe, solo esta inactiva), book_slot() no confirma
    // nada, y book_dynamic_slot() debe revertir la promocion a CANCELLED
    // en vez de dejar una SlotOccurrence ACTIVE fantasma sin Booking.
    const { data: hold3 } = await customer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "11:00"),
    });
    expect(hold3.status).toBe("OK");

    await admin.from("customers").update({ is_active: false }).eq("id", customerRow.id);

    const { data: revertedResult, error: revertedError } = await customer.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: hold3.slot_occurrence_id,
    });
    expect(revertedError).toBeNull();
    expect(revertedResult.status).toBe("NOT_A_CUSTOMER");

    const { data: occAfterRevert } = await admin
      .from("slot_occurrences")
      .select("status, cancellation_reason")
      .eq("id", hold3.slot_occurrence_id)
      .single();
    expect(occAfterRevert!.status).toBe("CANCELLED");
    expect(occAfterRevert!.cancellation_reason).toBe("SLOT_CANCELLED");
  });

  it("(g) release_dynamic_hold libera el propio hold y no revela nada sobre uno ajeno", async () => {
    const { owner, resource, serviceShort } = await setupDynamicOrg("p50-g");
    const futureDate = futureLocalDate(9);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    const customerA = await createSignedInUser("p50-g-a");
    createdUserIds.push(customerA.id);
    const customerB = await createSignedInUser("p50-g-b");
    createdUserIds.push(customerB.id);

    const { data: holdA } = await customerA.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(holdA.status).toBe("OK");

    // B intenta liberar el hold de A -- no-op silencioso, sin error, sin
    // revelar que el hold existe o a quien pertenece.
    const { error: bError } = await customerB.client.rpc("release_dynamic_hold", {
      p_slot_occurrence_id: holdA.slot_occurrence_id,
    });
    expect(bError).toBeNull();

    const { data: stillHeld } = await admin
      .from("slot_occurrences")
      .select("status, held_by")
      .eq("id", holdA.slot_occurrence_id)
      .single();
    expect(stillHeld!.status).toBe("HELD");
    expect(stillHeld!.held_by).toBe(customerA.id);

    // A libera su propio hold.
    const { error: aError } = await customerA.client.rpc("release_dynamic_hold", {
      p_slot_occurrence_id: holdA.slot_occurrence_id,
    });
    expect(aError).toBeNull();

    const { data: released } = await admin
      .from("slot_occurrences")
      .select("status, cancellation_reason, cancelled_by")
      .eq("id", holdA.slot_occurrence_id)
      .single();
    expect(released!.status).toBe("CANCELLED");
    expect(released!.cancellation_reason).toBe("SLOT_CANCELLED");
    expect(released!.cancelled_by).toBe(customerA.id);
  });

  it("(h) cross-tenant: resource/service de otra organizacion es rechazado sin filtrar datos", async () => {
    const { owner: ownerX, org: orgX, resource: resourceX } = await setupDynamicOrg("p50-h-x");
    const { owner: ownerY, serviceShort: serviceY } = await setupDynamicOrg("p50-h-y");
    const futureDate = futureLocalDate(10);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(ownerX, resourceX.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    const outsider = await createSignedInUser("p50-h-outsider");
    createdUserIds.push(outsider.id);

    // hold_dynamic_slot: Resource de X + Service de Y -- rechazado sin
    // distinguir "el resource no es tuyo" de "el service no es tuyo".
    const { error: crossHoldError } = await outsider.client.rpc("hold_dynamic_slot", {
      p_resource_id: resourceX.id,
      p_service_id: serviceY.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(crossHoldError).not.toBeNull();
    expect(crossHoldError!.message).toMatch(/SERVICE_NOT_FOUND/);

    // get_dynamic_availability: slug de X + Service de Y -- vacio, sin error.
    const { data: crossAvail, error: crossAvailError } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: orgX.slug,
      p_service_id: serviceY.id,
      p_date: futureDate,
    });
    expect(crossAvailError).toBeNull();
    expect(crossAvail).toEqual([]);

    // create_resource_availability_window: un owner de otra organizacion
    // (no miembro de X) sobre un Resource de X -- NOT_AUTHORIZED, nunca
    // RESOURCE_NOT_DYNAMIC ni ningun dato de X.
    const { error: crossWindowError } = await ownerY.client.rpc("create_resource_availability_window", {
      p_resource_id: resourceX.id,
      p_weekdays: [weekday],
      p_local_start_time: "09:00",
      p_local_end_time: "17:00",
    });
    expect(crossWindowError).not.toBeNull();
    expect(crossWindowError!.message).toMatch(/NOT_AUTHORIZED/);
  });

  it("(i) create_schedule_rule_group/create_schedule_rule_span rechazan RESOURCE_IS_DYNAMIC sobre un recurso dinamico", async () => {
    const { owner, resource, serviceShort } = await setupDynamicOrg("p50-i");
    const weekday = weekdayOf(futureLocalDate(4));

    const { error: groupError } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: serviceShort.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_local_start_time: "09:00",
      p_duration_minutes: 30,
      p_capacity: 1,
    });
    expect(groupError).not.toBeNull();
    expect(groupError!.message).toMatch(/RESOURCE_IS_DYNAMIC/);

    const { error: spanError } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: serviceShort.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "09:00",
      p_range_end: "12:00",
      p_step_minutes: 30,
      p_duration_minutes: 30,
      p_capacity: 1,
    });
    expect(spanError).not.toBeNull();
    expect(spanError!.message).toMatch(/RESOURCE_IS_DYNAMIC/);

    // Ningun ScheduleRule quedo a medio crear en ninguno de los dos intentos.
    const { data: rules } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", resource.id);
    expect(rules).toEqual([]);
  });

  // ============================================================
  // Fase 50c (fixes de seguridad del gate obligatorio) -- tests nuevos.
  // ============================================================

  it("(j) cancelar una Booking dinamica libera el horario: get_dynamic_availability lo vuelve a mostrar y un nuevo hold que se solapa funciona", async () => {
    const { owner, org, resource, serviceShort } = await setupDynamicOrg("p50-j");
    const futureDate = futureLocalDate(12);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    const customer = await createSignedInUser("p50-j-customer");
    createdUserIds.push(customer.id);
    await enrollCustomer(owner, org.id, customer);

    const { data: hold } = await customer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(hold.status).toBe("OK");

    const { data: bookResult, error: bookError } = await customer.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: hold.slot_occurrence_id,
    });
    expect(bookError).toBeNull();
    expect(bookResult.status).toBe("OK");

    // Antes de cancelar, 09:00 esta ocupado para cualquiera.
    const { data: availBeforeCancel } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceShort.id,
      p_date: futureDate,
    });
    expect(
      (availBeforeCancel as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at)),
    ).not.toContain("09:00");

    const { error: cancelError } = await customer.client.rpc("cancel_booking", {
      p_booking_id: bookResult.booking.id,
    });
    expect(cancelError).toBeNull();

    // ALTO-1: el trigger libera la SlotOccurrence dinamica de verdad, no
    // queda ACTIVE para siempre.
    const { data: occAfterCancel } = await admin
      .from("slot_occurrences")
      .select("status, cancellation_reason")
      .eq("id", hold.slot_occurrence_id)
      .single();
    expect(occAfterCancel!.status).toBe("CANCELLED");
    expect(occAfterCancel!.cancellation_reason).toBe("SLOT_CANCELLED");

    const { data: availAfterCancel } = await anon.rpc("get_dynamic_availability", {
      p_organization_slug: org.slug,
      p_service_id: serviceShort.id,
      p_date: futureDate,
    });
    expect(
      (availAfterCancel as Array<{ start_at: string }>).map((s) => localTimeOf(s.start_at)),
    ).toContain("09:00");

    // Un nuevo hold que se solapa ya no choca con el EXCLUDE (antes daria
    // SLOT_NO_LONGER_AVAILABLE contra la SlotOccurrence ACTIVE fantasma).
    const otherCustomer = await createSignedInUser("p50-j-other");
    createdUserIds.push(otherCustomer.id);
    const { data: newHold, error: newHoldError } = await otherCustomer.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(newHoldError).toBeNull();
    expect(newHold.status).toBe("OK");
  });

  it("(k) book_dynamic_slot llamado por una cuenta distinta de quien hizo el hold devuelve HOLD_NOT_FOUND sin tocar el hold original", async () => {
    const { owner, resource, serviceShort } = await setupDynamicOrg("p50-k");
    const futureDate = futureLocalDate(13);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    const holder = await createSignedInUser("p50-k-holder");
    createdUserIds.push(holder.id);
    const attacker = await createSignedInUser("p50-k-attacker");
    createdUserIds.push(attacker.id);

    const { data: hold } = await holder.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "09:00"),
    });
    expect(hold.status).toBe("OK");

    const { data: stolen, error: stolenError } = await attacker.client.rpc("book_dynamic_slot", {
      p_slot_occurrence_id: hold.slot_occurrence_id,
    });
    expect(stolenError).toBeNull();
    expect(stolen.status).toBe("HOLD_NOT_FOUND");

    const { data: bookings } = await admin
      .from("bookings")
      .select("id")
      .eq("slot_occurrence_id", hold.slot_occurrence_id);
    expect(bookings).toEqual([]);

    // El hold original sigue HELD e intacto -- no se cancelo como efecto
    // colateral del intento ajeno.
    const { data: stillHeld } = await admin
      .from("slot_occurrences")
      .select("status, held_by, held_until")
      .eq("id", hold.slot_occurrence_id)
      .single();
    expect(stillHeld!.status).toBe("HELD");
    expect(stillHeld!.held_by).toBe(holder.id);
    expect(stillHeld!.held_until).not.toBeNull();
  });

  it("(l) un STAFF no puede escribir HELD directo via PostgREST, ni tocar una fila ya HELD", async () => {
    const { owner, org, resource, serviceShort } = await setupDynamicOrg("p50-l");
    const futureDate = futureLocalDate(14);
    const weekday = weekdayOf(futureDate);
    const { error: windowError } = await createWindow(owner, resource.id, weekday, "09:00", "17:00");
    expect(windowError).toBeNull();

    // ACTIVE "fantasma" insertada directa (simula una reserva confirmada).
    const { data: activeOcc, error: activeOccError } = await admin
      .from("slot_occurrences")
      .insert({
        organization_id: org.id,
        resource_id: resource.id,
        service_id: serviceShort.id,
        start_at: localDateTimeToUtcIso(futureDate, "09:00"),
        end_at: localDateTimeToUtcIso(futureDate, "09:30"),
        generated_timezone: "America/Montevideo",
        capacity: 1,
        status: "ACTIVE",
        schedule_rule_id: null,
      })
      .select()
      .single();
    expect(activeOccError).toBeNull();

    // STAFF (dueno del propio recurso) intenta ACTIVE -> HELD directo,
    // poniendose a si mismo como held_by -- rechazado por el WITH CHECK.
    const { error: toHeldError } = await owner.client
      .from("slot_occurrences")
      .update({ status: "HELD", held_by: owner.id, held_until: new Date(Date.now() + 300_000).toISOString() })
      .eq("id", activeOcc!.id);
    expect(toHeldError).not.toBeNull();

    const { data: stillActive } = await admin
      .from("slot_occurrences")
      .select("status, held_by")
      .eq("id", activeOcc!.id)
      .single();
    expect(stillActive!.status).toBe("ACTIVE");
    expect(stillActive!.held_by).toBeNull();

    // Un hold real de un cliente sobre el mismo recurso -- el STAFF intenta
    // tocarla directo (ej. cambiar su capacity): el USING la excluye por
    // estar HELD, sin importar que tan "propia" sea la organizacion.
    const victim = await createSignedInUser("p50-l-victim");
    createdUserIds.push(victim.id);
    const { data: hold } = await victim.client.rpc("hold_dynamic_slot", {
      p_resource_id: resource.id,
      p_service_id: serviceShort.id,
      p_start_at: localDateTimeToUtcIso(futureDate, "11:00"),
    });
    expect(hold.status).toBe("OK");

    const { error: touchHeldError, data: touchHeldData } = await owner.client
      .from("slot_occurrences")
      .update({ capacity: 5 })
      .eq("id", hold.slot_occurrence_id)
      .select();
    expect(touchHeldError).toBeNull();
    expect(touchHeldData).toEqual([]);

    const { data: stillHeld } = await admin
      .from("slot_occurrences")
      .select("status, held_by, capacity")
      .eq("id", hold.slot_occurrence_id)
      .single();
    expect(stillHeld!.status).toBe("HELD");
    expect(stillHeld!.held_by).toBe(victim.id);
    expect(stillHeld!.capacity).toBe(1);
  });

  it("(m) DELETE sobre resource_availability_windows via PostgREST directo es rechazado -- la fila sobrevive", async () => {
    const { owner, resource } = await setupDynamicOrg("p50-m");
    const weekday = weekdayOf(futureLocalDate(15));
    const { data: windows, error: windowError } = await createWindow(owner, resource.id, weekday);
    expect(windowError).toBeNull();
    const windowId = windows![0]!.id;

    const { error: deleteError, data: deleteData } = await owner.client
      .from("resource_availability_windows")
      .delete()
      .eq("id", windowId)
      .select();
    expect(deleteError).toBeNull();
    expect(deleteData).toEqual([]);

    const { data: stillThere } = await admin
      .from("resource_availability_windows")
      .select("id")
      .eq("id", windowId)
      .single();
    expect(stillThere?.id).toBe(windowId);
  });

  it("(n) insert directo a schedule_rules sobre un Resource dinamico es rechazado (RESOURCE_IS_DYNAMIC)", async () => {
    const { owner, org, resource, serviceShort } = await setupDynamicOrg("p50-n");
    const weekday = weekdayOf(futureLocalDate(16));

    const { error } = await owner.client.from("schedule_rules").insert({
      organization_id: org.id,
      service_id: serviceShort.id,
      resource_id: resource.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 30,
      capacity: 1,
      created_by: owner.id,
    });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/RESOURCE_IS_DYNAMIC/);
  });

  it("(o) insert directo a resource_availability_windows falsificando created_by es rechazado", async () => {
    const { owner, org, resource } = await setupDynamicOrg("p50-o");
    const other = await createSignedInUser("p50-o-other");
    createdUserIds.push(other.id);
    const weekday = weekdayOf(futureLocalDate(17));

    const { error } = await owner.client.from("resource_availability_windows").insert({
      organization_id: org.id,
      resource_id: resource.id,
      weekday,
      local_start_time: "09:00",
      local_end_time: "17:00",
      created_by: other.id,
    });
    expect(error).not.toBeNull();
  });
});
