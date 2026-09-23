-- ============================================================
-- Phase 29 -- my_bookings(): identidad de la ocurrencia + color de servicio
-- ============================================================
-- Cierre pendiente de la agenda real de /me (Fase 23-ish): el frontend
-- deduplicaba una reserva propia contra la disponibilidad pública
-- comparando `startAt + serviceName` (occurrenceKey() en
-- frontend/lib/my-agenda.ts) porque my_bookings() no traía
-- slot_occurrence_id ni service_id -- no había con qué matchear por id.
-- El mismo hueco impedía pintar el bloque de la reserva propia con el
-- color real del servicio (services.color, Phase 14/16).
--
-- Se agregan tres columnas: slot_occurrence_id, service_id, service_color.
-- No cambia ninguna regla de negocio ni el WHERE -- mismo shape de
-- ADR-0010/0013, solo más columnas de identidad/presentación.
--
-- DROP + CREATE (no CREATE OR REPLACE): agrega columnas al resultado, y
-- Postgres no permite cambiar los OUT parameters de una función con
-- REPLACE (mismo motivo documentado en Phase 11 al agregar
-- not_generated_reason).

drop function if exists public.my_bookings(boolean);

create function public.my_bookings(p_include_past boolean default false)
returns table (
  booking_id uuid,
  status public.booking_status,
  organization_slug text,
  organization_name text,
  organization_timezone text,
  slot_occurrence_id uuid,
  service_id uuid,
  service_name text,
  service_color text,
  start_at timestamptz,
  end_at timestamptz,
  occurrence_status public.slot_occurrence_status,
  cancellation_reason public.booking_cancellation_reason,
  is_recurring boolean,
  not_generated_reason public.not_generated_reason
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.status,
    o.slug,
    o.name,
    o.timezone,
    so.id,
    s.id,
    s.name,
    s.color,
    so.start_at,
    so.end_at,
    so.status,
    b.cancellation_reason,
    b.recurring_booking_id is not null,
    b.not_generated_reason
  from public.bookings b
  join public.customers c on c.id = b.customer_id and c.profile_id = auth.uid()
  join public.slot_occurrences so on so.id = b.slot_occurrence_id
  join public.services s on s.id = so.service_id
  join public.organizations o on o.id = b.organization_id
  where p_include_past or so.start_at >= now()
  order by so.start_at asc;
$$;

comment on function public.my_bookings(boolean) is
  'Las Booking del cliente autenticado. slot_occurrence_id/service_id permiten al frontend matchear contra get_public_availability() por id en vez de startAt+serviceName; service_color pinta el bloque propio con el mismo color que la disponibilidad publica.';

-- DROP FUNCTION borra el objeto y con él sus privilegios: Postgres otorga
-- EXECUTE a PUBLIC por default en una función nueva. Phase 19 (security
-- fix) había revocado explícitamente PUBLIC/anon sobre my_bookings(boolean)
-- -- sin repetir el revoke acá, este DROP + CREATE reabriría esa función a
-- cualquier rol anónimo.
revoke execute on function public.my_bookings(boolean) from public, anon;
grant execute on function public.my_bookings(boolean) to authenticated;
