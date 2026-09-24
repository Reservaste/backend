-- ============================================================
-- Fase 35 -- ADR-0036: se cierra el DELETE de la Data API
-- ============================================================
-- Hallazgo de `security-engineer`, reproducido contra la base real:
--
--   DELETE /rest/v1/schedule_rules?id=eq.<X>
--     -> cascade schedule_rules -> slot_occurrences -> bookings
--     => borra Bookings CONFIRMED. No las cancela: las BORRA.
--        Sin cancelled_at/cancelled_by, sin MakeupCredit, sin fila en
--        audit_log. Rompe el invariante de CLAUDE.md
--        ("las reservas canceladas nunca se borran").
--
--   DELETE /rest/v1/services?id=eq.<X>
--     -> cascade services -> payments (payments.service_id, Fase 14)
--     => borra pagos PAID. Historial financiero destruido.
--
-- Por qué ningún gate de ADR-0033 lo cubría: **la cascada de FK no
-- evalúa RLS**. Postgres aplica las policies a la fila que el comando
-- nombra, no a las filas que la integridad referencial arrastra detrás.
-- Un STAFF con los cinco permisos de ADR-0033 en `false` lograba con un
-- DELETE el efecto que MANAGE_BOOKINGS y MANAGE_PAYMENTS existen para
-- negarle. No es un bug de ADR-0033 -- es preexistente desde que estas
-- tablas tienen policy `ALL` -- pero ADR-0033 lo vuelve urgente: un rol
-- restringido no vale nada si hay una puerta lateral que lo ignora.
--
-- Decisión (ADR-0036, Aceptada): **ninguna de estas siete tablas tiene
-- un caso de uso legítimo de DELETE por la Data API.** Todo lo que el
-- producto "borra" ya tiene su camino correcto y ninguno usa DELETE:
--
--   * horarios   -> discontinue_schedule_rule()  (UPDATE: corta la regla
--                   y cancela las ocurrencias futuras liberando cupo)
--   * servicios  -> is_active = false            (UPDATE)
--   * recursos   -> is_active = false            (UPDATE)
--   * equipo     -> revoke_member()              (UPDATE is_active)
--
-- Verificado antes de escribir esta migración, no asumido: en todo
-- `backend/supabase/migrations/` el único `delete from` es el de
-- `slot_occurrences` dentro de regenerate_occurrences_for_rule()
-- (Fase 3, ocurrencias futuras sin Booking -- tabla que NO está en esta
-- lista y cuyo borrado es el mecanismo de ADR-0003), y en
-- `frontend/app/actions/` no hay un solo `.delete()` contra PostgREST.
--
-- El fix es quitar el comando de la policy, no agregar un trigger: bajo
-- RLS la **ausencia** de policy de DELETE deniega por default. Es lo más
-- simple y lo que menos superficie nueva crea. Si algún día hace falta
-- borrar de verdad (no cancelar ni desactivar), es una RPC nueva con su
-- propia decisión explícita, nunca un DELETE genérico.
--
-- Qué NO se toca:
--   * Ninguna FK `on delete cascade`: siguen siendo correctas para
--     cuando la fila padre sí se borre por una vía legítima futura.
--   * Ninguna RPC: ninguna función de este esquema hace `delete from`
--     sobre estas siete tablas (ver arriba), así que no hay camino
--     interno que esta migración rompa. Las funciones `security
--     definer`, además, no evalúan RLS.
--   * Ninguna policy de SELECT. Las siete tablas ya tienen su policy de
--     lectura dedicada (`*_select_*`, Fases 1/2/3), con una expresión
--     idéntica o más amplia que la de la policy `ALL` que acá se
--     reemplaza -- incluido `customers`, donde
--     has_org_permission(..., 'MANAGE_CUSTOMERS') exige membresía activa
--     y por lo tanto es un subconjunto estricto de
--     is_organization_member(). Por eso la sustitución es
--     `ALL -> INSERT + UPDATE`: agregar una policy de SELECT duplicada
--     no cambiaría ni una fila visible, sólo sumaría una expresión más
--     a evaluar por fila leída.
--
-- Nota de comportamiento para quien lea los tests: un DELETE sin policy
-- no devuelve error. Postgres simplemente no encuentra filas que el
-- actor pueda borrar, así que PostgREST responde 204 / `[]` y la fila
-- sigue en su lugar. Lo que hay que afirmar en un test es que la fila
-- sobrevive, no que llegó un código de error.

-- ============================================================
-- 1. schedule_rules -- el caso que destruía Bookings CONFIRMED
-- ============================================================

drop policy if exists schedule_rules_write_staff on public.schedule_rules;

create policy schedule_rules_insert_staff
  on public.schedule_rules for insert
  with check (public.is_organization_member(organization_id));

create policy schedule_rules_update_staff
  on public.schedule_rules for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- ============================================================
-- 2. services -- el caso que destruía pagos PAID
-- ============================================================

drop policy if exists services_write_staff on public.services;

