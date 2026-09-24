// Integration tests for ADR-0033 -- roles configurables por organización.
//
// Lo que se prueba acá no es "el booleano guarda bien": es que el permiso
// se aplique donde se aplica de verdad. Cada permiso se ataca por las DOS
// puertas que existen, porque cerrar una sola es el modo de fallar más
// probable de esta feature (ADR-0033 riesgo 1):
//
//   1. PostgREST directo contra la tabla (RLS).
//   2. La RPC `security definer`, que corre como dueña de la tabla y
//      bypassea RLS por completo -- endurecer la policy no la toca.
//
// Requiere una instancia local de Supabase corriendo.

import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  isoDate,
  makeServicePaid,
  payFor,
  type SignedInUser,
} from "./helpers";

type Permissions = {
  can_view_payments?: boolean;
  can_manage_payments?: boolean;
  can_manage_bookings?: boolean;
  can_manage_customers?: boolean;
  can_manage_attendance?: boolean;
};

const createdUserIds: string[] = [];

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

/**
 * Organización con servicio, recurso, regla semanal, un cliente con
 * reserva confirmada y un pago PAID. Es el mínimo que hace falta para que
 * los cinco permisos tengan algo real sobre lo que negar o permitir.
 */
async function setupOrg(prefix: string) {
  const owner = await newUser(prefix);
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

  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service!.id,
      resource_id: resource!.id,
      weekday: 1,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 10,
      created_by: owner.id,
    })
    .select()
    .single();

  const servicePlanId = await makeServicePaid(owner, service!.id);

  const customerUser = await newUser(`${prefix}-cust`);
  const { data: customer } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customerUser.id, created_by: owner.id })
    .select()
    .single();

  await payFor(owner, {
    organizationId: org.id,
    customerId: customer!.id,
    serviceId: service!.id,
    from: isoDate(-15),
    to: isoDate(45),
  });

  const occurrence = await firstFutureOccurrence(owner, rule!.id);
  const { data: booked } = await owner.client.rpc("admin_book_for_customer", {
    p_slot_occurrence_id: occurrence.id,
    p_customer_id: customer!.id,
  });
  expect((booked as { status: string }).status).toBe("OK");
  const bookingId = (booked as { booking: { id: string } }).booking.id;

  return {
    owner,
    org,
    service: service!,
    resource: resource!,
    rule: rule!,
    servicePlanId,
    customerUser,
    customer: customer!,
    occurrence,
    bookingId,
  };
}

/** Un STAFF de la organización, con el rol configurable que se pida. */
async function addStaff(
  owner: SignedInUser,
  org: { id: string },
  prefix: string,
  permissions?: Permissions,
) {
  const staff = await newUser(prefix);

  const { data: member, error: memberError } = await owner.client
    .from("organization_members")
    .insert({
      organization_id: org.id,
      profile_id: staff.id,
      role: "STAFF",
      created_by: owner.id,
    })
    .select()
    .single();
  expect(memberError).toBeNull();

  let roleId: string | null = null;
  if (permissions) {
    const { data: role, error: roleError } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: `Rol ${prefix} ${Math.random().toString(36).slice(2, 8)}`,
      p_can_view_payments: permissions.can_view_payments ?? true,
      p_can_manage_payments: permissions.can_manage_payments ?? true,
      p_can_manage_bookings: permissions.can_manage_bookings ?? true,
      p_can_manage_customers: permissions.can_manage_customers ?? true,
      p_can_manage_attendance: permissions.can_manage_attendance ?? true,
    });
    expect(roleError).toBeNull();
    roleId = (role as { id: string }).id;

    const { error: assignError } = await owner.client.rpc("set_member_role", {
      p_member_id: (member as { id: string }).id,
      p_role_id: roleId,
    });
    expect(assignError).toBeNull();
  }

  return { staff, memberId: (member as { id: string }).id, roleId };
}

