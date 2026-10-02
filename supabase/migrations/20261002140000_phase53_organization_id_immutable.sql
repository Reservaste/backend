-- Phase 53: organization_id inmutable en resources/services (ADR-0052)
--
-- Problema (senalado de forma independiente por security-engineer en los
-- gates de Fase 48, 49 y 50): resources.organization_id y
-- services.organization_id se podian cambiar via UPDATE directo.
-- resources_update_staff/services_update_staff (Fase 35) validan
-- is_organization_member(organization_id) tanto en USING como en WITH
-- CHECK, pero eso solo exige ser miembro de la organizacion ORIGEN y de
-- la organizacion DESTINO por separado -- no impide el cambio en si.
-- Alguien con membresia en las Organizaciones A y B podia mover un
-- Resource/Service de A a B (nunca explotable por anon ni por un
-- tercero sin esa doble membresia). Ningun trigger cerraba la columna.
--
-- Decision: un trigger BEFORE UPDATE por tabla que rechaza
-- (ORGANIZATION_ID_IS_IMMUTABLE) cualquier UPDATE donde
-- new.organization_id is distinct from old.organization_id -- sin
-- excepcion, ni siquiera para OWNER/platform_admin. Mover un Resource o
-- Service de una Organization a otra nunca es una operacion legitima del
-- producto (multi-tenant por diseno, ADR-0001); si alguna vez hiciera
-- falta en la practica (migrar datos entre tenants), es una operacion de
-- soporte manual via service_role, nunca algo que ningun rol de la
-- aplicacion deberia poder hacer por accidente o abuso.
--
-- Confirmado (backend-engineer, antes de escribir el trigger): ningun
-- RPC ni server action existente hace UPDATE ... SET organization_id
-- sobre una fila ya creada de resources ni services. El unico lugar
-- donde organization_id se fija es el INSERT inicial (siempre con el
-- valor ya resuelto desde la sesion/membership, nunca de un parametro
-- libre del caller) -- un trigger BEFORE UPDATE no dispara sobre ese
-- INSERT, asi que no bloquea ningun camino legitimo existente.
--
-- Por que trigger y no solo policy: una policy de RLS no puede comparar
-- OLD contra NEW de forma nativa en WITH CHECK sin duplicar el valor
-- viejo en la condicion (fragil) -- un trigger BEFORE UPDATE con WHEN es
-- el mecanismo ya usado en este schema para este tipo de invariante
-- (mismo patron que resources_guard_dynamic_toggle, Fase 50a/ADR-0051).
--
-- Funcion generica (una sola, reusada por las dos tablas) en vez de dos
-- copias casi identicas -- mismo criterio que public.set_updated_at(),
-- ya reusada por resources/services/service_entitlements desde la Fase 2.

create or replace function public.guard_organization_id_immutable()
returns trigger
language plpgsql
as $BODY$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'ORGANIZATION_ID_IS_IMMUTABLE';
  end if;

  return new;
end;
$BODY$;

comment on function public.guard_organization_id_immutable() is
  'ADR-0052: rechaza cualquier UPDATE que cambie organization_id en una tabla de negocio. Generica -- reusada por resources y services via WHEN (new.organization_id IS DISTINCT FROM old.organization_id), sin excepcion de rol.';

drop trigger if exists resources_guard_organization_id_immutable on public.resources;

create trigger resources_guard_organization_id_immutable
  before update on public.resources
  for each row
  when (new.organization_id is distinct from old.organization_id)
  execute function public.guard_organization_id_immutable();

drop trigger if exists services_guard_organization_id_immutable on public.services;

create trigger services_guard_organization_id_immutable
  before update on public.services
  for each row
  when (new.organization_id is distinct from old.organization_id)
  execute function public.guard_organization_id_immutable();

-- ============================================================
-- Deuda tecnica relacionada (ADR-0052), agrupada en la misma migracion
-- por ser del mismo tamano/naturaleza.
-- ============================================================

-- 1. check_schedule_rule_conflicts() (Fase 42/ADR-0044) distinguia
--    RESOURCE_NOT_FOUND (el Resource no existe) de NOT_AUTHORIZED (existe
--    pero el caller no es miembro de su organizacion) -- un oraculo menor
--    de existencia de recursos de otra organizacion (UUID v4, impacto
--    minimo, pero evitable). Se unifica a RESOURCE_NOT_FOUND, mismo
--    criterio no-oraculo ya aplicado por create_schedule_rules_batch()
--    desde la Fase 48 (no distinguir "no existe" de "no es tuyo" para un
--    resource_id que el caller no es dueno). Mismo cuerpo que la version
--    de la Fase 42 en todo lo demas.
create or replace function public.check_schedule_rule_conflicts(
  p_resource_id uuid,
  p_weekday int[],
  p_local_start_time time[],
  p_duration_minutes int,
  p_exclude_rule_id uuid default null
)
returns table (
  weekday int,
  local_start_time time,
  conflict_start_at timestamptz,
  conflict_end_at timestamptz,
  existing_slot_occurrence_id uuid,
  existing_schedule_rule_id uuid
)
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
  v_org public.organizations;
  v_weekday int;
  v_local_start_time time;
  v_day date;
  v_horizon_end date;
  v_start_at timestamptz;
  v_end_at timestamptz;
begin
  select * into v_resource from public.resources where id = p_resource_id;
  if not found then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_resource.organization_id) then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  -- Nothing to project for a non-exclusive resource -- overlap is allowed
  -- by design (ADR-0044), unchanged from before this migration.
  if not v_resource.is_exclusive then
    return;
  end if;

  if p_weekday is null or array_length(p_weekday, 1) is null
     or p_local_start_time is null or array_length(p_local_start_time, 1) is null then
    return;
  end if;

  select * into v_org from public.organizations where id = v_resource.organization_id;
  v_horizon_end := current_date + 90;

  foreach v_weekday in array p_weekday loop
    foreach v_local_start_time in array p_local_start_time loop
      v_day := current_date + ((v_weekday - extract(dow from current_date)::int + 7) % 7);

      while v_day <= v_horizon_end loop
        v_start_at := (v_day + v_local_start_time) at time zone v_org.timezone;
        v_end_at := v_start_at + make_interval(mins => p_duration_minutes);

        return query
          select v_weekday, v_local_start_time, so.start_at, so.end_at, so.id, so.schedule_rule_id
          from public.slot_occurrences so
          where so.resource_id = p_resource_id
            and so.status = 'ACTIVE'
            and so.resource_is_exclusive
            and (p_exclude_rule_id is null or so.schedule_rule_id <> p_exclude_rule_id)
            and tstzrange(so.start_at, so.end_at, '[)') && tstzrange(v_start_at, v_end_at, '[)');

        v_day := v_day + 7;
      end loop;
    end loop;
  end loop;
end;
$BODY$;

revoke execute on function public.check_schedule_rule_conflicts(uuid, int[], time[], int, uuid) from public, anon;
grant execute on function public.check_schedule_rule_conflicts(uuid, int[], time[], int, uuid) to authenticated, service_role;

-- 2. Falta un indice sobre slot_occurrences(held_by) where status='HELD'
--    (ADR-0051) -- hold_dynamic_slot() (Fase 50b) cuenta holds vivos del
--    caller con where held_by = auth.uid() and status = 'HELD' and
--    held_until > now(), hoy hace sequential scan de toda la tabla.
create index if not exists slot_occurrences_held_by_idx
  on public.slot_occurrences (held_by)
  where status = 'HELD';
