-- ============================================================
-- Fase 36b -- ADR-0037 (continuación): organization_roles y
-- service_plan_services dejan de ser borrables por la Data API
-- ============================================================
-- Estas dos secciones nacieron dentro de
-- `20260923230000_phase36_public_views_read_only.sql` y se separaron acá
-- porque las dos dependen de objetos que crea la Fase 32
-- (`20260923230300_phase32_configurable_roles.sql`), que todavía no está
-- commiteada. Con todo junto, una base construida desde cero -- que es lo
-- único que hace CI -- moría en
-- `relation "public.organization_roles" does not exist`.
--
--   * `organization_roles`: tabla de la Fase 32. Sin ella, el
--     `drop policy` de abajo aborta la migración.
--   * `service_plan_services`: la tabla es de la Fase 22, pero la policy
--     que se reemplaza, `service_plan_services_write_owner`, la crea la
--     Fase 32. La Fase 22 la había llamado
--     `service_plan_services_write_staff` (con `is_organization_member`, no
--     `is_organization_owner`). Hacer este `drop policy if exists` antes de
--     la Fase 32 no falla: es peor -- no borra nada, deja viva la policy
--     `FOR ALL` con DELETE incluido, y los tests quedan en verde mirando
--     las dos policies nuevas mientras la puerta sigue abierta.
--
-- Por eso esta migración va DESPUÉS de la Fase 32 en el orden de
-- aplicación, y por eso se commitea junto con ella, nunca antes.
--
-- El criterio es el de ADR-0036 y ADR-0037: lo que hoy protege un trigger
-- se protege además con la ausencia de policy. Un trigger es una condición
-- que hay que acertar; la ausencia de policy es una puerta que no existe.

-- ============================================================
-- 1. organization_roles (defensa en profundidad)
-- ============================================================
-- Riesgo bajo y protegido hoy por triggers, no por ausencia de policy:
-- `check_organization_role_not_in_use()` (Fase 32) rechaza borrar un rol que
-- alguien todavía tiene, y el constraint trigger del rol por defecto
-- rechaza quedarse sin ninguno. Cerrar el DELETE igual.
--
-- El camino del producto nunca borró un rol: `deactivateOrganizationRole()`
-- llama a `update_organization_role(p_is_active => false)` (verificado en
-- `frontend/app/actions/roles.ts`, no asumido).

drop policy if exists organization_roles_write_owner on public.organization_roles;

create policy organization_roles_insert_owner
  on public.organization_roles for insert
  with check (public.is_organization_owner(organization_id));

create policy organization_roles_update_owner
  on public.organization_roles for update
  using (public.is_organization_owner(organization_id))
  with check (public.is_organization_owner(organization_id));

comment on policy organization_roles_update_owner on public.organization_roles is
  'ADR-0037: reemplaza a organization_roles_write_owner (era FOR ALL, incluia DELETE). Desactivar un rol es update_organization_role(p_is_active => false); borrarlo nunca fue un camino del producto.';

-- ============================================================
-- 2. service_plan_services (defensa en profundidad)
-- ============================================================
-- Mismo criterio. Hoy lo protege `check_service_plan_services_immutable()`
-- (Fase 22): quitar un servicio del alcance de un plan que ya tiene pagos
-- no VOID reescribiría retroactivamente qué compraron esos pagos. Pero el
-- trigger sólo cubre los planes con pagos; el resto del alcance era
-- borrable por cualquier OWNER por PostgREST, y el alcance de un plan no
-- se edita en ninguna pantalla -- se crea con create_service_plan(...
-- p_service_ids) y el plan se desactiva, no se rescopea (verificado en
-- `frontend/app/actions/service-plans.ts`).
--
-- El `drop policy if exists` cubre además el nombre viejo de la Fase 22,
-- `service_plan_services_write_staff`, para que esta migración deje el
-- estado final correcto sin importar por qué camino llegó la base.

drop policy if exists service_plan_services_write_owner on public.service_plan_services;
drop policy if exists service_plan_services_write_staff on public.service_plan_services;

create policy service_plan_services_insert_owner
  on public.service_plan_services for insert
  with check (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_owner(sp.organization_id)
  ));

create policy service_plan_services_update_owner
  on public.service_plan_services for update
  using (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_owner(sp.organization_id)
  ))
  with check (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_owner(sp.organization_id)
  ));

comment on policy service_plan_services_update_owner on public.service_plan_services is
  'ADR-0037: reemplaza a service_plan_services_write_owner (era FOR ALL, incluia DELETE). El alcance de un plan se fija al crearlo (create_service_plan(p_service_ids)) y el plan se desactiva en vez de rescopearse; check_service_plan_services_immutable() solo cubria los planes con pagos no VOID.';
