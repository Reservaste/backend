-- Phase 54: upgrade de plan a mitad de periodo (ADR-0050, Issue #4)
--
-- Problema: un cliente con un pago PAID de un plan (p. ej. 1x/semana) que
-- quiere pasar a 2x/semana a mitad de mes no puede: cargar el plan nuevo
-- por el mismo periodo choca con payment_service_coverage_no_overlap
-- ("Ya hay un pago registrado que cubre parte de ese periodo"). El
-- EXCLUDE es deliberado (ADR-0022/0024/0029) y NO se relaja: sigue
-- habiendo un solo pago vigente por (customer, service) en cada fecha, que
-- es lo que evita que el motor de reservas tenga que resolver "cual de dos
-- planes manda" (ADR-0024 resolucion 1).
--
-- Decision (ADR-0050): el upgrade PARTICIONA el periodo en vez de
-- solaparlo. admin_upgrade_payment() acorta el pago viejo
-- (period_end = fecha efectiva - 1) e inserta el pago nuevo (desde la
-- fecha efectiva hasta el fin original), en una sola transaccion. El
-- EXCLUDE queda intacto: acortar primero es lo que libera el rango para
-- el insert, y si cualquier paso falla (incluido el EXCLUDE) no cambia
-- nada.
--
-- Sin cambios de tablas ni constraints. El trigger
-- payments_coverage_sync_status (Fase 22) ya replica el period_end nuevo a
-- payment_service_coverage; el insert del pago nuevo dispara
-- fill_payment_service_coverage, check_payment_no_duplicate, la auditoria
-- (PAYMENT_CREATED), la reconciliacion de fechas pendientes (Fase 12) y el
-- cierre de plan_change_requests (Fase 28), igual que un cobro comun. Las
-- series NO se cancelan ni se crean (ADR-0024 res. 4): la cuota por fecha
-- ya resuelve el plan vigente por fecha, asi que desde la fecha efectiva
-- rige la frecuencia nueva.
--
-- Codigos de error (todos PAYMENT_UPGRADE_*, para que el frontend los
-- traduzca):
--   PAYMENT_UPGRADE_NOT_AUTHORIZED     pago inexistente, de otra organizacion
--                                      o sin MANAGE_PAYMENTS -- el mismo
--                                      error para los tres, para no revelar
--                                      si un pago ajeno existe (el
--                                      set_payment_status() de la Fase 32
--                                      distingue PAYMENT_NOT_FOUND de
--                                      NOT_AUTHORIZED y por eso filtra
--                                      existencia; esta RPC no).
--   PAYMENT_UPGRADE_NOT_PAID           el pago viejo no esta PAID
--   PAYMENT_UPGRADE_NOT_PERIOD_PAYMENT el pago es de turno suelto (DROP_IN /
--                                      anclado a una ocurrencia)
--   PAYMENT_UPGRADE_INVALID_DATE       fecha efectiva nula o fuera de
--                                      (period_start, period_end]
--   PAYMENT_UPGRADE_PLAN_NOT_FOUND     plan nuevo inexistente o de otra
--                                      organizacion (indistinguibles)
--   PAYMENT_UPGRADE_SAME_PLAN          el plan nuevo es el actual
--   PAYMENT_UPGRADE_PLAN_INACTIVE      plan nuevo desactivado
--   PAYMENT_UPGRADE_PLAN_DROP_IN       plan nuevo es de turno suelto
--   PAYMENT_UPGRADE_NOT_HIGHER_PLAN    el plan nuevo no es de mayor
--                                      frecuencia (bajar de plan sigue
--                                      siendo VOID + recargar, ADR-0024
--                                      res. 4)
--   PAYMENT_UPGRADE_SCOPE_MISMATCH     el plan nuevo no cubre exactamente
--                                      los mismos servicios que el pago
--                                      viejo
--   PAYMENT_UPGRADE_INVALID_AMOUNT     p_amount negativo o NaN
-- Ademas, un choque con otro pago PAID del cliente (p. ej. una renovacion
-- ya cargada) sigue saliendo del propio EXCLUDE/trigger de doble cobro
-- (payment_service_coverage_no_overlap / PAYMENT_DUPLICATE_PERIOD) y revierte
-- la transaccion entera.

create or replace function public.admin_upgrade_payment(
  p_payment_id uuid,
  p_new_plan_id uuid,
  p_effective_date date,
  p_amount numeric default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_org_id uuid;
  v_old public.payments;
  v_old_plan public.service_plans;
  v_new_plan public.service_plans;
  v_old_covered uuid[];
  v_new_covered uuid[];
  v_weekdays int[];
  v_total_sessions int;
  v_remaining_sessions int;
  v_amount numeric;
  v_new_id uuid;
begin
  -- Autorizacion ANTES de tomar ningun lock: un llamador sin permiso (o de
  -- otro tenant) no puede bloquear filas ajenas ni distinguir "no existe"
  -- de "no es tuyo".
  select organization_id into v_org_id from public.payments where id = p_payment_id;
  if v_org_id is null or not public.has_org_permission(v_org_id, 'MANAGE_PAYMENTS') then
    raise exception 'PAYMENT_UPGRADE_NOT_AUTHORIZED';
  end if;

  -- Bloquea el pago viejo y lo relee ya bajo el lock: dos upgrades
  -- concurrentes sobre el mismo pago se serializan, y el segundo ve el
  -- period_end ya acortado (y falla en la validacion de fecha).
  select * into v_old from public.payments where id = p_payment_id for update;
  -- Re-chequeo bajo el lock: la autorizacion se hizo sobre una lectura sin
  -- lock; si la fila cambio de organizacion en el medio, no se confia en ella.
  if not found or v_old.organization_id is distinct from v_org_id then
    raise exception 'PAYMENT_UPGRADE_NOT_AUTHORIZED';
  end if;

  if v_old.status <> 'PAID' then
    raise exception 'PAYMENT_UPGRADE_NOT_PAID';
  end if;

  if v_old.slot_occurrence_id is not null then
    raise exception 'PAYMENT_UPGRADE_NOT_PERIOD_PAYMENT';
  end if;

  select * into v_old_plan from public.service_plans where id = v_old.service_plan_id;
  if v_old_plan.plan_kind = 'DROP_IN' then
    raise exception 'PAYMENT_UPGRADE_NOT_PERIOD_PAYMENT';
  end if;

  if p_effective_date is null
     or p_effective_date <= v_old.period_start
     or p_effective_date > v_old.period_end
  then
    raise exception 'PAYMENT_UPGRADE_INVALID_DATE';
  end if;

  -- NaN explicito: 'NaN' < 0 es falso y numeric(12,2) lo acepta, asi que
  -- sin esto un NaN quedaba como amount de un PAID (mismo fix que Fase 44).
  if p_amount is not null and (p_amount = 'NaN'::numeric or p_amount < 0) then
    raise exception 'PAYMENT_UPGRADE_INVALID_AMOUNT';
  end if;

  -- Un plan de otra organizacion es indistinguible de uno inexistente.
  select * into v_new_plan
    from public.service_plans
   where id = p_new_plan_id and organization_id = v_old.organization_id;
  if not found then
    raise exception 'PAYMENT_UPGRADE_PLAN_NOT_FOUND';
  end if;

  if v_new_plan.id = v_old_plan.id then
    raise exception 'PAYMENT_UPGRADE_SAME_PLAN';
  end if;

  if not v_new_plan.is_active then
    raise exception 'PAYMENT_UPGRADE_PLAN_INACTIVE';
  end if;

  if v_new_plan.plan_kind = 'DROP_IN' then
    raise exception 'PAYMENT_UPGRADE_PLAN_DROP_IN';
  end if;

  -- "Mayor frecuencia": UNLIMITED > WEEKLY_QUOTA con mas weekly_quota.
  -- Todo lo demas (igual, menor, o partir de un UNLIMITED) es VOID + recargar.
  if not (
    (v_old_plan.plan_kind = 'WEEKLY_QUOTA' and v_new_plan.plan_kind = 'UNLIMITED')
    or (
      v_old_plan.plan_kind = 'WEEKLY_QUOTA' and v_new_plan.plan_kind = 'WEEKLY_QUOTA'
      and v_new_plan.weekly_quota > v_old_plan.weekly_quota
    )
  ) then
    raise exception 'PAYMENT_UPGRADE_NOT_HIGHER_PLAN';
  end if;

  -- Misma cobertura: los servicios que el pago viejo realmente cubre (sus
  -- filas de payment_service_coverage, que son lo que el motor de reservas
  -- lee) tienen que ser exactamente los que cubre el plan nuevo hoy.
  select coalesce(array_agg(psc.service_id order by psc.service_id), '{}')
    into v_old_covered
    from public.payment_service_coverage psc
   where psc.payment_id = v_old.id;

  select coalesce(array_agg(c order by c), '{}')
    into v_new_covered
    from public.service_plan_covered_service_ids(v_new_plan.id) as c;

  if v_old_covered is distinct from v_new_covered then
    raise exception 'PAYMENT_UPGRADE_SCOPE_MISMATCH';
  end if;

  -- Monto: lo que pasa el mostrador manda (mismo criterio que el cobro
  -- comun: no se valida contra el precio). Sin monto, prorrateo por
  -- sesiones restantes (ADR-0050).
  v_amount := p_amount;
  if v_amount is null then
    -- Dias de semana de las series en vigencia del cliente para los
    -- servicios cubiertos, como mucho tantas como la frecuencia del plan
    -- nuevo, en el orden de cuota (created_at, id) de
    -- customer_series_quota_position(). Un plan UNLIMITED no tiene una
    -- cantidad de series "completa", asi que nunca usa sesiones.
    if v_new_plan.plan_kind = 'WEEKLY_QUOTA' then
      select coalesce(array_agg(s.weekday), '{}') into v_weekdays
        from (
          select sr.weekday::int as weekday
            from public.recurring_bookings rb
            join public.schedule_rules sr on sr.id = rb.schedule_rule_id
           where rb.customer_id = v_old.customer_id
             and sr.service_id = any(v_new_covered)
             and rb.status = 'ACTIVE'
             and rb.start_date <= v_old.period_end
             and (rb.end_date is null or rb.end_date >= v_old.period_start)
           order by rb.created_at asc, rb.id asc
           limit v_new_plan.weekly_quota
        ) s;
    else
      v_weekdays := '{}';
    end if;

    v_total_sessions := 0;
    v_remaining_sessions := 0;

    -- Con menos series que la frecuencia del plan nuevo (el horario nuevo
    -- todavia no se armo: el caso tipico del issue) no se conocen todos
    -- los dias de semana: proporcion por dias corridos.
    if v_new_plan.plan_kind = 'WEEKLY_QUOTA'
       and coalesce(array_length(v_weekdays, 1), 0) >= v_new_plan.weekly_quota
    then
      -- timestamp (sin zona), no date: generate_series(date, date, interval)
      -- resuelve a timestamptz y dependeria de la zona de la sesion.
      select count(*)::int,
             (count(*) filter (where d.day >= p_effective_date))::int
        into v_total_sessions, v_remaining_sessions
        from (
          select g::date as day
            from generate_series(
              v_old.period_start::timestamp, v_old.period_end::timestamp, interval '1 day'
            ) as g
        ) d
        join unnest(v_weekdays) as w(weekday)
          on extract(dow from d.day)::int = w.weekday;
    end if;

    if v_total_sessions > 0 then
      v_amount := round(v_new_plan.price * v_remaining_sessions / v_total_sessions, 2);
    else
      v_amount := round(
        v_new_plan.price
          * (v_old.period_end - p_effective_date + 1)
          / (v_old.period_end - v_old.period_start + 1),
        2
      );
    end if;
  end if;

  -- Acortar primero: libera el rango para el insert (el EXCLUDE de
  -- payment_service_coverage lee la copia que payments_coverage_sync_status
  -- actualiza en este mismo UPDATE). El monto del viejo no se toca.
  --
  -- Auditoria: acortar period_end no cambia el status, asi que
  -- payments_audit_status no lo registra. El contexto viaja como nota
  -- (ADR-0032 §3, local a la transaccion) en el PAYMENT_CREATED del pago
  -- nuevo: queda constancia de que pago se acorto y desde/hasta cuando.
  perform set_config(
    'app.audit_note',
    format('UPGRADE from payment %s (plan %s): period_end %s -> %s',
           v_old.id, v_old.service_plan_id, v_old.period_end, p_effective_date - 1),
    true
  );

  update public.payments
     set period_end = p_effective_date - 1
   where id = v_old.id;

  insert into public.payments (
    organization_id, customer_id, service_plan_id,
    period_start, period_end, status, amount, notes, created_by
  ) values (
    v_old.organization_id, v_old.customer_id, v_new_plan.id,
    p_effective_date, v_old.period_end, 'PAID', v_amount, p_notes, auth.uid()
  )
  returning id into v_new_id;

  return v_new_id;
end;
$BODY$;

comment on function public.admin_upgrade_payment(uuid, uuid, date, numeric, text) is
  'ADR-0050: upgrade de plan a mitad de periodo. Acorta el pago viejo (period_end = fecha efectiva - 1) e inserta el nuevo (fecha efectiva .. fin original) en una transaccion, con FOR UPDATE sobre el viejo; el EXCLUDE de payment_service_coverage no se relaja. Requiere MANAGE_PAYMENTS en la organizacion del pago (un pago ajeno o inexistente da el mismo PAYMENT_UPGRADE_NOT_AUTHORIZED). Sin p_amount, prorratea por sesiones restantes (o por dias corridos si el horario nuevo aun no esta armado). Devuelve el id del pago nuevo. Codigos: ver cabecera de la migracion.';

revoke execute on function public.admin_upgrade_payment(uuid, uuid, date, numeric, text)
  from public, anon;
grant execute on function public.admin_upgrade_payment(uuid, uuid, date, numeric, text)
  to authenticated;