describe("ADR-0033 -- roles configurables por organización", () => {
  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ------------------------------------------------------------------
  // Migración / compatibilidad: el día del deploy no cambia nada
  // ------------------------------------------------------------------

  it("toda organización nace con exactamente un rol por defecto que puede todo", async () => {
    const owner = await newUser("p32-seed");
    const org = await createOrganization(owner, "p32-seed-org");

    const { data: roles, error } = await owner.client
      .from("organization_roles")
      .select("*")
      .eq("organization_id", org.id);

    expect(error).toBeNull();
    expect(roles).toHaveLength(1);
    expect(roles![0]).toMatchObject({
      name: "Equipo",
      is_default: true,
      is_active: true,
      can_view_payments: true,
      can_manage_payments: true,
      can_manage_bookings: true,
      can_manage_customers: true,
      can_manage_attendance: true,
    });
  });

  it("un STAFF sin role_id se comporta exactamente como antes de ADR-0033", async () => {
    const ctx = await setupOrg("p32-default");
    // Sin `permissions`: no se le asigna rol, cae en el rol por defecto.
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-default-staff");

    const { data: perms } = await staff.client.rpc("my_organization_permissions", {
      p_organization_id: ctx.org.id,
    });
    expect(perms![0]).toMatchObject({
      role: "STAFF",
      role_name: "Equipo",
      can_view_payments: true,
      can_manage_payments: true,
      can_manage_bookings: true,
      can_manage_customers: true,
      can_manage_attendance: true,
    });

    // Y lo puede hacer de verdad, no sólo decirlo.
    const { data: payments } = await staff.client.from("payments").select("id");
    expect(payments!.length).toBeGreaterThan(0);

    const { error: attendanceError } = await staff.client.rpc("mark_attendance", {
      p_booking_id: ctx.bookingId,
      p_status: "PRESENT",
    });
    expect(attendanceError).toBeNull();

    const { error: customerError } = await staff.client.rpc("create_managed_customer", {
      p_organization_id: ctx.org.id,
      p_display_name: "Cliente de mostrador",
      p_phone: null,
    });
    expect(customerError).toBeNull();
  });

  it("un OWNER nunca se filtra, aunque el rol por defecto de su organización no pueda nada", async () => {
    const ctx = await setupOrg("p32-owner");

    // El OWNER apaga todo en el rol por defecto.
    const { data: defaultRole } = await ctx.owner.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("is_default", true)
      .single();

    const { error } = await ctx.owner.client.rpc("update_organization_role", {
      p_role_id: defaultRole!.id,
      p_can_view_payments: false,
      p_can_manage_payments: false,
      p_can_manage_bookings: false,
      p_can_manage_customers: false,
      p_can_manage_attendance: false,
    });
    expect(error).toBeNull();

    const { data: perms } = await ctx.owner.client.rpc("my_organization_permissions", {
      p_organization_id: ctx.org.id,
    });
    expect(perms![0]).toMatchObject({
      role: "OWNER",
      role_id: null,
      can_view_payments: true,
      can_manage_payments: true,
    });

    const { data: payments } = await ctx.owner.client.from("payments").select("id");
    expect(payments!.length).toBeGreaterThan(0);
  });

  // ------------------------------------------------------------------
  // VIEW_PAYMENTS -- las dos puertas
  // ------------------------------------------------------------------

  it("sin VIEW_PAYMENTS no hay pagos por PostgREST ni por ninguna de las RPCs", async () => {
    const ctx = await setupOrg("p32-nopay");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-nopay-staff", {
      can_view_payments: false,
      can_manage_payments: false,
    });

    // 1. La tabla, directo.
    const { data: payments, error: paymentsError } = await staff.client
      .from("payments")
      .select("id, amount");
    expect(paymentsError).toBeNull();
    expect(payments).toEqual([]);

    // 2. La cobertura derivada del pago: mismo dato por otra tabla.
    const { data: coverage } = await staff.client
      .from("payment_service_coverage")
      .select("id");
    expect(coverage).toEqual([]);

    // 3. Las RPCs security definer, que bypassean RLS.
    const { data: summary } = await staff.client.rpc("organization_payment_summary", {
      p_organization_id: ctx.org.id,
      p_period_start: isoDate(-30),
      p_period_end: isoDate(60),
    });
    expect(summary).toEqual([]);

    const { data: detail } = await staff.client.rpc("customer_payment_detail", {
      p_customer_id: ctx.customer.id,
      p_period_start: isoDate(-30),
      p_period_end: isoDate(60),
    });
    expect(detail).toEqual([]);

    // 4. La cola de cambios de plan también trae precios.
    await admin.from("plan_change_requests").insert({
      organization_id: ctx.org.id,
      customer_id: ctx.customer.id,
      service_plan_id: ctx.servicePlanId,
    });

    const { data: requests } = await staff.client.rpc("organization_plan_change_requests", {
      p_organization_id: ctx.org.id,
      p_include_resolved: true,
    });
    expect(requests).toEqual([]);

    const { data: requestRows } = await staff.client.from("plan_change_requests").select("id");
    expect(requestRows).toEqual([]);
  });

  it("sin VIEW_PAYMENTS sigue viendo su trabajo: agenda, padrón y asistencia", async () => {
    const ctx = await setupOrg("p32-nopay-work");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-nopay-work-staff", {
      can_view_payments: false,
      can_manage_payments: false,
    });

    const { data: customers } = await staff.client.rpc("organization_customers", {
      p_organization_id: ctx.org.id,
    });
    expect(customers!.length).toBeGreaterThan(0);

    const { data: bookings } = await staff.client.rpc("occurrence_bookings", {
      p_slot_occurrence_id: ctx.occurrence.id,
    });
    expect(bookings!.length).toBeGreaterThan(0);

    const { error } = await staff.client.rpc("mark_attendance", {
      p_booking_id: ctx.bookingId,
      p_status: "PRESENT",
    });
    expect(error).toBeNull();
  });

  // ------------------------------------------------------------------
  // MANAGE_PAYMENTS -- ver sí, escribir no
  // ------------------------------------------------------------------

  it("con VIEW_PAYMENTS pero sin MANAGE_PAYMENTS: ve pero no escribe", async () => {
    const ctx = await setupOrg("p32-readonly");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-readonly-staff", {
      can_view_payments: true,
      can_manage_payments: false,
    });

    const { data: payments } = await staff.client.from("payments").select("id, status");
    expect(payments!.length).toBeGreaterThan(0);
    const paymentId = payments![0]!.id as string;

    // INSERT directo: la policy with check lo rechaza.
    const { error: insertError } = await payFor(staff, {
      organizationId: ctx.org.id,
      customerId: ctx.customer.id,
      serviceId: ctx.service.id,
      from: isoDate(60),
      to: isoDate(90),
    });
    expect(insertError).not.toBeNull();

    // UPDATE directo: sin filas alcanzables, no cambia nada.
    await staff.client.from("payments").update({ status: "VOID" }).eq("id", paymentId);
    const { data: after } = await admin.from("payments").select("status").eq("id", paymentId).single();
    expect(after!.status).not.toBe("VOID");

    // Y la RPC, que bypassea RLS, tampoco.
    const { error: rpcError } = await staff.client.rpc("set_payment_status", {
      p_payment_id: paymentId,
      p_status: "VOID",
    });
    expect(rpcError?.message).toContain("NOT_AUTHORIZED");

    // Cerrar un pedido de cambio de plan es cobranza.
    const { data: request } = await admin
      .from("plan_change_requests")
      .insert({
        organization_id: ctx.org.id,
        customer_id: ctx.customer.id,
        service_plan_id: ctx.servicePlanId,
      })
      .select()
      .single();

    const { error: resolveError } = await staff.client.rpc("resolve_plan_change_request", {
      p_request_id: request!.id,
      p_resolution: "APPLIED",
    });
    expect(resolveError?.message).toContain("NOT_AUTHORIZED");
  });

  it("no existe un rol que cobre sin poder ver lo cobrado", async () => {
    const owner = await newUser("p32-check");
    const org = await createOrganization(owner, "p32-check-org");

    const { error } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: "Imposible",
      p_can_view_payments: false,
      p_can_manage_payments: true,
    });
    expect(error?.message).toContain("MANAGE_PAYMENTS_REQUIRES_VIEW");

    // Y tampoco por PostgREST directo: el CHECK está en la tabla.
    const { error: directError } = await owner.client.from("organization_roles").insert({
      organization_id: org.id,
      name: "Imposible directo",
      can_view_payments: false,
      can_manage_payments: true,
    });
    expect(directError).not.toBeNull();
  });

  // ------------------------------------------------------------------
  // MANAGE_BOOKINGS
  // ------------------------------------------------------------------

  it("sin MANAGE_BOOKINGS no anota, no cancela ajeno y no baja una ocurrencia", async () => {
    const ctx = await setupOrg("p32-nobook");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-nobook-staff", {
      can_manage_bookings: false,
    });

    const { error: bookError } = await staff.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: ctx.occurrence.id,
      p_customer_id: ctx.customer.id,
    });
    expect(bookError?.message).toContain("NOT_AUTHORIZED");

    const { error: cancelError } = await staff.client.rpc("cancel_booking", {
      p_booking_id: ctx.bookingId,
    });
    expect(cancelError?.message).toContain("NOT_AUTHORIZED");

    const { error: slotError } = await staff.client.rpc("cancel_slot_occurrence", {
      p_slot_occurrence_id: ctx.occurrence.id,
      p_reason: "SLOT_CANCELLED",
    });
    expect(slotError?.message).toContain("NOT_AUTHORIZED");

    const { error: seriesError } = await staff.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
    });
    expect(seriesError?.message).toContain("NOT_AUTHORIZED");

    const { data: preview } = await staff.client.rpc("admin_preview_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
      p_count: 3,
    });
    expect(preview).toEqual([]);

    // La reserva sigue viva: nada de lo anterior se aplicó a medias.
    const { data: booking } = await admin
      .from("bookings")
      .select("status")
      .eq("id", ctx.bookingId)
      .single();
    expect(booking!.status).toBe("CONFIRMED");
  });

  it("un STAFF sin MANAGE_BOOKINGS sigue pudiendo soltar SU propia reserva", async () => {
    const ctx = await setupOrg("p32-selfbook");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-selfbook-staff", {
      can_manage_bookings: false,
    });

    // El mismo profile es además cliente de la organización.
    const { data: selfCustomer } = await ctx.owner.client
      .from("customers")
      .insert({ organization_id: ctx.org.id, profile_id: staff.id, created_by: ctx.owner.id })
      .select()
      .single();

    await payFor(ctx.owner, {
      organizationId: ctx.org.id,
      customerId: selfCustomer!.id,
      serviceId: ctx.service.id,
      from: isoDate(-15),
      to: isoDate(45),
    });

    const { data: booked } = await ctx.owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: ctx.occurrence.id,
      p_customer_id: selfCustomer!.id,
    });
    const ownBookingId = (booked as { booking: { id: string } }).booking.id;

    const { error } = await staff.client.rpc("cancel_booking", { p_booking_id: ownBookingId });
    expect(error).toBeNull();
  });

  // ------------------------------------------------------------------
  // MANAGE_CUSTOMERS
  // ------------------------------------------------------------------

  it("sin MANAGE_CUSTOMERS no da de alta, no enrola y no emite links de activación", async () => {
    const ctx = await setupOrg("p32-nocust");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-nocust-staff", {
      can_manage_customers: false,
    });

    const { error: createError } = await staff.client.rpc("create_managed_customer", {
      p_organization_id: ctx.org.id,
      p_display_name: "No debería entrar",
      p_phone: "+59899111222",
    });
    expect(createError?.message).toContain("NOT_AUTHORIZED");

    const { error: enrollError } = await staff.client.rpc("enroll_customer_by_email", {
      p_organization_id: ctx.org.id,
      p_email: "alguien@example.com",
    });
    expect(enrollError?.message).toContain("NOT_AUTHORIZED");

    // PostgREST directo contra la tabla.
    const other = await newUser("p32-nocust-target");
    const { error: directError } = await staff.client.from("customers").insert({
      organization_id: ctx.org.id,
      profile_id: other.id,
      created_by: staff.id,
    });
    expect(directError).not.toBeNull();

    // Y tampoco puede darlos de baja.
    await staff.client.from("customers").update({ is_active: false }).eq("id", ctx.customer.id);
    const { data: stillActive } = await admin
      .from("customers")
      .select("is_active")
      .eq("id", ctx.customer.id)
      .single();
    expect(stillActive!.is_active).toBe(true);

    // Un link de activación es acceso a la cuenta de un cliente.
    await ctx.owner.client
      .from("organizations")
      .update({ customer_activation_enabled: true })
      .eq("id", ctx.org.id);
    const { data: managed } = await ctx.owner.client.rpc("create_managed_customer", {
      p_organization_id: ctx.org.id,
      p_display_name: "Sin cuenta",
      p_phone: "+59899333444",
    });

    const { error: activationError } = await staff.client.rpc("issue_customer_activation", {
      p_customer_id: (managed as { id: string }).id,
    });
    expect(activationError?.message).toContain("NOT_AUTHORIZED");

    // Pero el padrón lo sigue viendo: sin eso no puede trabajar (ADR-0033 4.3).
    const { data: roster } = await staff.client.rpc("organization_customers", {
      p_organization_id: ctx.org.id,
    });
    expect(roster!.length).toBeGreaterThan(0);
  });

  // ------------------------------------------------------------------
  // MANAGE_ATTENDANCE
  // ------------------------------------------------------------------

  it("sin MANAGE_ATTENDANCE no pasa lista, pero ve la lista", async () => {
    const ctx = await setupOrg("p32-noatt");
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-noatt-staff", {
      can_manage_attendance: false,
    });

    const { error } = await staff.client.rpc("mark_attendance", {
      p_booking_id: ctx.bookingId,
      p_status: "PRESENT",
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");

    const { data: summary } = await staff.client.rpc("occurrence_attendance_summary", {
      p_slot_occurrence_id: ctx.occurrence.id,
    });
    expect(summary![0]!.reserved).toBeGreaterThan(0);
  });

  // ------------------------------------------------------------------
  // Precios de plan: OWNER en la BASE, no sólo en TypeScript
  // ------------------------------------------------------------------

  it("un STAFF no puede cambiar el precio de un plan ni crear uno, ni siquiera con todos los permisos", async () => {
    const ctx = await setupOrg("p32-plans");
    // Todos los permisos configurables en true: administrar planes no es
    // uno de ellos, es OWNER-only.
    const { staff } = await addStaff(ctx.owner, ctx.org, "p32-plans-staff", {});

    const { data: before } = await admin
      .from("service_plans")
      .select("price, name")
      .eq("id", ctx.servicePlanId)
      .single();

    await staff.client
      .from("service_plans")
      .update({ price: 1, name: "Gratis" })
      .eq("id", ctx.servicePlanId);

    const { data: after } = await admin
      .from("service_plans")
      .select("price, name")
      .eq("id", ctx.servicePlanId)
      .single();
    expect(Number(after!.price)).toBe(Number(before!.price));
    expect(after!.name).toBe(before!.name);

    const { error: createError } = await staff.client.rpc("create_service_plan", {
      p_organization_id: ctx.org.id,
      p_name: "Plan del STAFF",
      p_description: null,
      p_price: 1,
      p_plan_kind: "UNLIMITED",
      p_weekly_quota: null,
      p_billing_type: "MONTHLY",
      p_billing_cycle: "CALENDAR_MONTH",
      p_sort_order: 0,
      p_applies_to_all_services: false,
      p_service_ids: [ctx.service.id],
      p_quota_scope: null,
    });
    expect(createError).not.toBeNull();

    // El OWNER sí puede: la puerta se cerró, no se tapió.
    const { error: ownerUpdate } = await ctx.owner.client
      .from("service_plans")
      .update({ price: 2500 })
      .eq("id", ctx.servicePlanId);
    expect(ownerUpdate).toBeNull();
  });

  // ------------------------------------------------------------------
  // Administrar roles es OWNER-only, y las guardas viven en la base
  // ------------------------------------------------------------------

  it("un STAFF no administra roles ni se amplía el propio", async () => {
    const ctx = await setupOrg("p32-roleadmin");
    // Rol restringido: es el caso peligroso -- si pudiera editar roles,
    // los otros permisos no significarían nada.
    const { staff, memberId, roleId } = await addStaff(ctx.owner, ctx.org, "p32-roleadmin-staff", {
      can_view_payments: false,
      can_manage_payments: false,
    });

    const { error: rpcError } = await staff.client.rpc("create_organization_role", {
      p_organization_id: ctx.org.id,
      p_name: "Rol que se amplía solo",
    });
    expect(rpcError?.message).toContain("NOT_AUTHORIZED");

    const { error: insertError } = await staff.client.from("organization_roles").insert({
      organization_id: ctx.org.id,
      name: "Rol por PostgREST",
    });
    expect(insertError).not.toBeNull();

    // Ve su rol (la pantalla de equipo muestra el nombre) pero no lo edita.
    const { data: roles } = await staff.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id);
    expect(roles!.length).toBeGreaterThan(0);

    await staff.client
      .from("organization_roles")
      .update({ can_manage_payments: true, can_view_payments: true })
      .eq("id", roleId!);

    const { data: afterSelfEdit } = await admin
      .from("organization_roles")
      .select("can_view_payments, can_manage_payments")
      .eq("id", roleId!)
      .single();
    expect(afterSelfEdit).toMatchObject({
      can_view_payments: false,
      can_manage_payments: false,
    });

    // Y tampoco puede reasignarse a sí mismo el rol por defecto, que puede todo.
    const { data: defaultRole } = await admin
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("is_default", true)
      .single();

    const { error: assignError } = await staff.client.rpc("set_member_role", {
      p_member_id: memberId,
      p_role_id: defaultRole!.id,
    });
    expect(assignError?.message).toContain("NOT_AUTHORIZED");

    await staff.client
      .from("organization_members")
      .update({ role_id: defaultRole!.id })
      .eq("id", memberId);

    const { data: member } = await admin
      .from("organization_members")
      .select("role_id")
      .eq("id", memberId)
      .single();
    expect(member!.role_id).toBe(roleId);

    // Cierre real: sigue sin ver pagos después de los cuatro intentos.
    const { data: payments } = await staff.client.from("payments").select("id");
    expect(payments).toEqual([]);
  });

  it("un rol con miembros activos no se desactiva ni se borra", async () => {
    const ctx = await setupOrg("p32-inuse");
    const { roleId } = await addStaff(ctx.owner, ctx.org, "p32-inuse-staff", {
      can_view_payments: false,
      can_manage_payments: false,
    });

    const { error: deactivateError } = await ctx.owner.client.rpc("update_organization_role", {
      p_role_id: roleId,
      p_is_active: false,
    });
    expect(deactivateError?.message).toContain("ROLE_IN_USE");

    // El DELETE directo por PostgREST ya no llega ni al trigger: desde
    // ADR-0037 (Fase 36) `organization_roles` no tiene policy de DELETE, y
    // bajo RLS la ausencia de policy deniega por default -- o sea que el
    // comando no encuentra filas que borrar y termina sin error, con cero
    // filas afectadas. Lo que este caso afirma sigue siendo lo mismo (el
    // rol en uso sobrevive), pero ahora por una razón más fuerte: antes lo
    // salvaba acertar una condición del trigger, ahora la puerta no existe.
    const { data: deleted, error: deleteError } = await ctx.owner.client
      .from("organization_roles")
      .delete()
      .eq("id", roleId!)
      .select();
    expect(deleteError).toBeNull();
    expect(deleted ?? []).toHaveLength(0);

    const { count } = await admin
      .from("organization_roles")
      .select("*", { count: "exact", head: true })
      .eq("id", roleId!);
    expect(count).toBe(1);
  });

  it("siempre queda exactamente un rol por defecto", async () => {
    const ctx = await setupOrg("p32-default-guard");

    const { data: defaultRole } = await ctx.owner.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("is_default", true)
      .single();

    // Quitarle el default al único que lo tiene deja la organización sin
    // rol por defecto -> el constraint trigger diferido lo rechaza.
    const { error } = await ctx.owner.client
      .from("organization_roles")
      .update({ is_default: false })
      .eq("id", defaultRole!.id);
    expect(error?.message).toContain("DEFAULT_ROLE_REQUIRED");

    // Moverlo a otro rol sí se puede, y es atómico.
    const { data: newRole } = await ctx.owner.client.rpc("create_organization_role", {
      p_organization_id: ctx.org.id,
      p_name: "Recepción",
      p_can_view_payments: true,
      p_can_manage_payments: false,
    });

    const { error: moveError } = await ctx.owner.client.rpc("set_organization_role_default", {
      p_role_id: (newRole as { id: string }).id,
    });
    expect(moveError).toBeNull();

    const { data: defaults } = await ctx.owner.client
      .from("organization_roles")
      .select("id, name")
      .eq("organization_id", ctx.org.id)
      .eq("is_default", true);
    expect(defaults).toHaveLength(1);
    expect(defaults![0]!.name).toBe("Recepción");
  });

  // ------------------------------------------------------------------
  // Multi-tenancy y OWNER
  // ------------------------------------------------------------------

  it("un rol de otra organización no se puede asignar ni se puede leer", async () => {
    const a = await setupOrg("p32-tenant-a");
    const b = await setupOrg("p32-tenant-b");

    const { data: roleB } = await b.owner.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", b.org.id)
      .single();

    const { staff } = await addStaff(a.owner, a.org, "p32-tenant-a-staff");
    const { data: memberA } = await a.owner.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", a.org.id)
      .eq("profile_id", staff.id)
      .single();

    const { error: assignError } = await a.owner.client.rpc("set_member_role", {
      p_member_id: memberA!.id,
      p_role_id: roleB!.id,
    });
    expect(assignError).not.toBeNull();

    // Y ni siquiera por PostgREST directo (trigger, no sólo la RPC).
    const { error: directError } = await a.owner.client
      .from("organization_members")
      .update({ role_id: roleB!.id })
      .eq("id", memberA!.id);
    expect(directError?.message).toContain("ROLE_OTHER_ORGANIZATION");

    // Los roles de B no son visibles desde A.
    const { data: leaked } = await a.owner.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", b.org.id);
    expect(leaked).toEqual([]);
  });

  it("un OWNER no lleva rol configurable", async () => {
    const ctx = await setupOrg("p32-owner-role");

    const { data: ownerMember } = await ctx.owner.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("role", "OWNER")
      .single();

    const { data: role } = await ctx.owner.client.rpc("create_organization_role", {
      p_organization_id: ctx.org.id,
      p_name: "Profesor",
      p_can_view_payments: false,
      p_can_manage_payments: false,
    });

    const { error } = await ctx.owner.client.rpc("set_member_role", {
      p_member_id: ownerMember!.id,
      p_role_id: (role as { id: string }).id,
    });
    expect(error?.message).toContain("OWNER_HAS_NO_ROLE");

    const { error: directError } = await ctx.owner.client
      .from("organization_members")
      .update({ role_id: (role as { id: string }).id })
      .eq("id", ownerMember!.id);
    expect(directError).not.toBeNull();
  });

  it("el último OWNER sigue protegido (revoke_member no se ve afectado)", async () => {
    const ctx = await setupOrg("p32-last-owner");

    const { data: ownerMember } = await ctx.owner.client
      .from("organization_members")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("role", "OWNER")
      .single();

    const { error } = await ctx.owner.client.rpc("revoke_member", {
      p_member_id: ownerMember!.id,
    });
    expect(error?.message).toContain("LAST_OWNER");

    // Y revocar a un STAFF con rol sigue funcionando.
    const { memberId } = await addStaff(ctx.owner, ctx.org, "p32-last-owner-staff", {
      can_view_payments: false,
      can_manage_payments: false,
    });
    const { error: revokeError } = await ctx.owner.client.rpc("revoke_member", {
      p_member_id: memberId,
    });
    expect(revokeError).toBeNull();

    // Y al quedar inactivo, pierde todo permiso.
    const { data: perms } = await ctx.owner.client.rpc("my_organization_permissions", {
      p_organization_id: ctx.org.id,
    });
    expect(perms![0]!.role).toBe("OWNER");
  });

  // ------------------------------------------------------------------
  // Contratos nuevos
  // ------------------------------------------------------------------

  it("organization_team() devuelve el rol efectivo de cada miembro", async () => {
    const ctx = await setupOrg("p32-team");
    const { staff: withRole } = await addStaff(ctx.owner, ctx.org, "p32-team-role", {
      can_view_payments: false,
      can_manage_payments: false,
    });
    const { staff: withoutRole } = await addStaff(ctx.owner, ctx.org, "p32-team-norole");

    const { data: team, error } = await ctx.owner.client.rpc("organization_team", {
      p_organization_id: ctx.org.id,
    });
    expect(error).toBeNull();

    const rows = team as Array<{
      profile_id: string;
      role: string;
      role_id: string | null;
      role_name: string | null;
    }>;

    const ownerRow = rows.find((r) => r.role === "OWNER")!;
    expect(ownerRow.role_id).toBeNull();
    expect(ownerRow.role_name).toBeNull();

    const assigned = rows.find((r) => r.profile_id === withRole.id)!;
    expect(assigned.role_name).not.toBeNull();
    expect(assigned.role_name).not.toBe("Equipo");

    // Sin role_id asignado: organization_team() devuelve el rol EFECTIVO,
    // o sea el por defecto -- no null. Es lo que el selector de la
    // pantalla de equipo tiene que mostrar preseleccionado.
    const fallback = rows.find((r) => r.profile_id === withoutRole.id)!;
    expect(fallback.role_name).toBe("Equipo");
    const { data: defaultRole } = await ctx.owner.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id)
      .eq("is_default", true)
      .single();
    expect(fallback.role_id).toBe(defaultRole!.id);
  });

  it("invite_member_by_email() sigue aceptando 3 argumentos y acepta el rol nuevo", async () => {
    const ctx = await setupOrg("p32-invite");

    const legacy = await newUser("p32-invite-legacy");
    const { data: legacyEmail } = await admin.auth.admin.getUserById(legacy.id);
    const { error: legacyError } = await ctx.owner.client.rpc("invite_member_by_email", {
      p_organization_id: ctx.org.id,
      p_email: legacyEmail.user!.email!,
      p_role: "STAFF",
    });
    expect(legacyError).toBeNull();

    const { data: role } = await ctx.owner.client.rpc("create_organization_role", {
      p_organization_id: ctx.org.id,
      p_name: "Profesor invitado",
      p_can_view_payments: false,
      p_can_manage_payments: false,
    });

    const invited = await newUser("p32-invite-role");
    const { data: invitedEmail } = await admin.auth.admin.getUserById(invited.id);
    const { error: inviteError } = await ctx.owner.client.rpc("invite_member_by_email", {
      p_organization_id: ctx.org.id,
      p_email: invitedEmail.user!.email!,
      p_role: "STAFF",
      p_role_id: (role as { id: string }).id,
    });
    expect(inviteError).toBeNull();

    const { data: perms } = await invited.client.rpc("my_organization_permissions", {
      p_organization_id: ctx.org.id,
    });
    expect(perms![0]).toMatchObject({
      role_name: "Profesor invitado",
      can_view_payments: false,
      can_manage_payments: false,
      can_manage_bookings: true,
    });
  });

  it("un no-miembro no obtiene permisos ni ve los roles de la organización", async () => {
    const ctx = await setupOrg("p32-outsider");
    const outsider = await newUser("p32-outsider-user");

    const { data: perms } = await outsider.client.rpc("my_organization_permissions", {
      p_organization_id: ctx.org.id,
    });
    expect(perms).toEqual([]);

    const { data: roles } = await outsider.client
      .from("organization_roles")
      .select("id")
      .eq("organization_id", ctx.org.id);
    expect(roles).toEqual([]);
  });
});
