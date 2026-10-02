-- Phase 50b: disponibilidad dinamica para Resources exclusivos, opt-in por
-- Resource (ADR-0051, Fase 1) -- parte 2/2
-- Ref: docs/decisions.md ADR-0051. Ver 20261002100000_phase50a_dynamic_availability_enum.sql
-- para el porque de la division en dos migraciones (restriccion de
-- Postgres sobre usar un valor de enum recien agregado dentro de una
-- restriccion DDL en la misma transaccion en la que se agrego).

-- ============================================================
-- 6. EXCLUDE de ADR-0044 ampliado: un HELD vigente ocupa el Resource
--    exclusivo exactamente igual que un ACTIVE. No se puede ampliar un
--    EXCLUDE existente in-place -- hace falta drop + add.
--
-- Limite tecnico documentado explicitamente (ADR-0051, "Riesgos
-- identificados"): el predicado de un EXCLUDE/indice parcial tiene que ser
-- una expresion INMUTABLE. now() no lo es -- por eso este predicado NUNCA
-- puede evaluar "held_until > now()" para decidir si un HELD todavia
-- cuenta. Que un HELD haya vencido se resuelve exclusivamente escribiendo
-- (UPDATE a CANCELLED) en el camino de lectura/escritura
-- (hold_dynamic_slot(), el housekeeping del punto 9, get_dynamic_availability()
-- para lectura sin side-effects) -- nunca moviendo esa condicion a este
-- WHERE. Que alguien intente "simplificarlo" asi en el futuro es
-- exactamente el error que este comentario busca prevenir.
-- ============================================================

-- Nota de implementacion: el valor 'HELD' se agrego en una migracion
-- ANTERIOR y ya committeada (20261002100000_phase50a_dynamic_availability_enum.sql)
-- -- Postgres no permite usar un valor de enum como literal dentro de la
-- misma transaccion en la que se agrego via ALTER TYPE ... ADD VALUE
-- (mismo problema ya resuelto en la Fase 31/billing_cycle), asi que esta
-- migracion se partio en dos para que el EXCLUDE de abajo (que evalua el
-- predicado de inmediato, a diferencia del cuerpo de una funcion plpgsql,
-- que recien se valida en su primera ejecucion) pudiera referenciar
-- 'HELD' sin error.
--
-- Segunda vuelta, confirmada en vivo contra reservaste-stg: el predicado
-- NO puede castear el enum a texto (status::text in (...)) -- Postgres
-- marca la funcion de salida de un enum (el cast a text) como STABLE, no
-- IMMUTABLE (los labels de un enum se pueden renombrar con ALTER TYPE
-- ... RENAME VALUE, asi que su representacion de texto no esta
-- garantizada estable para siempre), y un predicado de indice/EXCLUDE
-- exige IMMUTABLE estricto. La comparacion directa contra el valor del
-- enum (sin cast, status in ('ACTIVE','HELD')) si es inmutable -- es la
-- forma correcta, confirmada con una prueba aislada contra una tabla
-- temporal antes de aplicar este fix.
alter table public.slot_occurrences
  drop constraint slot_occurrences_exclusive_resource_no_overlap;

alter table public.slot_occurrences
  add constraint slot_occurrences_exclusive_resource_no_overlap
  exclude using gist (
    resource_id with =,
    tstzrange(start_at, end_at, '[)') with &&
  ) where (status in ('ACTIVE', 'HELD') and resource_is_exclusive);

-- ============================================================
-- 7. get_dynamic_availability(): horarios posibles para un Service en un
--    Resource (o todos los dinamicos que lo presten) en una fecha dada.
--    Mismo perimetro que get_public_availability() (Fase 49): stable,
--    security definer, grant a anon/authenticated. Mismas reglas de
--    disclosure de ADR-0008/ADR-0048 (resource_id siempre opaco,
--    resource_name solo si organizations.public_resource_names).
-- ============================================================

create or replace function public.get_dynamic_availability(
  p_organization_slug text,
  p_service_id uuid,
  p_date date,
  p_resource_id uuid default null
)
returns table (
  resource_id uuid,
  resource_name text,
  start_at timestamptz,
  end_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org public.organizations;
  v_service public.services;
  v_weekday int;
begin
  select * into v_org from public.organizations where slug = p_organization_slug and is_active;
  if not found then
    return;
  end if;

  select * into v_service from public.services
    where id = p_service_id and organization_id = v_org.id and is_active;
  -- Sin duration_minutes no hay candidatos que generar -- devuelve vacio,
  -- nunca un error, mismo criterio que get_public_availability() cuando
  -- la organizacion/slug no matchea: una RPC publica de disponibilidad
  -- nunca revela "por que" no hay horarios.
  if not found or v_service.duration_minutes is null then
    return;
  end if;

  -- El weekday de p_date es puramente calendario (no requiere conversion
  -- de zona horaria -- a diferencia de un timestamptz, un date no tiene
  -- instante que convertir). La conversion a UTC real ocurre mas abajo,
  -- recien al combinar esta fecha con cada horario candidato de la
  -- ventana, igual que generate_slot_occurrences_for_rule (ADR-0014).
  v_weekday := extract(dow from p_date)::int;

  return query
    select
      res.id,
      case when v_org.public_resource_names then res.name else null end,
      cand.start_at,
      cand.start_at + make_interval(mins => v_service.duration_minutes)
    from public.resources res
    join public.service_resources svr on svr.resource_id = res.id and svr.service_id = v_service.id
    join public.resource_availability_windows w
      on w.resource_id = res.id
      and w.weekday = v_weekday
      and w.is_active
      and w.valid_from <= p_date
      and (w.valid_until is null or w.valid_until >= p_date)
    cross join lateral (
      -- Paso fijo de 15 minutos (ADR-0051 Fase 1: valor fijo documentado,
      -- sin parametro step_minutes todavia -- ADR-0045 lo tiene a nivel
      -- ScheduleRule, no aplica aca). Ancla ambos extremos a p_date (nunca
      -- una fecha arbitraria distinta) para que la resta de duration_minutes
      -- nunca "envuelva" a otro dia: si la ventana es mas corta que la
      -- duracion, generate_series no produce filas.
      select gs as start_at
      from generate_series(
        ((p_date + w.local_start_time) at time zone v_org.timezone),
        ((p_date + w.local_end_time) at time zone v_org.timezone) - make_interval(mins => v_service.duration_minutes),
        interval '15 minutes'
      ) as gs
    ) as cand
    where res.organization_id = v_org.id
      and res.is_active
      and res.dynamic_availability
      and (p_resource_id is null or res.id = p_resource_id)
      and not exists (
        select 1 from public.slot_occurrences so
        where so.resource_id = res.id
          and (so.status = 'ACTIVE' or (so.status = 'HELD' and so.held_until > now()))
          and tstzrange(so.start_at, so.end_at, '[)')
              && tstzrange(cand.start_at, cand.start_at + make_interval(mins => v_service.duration_minutes), '[)')
      )
    order by res.id, cand.start_at;
end;
$BODY$;

comment on function public.get_dynamic_availability(text, uuid, date, uuid) is
  'ADR-0051 Fase 1: horarios de inicio posibles para un Service en Resources con dynamic_availability=true, generados cada 15 minutos dentro de cada resource_availability_window activa, excluyendo lo ya ocupado (ACTIVE o HELD vigente) de cada Resource. Mismo perimetro/disclosure que get_public_availability() (Fase 49, ADR-0008/ADR-0048).';

grant execute on function public.get_dynamic_availability(text, uuid, date, uuid) to anon, authenticated;

-- ============================================================
-- 8. hold_dynamic_slot(): insert real de un HELD, con rate limit y
--    limpieza perezosa acotada al Resource.
--
-- Decision de implementacion (no detallada literal en la ADR): las
-- validaciones de precondicion (recurso/servicio invalidos, horario fuera
-- de ventana) se devuelven como excepciones -- no como status en el jsonb
-- -- porque un llamador normal solo llega a este punto con datos que
-- get_dynamic_availability() ya le mostro como validos; si no coinciden,
-- es UI desincronizada o manipulacion directa del RPC, mismo criterio que
-- create_schedule_rule_group()/create_schedule_rule_span() (RESOURCE_NOT_FOUND
-- como excepcion). Los dos resultados que SI son parte normal del flujo de
-- negocio (tope de holds alcanzado, perdida de la carrera por el horario)
-- son jsonb, igual que book_slot() nunca lanza excepcion por SLOT_FULL.
-- ============================================================

create or replace function public.hold_dynamic_slot(
  p_resource_id uuid,
  p_service_id uuid,
  p_start_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
  v_org public.organizations;
  v_service public.services;
  v_end_at timestamptz;
  v_local_date date;
  v_weekday int;
  v_window_ok boolean;
  v_hold_count int;
  v_occurrence_id uuid;
  v_held_until timestamptz;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if not found or not v_resource.dynamic_availability or not v_resource.is_active then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  select * into v_org from public.organizations where id = v_resource.organization_id;
  if not found or not v_org.is_active then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  select * into v_service from public.services
    where id = p_service_id and organization_id = v_org.id and is_active;
  if not found or v_service.duration_minutes is null then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.service_resources
    where service_id = v_service.id and resource_id = v_resource.id
  ) then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if p_start_at is null or p_start_at < now() then
    raise exception 'OUTSIDE_AVAILABILITY_WINDOW';
  end if;

  v_end_at := p_start_at + make_interval(mins => v_service.duration_minutes);

  -- Mismo calculo de weekday/timezone que get_dynamic_availability(): la
  -- fecha local se resuelve convirtiendo el instante solicitado a la zona
  -- de la organizacion, nunca al reves (nunca se asume que p_start_at ya
  -- viene en hora local).
  v_local_date := (p_start_at at time zone v_org.timezone)::date;
  v_weekday := extract(dow from v_local_date)::int;

  select exists (
    select 1 from public.resource_availability_windows w
    where w.resource_id = v_resource.id
      and w.weekday = v_weekday
      and w.is_active
      and w.valid_from <= v_local_date
      and (w.valid_until is null or w.valid_until >= v_local_date)
      and p_start_at >= (v_local_date + w.local_start_time) at time zone v_org.timezone
      and v_end_at <= (v_local_date + w.local_end_time) at time zone v_org.timezone
  ) into v_window_ok;

  if not v_window_ok then
    raise exception 'OUTSIDE_AVAILABILITY_WINDOW';
  end if;

  -- Rate limit: maximo 3 holds vivos simultaneos por perfil. Mismo patron
  -- pg_advisory_xact_lock + count(*) que book_slot() (ADR-0047, Fase 45)
  -- usa para sus topes de alta SELF_SERVICE -- serializa el conteo sin
  -- tocar el locking de filas real.
  perform pg_advisory_xact_lock(hashtext('hold_dynamic_slot_rate_limit'), hashtext(auth.uid()::text));

  select count(*) into v_hold_count
    from public.slot_occurrences
    where held_by = auth.uid() and status = 'HELD' and held_until > now();

  if v_hold_count >= 3 then
    return jsonb_build_object('status', 'TOO_MANY_ACTIVE_HOLDS');
  end if;

  -- Limpieza perezosa acotada a ESTE Resource -- sin job nuevo, mismo
  -- criterio que customer_activations (ADR-0026). El housekeeping diario
  -- (punto 9 mas abajo, dentro de generate_all_slot_occurrences()) es solo
  -- higiene de almacenamiento para holds mas viejos de un dia, no la unica
  -- forma de limpiar uno vencido.
  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancellation_reason = 'SLOT_CANCELLED'
    where resource_id = p_resource_id and status = 'HELD' and held_until <= now();

  begin
    insert into public.slot_occurrences (
      organization_id, resource_id, service_id, start_at, end_at,
      generated_timezone, capacity, status, held_until, held_by, schedule_rule_id
    )
    values (
      v_org.id, p_resource_id, v_service.id, p_start_at, v_end_at,
      v_org.timezone, 1, 'HELD', now() + interval '5 minutes', auth.uid(), null
    )
    returning id, held_until into v_occurrence_id, v_held_until;
  exception
    when exclusion_violation then
      return jsonb_build_object('status', 'SLOT_NO_LONGER_AVAILABLE');
  end;

  return jsonb_build_object('status', 'OK', 'slot_occurrence_id', v_occurrence_id, 'held_until', v_held_until);
end;
$BODY$;

comment on function public.hold_dynamic_slot(uuid, uuid, timestamptz) is
  'ADR-0051 Fase 1: reserva temporal (5 minutos) de un horario sobre un Resource con dynamic_availability=true, para que deje de verse disponible mientras el cliente completa la reserva. Exige auth.uid() (AUTH_REQUIRED). Tope de 3 holds vivos simultaneos por perfil (TOO_MANY_ACTIVE_HOLDS). El EXCLUDE ampliado de slot_occurrences_exclusive_resource_no_overlap es el backstop real contra dos holds del mismo horario (SLOT_NO_LONGER_AVAILABLE).';

revoke execute on function public.hold_dynamic_slot(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.hold_dynamic_slot(uuid, uuid, timestamptz) to authenticated;

-- ============================================================
-- 9. book_dynamic_slot(): wrapper delgado sobre book_slot() -- no
--    reimplementa cobertura/pago/alta de Customer.
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

  if v_occurrence.status <> 'HELD' or v_occurrence.held_until is null or v_occurrence.held_until <= now() then
    return jsonb_build_object('status', 'HOLD_EXPIRED');
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
  'ADR-0051 Fase 1: confirma un hold creado por hold_dynamic_slot(). HOLD_NOT_FOUND / HOLD_EXPIRED si no esta HELD y vigente; promueve a ACTIVE y delega en book_slot() (ADR-0004/0025/0047) el resto del flujo -- mismo shape de respuesta que book_slot() siempre devolvio. Si book_slot() no devuelve OK, revierte la promocion a CANCELLED explicitamente.';

revoke execute on function public.book_dynamic_slot(uuid, boolean) from public, anon;
grant execute on function public.book_dynamic_slot(uuid, boolean) to authenticated;

-- ============================================================
-- 10. release_dynamic_hold(): cancela el propio hold antes de que venza.
-- ============================================================

create or replace function public.release_dynamic_hold(p_slot_occurrence_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- Sin "not found"/distincion de motivo: si no es tuyo o no esta HELD,
  -- esta sentencia simplemente no actualiza ninguna fila -- mismo criterio
  -- de no-oraculo que el resto del esquema (nunca revelar si un
  -- slot_occurrence_id ajeno existe o en que estado esta).
  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = 'SLOT_CANCELLED'
    where id = p_slot_occurrence_id
      and status = 'HELD'
      and held_by = auth.uid();
end;
$BODY$;

comment on function public.release_dynamic_hold(uuid) is
  'ADR-0051 Fase 1: libera el propio hold (status=HELD and held_by=auth.uid()) antes de que venza, p.ej. el cliente cambia de horario sin esperar los 5 minutos. No revela nada sobre un hold ajeno o inexistente -- no-op silencioso.';

revoke execute on function public.release_dynamic_hold(uuid) from public, anon;
grant execute on function public.release_dynamic_hold(uuid) to authenticated;

-- ============================================================
-- 11. Bloquear ScheduleRule sobre un Resource dinamico -- create_schedule_
--     rules_batch() es el chokepoint comun real (toda otra via delega en
--     ella); create_schedule_rule_group()/create_schedule_rule_span()
--     reciben el mismo chequeo fail-fast en el punto donde ya resuelven el
--     Resource, mismo patron "fail-fast aca, defensa en profundidad alla"
--     que la Fase 48 aplico para la validacion de organizacion. Cierra
--     tambien RecurringBooking (atada a schedule_rule_id: nunca va a
--     existir una ScheduleRule sobre la que crear una serie) y
--     admin_create_recurring_booking()/create_recurring_booking() sin
--     tocarlas -- fallan solas con SCHEDULE_RULE_NOT_FOUND al no encontrar
--     ninguna regla activa sobre ese Resource.
-- ============================================================

create or replace function public.create_schedule_rules_batch(
  p_organization_id uuid,
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays int[],
  p_local_start_times time[],
  p_duration_minutes int,
  p_capacity int
)
returns setof public.schedule_rules
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_resource public.resources;
  v_group_id uuid := gen_random_uuid();
  v_weekday int;
  v_local_start_time time;
  v_rule public.schedule_rules;
  v_conflict record;
begin
  select * into v_resource from public.resources where id = p_resource_id;
  if not found or v_resource.organization_id <> p_organization_id then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  -- ADR-0051 Fase 1: un Resource dinamico nunca tiene ScheduleRules -- su
  -- disponibilidad se calcula al momento de reservar, no via grilla.
  if v_resource.dynamic_availability then
    raise exception 'RESOURCE_IS_DYNAMIC';
  end if;

  select * into v_conflict
    from public.check_schedule_rule_conflicts(
      p_resource_id, p_weekdays, p_local_start_times, p_duration_minutes
    )
    limit 1;
  if found then
    raise exception 'RESOURCE_SCHEDULE_CONFLICT: weekday % at % conflicts with an existing occurrence starting %',
      v_conflict.weekday, v_conflict.local_start_time, v_conflict.conflict_start_at;
  end if;

  foreach v_weekday in array p_weekdays loop
    foreach v_local_start_time in array p_local_start_times loop
      insert into public.schedule_rules (
        organization_id, service_id, resource_id, weekday, local_start_time,
        duration_minutes, capacity, group_id, created_by
      )
      values (
        p_organization_id, p_service_id, p_resource_id, v_weekday, v_local_start_time,
        p_duration_minutes, p_capacity, v_group_id, auth.uid()
      )
      returning * into v_rule;

      return next v_rule;
    end loop;
  end loop;
end;
$BODY$;

revoke execute on function public.create_schedule_rules_batch(uuid, uuid, uuid, int[], time[], int, int)
  from public, anon, authenticated;

create or replace function public.create_schedule_rule_group(
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays smallint[],
  p_local_start_time time,
  p_duration_minutes int,
  p_capacity int
)
returns setof public.schedule_rules
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_resource public.resources;
  v_weekdays_distinct int[];
  v_weekday int;
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_service.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if not found or v_resource.organization_id <> v_service.organization_id then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  -- ADR-0051 Fase 1: fail-fast aca, defensa en profundidad en
  -- create_schedule_rules_batch() (que tambien lo rechaza).
  if v_resource.dynamic_availability then
    raise exception 'RESOURCE_IS_DYNAMIC';
  end if;

  if p_weekdays is null or array_length(p_weekdays, 1) is null then
    raise exception 'NO_WEEKDAYS';
  end if;

  select array_agg(distinct w order by w) into v_weekdays_distinct from unnest(p_weekdays::int[]) w;

  foreach v_weekday in array v_weekdays_distinct loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;
  end loop;

  return query select * from public.create_schedule_rules_batch(
    v_service.organization_id, v_service.id, p_resource_id,
    v_weekdays_distinct, array[p_local_start_time]::time[], p_duration_minutes, p_capacity
  );
end;
$BODY$;

revoke execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) from public, anon;
grant execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) to authenticated;

create or replace function public.create_schedule_rule_span(
  p_service_id uuid,
  p_resource_id uuid,
  p_weekdays int[],
  p_range_start time,
  p_range_end time,
  p_step_minutes int,
  p_duration_minutes int,
  p_capacity int
)
returns uuid
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_service public.services;
  v_resource public.resources;
  v_weekdays_distinct int[];
  v_weekday int;
  v_start_times time[];
  v_num_starts int;
  v_total int;
  v_group_ids uuid[];
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_service.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_resource from public.resources where id = p_resource_id;
  if not found or v_resource.organization_id <> v_service.organization_id then
    raise exception 'RESOURCE_NOT_FOUND';
  end if;

  -- ADR-0051 Fase 1: fail-fast aca, defensa en profundidad en
  -- create_schedule_rules_batch() (que tambien lo rechaza).
  if v_resource.dynamic_availability then
    raise exception 'RESOURCE_IS_DYNAMIC';
  end if;

  if p_duration_minutes is null or p_duration_minutes <= 0 then
    raise exception 'INVALID_DURATION';
  end if;

  if p_step_minutes is null or p_step_minutes < 5 then
    raise exception 'STEP_TOO_SHORT: step_minutes must be at least 5 minutes, got %', p_step_minutes;
  end if;

  if v_resource.is_exclusive and p_step_minutes < p_duration_minutes then
    raise exception 'SPAN_SELF_OVERLAP_ON_EXCLUSIVE_RESOURCE: step_minutes (%) is shorter than duration_minutes (%) on an exclusive Resource -- generated occurrences would overlap each other',
      p_step_minutes, p_duration_minutes;
  end if;

  if v_resource.is_exclusive and coalesce(p_capacity, 1) > 1 then
    raise exception 'EXCLUSIVE_RESOURCE_CAPACITY_MUST_BE_ONE';
  end if;

  if p_range_start is null or p_range_end is null or p_range_end <= p_range_start then
    raise exception 'INVALID_RANGE';
  end if;

  if p_weekdays is null or array_length(p_weekdays, 1) is null then
    raise exception 'NO_WEEKDAYS';
  end if;

  if array_length(p_weekdays, 1) > 7 then
    raise exception 'INVALID_WEEKDAY: too many weekday entries';
  end if;

  select array_agg(distinct w order by w) into v_weekdays_distinct from unnest(p_weekdays) w;

  foreach v_weekday in array v_weekdays_distinct loop
    if v_weekday < 0 or v_weekday > 6 then
      raise exception 'INVALID_WEEKDAY';
    end if;
  end loop;

  select array_agg(gs::time order by gs) into v_start_times
    from generate_series(
      date '2000-01-01' + p_range_start,
      date '2000-01-01' + p_range_end - make_interval(mins => p_duration_minutes),
      make_interval(mins => p_step_minutes)
    ) as gs;

  if v_start_times is null or array_length(v_start_times, 1) is null then
    raise exception 'RANGE_TOO_SHORT: no start time fits duration_minutes inside [range_start, range_end)';
  end if;

  v_num_starts := array_length(v_start_times, 1);
  if v_num_starts > 96 then
    raise exception 'TOO_MANY_START_TIMES: % start times requested for one day, max 96', v_num_starts;
  end if;

  v_total := array_length(v_weekdays_distinct, 1) * v_num_starts;
  if v_total > 672 then
    raise exception 'TOO_MANY_SCHEDULE_RULES: % rules requested (% weekdays x % start times), max 672 per call',
      v_total, array_length(v_weekdays_distinct, 1), v_num_starts;
  end if;

  select array_agg(group_id) into v_group_ids
    from public.create_schedule_rules_batch(
      v_service.organization_id, v_service.id, p_resource_id,
      v_weekdays_distinct, v_start_times, p_duration_minutes, p_capacity
    );

  if v_group_ids is null or array_length(v_group_ids, 1) is null then
    raise exception 'NO_RULES_CREATED';
  end if;

  return v_group_ids[1];
end;
$BODY$;

revoke execute on function public.create_schedule_rule_span(uuid, uuid, int[], time, time, int, int, int) from public, anon;
grant execute on function public.create_schedule_rule_span(uuid, uuid, int[], time, time, int, int, int) to authenticated;

-- ============================================================
-- 12. generate_slot_occurrences_for_rule(): filtro defensivo de una linea
--     para saltear Resources dinamicos. Por construccion (punto 11) un
--     Resource dinamico nunca deberia tener una ScheduleRule activa -- este
--     chequeo es higiene explicita, no la unica defensa.
-- ============================================================

create or replace function public.generate_slot_occurrences_for_rule(
  p_schedule_rule_id uuid,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_resource_dynamic boolean;
  v_horizon_days int;
  v_horizon_end date;
  v_day date;
  v_exception public.schedule_exceptions;
  v_local_start_time time;
  v_duration_minutes int;
  v_capacity int;
  v_start_at timestamptz;
  v_new_occurrence_id uuid;
  v_recurring_booking_id uuid;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    return;
  end if;

  -- ADR-0051 Fase 1: defensa explicita -- un Resource con
  -- dynamic_availability=true no genera ocurrencias via grilla, aunque por
  -- construccion nunca deberia llegar a tener una ScheduleRule activa
  -- (create_schedule_rules_batch lo rechaza con RESOURCE_IS_DYNAMIC).
  select dynamic_availability into v_resource_dynamic
    from public.resources where id = v_rule.resource_id;
  if coalesce(v_resource_dynamic, false) then
    return;
  end if;

  if auth.uid() is not null and not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  v_horizon_days := least(greatest(coalesce(p_horizon_days, 90), 0), 365);

  select * into v_org from public.organizations where id = v_rule.organization_id;

  v_horizon_end := least(
    current_date + v_horizon_days,
    coalesce(v_rule.valid_until, current_date + v_horizon_days)
  );

  v_day := greatest(v_rule.valid_from, current_date);
  v_day := v_day + ((v_rule.weekday - extract(dow from v_day)::int + 7) % 7);

  while v_day <= v_horizon_end loop
    select * into v_exception
      from public.schedule_exceptions
      where schedule_rule_id = p_schedule_rule_id and exception_date = v_day;

    if found and v_exception.exception_type = 'CANCELLED' then
      v_day := v_day + 7;
      continue;
    end if;

    v_local_start_time := coalesce((case when found then v_exception.modified_local_start_time end), v_rule.local_start_time);
    v_duration_minutes := coalesce((case when found then v_exception.modified_duration_minutes end), v_rule.duration_minutes);
    v_capacity := coalesce((case when found then v_exception.modified_capacity end), v_rule.capacity);

    v_start_at := (v_day + v_local_start_time) at time zone v_org.timezone;

    v_new_occurrence_id := null;
    begin
      insert into public.slot_occurrences (
        organization_id, schedule_rule_id, service_id, resource_id,
        start_at, end_at, generated_timezone, capacity,
        schedule_exception_id
      )
      values (
        v_rule.organization_id, v_rule.id, v_rule.service_id, v_rule.resource_id,
        v_start_at, v_start_at + make_interval(mins => v_duration_minutes), v_org.timezone, v_capacity,
        case when found then v_exception.id else null end
      )
      on conflict (schedule_rule_id, start_at) do nothing
      returning id into v_new_occurrence_id;
    exception
      when exclusion_violation then
        v_new_occurrence_id := null;
    end;

    if v_new_occurrence_id is not null then
      for v_recurring_booking_id in
        select id from public.recurring_bookings
        where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE'
      loop
        perform public.generate_recurring_booking(v_recurring_booking_id, v_new_occurrence_id);
      end loop;
    end if;

    v_day := v_day + 7;
  end loop;
end;
$BODY$;

revoke execute on function public.generate_slot_occurrences_for_rule(uuid, int) from public, anon;
grant execute on function public.generate_slot_occurrences_for_rule(uuid, int) to authenticated, service_role;

-- ============================================================
-- 13. generate_all_slot_occurrences(): housekeeping extra de una sola
--     sentencia (no un job nuevo, no una funcion nueva) -- limpia HELD
--     vencidos de mas de un dia, respaldo del cleanup perezoso y acotado
--     que ya hace hold_dynamic_slot() por Resource.
-- ============================================================

create or replace function public.generate_all_slot_occurrences(p_horizon_days int default 90)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule_id uuid;
  v_lock_acquired boolean;
begin
  select pg_try_advisory_xact_lock(hashtext('generate_all_slot_occurrences')) into v_lock_acquired;
  if not v_lock_acquired then
    return;
  end if;

  for v_rule_id in select id from public.schedule_rules where is_active loop
    perform public.generate_slot_occurrences_for_rule(v_rule_id, p_horizon_days);
  end loop;

  -- ADR-0051 Fase 1: higiene de almacenamiento, no de correccion (un HELD
  -- vencido ya es tratado como libre por get_dynamic_availability() y por
  -- el EXCLUDE -- este UPDATE solo evita que filas HELD viejas se acumulen
  -- para siempre si ningun hold_dynamic_slot() posterior sobre ese mismo
  -- Resource dispara su propia limpieza).
  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancellation_reason = 'SLOT_CANCELLED'
    where status = 'HELD' and held_until < now() - interval '1 day';
end;
$BODY$;

notify pgrst, 'reload schema';