create policy services_insert_staff
  on public.services for insert
  with check (public.is_organization_member(organization_id));

-- El trigger de columnas de OWNER (check_service_owner_columns, Fases
-- 25/34) sigue colgado del UPDATE y sigue siendo el que decide qué
-- columnas puede tocar un STAFF. Esta policy no cambia ese reparto.
create policy services_update_staff
  on public.services for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- ============================================================
-- 3. resources
-- ============================================================

drop policy if exists resources_write_staff on public.resources;

create policy resources_insert_staff
  on public.resources for insert
  with check (public.is_organization_member(organization_id));

create policy resources_update_staff
  on public.resources for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- ============================================================
-- 4. customers
-- ============================================================
-- La expresión es la de la Fase 32 (ADR-0033 §4.3: escribir el padrón
-- pide MANAGE_CUSTOMERS), no la original de la Fase 1.

drop policy if exists customers_write_staff on public.customers;

create policy customers_insert_staff
  on public.customers for insert
  with check (public.has_org_permission(organization_id, 'MANAGE_CUSTOMERS'));

create policy customers_update_staff
  on public.customers for update
  using (public.has_org_permission(organization_id, 'MANAGE_CUSTOMERS'))
  with check (public.has_org_permission(organization_id, 'MANAGE_CUSTOMERS'));

-- ============================================================
-- 5. schedule_exceptions
-- ============================================================

drop policy if exists schedule_exceptions_write_staff on public.schedule_exceptions;

create policy schedule_exceptions_insert_staff
  on public.schedule_exceptions for insert
  with check (public.is_organization_member(organization_id));

create policy schedule_exceptions_update_staff
  on public.schedule_exceptions for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- ============================================================
-- 6. service_entitlements
-- ============================================================

drop policy if exists service_entitlements_write_staff on public.service_entitlements;

create policy service_entitlements_insert_staff
  on public.service_entitlements for insert
  with check (public.is_organization_member(organization_id));

create policy service_entitlements_update_staff
  on public.service_entitlements for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

-- ============================================================
-- 7. service_resources
-- ============================================================
-- Tabla de unión sin organization_id propio: el tenant se resuelve
-- subiendo al Service, igual que en la Fase 2.

drop policy if exists service_resources_write_staff on public.service_resources;

create policy service_resources_insert_staff
  on public.service_resources for insert
  with check (
    exists (
      select 1 from public.services s
      where s.id = service_resources.service_id
        and public.is_organization_member(s.organization_id)
    )
  );

create policy service_resources_update_staff
  on public.service_resources for update
  using (
    exists (
      select 1 from public.services s
      where s.id = service_resources.service_id
        and public.is_organization_member(s.organization_id)
    )
  )
  with check (
    exists (
      select 1 from public.services s
      where s.id = service_resources.service_id
        and public.is_organization_member(s.organization_id)
    )
  );

-- ============================================================
-- Documentación en la base
-- ============================================================

comment on policy schedule_rules_update_staff on public.schedule_rules is
  'ADR-0036: reemplaza a schedule_rules_write_staff (era FOR ALL, incluia DELETE). Sin policy de DELETE, un DELETE por la Data API no encuentra filas y la cascada schedule_rules -> slot_occurrences -> bookings deja de poder borrar Bookings CONFIRMED. Dar de baja un horario es discontinue_schedule_rule(), que hace UPDATE y cancela liberando cupo.';

comment on policy services_update_staff on public.services is
  'ADR-0036: reemplaza a services_write_staff (era FOR ALL, incluia DELETE). Sin policy de DELETE, la cascada services -> payments deja de poder borrar pagos PAID. Dar de baja un servicio es is_active = false.';

comment on policy resources_update_staff on public.resources is
  'ADR-0036: reemplaza a resources_write_staff (era FOR ALL, incluia DELETE). Dar de baja un recurso es is_active = false.';

comment on policy customers_update_staff on public.customers is
  'ADR-0036: reemplaza a customers_write_staff (era FOR ALL, incluia DELETE; expresion MANAGE_CUSTOMERS de la Fase 32 sin cambios). Sin policy de DELETE, la cascada customers -> bookings/payments/service_entitlements deja de poder borrar historial.';

comment on policy schedule_exceptions_update_staff on public.schedule_exceptions is
  'ADR-0036: reemplaza a schedule_exceptions_write_staff (era FOR ALL, incluia DELETE).';

comment on policy service_entitlements_update_staff on public.service_entitlements is
  'ADR-0036: reemplaza a service_entitlements_write_staff (era FOR ALL, incluia DELETE). Sin policy de DELETE, la cascada service_entitlements -> payments deja de poder borrar pagos.';

comment on policy service_resources_update_staff on public.service_resources is
  'ADR-0036: reemplaza a service_resources_write_staff (era FOR ALL, incluia DELETE). Desasociar un recurso de un servicio es el unico caso de esta lista que se parecia a un borrado legitimo: hoy se resuelve reescribiendo la fila, y si hiciera falta borrarla va por RPC propia con su gate.';
