-- Phase 50c: fixes de seguridad sobre disponibilidad dinamica (ADR-0051,
-- Fase 1), encontrados por el gate de seguridad obligatorio contra
-- 20261002100000_phase50a_dynamic_availability_enum.sql y
-- 20261002100001_phase50b_dynamic_availability.sql (ya aplicadas a
-- reservaste-stg). Esta migracion hace `create or replace`/ajustes
-- encima de lo ya aplicado -- no reescribe 50a/50b.
--
-- Incluye:
--   ALTO-1  cancelar una Booking dinamica no liberaba nunca el horario.
--   MEDIO-1 book_dynamic_slot() no validaba held_by -- robo/sabotaje de hold
--           ajeno, y funcionaba como oraculo (HOLD_EXPIRED vs HOLD_NOT_FOUND).
--   MEDIO-2 un STAFF podia escribir HELD directo via PostgREST, afectando
--           el tope global de holds de OTRAS organizaciones.
--   BAJO-1  inserts directos a schedule_rules esquivaban RESOURCE_IS_DYNAMIC.
--   BAJO-2  resource_availability_windows_write_staff era FOR ALL (incluia
--           DELETE) y permitia falsificar created_by.
--   BAJO-4  comentarios incorrectos sobre que hace el EXCLUDE con un HELD
--           vencido.
--
-- Fuera de alcance de esta pasada (confirmado explicitamente, no omitido
-- por descuido):
--   BAJO-3  "alguien sin forma de reservar igual puede holdear" -- decision
--           de producto diferida, no se toca aca.
--   Decision 3 de ADR-0051 ("un Service que requiera mas de un Resource
--           simultaneo queda bloqueado si alguno es dinamico") -- release
--           notes abajo.
--
-- Decision 3 de ADR-0051 (N:M) -- por que NO se agrega un guard nuevo aca:
--   `service_resources` ya es N:M a nivel de schema desde la Fase 2 (un
--   Service puede listar varios Resource, y viceversa), pero esa relacion
--   es "cualquiera de estos Resources puede prestar el Service" (semantica
--   OR: cada Booking real sigue consumiendo exactamente UN Resource via
--   schedule_rules.resource_id o hold_dynamic_slot(p_resource_id) --
--   ningun camino del schema hoy reserva dos Resources SIMULTANEAMENTE para
--   una misma Booking). La decision 3 de la ADR habla de bloquear esa otra
--   cosa -- un Service que exija N Resources a la vez (semantica AND) --
--   que es exactamente el "soporte N:M" que la propia ADR-0051 (seccion
--   "Fases") y el encabezado de 20261002100000 ya listan como Fase 2, no
--   bloqueante para la Fase 1 ("soporte N:M si aparece demanda real").
--   Agregar hoy un guard contra un mecanismo (reserva simultanea de N
--   Resources) que el schema ni siquiera implementa todavia seria
--   validar una funcionalidad inexistente, no cerrar un hueco real --
--   confirmado releyendo la ADR completa antes de decidir. Se deja
--   explicitamente diferido junto con BAJO-3, para cuando el soporte N:M
--   real (Fase 2) se construya.

-- ============================================================
-- ALTO-1: cancelar una Booking de un Resource dinamico deja la
-- SlotOccurrence ACTIVE para siempre (capacidad 1, sin reservas reales) --
-- rompe el invariante de CLAUDE.md "cancelar libera el cupo
-- inmediatamente" y permite vaciar la agenda de un Resource dinamico de
-- forma permanente (hold -> confirmar -> cancelar, repetido).
--
-- Fix: trigger AFTER UPDATE OF status ON bookings, no dentro de
-- cancel_booking() -- para cubrir TODOS los caminos que ya cancelan una
-- Booking cambiando su status (cliente, staff, cancelacion de serie,
-- makeup credits, lo que sea), sin tener que auditar ni mantener cada uno
-- por separado. Solo actua sobre SlotOccurrence con schedule_rule_id is
-- null (la marca de "viene de un Resource dinamico, nunca de grilla" --
-- ver decision #2 del encabezado de 20261002100000) y unicamente si ya no
-- queda ninguna Booking CONFIRMED sobre esa ocurrencia (un Resource
-- dinamico es is_exclusive=true asi que capacity=1 y nunca deberia haber
-- mas de una CONFIRMED simultanea, pero el chequeo es por conteo, no por
-- asuncion, para no asumir esa invariante en dos lugares distintos).
-- ============================================================

create or replace function public.release_dynamic_slot_on_booking_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_still_booked boolean;
begin
  select * into v_occurrence
    from public.slot_occurrences
    where id = new.slot_occurrence_id
    for update;

  -- No es una ocurrencia dinamica (schedule_rule_id poblado -> viene de una
  -- ScheduleRule/grilla, ADR-0009) o ya esta CANCELLED -- nada que hacer.
  if not found or v_occurrence.schedule_rule_id is not null or v_occurrence.status = 'CANCELLED' then
    return new;
  end if;

  select exists (
    select 1 from public.bookings
    where slot_occurrence_id = new.slot_occurrence_id and status = 'CONFIRMED'
  ) into v_still_booked;

  if not v_still_booked then
    update public.slot_occurrences
      set status = 'CANCELLED', cancelled_at = now(), cancellation_reason = 'SLOT_CANCELLED'
      where id = new.slot_occurrence_id;
  end if;

  return new;
end;
$BODY$;

comment on function public.release_dynamic_slot_on_booking_cancel() is
  'ADR-0051 Fase 1 (fix de seguridad ALTO-1, Fase 50c): cuando una Booking pasa a CANCELLED, si su SlotOccurrence es de un Resource dinamico (schedule_rule_id is null) y ya no le queda ninguna Booking CONFIRMED, la pasa a CANCELLED tambien -- liberando el horario de verdad. Trigger, no logica dentro de cancel_booking(), para cubrir todos los caminos existentes que cancelan una Booking.';

drop trigger if exists bookings_release_dynamic_slot on public.bookings;

create trigger bookings_release_dynamic_slot
  after update of status on public.bookings
  for each row
  when (new.status = 'CANCELLED' and old.status <> 'CANCELLED')
  execute function public.release_dynamic_slot_on_booking_cancel();

-- ============================================================
-- MEDIO-1: book_dynamic_slot() solo validaba status='HELD' and held_until
-- > now() -- nunca held_by. Cualquier cuenta autenticada que consiga el
-- slot_occurrence_id (ej. filtrado por URL/logs, /reservar/confirmar?slot=)
-- podia confirmar el hold de OTRA persona a su propio nombre, o hacerlo
-- fallar a proposito (el intento falla por otra razon -- ej. no es cliente
-- de esa organizacion -- y la reversion cancela el hold de la victima
-- igual). Ademas funcionaba como oraculo: HOLD_EXPIRED para cualquier id
-- existente, HOLD_NOT_FOUND para uno inexistente.
--
-- Fix: se agrega `held_by is distinct from auth.uid()` y
-- `schedule_rule_id is not null` (una ocurrencia de grilla normal nunca
-- deberia poder pasar por aca) a la condicion de rechazo, y se unifica el
-- resultado de TODAS esas ramas (no encontrada / no HELD / vencida / no es
-- tuya / es de grilla) en un unico 'HOLD_NOT_FOUND' -- nunca distinguir "no
-- es tuyo" de "no existe"/"vencio", mismo criterio de no-oraculo que ya
-- usa release_dynamic_hold(). 'HOLD_EXPIRED' deja de existir como resultado
-- distinto (no hay ningun consumidor todavia -- frontend-engineer construye
-- este flujo recien despues de este gate, ver ADR-0051 "Impacto").
-- ============================================================

create or replace function public.book_dynamic_slot(
  p_slot_occurrence_id uuid,
  p_use_makeup_credit boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_result jsonb;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found then
    return jsonb_build_object('status', 'HOLD_NOT_FOUND');
  end if;

  -- Fase 50c (MEDIO-1): unificado en un solo resultado -- no HELD, vencido,
  -- de otra persona, o de una ocurrencia de grilla (schedule_rule_id no
  -- nulo, nunca deberia llegar aca) devuelven exactamente lo mismo, sin
  -- distincion observable desde afuera.
  if v_occurrence.status <> 'HELD'
     or v_occurrence.held_until is null
     or v_occurrence.held_until <= now()
     or v_occurrence.held_by is distinct from auth.uid()
     or v_occurrence.schedule_rule_id is not null
  then
    return jsonb_build_object('status', 'HOLD_NOT_FOUND');
  end if;

  update public.slot_occurrences
    set status = 'ACTIVE', held_until = null
    where id = p_slot_occurrence_id;

  -- book_slot() vuelve a tomar FOR UPDATE sobre esta misma fila -- re
  -- entrante dentro de la misma transaccion y misma sesion (ADR-0004), no
  -- hay auto-deadlock. Delega el 100% de cobertura/pago/alta de Customer/
  -- creacion de Booking -- no se duplica una sola linea de esa logica.
  v_result := public.book_slot(p_slot_occurrence_id, p_use_makeup_credit);

  if coalesce(v_result ->> 'status', '') <> 'OK' then
    -- Revertir la promocion explicitamente: sin esto quedaria una
    -- SlotOccurrence ACTIVE fantasma, sin Booking, ocupando el horario
    -- para siempre (el Resource es exclusivo -- nadie mas podria usarlo).
    update public.slot_occurrences
      set status = 'CANCELLED', cancelled_at = now(), cancellation_reason = 'SLOT_CANCELLED'
      where id = p_slot_occurrence_id;
  end if;

  return v_result;
end;
$BODY$;

comment on function public.book_dynamic_slot(uuid, boolean) is
  'ADR-0051 Fase 1 (fix de seguridad MEDIO-1, Fase 50c): confirma un hold creado por hold_dynamic_slot(). HOLD_NOT_FOUND unico resultado de rechazo -- cubre no encontrada, no HELD, vencida, de otra persona (held_by <> auth.uid()) y ocurrencia de grilla (schedule_rule_id not null), sin distincion observable entre esos casos (no-oraculo, mismo criterio que release_dynamic_hold()). Promueve a ACTIVE y delega en book_slot() (ADR-0004/0025/0047) el resto del flujo. Si book_slot() no devuelve OK, revierte la promocion a CANCELLED explicitamente.';

revoke execute on function public.book_dynamic_slot(uuid, boolean) from public, anon;
grant execute on function public.book_dynamic_slot(uuid, boolean) to authenticated;

-- ============================================================
-- MEDIO-2: slot_occurrences_toggle_active_blocked (Fase 3) solo excluia
-- status='CANCELLED' de lo que un STAFF puede escribir directo via
-- PostgREST -- nunca excluyo HELD. Impacto real: el tope de 3 holds vivos
-- es GLOBAL por perfil (no por organizacion) -- un STAFF de la Organizacion
-- A, conociendo el profile_id de cualquier persona, podia convertir 3
-- ocurrencias de SU PROPIO Resource en HELD con held_by = <profile_id de
-- la victima> y held_until muy en el futuro, dejandola sin poder holdear
-- NADA en NINGUNA organizacion de la plataforma.
--
-- Fix: la policy ahora excluye HELD tanto para leer-para-escribir (USING)
-- como para el valor final (WITH CHECK) -- un STAFF nunca puede tocar una
-- fila que YA esta HELD (de nadie, ni de su propia organizacion -- es
-- indistinguible desde afuera si esa fila es de un hold ajeno o de un
-- Resource propio en curso, y no hay necesidad de negocio de tocarla
-- directo mientras esta HELD), y nunca puede hacer que una fila PASE a
-- HELD por este camino (unicamente hold_dynamic_slot() puede, via
-- SECURITY DEFINER). El resto de la logica (toggle reversible ACTIVE <->
-- BLOCKED, nunca CANCELLED) queda exactamente igual.
--
-- Verificado antes de este cambio: el unico camino del frontend que escribe
-- directo sobre slot_occurrences es updateOccurrenceCapacity()
-- (frontend/app/actions/admin.ts), que solo toca `capacity` -- nunca
-- `status` -- y nunca contra una fila HELD en la practica (la UI de agenda
-- no opera sobre holds dinamicos). Este cambio no lo rompe: si alguna vez
-- se invocara contra una fila HELD, el UPDATE simplemente no encuentra la
-- fila (USING la excluye), mismo comportamiento silencioso ya establecido
-- para el resto de este esquema -- no un error nuevo que la UI deba
-- manejar que no maneje ya.
-- ============================================================

drop policy if exists slot_occurrences_toggle_active_blocked on public.slot_occurrences;

create policy slot_occurrences_toggle_active_blocked
  on public.slot_occurrences for update
  using (public.is_organization_member(organization_id) and status <> 'HELD')
  with check (public.is_organization_member(organization_id) and status in ('ACTIVE', 'BLOCKED'));

comment on policy slot_occurrences_toggle_active_blocked on public.slot_occurrences is
  'ADR-0051 Fase 1 (fix de seguridad MEDIO-2, Fase 50c): reemplaza a la version de la Fase 3 (solo excluia CANCELLED). Un STAFF puede togglear ACTIVE <-> BLOCKED directo (reversible, bajo riesgo), pero nunca puede escribir CANCELLED (va por cancel_slot_occurrence(), que fija cancelled_at/by/reason atomicamente) ni tocar una fila que ya esta HELD, ni hacer que una fila pase a HELD por este camino -- eso es exclusivo de hold_dynamic_slot()/book_dynamic_slot() (SECURITY DEFINER). Sin esto, el tope global de 3 holds/perfil (ADR-0051) era saboteable por cualquier STAFF de cualquier organizacion contra cualquier perfil.';

-- ============================================================
-- BAJO-1: schedule_rules_insert_staff/schedule_rules_update_staff (Fase
-- 35, ADR-0036) permiten crear/reactivar una ScheduleRule sobre un Resource
-- dinamico sin pasar por create_schedule_rules_batch() (el chokepoint que
-- ya rechaza esto con RESOURCE_IS_DYNAMIC). Impacto confirmado como nulo
-- hoy -- generate_slot_occurrences_for_rule() salta esas reglas, ninguna
-- ocurrencia real se genera -- pero se cierra igual, barato.
--
-- Fix: trigger BEFORE INSERT OR UPDATE que, cuando la fila queda activa
-- (new.is_active), lee el Resource con FOR SHARE y rechaza si
-- dynamic_availability=true. El FOR SHARE ademas serializa contra el
-- trigger resources_guard_dynamic_toggle (BEFORE UPDATE OF
-- dynamic_availability ON resources, Fase 50a) -- cierra de paso la carrera
-- de dos transacciones prendiendo el flag y creando reglas en paralelo que
-- senalo el gate de seguridad.
-- ============================================================

create or replace function public.guard_schedule_rule_dynamic_resource()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
begin
  select * into v_resource from public.resources where id = new.resource_id for share;

  if found and v_resource.dynamic_availability then
    raise exception 'RESOURCE_IS_DYNAMIC';
  end if;

  return new;
end;
$BODY$;

comment on function public.guard_schedule_rule_dynamic_resource() is
  'ADR-0051 Fase 1 (fix de seguridad BAJO-1, Fase 50c): defensa en profundidad contra un insert/update directo (PostgREST) sobre schedule_rules que active una fila sobre un Resource con dynamic_availability=true, esquivando el chequeo de create_schedule_rules_batch(). FOR SHARE sobre el Resource serializa contra resources_guard_dynamic_toggle().';

drop trigger if exists schedule_rules_guard_dynamic_resource on public.schedule_rules;

create trigger schedule_rules_guard_dynamic_resource
  before insert or update on public.schedule_rules
  for each row
  when (new.is_active)
  execute function public.guard_schedule_rule_dynamic_resource();

-- ============================================================
-- BAJO-2: resource_availability_windows_write_staff (Fase 50a) es FOR ALL
-- -- incluye DELETE, contra el patron ya establecido por ADR-0036 (ninguna
-- tabla de negocio tiene DELETE por PostgREST). El INSERT directo ademas
-- permite falsificar created_by con cualquier profile_id y esquivar
-- RESOURCE_NOT_DYNAMIC (que solo valida create_resource_availability_window(),
-- no esta policy).
--
-- Fix: se reemplaza por INSERT + UPDATE separadas, sin ninguna policy de
-- DELETE (RLS deniega por default lo que no tiene policy -- un DELETE
-- simplemente no encuentra filas, la fila sobrevive). created_by =
-- auth.uid() obligatorio en el INSERT directo.
-- ============================================================

drop policy if exists resource_availability_windows_write_staff on public.resource_availability_windows;

create policy resource_availability_windows_insert_staff
  on public.resource_availability_windows for insert
  with check (public.is_organization_member(organization_id) and created_by = auth.uid());

create policy resource_availability_windows_update_staff
  on public.resource_availability_windows for update
  using (public.is_organization_member(organization_id))
  with check (public.is_organization_member(organization_id));

comment on policy resource_availability_windows_update_staff on public.resource_availability_windows is
  'ADR-0036/ADR-0051 Fase 1 (fix de seguridad BAJO-2, Fase 50c): reemplaza a resource_availability_windows_write_staff (era FOR ALL, incluia DELETE y no exigia created_by = auth.uid() en el INSERT). Sin policy de DELETE: dar de baja una ventana es is_active = false.';

-- ============================================================
-- BAJO-4: comentarios incorrectos en 50a/50b sobre que hace el EXCLUDE con
-- un HELD vencido -- decian "no bloquea el EXCLUDE", es al reves: el
-- predicado del EXCLUDE no puede evaluar held_until > now() (no es
-- inmutable), asi que SIGUE contando cualquier fila HELD como ocupada
-- hasta que algo la pasa FISICAMENTE a CANCELLED (la limpieza perezosa de
-- hold_dynamic_slot() o el housekeeping diario). Se corrige el texto via
-- `comment on`, sin tocar el DDL de 50a/50b.
-- ============================================================

comment on column public.slot_occurrences.held_until is
  'ADR-0051 Fase 1 (corrige el comentario de 20261002100000_phase50a_dynamic_availability_enum.sql, impreciso -- fix BAJO-4, Fase 50c): TTL de 5 minutos puesto por hold_dynamic_slot(), solo poblado para status=HELD. Un HELD vencido (held_until <= now()) deja de contar como ocupado en get_dynamic_availability() (lectura, sin side-effects) -- pero SIGUE contando como ocupado para el EXCLUDE slot_occurrences_exclusive_resource_no_overlap, que no puede evaluar held_until en su predicado (debe ser IMMUTABLE, now() no lo es). La liberacion real es un UPDATE fisico a CANCELLED, hecho de forma perezosa por el propio hold_dynamic_slot() (acotado al Resource) y, como housekeeping diario de respaldo, por generate_all_slot_occurrences().';

comment on function public.generate_all_slot_occurrences(int) is
  'ADR-0051 Fase 1 (corrige el comentario interno de 20261002100001_phase50b_dynamic_availability.sql, impreciso -- fix BAJO-4, Fase 50c): limpia HELD vencidos de mas de un dia. Es higiene de almacenamiento, no de correccion, UNICAMENTE para get_dynamic_availability() (que ya trata un HELD vencido como libre en lectura) -- pero SI es correccion real para el EXCLUDE slot_occurrences_exclusive_resource_no_overlap, que sigue contando cualquier fila HELD como ocupada sin importar held_until hasta que esta u otra limpieza la pase fisicamente a CANCELLED.';

notify pgrst, 'reload schema';
