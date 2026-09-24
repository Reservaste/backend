// Integration tests for Fase 36 -- ADR-0037: las vistas públicas de
// `public` dejan de ser escribibles por `anon`/`authenticated`.
//
// El hallazgo de `security-engineer`, en una línea: **una vista sin
// `security_invoker` no saltea la RLS sólo en lectura.** El bypass del
// dueño de la vista alcanza los cuatro comandos, y los default privileges
// de Supabase ya le habían dado a `anon` INSERT/UPDATE/DELETE/TRUNCATE
// sobre toda vista nueva de `public`. Resultado: un visitante **sin
// sesión**, con la anon key (pública por diseño), borraba `Booking`s
// CONFIRMED y pagos PAID en cascada, reescribía el slug de cualquier
// organización y creaba organizaciones salteando el gate de invitación.
//
// Diferencia de forma con la Fase 35, que importa para leer los asserts:
// un DELETE denegado por **ausencia de policy RLS** no da error (0 filas,
// 204). Un DELETE denegado por **falta de privilegio de tabla** sí da
// error: `42501`. Acá conviven las dos formas -- las vistas (secciones
// 1-4) fallan con 42501; `organization_members` (sección 6) falla en
// silencio con 0 filas. En los dos casos el test afirma además que la fila
// sobrevive: afirmar sólo el código de error daría un falso verde el día
// que alguien vuelva a abrir la puerta por el otro mecanismo.
//
// Los otros dos hallazgos de ADR-0037 -- `organization_roles` y
// `service_plan_services` -- se prueban en
// `phase36b.role-and-plan-scope-delete-closed.test.ts`, porque su migración
// (`20260923240000_phase36b_...`) depende de la Fase 32 y se aplica después
// de ella. Este archivo se queda sólo con lo que se sostiene contra el
// historial commiteado.
//
// Requiere una instancia local de Supabase corriendo.

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  payFor,
  SUPABASE_URL,
  type SignedInUser,
} from "./helpers";

/** El atacante: la anon key y nada más. Sin `signIn`, sin JWT de usuario. */
const anon = createClient(SUPABASE_URL, ANON_KEY);

const createdUserIds: string[] = [];

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

/**
 * Si la fila está en la tabla, mirada con service role. Un `.select()`
 * vacío del actor bajo prueba no distingue "no la veo" de "la borré".
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

/**
 * Sufijo único por corrida para los payloads que el atacante intenta
 * insertar. Los asserts de "esto no se creó" miran la fila concreta del
 * intento, nunca un `count(*)` global de `organizations`: vitest corre los
 * archivos de test en paralelo (así corre CI, sin `--no-file-parallelism`)
 * y otros archivos crean y borran organizaciones reales dentro de la misma
 * ventana. Un conteo global comparado antes/después mide ese ruido ajeno y
 * se pone rojo sin que nada de seguridad haya cambiado.
 */
const attackToken = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

