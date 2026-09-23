-- Phase 25: correcciones sobre el feedback del primer cliente en producción.
-- Ref: docs/decisions.md ADR-0013, ADR-0022, ADR-0024, ADR-0025, ADR-0029.
--
-- Nada de lo que hay acá cambia una decisión: cada bloque repara una
-- implementación que se apartó de la ADR que dice cómo tenía que ser.
--
--   1. Un pago de un plan multi-servicio (ADR-0029) era IMPOSIBLE de
--      registrar: check_payment_plan_consistency() pone service_id en NULL
--      a propósito cuando el plan cubre más de un servicio, y
--      check_payment_same_org() -- escrito en la Fase 7, cuando service_id
--      era obligatorio -- lo rechazaba por nulo. Verificado contra la base
--      local: todo insert con un plan `applies_to_all_services` falla con
--      'Payment organization_id must match its Customer and Service'.
--   2. Doble cobro: el EXCLUDE de ADR-0024 sólo mira status = 'PAID', así
--      que dos pagos PENDING idénticos (mismo cliente, servicio y período)
--      entran sin ninguna protección, y dos pagos de turno suelto sobre la
--      misma ocurrencia también mientras no sean PAID -- el hueco que
--      ADR-0027 dejó anotado. Verificado: los cuatro casos entran.
--   3. "Falta el pago" en un cliente con el mes al día:
--      schedule_rule_standing_reservations() contaba como impagas TODAS
--      las fechas futuras de la ventana rodante de 90 días (ADR-0009). Un
--      pago mensual nunca puede cubrir noventa días, así que el contador
--      era > 0 para todo horario fijo de todo cliente, siempre, y no había
--      forma de que se apagara. El motor de decisión NO tiene este
--      problema: se verificó que evaluate_customer_booking() responde OK
--      para cada fecha dentro del período pago, incluida una clase de las
--      21:00 del último día del mes (00:00 UTC del 1 del mes siguiente).
--   4. Un pago de plan multi-servicio tampoco se veía en la pantalla de
--      pagos: customer_payment_detail() joineaba services por
--      payments.service_id con un INNER JOIN.
--   5. El portal no tiene forma de avisar "esta reserva usa tu crédito":
--      can_customer_book() devuelve sólo el enum y pierde el
--      makeup_credit_id que el veredicto compuesto de ADR-0025 ya resuelve.

-- ============================================================
-- 1. Un pago de un plan multi-servicio tiene que poder registrarse
-- ============================================================
-- ADR-0029 §4.1: payments.service_id es derivada y vale NULL cuando el
-- plan cubre más de un servicio -- la cobertura completa vive en
-- payment_service_coverage. Esta función es de la Fase 7 y todavía
-- asumía la forma vieja. Se mantiene exactamente la misma garantía
-- (cliente y servicios del pago pertenecen a la organización del pago),
-- expresada sobre el conjunto cubierto en vez de sobre una sola columna.
create or replace function public.check_payment_same_org()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer_org uuid;
  v_service_org uuid;
  v_foreign int;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;

  if v_customer_org is null or v_customer_org <> new.organization_id then
    raise exception 'Payment organization_id must match its Customer';
  end if;

  if new.service_id is not null then
    select organization_id into v_service_org from public.services where id = new.service_id;
    if v_service_org is null or v_service_org <> new.organization_id then
      raise exception 'Payment organization_id must match its Service';
    end if;
    return new;
  end if;

  -- service_id nulo = plan multi-servicio. Se valida el conjunto cubierto:
  -- tiene que existir y no puede tener un servicio de otra organización.
  select count(*) into v_foreign
    from public.service_plan_covered_service_ids(new.service_plan_id) as covered
    join public.services s on s.id = covered
   where s.organization_id <> new.organization_id;

  if v_foreign > 0 then
    raise exception 'Payment organization_id must match every Service its ServicePlan covers';
  end if;

  if not exists (select 1 from public.service_plan_covered_service_ids(new.service_plan_id)) then
    raise exception 'SERVICE_PLAN_SCOPE_EMPTY';
  end if;

  return new;
end;
$BODY$;

comment on function public.check_payment_same_org() is
  'Coherencia de tenant de un Payment. ADR-0029: service_id es NULL en un plan multi-servicio, y en ese caso la validacion se hace contra el conjunto cubierto por el plan, no contra una columna que a proposito no existe.';

