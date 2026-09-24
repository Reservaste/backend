// Integration tests for Fase 34 -- límites de permiso.
//
// Los cuatro hallazgos de la auditoría de ADR-0031/0032/0033. Los dos
// primeros son la misma regla vista desde sus dos lados:
//
//   La autorización va en el punto de entrada público, nunca en un helper
//   compartido que también corre como efecto colateral interno de otra
//   escritura.
//
//   * Fix 1 (falso negativo): el chequeo estaba adentro del helper, así
//     que la reconciliación automática que dispara un pago le exigía
//     MANAGE_BOOKINGS al cajero y abortaba el pago entero.
//   * Fix 2 (falso positivo): dos entradas públicas que cancelan reservas
//     en masa pedían permisos distintos.
//
// Fix 3 y Fix 4 son la misma forma en otra capa: una policy de UPDATE que
// no distingue columnas deja escribir estado que no le corresponde al
// actor.
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
  type SignedInUser,
} from "./helpers";

type Permissions = {
  can_view_payments: boolean;
  can_manage_payments: boolean;
  can_manage_bookings: boolean;
  can_manage_customers: boolean;
  can_manage_attendance: boolean;
};

const ALL_FALSE: Permissions = {
  can_view_payments: false,
  can_manage_payments: false,
  can_manage_bookings: false,
  can_manage_customers: false,
  can_manage_attendance: false,
};

const createdUserIds: string[] = [];

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

/** Un STAFF con un rol configurable exacto (ADR-0033). */
async function addStaff(
  owner: SignedInUser,
  org: { id: string },
  prefix: string,
  permissions: Permissions,
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

  const { data: role, error: roleError } = await owner.client.rpc("create_organization_role", {
    p_organization_id: org.id,
    p_name: `Rol ${prefix} ${Math.random().toString(36).slice(2, 8)}`,
    p_can_view_payments: permissions.can_view_payments,
    p_can_manage_payments: permissions.can_manage_payments,
    p_can_manage_bookings: permissions.can_manage_bookings,
    p_can_manage_customers: permissions.can_manage_customers,
    p_can_manage_attendance: permissions.can_manage_attendance,
  });
  expect(roleError).toBeNull();

  const { error: assignError } = await owner.client.rpc("set_member_role", {
    p_member_id: (member as { id: string }).id,
    p_role_id: (role as { id: string }).id,
  });
  expect(assignError).toBeNull();

  return { staff, memberId: (member as { id: string }).id, roleId: (role as { id: string }).id };
}

/** Servicio + recurso + regla semanal + cliente. El mínimo reutilizable. */
async function setupOrg(prefix: string, opts: { paid: boolean; weekday?: number }) {
  const owner = await newUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service, error: serviceError } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "Pilates", created_by: owner.id })
    .select()
    .single();
  expect(serviceError).toBeNull();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  const servicePlanId = opts.paid ? await makeServicePaid(owner, service!.id) : null;

  const { data: rule, error: ruleError } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service!.id,
      resource_id: resource!.id,
      weekday: opts.weekday ?? 3,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 10,
      created_by: owner.id,
    })
    .select()
    .single();
  expect(ruleError).toBeNull();

  const customerUser = await newUser(`${prefix}-cust`);
  const { data: customer, error: customerError } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customerUser.id, created_by: owner.id })
    .select()
    .single();
  expect(customerError).toBeNull();

  return {
    owner,
    org,
    service: service!,
    resource: resource!,
    rule: rule!,
    servicePlanId,
    customerUser,
    customer: customer!,
  };
}

