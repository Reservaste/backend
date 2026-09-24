-- ============================================================
-- Fase 33 -- Alta de equipo sin registro previo (ADR-0034)
-- ============================================================
-- Propuesta completa: docs/proposals/adr-0034-team-invitations.md
-- Resoluciones del Orchestrator: docs/decisions.md ADR-0034.
--
-- El problema: invite_member_by_email() exige que la persona ya exista en
-- auth.users (`if v_profile_id is null then raise PROFILE_NOT_FOUND`), así
-- que el dueño no puede dar de alta a un profesor -- tiene que pedirle que
-- se registre primero, esperar, y recién ahí invitarlo con el email exacto
-- con el que se registró. Esta migración agrega el camino que no lo exige:
-- una invitación con link de un solo uso, 24 h de vida, vinculada al email.
--
-- Mecanismo SEPARADO de customer_activations (ADR-0034, decisión 1): el
-- destino del token no existe todavía como fila (la fila de
-- organization_members nace en el canje), lo que otorga es acceso a datos
-- de TERCEROS y no "sos vos mismo", y la unicidad de "un link vivo" es por
-- (organización, email) y no por fila. Lo único que se comparte es el
-- acuñado del token, extraído acá a new_activation_token() y adoptado
-- también por issue_customer_activation() (sección 1): es la parte que no
-- debe divergir entre los dos flujos.
--
-- Depende de la Fase 32 (ADR-0033): team_invitations nace con role_id, no
-- lo agrega una segunda migración sobre una tabla con tokens vivos.

-- ============================================================
-- 1. new_activation_token() -- el acuñado, una sola definición
-- ============================================================
-- Las cuatro decisiones de ADR-0026 sobre el token, en un solo lugar:
-- 256 bits de extensions.gen_random_bytes (CSPRNG real, no random()),
-- base64url sin padding para que entre en un path segment sin re-encodear,
-- sha256 en reposo, y todo schema-calificado para no depender del
-- search_path (la advertencia explícita de ADR-0026 sobre el precedente de
-- create_organization_invite(), phase10:427).
--
-- Sin grants a nadie -- ni authenticated, ni service_role. Es un helper
-- interno: la única forma de llegar a él es desde las funciones
-- `security definer` de abajo, que corren como su dueño. Mismo patrón (y
-- mismo motivo) que el revoke de customer_billing_horizon() en la Fase 32.
create or replace function public.new_activation_token()
returns table (token text, token_hash bytea)
language sql
volatile
set search_path = public
as $BODY$
  select s.t, extensions.digest(s.t, 'sha256')
  from (
    select translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_') as t
  ) s;
$BODY$;

comment on function public.new_activation_token() is
  'ADR-0034 Sec 2.4: el acuñado de token compartido entre customer_activations (ADR-0026) y team_invitations. 256 bits de CSPRNG, base64url sin padding, sha256 en reposo. Sin EXECUTE para nadie: sólo lo alcanzan las RPCs security definer.';

revoke execute on function public.new_activation_token()
  from public, anon, authenticated, service_role;