describe("Fase 36 -- ADR-0037: vistas públicas sólo de lectura", () => {
  let owner: SignedInUser;
  let outsider: SignedInUser;
  let org: { id: string; slug: string };
  let serviceId: string;
  let ruleId: string;
  let customerId: string;
  let occurrenceId: string;
  let bookingId: string;
  let paymentId: string;
  let globalOnlyServiceId: string;
  let unplannedServiceId: string;
  let unplannedOccurrenceId: string;
  let unplannedBookingId: string;
  let ownerMemberId: string;
  let staffMemberId: string;
  let staffUserId: string;

  beforeAll(async () => {
    owner = await newUser("p36-owner");
    outsider = await newUser("p36-outsider");
    org = await createOrganization(owner, "p36-org");

    const { data: services, error: servicesError } = await owner.client
      .from("services")
      .insert([
        { organization_id: org.id, name: "Pilates", created_by: owner.id },
        { organization_id: org.id, name: "Yoga", created_by: owner.id },
        { organization_id: org.id, name: "Aparatos", created_by: owner.id },
      ])
      .select("id");
    expect(servicesError).toBeNull();
    [serviceId, unplannedServiceId, globalOnlyServiceId] = (services as { id: string }[]).map(
      (s) => s.id,
    );

    const { data: resource, error: resourceError } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
      .select()
      .single();
    expect(resourceError).toBeNull();

    const { data: rule, error: ruleError } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceId,
        resource_id: resource!.id,
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

    // El servicio "Yoga" existe para reproducir el escenario EXACTO de
    // `security-engineer`: un servicio **sin ningún plan**, con una
    // Booking CONFIRMED colgando de él. Sin plan no hay fila en
    // `service_plan_services`, así que la cascada
    // services -> schedule_rules -> slot_occurrences -> bookings corre
    // hasta el final sin que ningún trigger de la Fase 22 la frene por
    // casualidad -- es el caso donde el DELETE anónimo de verdad destruía
    // datos. Los otros servicios tienen planes y esa casualidad los
    // protegía a medias; un test que sólo los mirara sería más débil de lo
    // que parece.
    const { data: unplannedRule, error: unplannedRuleError } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: unplannedServiceId,
        resource_id: resource!.id,
        weekday: 5,
        local_start_time: "18:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(unplannedRuleError).toBeNull();

    const customerUser = await newUser("p36-cust");
    const { data: customer, error: customerError } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customerUser.id, created_by: owner.id })
      .select()
      .single();
    expect(customerError).toBeNull();
    customerId = customer!.id as string;

    occurrenceId = (await firstFutureOccurrence(owner, ruleId)).id;

    // La Booking CONFIRMED y el Payment PAID que el DELETE anónimo
    // destruía en cascada.
    const booked = await customerUser.client.rpc("book_slot", {
      p_slot_occurrence_id: occurrenceId,
    });
    expect(booked.error).toBeNull();
    expect(booked.data.status).toBe("OK");
    bookingId = booked.data.booking.id as string;

    unplannedOccurrenceId = (await firstFutureOccurrence(owner, unplannedRule!.id as string)).id;
    const bookedUnplanned = await customerUser.client.rpc("book_slot", {
      p_slot_occurrence_id: unplannedOccurrenceId,
    });
    expect(bookedUnplanned.error).toBeNull();
    expect(bookedUnplanned.data.status).toBe("OK");
    unplannedBookingId = bookedUnplanned.data.booking.id as string;

    // El segundo escenario de `security-engineer`: un pago PAID anclado a
    // un plan `applies_to_all_services`, sobre un servicio ("Aparatos")
    // que NINGÚN plan por servicio cubre. Las dos mitades importan: un
    // plan `applies_to_all_services` no tiene filas en
    // `service_plan_services`, así que borrar el servicio llega derecho a
    // `payments` por la FK de la Fase 14 -- mientras que si el servicio
    // estuviera además en un plan PER_SERVICE, el DELETE moriría antes
    // contra `validate_service_plan_scope()` (el plan se quedaría sin
    // servicios) y el test estaría midiendo esa casualidad en vez del
    // agujero.
    const { data: globalPlan, error: globalPlanError } = await owner.client.rpc(
      "create_service_plan",
      {
        p_organization_id: org.id,
        p_name: `Pase libre ${Math.random().toString(36).slice(2, 8)}`,
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

    const paid = await payFor(owner, {
      organizationId: org.id,
      customerId,
      serviceId: globalOnlyServiceId,
      servicePlanId: (globalPlan as { id: string }).id,
      from: isoDate(-1),
      to: isoDate(30),
      status: "PAID",
    });
    expect(paid.error).toBeNull();
    paymentId = (paid.data as { id: string }).id;

    const { data: ownerMember, error: ownerMemberError } = await admin
      .from("organization_members")
      .select("id")
      .eq("organization_id", org.id)
      .eq("profile_id", owner.id)
      .single();
    expect(ownerMemberError).toBeNull();
    ownerMemberId = ownerMember!.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ================================================================
  // 1. LO PRIMERO: la lectura anónima sigue viva
  // ================================================================
  // El fix equivocado para esto era `security_invoker = on`, que cierra
  // la escritura **y también** la lectura anónima -- o sea, apaga el
  // calendario público (ADR-0008) para todo visitante. Si algo de esta
  // sección se pone rojo, el fix está mal y hay que volver atrás, no
  // ajustar el test.

  it("anon sigue pudiendo SELECT organizations_public", async () => {
    const { data, error } = await anon
      .from("organizations_public")
      .select("id, slug, name, timezone, brand_color, logo_path")
      .eq("slug", org.slug)
      .maybeSingle();

    expect(error).toBeNull();
    expect(data).not.toBeNull();
    expect(data!.id).toBe(org.id);
    expect(data!.slug).toBe(org.slug);
  });

  it("anon sigue pudiendo SELECT services_public", async () => {
    const { data, error } = await anon
      .from("services_public")
      .select("id, organization_id, name, description")
      .eq("organization_id", org.id);

    expect(error).toBeNull();
    expect((data ?? []).map((s) => s.id)).toContain(serviceId);
  });

  it("el calendario público de un visitante sin sesión sigue devolviendo disponibilidad", async () => {
    const { data, error } = await anon.rpc("get_public_availability", {
      p_organization_slug: org.slug,
    });

    expect(error).toBeNull();
    expect((data as unknown[]).length).toBeGreaterThan(0);
  });

  // ================================================================
  // 2. services_public: el DELETE que borraba reservas y pagos
  // ================================================================

  it("anon no puede DELETE services_public de un servicio sin plan, y la Booking CONFIRMED sigue viva", async () => {
    const { data: bookingBefore } = await admin
      .from("bookings")
      .select("status")
      .eq("id", unplannedBookingId)
      .single();
    expect(bookingBefore!.status).toBe("CONFIRMED");

    const { error } = await anon
      .from("services_public")
      .delete()
      .eq("id", unplannedServiceId)
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    expect(await rowExists("services", { id: unplannedServiceId })).toBe(true);
    expect(await rowExists("slot_occurrences", { id: unplannedOccurrenceId })).toBe(true);

    // Lo que se perdía: la reserva no se cancelaba, desaparecía. Por eso
    // se afirma también `cancelled_at is null` -- "sigue CONFIRMED" sola
    // no distinguiría una fila intacta de una recreada.
    const { data: booking } = await admin
      .from("bookings")
      .select("status, cancelled_at")
      .eq("id", unplannedBookingId)
      .single();
    expect(booking).not.toBeNull();
    expect(booking!.status).toBe("CONFIRMED");
    expect(booking!.cancelled_at).toBeNull();
  });

  it("anon no puede DELETE services_public de un servicio con plan global, y el Payment PAID sigue ahí", async () => {
    const { error } = await anon
      .from("services_public")
      .delete()
      .eq("id", globalOnlyServiceId)
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    expect(await rowExists("services", { id: globalOnlyServiceId })).toBe(true);

    const { data: payment } = await admin
      .from("payments")
      .select("status")
      .eq("id", paymentId)
      .single();
    expect(payment).not.toBeNull();
    expect(payment!.status).toBe("PAID");
  });

  it("anon no puede DELETE services_public del servicio que tiene la agenda y la reserva principal", async () => {
    const { error } = await anon.from("services_public").delete().eq("id", serviceId).select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    expect(await rowExists("services", { id: serviceId })).toBe(true);
    expect(await rowExists("slot_occurrences", { id: occurrenceId })).toBe(true);

    const { data: booking } = await admin
      .from("bookings")
      .select("status, cancelled_at")
      .eq("id", bookingId)
      .single();
    expect(booking!.status).toBe("CONFIRMED");
    expect(booking!.cancelled_at).toBeNull();
  });

  it("anon no puede PATCH services_public", async () => {
    const { error } = await anon
      .from("services_public")
      .update({ name: "Defaced", description: "hacked" })
      .eq("id", serviceId)
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    const { data: service } = await admin
      .from("services")
      .select("name, description")
      .eq("id", serviceId)
      .single();
    expect(service!.name).toBe("Pilates");
    expect(service!.description).toBeNull();
  });

  it("anon no puede POST services_public", async () => {
    const before = await rowExists("services", { organization_id: org.id });
    expect(before).toBe(true);

    const { error } = await anon
      .from("services_public")
      .insert({ organization_id: org.id, name: "Servicio fantasma", description: null })
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    const { count } = await admin
      .from("services")
      .select("*", { count: "exact", head: true })
      .eq("organization_id", org.id)
      .eq("name", "Servicio fantasma");
    expect(count ?? 0).toBe(0);
  });

  // ================================================================
  // 3. organizations_public: desfiguración y alta sin invitación
  // ================================================================

  it("anon no puede PATCH organizations_public de un tenant ajeno", async () => {
    const { error } = await anon
      .from("organizations_public")
      .update({ name: "Negocio secuestrado", timezone: "UTC" })
      .eq("id", org.id)
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    const { data: organization } = await admin
      .from("organizations")
      .select("slug, name, timezone")
      .eq("id", org.id)
      .single();
    expect(organization!.slug).toBe(org.slug);
    expect(organization!.name).toBe(org.slug);
    expect(organization!.timezone).toBe("America/Montevideo");
  });

  it("anon no puede POST organizations_public: el gate de invitación no se saltea", async () => {
    const attackerSlug = `p36-fake-${attackToken}`;
    const attackerName = `Organización del atacante ${attackToken}`;

    const { error } = await anon
      .from("organizations_public")
      .insert({
        slug: attackerSlug,
        name: attackerName,
        timezone: "UTC",
      })
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");

    // La organización que el atacante intentó crear no existe. Se mira por
    // slug y también por nombre: si el INSERT hubiera pasado con otro slug
    // (p. ej. reescrito por un trigger), el chequeo por nombre lo delata.
    expect(await rowExists("organizations", { slug: attackerSlug })).toBe(false);
    expect(await rowExists("organizations", { name: attackerName })).toBe(false);
  });

  it("anon no puede DELETE organizations_public", async () => {
    const { error } = await anon
      .from("organizations_public")
      .delete()
      .eq("id", org.id)
      .select();

    expect(error).not.toBeNull();
    expect(error!.code).toBe("42501");
    expect(await rowExists("organizations", { id: org.id })).toBe(true);
  });

  it("el secuestro de slug encadenado (PATCH para liberarlo + POST para reclamarlo) falla en el primer paso", async () => {
    const abandonedSlug = `p36-abandoned-${attackToken}`;
    const impostorName = `Impostor ${attackToken}`;

    const freed = await anon
      .from("organizations_public")
      .update({ slug: abandonedSlug })
      .eq("id", org.id)
      .select();
    expect(freed.error).not.toBeNull();

    const claimed = await anon
      .from("organizations_public")
      .insert({ slug: org.slug, name: impostorName, timezone: "UTC" })
      .select();
    expect(claimed.error).not.toBeNull();

    // Lo que de verdad importa: la URL pública del negocio real sigue
    // resolviendo al negocio real.
    const { data: resolved, error: resolveError } = await anon
      .from("organizations_public")
      .select("id, name")
      .eq("slug", org.slug)
      .maybeSingle();
    expect(resolveError).toBeNull();
    expect(resolved!.id).toBe(org.id);
    expect(resolved!.name).toBe(org.slug);

    // Ninguno de los dos pasos dejó rastro: el PATCH no renombró el slug
    // real (no hay fila con el slug "liberado") y el POST no creó al
    // impostor.
    expect(await rowExists("organizations", { slug: abandonedSlug })).toBe(false);
    expect(await rowExists("organizations", { name: impostorName })).toBe(false);
  });

  // ================================================================
  // 4. `authenticated` tampoco: tener cuenta no es ser dueño de nada
  // ================================================================
  // El REVOKE es para los dos roles de request. Un usuario logueado que no
  // es miembro de la organización es el caso más común de "tengo un JWT
  // válido y ninguna autorización".

  it("un usuario autenticado sin membresía tampoco puede escribir las vistas públicas", async () => {
    const patched = await outsider.client
      .from("organizations_public")
      .update({ name: "Mío ahora" })
      .eq("id", org.id)
      .select();
    expect(patched.error).not.toBeNull();
    expect(patched.error!.code).toBe("42501");

    const deleted = await outsider.client
      .from("services_public")
      .delete()
      .eq("id", serviceId)
      .select();
    expect(deleted.error).not.toBeNull();
    expect(deleted.error!.code).toBe("42501");

    // Y sigue leyendo, como cualquier visitante.
    const { data, error } = await outsider.client
      .from("organizations_public")
      .select("id")
      .eq("id", org.id)
      .maybeSingle();
    expect(error).toBeNull();
    expect(data!.id).toBe(org.id);
  });

  // ================================================================
  // 5. El guardarraíl genérico, para la próxima vista que alguien cree
  // ================================================================
  // Este caso no mira `organizations_public`/`services_public` por nombre:
  // recorre TODA vista de `public`. Los default privileges de Supabase le
  // van a dar los cuatro comandos de escritura a la próxima vista pública
  // que se cree, y la única forma de que eso no vuelva a pasar meses
  // desapercibido es que un test falle solo.

  it("ninguna vista de public tiene INSERT/UPDATE/DELETE/TRUNCATE para anon ni authenticated", async () => {
    const { data, error } = await admin.rpc("audit_public_view_write_grants");

    expect(error).toBeNull();
    // Si esto falla, el mensaje dice exactamente qué vista, qué rol y qué
    // privilegio -- no hace falta ir al catálogo a mano.
    expect(data).toEqual([]);
  });

  // ================================================================
  // 6. organization_members: el OWNER ya no se borra a sí mismo
  // ================================================================

  it("un OWNER no puede borrar su propia fila de organization_members y sigue siendo miembro", async () => {
    const { data, error } = await owner.client
      .from("organization_members")
      .delete()
      .eq("id", ownerMemberId)
      .select();

    // Acá el mecanismo es RLS, no privilegios: sin policy de DELETE no hay
    // error, hay cero filas.
    expect(error).toBeNull();
    expect(data ?? []).toHaveLength(0);

    const { data: member } = await admin
      .from("organization_members")
      .select("is_active, role, cancelled_at")
      .eq("id", ownerMemberId)
      .single();
    expect(member).not.toBeNull();
    expect(member!.is_active).toBe(true);
    expect(member!.role).toBe("OWNER");
    expect(member!.cancelled_at).toBeNull();
  });

  it("revoke_member() sigue siendo la vía correcta y sigue protegiendo al último OWNER", async () => {
    const { error } = await owner.client.rpc("revoke_member", { p_member_id: ownerMemberId });

    expect(error).not.toBeNull();
    expect(error!.message).toContain("LAST_OWNER");
    expect(await rowExists("organization_members", { id: ownerMemberId })).toBe(true);
  });

  it("el OWNER sigue pudiendo dar de alta, actualizar y leer el equipo, y revocar por la vía correcta", async () => {
    const staffUser = await newUser("p36-staff");
    staffUserId = staffUser.id;

    // INSERT (policy organization_members_insert_owner)
    const { data: inserted, error: insertError } = await owner.client
      .from("organization_members")
      .insert({ organization_id: org.id, profile_id: staffUserId, role: "STAFF" })
      .select()
      .single();
    expect(insertError).toBeNull();
    staffMemberId = inserted!.id as string;

    // SELECT
    const { data: roster, error: rosterError } = await owner.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", org.id);
    expect(rosterError).toBeNull();
    expect((roster ?? []).map((m) => m.id)).toContain(staffMemberId);

    // UPDATE (policy organization_members_update_owner). Se toca
    // `created_by` y no `role_id` a propósito: `role_id` es una columna de
    // la Fase 32, y este archivo tiene que pasar contra el historial
    // commiteado, donde esa columna todavía no existe. La variante con
    // `role_id` vive en el test de la Fase 36b.
    const { data: updated, error: updateError } = await owner.client
      .from("organization_members")
      .update({ created_by: owner.id })
      .eq("id", staffMemberId)
      .select();
    expect(updateError).toBeNull();
    expect(updated).toHaveLength(1);

    // DELETE directo del STAFF: también cerrado.
    const { data: deleted, error: deleteError } = await owner.client
      .from("organization_members")
      .delete()
      .eq("id", staffMemberId)
      .select();
    expect(deleteError).toBeNull();
    expect(deleted ?? []).toHaveLength(0);
    expect(await rowExists("organization_members", { id: staffMemberId })).toBe(true);

    // La vía correcta: revoke_member() sobre alguien que no es el último
    // OWNER sigue funcionando, y deja rastro en vez de borrar.
    const { error: revokeError } = await owner.client.rpc("revoke_member", {
      p_member_id: staffMemberId,
    });
    expect(revokeError).toBeNull();

    const { data: revoked } = await admin
      .from("organization_members")
      .select("is_active, cancelled_at, cancellation_reason")
      .eq("id", staffMemberId)
      .single();
    expect(revoked!.is_active).toBe(false);
    expect(revoked!.cancelled_at).not.toBeNull();
    expect(revoked!.cancellation_reason).toBe("REVOKED_BY_ORGANIZATION");
  });

  // Las secciones 7 (`organization_roles`) y 8 (`service_plan_services`) de
  // este archivo se movieron a
  // `phase36b.role-and-plan-scope-delete-closed.test.ts`: su migración
  // (`20260923240000_phase36b_...`) depende de la Fase 32, y hasta que la
  // Fase 32 esté commiteada estos casos no pueden correr contra el
  // historial de git. No se perdió cobertura -- cambió de archivo.
});