describe("Fase 34 -- límites de permiso", () => {
  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ------------------------------------------------------------------
  // Fix 1 -- MANAGE_PAYMENTS sin MANAGE_BOOKINGS tiene que poder cobrar
  // ------------------------------------------------------------------

  it("un rol que cobra pero no gestiona reservas puede registrar un pago PAID de un cliente con fechas NOT_GENERATED pendientes", async () => {
    const ctx = await setupOrg("p34-cash", { paid: true });
    // "Recepción": cobra, NO edita reservas. A propósito.
    const { staff: cashier } = await addStaff(ctx.owner, ctx.org, "p34-cashier", {
      ...ALL_FALSE,
      can_view_payments: true,
      can_manage_payments: true,
      can_manage_customers: true,
    });

    // El horario fijo lo crea el OWNER. El cliente no pagó todavía, así
    // que todas las fechas nacen NOT_GENERATED / PAYMENT_REQUIRED.
    const { error: seriesError } = await ctx.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
    });
    expect(seriesError).toBeNull();

    const { data: pending } = await admin
      .from("bookings")
      .select("id, status, not_generated_reason")
      .eq("customer_id", ctx.customer.id);
    expect(
      (pending ?? []).some(
        (b) => b.status === "NOT_GENERATED" && b.not_generated_reason === "PAYMENT_REQUIRED",
      ),
    ).toBe(true);

    // Acá estaba la regresión: el trigger de reconciliación corría con el
    // auth.uid() del cajero y abortaba el INSERT entero con NOT_AUTHORIZED.
    const { data: payment, error: paymentError } = await cashier.client
      .from("payments")
      .insert({
        organization_id: ctx.org.id,
        customer_id: ctx.customer.id,
        service_id: ctx.service.id,
        service_plan_id: ctx.servicePlanId,
        amount: 2000,
        status: "PAID",
        period_start: isoDate(-15),
        period_end: isoDate(45),
      })
      .select()
      .single();
    expect(paymentError).toBeNull();
    expect(payment).not.toBeNull();

    // Y la reconciliación efectivamente corrió: alguna fecha se confirmó.
    const { data: after } = await admin
      .from("bookings")
      .select("id, status")
      .eq("customer_id", ctx.customer.id)
      .eq("status", "CONFIRMED");
    expect((after ?? []).length).toBeGreaterThan(0);
  });

  it("el mismo rol puede pasar un pago PENDING a PAID sobre un cliente con fechas pendientes", async () => {
    const ctx = await setupOrg("p34-setst", { paid: true });
    const { staff: cashier } = await addStaff(ctx.owner, ctx.org, "p34-cashier2", {
      ...ALL_FALSE,
      can_view_payments: true,
      can_manage_payments: true,
    });

    await ctx.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
    });

    const { data: pendingPayment, error: insertError } = await cashier.client
      .from("payments")
      .insert({
        organization_id: ctx.org.id,
        customer_id: ctx.customer.id,
        service_id: ctx.service.id,
        service_plan_id: ctx.servicePlanId,
        amount: 2000,
        status: "PENDING",
        period_start: isoDate(-15),
        period_end: isoDate(45),
      })
      .select()
      .single();
    expect(insertError).toBeNull();

    const { error: statusError } = await cashier.client.rpc("set_payment_status", {
      p_payment_id: (pendingPayment as { id: string }).id,
      p_status: "PAID",
    });
    expect(statusError).toBeNull();

    const { data: after } = await admin
      .from("bookings")
      .select("id, status")
      .eq("customer_id", ctx.customer.id)
      .eq("status", "CONFIRMED");
    expect((after ?? []).length).toBeGreaterThan(0);
  });

  it("apagar payment_required (edición de servicio de cualquier miembro) reconcilia sin exigir MANAGE_BOOKINGS", async () => {
    const ctx = await setupOrg("p34-nopay", { paid: true });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-nopay-staff", ALL_FALSE);

    await ctx.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
    });

    // La otra cascada que terminaba en retry_not_generated_booking()
    // (trigger services_reconcile_on_payment_not_required, Fase 15).
    const { error } = await staff.client
      .from("services")
      .update({ payment_required: false })
      .eq("id", ctx.service.id);
    expect(error).toBeNull();

    const { data: after } = await admin
      .from("bookings")
      .select("id, status")
      .eq("customer_id", ctx.customer.id)
      .eq("status", "CONFIRMED");
    expect((after ?? []).length).toBeGreaterThan(0);
  });

  it("la RPC pública retry_not_generated_booking() sigue exigiendo MANAGE_BOOKINGS", async () => {
    const ctx = await setupOrg("p34-retry", { paid: true });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-retry-staff", ALL_FALSE);

    await ctx.owner.client.rpc("admin_create_recurring_booking", {
      p_schedule_rule_id: ctx.rule.id,
      p_customer_id: ctx.customer.id,
    });

    const { data: pending } = await admin
      .from("bookings")
      .select("id")
      .eq("customer_id", ctx.customer.id)
      .eq("status", "NOT_GENERATED")
      .limit(1);
    const bookingId = pending![0]!.id as string;

    const denied = await staff.client.rpc("retry_not_generated_booking", {
      p_booking_id: bookingId,
    });
    expect(denied.error?.message).toContain("NOT_AUTHORIZED");

    const allowed = await ctx.owner.client.rpc("retry_not_generated_booking", {
      p_booking_id: bookingId,
    });
    expect(allowed.error).toBeNull();
  });

  it("el helper interno no es alcanzable como RPC", async () => {
    const ctx = await setupOrg("p34-internal", { paid: false });
    const { error } = await ctx.owner.client.rpc("internal_retry_not_generated_booking", {
      p_booking_id: ctx.customer.id,
    });
    expect(error).not.toBeNull();
  });

  // ------------------------------------------------------------------
  // Fix 2 -- discontinue_schedule_rule() exige MANAGE_BOOKINGS
  // ------------------------------------------------------------------

  it("un STAFF sin MANAGE_BOOKINGS no puede discontinuar un horario ni cancelar sus reservas", async () => {
    const ctx = await setupOrg("p34-disc", { paid: false, weekday: 2 });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-disc-staff", ALL_FALSE);

    const occurrence = await firstFutureOccurrence(ctx.owner, ctx.rule.id);
    const { data: booked } = await ctx.owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence.id,
      p_customer_id: ctx.customer.id,
    });
    expect((booked as { status: string }).status).toBe("OK");
    const bookingId = (booked as { booking: { id: string } }).booking.id;

    const { error } = await staff.client.rpc("discontinue_schedule_rule", {
      p_schedule_rule_id: ctx.rule.id,
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");

    // Nada quedó cancelado: ni la regla, ni la ocurrencia, ni la reserva.
    const { data: rule } = await admin
      .from("schedule_rules")
      .select("is_active, cancelled_at")
      .eq("id", ctx.rule.id)
      .single();
    expect(rule!.is_active).toBe(true);
    expect(rule!.cancelled_at).toBeNull();

    const { data: occ } = await admin
      .from("slot_occurrences")
      .select("status")
      .eq("id", occurrence.id)
      .single();
    expect(occ!.status).toBe("ACTIVE");

    const { data: booking } = await admin
      .from("bookings")
      .select("status")
      .eq("id", bookingId)
      .single();
    expect(booking!.status).toBe("CONFIRMED");
  });

  it("el grupo de horarios hereda el gate: sin MANAGE_BOOKINGS no cancela ninguna regla", async () => {
    const ctx = await setupOrg("p34-group", { paid: false });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-group-staff", ALL_FALSE);

    const { data: groupRules, error: groupError } = await ctx.owner.client.rpc(
      "create_schedule_rule_group",
      {
        p_service_id: ctx.service.id,
        p_resource_id: ctx.resource.id,
        p_weekdays: [1, 4],
        p_local_start_time: "18:00",
        p_duration_minutes: 60,
        p_capacity: 5,
      },
    );
    expect(groupError).toBeNull();
    const groupId = (groupRules as { group_id: string }[])[0]!.group_id;

    const { error } = await staff.client.rpc("discontinue_schedule_rule_group", {
      p_group_id: groupId,
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");

    const { data: rules } = await admin
      .from("schedule_rules")
      .select("is_active")
      .eq("group_id", groupId);
    expect(rules!.length).toBe(2);
    expect(rules!.every((r) => r.is_active)).toBe(true);
  });

  it("un STAFF con MANAGE_BOOKINGS sí puede discontinuar el horario (el camino legítimo no se rompe)", async () => {
    const ctx = await setupOrg("p34-disc-ok", { paid: false, weekday: 4 });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-disc-ok-staff", {
      ...ALL_FALSE,
      can_manage_bookings: true,
    });

    const occurrence = await firstFutureOccurrence(ctx.owner, ctx.rule.id);
    const { data: booked } = await ctx.owner.client.rpc("admin_book_for_customer", {
      p_slot_occurrence_id: occurrence.id,
      p_customer_id: ctx.customer.id,
    });
    const bookingId = (booked as { booking: { id: string } }).booking.id;

    const { error } = await staff.client.rpc("discontinue_schedule_rule", {
      p_schedule_rule_id: ctx.rule.id,
    });
    expect(error).toBeNull();

    const { data: rule } = await admin
      .from("schedule_rules")
      .select("is_active, cancellation_reason")
      .eq("id", ctx.rule.id)
      .single();
    expect(rule!.is_active).toBe(false);
    expect(rule!.cancellation_reason).toBe("DISCONTINUED_BY_ORGANIZATION");

    const { data: booking } = await admin
      .from("bookings")
      .select("status, cancellation_reason")
      .eq("id", bookingId)
      .single();
    expect(booking!.status).toBe("CANCELLED");
    expect(booking!.cancellation_reason).toBe("RULE_DISCONTINUED");
  });

  it("editar un horario sin cancelar nada sigue siendo de cualquier miembro", async () => {
    const ctx = await setupOrg("p34-edit", { paid: false, weekday: 5 });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-edit-staff", ALL_FALSE);

    const { error } = await staff.client
      .from("schedule_rules")
      .update({ capacity: 12 })
      .eq("id", ctx.rule.id);
    expect(error).toBeNull();

    const { data: rule } = await admin
      .from("schedule_rules")
      .select("capacity")
      .eq("id", ctx.rule.id)
      .single();
    expect(rule!.capacity).toBe(12);
  });

  // ------------------------------------------------------------------
  // Fix 3 -- el OWNER no se auto-reactiva ni se sube de plan
  // ------------------------------------------------------------------

  it("el OWNER no puede cambiar subscription_status / plan_code / trial_ends_at / current_period_end por PATCH", async () => {
    const owner = await newUser("p34-sub");
    const org = await createOrganization(owner, "p34-sub-org");

    await admin
      .from("organizations")
      .update({ subscription_status: "SUSPENDED" })
      .eq("id", org.id);

    for (const patch of [
      { subscription_status: "ACTIVE" },
      // La organización nace en `full`: hay que pedir OTRO plan para que
      // el trigger vea un cambio real (un PATCH que no cambia nada no es
      // una escalada).
      { plan_code: "pro" },
      { trial_ends_at: new Date(Date.now() + 86400000 * 365).toISOString() },
      { current_period_end: new Date(Date.now() + 86400000 * 365).toISOString() },
    ]) {
      const { error } = await owner.client.from("organizations").update(patch).eq("id", org.id);
      expect(error?.message, `patch ${JSON.stringify(patch)}`).toContain("NOT_AUTHORIZED");
    }

    const { data: after } = await admin
      .from("organizations")
      .select("subscription_status, plan_code")
      .eq("id", org.id)
      .single();
    expect(after!.subscription_status).toBe("SUSPENDED");
  });

  it("el OWNER sigue editando la configuración de su organización", async () => {
    const owner = await newUser("p34-cfg");
    const org = await createOrganization(owner, "p34-cfg-org");

    const { error } = await owner.client
      .from("organizations")
      .update({ name: "Nombre nuevo", timezone: "America/Argentina/Buenos_Aires" })
      .eq("id", org.id);
    expect(error).toBeNull();

    const { data: after } = await admin
      .from("organizations")
      .select("name")
      .eq("id", org.id)
      .single();
    expect(after!.name).toBe("Nombre nuevo");
  });

  it("un platform admin real sigue cambiando la suscripción vía set_organization_subscription()", async () => {
    const owner = await newUser("p34-padmin-owner");
    const org = await createOrganization(owner, "p34-padmin-org");

    const platformAdmin = await newUser("p34-padmin");
    const { error: grantError } = await admin
      .from("platform_admins")
      .insert({ profile_id: platformAdmin.id, note: "fase 34 test" });
    expect(grantError).toBeNull();

    const { error } = await platformAdmin.client.rpc("set_organization_subscription", {
      p_organization_id: org.id,
      p_plan_code: "pro",
      p_status: "SUSPENDED",
      p_current_period_end: null,
    });
    expect(error).toBeNull();

    const { data: after } = await admin
      .from("organizations")
      .select("plan_code, subscription_status")
      .eq("id", org.id)
      .single();
    expect(after!.plan_code).toBe("pro");
    expect(after!.subscription_status).toBe("SUSPENDED");
  });

  // ------------------------------------------------------------------
  // Fix 4 -- services.price sólo lo cambia el OWNER
  // ------------------------------------------------------------------

  it("un STAFF no puede cambiar services.price, con permisos o sin ellos", async () => {
    const ctx = await setupOrg("p34-price", { paid: false });
    const { staff: nobody } = await addStaff(ctx.owner, ctx.org, "p34-price-nobody", ALL_FALSE);
    const { staff: everything } = await addStaff(ctx.owner, ctx.org, "p34-price-all", {
      can_view_payments: true,
      can_manage_payments: true,
      can_manage_bookings: true,
      can_manage_customers: true,
      can_manage_attendance: true,
    });

    for (const [label, client] of [
      ["sin permisos", nobody.client],
      ["con los cinco permisos", everything.client],
    ] as const) {
      const { error } = await client
        .from("services")
        .update({ price: 1 })
        .eq("id", ctx.service.id);
      expect(error?.message, label).toContain("NOT_AUTHORIZED");
    }

    const { data: after } = await admin
      .from("services")
      .select("price")
      .eq("id", ctx.service.id)
      .single();
    expect(after!.price).toBeNull();
  });

  it("el OWNER sí puede cambiar services.price, y el resto de columnas sigue siendo de cualquier miembro", async () => {
    const ctx = await setupOrg("p34-price-ok", { paid: false });
    const { staff } = await addStaff(ctx.owner, ctx.org, "p34-price-ok-staff", ALL_FALSE);

    const { error: ownerError } = await ctx.owner.client
      .from("services")
      .update({ price: 1234 })
      .eq("id", ctx.service.id);
    expect(ownerError).toBeNull();

    const { error: staffError } = await staff.client
      .from("services")
      .update({ description: "editable por cualquier miembro" })
      .eq("id", ctx.service.id);
    expect(staffError).toBeNull();

    const { data: after } = await admin
      .from("services")
      .select("price, description")
      .eq("id", ctx.service.id)
      .single();
    expect(Number(after!.price)).toBe(1234);
    expect(after!.description).toBe("editable por cualquier miembro");
  });
});
