// Integration tests for Phase 44 (ADR-0046): quote_booking() / book_slot_paying(),
// the mostrador-only "cobrar un turno suelto" RPCs. Requires the Supabase
// project configured via SUPABASE_URL/SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY
// (see test/helpers.ts) with this phase's migration already applied.

import { afterAll, describe, expect, it } from "vitest";
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

async function setupOrgWithService(
  prefix: string,
  paymentRequired: boolean,
) {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`);

  const { data: service } = await owner.client
    .from("services")
    .insert({
      organization_id: org.id,
      name: "Pilates",
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

async function enroll(owner: SignedInUser, org: { id: string }, prefix: string) {
  const customer = await createSignedInUser(prefix);
  const { data: row } = await owner.client
    .from("customers")
    .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
    .select()
    .single();
  return { customer, customerRow: row! as { id: string } };
}

describe("Phase 44: quote_booking() / book_slot_paying() (ADR-0046)", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("(a) crea Payment PAID + Booking CONFIRMED atomicamente para un cliente nuevo sin booking previa", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-a", true);
    createdUserIds.push(owner.id);

    const planId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 800,
    });
    const rule = await createRule(owner, org, service, resource, 2, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-a-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await owner.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    expect(data.status).toBe("OK");
    expect(data.booking.status).toBe("CONFIRMED");
    expect(data.booking.customer_id).toBe(customerRow.id);
    expect(data.payment.status).toBe("PAID");
    expect(data.payment.amount).toBe(800);
    expect(data.payment.service_plan_id).toBe(planId);

    const { count: bookingCount } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id)
      .eq("status", "CONFIRMED");
    expect(bookingCount).toBe(1);

    const { count: paymentCount } = await owner.client
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id)
      .eq("status", "PAID");
    expect(paymentCount).toBe(1);
  });

  it("(b) si la Booking ya existia (servicio gratis con DROP_IN opcional), solo crea el Payment -- nunca duplica la Booking", async () => {
    // payment_required=false a proposito: es el caso de negocio que
    // ADR-0046 resolucion 2 cita explicitamente ("un negocio con
    // payment_required=false que igual quiere dejar registro de un cobro
    // hecho en efectivo despues del servicio"). El cliente ya se anoto
    // solo (book_slot(), gratis) antes de que el mostrador le cobre.
    const { owner, org, service, resource } = await setupOrgWithService("p44-b", false);
    createdUserIds.push(owner.id);

    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 500,
    });
    const rule = await createRule(owner, org, service, resource, 3, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-b-cust");
    createdUserIds.push(customer.id);

    const { data: bookData, error: bookError } = await customer.client.rpc("book_slot", {
      p_slot_occurrence_id: occ.id,
    });
    expect(bookError).toBeNull();
    expect(bookData.status).toBe("OK");
    const existingBookingId = bookData.booking.id as string;

    const { data, error } = await owner.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    expect(data.status).toBe("OK");
    expect(data.booking.id).toBe(existingBookingId);
    expect(data.payment.status).toBe("PAID");
    expect(data.payment.amount).toBe(500);

    const { count: bookingCount } = await owner.client
      .from("bookings")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id)
      .eq("status", "CONFIRMED");
    expect(bookingCount).toBe(1);
  });

  it("(c) ALREADY_COVERED si ya esta pago (plan de periodo vigente) -- no cobra de nuevo", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-c", true);
    createdUserIds.push(owner.id);

    const unlimitedPlanId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "UNLIMITED",
      price: 2500,
    });
    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 800,
    });
    const rule = await createRule(owner, org, service, resource, 4, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-c-cust");
    createdUserIds.push(customer.id);

    await payFor(owner, {
      organizationId: org.id,
      customerId: customerRow.id,
      serviceId: service.id,
      from: isoDate(-2),
      to: isoDate(35),
      servicePlanId: unlimitedPlanId,
    });

    const { data: bookData, error: bookError } = await customer.client.rpc("book_slot", {
      p_slot_occurrence_id: occ.id,
    });
    expect(bookError).toBeNull();
    expect(bookData.status).toBe("OK");

    const { data, error } = await owner.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    expect(data.status).toBe("ALREADY_COVERED");

    const { count: paymentCount } = await owner.client
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id);
    expect(paymentCount).toBe(0);
  });

  it(
    "(d) doble cobro concurrente -> exactamente uno gana, el otro ALREADY_PAID (servicio gratis con DROP_IN opcional: " +
      "para un servicio payment_required=true el mismo lock de la ocurrencia hace que el segundo, tras esperar, re-evalue " +
      "cobertura y vea el pago del primero -> ALREADY_COVERED, no ALREADY_PAID; el indice unico solo se ejercita cuando " +
      "la cobertura no se vuelve a mirar, que es exactamente el camino payment_required=false de la resolucion 2)",
    async () => {
      const { owner, org, service, resource } = await setupOrgWithService("p44-d", false);
      createdUserIds.push(owner.id);

      await createServicePlan(owner, {
        organizationId: org.id,
        serviceId: service.id,
        planKind: "DROP_IN",
        price: 500,
      });
      const rule = await createRule(owner, org, service, resource, 5, 5);
      const occ = await firstFutureOccurrence(owner, rule.id);

      const { customer, customerRow } = await enroll(owner, org, "p44-d-cust");
      createdUserIds.push(customer.id);

      const [resA, resB] = await Promise.all([
        owner.client.rpc("book_slot_paying", { p_slot_occurrence_id: occ.id, p_customer_id: customerRow.id }),
        owner.client.rpc("book_slot_paying", { p_slot_occurrence_id: occ.id, p_customer_id: customerRow.id }),
      ]);

      const statuses = [resA.data?.status, resB.data?.status].sort();
      expect(statuses).toEqual(["ALREADY_PAID", "OK"]);

      const { count: paymentCount } = await owner.client
        .from("payments")
        .select("id", { count: "exact", head: true })
        .eq("customer_id", customerRow.id)
        .eq("slot_occurrence_id", occ.id)
        .eq("status", "PAID");
      expect(paymentCount).toBe(1);

      const { count: bookingCount } = await owner.client
        .from("bookings")
        .select("id", { count: "exact", head: true })
        .eq("customer_id", customerRow.id)
        .eq("slot_occurrence_id", occ.id)
        .eq("status", "CONFIRMED");
      expect(bookingCount).toBe(1);
    },
  );

  it("(e) CUSTOMER_NOT_IN_ORG si el cliente pertenece a otra organizacion (cross-tenant)", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-e", true);
    createdUserIds.push(owner.id);

    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 800,
    });
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const otherOwner = await createSignedInUser("p44-e-other-owner");
    createdUserIds.push(otherOwner.id);
    const otherOrg = await createOrganization(otherOwner, "p44-e-other-org");
    const { customer: otherCustomer, customerRow: otherCustomerRow } = await enroll(
      otherOwner,
      otherOrg,
      "p44-e-other-cust",
    );
    createdUserIds.push(otherCustomer.id);

    const { data, error } = await owner.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: otherCustomerRow.id,
    });
    expect(error).toBeNull();
    expect(data.status).toBe("CUSTOMER_NOT_IN_ORG");
  });

  it("(f) un cliente NO puede invocar book_slot_paying -- solo staff con MANAGE_BOOKINGS", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-f", true);
    createdUserIds.push(owner.id);

    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 800,
    });
    const rule = await createRule(owner, org, service, resource, 2, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-f-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await customer.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
  });

  it("(g) quote_booking: el propio cliente puede consultar su cobertura, pero no la de otro cliente", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-g", true);
    createdUserIds.push(owner.id);

    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "DROP_IN",
      price: 800,
    });
    const rule = await createRule(owner, org, service, resource, 3, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-g-cust");
    createdUserIds.push(customer.id);
    const { customer: otherCustomer, customerRow: otherCustomerRow } = await enroll(owner, org, "p44-g-other");
    createdUserIds.push(otherCustomer.id);

    const { data: ownQuote, error: ownError } = await customer.client.rpc("quote_booking", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(ownError).toBeNull();
    expect(ownQuote).toHaveLength(1);
    expect(ownQuote![0].can_book).toBe(false);
    expect(ownQuote![0].reason).toBe("PAYMENT_REQUIRED");
    expect(ownQuote![0].coverage_path).toBe("NONE");
    expect(ownQuote![0].price).toBe(800);

    const { data: otherQuote, error: otherError } = await customer.client.rpc("quote_booking", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: otherCustomerRow.id,
    });
    expect(otherQuote).toBeNull();
    expect(otherError).not.toBeNull();

    // El mostrador si puede pedir el quote de cualquier cliente de su organizacion.
    const { data: staffQuote, error: staffError } = await owner.client.rpc("quote_booking", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: otherCustomerRow.id,
    });
    expect(staffError).toBeNull();
    expect(staffQuote).toHaveLength(1);
    expect(staffQuote![0].reason).toBe("PAYMENT_REQUIRED");
  });

  it("(h) NO_DROP_IN_PLAN si el servicio no tiene un plan DROP_IN activo", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-h", true);
    createdUserIds.push(owner.id);

    // Un UNLIMITED existe (y el servicio exige pago), pero ningun DROP_IN.
    await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: service.id,
      planKind: "UNLIMITED",
      price: 2500,
    });
    const rule = await createRule(owner, org, service, resource, 4, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);

    const { customer, customerRow } = await enroll(owner, org, "p44-h-cust");
    createdUserIds.push(customer.id);

    const { data, error } = await owner.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(error).toBeNull();
    expect(data.status).toBe("NO_DROP_IN_PLAN");
  });

  // ---- Regresiones del gate de security-engineer (ADR-0046) ----

  it("(i) un DROP_IN applies_to_all_services de OTRA organizacion nunca se resuelve para esta (cross-tenant)", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-i", true);
    createdUserIds.push(owner.id);
    const rule = await createRule(owner, org, service, resource, 5, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);
    const { customer, customerRow } = await enroll(owner, org, "p44-i-cust");
    createdUserIds.push(customer.id);

    const other = await setupOrgWithService("p44-i-other", true);
    createdUserIds.push(other.owner.id);
    const { data: foreignPlan, error: foreignError } = await other.owner.client.rpc("create_service_plan", {
      p_organization_id: other.org.id,
      p_name: "Suelta global",
      p_description: null,
      p_price: 1,
      p_plan_kind: "DROP_IN",
      p_weekly_quota: null,
      p_billing_type: "ONE_TIME",
      p_billing_cycle: null,
      p_sort_order: 0,
      p_applies_to_all_services: true,
      p_service_ids: null,
      p_quota_scope: null,
    });
    expect(foreignError).toBeNull();

    try {
      const { data, error } = await owner.client.rpc("book_slot_paying", {
        p_slot_occurrence_id: occ.id,
        p_customer_id: customerRow.id,
      });
      expect(error).toBeNull();
      expect(data.status).toBe("NO_DROP_IN_PLAN");

      const { data: quote } = await owner.client.rpc("quote_booking", {
        p_slot_occurrence_id: occ.id,
        p_customer_id: customerRow.id,
      });
      expect(quote![0].price).toBeNull();

      const { data: agenda } = await owner.client.rpc("agenda_occurrences", {
        p_organization_id: org.id,
        p_from: new Date(Date.now() - 86_400_000).toISOString(),
        p_to: new Date(Date.now() + 30 * 86_400_000).toISOString(),
      });
      const row = (agenda as Array<{ id: string; drop_in_plan_id: string | null }>).find((r) => r.id === occ.id);
      expect(row?.drop_in_plan_id ?? null).toBeNull();
    } finally {
      // Nunca dejar un DROP_IN global activo en la base compartida.
      await other.owner.client
        .from("service_plans")
        .update({ is_active: false })
        .eq("id", (foreignPlan as { id: string }).id);
    }
  });

  async function addStaffWithRole(
    owner: SignedInUser,
    org: { id: string },
    prefix: string,
    perms: { payments: boolean; bookings: boolean },
  ) {
    const staff = await createSignedInUser(prefix);
    createdUserIds.push(staff.id);
    const { data: member, error: memberError } = await owner.client
      .from("organization_members")
      .insert({ organization_id: org.id, profile_id: staff.id, role: "STAFF", created_by: owner.id })
      .select()
      .single();
    expect(memberError).toBeNull();
    const { data: role, error: roleError } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: `Rol ${prefix} ${Math.random().toString(36).slice(2, 8)}`,
      p_can_view_payments: perms.payments,
      p_can_manage_payments: perms.payments,
      p_can_manage_bookings: perms.bookings,
      p_can_manage_customers: false,
      p_can_manage_attendance: false,
    });
    expect(roleError).toBeNull();
    const { error: assignError } = await owner.client.rpc("set_member_role", {
      p_member_id: (member as { id: string }).id,
      p_role_id: (role as { id: string }).id,
    });
    expect(assignError).toBeNull();
    return staff;
  }

  it("(j) permisos: MANAGE_BOOKINGS sin MANAGE_PAYMENTS no cobra; MANAGE_PAYMENTS sin MANAGE_BOOKINGS cobra lo ya anotado pero no anota", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-j", true);
    createdUserIds.push(owner.id);
    await createServicePlan(owner, { organizationId: org.id, serviceId: service.id, planKind: "DROP_IN", price: 800 });
    const rule = await createRule(owner, org, service, resource, 6, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);
    const { customer, customerRow } = await enroll(owner, org, "p44-j-cust");
    createdUserIds.push(customer.id);

    const bookingsOnly = await addStaffWithRole(owner, org, "p44-j-book", { payments: false, bookings: true });
    const paymentsOnly = await addStaffWithRole(owner, org, "p44-j-pay", { payments: true, bookings: false });

    // Vector original: PAID con amount 0 para esquivar PAYMENT_REQUIRED.
    const denied = await bookingsOnly.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
      p_amount: 0,
    });
    expect(denied.data).toBeNull();
    expect(denied.error).not.toBeNull();

    // Cajero: no puede crear la Booking.
    const cannotBook = await paymentsOnly.client.rpc("book_slot_paying", {
      p_slot_occurrence_id: occ.id,
      p_customer_id: customerRow.id,
    });
    expect(cannotBook.data).toBeNull();
    expect(cannotBook.error).not.toBeNull();

    const { count: none } = await owner.client
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRow.id)
      .eq("slot_occurrence_id", occ.id);
    expect(none).toBe(0);
  });

  it("(k) INVALID_AMOUNT para NaN y negativos -- nunca queda un PAID con amount NaN", async () => {
    const { owner, org, service, resource } = await setupOrgWithService("p44-k", true);
    createdUserIds.push(owner.id);
    await createServicePlan(owner, { organizationId: org.id, serviceId: service.id, planKind: "DROP_IN", price: 800 });
    const rule = await createRule(owner, org, service, resource, 1, 5);
    const occ = await firstFutureOccurrence(owner, rule.id);
    const { customer, customerRow } = await enroll(owner, org, "p44-k-cust");
    createdUserIds.push(customer.id);

    for (const amount of ["NaN", -1]) {
      const { data, error } = await owner.client.rpc("book_slot_paying", {
        p_slot_occurrence_id: occ.id,
        p_customer_id: customerRow.id,
        p_amount: amount,
      });
      expect(error).toBeNull();
      expect(data.status).toBe("INVALID_AMOUNT");
    }
  });
});
