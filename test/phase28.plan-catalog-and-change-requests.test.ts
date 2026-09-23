// Integration tests for Phase 28: el catálogo de planes visible al cliente
// (public_service_plans) y la solicitud de cambio de plan
// (request_plan_change y su ciclo de vida). Requiere un Supabase local
// corriendo (`npx supabase start`).
//
// Lo que estas pruebas cuidan, en orden de importancia:
// 1. El catálogo es público pero no filtra nada privado ni cruza tenants.
// 2. La solicitud nunca habilita ni cubre nada -- es un hecho para el
//    mostrador. El cambio real sigue siendo el pago (ADR-0024 res. 1).
// 3. El Customer se resuelve desde auth.uid(), nunca de un parámetro
//    (ADR-0005).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createClient } from "@supabase/supabase-js";
import {
  ANON_KEY,
  SUPABASE_URL,
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  isoDate,
  payFor,
  type SignedInUser,
} from "./helpers";

const anon = createClient(SUPABASE_URL, ANON_KEY);

describe("Phase 28: catálogo de planes y solicitud de cambio", () => {
  const createdUserIds: string[] = [];

  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceId: string;
  let otherServiceId: string;
  let planOneId: string; // WEEKLY_QUOTA 1x -- el que "no alcanza"
  let planTwoId: string; // WEEKLY_QUOTA 2x -- el upgrade
  let dropInId: string;
  let inactivePlanId: string;

  let customer: SignedInUser;
  let customerRowId: string;

  beforeAll(async () => {
    owner = await createSignedInUser("p28-owner");
    createdUserIds.push(owner.id);
    org = await createOrganization(owner, "p28-org");

    const { data: service } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Pilates", payment_required: true, created_by: owner.id })
      .select()
      .single();
    serviceId = service!.id as string;

    const { data: other } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Funcional", payment_required: true, created_by: owner.id })
      .select()
      .single();
    otherServiceId = other!.id as string;

    planOneId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Pilates 1x semana",
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 1,
      price: 1800,
    });
    planTwoId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Pilates 2x semana",
      planKind: "WEEKLY_QUOTA",
      weeklyQuota: 2,
      price: 2500,
    });
    dropInId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Clase suelta",
      planKind: "DROP_IN",
      price: 800,
    });
    inactivePlanId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId,
      name: "Plan viejo",
      planKind: "UNLIMITED",
      price: 9999,
    });
    await owner.client.from("service_plans").update({ is_active: false }).eq("id", inactivePlanId);

    customer = await createSignedInUser("p28-customer");
    createdUserIds.push(customer.id);
    const { data: customerRow } = await owner.client
      .from("customers")
      .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
      .select()
      .single();
    customerRowId = customerRow!.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ============================================================
  // public_service_plans()
  // ============================================================

  it("lista los planes activos de la organización sin login", async () => {
    const { data, error } = await anon.rpc("public_service_plans", {
      p_organization_slug: org.slug,
    });

    expect(error).toBeNull();
    const ids = data.map((row: { plan_id: string }) => row.plan_id);
    expect(ids).toContain(planOneId);
    expect(ids).toContain(planTwoId);
    expect(ids).toContain(dropInId);
    // is_active es el interruptor de "está a la venta": un plan
    // desactivado no se ofrece, aunque siga cubriendo a quien ya pagó.
    expect(ids).not.toContain(inactivePlanId);
  });

  it("devuelve precio, frecuencia y los servicios que cubre cada plan", async () => {
    const { data } = await anon.rpc("public_service_plans", { p_organization_slug: org.slug });
    const two = data.find((row: { plan_id: string }) => row.plan_id === planTwoId);

    expect(two.name).toBe("Pilates 2x semana");
    expect(Number(two.price)).toBe(2500);
    expect(two.plan_kind).toBe("WEEKLY_QUOTA");
    expect(two.weekly_quota).toBe(2);
    expect(two.currency).toBe("UYU");
    expect(two.service_ids).toEqual([serviceId]);
    expect(two.service_names).toEqual(["Pilates"]);
  });

  it("filtra por servicio, incluidos los planes que cubren todos (ADR-0029)", async () => {
    const { data: allServicesPlan } = await owner.client.rpc("create_service_plan", {
      p_organization_id: org.id,
      p_name: "Pase libre",
      p_description: null,
      p_price: 4000,
      p_plan_kind: "UNLIMITED",
      p_weekly_quota: null,
      p_billing_type: "MONTHLY",
      p_billing_cycle: "CALENDAR_MONTH",
      p_sort_order: 9,
      p_applies_to_all_services: true,
      p_service_ids: null,
      p_quota_scope: null,
    });
    const allServicesPlanId = (allServicesPlan as { id: string }).id;

    const { data } = await anon.rpc("public_service_plans", {
      p_organization_slug: org.slug,
      p_service_id: otherServiceId,
    });
    const ids = data.map((row: { plan_id: string }) => row.plan_id);

    // "Funcional" sólo lo cubre el pase libre; los planes de Pilates no.
    expect(ids).toContain(allServicesPlanId);
    expect(ids).not.toContain(planOneId);

    const pass = data.find((row: { plan_id: string }) => row.plan_id === allServicesPlanId);
    expect(pass.service_ids.sort()).toEqual([serviceId, otherServiceId].sort());

    await owner.client.from("service_plans").update({ is_active: false }).eq("id", allServicesPlanId);
  });

  it("no deja ver los planes de otra organización por el mismo slug", async () => {
    const otherOwner = await createSignedInUser("p28-other-owner");
    createdUserIds.push(otherOwner.id);
    const otherOrg = await createOrganization(otherOwner, "p28-other-org");
    const { data: svc } = await otherOwner.client
      .from("services")
      .insert({ organization_id: otherOrg.id, name: "Yoga", payment_required: true, created_by: otherOwner.id })
      .select()
      .single();
    const foreignPlan = await createServicePlan(otherOwner, {
      organizationId: otherOrg.id,
      serviceId: svc!.id as string,
      name: "Yoga mensual",
      planKind: "UNLIMITED",
      price: 1200,
    });

    const { data } = await anon.rpc("public_service_plans", { p_organization_slug: org.slug });
    const ids = data.map((row: { plan_id: string }) => row.plan_id);
    expect(ids).not.toContain(foreignPlan);
  });

  it("una organización inexistente o inactiva devuelve lista vacía, no un error", async () => {
    const { data, error } = await anon.rpc("public_service_plans", {
      p_organization_slug: "no-existe-este-slug",
    });
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  // ============================================================
  // request_plan_change()
  // ============================================================

  it("no se puede pedir un cambio de plan sin login", async () => {
    const { error } = await anon.rpc("request_plan_change", { p_service_plan_id: planTwoId });
    expect(error).not.toBeNull();
  });

  it("alguien que no es cliente de esa organización no puede pedir el cambio", async () => {
    const stranger = await createSignedInUser("p28-stranger");
    createdUserIds.push(stranger.id);

    const { error } = await stranger.client.rpc("request_plan_change", { p_service_plan_id: planTwoId });
    expect(error?.message).toContain("NOT_A_CUSTOMER");
  });

  it("registra el pedido con el plan vigente resuelto en la base", async () => {
    // El cliente está en el plan de 1x semana: es el caso del feedback
    // (OVER_PLAN_QUOTA) que motivó esta fase.
    const { error: payError } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRowId,
      serviceId,
      from: isoDate(-5),
      to: isoDate(25),
      servicePlanId: planOneId,
      amount: 1800,
    });
    expect(payError).toBeNull();

    const { data, error } = await customer.client.rpc("request_plan_change", {
      p_service_plan_id: planTwoId,
      p_note: "Quiero ir dos veces por semana",
    });

    expect(error).toBeNull();
    expect(data.service_plan_id).toBe(planTwoId);
    // Nunca vino del caller: lo resolvió resolve_covering_service_plan().
    expect(data.current_service_plan_id).toBe(planOneId);
    expect(data.customer_id).toBe(customerRowId);
    expect(data.resolved_at).toBeNull();
    expect(data.note).toBe("Quiero ir dos veces por semana");
  });

  it("pedir dos veces el mismo plan devuelve el pedido pendiente, no un duplicado", async () => {
    const { data, error } = await customer.client.rpc("request_plan_change", {
      p_service_plan_id: planTwoId,
    });
    expect(error).toBeNull();

    const { count } = await admin
      .from("plan_change_requests")
      .select("id", { count: "exact", head: true })
      .eq("customer_id", customerRowId)
      .eq("service_plan_id", planTwoId)
      .is("resolved_at", null);
    expect(count).toBe(1);
    expect(data.note).toBe("Quiero ir dos veces por semana");
  });

  it("no deja pedir el plan que ya lo cubre", async () => {
    const { error } = await customer.client.rpc("request_plan_change", { p_service_plan_id: planOneId });
    expect(error?.message).toContain("ALREADY_ON_PLAN");
  });

  it("no deja pedir un plan desactivado", async () => {
    const { error } = await customer.client.rpc("request_plan_change", { p_service_plan_id: inactivePlanId });
    expect(error?.message).toContain("SERVICE_PLAN_NOT_AVAILABLE");
  });

  it("no deja pedir un plan de otra organización", async () => {
    const otherOwner = await createSignedInUser("p28-foreign-owner");
    createdUserIds.push(otherOwner.id);
    const otherOrg = await createOrganization(otherOwner, "p28-foreign-org");
    const { data: svc } = await otherOwner.client
      .from("services")
      .insert({ organization_id: otherOrg.id, name: "Spinning", payment_required: true, created_by: otherOwner.id })
      .select()
      .single();
    const foreignPlan = await createServicePlan(otherOwner, {
      organizationId: otherOrg.id,
      serviceId: svc!.id as string,
      name: "Spinning mensual",
      planKind: "UNLIMITED",
      price: 1500,
    });

    const { error } = await customer.client.rpc("request_plan_change", { p_service_plan_id: foreignPlan });
    expect(error?.message).toContain("NOT_A_CUSTOMER");
  });

  // ============================================================
  // Lecturas y cierre
  // ============================================================

  it("el cliente ve su propio pedido y nadie más lo ve", async () => {
    const { data, error } = await customer.client.rpc("my_plan_change_requests");
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data[0].plan_name).toBe("Pilates 2x semana");
    expect(data[0].current_plan_name).toBe("Pilates 1x semana");
    expect(data[0].resolution).toBeNull();

    const stranger = await createSignedInUser("p28-nosy");
    createdUserIds.push(stranger.id);
    const { data: nothing } = await stranger.client.rpc("my_plan_change_requests");
    expect(nothing).toEqual([]);

    // Y tampoco por PostgREST directo: la policy de SELECT es self-or-staff.
    const { data: rows } = await stranger.client.from("plan_change_requests").select("*");
    expect(rows).toEqual([]);
  });

  it("el mostrador ve el pedido con el plan actual al lado; un ajeno no ve nada", async () => {
    const { data, error } = await owner.client.rpc("organization_plan_change_requests", {
      p_organization_id: org.id,
    });
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data[0].requested_plan_name).toBe("Pilates 2x semana");
    expect(Number(data[0].requested_plan_price)).toBe(2500);
    expect(data[0].current_plan_name).toBe("Pilates 1x semana");
    expect(data[0].customer_id).toBe(customerRowId);

    const outsider = await createSignedInUser("p28-outsider");
    createdUserIds.push(outsider.id);
    const { data: empty } = await outsider.client.rpc("organization_plan_change_requests", {
      p_organization_id: org.id,
    });
    expect(empty).toEqual([]);
  });

  it("un no-miembro no puede cerrar el pedido", async () => {
    const { data: pending } = await admin
      .from("plan_change_requests")
      .select("id")
      .eq("customer_id", customerRowId)
      .is("resolved_at", null)
      .single();

    const { error } = await customer.client.rpc("resolve_plan_change_request", {
      p_request_id: pending!.id,
      p_resolution: "DISMISSED",
    });
    expect(error?.message).toContain("NOT_AUTHORIZED");
  });

  it("cobrar el plan pedido cierra el pedido como APPLIED", async () => {
    // ADR-0024 resolución 1: cambiar de plan es VOID del pago viejo +
    // recargar el nuevo. Esa es la operación que cierra el pedido.
    await owner.client
      .from("payments")
      .update({ status: "VOID" })
      .eq("customer_id", customerRowId)
      .eq("service_plan_id", planOneId);

    const { error: payError } = await payFor(owner, {
      organizationId: org.id,
      customerId: customerRowId,
      serviceId,
      from: isoDate(-5),
      to: isoDate(25),
      servicePlanId: planTwoId,
      amount: 2500,
    });
    expect(payError).toBeNull();

    const { data } = await customer.client.rpc("my_plan_change_requests");
    expect(data[0].resolution).toBe("APPLIED");
    expect(data[0].resolved_at).not.toBeNull();

    // Y desaparece de la lista de pendientes del mostrador.
    const { data: pendientes } = await owner.client.rpc("organization_plan_change_requests", {
      p_organization_id: org.id,
    });
    expect(pendientes).toEqual([]);

    const { data: todos } = await owner.client.rpc("organization_plan_change_requests", {
      p_organization_id: org.id,
      p_include_resolved: true,
    });
    expect(todos).toHaveLength(1);
  });

  it("cerrar a mano es idempotente y no pisa quién lo cerró", async () => {
    // Un pedido nuevo: el cliente ahora está en 2x y quiere la clase suelta.
    const { data: request } = await customer.client.rpc("request_plan_change", {
      p_service_plan_id: dropInId,
    });

    const { data: first } = await owner.client.rpc("resolve_plan_change_request", {
      p_request_id: request.id,
      p_resolution: "DISMISSED",
    });
    expect(first.resolution).toBe("DISMISSED");
    expect(first.resolved_by).toBe(owner.id);

    const { data: second } = await owner.client.rpc("resolve_plan_change_request", {
      p_request_id: request.id,
      p_resolution: "APPLIED",
    });
    expect(second.resolution).toBe("DISMISSED");
    expect(second.resolved_at).toBe(first.resolved_at);
  });

  it("nadie puede escribir la tabla directamente", async () => {
    const { error } = await customer.client.from("plan_change_requests").insert({
      organization_id: org.id,
      customer_id: customerRowId,
      service_plan_id: planOneId,
    });
    expect(error).not.toBeNull();
  });

  it("la solicitud no cambia en nada lo que el cliente puede reservar", async () => {
    // El invariante central de esta fase: plan_change_requests no
    // participa de ninguna decisión. Se comprueba contra la única puerta
    // (ADR-0005) -- misma respuesta antes y después de pedir un cambio.
    const { data: before } = await customer.client.rpc("my_services");
    const beforeCovered = before.map((r: { is_covered_today: boolean }) => r.is_covered_today);

    // Ahora está cubierto por el plan de 2x: pedir el de 1x es un
    // downgrade legítimo, no ALREADY_ON_PLAN.
    const { error } = await customer.client.rpc("request_plan_change", { p_service_plan_id: planOneId });
    expect(error).toBeNull();

    const { data: after } = await customer.client.rpc("my_services");
    expect(after.map((r: { is_covered_today: boolean }) => r.is_covered_today)).toEqual(beforeCovered);
  });
});