-- ============================================================
-- 2. Doble cobro: la protección deja de depender de status = 'PAID'
-- ============================================================
-- Las dos estructuras de ADR-0024 (el EXCLUDE sobre payment_service_coverage
-- y el índice único por ocurrencia) se dejan intactas: son la defensa
-- a prueba de carreras para el caso que mueve plata, y están validadas
-- contra los datos existentes. Lo que faltaba es el mismo invariante para
-- un pago que todavía no está cobrado, donde el riesgo no es la carrera
-- sino la carga repetida en el mostrador.
--
-- Por qué un trigger y no ampliar el EXCLUDE a `status <> 'VOID'`: ampliar
-- el predicado obliga a validar todas las filas históricas en el momento
-- del deploy, y si una organización ya tiene dos PENDING solapados
-- (exactamente el bug que se está corrigiendo) la migración falla o hay
-- que anular datos reales sin que nadie los haya mirado. "Nada se borra"
-- (invariants.md §5) incluye "nada se anula por su cuenta".
--
-- INSERT siempre, y UPDATE sólo para el caso que de verdad puede volver a
-- crear un duplicado: revivir un VOID a cualquier otro estado. Marcar
-- pagado un PENDING que solapa con otro ya lo rechaza el EXCLUDE, así que
-- ampliar esto a cualquier UPDATE de un pago no-VOID rechazaría también
-- las transiciones normales de set_payment_status() que no reviven nada,
-- sobre un camino cuya acción de frontend hoy ignora el error.
create or replace function public.check_payment_no_duplicate()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_conflict uuid;
begin
  if new.status = 'VOID' then
    return null;
  end if;

  -- Serializa por Customer: sin esto, dos INSERT concurrentes del mismo
  -- pago PENDING pasan los dos bajo Read Committed -- mismo TOCTOU que
  -- ADR-0004 cazó en book_slot(), verificado empíricamente acá con dos
  -- transacciones psql concurrentes reales.
  --
  -- Advisory lock y no `select ... for update` sobre la fila real del
  -- Customer: se probó esa versión primero y produjo un deadlock real (no
  -- teórico -- reproducido con Promise.all bajo el test de concurrencia de
  -- abajo). Este trigger corre AFTER INSERT, así que para cuando llega acá
  -- el chequeo de FK de payments.customer_id ya tomó un FOR KEY SHARE
  -- implícito sobre esa fila EN ESTA MISMA transacción; pedir después un
  -- FOR UPDATE sobre la misma fila es un upgrade de lock, y con seis
  -- transacciones concurrentes cada una ya sosteniendo su propio FOR KEY
  -- SHARE y esperando a que las demás lo suelten para poder subir a FOR
  -- UPDATE, la espera es circular. El advisory lock es una primitiva
  -- aparte que no interactúa con el locking de fila/FK de Postgres, así
  -- que no tiene ese problema -- mismo patrón que ya usan
  -- generate_all_slot_occurrences() (Fase 3) y
  -- submit_platform_contact_request() (Fase 24).
  perform pg_advisory_xact_lock(hashtext(new.customer_id::text));

  if new.slot_occurrence_id is not null then
    -- Turno suelto: el grano es la clase, no un período de un día
    -- (ADR-0024 §"El EXCLUDE se re-ancla"). El hueco que ADR-0027 dejó
    -- anotado es justamente que el índice único sólo mira PAID.
    select p.id into v_conflict
      from public.payments p
     where p.customer_id = new.customer_id
       and p.slot_occurrence_id = new.slot_occurrence_id
       and p.status <> 'VOID'
       and p.id <> new.id
     limit 1;

    if v_conflict is not null then
      raise exception 'PAYMENT_DUPLICATE_OCCURRENCE';
    end if;

    return null;
  end if;

  -- Pago por período: se compara contra payment_service_coverage, que es
  -- donde ADR-0029 dejó la cobertura real -- un plan de un servicio y uno
  -- multi-servicio que chocan sobre el mismo servicio no se ven mirando
  -- payments.service_id.
  select other.payment_id into v_conflict
    from public.payment_service_coverage mine
    join public.payment_service_coverage other
      on other.customer_id = mine.customer_id
     and other.service_id = mine.service_id
     and other.payment_id <> mine.payment_id
     and other.status <> 'VOID'
     and daterange(other.period_start, other.period_end, '[]')
         && daterange(mine.period_start, mine.period_end, '[]')
   where mine.payment_id = new.id
   limit 1;

  if v_conflict is not null then
    raise exception 'PAYMENT_DUPLICATE_PERIOD';
  end if;

  return null;
