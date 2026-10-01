-- Phase 45: reserva abierta -- alta de Customer en el momento de reservar,
-- detras de un flag por organizacion (ADR-0047)
-- Ref: docs/decisions.md ADR-0047.
--
-- Problema que cierra: can_customer_book() devuelve NOT_A_CUSTOMER para
-- cualquier cuenta autenticada que todavia no sea Customer activo de la
-- organizacion -- no existia ningun camino de autoservicio. Hoy ningun
-- cliente nuevo puede reservar sin que el dueno lo de de alta a mano
-- primero, lo cual contradice el FAQ de la landing ("solo necesitan una
-- cuenta simple").
--
-- Decision central de ADR-0047, no trivial: el alta on-the-fly vive
-- DENTRO de book_slot(), nunca dentro de can_customer_book() /
-- evaluate_customer_booking(). Esas dos ultimas tambien las invocan
-- funciones de solo-lectura (preview_recurring_booking(),
-- can_customer_book_detail(), quote_booking()) -- si el alta viviera ahi,
-- un preview inocente crearia Customers reales como side-effect no
-- deseado. book_slot() ya toma FOR UPDATE sobre la ocurrencia en el
-- intento real de reserva -- es el unico lugar seguro, y el rollback de
-- una reserva que despues falla (sin cupo, sin cobertura) se lleva puesto
-- el alta tambien, atomicamente.
--
-- Correccion post-gate de seguridad (docs/decisions.md, ADR-0047
-- "Correccion post-gate de seguridad"), aplicada sobre este mismo archivo
-- porque todavia no esta mergeado a main: dos hallazgos ALTO (tope de 2
-- reservas CONFIRMED futuras por Customer SELF_SERVICE, mas vedar
-- create_recurring_booking() para esos mismos Customers; filtrar
-- PLAN_LIMIT_REACHED/SUBSCRIPTION_INACTIVE del alta on-the-fly y bajar el
-- tope de altas por organizacion de 50/hora a 10/hora + 30/dia nuevo) y
-- un MEDIO (serializar los conteos de rate limit con
-- pg_advisory_xact_lock). Ver el comentario de cada bloque para el detalle.

-- ============================================================
-- 1. organizations.open_booking_enabled -- opt-in, mismo patron ya usado
--    tres veces (makeup_credits_enabled, customer_activation_enabled,
--    public_availability_display).
-- ============================================================

alter table public.organizations
  add column if not exists open_booking_enabled boolean not null default false;

comment on column public.organizations.open_booking_enabled is
  'ADR-0047: opt-in del dueno. false por defecto: nadie cambia de comportamiento el dia del deploy. Prendido, cualquier cuenta autenticada sin Customer previo puede reservar directo -- book_slot() da de alta un Customer source=SELF_SERVICE en la misma transaccion que la reserva.';

-- ============================================================
-- 2. customers.source -- distingue altas de mostrador (staff) de las
--    auto-inscriptas via reserva abierta. Enum, mismo estilo que el resto
--    del schema (customer_cancellation_reason, makeup_credit_origin, etc.)
--    en vez de un text+check suelto.
-- ============================================================

create type public.customer_source as enum ('STAFF', 'SELF_SERVICE');

comment on type public.customer_source is
  'ADR-0047: STAFF = de alta por el mostrador (enroll_customer_by_email, create_managed_customer, insert directo del panel -- todo lo que existia antes de esta fase). SELF_SERVICE = auto-inscripto por book_slot() con open_booking_enabled prendido.';

alter table public.customers
  add column if not exists source public.customer_source not null default 'STAFF';

comment on column public.customers.source is
  'ADR-0047. Default STAFF preserva el significado de todas las filas existentes (altas de mostrador, la unica via que existia hasta esta fase) -- solo book_slot() escribe SELF_SERVICE, para que el staff pueda filtrar/depurar altas auto-inscriptas.';

-- ============================================================
-- 3. can_book_reason: un valor nuevo, de solo-lectura, para que la UI
--    publica sepa mostrar "Reservar" en vez de "pedile al negocio que te
--    habilite" cuando la organizacion tiene reserva abierta prendida.
-- ============================================================

alter type public.can_book_reason add value if not exists 'OK_OPEN_BOOKING';

-- ============================================================
-- 4. can_customer_book(): unico cambio de comportamiento -- que devuelve
--    cuando NO hay Customer activo. Su logica de alta/reactivacion NO se
--    toca (vive solo en book_slot(), punto 5). Nota importante, mas
--    estricta que el enunciado original de la ADR: el reason nuevo solo
--    se devuelve si no existe NINGUNA fila de customers para ese (org,
--    profile_id) -- ni siquiera inactiva. Si existe una fila inactiva
--    (baja del staff), sigue devolviendo NOT_A_CUSTOMER igual que hoy,
--    sin que la reserva abierta pueda pasar por encima de esa decision --
--    ver el razonamiento completo junto a book_slot() mas abajo, donde
--    importa que esta funcion nunca "mienta" OK_OPEN_BOOKING para una
--    baja que book_slot() jamas va a reactivar.
-- ============================================================

create or replace function public.can_customer_book(
  p_slot_occurrence_id uuid,
  p_use_makeup_credit boolean default true
)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org uuid;
  v_customer_id uuid;
  v_open_booking boolean;
  v_has_any_customer_row boolean;
begin
  if auth.uid() is null then
    return 'AUTH_REQUIRED';
  end if;

  select organization_id into v_org from public.slot_occurrences where id = p_slot_occurrence_id;
  if v_org is null then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  select id into v_customer_id from public.customers
    where organization_id = v_org and profile_id = auth.uid() and is_active;
  if v_customer_id is null then
    -- ADR-0047: OK_OPEN_BOOKING solo si NO hay absolutamente ninguna fila
    -- (activa o inactiva) para este (org, profile) -- una baja del staff
    -- nunca queda disfrazada de "podes reservar".
    select exists (
      select 1 from public.customers
      where organization_id = v_org and profile_id = auth.uid()
    ) into v_has_any_customer_row;

    if not v_has_any_customer_row then
      select open_booking_enabled into v_open_booking
        from public.organizations where id = v_org;
      if coalesce(v_open_booking, false) then
        return 'OK_OPEN_BOOKING';
      end if;
    end if;

    return 'NOT_A_CUSTOMER';
  end if;

  return public.evaluate_customer_booking(p_slot_occurrence_id, v_customer_id, null, false, p_use_makeup_credit);
end;
$BODY$;

comment on function public.can_customer_book(uuid, boolean) is
  'ADR-0005/ADR-0047: la puerta de "se puede reservar". Sin Customer activo, devuelve OK_OPEN_BOOKING en vez de NOT_A_CUSTOMER unicamente si la organizacion tiene open_booking_enabled Y no existe ninguna fila de customers (ni inactiva) para (organization_id, auth.uid()). Nunca crea nada -- el alta real vive solo en book_slot(). Invocada tambien, de solo lectura, por can_customer_book_detail() y quote_booking().';

revoke execute on function public.can_customer_book(uuid, boolean) from public, anon;
grant execute on function public.can_customer_book(uuid, boolean) to authenticated;

-- ============================================================
-- 5. book_slot(): recreada desde la version vigente de la Fase 20
--    (20260922180000_phase20_makeup_credits.sql:726) -- mismo orden de
--    locks y mismo resultado final para toda ocurrencia que ya tenia un
--    Customer o que corre con el flag apagado. El unico comportamiento
--    nuevo es el bloque de alta on-the-fly, insertado DESPUES del FOR
--    UPDATE de la ocurrencia y ANTES de invocar can_customer_book() --
--    exactamente la mecanica que describe ADR-0047.
-- ============================================================

create or replace function public.book_slot(
  p_slot_occurrence_id uuid,
  p_use_makeup_credit boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_reason public.can_book_reason;
  v_coverage public.can_book_reason;
  v_makeup_credit_id uuid;
  v_occurrence public.slot_occurrences;
  v_org public.organizations;
  v_profile public.profiles;
  v_customer public.customers;
  v_active_count int;
  v_booking public.bookings;
  v_hourly_count int;
  v_daily_count int;
  v_org_daily_count int;
  v_self_service_active_count int;
  v_abort_detail text;
begin
  -- ADR-0004, sin cambios de fondo: el lock de la ocurrencia sigue siendo
  -- lo primero que hace esta funcion. ADR-0047 lo reusa tambien como el
  -- gate del alta on-the-fly (se decide despues de tomarlo, nunca antes)
  -- para que el rollback de una reserva que termina fallando (sin cupo,
  -- sin cobertura) se lleve puesto el alta del Customer tambien -- nunca
  -- queda un Customer huerfano sin Booking.
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found then
    -- Atajo: can_customer_book(), mas abajo, llega al mismo
    -- OCCURRENCE_NOT_AVAILABLE por su propio camino (vuelve a buscar la
    -- ocurrencia y tampoco la encuentra) -- esto solo evita trabajo de
    -- mas con organization_id nulo. El status/expiracion de la ocurrencia
    -- (status <> 'ACTIVE', end_at < now()) se sigue resolviendo, como
    -- siempre, dentro de evaluate_customer_booking() via
    -- can_customer_book() mas abajo -- mismo orden de motivos que antes
    -- de esta fase, solo que ahora despues del lock en vez de antes.
    return jsonb_build_object('status', 'OCCURRENCE_NOT_AVAILABLE');
  end if;

  -- ============================================================
  -- ADR-0047, la pieza que no es mecanica sino de correccion
  -- transaccional: un RETURN normal de una funcion plpgsql NO deshace lo
  -- que esa misma funcion ya escribio antes en la misma transaccion --
  -- solo una excepcion (atrapada o no) lo hace, via el SAVEPOINT
  -- implicito que crea todo bloque BEGIN/EXCEPTION. book_slot_paying()
  -- (Fase 44/ADR-0046) ya resolvio exactamente este problema para su
  -- Payment con el mismo mecanismo ("raise exception, nunca un status,
  -- desde el insert en adelante"). Aca el mismo bloque envuelve TODO el
  -- flujo de reserva (incluido el camino sin alta -- flag apagado o
  -- Customer ya existente) para no mantener dos copias del mismo flujo:
  -- cada salida que antes de esta fase era un RETURN directo ahora es un
  -- RAISE EXCEPTION 'BOOK_SLOT_ABORT' con el status real viajando en
  -- DETAIL, atrapado por el WHEN OTHERS de mas abajo, que lo devuelve
  -- como el mismo jsonb de siempre. El efecto neto para cualquier llamador
  -- (flag apagado, o Customer preexistente) es identico al de antes de
  -- esta fase; el efecto nuevo es que, si esta funcion SI creo un
  -- Customer mas abajo, cualquier fallo posterior lo deshace junto con
  -- todo lo demas.
  -- ============================================================
  begin
    select * into v_customer from public.customers
      where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;

    -- Alta on-the-fly: solo si no hay Customer ACTIVO para este (org,
    -- auth.uid()) todavia, y no existe absolutamente ninguna fila para
    -- ese par, ni siquiera inactiva -- esa segunda condicion es la que
    -- impide reactivar una baja hecha por el staff: si la fila existe
    -- pero esta inactiva, este bloque entero se saltea, v_customer sigue
    -- en null, y can_customer_book() mas abajo devuelve NOT_A_CUSTOMER
    -- (nunca OK_OPEN_BOOKING -- ver el comentario en esa funcion) igual
    -- que devolveria hoy sin esta fase.
    if v_customer.id is null and auth.uid() is not null and not exists (
      select 1 from public.customers
      where organization_id = v_occurrence.organization_id and profile_id = auth.uid()
    ) then
      select * into v_org from public.organizations where id = v_occurrence.organization_id;

      if v_org.id is not null and v_org.open_booking_enabled then
        -- Rate limit, mismo patron que issue_customer_activation() (Fase
        -- 21, 20260922190000_phase21_managed_customers.sql:335-353):
        -- resuelto adentro de la RPC, sin infraestructura nueva.
        --
        -- Corregido post-gate de seguridad (ADR-0047, "Correccion
        -- post-gate"): el tope original de 50 altas/organizacion/hora
        -- agotaba un plan starter completo (max_customers=50) en una
        -- sola hora de abuso y bloqueaba al staff de dar de alta
        -- clientes reales. Bajado a 10/hora, mas un tope diario nuevo de
        -- 30/organizacion que no existia antes. El tope por auth.uid()
        -- (5/24h, GLOBAL, no por organizacion -- la misma cuenta
        -- descartable podria repartir el abuso entre varios tenants en
        -- vez de concentrarlo en uno solo) se deja igual: el gate senalo
        -- que ya no es la defensa principal, porque crear una cuenta solo
        -- cuesta pasar el captcha -- la defensa real pasa a ser el tope
        -- de RESERVAS por Customer SELF_SERVICE de mas abajo.
        --
        -- Fix MEDIO del mismo gate: el conteo+chequeo no estaba
        -- serializado -- reproducido en vivo, 7 altas concurrentes
        -- pasaron contra un tope de 5. pg_advisory_xact_lock con
        -- namespace propio (dos claves int, no el keyspace de un solo
        -- bigint que ya usa check_payment_no_duplicate(), Fase 25, para
        -- otro proposito) serializa cada contador sin tocar el locking de
        -- filas real -- se libera solo al terminar la transaccion, igual
        -- que el resto de los advisory locks de este repo.
        perform pg_advisory_xact_lock(
          hashtext('book_slot_rate_limit_org'), hashtext(v_occurrence.organization_id::text)
        );

        select count(*) into v_hourly_count
          from public.customers
          where organization_id = v_occurrence.organization_id
            and source = 'SELF_SERVICE'
            and created_at > now() - interval '1 hour';
        if v_hourly_count >= 10 then
          raise exception 'BOOK_SLOT_ABORT' using detail = 'RATE_LIMITED_HOURLY';
        end if;

        select count(*) into v_org_daily_count
          from public.customers
          where organization_id = v_occurrence.organization_id
            and source = 'SELF_SERVICE'
            and created_at > now() - interval '24 hours';
        if v_org_daily_count >= 30 then
          raise exception 'BOOK_SLOT_ABORT' using detail = 'RATE_LIMITED_DAILY';
        end if;

        perform pg_advisory_xact_lock(
          hashtext('book_slot_rate_limit_user'), hashtext(auth.uid()::text)
        );

        select count(*) into v_daily_count
          from public.customers
          where profile_id = auth.uid()
            and source = 'SELF_SERVICE'
            and created_at > now() - interval '24 hours';
        if v_daily_count >= 5 then
          raise exception 'BOOK_SLOT_ABORT' using detail = 'RATE_LIMITED_DAILY';
        end if;

        select * into v_profile from public.profiles where id = auth.uid();

        begin
          insert into public.customers (
            organization_id, profile_id, display_name, is_active, source, created_by
          )
          values (
            v_occurrence.organization_id, auth.uid(),
            nullif(trim(v_profile.full_name), ''),
            true, 'SELF_SERVICE', auth.uid()
          )
          returning * into v_customer;
        exception
          when unique_violation then
            -- Concurrencia (ADR-0047): dos pestanas del mismo auth.uid()
            -- reservando ocurrencias DISTINTAS a la vez -- el FOR UPDATE
            -- de arriba no alcanza a serializar esto, porque cada
            -- transaccion lockea una fila de slot_occurrences distinta.
            -- Gana la primera en confirmar el insert sobre el
            -- unique(organization_id, profile_id) de customers (Fase 1);
            -- esta vuelve a leer la fila ya comprometida en vez de
            -- fallar. (Este catch es del unique_violation puntual, no del
            -- BOOK_SLOT_ABORT generico de mas abajo -- no interfiere con
            -- el.)
            select * into v_customer from public.customers
              where organization_id = v_occurrence.organization_id and profile_id = auth.uid();
          when others then
            -- Fix ALTO #2 del gate post-review: enforce_plan_limit()/
            -- organization_can_operate() (Fase 10, trigger BEFORE INSERT
            -- en customers) pueden abortar este insert con
            -- PLAN_LIMIT_REACHED -- que trae el conteo crudo de clientes
            -- del tenant en el mensaje, ej. "PLAN_LIMIT_REACHED: clientes
            -- (50/50)" -- o con SUBSCRIPTION_INACTIVE. Ninguno de los dos
            -- puede llegar tal cual a cualquier cuenta autenticada
            -- (reproducido en vivo); se traducen a un unico status opaco,
            -- sin filtrar el detalle.
            if sqlerrm = 'SUBSCRIPTION_INACTIVE' or sqlerrm like 'PLAN_LIMIT_REACHED%' then
              raise exception 'BOOK_SLOT_ABORT' using detail = 'ORGANIZATION_NOT_ACCEPTING_NEW_CUSTOMERS';
            end if;
            raise;
        end;
      end if;
    end if;

    -- can_customer_book() sigue siendo la unica puerta de "se puede
    -- reservar" (ADR-0005). Si el alta de arriba funciono (o ya habia un
    -- Customer activo), esta llamada encuentra esa fila por su cuenta
    -- (misma transaccion, misma fila recien insertada visible) y sigue el
    -- camino normal (OK / PAYMENT_REQUIRED / SLOT_FULL / etc. via
    -- evaluate_customer_booking()) -- nunca deberia ver OK_OPEN_BOOKING en
    -- este punto, porque esa rama de can_customer_book() solo dispara
    -- cuando no hay ninguna fila, y si el alta de arriba corria sin cortar
    -- camino antes (rate limit) esa fila ya existe.
    v_reason := public.can_customer_book(p_slot_occurrence_id, p_use_makeup_credit);
    if v_reason <> 'OK' then
      raise exception 'BOOK_SLOT_ABORT' using detail = v_reason::text;
    end if;

    -- Red de seguridad defensiva: en el camino normal v_customer ya quedo
    -- resuelto arriba (por la seleccion inicial o por el alta on-the-fly).
    -- Si por algun motivo no fue asi y can_customer_book() de todos modos
    -- dijo 'OK', se vuelve a leer antes de usarlo -- mejor un select de
    -- mas que un customer_id nulo llegando al insert de bookings de abajo.
    if v_customer.id is null then
      select * into v_customer from public.customers
        where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;
    end if;

    -- Fix ALTO #1 del gate post-review (ADR-0047): sin tope, una cuenta
    -- SELF_SERVICE (solo necesita pasar el captcha del signup, ninguna
    -- verificacion del staff) podia reservar todas las ocurrencias
    -- futuras de un servicio sin pago y vaciar la agenda. Corre siempre
    -- que el Customer resuelto tenga source='SELF_SERVICE' -- recien
    -- creado en esta misma llamada (bloque de alta de arriba) o ya
    -- existente de una reserva anterior, da igual el origen, lo que
    -- importa es el source actual de la fila. FOR UPDATE sobre la fila
    -- del Customer (no un advisory lock, a diferencia del rate limit de
    -- arriba): lo que hay que serializar es exactamente esa fila, igual
    -- que el FOR UPDATE de la ocurrencia mas arriba serializa el cupo --
    -- sin el, dos reservas en paralelo del mismo Customer podrian leer
    -- las dos "todavia tengo 1 activa" y pasar juntas. El staff "verifica"
    -- a un cliente real pasando source a STAFF (UPDATE directo va
    -- customers_update_staff, sin RPC nueva) -- desde ahi este bloque ni
    -- se ejecuta.
    --
    -- FOR NO KEY UPDATE, no FOR UPDATE (segundo pase del gate de
    -- seguridad): FOR UPDATE choca con el FOR KEY SHARE que toma todo FK
    -- check sobre customers (insert en recurring_bookings, bookings,
    -- payments, makeup_credits). admin_create_recurring_booking() toma ese
    -- KEY SHARE sobre el Customer ANTES de lockear ocurrencias (via
    -- generate_recurring_booking()), o sea el orden inverso al de esta
    -- funcion (ocurrencia -> Customer): reproducido en vivo, termina en
    -- "deadlock detected". NO KEY UPDATE no conflictua con KEY SHARE, pero
    -- si consigo mismo y con el UPDATE de source del staff -- sigue
    -- serializando exactamente lo que este tope necesita.
    if v_customer.id is not null and v_customer.source = 'SELF_SERVICE' then
      select * into v_customer from public.customers where id = v_customer.id for no key update;

      select count(*) into v_self_service_active_count
        from public.bookings b
        join public.slot_occurrences so on so.id = b.slot_occurrence_id
        where b.customer_id = v_customer.id
          and b.status = 'CONFIRMED'
          and so.start_at >= now();

      if v_self_service_active_count >= 2 then
        raise exception 'BOOK_SLOT_ABORT' using detail = 'SELF_SERVICE_BOOKING_LIMIT_REACHED';
      end if;
    end if;

    select count(*) into v_active_count
      from public.bookings
      where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

    if v_active_count >= v_occurrence.capacity then
      raise exception 'BOOK_SLOT_ABORT' using detail = 'SLOT_FULL';
    end if;

    select reason, makeup_credit_id into v_coverage, v_makeup_credit_id
    from public.evaluate_payment_coverage_with_credit(
      v_customer.id, v_occurrence.service_id, p_slot_occurrence_id, null, false, p_use_makeup_credit
    );
    if v_coverage <> 'OK' then
      raise exception 'BOOK_SLOT_ABORT' using detail = v_coverage::text;
    end if;

    insert into public.bookings (
      organization_id, customer_id, slot_occurrence_id, status, created_by
    )
    values (
      v_occurrence.organization_id, v_customer.id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
    )
    on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
    returning * into v_booking;

    if v_booking.id is null then
      raise exception 'BOOK_SLOT_ABORT' using detail = 'DUPLICATE';
    end if;

    if v_makeup_credit_id is not null then
      update public.makeup_credits
        set status = 'CONSUMED', consumed_booking_id = v_booking.id, consumed_at = now()
        where id = v_makeup_credit_id and status = 'AVAILABLE';

      if not found then
        -- ADR-0025 Sec 2.4.5, ahora tambien ADR-0047: nunca un status
        -- explicito aca -- se deja como excepcion "cruda" (no
        -- BOOK_SLOT_ABORT) para que se siga viendo como un error real del
        -- lado del cliente RPC, exactamente igual que antes de esta fase.
        -- El WHEN OTHERS de abajo igual la re-lanza (no la confunde con un
        -- BOOK_SLOT_ABORT), pero para entonces el ROLLBACK al SAVEPOINT ya
        -- deshizo todo lo de este bloque -- la Booking, y el Customer
        -- SELF_SERVICE si se creo en esta misma transaccion. Lo contrario
        -- dejaria una reserva extra confirmada sin haber consumido nada.
        raise exception 'MAKEUP_CREDIT_RACE_LOST';
      end if;
    end if;

    return jsonb_build_object(
      'status', 'OK',
      'booking', to_jsonb(v_booking),
      'makeup_credit_id', v_makeup_credit_id
    );
  exception
    when others then
      if sqlerrm = 'BOOK_SLOT_ABORT' then
        get stacked diagnostics v_abort_detail = pg_exception_detail;
        return jsonb_build_object('status', v_abort_detail);
      end if;
      -- Cualquier otro error (MAKEUP_CREDIT_RACE_LOST, o algo realmente
      -- inesperado) se re-lanza tal cual -- el ROLLBACK al SAVEPOINT de
      -- este bloque ya ocurrio al entrar aca, asi que re-lanzar no vuelve
      -- a dejar nada a medio insertar; solo propaga el error al llamador,
      -- igual que si este bloque no existiera.
      raise;
  end;
end;
$BODY$;

comment on function public.book_slot(uuid, boolean) is
  'ADR-0004/ADR-0025/ADR-0047: reserva atomica. Desde la Fase 45, si la organizacion tiene open_booking_enabled y auth.uid() no tiene ningun Customer (ni siquiera inactivo) para esa organizacion, da de alta un Customer source=SELF_SERVICE dentro de la MISMA transaccion -- todo el flujo posterior vive en un bloque BEGIN/EXCEPTION cuyo SAVEPOINT implicito hace que cualquier fallo despues del alta (SLOT_FULL, PAYMENT_REQUIRED, DUPLICATE, MAKEUP_CREDIT_RACE_LOST, SELF_SERVICE_BOOKING_LIMIT_REACHED) la deshaga tambien -- nunca queda un Customer huerfano. Nunca reactiva un Customer inactivo. Correccion post-gate de seguridad (misma Fase, sin migracion nueva): rate limit de altas SELF_SERVICE bajado a 10/organizacion/hora + 30/organizacion/dia (nuevo), 5 por auth.uid() (global) cada 24h sin cambios, todos serializados con pg_advisory_xact_lock para que llamadas concurrentes no se salteen el tope; PLAN_LIMIT_REACHED/SUBSCRIPTION_INACTIVE del trigger de planes (Fase 10) se atrapan y se devuelven como ORGANIZATION_NOT_ACCEPTING_NEW_CUSTOMERS, sin filtrar el detalle crudo; y un Customer source=SELF_SERVICE no puede tener mas de 2 Bookings CONFIRMED futuras (SELF_SERVICE_BOOKING_LIMIT_REACHED) -- el staff lo destraba pasando source a STAFF.';

revoke execute on function public.book_slot(uuid, boolean) from public, anon;
grant execute on function public.book_slot(uuid, boolean) to authenticated;

-- ============================================================
-- 6. create_recurring_booking(): recreada desde la version vigente de la
--    Fase 17 (20260922120000_phase17_service_plans.sql:1324) -- unico
--    cambio, agregado en la correccion post-gate de seguridad de
--    ADR-0047: rechaza de entrada si el Customer resuelto tiene
--    source='SELF_SERVICE'. Sin esto, una cuenta auto-inscripta por
--    reserva abierta podia armar una reserva fija recurrente que genera
--    una Booking para cada ocurrencia futura ya materializada de la
--    regla -- el mismo vaciamiento de agenda que el tope de 2 reservas de
--    book_slot() ya cierra para reservas sueltas, pero por otra puerta
--    (create_recurring_booking() nunca pasa por book_slot()).
-- ============================================================

create or replace function public.create_recurring_booking(p_schedule_rule_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_customer public.customers;
  v_rb public.recurring_bookings;
  v_occurrence_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers
    where organization_id = v_rule.organization_id and profile_id = auth.uid() and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  -- ADR-0047, correccion post-gate: un Customer SELF_SERVICE nunca puede
  -- armar una serie recurrente -- vedado de entrada, antes de cualquier
  -- otro chequeo (duplicado de serie, cupo de plan). El staff lo
  -- destraba pasando source a STAFF (UPDATE directo, customers_update_staff
  -- ya lo permite, sin RPC nueva).
  if v_customer.source = 'SELF_SERVICE' then
    raise exception 'SELF_SERVICE_CANNOT_CREATE_RECURRING';
  end if;

  -- One standing reservation per customer per rule, same as the
  -- front-desk path. Self-service never had this guard, and ADR-0024
  -- makes it load-bearing: "k series = k bookings a week" only holds if
  -- two series cannot follow the same weekly rule. Two of them would
  -- also generate a duplicate Booking for every occurrence.
  if public.customer_standing_series_on_rule(v_customer.id, p_schedule_rule_id, current_date) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  -- The series starts today (start_date defaults to current_date), so
  -- that is the date whose plan decides. The day these RPCs accept a
  -- start date, this becomes greatest(start_date, current_date).
  perform public.assert_series_within_plan_quota(v_customer.id, v_rule.service_id, current_date);

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by)
  values (v_rule.organization_id, v_customer.id, p_schedule_rule_id, auth.uid())
  returning * into v_rb;

  for v_occurrence_id in
    select id from public.slot_occurrences
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE' and start_at >= now()
  loop
    perform public.generate_recurring_booking(v_rb.id, v_occurrence_id);
  end loop;

  return v_rb;
end;
$BODY$;

comment on function public.create_recurring_booking(uuid) is
  'ADR-0024/ADR-0047: crea una reserva fija (RecurringBooking) self-service para el Customer autenticado sobre una ScheduleRule, y genera Bookings para toda ocurrencia futura ya materializada. Desde la correccion post-gate de la Fase 45 rechaza de entrada (SELF_SERVICE_CANNOT_CREATE_RECURRING) si el Customer tiene source=SELF_SERVICE -- evita que una cuenta auto-inscripta por reserva abierta vacie la agenda de una regla entera con una sola serie.';

revoke execute on function public.create_recurring_booking(uuid) from public, anon;
grant execute on function public.create_recurring_booking(uuid) to authenticated;
