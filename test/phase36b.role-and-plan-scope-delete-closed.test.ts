// Integration tests for Fase 36b -- ADR-0037 (continuación):
// `organization_roles` y `service_plan_services` dejan de ser borrables por
// la Data API.
//
// Estos casos vivían en `phase36.public-views-read-only.test.ts`. Se
// separaron acá junto con su migración
// (`20260923240000_phase36b_role_and_plan_scope_delete_closed.sql`) porque
// los dos dependen de la Fase 32:
//
//   * `organization_roles` es una tabla de la Fase 32.
//   * `organization_members.role_id` es una columna de la Fase 32.
//   * la policy que reemplaza la migración, `service_plan_services_write_owner`,
//     la crea la Fase 32 (la Fase 22 la había llamado
//     `service_plan_services_write_staff`).
//
// Mientras la Fase 32 no esté commiteada, este archivo tampoco se commitea:
// CI construye la base desde cero con lo que hay en git, y estos tests
// fallarían por dependencia faltante, no por el comportamiento que miden.
//
// Forma de los asserts: acá el mecanismo es RLS, no privilegios de tabla.
// Un DELETE sin policy no da error -- devuelve 0 filas. Por eso cada caso
// afirma además, con service role, que la fila sobrevivió: afirmar sólo
// "no borró nada visible" daría un falso verde.
//
// Requiere una instancia local de Supabase corriendo.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createServicePlan,
  createSignedInUser,
  type SignedInUser,
} from "./helpers";

const createdUserIds: string[] = [];

async function newUser(prefix: string): Promise<SignedInUser> {
  const user = await createSignedInUser(prefix);
  createdUserIds.push(user.id);
  return user;
}

async function rowExists(table: string, filter: Record<string, string>) {
  let query = admin.from(table).select("*", { count: "exact", head: true });
  for (const [column, value] of Object.entries(filter)) {
    query = query.eq(column, value);
  }
  const { count, error } = await query;
  expect(error).toBeNull();
  return (count ?? 0) > 0;
}

describe("Fase 36b -- ADR-0037: organization_roles y service_plan_services sin DELETE", () => {
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceId: string;
  let secondServiceId: string;
  let scopePlanId: string;
  let defaultRoleId: string;

  beforeAll(async () => {
    owner = await newUser("p36b-owner");
    org = await createOrganization(owner, "p36b-org");

    const { data: services, error: servicesError } = await owner.client
      .from("services")
      .insert([
        { organization_id: org.id, name: "Pilates", created_by: owner.id },
        { organization_id: org.id, name: "Funcional", created_by: owner.id },
        { organization_id: org.id, name: "Spinning", created_by: owner.id },
      ])
      .select("id");
    expect(servicesError).toBeNull();
    const ids = (services as { id: string }[]).map((s) => s.id);
    serviceId = ids[0]!;
    secondServiceId = ids[1]!;

    const { data: role, error: roleError } = await admin
      .from("organization_roles")
      .select("id")
      .eq("organization_id", org.id)
      .eq("is_default", true)
      .single();
    expect(roleError).toBeNull();
    defaultRoleId = role!.id as string;

    // Un plan SIN pagos: check_service_plan_services_immutable() (Fase 22)
    // bloquea tocar el alcance de un plan que ya tiene pagos no VOID, y el
    // punto de este test es medir la policy, no ese trigger.
    scopePlanId = await createServicePlan(owner, {
      organizationId: org.id,
      serviceId: ids[2]!,
      name: "Plan sin pagos",
    });
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  // ================================================================
  // 1. organization_roles (defensa en profundidad)
  // ================================================================

  it("un OWNER no puede borrar un organization_role, pero sí crearlo, leerlo y actualizarlo", async () => {
    const { data: created, error: createError } = await owner.client
      .from("organization_roles")
      .insert({
        organization_id: org.id,
        name: `Recepción ${Math.random().toString(36).slice(2, 8)}`,
        can_view_payments: true,
        can_manage_payments: false,
        can_manage_bookings: true,
        can_manage_customers: false,
        can_manage_attendance: true,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(createError).toBeNull();
    const roleId = created!.id as string;

    const { data: read, error: readError } = await owner.client
      .from("organization_roles")
      .select("id")
      .eq("id", roleId);
    expect(readError).toBeNull();
    expect(read).toHaveLength(1);

    const { data: updated, error: updateError } = await owner.client
      .from("organization_roles")
      .update({ can_manage_bookings: false })
      .eq("id", roleId)
      .select();
    expect(updateError).toBeNull();
    expect(updated).toHaveLength(1);

    const { data: deleted, error: deleteError } = await owner.client
      .from("organization_roles")
      .delete()
      .eq("id", roleId)
      .select();
    expect(deleteError).toBeNull();
    expect(deleted ?? []).toHaveLength(0);
    expect(await rowExists("organization_roles", { id: roleId })).toBe(true);
  });

  // ================================================================
  // 2. organization_members.role_id: el UPDATE del OWNER sigue vivo
  // ================================================================
  // Esta mitad es la que no cabía en el test de la Fase 36: la policy
  // organization_members_update_owner es de la Fase 36, pero `role_id` es
  // una columna de la Fase 32, así que sólo se puede afirmar acá.

  it("el OWNER sigue pudiendo asignar un role_id a un miembro del equipo", async () => {
    const staffUser = await newUser("p36b-staff");

    const { data: inserted, error: insertError } = await owner.client
      .from("organization_members")
      .insert({ organization_id: org.id, profile_id: staffUser.id, role: "STAFF" })
      .select()
      .single();
    expect(insertError).toBeNull();
    const staffMemberId = inserted!.id as string;

    const { data: updated, error: updateError } = await owner.client
      .from("organization_members")
      .update({ role_id: defaultRoleId })
      .eq("id", staffMemberId)
      .select();
    expect(updateError).toBeNull();
    expect(updated).toHaveLength(1);

    const { data: member } = await admin
      .from("organization_members")
      .select("role_id")
      .eq("id", staffMemberId)
      .single();
    expect(member!.role_id).toBe(defaultRoleId);
  });

  // ================================================================
  // 3. service_plan_services (defensa en profundidad)
  // ================================================================

  it("un OWNER no puede borrar un service_plan_services, pero sí crearlo, leerlo y actualizarlo", async () => {
    const { error: insertError } = await owner.client
      .from("service_plan_services")
      .insert({ service_plan_id: scopePlanId, service_id: secondServiceId });
    expect(insertError).toBeNull();

    const { data: read, error: readError } = await owner.client
      .from("service_plan_services")
      .select("service_id")
      .eq("service_plan_id", scopePlanId);
    expect(readError).toBeNull();
    expect((read ?? []).map((r) => r.service_id)).toContain(secondServiceId);

    const { data: updated, error: updateError } = await owner.client
      .from("service_plan_services")
      .update({ service_id: serviceId })
      .eq("service_plan_id", scopePlanId)
      .eq("service_id", secondServiceId)
      .select();
    expect(updateError).toBeNull();
    expect(updated).toHaveLength(1);

    const { data: deleted, error: deleteError } = await owner.client
      .from("service_plan_services")
      .delete()
      .eq("service_plan_id", scopePlanId)
      .eq("service_id", serviceId)
      .select();
    expect(deleteError).toBeNull();
    expect(deleted ?? []).toHaveLength(0);
    expect(
      await rowExists("service_plan_services", {
        service_plan_id: scopePlanId,
        service_id: serviceId,
      }),
    ).toBe(true);
  });
});
