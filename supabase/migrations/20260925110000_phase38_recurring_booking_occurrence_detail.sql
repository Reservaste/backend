-- Phase 38: detalle fecha por fecha de un horario fijo YA ACTIVO.
--
-- Pedido del dueño (captura de pantalla): la fila de un cliente con
-- horario fijo mostraba a la vez, uno al lado del otro, el badge rojo
-- "Falta el pago" (de upcoming_unpaid, sin ninguna oración propia en el
-- frontend) y la oración informativa de upcoming_beyond_period ("N caen
-- más adelante..."). Leído en conjunto parece una contradicción. La
-- asimetría de mensajes se corrige en el frontend (standing-
-- reservations.tsx); esta migración resuelve la otra mitad del pedido:
-- "poder ver claramente qué tiene agendado y qué no", fecha por fecha, no
-- solo el conteo agregado que ya da schedule_rule_standing_reservations().
--
-- Por qué no reusar admin_preview_recurring_booking(): esa RPC evalúa
-- "como si la serie fuera la k+1-ésima" (v_existing_series is null ->
-- p_prospective_series = true en evaluate_customer_booking(), ver Fase 11
-- / Fase 32) -- es decir, sin contar la serie ya existente entre las que
-- ocupan la cuota del plan. Contra una RecurringBooking que YA existe eso
-- cuenta mal la posición de cuota (ver customer_series_in_force_count()
-- vs. customer_series_quota_position(), Fase 22): la trataría como una
-- serie ADICIONAL hipotética, no como la que ya está.
--
-- recurring_booking_occurrences() en cambio lee lo que YA HAY: para cada
-- Booking real de la serie (CONFIRMED o NOT_GENERATED, futura) devuelve
-- su not_generated_reason real, tal como quedó guardado la última vez que
-- generate_recurring_booking()/reconcile_pending_recurring_bookings()
-- escribió esa fila -- nunca se re-evalúa nada de forma prospectiva.
--
-- La única cuenta que esta función SÍ hace en el momento de leer es la
-- misma que schedule_rule_standing_reservations() (Fase 25) ya hace para
-- el agregado: separar PAYMENT_REQUIRED en "unpaid" (fecha dentro del
-- horizonte que se puede cobrar hoy) vs. "beyond_period" (fecha más allá
-- de lo que el cliente ya compró, no es deuda). Esa separación no es una
-- evaluación prospectiva de si la fecha "se podría reservar" -- es una
-- comparación de fechas (public.customer_billing_horizon(), ya definida
-- en la Fase 25) sobre un reason que la fila ya tiene guardado. Sin este
-- desdoble, el raw not_generated_reason = 'PAYMENT_REQUIRED' no alcanza
-- para decir cuál de las dos categorías del agregado es cada fila, y el
-- detalle no podría sumar igual que schedule_rule_standing_reservations()
-- (el requisito del test de integración de esta fase).
create or replace function public.recurring_booking_occurrences(p_recurring_booking_id uuid)
returns table (
  slot_occurrence_id uuid,
  start_at timestamptz,
  -- Vocabulario ya establecido en frontend/app/actions/standing.ts
  -- (StandingCreateSummary: confirmed/unpaid/overQuota/beyondPeriod/
  -- unavailable) -- se reusa acá para que el detalle fecha por fecha y el
  -- resumen agregado hablen el mismo idioma sin que el frontend tenga que
  -- re-mapear nada.
  display_status text,
  -- El dato real, sin traducir: para quien prefiera leer directamente lo
  -- que hay en bookings en vez de confiar en display_status.
  booking_status public.booking_status,
  not_generated_reason public.not_generated_reason
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    so.id,
    so.start_at,
    case
      when b.status = 'CONFIRMED' then 'CONFIRMED'
      when b.not_generated_reason = 'PAYMENT_REQUIRED' then
        case
          when public.slot_local_date(so.id)
               <= public.customer_billing_horizon(
                    rb.customer_id, sr.service_id,
                    (now() at time zone org.timezone)::date)
          then 'UNPAID'
          else 'BEYOND_PERIOD'
        end
      when b.not_generated_reason::text = 'OVER_PLAN_QUOTA' then 'OVER_QUOTA'
      else 'UNAVAILABLE'
    end,
    b.status,
    b.not_generated_reason
  from public.recurring_bookings rb
  join public.schedule_rules sr on sr.id = rb.schedule_rule_id
  join public.organizations org on org.id = sr.organization_id
  join public.bookings b on b.recurring_booking_id = rb.id
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  where rb.id = p_recurring_booking_id
    -- Mismo recorte de "upcoming" que schedule_rule_standing_reservations():
    -- CANCELLED queda afuera (no es una fecha pendiente, es historial), y
    -- so.start_at >= now() es el mismo horizonte rodante de 90 días de
    -- ADR-0009 -- no hace falta un techo explícito porque slot_occurrences
    -- ya no genera más allá de esa ventana.
    and b.status in ('CONFIRMED', 'NOT_GENERATED')
    and so.start_at >= now()
    and public.is_organization_member(rb.organization_id)
  order by so.start_at asc;
$BODY$;

comment on function public.recurring_booking_occurrences(uuid) is
  'Detalle fecha por fecha de una RecurringBooking YA ACTIVA: para cada Booking futura (CONFIRMED o NOT_GENERATED) de la serie, su estado real y el not_generated_reason real que generate_recurring_booking()/reconcile_pending_recurring_bookings() ya dejó guardado -- nunca evaluado de forma prospectiva. display_status desdobla PAYMENT_REQUIRED en UNPAID/BEYOND_PERIOD con la misma comparación de fechas que schedule_rule_standing_reservations() (Fase 25) usa para el agregado, para que ambas fuentes sumen igual. Distinta de admin_preview_recurring_booking(), que evalúa una serie PROSPECTIVA (todavía no creada) y por eso no puede reusarse acá: contaría mal la posición de cuota de una serie que ya existe.';

revoke execute on function public.recurring_booking_occurrences(uuid) from public, anon;
grant execute on function public.recurring_booking_occurrences(uuid) to authenticated;
