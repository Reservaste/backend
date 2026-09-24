-- ============================================================
-- Phase 27b -- slugs reservados en organizations.slug (hallazgo de security-engineer)
-- ============================================================
-- organizations_slug_format_check (Fase 27) valida el FORMATO, pero no
-- excluye los segmentos top-level de la app. La página pública de una
-- organización vive en `/[organizationSlug]` y comparte espacio de nombres
-- con las rutas fijas de `frontend/app/`. Una organización con slug
-- `equipo` o `activar` convertiría `/equipo/[token]` / `/activar/[token]`
-- (invitaciones de equipo, ADR-0034; activación de cliente gestionado,
-- ADR-0026) en rutas ambiguas y rompería cualquier invitación en vuelo;
-- con `login`, `me` o `dashboard` pasa lo mismo con el flujo de auth.
--
-- Por qué CHECK y no sólo dentro de create_organization_with_owner(): un
-- CHECK no se saltea con ningún camino de escritura futuro (un UPDATE de
-- slug que hoy no existe, un script de soporte, otra RPC), y es el mismo
-- criterio que la Fase 27: la validación que sólo vive en una función o en
-- Zod no es un límite. Constraint APARTE del de formato (no un `and` más
-- en el mismo) para que la RPC traduzca cada caso a su propio código:
-- INVALID_SLUG ("está mal escrito") vs SLUG_RESERVED ("está bien escrito,
-- pero no se puede usar") son respuestas distintas para quien completa el
-- formulario.
--
-- La lista es EXACTAMENTE el árbol de rutas top-level de `frontend/app/`
-- al 2026-09-24 (activar, admin, auth, contacto, dashboard, equipo, login,
-- me, onboarding, org, signup) + `api` (reservado por convención de Next
-- para route handlers) + `_next` (assets del framework; el regex de formato
-- ya lo rechaza por el guion bajo, se lista igual para que esta lista sea
-- la referencia completa). Espejo exacto de RESERVED_ORGANIZATION_SLUGS
-- (backend/src/schemas.ts). Regla de mantenimiento: una ruta top-level
-- nueva en `frontend/app/` = una migración que agrega el valor acá (y en
-- Zod) ANTES de publicar la ruta.
--
-- CHECK validado en el acto (no NOT VALID): si alguna organización
-- existente ya tuviera uno de estos slugs, la migración falla y hay que
-- resolverlo a mano -- es preferible a dejar una organización que captura
-- una ruta del producto en silencio.

alter table public.organizations
  add constraint organizations_slug_not_reserved_check
  check (
    slug not in (
      '_next',
      'activar',
      'admin',
      'api',
      'auth',
      'contacto',
      'dashboard',
      'equipo',
      'login',
      'me',
      'onboarding',
      'org',
      'signup'
    )
  );

comment on constraint organizations_slug_not_reserved_check on public.organizations is
  'Phase 27b: un slug no puede ser un segmento top-level de frontend/app/ (capturaría /equipo/[token], /activar/[token], /login, etc.). Espejo exacto de RESERVED_ORGANIZATION_SLUGS (backend/src/schemas.ts). Ruta top-level nueva = migración nueva que la agrega acá.';

-- create_organization_with_owner(): misma firma y mismo cuerpo que la
-- Fase 27; único cambio, traducir la violación del constraint nuevo a
-- SLUG_RESERVED en vez de dejar pasar el mensaje crudo de Postgres.
-- `create or replace` conserva los grants (Fase 10) y revokes (Fase 19).
create or replace function public.create_organization_with_owner(
  p_slug text,
  p_name text,
  p_timezone text,
  p_invite_code text
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.organization_invites;
  v_org public.organizations;
  v_email text;
  v_status public.subscription_status;
  v_trial_ends timestamptz;
  v_constraint_name text;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_invite
    from public.organization_invites
    where code = upper(trim(p_invite_code))
    for update;

  if not found then
    raise exception 'INVITE_NOT_FOUND';
  end if;

  if v_invite.redeemed_at is not null then
    raise exception 'INVITE_ALREADY_USED';
  end if;

  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    raise exception 'INVITE_EXPIRED';
  end if;

  if v_invite.email is not null then
    select email into v_email from auth.users where id = auth.uid();
    if lower(v_email) <> lower(v_invite.email) then
      raise exception 'INVITE_WRONG_EMAIL';
    end if;
  end if;

  if v_invite.trial_days is not null then
    v_status := 'TRIALING';
    v_trial_ends := now() + make_interval(days => v_invite.trial_days);
  else
    v_status := 'ACTIVE';
  end if;

  begin
    insert into public.organizations (
      slug, name, timezone, created_by, plan_code, subscription_status, trial_ends_at
    )
    values (p_slug, p_name, p_timezone, auth.uid(), v_invite.plan_code, v_status, v_trial_ends)
    returning * into v_org;
  exception
    when check_violation then
      get stacked diagnostics v_constraint_name = constraint_name;
      if v_constraint_name = 'organizations_slug_format_check' then
        raise exception 'INVALID_SLUG';
      end if;
      if v_constraint_name = 'organizations_slug_not_reserved_check' then
        raise exception 'SLUG_RESERVED';
      end if;
      raise;
  end;

  insert into public.organization_members (organization_id, profile_id, role, created_by)
  values (v_org.id, auth.uid(), 'OWNER', auth.uid());

  update public.organization_invites
    set redeemed_at = now(), redeemed_by = auth.uid(), redeemed_organization_id = v_org.id
    where code = v_invite.code;

  return v_org;
end;
$$;
