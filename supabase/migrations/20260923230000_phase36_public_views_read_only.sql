-- ============================================================
-- Fase 36 -- ADR-0037: las vistas públicas dejan de ser escribibles
-- ============================================================
-- Vulnerabilidad CRÍTICA preexistente en producción, encontrada por
-- `security-engineer` en el barrido que pidió ADR-0036 y reproducida
-- contra la base real con el actor `anon` **sin sesión**. No la introdujo
-- ninguna ADR de hoy: existe desde la Fase 4 (ADR-0008).
--
-- La causa, en dos mitades que por separado parecían inofensivas:
--
--   1. `organizations_public` / `services_public` se crearon SIN
--      `security_invoker` a propósito: una vista común corre con los
--      privilegios de su dueño, y eso es justo lo que el calendario
--      público necesita para leer `organizations`/`services` salteando la
--      RLS de miembro (ADR-0008). Pero ese bypass **no es sólo de
--      lectura**: alcanza los cuatro comandos. Las dos vistas son
--      "auto-updatable" para Postgres (un solo `FROM`, sin agregación, sin
--      `DISTINCT`), así que un `INSERT`/`UPDATE`/`DELETE` sobre la vista se
--      reescribe como el mismo comando sobre la tabla base -- con los
--      privilegios del dueño de la vista, sin evaluar la RLS de la tabla.
--
--   2. Los default privileges de Supabase para el esquema `public`
--      entregan **todos** los privilegios a `anon`/`authenticated` sobre
--      cada tabla y vista nueva. El `grant select` explícito de la Fase 4
--      era decorativo: `anon` ya tenía INSERT, UPDATE, DELETE y TRUNCATE
--      antes de que esa línea corriera. Verificado en
--      `information_schema.role_table_grants`, no deducido.
--
-- Lo que un visitante anónimo lograba con la anon key (pública por
-- diseño) y nada más:
--
--   * DELETE services_public?id=eq.<X>
--       -> cascade services -> bookings / payments
--       => borra Bookings CONFIRMED y pagos PAID. No los cancela: los
--          BORRA -- sin cancelled_at, sin MakeupCredit, sin audit_log.
--   * PATCH organizations_public?id=eq.<otro tenant>
--       => reescribe slug/name/timezone de una organización ajena.
--   * POST organizations_public
--       => crea una Organization salteando create_organization_with_owner(),
--          el gate de invitación (ADR-0017) y enforce_plan_limit(). La
--          ausencia deliberada de policy de INSERT en `organizations`
--          (Fase 1) no servía de nada: la vista no evalúa esa policy.
--   * PATCH (liberar un slug) + POST (reclamarlo)
--       => secuestro completo del slug de un negocio real: su URL pública
--          pasa a resolver a la organización falsa del atacante.
--
-- Decisión (ADR-0037, Aceptada, urgente): **se cierra la escritura y se
-- conserva la lectura intacta.**
--
-- `security_invoker = on` es el fix EQUIVOCADO y no se aplica: haría que
-- el SELECT evaluara RLS con los privilegios del llamador, y un visitante
-- anónimo no es miembro de ninguna organización -- el calendario público,
-- que es todo el punto de ADR-0008, devolvería cero filas para todo el
-- mundo. La lectura anónima de estas dos vistas es legítima e
-- intencional; lo que nunca debió existir es la escritura.

-- ============================================================
-- 1. Las dos vistas públicas: sólo lectura
-- ============================================================
-- TRUNCATE va en la lista aunque no se pueda truncar una vista: el bit de
-- privilegio existe igual y el objetivo es que
-- `has_table_privilege('anon', ..., 'TRUNCATE')` dé `false`, para que el
-- test genérico de la sección 3 no tenga excepciones que explicar.
--
-- REFERENCES y TRIGGER siguen concedidos (también vienen de los default
-- privileges). No son alcanzables por la Data API -- PostgREST no emite
-- DDL, y `anon` no tiene CREATE en `public` -- así que quedan fuera del
-- alcance de ADR-0037 y anotados para `security-engineer`, en vez de
-- ampliarlo por mi cuenta.

revoke insert, update, delete, truncate on public.organizations_public from anon, authenticated;
revoke insert, update, delete, truncate on public.services_public from anon, authenticated;

-- La lectura se reafirma explícitamente. Es redundante (nunca se revocó),
-- pero deja el contrato de estas dos vistas escrito en un solo lugar: se
-- leen sin sesión, no se escriben nunca.
grant select on public.organizations_public to anon, authenticated;
grant select on public.services_public to anon, authenticated;

comment on view public.organizations_public is
  'ADR-0008: vista pública del calendario, deliberadamente SIN security_invoker para saltear la RLS de miembro en LECTURA. ADR-0037: la escritura (insert/update/delete/truncate) está revocada para anon/authenticated -- el bypass del dueño de la vista alcanzaba los cuatro comandos y permitia a un anonimo reescribir el slug de otro tenant y crear organizaciones salteando create_organization_with_owner(). No poner security_invoker: rompe la lectura anonima.';

comment on view public.services_public is
  'ADR-0008: vista pública del calendario, deliberadamente SIN security_invoker para saltear la RLS de miembro en LECTURA. ADR-0037: la escritura está revocada para anon/authenticated -- un DELETE anonimo borraba en cascada Bookings CONFIRMED y pagos PAID. No poner security_invoker: rompe la lectura anonima.';

-- ============================================================
-- 2. Vistas nuevas: la regla, escrita donde se va a leer
-- ============================================================
-- Regla del repo (ADR-0037): toda vista de `public` se cierra con REVOKE
-- explícito de escritura para anon/authenticated **en la misma migración
-- que la crea**. El default de Postgres/Supabase es entregar los cuatro
-- comandos, y "hicimos grant select" no implica que el resto esté cerrado.
-- La sección 3 existe para que olvidarse no sea silencioso.