end;
$BODY$;

comment on function public.check_payment_no_duplicate() is
  'Doble cobro para pagos que todavia no estan PAID (ADR-0024 / hueco anotado por ADR-0027). El EXCLUDE y el indice unico de ADR-0024 siguen siendo la defensa a prueba de carreras de los pagos PAID; esto cubre el mismo invariante para PENDING/OVERDUE, donde el riesgo es la carga repetida en el mostrador. Serializa por Customer con un advisory lock (hashtext del customer_id) para que las cargas concurrentes no pasen todas -- verificado con Promise.all real; un lock de fila real (for update) sobre el Customer se probo primero y deadlockeaba, porque el chequeo de FK de payments.customer_id ya deja esta misma transaccion sosteniendo un FOR KEY SHARE sobre esa fila antes de que el trigger pida el upgrade. Corre en INSERT y en UPDATE, acotado por el WHEN del segundo trigger a la resurreccion VOID -> no-VOID.';

-- El nombre importa: los triggers corren en orden alfabético y este tiene
-- que ver las filas que payments_fill_service_coverage acaba de escribir
-- (f < n), después de que payments_plan_consistency derivó service_id.
--
-- Dos triggers, no uno con "INSERT OR UPDATE": Postgres rechaza un WHEN
-- que referencia OLD en un trigger cuyo conjunto de eventos incluye INSERT
-- (SQLSTATE 42P17 -- "INSERT trigger's WHEN condition cannot reference
-- OLD values", confirmado corriendo la migración) aunque el evento
-- combinado también incluya UPDATE. El de INSERT es el de siempre; el de
-- UPDATE es nuevo y se acota a la resurrección: un pago insertado como
-- VOID (aceptado, correcto) podía pasar a PENDING vía
-- set_payment_status() o un PATCH directo y dejar un duplicado sin que el
-- trigger -- que hasta acá sólo corría en INSERT -- lo viera nunca. No
-- dispara en cualquier UPDATE de un pago no-VOID: eso rompería las
-- transiciones normales de set_payment_status() (p. ej. PENDING -> PAID)
-- que no reviven nada. El nombre del segundo también importa: tiene que
-- ver la copia ya sincronizada de payments_coverage_sync_status (Fase 22,
-- c < n) antes de comparar períodos.
drop trigger if exists payments_no_duplicate on public.payments;
create trigger payments_no_duplicate
  after insert on public.payments
  for each row
  when (new.status <> 'VOID')
  execute function public.check_payment_no_duplicate();

drop trigger if exists payments_no_duplicate_on_resurrect on public.payments;
create trigger payments_no_duplicate_on_resurrect
  after update on public.payments
  for each row
  when (old.status = 'VOID' and new.status <> 'VOID')
  execute function public.check_payment_no_duplicate();

-- ============================================================
-- 3. "Falta el pago" acotado al período que se puede cobrar hoy
-- ============================================================
-- La ventana rodante de SlotOccurrence son 90 días (ADR-0009) y un pago
-- mensual cubre uno. Contar como "impaga" cada fecha de esa ventana deja
-- el contador permanentemente en rojo para un cliente que está al día, y
-- ADR-0018 existe precisamente para que el mostrador no lea "cobrale el
-- mes" cuando el mes ya está cobrado.
--
-- El horizonte es "hasta cuándo llega lo que este cliente ya compró": si
-- tiene cobertura vigente hoy, el fin de ese período; si no, el fin del
-- período que compraría hoy, resuelto con billing_period_for() sobre el
-- plan de su último pago no anulado -- y el fin del mes calendario si
-- nunca pagó nada de este servicio, que es lo que billing_period_for()
-- devuelve para el ciclo por defecto.
create or replace function public.customer_billing_horizon(
  p_customer_id uuid,
  p_service_id uuid,
  p_today date
)
returns date
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_horizon date;
  v_plan_id uuid;
begin
  select max(psc.period_end) into v_horizon
    from public.payment_service_coverage psc
    join public.payments p on p.id = psc.payment_id
   where psc.customer_id = p_customer_id
     and psc.service_id = p_service_id
     and p.status = 'PAID'
     and psc.period_start <= p_today
     and psc.period_end >= p_today;

  if v_horizon is not null then
    return v_horizon;
  end if;

  select p.service_plan_id into v_plan_id
    from public.payment_service_coverage psc
    join public.payments p on p.id = psc.payment_id
   where psc.customer_id = p_customer_id
     and psc.service_id = p_service_id
     and p.status <> 'VOID'
   order by psc.period_end desc, p.created_at desc
   limit 1;

  if v_plan_id is not null then
    select period_end into v_horizon from public.billing_period_for(v_plan_id, p_today);
    if v_horizon is not null then
      return v_horizon;
    end if;
  end if;

  return (date_trunc('month', p_today) + interval '1 month - 1 day')::date;
end;
$BODY$;

comment on function public.customer_billing_horizon(uuid, uuid, date) is
  'Hasta que fecha alcanza lo que este cliente ya compro de este servicio, o hasta donde llegaria el periodo que compraria hoy. Es el corte entre "esta fecha espera un pago" y "esta fecha todavia no se factura": sin el, la ventana rodante de 90 dias (ADR-0009) hace que un cliente al dia figure siempre en rojo.';

revoke execute on function public.customer_billing_horizon(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- La firma cambia (columna nueva), así que no alcanza CREATE OR REPLACE.
drop function if exists public.schedule_rule_standing_reservations(uuid);

create function public.schedule_rule_standing_reservations(p_schedule_rule_id uuid)
returns table (
  recurring_booking_id uuid,
  customer_id uuid,
  customer_name text,
  status public.recurring_booking_status,
  created_at timestamptz,
  upcoming_confirmed int,
  upcoming_not_generated int,
  upcoming_unpaid int,
  upcoming_over_quota int,
  upcoming_beyond_period int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    rb.id,
    rb.customer_id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    rb.status,
    rb.created_at,
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'CONFIRMED' and so.start_at >= now()),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED' and so.start_at >= now()),
    -- Sólo las fechas que están dentro del período que el cliente ya
    -- compró (o del que compraría hoy). Más allá de eso no falta un pago:
    -- todavía no se factura.
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()
        and public.slot_local_date(so.id)
            <= public.customer_billing_horizon(
                 rb.customer_id, sr.service_id,
                 (now() at time zone org.timezone)::date)),
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason::text = 'OVER_PLAN_QUOTA' and so.start_at >= now()),
    -- Las de más adelante, contadas aparte: son información ("el horario
    -- sigue reservado para cuando pague noviembre"), no una deuda.
    (select count(*)::int from public.bookings b
       join public.slot_occurrences so on so.id = b.slot_occurrence_id
      where b.recurring_booking_id = rb.id and b.status = 'NOT_GENERATED'
        and b.not_generated_reason = 'PAYMENT_REQUIRED' and so.start_at >= now()
        and public.slot_local_date(so.id)
            > public.customer_billing_horizon(
                rb.customer_id, sr.service_id,
                (now() at time zone org.timezone)::date))
  from public.recurring_bookings rb
  join public.customers c on c.id = rb.customer_id
  left join public.profiles p on p.id = c.profile_id
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  join public.organizations org on org.id = sr.organization_id
  where rb.schedule_rule_id = p_schedule_rule_id
    and public.is_organization_member(sr.organization_id)
  order by rb.status asc, coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$BODY$;

comment on function public.schedule_rule_standing_reservations(uuid) is
  'Las reservas fijas de una regla, con sus fechas futuras clasificadas. upcoming_unpaid es SOLO lo que se puede cobrar hoy; upcoming_beyond_period son las fechas mas alla del periodo vigente, que no son una deuda (la ventana rodante son 90 dias y un pago mensual cubre uno).';

revoke execute on function public.schedule_rule_standing_reservations(uuid) from public, anon;
grant execute on function public.schedule_rule_standing_reservations(uuid) to authenticated;

-- ============================================================
-- 4. Un pago de plan multi-servicio tiene que verse en la pantalla
-- ============================================================
-- INNER JOIN contra payments.service_id = el pago desaparece de la
-- pantalla de pagos cuando el plan cubre más de un servicio (ADR-0029).
-- Un pago invisible es indistinguible de un pago que no se registró.
create or replace function public.customer_payment_detail(
  p_customer_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  payment_id uuid,
  service_id uuid,
  service_name text,
  period_start date,
  period_end date,
  status public.payment_status,
  amount numeric,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    pay.id,
    pay.service_id,
    coalesce(s.name, sp.name, 'Plan'),
    pay.period_start,
    pay.period_end,
    pay.status,
    pay.amount,
    pay.created_at
  from public.payments pay
  left join public.services s on s.id = pay.service_id
  left join public.service_plans sp on sp.id = pay.service_plan_id
  where pay.customer_id = p_customer_id
    and pay.period_start <= p_period_end
    and pay.period_end >= p_period_start
    and public.is_organization_member(pay.organization_id)
  order by coalesce(s.name, sp.name, 'Plan') asc, pay.period_start desc;
$BODY$;

comment on function public.customer_payment_detail(uuid, date, date) is
  'Los pagos de un cliente que tocan un periodo. ADR-0029: payments.service_id es NULL en un plan multi-servicio, asi que el nombre cae al del plan en vez de que el pago desaparezca de la pantalla.';

revoke execute on function public.customer_payment_detail(uuid, date, date) from public, anon;
grant execute on function public.customer_payment_detail(uuid, date, date) to authenticated;

-- ============================================================
-- 5. El veredicto positivo, con el crédito que lo hizo posible
-- ============================================================
-- ADR-0025 §2.4.3: el veredicto viaja como par (reason, makeup_credit_id)
-- porque seis funciones comparan = 'OK'. can_customer_book() devuelve sólo
-- el enum, así que el portal muestra "Reservar" y gasta el crédito sin
-- avisar. No se duplica ninguna regla: esto es exactamente
-- evaluate_customer_booking() más el crédito que ya resolvió, leído del
-- mismo resolutor con el mismo orden total.
create or replace function public.can_customer_book_detail(p_slot_occurrence_id uuid)
returns table (
  reason public.can_book_reason,
  makeup_credit_id uuid,
  makeup_credit_expires_on date
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org uuid;
  v_customer_id uuid;
  v_service_id uuid;
begin
  reason := public.can_customer_book(p_slot_occurrence_id, true);
  makeup_credit_id := null;
  makeup_credit_expires_on := null;

  if reason <> 'OK' then
    return next;
    return;
  end if;

  select so.organization_id, so.service_id into v_org, v_service_id
    from public.slot_occurrences so where so.id = p_slot_occurrence_id;

  select id into v_customer_id from public.customers
    where organization_id = v_org and profile_id = auth.uid() and is_active;

  -- Un OK sin crédito es el caso normal: sólo se informa el crédito
  -- cuando la cobertura por sí sola NO alcanzaba (nunca se gasta un
  -- crédito si otra cobertura alcanzaba, ADR-0025 §2.4.1). Se lee del
  -- mismo resolutor canónico en vez de re-derivar su condición a mano:
  -- comparar evaluate_payment_coverage(...) <> 'OK' duplicaba la lista
  -- blanca de motivos que evaluate_payment_coverage_with_credit() ya
  -- mantiene -- si esa lista cambia algún día, esto se desincroniza en
  -- silencio en vez de romper algo visible.
  if v_customer_id is not null then
    select ewc.makeup_credit_id into makeup_credit_id
      from public.evaluate_payment_coverage_with_credit(
        v_customer_id, v_service_id, p_slot_occurrence_id, null, false, true
      ) ewc;

    if makeup_credit_id is not null then
      select expires_on into makeup_credit_expires_on
        from public.makeup_credits where id = makeup_credit_id;
    end if;
  end if;

  return next;
end;
$BODY$;

comment on function public.can_customer_book_detail(uuid) is
  'can_customer_book() mas el credito de recupero que haria posible la reserva (ADR-0025). Para que el portal pueda decir "esta reserva usa tu credito, vence el DD/MM" antes de gastarlo, en vez de gastarlo en silencio. No reimplementa ninguna regla: llama a can_customer_book() y a evaluate_payment_coverage_with_credit(), el mismo resolutor canonico que usa book_slot().';

-- ============================================================
-- 6. El piso de anticipación de liberación tiene que ser 1, no 0
-- ============================================================
-- updateOrganizationSettings (frontend/app/actions/settings.ts) valida
-- 1-720, pero el CHECK de la tabla (Fase 20) permitía 0-720, y
-- organizations es editable directo por el OWNER vía PostgREST
-- (organizations_update_owner, ADR-0013) -- el piso real era 0, no 1: un
-- OWNER podía poner release_deadline_hours = 0 sin pasar por el action,
-- dejando la política de ADR-0025 sin sentido (el crédito se emitiría
-- cancelando en la puerta del salón, exactamente lo que esa ADR vino a
-- impedir).
alter table public.organizations
  drop constraint organizations_release_deadline_hours_range;

alter table public.organizations
  add constraint organizations_release_deadline_hours_range
  check (release_deadline_hours between 1 and 720);

comment on constraint organizations_release_deadline_hours_range on public.organizations is
  'Entre 1h y 720h (30 dias, ADR-0025 S2.2 punto 3): 0 vacia la politica de anticipacion -- el credito se emitiria cancelando en la puerta -- y mas de 720h la haria imposible de ganar sin que el dueno pudiera notarlo salvo por un reclamo.';

revoke execute on function public.can_customer_book_detail(uuid) from public, anon;
grant execute on function public.can_customer_book_detail(uuid) to authenticated;

-- ============================================================
-- 7. El mismo piso, del lado del override en services
-- ============================================================
-- services_release_deadline_hours_override_range (Fase 20) seguía en
-- 0-720 -- el fix de #6 subió el piso de organizations pero no el del
-- override, que pisa ese mismo valor a nivel de un Service puntual
-- (resolve_makeup_credits_policy(): coalesce(override, org default)).
alter table public.services
  drop constraint services_release_deadline_hours_override_range;

alter table public.services
  add constraint services_release_deadline_hours_override_range
  check (release_deadline_hours_override is null or release_deadline_hours_override between 1 and 720);

comment on constraint services_release_deadline_hours_override_range on public.services is
  'Mismo piso que organizations_release_deadline_hours_range (#6 de esta migracion): 0 vacia la politica de anticipacion tambien cuando se fija por Service.';

-- ============================================================
-- 8. Los overrides de politica de credito en services son de OWNER, no de STAFF
-- ============================================================
-- services_write_staff (Fase 2) deja escribir cualquier columna de
-- services a cualquier member -- correcto para nombre/descripcion/
-- capacidad, que son operativas. Pero cuatro columnas de acá son
-- politica de negocio, no dato operativo: encienden/ajustan el credito
-- de recupero (ADR-0025 resolucion 3, "opt-in explicito del dueno") para
-- ESTE Service, pisando el default de la organizacion. Sin este trigger,
-- un STAFF autenticado con su propio JWT podia hacer
-- `PATCH /rest/v1/services?id=eq.<X>
--   {"makeup_credits_enabled_override": true, "release_deadline_hours_override": 1}`
-- directo por PostgREST -- pasando por encima del interruptor general
-- que el OWNER dejó apagado, exactamente lo que esa resolución vino a
-- impedir. La policy de UPDATE de la tabla completa no puede pasar a
-- OWNER-only (el resto de columnas sigue siendo edición normal de
-- STAFF): el chequeo tiene que ser por columna, no por tabla, así que va
-- en un trigger en vez de en la policy.
create or replace function public.check_service_billing_override_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.makeup_credits_enabled_override is distinct from old.makeup_credits_enabled_override
     or new.release_deadline_hours_override is distinct from old.release_deadline_hours_override
     or new.makeup_credit_expiry_override is distinct from old.makeup_credit_expiry_override
     or new.makeup_credit_expiry_days_override is distinct from old.makeup_credit_expiry_days_override
  then
    if not public.is_organization_owner(new.organization_id) then
      raise exception 'NOT_AUTHORIZED';
    end if;
  end if;

  return new;
end;
$BODY$;

comment on function public.check_service_billing_override_owner() is
  'Los cuatro overrides de politica de credito de recupero en services (makeup_credits_enabled_override, release_deadline_hours_override, makeup_credit_expiry_override, makeup_credit_expiry_days_override) solo los puede tocar el OWNER de la organizacion -- misma decision ya tomada para organizations (organizations_update_owner) y para updateServiceBilling/updateOrganizationSettings del lado del action. El resto de columnas de services sigue editable por cualquier member (services_write_staff); el chequeo es por columna, no por policy, porque esas dos cosas conviven en la misma tabla.';

drop trigger if exists services_billing_override_owner on public.services;
create trigger services_billing_override_owner
  before update on public.services
  for each row
  execute function public.check_service_billing_override_owner();