-- issue_customer_activation() pasa a usar el helper. El cuerpo es idéntico
-- al de la Fase 32 (que es la definición vigente: la Fase 21 la creó y la
-- Fase 32 le cambió el gate de is_organization_member() a
-- has_org_permission(..., 'MANAGE_CUSTOMERS')) salvo las dos líneas del
-- acuñado: el punto de extraer el helper era justamente que esas dos líneas
-- no existan dos veces y puedan divergir (ADR-0034 Sec 2.4).
create or replace function public.issue_customer_activation(
  p_customer_id uuid
)
returns table (activation_id uuid, token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer public.customers;
  v_org public.organizations;
  v_token text;
  v_hash bytea;
  v_expires timestamptz;
  v_count int;
  v_activation_id uuid;
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_customer.organization_id, 'MANAGE_CUSTOMERS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_org from public.organizations where id = v_customer.organization_id;

  if not v_org.customer_activation_enabled then
    raise exception 'ACTIVATION_DISABLED';
  end if;

  if not v_customer.is_active then
    raise exception 'CUSTOMER_INACTIVE';
  end if;

  if v_customer.profile_id is not null then
    raise exception 'ALREADY_ACTIVATED';
  end if;

  if v_customer.phone is null then
    raise exception 'CUSTOMER_HAS_NO_PHONE';
  end if;

  select count(*) into v_count
    from public.customer_activations
    where organization_id = v_customer.organization_id
      and created_at > now() - interval '1 hour';
  if v_count >= 30 then
    raise exception 'RATE_LIMITED_HOURLY';
  end if;

  select count(*) into v_count
    from public.customer_activations
    where organization_id = v_customer.organization_id
      and created_at > now() - interval '1 day';
  if v_count >= 200 then
    raise exception 'RATE_LIMITED_DAILY';
  end if;

  update public.customer_activations
    set revoked_at = now(), revoked_by = auth.uid()
    where customer_id = p_customer_id
      and redeemed_at is null
      and revoked_at is null;

  select t.token, t.token_hash into v_token, v_hash from public.new_activation_token() t;
  v_expires := now() + interval '72 hours';

  insert into public.customer_activations (
    organization_id, customer_id, token_hash, phone, expires_at, created_by
  ) values (
    v_customer.organization_id, p_customer_id, v_hash, v_customer.phone, v_expires, auth.uid()
  )
  returning id into v_activation_id;

  return query select v_activation_id, v_token, v_expires;
end;
$BODY$;

-- ============================================================
-- 2. team_invitations
-- ============================================================
-- Una invitación pendiente NO es un miembro: no hay fila en
-- organization_members hasta el canje (ADR-0034, alternativa descartada
-- "crear la fila inactiva al invitar"). Modelarla como miembro sería
-- mentirle al padrón y contar max_team_members sobre gente que no entró.

create table public.team_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,

  -- El vínculo real. El canal de envío es WhatsApp (phone), pero lo que
  -- el canje exige es la casilla: eso convierte un secreto de un factor en
  -- uno de dos y mitiga el caso de falla más probable (el número mal
  -- tipeado). Normalizado a lower(btrim(...)) por el CHECK de abajo, no
  -- por confianza en el llamador.
  email text not null,
  -- Sólo canal de envío, E.164. Se guarda (ADR-0034 resolución 4) para
  -- poder reenviar sin volver a tipearlo y para tener registro de a dónde
  -- se mandó el link, que es justo el dato que hace falta cuando alguien
  -- dice "no me llegó".
  phone text,
  -- El nombre con el que el dueño dio de alta a la persona, para que la
  -- lista de pendientes diga "Juan Pérez -- invitado el 12/03" y no un
  -- email pelado. No es identidad: la identidad la trae la sesión al
  -- canjear.
  display_name text,

  -- ADR-0034 resolución 5: una invitación NUNCA puede crear un OWNER, y es
  -- un CHECK y no una convención que la RPC deba recordar. La columna
  -- existe (en vez de asumir 'STAFF') para que el día que el enum crezca,
  -- el CHECK siga siendo la frontera explícita y no haya que redescubrirla.
  role public.organization_member_role not null default 'STAFF',
  -- ADR-0033/ADR-0034 resolución 7: el rol lo elige quien invita, al
  -- invitar. Nullable = el rol is_default de la organización, exactamente
  -- igual que organization_members.role_id.
  role_id uuid references public.organization_roles (id),

  -- sha256(token), nunca el token. El claro existe una sola vez, en el
  -- valor de retorno de issue_team_invitation().
  token_hash bytea not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles (id),
  redeemed_at timestamptz,
  redeemed_profile_id uuid references public.profiles (id),
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id),

  constraint team_invitations_never_owner check (role = 'STAFF'),
  constraint team_invitations_email_lower check (email = lower(btrim(email))),
  constraint team_invitations_email_shape
    check (email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'),
  constraint team_invitations_phone_e164
    check (phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'),
  -- "Canjeada" y "canjeada por alguien" son el mismo hecho. Sin esto
  -- podría existir una fila redeemed_at not null con redeemed_profile_id
  -- null, que es justo el estado que haría ambigua la idempotencia del
  -- doble click en claim_team_invitation().
  constraint team_invitations_redeemed_shape
    check ((redeemed_at is null) = (redeemed_profile_id is null))
);

comment on table public.team_invitations is
  'ADR-0034: invitación de equipo con link de un solo uso y 24 h de vida, para dar de alta a alguien que todavía no tiene cuenta. token_hash es sha256 de 256 bits de CSPRNG; el token claro existe sólo en el retorno de issue_team_invitation(). El canje exige que el email de la sesión coincida (resolución 3) y nunca puede crear un OWNER (resolución 5, CHECK team_invitations_never_owner).';

comment on column public.team_invitations.role_id is
  'ADR-0034 resolución 7: el rol con el que la persona entra, elegido al invitar. Null = el rol is_default de la organización, igual que organization_members.role_id. El canje falla cerrado si el rol fue desactivado entre la emisión y el click (INVITATION_ROLE_UNAVAILABLE): no se cae al default ni se adivina.';

-- Un solo link vivo por (organización, email). Reenviar revoca el anterior
-- adentro de la RPC (igual que ADR-0026): un link viejo es justo el que
-- pudo haber ido al lugar equivocado, no algo que deba seguir sirviendo al
-- lado del nuevo.
create unique index team_invitations_one_live_idx
  on public.team_invitations (organization_id, email)
  where redeemed_at is null and revoked_at is null;

-- Respalda el rate limit de emisión (dos count(*) por hora/día) y el read
-- model ordenado por fecha.
create index team_invitations_org_created_idx
  on public.team_invitations (organization_id, created_at);

create index team_invitations_role_idx
  on public.team_invitations (role_id);

-- Un rol de OTRA organización no es un rol de esta invitación. La FK sola
-- no lo impide (apunta a organization_roles, no a "los roles de esta
-- organización") y el resultado sería un cross-tenant de autorización
-- acuñado en un token. Mismo precedente que check_member_role_same_org()
-- de la Fase 32.
create or replace function public.check_team_invitation_role_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if new.role_id is not null and not exists (
    select 1 from public.organization_roles r
    where r.id = new.role_id and r.organization_id = new.organization_id
  ) then
    raise exception 'ROLE_OTHER_ORGANIZATION';
  end if;
  return new;
end;
$BODY$;

create trigger team_invitations_role_same_org
  before insert or update on public.team_invitations
  for each row execute function public.check_team_invitation_role_same_org();

alter table public.team_invitations enable row level security;

-- Sin una sola policy y sin grants a anon/authenticated, igual que
-- customer_activations (phase21:163-172). RLS con cero policies deniega
-- toda fila a anon/authenticated sin importar los grants, y grants no hay:
-- la única puerta desde una request de PostgREST son las RPCs
-- `security definer` de abajo, que leen/escriben como dueñas de la función
-- y bypassean RLS. Esta tabla tiene emails y teléfonos de gente que
-- todavía no aceptó nada; un `grant select` acá sería un padrón de
-- contactos expuesto a cualquier miembro.
revoke all on public.team_invitations from anon, authenticated;

-- ============================================================
-- 3. assert_team_seat_available() -- el cupo de plan, en un solo lugar
-- ============================================================
-- ADR-0034 riesgo 7 / resolución del Orchestrator 9: enforce_plan_limit()
-- es un `before insert on organization_members` (phase10:243), y con este
-- flujo el INSERT ocurre en el CANJE. Sin un chequeo en la emisión, un
-- OWNER con un lugar libre emite cinco invitaciones y cuatro personas se
-- comen PLAN_LIMIT_REACHED al hacer click en un link que ya tenían -- un
-- error incomprensible para quien lo recibe, y del lado equivocado del
-- mostrador.
--
-- El trigger sigue siendo LA REGLA; esto es el mensaje de error temprano,
-- el mismo reparto que el proyecto ya usa (la base manda, el borde
-- explica). Por eso la excepción tiene exactamente la forma que levanta
-- enforce_plan_limit(): si el frontend aprendió a leer una, lee las dos.
--
-- `p_include_live_invitations`:
--   true  -> emisión: miembros activos + invitaciones vivas.
--   false -> reactivación de un miembro dado de baja en el canje, que es un
--            UPDATE y por lo tanto NO pasa por el trigger (INSERT only).
--            Sin este chequeo, un link viejo reabriría una plaza que el
--            plan ya no tiene.
create or replace function public.assert_team_seat_available(
  p_organization_id uuid,
  p_include_live_invitations boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_limit int;
  v_count int;
begin
  select p.max_team_members into v_limit
    from public.organizations o
    join public.plans p on p.code = o.plan_code
    where o.id = p_organization_id;

  -- Sin plan resoluble o sin tope: no hay nada que exigir. Misma salida
  -- que el `if not found then return new` de enforce_plan_limit().
  if v_limit is null then
    return;
  end if;

  select count(*) into v_count
    from public.organization_members
    where organization_id = p_organization_id and is_active;

  if p_include_live_invitations then
    v_count := v_count + (
      select count(*)
        from public.team_invitations
        where organization_id = p_organization_id
          and redeemed_at is null
          and revoked_at is null
          and expires_at > now()
    );
  end if;

  if v_count >= v_limit then
    raise exception 'PLAN_LIMIT_REACHED: personas en el equipo (%/%)', v_count, v_limit;
  end if;
end;
$BODY$;

comment on function public.assert_team_seat_available(uuid, boolean) is
  'ADR-0034 resolución 9: el cupo de max_team_members chequeado también al EMITIR una invitación (contando invitaciones vivas), no sólo en el INSERT del canje. La regla sigue siendo el trigger enforce_plan_limit(); esto es el error temprano, con la misma forma de mensaje.';

revoke execute on function public.assert_team_seat_available(uuid, boolean)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 4. issue_team_invitation() -- OWNER, emitir / reenviar
-- ============================================================
-- OWNER y no STAFF, asimetría deliberada con ADR-0026 (donde un STAFF
-- emite activaciones de cliente): allá el link otorga "ser vos mismo",
-- acá otorga acceso a los datos de todos. El argumento de ADR-0026
-- resolución 2 para gatear a STAFF ("gatearlo a OWNER forzaría a compartir
-- su cuenta") no aplica al alta de personal, que es ocasional y del dueño.
--
-- No consulta auth.users en NINGÚN momento, a propósito (ADR-0034 Sec
-- 5.6): invite_member_by_email() levanta PROFILE_NOT_FOUND y con eso
-- convierte al panel en un oráculo de "¿tal email tiene cuenta en la
-- plataforma?". Este camino no responde esa pregunta, ni siquiera para
-- decir "ya es miembro" -- si la persona ya es miembro, el canje devuelve
-- OK sin tocarle nada (sección 7, paso 9).
create or replace function public.issue_team_invitation(
  p_organization_id uuid,
  p_email text,
  p_display_name text default null,
  p_phone text default null,
  p_role_id uuid default null
)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_email text;
  v_phone text;
  v_name text;
  v_token text;
  v_hash bytea;
  v_expires timestamptz;
  v_count int;
  v_invitation_id uuid;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Una organización suspendida no suma gente. Mismo veredicto que
  -- levantaría el trigger en el canje, dicho acá en vez de dentro de tres
  -- semanas cuando alguien haga click.
  if not public.organization_can_operate(p_organization_id) then
    raise exception 'SUBSCRIPTION_INACTIVE';
  end if;

  v_email := lower(btrim(coalesce(p_email, '')));
  if v_email = '' then
    raise exception 'EMAIL_REQUIRED';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'INVALID_EMAIL';
  end if;

  v_name := nullif(btrim(coalesce(p_display_name, '')), '');

  -- Misma normalización que create_managed_customer() (phase21:247): el
  -- CHECK es la defensa real, esto es un mejor mensaje de error que una
  -- violación de constraint cruda.
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  -- Una diferencia deliberada con create_managed_customer(), que ante
  -- "no-es-un-telefono" deja el campo en null sin decir nada: acá el
  -- teléfono ES el canal por el que va a viajar el link, así que dejarlo en
  -- null en silencio haría que el dueño crea que ya mandó el WhatsApp.
  if v_phone is null and nullif(btrim(coalesce(p_phone, '')), '') is not null then
    raise exception 'INVALID_PHONE';
  end if;
  if v_phone is not null then
    if left(v_phone, 1) <> '+' then
      v_phone := '+' || v_phone;
    end if;
    if v_phone !~ '^\+[1-9][0-9]{6,14}$' then
      raise exception 'INVALID_PHONE';
    end if;
  end if;

  -- Un rol inactivo no se invita: la invitación describe completa su
  -- consecuencia o no sirve para nada.
  if p_role_id is not null and not exists (
    select 1 from public.organization_roles r
    where r.id = p_role_id
      and r.organization_id = p_organization_id
      and r.is_active
  ) then
    raise exception 'ROLE_NOT_FOUND';
  end if;

  -- Rate limit adentro de la RPC, sin infraestructura nueva (mismo
  -- criterio que ADR-0026 resolución 4). 10/h y 30/día: un equipo son
  -- 2-20 personas, no 200 clientes, así que los números de
  -- issue_customer_activation() (30/h, 200/día) están dimensionados para
  -- otra cosa. La fuerza bruta del CANJE sigue siendo riesgo residual
  -- aceptado -- 256 bits lo vuelven computacionalmente irrelevante y el
  -- rate limiting general es deuda de ADR-0008.
  select count(*) into v_count
    from public.team_invitations
    where organization_id = p_organization_id
      and created_at > now() - interval '1 hour';
  if v_count >= 10 then
    raise exception 'RATE_LIMITED_HOURLY';
  end if;

  select count(*) into v_count
    from public.team_invitations
    where organization_id = p_organization_id
      and created_at > now() - interval '1 day';
  if v_count >= 30 then
    raise exception 'RATE_LIMITED_DAILY';
  end if;

  -- Reenviar revoca lo que estuviera vivo para ese email. Va ANTES del
  -- chequeo de cupo a propósito: un reenvío a la misma persona no puede
  -- contar dos plazas. El índice parcial único rechazaría el insert de
  -- todos modos.
  update public.team_invitations
    set revoked_at = now(), revoked_by = auth.uid()
    where organization_id = p_organization_id
      and email = v_email
      and redeemed_at is null
      and revoked_at is null;

  perform public.assert_team_seat_available(p_organization_id, true);

  select t.token, t.token_hash into v_token, v_hash from public.new_activation_token() t;
  -- 24 h (ADR-0034 resolución 3, el pedido textual del usuario). No 72 h
  -- como los clientes: un alta de personal se coordina en tiempo real con
  -- alguien con quien estás hablando, y la consecuencia si el link cae en
  -- la casilla equivocada es mayor.
  v_expires := now() + interval '24 hours';

  insert into public.team_invitations (
    organization_id, email, phone, display_name, role, role_id,
    token_hash, expires_at, created_by
  ) values (
    p_organization_id, v_email, v_phone, v_name, 'STAFF', p_role_id,
    v_hash, v_expires, auth.uid()
  )
  returning id into v_invitation_id;

  return query select v_invitation_id, v_token, v_expires;
end;
$BODY$;

comment on function public.issue_team_invitation(uuid, text, text, text, uuid) is
  'ADR-0034: devuelve el token claro exactamente una vez. Perderlo antes de mandar el WhatsApp obliga a reemitir (lo que revoca el anterior), no a recuperarlo -- token_hash no se invierte. No consulta auth.users, así que no es un oráculo de "¿este email tiene cuenta?" (ADR-0034 Sec 5.6).';

revoke execute on function public.issue_team_invitation(uuid, text, text, text, uuid)
  from public, anon;
grant execute on function public.issue_team_invitation(uuid, text, text, text, uuid)
  to authenticated;

-- ============================================================
-- 5. revoke_team_invitation() -- OWNER, idempotente
-- ============================================================
create or replace function public.revoke_team_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_inv public.team_invitations;
begin
  select * into v_inv from public.team_invitations where id = p_invitation_id;
  if not found then
    -- Ni "no existe" ni "no sos dueño": una invitación de otra
    -- organización y una inexistente se ven igual desde afuera.
    return;
  end if;

  if not public.is_organization_owner(v_inv.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_inv.redeemed_at is not null or v_inv.revoked_at is not null then
    return;
  end if;

  update public.team_invitations
    set revoked_at = now(), revoked_by = auth.uid()
    where id = p_invitation_id;
end;
$BODY$;

revoke execute on function public.revoke_team_invitation(uuid) from public, anon;
grant execute on function public.revoke_team_invitation(uuid) to authenticated;

-- ============================================================
-- 6. organization_team_invitations() -- el read model que faltaba
-- ============================================================
-- ADR-0034 riesgo 8: organization_team() hace `join public.profiles p on
-- p.id = om.profile_id` (phase8:431) y una invitación pendiente ni
-- siquiera tiene fila de miembro, así que hoy el dueño no tiene forma de
-- ver a quién invitó, ni de reenviar, ni de revocar. Es el eco exacto del
-- hallazgo B de ADR-0026, y por eso esto entra en el alcance y no en
-- "después".
--
-- Gate: OWNER, más estricto que el "miembro" que sugería la propuesta
-- (§4.2). Motivo: cada fila es el email y el teléfono de alguien que
-- todavía no aceptó nada, la emisión y la revocación ya son OWNER-only, y
-- la pantalla que lo muestra también. Devuelve vacío para un no-OWNER en
-- vez de levantar excepción, igual que customer_activation_status(): una
-- lista sin filas es algo que la UI ya sabe dibujar.
--
-- NUNCA devuelve token_hash. El token claro no se puede recuperar; para
-- volver a mandarlo hay que reemitir.
create or replace function public.organization_team_invitations(
  p_organization_id uuid,
  p_include_history boolean default false
)
returns table (
  invitation_id uuid,
  email text,
  display_name text,
  phone text,
  role_id uuid,
  role_name text,
  status text,
  created_at timestamptz,
  expires_at timestamptz,
  redeemed_at timestamptz,
  redeemed_profile_id uuid,
  revoked_at timestamptz,
  created_by uuid
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    ti.id,
    ti.email,
    ti.display_name,
    ti.phone,
    ti.role_id,
    -- El rol EFECTIVO que le va a tocar: el elegido, o el por defecto de
    -- la organización si se invitó sin elegir. Igual que organization_team().
    r.name,
    case
      when ti.redeemed_at is not null then 'REDEEMED'
      when ti.revoked_at is not null then 'REVOKED'
      when ti.expires_at <= now() then 'EXPIRED'
      else 'PENDING'
    end,
    ti.created_at,
    ti.expires_at,
    ti.redeemed_at,
    ti.redeemed_profile_id,
    ti.revoked_at,
    ti.created_by
  from public.team_invitations ti
  left join public.organization_roles r
    on r.id = coalesce(
         ti.role_id,
         (select d.id from public.organization_roles d
           where d.organization_id = ti.organization_id and d.is_default limit 1)
       )
  where ti.organization_id = p_organization_id
    and public.is_organization_owner(p_organization_id)
    and (
      p_include_history
      or (ti.redeemed_at is null and ti.revoked_at is null)
    )
  order by ti.created_at desc;
$BODY$;

comment on function public.organization_team_invitations(uuid, boolean) is
  'ADR-0034 resolución 10: lo que el dueño necesita para ver a quién invitó, reenviar y revocar. OWNER-only (más estricto que la propuesta: son emails y teléfonos de gente que no aceptó nada). Nunca devuelve token_hash. Con p_include_history = false muestra sólo lo no canjeado/no revocado -- incluidas las vencidas, que son justo las que hay que reenviar.';

revoke execute on function public.organization_team_invitations(uuid, boolean) from public, anon;
grant execute on function public.organization_team_invitations(uuid, boolean) to authenticated;

-- ============================================================
-- 7. claim_team_invitation() -- el canje, authenticated
-- ============================================================
-- ADR-0005 aplicado literalmente, igual que claim_customer_activation():
-- UN solo parámetro, el token. No nombra ninguna organización ni ninguna
-- fila de miembro. El destino sale entero del token; la identidad, entera
-- de auth.uid(). No hay superficie de IDOR porque no hay input que apunte
-- a una fila.
create or replace function public.claim_team_invitation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_inv public.team_invitations;
  v_org public.organizations;
  v_email text;
  v_role public.organization_roles;
  v_member public.organization_members;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_token is null or length(btrim(p_token)) = 0 then
    raise exception 'INVALID_TOKEN';
  end if;

  select * into v_inv
    from public.team_invitations
    where token_hash = extensions.digest(btrim(p_token), 'sha256')
    for update;

  if not found then
    raise exception 'INVALID_TOKEN';
  end if;

  if v_inv.revoked_at is not null then
    raise exception 'INVITATION_REVOKED';
  end if;

  select * into v_org from public.organizations where id = v_inv.organization_id;

  -- Idempotencia del doble click: el mismo profile que ya canjeó recibe OK
  -- otra vez; otro profile recibe ALREADY_REDEEMED y no se toca nada.
  if v_inv.redeemed_at is not null then
    if v_inv.redeemed_profile_id = auth.uid() then
      return jsonb_build_object(
        'status', 'OK',
        'organization_slug', v_org.slug,
        'organization_name', v_org.name
      );
    end if;
    raise exception 'ALREADY_REDEEMED';
  end if;

  if v_inv.expires_at <= now() then
    raise exception 'INVITATION_EXPIRED';
  end if;

  -- ADR-0034 resolución 3, sin excepción. Precedente exacto:
  -- create_organization_with_owner() ya hace esta comparación
  -- (phase10:319-323). El canal es WhatsApp; el vínculo es el email. Si la
  -- persona se registró con otro (típico con Google), el canje falla con
  -- un error claro y el OWNER reemite al email correcto: fricción visible
  -- y arreglable, no un acceso silencioso al tenant equivocado.
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null or lower(btrim(v_email)) <> v_inv.email then
    raise exception 'INVITE_WRONG_EMAIL';
  end if;

  if v_org.id is null or not v_org.is_active
     or not public.organization_can_operate(v_inv.organization_id) then
    raise exception 'ORGANIZATION_UNAVAILABLE';
  end if;

  -- Falla cerrado si el rol fue desactivado entre la emisión y el click:
  -- no se cae al rol por defecto ni se adivina. Un rol desactivado suele
  -- ser una decisión de seguridad reciente; entrar "con otra cosa" sería
  -- justamente lo que esa decisión quería evitar.
  if v_inv.role_id is not null then
    select * into v_role from public.organization_roles
      where id = v_inv.role_id and organization_id = v_inv.organization_id;
    if not found or not v_role.is_active then
      raise exception 'INVITATION_ROLE_UNAVAILABLE';
    end if;
  end if;

  select * into v_member from public.organization_members
    where organization_id = v_inv.organization_id and profile_id = auth.uid();

  if found then
    -- ADR-0034 riesgo 3 / resolución 8: el canje NUNCA le pisa el rol a un
    -- miembro que ya existe. invite_member_by_email() sí lo hace
    -- (phase8:141-145 / phase32:749-753) y ahí es correcto -- es
    -- sincrónico y OWNER-gated. Acá sería un camino de escalada: un STAFF
    -- que consigue una invitación a un rol mayor, o peor, un link que
    -- DEGRADA a alguien que ya trabaja.
    if not v_member.is_active then
      -- Reactivar es un UPDATE, y enforce_plan_limit() es INSERT-only, así
      -- que el cupo hay que exigirlo acá o un link viejo reabriría una
      -- plaza que el plan ya no tiene.
      perform public.assert_team_seat_available(v_inv.organization_id, false);

      update public.organization_members
        set is_active = true,
            cancelled_at = null,
            cancelled_by = null,
            cancellation_reason = null
        where id = v_member.id
        returning * into v_member;
    end if;
  else
    -- created_by = quien invitó, no quien hizo click: el alta la decidió
    -- el dueño. El trigger enforce_plan_limit() corre acá y es LA regla
    -- (PLAN_LIMIT_REACHED / SUBSCRIPTION_INACTIVE); el chequeo de la
    -- emisión sólo adelanta el mensaje.
    insert into public.organization_members (
      organization_id, profile_id, role, role_id, created_by
    ) values (
      v_inv.organization_id, auth.uid(), 'STAFF', v_inv.role_id, v_inv.created_by
    )
    returning * into v_member;
  end if;

  -- `and redeemed_at is null` sobre el `for update` de arriba: dos canjes
  -- concurrentes del mismo token tienen exactamente un ganador incluso si
  -- el lock de fila no los hubiera serializado.
  update public.team_invitations
    set redeemed_at = now(), redeemed_profile_id = auth.uid()
    where id = v_inv.id
      and redeemed_at is null;

  if not found then
    raise exception 'ALREADY_REDEEMED';
  end if;

  return jsonb_build_object(
    'status', 'OK',
    'organization_slug', v_org.slug,
    'organization_name', v_org.name,
    'member_id', v_member.id
  );
end;
$BODY$;

comment on function public.claim_team_invitation(text) is
  'ADR-0034 Sec 4.3. Nunca anon: vincular auth.uid() a una organización exige que exista una sesión. Un solo parámetro (ADR-0005), así que no hay forma de apuntar el canje a otra fila. Exige coincidencia de email (INVITE_WRONG_EMAIL) y nunca cambia el rol de un miembro que ya existe.';

revoke execute on function public.claim_team_invitation(text) from public, anon;
grant execute on function public.claim_team_invitation(text) to authenticated;

-- ============================================================
-- Verificación manual (lo automatizado vive en
-- test/phase33.team-invitations.test.ts):
--
--   -- La tabla no se lee por PostgREST directo, ni como OWNER:
--   GET /rest/v1/team_invitations  -> 0 filas / permission denied.
--
--   -- El OWNER no puede fabricar un OWNER ni por insert directo (no tiene
--   -- grant) ni por la RPC (no hay parámetro de rol enum), y el CHECK
--   -- team_invitations_never_owner cierra incluso el camino de
--   -- service_role.
-- ============================================================
