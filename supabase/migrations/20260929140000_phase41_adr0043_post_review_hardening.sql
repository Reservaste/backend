-- Fase 41: correccion post-review de seguridad de ADR-0043.
-- Ref: docs/decisions.md ADR-0043, seccion "Correccion post-review de
-- seguridad" -- hallazgo real de security-engineer, verificado en vivo:
-- sin confirmacion de email (enable_confirmations=false), habia tres
-- caminos reales para terminar con acceso de OWNER a un negocio ajeno.
-- Esta migracion cierra los caminos 1 y 2 de esa seccion. El camino 3
-- (usuarios viejos sin confirmar en el instante de apagar el toggle en
-- produccion) no es una migracion -- es una auditoria manual, documentada
-- en la ADR misma para copiar/pegar.
--
-- ============================================================
-- 1. Revocar el camino de invitacion/enrolamiento directo por email
-- ============================================================
-- invite_member_by_email() (Fase 32) le da membresia -- incluido rol
-- OWNER -- a quien tenga ese email registrado en auth.users, sin ninguna
-- prueba de que sea la persona real: "ocupar" el email de un futuro
-- dueno/empleado y esperar a que alguien lo invite alcanza para heredar
-- su rol. enroll_customer_by_email() tiene el mismo problema del lado de
-- Customer. Los dos reemplazos ya existen y no dependen de "el email
-- prueba identidad":
--   - invite_member_by_email()  -> invitacion de equipo por token
--     (ADR-0034, claim_team_invitation(), /equipo/[token]).
--   - enroll_customer_by_email() -> activacion de cliente gestionado por
--     link de WhatsApp (ADR-0026, issue_customer_activation() +
--     claim_customer_activation()).
--
-- No se borran (podrian tener consumidores legitimos via service_role que
-- convenga preservar) -- se revoca el EXECUTE. Investigado antes de
-- decidir el alcance del revoke (ver ADR-0043 para el detalle completo):
--   - Ningun caller de este repo (backend/test, backend/supabase,
--     frontend/app) invoca ninguna de las dos via el cliente service_role
--     (`admin.rpc(...)` en los tests, o un service_role equivalente en
--     frontend). Todos los callers -- tests y frontend/app/actions/
--     admin.ts (enrollCustomer(), inviteMember()) -- llaman con la sesion
--     del usuario autenticado (rol `authenticated`).
--   - enroll_customer_by_email() nunca tuvo un `grant ... to service_role`
--     explicito. invite_member_by_email() tampoco. Fase 19
--     (20260922160000_phase19_security_fixes.sql:526-527) ya le habia
--     revocado el `public`/`anon` heredado por el default de Supabase
--     ("Supabase's default privileges additionally grant it to
--     anon/authenticated/service_role" -- comentario de esa misma
--     migracion, linea 13), y el `create or replace`/`drop + create` de
--     ambas en Fase 32 no volvio a otorgarle nada a `service_role`.
--   - Conclusion: HOY, antes de esta migracion, `service_role` YA NO
--     puede ejecutar ninguna de las dos (perdio el grant heredado de
--     PUBLIC en Fase 19 y nunca tuvo uno propio). Revocarlo explicitamente
--     ahora es documentar ese estado, no cambiarlo -- y cierra la puerta a
--     que una migracion futura con `create or replace` le devuelva el
--     grant de PUBLIC por accidente (mismo riesgo que motivo el patron
--     "revoke explicito, no confiar en que nadie lo vuelva a otorgar" que
--     ya usa el resto del repo, p.ej. retry_not_generated_booking()).
--
-- IMPORTANTE, coordinar con frontend-engineer antes de desplegar: esta
-- migracion rompe frontend/app/actions/admin.ts::enrollCustomer() e
-- ::inviteMember() -- las dos hacen `supabase.rpc(...)` con la sesion del
-- usuario (rol `authenticated`), asi que pasan a recibir "permission
-- denied for function" (Postgres 42501) en vez del comportamiento actual.
-- La ADR ya preve este trabajo para frontend-engineer ("sacar/redirigir
-- la UI de invitacion directa por email"); no desplegar esta migracion
-- sin coordinar el orden con ese cambio de frontend.
revoke execute on function public.invite_member_by_email(
  uuid, text, public.organization_member_role, uuid
) from anon, authenticated, service_role;

revoke execute on function public.enroll_customer_by_email(uuid, text)
  from anon, authenticated, service_role;

comment on function public.invite_member_by_email(uuid, text, public.organization_member_role, uuid) is
  'ADR-0043 (correccion post-review): EXECUTE revocado de anon/authenticated/service_role -- daba rol OWNER a quien ocupara un email en auth.users sin probar identidad. Reemplazo: invitacion de equipo por token (ADR-0034, claim_team_invitation()). No se borra por si un consumidor interno legitimo la necesitara reinstaurar a proposito -- ninguno existia al momento de este revoke (ver comentario de la migracion 20260929140000).';

comment on function public.enroll_customer_by_email(uuid, text) is
  'ADR-0043 (correccion post-review): EXECUTE revocado de anon/authenticated/service_role -- vinculaba como Customer a quien ocupara un email en auth.users sin probar identidad. Reemplazo: activacion de cliente gestionado por link de WhatsApp (ADR-0026, issue_customer_activation()/claim_customer_activation()). No se borra por si un consumidor interno legitimo la necesitara reinstaurar a proposito -- ninguno existia al momento de este revoke (ver comentario de la migracion 20260929140000).';

-- ============================================================
-- 2. Trigger sobre auth.identities contra el secuestro via Google OAuth
-- ============================================================
-- El problema (verificado en vivo por security-engineer): GoTrue solo
-- purga identidades no confirmadas al vincular una identidad OAuth nueva
-- a un email ya registrado cuando la identidad existente esta SIN
-- confirmar. Con enable_confirmations=false (ADR-0043) toda cuenta por
-- contraseña queda confirmada al instante de crearse, asi que esa purga
-- nunca se dispara -- GoTrue en cambio hace su comportamiento normal de
-- "vincular por email ya verificado": ata la identidad Google nueva al
-- MISMO user_id que ya tenia la contraseña. Si esa cuenta la creo un
-- atacante ocupando el Gmail de una futura dueña, la dueña real termina
-- autenticada -- via "Continuar con Google" -- dentro de la cuenta del
-- atacante, que sigue pudiendo entrar con su contraseña.
--
-- Por que alcanza con bloquear TODO insert de una identidad no-email
-- sobre un user_id que ya tiene una identidad de email/contraseña, sin
-- distinguir "signup publico" de "invitacion/activacion administrada":
-- este proyecto tiene enable_manual_linking=false (supabase/config.toml,
-- [auth] -- production debe tener el equivalente apagado en el
-- dashboard). Sin manual linking, NO EXISTE ningun flujo soportado por el
-- que una persona ya autenticada por contraseña pueda agregar Google a su
-- propia cuenta de forma deliberada -- la unica manera en que GoTrue
-- inserta una identidad no-email para un user_id que ya tiene una de
-- password es el camino automatico de "vincular por email verificado"
-- durante un signInWithOAuth() SIN sesion previa, que es exactamente el
-- camino vulnerable. No hace falta (ni séria confiable) distinguir el
-- origen de la cuenta -- publica o administrada -- porque ninguna de las
-- dos prueba posesion de email al crearse, y con manual linking apagado
-- cualquier insert de este tipo, venga de la cuenta que venga, es por
-- definicion ese camino automatico.
--
-- Efecto: se bloquea el INSERT (no se intenta borrar la identidad vieja
-- ni tocar auth.users) -- la persona real recibe un error al hacer
-- "Continuar con Google" por primera vez con un email ya ocupado, en vez
-- de quedar autenticada en silencio dentro de la cuenta ajena. Es un
-- fail-closed deliberado: mas seguro que replicar exactamente el
-- comportamiento viejo de GoTrue (purgar y dejar crear una cuenta nueva),
-- que exigiria mutar auth.users/auth.identities a mano en medio de la
-- propia transaccion de GoTrue -- mas riesgo sobre un schema gestionado
-- por Supabase para un beneficio de UX, no de seguridad. El soporte
-- resuelve a mano via la auditoria de la seccion 3 de esta misma ADR.
--
-- Seguro triggerear sobre auth.identities: mismo patron ya usado en este
-- repo desde la Fase 1 (public.handle_new_user(), `after insert on
-- auth.users`) -- ambas tablas viven en el mismo schema `auth` gestionado
-- por Supabase, con el mismo dueño (supabase_auth_admin) y el mismo rol
-- de migracion (postgres) con privilegio suficiente para crear triggers
-- ahi. Confirmado en vivo contra Supabase local (CLI 2.118.0): un trigger
-- de prueba sobre auth.identities se creo y disparo sin error.
create or replace function public.check_identity_link_not_oauth_hijack()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.provider <> 'email' and exists (
    select 1 from auth.identities
    where user_id = new.user_id and provider = 'email'
  ) then
    raise exception 'OAUTH_LINK_BLOCKED_EXISTING_PASSWORD_IDENTITY'
      using errcode = 'P0001',
            detail = 'ADR-0043: se bloquea vincular una identidad no-email a una cuenta que ya tiene una identidad de contraseña -- con enable_manual_linking=false este insert solo puede venir del camino automatico de OAuth que GoTrue usa para "vincular por email ya verificado", el mismo que permite el secuestro de cuenta documentado en la correccion post-review de ADR-0043.';
  end if;
  return new;
end;
$$;

comment on function public.check_identity_link_not_oauth_hijack() is
  'ADR-0043 (correccion post-review, camino 2): replica a mano la proteccion que GoTrue perdio al desactivar enable_confirmations -- bloquea vincular una identidad OAuth (Google) a una cuenta que ya tiene contraseña, porque con enable_manual_linking=false ese insert solo puede originarse en el camino automatico y vulnerable de "vincular por email ya verificado" durante un signInWithOAuth() sin sesion previa.';

-- Sin `comment on trigger ... on auth.identities`: COMMENT ON TRIGGER
-- exige ser dueño de la relacion (`must be owner of relation identities`,
-- confirmado en vivo), y el rol de migracion (postgres) puede crear el
-- trigger pero no es dueño de la tabla (la dueña es supabase_auth_admin).
-- La documentacion vive en el comentario de la funcion de arriba.
create trigger auth_identities_block_oauth_hijack
  before insert on auth.identities
  for each row execute function public.check_identity_link_not_oauth_hijack();

notify pgrst, 'reload schema';
