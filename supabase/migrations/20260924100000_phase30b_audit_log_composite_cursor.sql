-- ============================================================
-- Phase 30b -- organization_audit_log(): cursor compuesto (created_at, id)
-- ============================================================
-- Hallazgo de QA sobre la Fase 30: la paginación cortaba con
-- `created_at < p_before` estricto. `audit_log.created_at` es
-- `default now()`, que es la hora de INICIO de la transacción, no
-- clock_timestamp(). cancel_slot_occurrence() y discontinue_schedule_rule()
-- cancelan N reservas en un solo UPDATE dentro de una misma transacción, y
-- el trigger bookings_audit_cancel escribe N filas de audit_log con el
-- MISMO created_at exacto. Si el límite de página caía en medio de ese
-- grupo, la página siguiente pedía `created_at < <ese timestamp>` y las
-- filas restantes del grupo no aparecían en NINGUNA página: los datos
-- estaban, pero no se veían, y sin ningún error.
--
-- Fix: keyset pagination sobre la clave total (created_at, id). El orden ya
-- era `created_at desc, id desc` desde la Fase 30; lo que faltaba era que
-- el corte usara la misma clave que el orden. `id` es la PK, así que la
-- tupla es única y el corte es exacto: cada fila cae en exactamente una
-- página.
--
-- Cambio de CONTRATO (docs/api.md): `p_before timestamptz` se reemplaza por
-- `p_before_created_at timestamptz` + `p_before_id uuid`, los dos tomados de
-- la ÚLTIMA fila de la página anterior. Van juntos o no van: uno solo es un
-- cursor ambiguo y se rechaza con INVALID_CURSOR en vez de adivinar.
--
-- drop + create (no `create or replace`): cambia la lista de argumentos, y
-- dejar la firma vieja viva como overload mantendría el camino con el bug
-- invocable por PostgREST. Por eso los grants se re-declaran abajo.
--
-- Advertencia para el consumidor (también en docs/api.md): created_at tiene
-- precisión de MICROsegundos. El cursor se tiene que devolver tal cual vino
-- de la RPC (el string). Pasarlo por `new Date(...)`/`Date.parse` lo trunca
-- a milisegundos, el cursor queda ANTES del grupo real y se pierden filas
-- -- exactamente el bug que esta migración cierra, por otro camino.

drop function if exists public.organization_audit_log(uuid, int, timestamptz);

create function public.organization_audit_log(
  p_organization_id uuid,
  p_limit int default 100,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table (
  id uuid,
  action public.audit_action,
  target_table text,
  target_id uuid,
  actor_id uuid,
  actor_name text,
  actor_is_platform boolean,
  metadata jsonb,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_is_platform_admin boolean := public.is_platform_admin();
begin
  if not v_is_platform_admin and not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Un cursor a medias no es "sin cursor" ni "cursor por fecha": con sólo
  -- la fecha volvería exactamente el bug de esta migración.
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'INVALID_CURSOR';
  end if;

  return query
  select
    a.id,
    a.action,
    a.target_table,
    a.target_id,
    case when v_is_platform_admin or m.profile_id is not null then a.actor_id end,
    case
      when a.actor_id is null then null
      when v_is_platform_admin or m.profile_id is not null
        then coalesce(nullif(btrim(p.full_name), ''), 'Sin nombre')
    end,
    (a.actor_id is not null and m.profile_id is null and not v_is_platform_admin),
    a.metadata,
    a.created_at
  from public.audit_log a
  left join public.organization_members m
    on m.organization_id = a.organization_id
   and m.profile_id = a.actor_id
  left join public.profiles p on p.id = a.actor_id
  where a.organization_id = p_organization_id
    -- Comparación de fila: (x, y) < (x0, y0) = x < x0 OR (x = x0 AND y < y0).
    -- Misma clave y mismo sentido que el ORDER BY; es lo que hace el corte
    -- exacto aunque N filas compartan created_at.
    and (
      p_before_created_at is null
      or (a.created_at, a.id) < (p_before_created_at, p_before_id)
    )
  order by a.created_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
end;
$$;

comment on function public.organization_audit_log(uuid, int, timestamptz, uuid) is
  'ADR-0032 resolución 1 y 2: el OWNER lee el log de su organización, más nuevo primero. Paginación keyset por (created_at, id): p_before_created_at + p_before_id = la última fila de la página anterior (los dos o ninguno; si no, INVALID_CURSOR). El actor de plataforma no se resuelve a nombre ni a uuid (actor_is_platform = true). STAFF recibe NOT_AUTHORIZED.';

revoke execute on function public.organization_audit_log(uuid, int, timestamptz, uuid) from public, anon;
grant execute on function public.organization_audit_log(uuid, int, timestamptz, uuid) to authenticated;

-- El índice de la pantalla pasa a cubrir la clave completa del cursor, así
-- el corte + orden se resuelven con un solo index scan sin sort por id
-- dentro de un grupo de timestamp idéntico.
drop index if exists public.audit_log_org_time_idx;
create index audit_log_org_time_idx on public.audit_log (organization_id, created_at desc, id desc);
