-- Phase 49: disponibilidad publica por recurso -- opt-in (ADR-0048)
-- Ref: docs/decisions.md ADR-0048.
--
-- Problema que cierra: get_public_availability() nunca devolvio
-- resource_id ni el nombre del recurso -- un cliente que mira el
-- calendario publico no puede saber "con quien" es cada turno (ej. que
-- barbero). El RPC equivalente de staff (agenda_occurrences()) ya lo
-- expone; faltaba en el camino publico.
--
-- Decision: agregar al final del returns table (patron aditivo ya usado
-- varias veces en este archivo -- fase 5, 16, 20) resource_id uuid,
-- resource_name text. resource_id siempre se devuelve (opaco, sirve para
-- agrupar/filtrar sin revelar nada por si solo). resource_name solo se
-- devuelve si organizations.public_resource_names esta en true para esa
-- organizacion; si no, null. Regla de disclosure nueva, analoga en
-- espiritu a ADR-0008 pero sobre identidad en vez de cupo: si el recurso
-- es una persona, su nombre es un dato que hoy nunca sale por anon, y no
-- deberia empezar a salir por default silenciosamente -- por eso el flag
-- nace en false.

-- ============================================================
-- 1. organizations.public_resource_names -- opt-in del dueno, mismo
--    patron ya usado varias veces (open_booking_enabled,
--    makeup_credits_enabled, customer_activation_enabled,
--    public_availability_display).
-- ============================================================

alter table public.organizations
  add column if not exists public_resource_names boolean not null default false;

comment on column public.organizations.public_resource_names is
  'ADR-0048: opt-in del dueno. false por defecto: get_public_availability() nunca expone el nombre del recurso (resource_id si, siempre, es opaco). Prendido, el nombre real del recurso (ej. el barbero) se devuelve a anon junto con la disponibilidad.';

-- ============================================================
-- 2. get_public_availability(): agrega resource_id, resource_name al
--    final del returns table.
-- ============================================================
-- Dropped en vez de reemplazada: agregar una columna cambia los OUT
-- parameters. Cuerpo copiado del vigente en la Fase 20 (que ya advertia
-- sobre esto): reescribir de memoria las reglas de disclosure de
-- ADR-0008/ADR-0025 es como cambian en silencio.

drop function if exists public.get_public_availability(text, uuid, timestamptz, timestamptz);

create function public.get_public_availability(
  p_organization_slug text,
  p_service_id uuid default null,
  p_from timestamptz default now(),
  p_to timestamptz default now() + interval '30 days'
)
returns table (
  slot_occurrence_id uuid,
  service_id uuid,
  service_name text,
  service_color text,
  start_at timestamptz,
  end_at timestamptz,
  mode text,
  status text,
  remaining int,
  capacity int,
  recently_released boolean,
  resource_id uuid,
  resource_name text
)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org public.organizations;
begin
  select * into v_org from public.organizations where slug = p_organization_slug and is_active;
  if not found then
    return;
  end if;

  return query
    select
      so.id,
      so.service_id,
      s.name,
      s.color,
      so.start_at,
      so.end_at,
      effective.mode,
      case
        when effective.mode = 'EXACT' then null
        when effective.remaining <= 0 then 'FULL'
        when effective.mode = 'LIMITED' and effective.remaining <= effective.low_threshold then 'LOW'
        else 'AVAILABLE'
      end as status,
      case when effective.mode = 'EXACT' then effective.remaining end as remaining,
      case when effective.mode = 'EXACT' then so.capacity end as capacity,
      -- ADR-0025 §2.7.3, dos supresiones sobre la regla de ADR-0008:
      -- BOOLEAN existe justamente para que no se pueda inferir una
      -- transición, y capacidad 1 vuelve "se liberó" idéntico a "había
      -- una reserva y la cancelaron" (el problema original de ADR-0007).
      -- Ni número, ni actor, ni timestamp -- sólo el booleano.
      case
        when effective.mode = 'BOOLEAN' then null
        when so.capacity = 1 then null
        else (
          effective.remaining > 0
          and exists (
            select 1 from public.bookings b
            where b.slot_occurrence_id = so.id
              and b.status = 'CANCELLED'
              and b.cancellation_reason = 'CUSTOMER_REQUEST'
              and b.cancelled_at >= now() - interval '72 hours'
          )
        )
      end as recently_released,
      -- ADR-0048: resource_id siempre va (opaco). resource_name usa el
      -- v_org YA resuelto arriba por p_organization_slug -- nunca un
      -- segundo lookup ni un valor compartido entre organizaciones.
      so.resource_id,
      case when v_org.public_resource_names then r.name else null end as resource_name
    from public.slot_occurrences so
    join public.services s on s.id = so.service_id and s.is_active
    join public.resources r on r.id = so.resource_id
    cross join lateral (
      select
        coalesce(s.public_availability_display_override, v_org.public_availability_display) as mode,
        (so.capacity - (
          select count(*) from public.bookings b
          where b.slot_occurrence_id = so.id and b.status = 'CONFIRMED'
        ))::int as remaining,
        greatest(
          1,
          least(
            coalesce(v_org.low_availability_fixed_cap, so.capacity),
            ceil(so.capacity * v_org.low_availability_percentage / 100.0)::int
          )
        ) as low_threshold
    ) as effective
    where so.organization_id = v_org.id
      and so.status = 'ACTIVE'
      and so.start_at >= p_from
      and so.start_at <= p_to
      and (p_service_id is null or so.service_id = p_service_id)
    order by so.start_at asc;
end;
$BODY$;

grant execute on function public.get_public_availability(text, uuid, timestamptz, timestamptz) to anon, authenticated;

notify pgrst, 'reload schema';
