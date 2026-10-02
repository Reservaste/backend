-- Phase 50a: disponibilidad dinamica para Resources exclusivos, opt-in por
-- Resource (ADR-0051, Fase 1) -- parte 1/2
-- Ref: docs/decisions.md ADR-0051.
--
-- Partida en dos migraciones por una restriccion real de Postgres: un
-- valor de enum agregado via ALTER TYPE ... ADD VALUE no se puede usar
-- como literal (ni siquiera con un cast) dentro de una restriccion DDL
-- (como un EXCLUDE/indice parcial, que evalua su predicado de inmediato)
-- en la MISMA transaccion en la que se agrego -- confirmado en vivo
-- contra reservaste-stg (SQLSTATE 42P17, "functions in index predicate
-- must be marked IMMUTABLE"). Un cuerpo de funcion plpgsql no tiene este
-- problema (se valida recien en su primera ejecucion, ya en otra
-- transaccion) -- mismo precedente ya documentado para la Fase 31
-- (billing_cycle). Esta migracion (50a) agrega el valor 'HELD' y commitea;
-- la siguiente (50b, mismo timestamp base + 1 segundo) hace todo lo que
-- necesita referenciarlo en una restriccion DDL (el EXCLUDE ampliado) mas
-- el resto de la Fase 1 completa.
--
-- Problema que cierra: un Resource exclusivo (ADR-0044, is_exclusive=true)
-- que ofrece varios Service de distinta duracion (ej. un barbero con
-- "Corte" 30min y "Combo" 60min) arma una grilla pre-generada
-- independiente por servicio -- cuando el generador choca con una
-- ocurrencia ya existente de otro servicio en el mismo recurso, el EXCLUDE
-- de ADR-0044 rechaza el insert y generate_slot_occurrences_for_rule()
-- salta esa fecha en silencio, dejando huecos de disponibilidad
-- inexplicables. Este flag opt-in hace que ESE recurso calcule su
-- disponibilidad al momento de reservar (contra una "apertura general" sin
-- Service atado) en vez de depender de una grilla por ScheduleRule.
--
-- Decisiones tomadas en esta migracion que la ADR-0051 no especificaba
-- literalmente, porque el schema real no era exactamente como asumia el
-- resumen operativo (documentadas tambien junto a cada bloque):
--
--   1. services.duration_minutes (columna nueva, nullable): la ADR asume
--      "service.duration_minutes" como si ya existiera. En el schema real,
--      la duracion siempre vivio en schedule_rules.duration_minutes (por
--      par Service/Resource), nunca en Service -- correcto para el modelo
--      de grilla pre-generada, pero un Resource dinamico no tiene NINGUNA
--      ScheduleRule (por construccion, ver punto 8 de 50b), asi que no hay
--      de donde leer la duracion. Se agrega la columna, nullable (ningun
--      Service existente la necesita salvo que se use con un Resource
--      dinamico), y se valida en tiempo de ejecucion (no a nivel
--      constraint, para no bloquear la creacion normal de un Service)
--      dentro de get_dynamic_availability()/hold_dynamic_slot().
--   2. slot_occurrences.schedule_rule_id pasa a ser nullable: la tabla lo
--      tenia "not null references schedule_rules(id)" desde la Fase 3. Una
--      ocurrencia HELD/ACTIVE generada por hold_dynamic_slot() no proviene
--      de ninguna ScheduleRule -- se relaja la columna a nullable (ya
--      queda cubierto por el UNIQUE(schedule_rule_id, start_at) existente,
--      que trata NULLs como distintos entre si, y por el EXCLUDE de
--      ADR-0044/ampliado en 50b, que es el que realmente protege contra
--      solapamiento). Auditado: ningun otro consumidor en el schema hace
--      join directo slot_occurrences.schedule_rule_id -> schedule_rules
--      asumiendolo not null (los que existen son rb.schedule_rule_id ->
--      schedule_rules, de recurring_bookings, no afectados).
--   3. cancellation_reason reusado (ver 50b): la ADR pide "confirmar el
--      nombre real del enum/valor que corresponde usar" para limpiar HELD
--      vencidos. slot_occurrence_cancellation_reason ya tiene
--      'SLOT_CANCELLED' ('RULE_DISCONTINUED' es el otro valor, no aplica)
--      -- se reusa tal cual, sin agregar un tercer valor, porque "el hold
--      vencio sin confirmarse" es exactamente el mismo concepto que "esta
--      ocurrencia puntual se cancelo", no una categoria nueva.
--
-- Fuera de alcance deliberado de esta migracion (Fase 2 de la ADR, no
-- bloqueante): resource_availability_exceptions (feriados/bloqueos
-- puntuales sobre un Resource dinamico), constructor de franjas tipo
-- create_schedule_rule_span(), soporte N:M de Resources por Service
-- dinamico.

-- ============================================================
-- 1. resources.dynamic_availability -- opt-in, solo valido sobre un
--    Resource exclusivo.
-- ============================================================

alter table public.resources
  add column if not exists dynamic_availability boolean not null default false;

comment on column public.resources.dynamic_availability is
  'ADR-0051 Fase 1: opt-in del dueno, solo valido si is_exclusive=true (CHECK resources_dynamic_requires_exclusive). false por defecto: cero cambio de comportamiento para cualquier dato existente -- el modelo de grilla pre-generada (ScheduleRule) sigue igual. Prendido, este Resource deja de poder tener ScheduleRules activas (create_schedule_rules_batch lo rechaza con RESOURCE_IS_DYNAMIC) y su disponibilidad se calcula al momento de reservar via get_dynamic_availability()/hold_dynamic_slot(), contra resource_availability_windows en vez de una grilla por Service.';

alter table public.resources
  add constraint resources_dynamic_requires_exclusive
  check (not dynamic_availability or is_exclusive);

-- Guard: no se puede prender el flag (false -> true) mientras el recurso
-- todavia tiene ScheduleRules activas -- el dueno tiene que discontinuarlas
-- primero (discontinue_schedule_rule(), ya existente desde la Fase 3/5, que
-- cancela en cascada Booking/RecurringBooking afectadas de forma explicita).
-- Nunca cascadear esa cancelacion automaticamente como efecto colateral de
-- un toggle -- seria cancelar reservas reales de clientes sin que nadie lo
-- pidio explicitamente.
create or replace function public.resources_guard_dynamic_toggle()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.dynamic_availability and not old.dynamic_availability then
    if exists (
      select 1 from public.schedule_rules
      where resource_id = new.id and is_active
    ) then
      raise exception 'RESOURCE_HAS_ACTIVE_SCHEDULE_RULES';
    end if;
  end if;

  return new;
end;
$BODY$;

create trigger resources_guard_dynamic_toggle
  before update of dynamic_availability on public.resources
  for each row execute function public.resources_guard_dynamic_toggle();

-- ============================================================
-- 2. services.duration_minutes -- ver decision #1 en el encabezado de
--    este archivo.
-- ============================================================

alter table public.services
  add column if not exists duration_minutes int
    check (duration_minutes is null or duration_minutes > 0);

comment on column public.services.duration_minutes is
  'ADR-0051 Fase 1 (decision no explicitada literal en la ADR, necesaria por el schema real -- ver encabezado de la migracion 20261002100000): duracion intrinseca del Service, solo requerida cuando se ofrece desde un Resource con dynamic_availability=true. Esos Resources no tienen ninguna ScheduleRule (fuente habitual de duration_minutes), asi que get_dynamic_availability()/hold_dynamic_slot() leen esta columna. Nula para cualquier Service que solo se agenda via ScheduleRule -- sin cambio de comportamiento. Sin enforcement a nivel constraint de "obligatoria si se usa con un Resource dinamico": se valida en tiempo de ejecucion (SERVICE_NOT_FOUND si es null) para no bloquear la creacion normal de un Service antes de saber con que Resource se va a emparejar.';

-- ============================================================
-- 3. resource_availability_windows -- la "apertura general" de un Resource
--    dinamico (ej. "atiende lunes a viernes 9 a 17"), desacoplada de
--    cualquier Service. No reusa ScheduleRule con service_id nullable
--    (decision estructural ya confirmada en ADR-0051): es puramente
--    aditiva, y un Resource dinamico no tiene ninguna fila en
--    schedule_rules por construccion (punto 8 de 50b), asi que
--    RecurringBooking (atada a schedule_rule_id) no puede referenciarlo.
-- ============================================================

create table public.resource_availability_windows (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  resource_id uuid not null references public.resources (id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6), -- 0 = Sunday, matches schedule_rules.weekday
  local_start_time time not null,
  local_end_time time not null check (local_end_time > local_start_time),
  valid_from date not null default current_date,
  valid_until date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  constraint resource_availability_windows_valid_range check (valid_until is null or valid_until >= valid_from)
);

comment on table public.resource_availability_windows is
  'ADR-0051 Fase 1: apertura general de un Resource con dynamic_availability=true para un weekday dado (ej. "lunes 9 a 17"), sin Service atado -- a diferencia de ScheduleRule, una sola fila cubre un rango horario completo, no un punto de inicio fijo. get_dynamic_availability()/hold_dynamic_slot() calculan los horarios concretos dentro de esta ventana al momento de reservar.';

create index resource_availability_windows_resource_idx
  on public.resource_availability_windows (resource_id, weekday);
create index resource_availability_windows_organization_idx
  on public.resource_availability_windows (organization_id);

-- Mismo guard de pairing cross-tenant que schedule_rules_same_org (Fase 3):
-- resolver y validar organization_id internamente, nunca confiar en el
-- valor que manda el caller.
create or replace function public.check_resource_availability_window_same_org()
returns trigger
language plpgsql
as $BODY$
declare
  v_resource_org uuid;
begin
  select organization_id into v_resource_org from public.resources where id = new.resource_id;

  if v_resource_org is null or v_resource_org <> new.organization_id then
    raise exception 'ResourceAvailabilityWindow organization_id must match its Resource';
  end if;

  return new;
end;
$BODY$;

create trigger resource_availability_windows_same_org
  before insert or update on public.resource_availability_windows
  for each row execute function public.check_resource_availability_window_same_org();

-- RLS: mismo criterio de aislamiento multi-tenant que schedule_rules (Fase
-- 3) -- lectura/escritura solo para miembros de la organizacion via
-- is_organization_member(). Sin policy publica sobre la tabla misma: igual
-- que schedule_rules/slot_occurrences, la exposicion a anon pasa
-- exclusivamente por una RPC security definer (get_dynamic_availability()
-- en 50b), nunca por acceso directo a la tabla.
alter table public.resource_availability_windows enable row level security;

create policy resource_availability_windows_select_members
  on public.resource_availability_windows for select
  using (public.is_organization_member(organization_id));

create policy resource_availability_windows_write_staff
  on public.resource_availability_windows for all
  using (public.is_organization_member(organization_id));

-- ============================================================
-- 4. create_resource_availability_window(): alta simple, una fila por
--    weekday. Mismo perimetro de permiso que create_schedule_rule_group
--    (is_organization_member, nada mas granular).
-- ============================================================

create or replace function public.create_resource_availability_window(
  p_resource_id uuid,
  p_weekdays int[],
  p_local_start_time time,
  p_local_end_time time
)
returns setof public.resource_availability_windows
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
  v_weekdays_distinct int[];
  v_weekday int;
  v_window public.resource_availability_windows;
begin
  select * into v_resource from public.resources where id = p_resource_id;
  if not found then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_resource.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if not v_resource.dynamic_availability then
    raise exception 'RESOURCE_NOT_DYNAMIC';
  end if;

  if p_local_start_time is null or p_local_end_time is null or p_local_end_time <= p_local_start_time then
    raise exception 'INVALID_RANGE';
  end if;

  if p_weekdays is null or array_length(p_weekdays, 1) is null then
    raise exception 'NO_WEEKDAYS';
  end if;

  -- Distinct y ordenado, mismo criterio que create_schedule_rule_group:
  -- elegir lunes dos veces en la UI no debe crear dos filas identicas.
  select array_agg(distinct w order by w) into v_weekdays_distinct from unnest(p_weekdays) w;

  foreach v_weekday in array v_weekdays_distinct loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;
  end loop;

  foreach v_weekday in array v_weekdays_distinct loop
    insert into public.resource_availability_windows (
      organization_id, resource_id, weekday, local_start_time, local_end_time, created_by
    )
    values (
      v_resource.organization_id, p_resource_id, v_weekday, p_local_start_time, p_local_end_time, auth.uid()
    )
    returning * into v_window;

    return next v_window;
  end loop;
end;
$BODY$;

comment on function public.create_resource_availability_window(uuid, int[], time, time) is
  'ADR-0051 Fase 1: alta de resource_availability_windows, una fila por weekday. Exige is_organization_member() sobre el Resource (mismo perimetro que create_schedule_rule_group) y resources.dynamic_availability=true (RESOURCE_NOT_DYNAMIC si no).';

revoke execute on function public.create_resource_availability_window(uuid, int[], time, time) from public, anon;
grant execute on function public.create_resource_availability_window(uuid, int[], time, time) to authenticated;

-- ============================================================
-- 5. slot_occurrences: schedule_rule_id nullable (ver decision #2 en el
--    encabezado), slot_occurrence_status gana 'HELD', columnas
--    held_until/held_by.
-- ============================================================

alter table public.slot_occurrences
  alter column schedule_rule_id drop not null;

comment on column public.slot_occurrences.schedule_rule_id is
  'ADR-0051 Fase 1: nullable desde esta fase -- una ocurrencia creada por hold_dynamic_slot() (Resource con dynamic_availability=true) no proviene de ninguna ScheduleRule. NULL unicamente para esas filas; toda ocurrencia generada por generate_slot_occurrences_for_rule() sigue teniendo esta columna poblada como siempre.';

alter type public.slot_occurrence_status add value if not exists 'HELD';

alter table public.slot_occurrences
  add column if not exists held_until timestamptz,
  add column if not exists held_by uuid references public.profiles (id);

comment on column public.slot_occurrences.held_until is
  'ADR-0051 Fase 1: solo poblado para status=HELD -- TTL de 5 minutos puesto por hold_dynamic_slot(). Un HELD vencido (held_until <= now()) no cuenta como ocupado en get_dynamic_availability() ni bloquea el EXCLUDE de nuevas ocurrencias; se limpia (CANCELLED) de forma perezosa por el propio hold_dynamic_slot() (acotado al Resource) y, como housekeeping diario de respaldo, por generate_all_slot_occurrences().';

comment on column public.slot_occurrences.held_by is
  'ADR-0051 Fase 1: profiles.id de quien pidio el hold via hold_dynamic_slot(). Se conserva como trazabilidad aun despues de promover la fila a ACTIVE en book_dynamic_slot() -- nunca se borra ni se limpia al confirmar.';

notify pgrst, 'reload schema';