-- ============================================================
-- 3. El guardarraíl: auditoría de privilegios de escritura en vistas
-- ============================================================
-- Devuelve una fila por cada (vista de `public`, rol de request,
-- privilegio de escritura) que todavía esté concedido. **El resultado
-- correcto es el conjunto vacío.**
--
-- `has_table_privilege` -- y no `information_schema.role_table_grants` --
-- porque resuelve también lo indirecto: privilegios concedidos a PUBLIC y
-- los heredados por pertenencia a otro rol. Un grant a PUBLIC no aparece
-- como fila de `anon` en el catálogo, pero `anon` lo tiene igual.
--
-- EXECUTE sólo para `service_role`: es introspección de la superficie de
-- seguridad del esquema y no tiene por qué ser enumerable desde un
-- cliente público. `revoke ... from public` primero, porque toda función
-- nueva nace con EXECUTE para PUBLIC.

create or replace function public.audit_public_view_write_grants()
returns table (view_name text, role_name text, privilege text)
language sql
stable
set search_path = public, pg_catalog
as $$
  select v.viewname::text, r.role_name, p.privilege
  from pg_catalog.pg_views v
  cross join (values ('anon'), ('authenticated')) as r(role_name)
  cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) as p(privilege)
  where v.schemaname = 'public'
    and has_table_privilege(r.role_name, format('%I.%I', v.schemaname, v.viewname), p.privilege)
  order by 1, 2, 3;
$$;

revoke all on function public.audit_public_view_write_grants() from public;
revoke all on function public.audit_public_view_write_grants() from anon, authenticated;
grant execute on function public.audit_public_view_write_grants() to service_role;

comment on function public.audit_public_view_write_grants() is
  'ADR-0037: devuelve cada privilegio de escritura que anon/authenticated todavia tengan sobre una vista de `public`. El resultado correcto es vacio. Existe para que la proxima vista publica que alguien cree no repita la vulnerabilidad de la Fase 4: los default privileges de Supabase le van a dar los cuatro comandos y el test de integracion lo va a ver.';

-- ============================================================
-- 4. organization_members: el OWNER ya no puede borrarse a sí mismo
-- ============================================================
-- Segundo hallazgo del mismo barrido. `organization_members_write_owner`
-- era `for all`, así que un OWNER podía hacer
-- `DELETE /rest/v1/organization_members?id=eq.<su propia fila>` y saltear
-- entero el guard LAST_OWNER de revoke_member(): la organización quedaba
-- sin ningún OWNER activo y por lo tanto **inadministrable para siempre**
-- (agregar un OWNER es a su vez OWNER-only), salvo intervención de un
-- platform admin sobre la base.
--
-- Mismo fix que ADR-0036: `ALL` -> `INSERT` + `UPDATE`, misma expresión.
-- La policy original no tenía `with check`, así que Postgres usaba su
-- `using` también como check de INSERT -- de ahí que la policy de INSERT
-- lleve exactamente esa expresión y el reparto de permisos no cambie.
--
-- Dar de baja a alguien del equipo es revoke_member() (UPDATE
-- `is_active = false` + `cancelled_at`/`cancelled_by`/
-- `cancellation_reason`), que es `security definer` y por eso no depende
-- de estas policies. Ninguna pantalla del panel ofrece "eliminar
-- miembro": el botón es "revocar".

drop policy if exists organization_members_write_owner on public.organization_members;

create policy organization_members_insert_owner
  on public.organization_members for insert
  with check (public.is_organization_owner(organization_id));

create policy organization_members_update_owner
  on public.organization_members for update
  using (public.is_organization_owner(organization_id))
  with check (public.is_organization_owner(organization_id));

comment on policy organization_members_update_owner on public.organization_members is
  'ADR-0037: reemplaza a organization_members_write_owner (era FOR ALL, incluia DELETE). Sin policy de DELETE, un OWNER ya no puede borrar su propia fila por PostgREST y saltear el guard LAST_OWNER de revoke_member(), que es lo unico que impide dejar una organizacion sin ningun OWNER activo -- estado inadministrable para siempre, porque agregar un OWNER es OWNER-only. Dar de baja a alguien es revoke_member().';

-- ============================================================
-- 5. organization_roles (defensa en profundidad)
-- ============================================================
-- Riesgo bajo y protegido hoy por triggers, no por ausencia de policy:
-- `check_organization_role_not_in_use()` (Fase 32) rechaza borrar un rol que
-- alguien todavía tiene, y el constraint trigger del rol por defecto
-- rechaza quedarse sin ninguno. Cerrar el DELETE igual, por la misma razón
-- que ADR-0036: un trigger es una condición que hay que acertar, la
-- ausencia de policy es una puerta que no existe.
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
-- 6. service_plan_services (defensa en profundidad)
-- ============================================================
-- Mismo criterio. Hoy lo protege `check_service_plan_services_immutable()`
-- (Fase 22): quitar un servicio del alcance de un plan que ya tiene pagos
-- no VOID reescribiría retroactivamente qué compraron esos pagos. Pero el
-- trigger sólo cubre los planes con pagos; el resto del alcance era
-- borrable por cualquier OWNER por PostgREST, y el alcance de un plan no
-- se edita en ninguna pantalla -- se crea con create_service_plan(...
-- p_service_ids) y el plan se desactiva, no se rescopea (verificado en
-- `frontend/app/actions/service-plans.ts`).

drop policy if exists service_plan_services_write_owner on public.service_plan_services;

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
