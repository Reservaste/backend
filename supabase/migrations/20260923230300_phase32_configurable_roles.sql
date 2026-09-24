-- Fase 30: roles configurables por organización (ADR-0033)
-- Propuesta completa: docs/proposals/adr-0033-roles-configurables.md
-- Resoluciones del Orchestrator: docs/decisions.md ADR-0033.
--
-- `OWNER` sigue siendo enum fijo (raíz de confianza, §3 de la propuesta):
-- nunca se evalúa contra un permiso, corta antes. Lo nuevo es una capa de
-- roles configurables DENTRO de `STAFF`:
--
--   OWNER                   -> todo, sin mirar role_id
--   STAFF con role_id       -> ese rol
--   STAFF con role_id null  -> el rol is_default de la organización
--
-- ORDEN DE ESTA MIGRACIÓN (importa, ADR-0033 §6): primero la tabla, el
-- trigger de siembra y el backfill; después el helper que resuelve
-- permisos; recién al final el endurecimiento de policies y RPCs. Al revés
-- hay una ventana dentro de la transacción en la que has_org_permission()
-- devuelve false para todos porque todavía no existe el rol por defecto.
--
-- Los cinco booleanos nacen en `true` y el backfill le da a cada
-- organización un rol "Equipo" por defecto: el día del deploy todo `STAFF`
-- existente puede exactamente lo mismo que podía ayer, bit a bit.
-- Restringir es una acción deliberada y posterior del `OWNER`.

-- ============================================================
-- 1. El enum de permisos
-- ============================================================
-- Enum y no `text` a propósito: un typo en una policy ('VIEW_PAYMENT')
-- falla en la migración con `invalid input value for enum`, no en
-- producción con un permiso que silenciosamente deniega.
--
-- Conjunto cerrado y chico (ADR-0033): lo que no está acá no es
-- configurable y sigue siendo de todo miembro activo (ver el calendario,
-- la agenda, el padrón de clientes, los horarios) o ya es OWNER-only
-- (configuración, branding, invitar equipo, planes y precios, créditos
-- manuales, merge/unlink de clientes).

create type public.org_permission as enum (
  'VIEW_PAYMENTS',
  'MANAGE_PAYMENTS',
  'MANAGE_BOOKINGS',
  'MANAGE_CUSTOMERS',
  'MANAGE_ATTENDANCE'
);

-- ============================================================
-- 2. organization_roles
-- ============================================================
-- Permisos como columnas booleanas `not null`, no `jsonb` (ADR-0033 §4.2):
-- `(permissions->>'view_payments')::boolean` con una clave ausente o mal
-- tipeada da NULL, y este proyecto ya tuvo un bypass de autorización por
-- lógica de tres valores (raíz de ADR-0026 hallazgo A y de ADR-0028). Una
-- columna booleana `not null` no tiene ese estado. Además el DEFAULT de la
-- columna *es* el mecanismo de migración: agregar un permiso más adelante
-- es `add column can_x boolean not null default true` y ningún rol
-- existente cambia de comportamiento.

create table public.organization_roles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  -- Nombre libre, elegido por la organización: "Profesor", "Recepción",
  -- "Instructor". El producto es genérico (CLAUDE.md), así que el nombre
  -- del rol no puede venir de un enum nuestro.
  name            text not null,
  -- El rol que recibe un STAFF sin rol asignado. Exactamente uno por
  -- organización, garantizado por la base (índice parcial + trigger).
  is_default      boolean not null default false,
  is_active       boolean not null default true,

  can_view_payments     boolean not null default true,
  can_manage_payments   boolean not null default true,
  can_manage_bookings   boolean not null default true,
  can_manage_customers  boolean not null default true,
  can_manage_attendance boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),

  constraint organization_roles_name_length
    check (char_length(trim(name)) between 1 and 60),

  -- Cobrar sin poder ver lo cobrado no es un rol, es un bug.
  -- (ADR-0033 resolución 1: MANAGE implica VIEW.)
  constraint organization_roles_manage_implies_view
    check (not can_manage_payments or can_view_payments),

  -- El rol por defecto es el que reciben los STAFF sin rol: un rol por
  -- defecto inactivo dejaría a esos miembros sin ningún permiso sin que
  -- nadie lo haya pedido. Para desactivarlo primero hay que mover el
  -- default a otro rol.
  constraint organization_roles_default_is_active
    check (not is_default or is_active)
);

comment on table public.organization_roles is
  'ADR-0033: rol configurable por organización, una capa DENTRO de STAFF. OWNER no se configura y nunca consulta esta tabla. Permisos como columnas booleanas not null, no jsonb (ver ADR-0033 4.2).';

create trigger organization_roles_set_updated_at
  before update on public.organization_roles
  for each row execute function public.set_updated_at();

create unique index organization_roles_org_name_idx
  on public.organization_roles (organization_id, lower(trim(name)));

-- Como máximo un rol por defecto por organización. El "como mínimo uno" lo
-- pone el constraint trigger diferido de la sección 5 -- este índice es
-- inmediato, así que mover el default siempre es "desmarcar y después
-- marcar", nunca al revés.
create unique index organization_roles_one_default_idx
  on public.organization_roles (organization_id) where is_default;

create index organization_roles_organization_idx
  on public.organization_roles (organization_id);

-- ============================================================
-- 3. organization_members.role_id
-- ============================================================
-- Nullable a propósito (ADR-0033 §4.1): organization_members es escribible
-- por PostgREST directo (organization_members_write_owner es `for all`),
-- así que un `not null` rompería cualquier escritura que hoy no manda la
-- columna -- y ADR-0028 ya dejó la lección de que lo que se confía a que
-- cada llamador recuerde hacer, en algún lado no se hace. El fallback al
-- rol por defecto no es fail-open: ese rol lo configura el OWNER.

alter table public.organization_members
  add column role_id uuid references public.organization_roles (id);

comment on column public.organization_members.role_id is
  'ADR-0033: rol configurable del miembro. Null = el rol is_default de la organización. Siempre null para un OWNER (un OWNER corta antes de mirar permisos).';

create index organization_members_role_idx
  on public.organization_members (role_id);

-- Un OWNER no tiene rol configurable. Es un CHECK y no una convención de
-- la UI: la propuesta (riesgo 4) preveía "la pantalla no ofrece rol para un
-- OWNER", pero eso deja la contradicción "le puse el rol Profesor al dueño
-- y sigue viendo todo" viva en la base para cualquier PATCH directo.
alter table public.organization_members
  add constraint organization_members_owner_has_no_role
  check (role <> 'OWNER' or role_id is null);

-- Un rol de OTRA organización no es un rol de este miembro. La FK sola no
-- lo impide (apunta a organization_roles, no a "los roles de esta
-- organización"), y el resultado sería un cross-tenant de autorización.
-- Mismo precedente que check_payment_same_org().
create or replace function public.check_member_role_same_org()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.role_id is not null and not exists (
    select 1 from public.organization_roles r
    where r.id = new.role_id and r.organization_id = new.organization_id
  ) then
    raise exception 'ROLE_OTHER_ORGANIZATION';
  end if;
  return new;
end;
$$;

create trigger organization_members_role_same_org
  before insert or update on public.organization_members
  for each row execute function public.check_member_role_same_org();

-- ============================================================
-- 4. Siembra del rol por defecto + backfill
-- ============================================================
-- Un trigger, no una línea dentro de create_organization_with_owner():
-- una organización sin rol por defecto es una organización donde todo
-- STAFF futuro queda sin ningún permiso, y ADR-0028 ya demostró que lo que
-- depende de que cada llamador se acuerde, en algún camino no pasa. Esto
-- cubre también el alta de ADR-0034 y cualquier inserción por service_role
-- en tests.

create or replace function public.seed_default_organization_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.organization_roles (organization_id, name, is_default, created_by)
  values (new.id, 'Equipo', true, new.created_by);
  return new;
end;
$$;

create trigger organizations_seed_default_role
  after insert on public.organizations
  for each row execute function public.seed_default_organization_role();

-- Backfill: las organizaciones que ya existen.
insert into public.organization_roles (organization_id, name, is_default, created_by)
select o.id, 'Equipo', true, o.created_by
  from public.organizations o
 where not exists (
   select 1 from public.organization_roles r where r.organization_id = o.id
 );

-- Y sus miembros STAFF. Los OWNER quedan con role_id null por el CHECK de
-- la sección 3: un OWNER nunca consulta la columna.
update public.organization_members om
   set role_id = r.id
  from public.organization_roles r
 where r.organization_id = om.organization_id
   and r.is_default
   and om.role = 'STAFF'
   and om.role_id is null;

-- ============================================================
-- 5. Las dos guardas que van en la base, no en el server action
-- ============================================================

-- 5.1 Siempre existe exactamente un rol por defecto.
-- Constraint trigger DIFERIDO: mover el default es "desmarcar y después
-- marcar" (dos statements), y un chequeo inmediato rechazaría el primero.
-- Diferido al commit ve el estado final. Una organización borrada no se
-- chequea: el cascade de organizations borra sus roles y no hay nada que
-- exigir.
create or replace function public.check_organization_default_role_present()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_org uuid;
  v_count int;
begin
  if tg_op = 'DELETE' then
    v_org := old.organization_id;
  else
    v_org := new.organization_id;
  end if;

  if not exists (select 1 from public.organizations where id = v_org) then
    return null;
  end if;

  select count(*) into v_count
    from public.organization_roles
   where organization_id = v_org and is_default;

  if v_count <> 1 then
    raise exception 'DEFAULT_ROLE_REQUIRED';
  end if;

  return null;
end;
$$;

create constraint trigger organization_roles_default_present
  after insert or update or delete on public.organization_roles
  deferrable initially deferred
  for each row execute function public.check_organization_default_role_present();

-- 5.2 Un rol con miembros activos no se desactiva ni se borra.
-- Si se pudiera, esos miembros caerían al rol por defecto de golpe y en
-- silencio -- posiblemente ganando permisos. Primero se reasigna.
create or replace function public.check_organization_role_not_in_use()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_role_id uuid;
begin
  if tg_op = 'DELETE' then
    -- Cascade de organizations: no hay nada que proteger.
    if not exists (select 1 from public.organizations where id = old.organization_id) then
      return old;
    end if;
    v_role_id := old.id;
  elsif old.is_active and not new.is_active then
    v_role_id := old.id;
  else
    return new;
  end if;

  if exists (
    select 1 from public.organization_members om
    where om.role_id = v_role_id and om.is_active
  ) then
    raise exception 'ROLE_IN_USE';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger organization_roles_not_in_use
  before update or delete on public.organization_roles
  for each row execute function public.check_organization_role_not_in_use();

-- ============================================================
-- 6. has_org_permission(): el único resolvedor de permisos
-- ============================================================
-- Mismas propiedades que is_organization_member(): `security definer` para
-- romper la recursión de RLS que documenta phase1:204-213, `stable` para
-- que Postgres la cachee dentro del statement, y **con EXECUTE para
-- PUBLIC a propósito** -- es una de las funciones "correctas por
-- construcción que RLS necesita evaluar como cualquier rol" que ADR-0028
-- dejó explícitamente exceptuadas del `revoke from public`. Sólo contesta
-- sobre auth.uid(), así que no revela nada de nadie más.
--
-- El `else false` del CASE es el segundo cinturón detrás del enum: un
-- permiso agregado al enum sin agregar su columna falla cerrado.

create or replace function public.has_org_permission(
  p_organization_id uuid,
  p_permission public.org_permission
)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members om
    left join public.organization_roles r
      on r.id = coalesce(
           om.role_id,
           (select d.id
              from public.organization_roles d
             where d.organization_id = om.organization_id
               and d.is_default
             limit 1)
         )
    where om.organization_id = p_organization_id
      and om.profile_id = auth.uid()
      and om.is_active
      and (
        om.role = 'OWNER'
        or (r.is_active and case p_permission
              when 'VIEW_PAYMENTS'     then r.can_view_payments
              when 'MANAGE_PAYMENTS'   then r.can_manage_payments
              when 'MANAGE_BOOKINGS'   then r.can_manage_bookings
              when 'MANAGE_CUSTOMERS'  then r.can_manage_customers
              when 'MANAGE_ATTENDANCE' then r.can_manage_attendance
              else false
            end)
      )
  );
$$;

comment on function public.has_org_permission(uuid, public.org_permission) is
  'ADR-0033: única puerta de permisos del panel. OWNER siempre true sin consultar el rol (raíz de confianza). STAFF resuelve su rol, o el rol is_default de la organización si no tiene uno asignado. Mantiene EXECUTE para PUBLIC igual que is_organization_member(): las policies la evalúan como el rol que consulta.';

-- El read model que necesita el panel para esconder/deshabilitar en vez de
-- mostrar-todo-y-fallar-al-guardar. Sin filas para un no-miembro.
create or replace function public.my_organization_permissions(p_organization_id uuid)
returns table (
  role public.organization_member_role,
  role_id uuid,
  role_name text,
  can_view_payments boolean,
  can_manage_payments boolean,
  can_manage_bookings boolean,
  can_manage_customers boolean,
  can_manage_attendance boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    om.role,
    case when om.role = 'OWNER' then null else r.id end,
    case when om.role = 'OWNER' then null else r.name end,
    om.role = 'OWNER' or coalesce(r.is_active and r.can_view_payments, false),
    om.role = 'OWNER' or coalesce(r.is_active and r.can_manage_payments, false),
    om.role = 'OWNER' or coalesce(r.is_active and r.can_manage_bookings, false),
    om.role = 'OWNER' or coalesce(r.is_active and r.can_manage_customers, false),
    om.role = 'OWNER' or coalesce(r.is_active and r.can_manage_attendance, false)
  from public.organization_members om
  left join public.organization_roles r
    on r.id = coalesce(
         om.role_id,
         (select d.id from public.organization_roles d
           where d.organization_id = om.organization_id and d.is_default limit 1)
       )
  where om.organization_id = p_organization_id
    and om.profile_id = auth.uid()
    and om.is_active;
$$;

revoke execute on function public.my_organization_permissions(uuid) from public, anon;
grant execute on function public.my_organization_permissions(uuid) to authenticated;

-- ============================================================
-- 7. RLS de organization_roles
-- ============================================================
-- Lectura para todo miembro: la pantalla de equipo muestra el nombre del
-- rol de cada uno. Escritura sólo OWNER, mismo criterio que
-- organization_members, organizations y revoke_member().
--
-- Administrar roles NO es un permiso configurable a propósito: si lo
-- fuera, existiría un rol capaz de ampliarse a sí mismo y los otros cinco
-- no significarían nada (ADR-0033 §4.6).

alter table public.organization_roles enable row level security;

create policy organization_roles_select_members
  on public.organization_roles for select
  using (public.is_organization_member(organization_id));

create policy organization_roles_write_owner
  on public.organization_roles for all
  using (public.is_organization_owner(organization_id))
  with check (public.is_organization_owner(organization_id));

revoke all on public.organization_roles from anon;
grant select, insert, update, delete on public.organization_roles to authenticated;

-- ============================================================
-- 8. RPCs de administración de roles (OWNER)
-- ============================================================
-- Las policies de la sección 7 ya alcanzan para un PATCH directo, pero
-- mover el rol por defecto son dos statements (desmarcar, marcar) y dos
-- llamadas de PostgREST son dos transacciones -- el mismo razonamiento de
-- ADR-0004 que obligó a book_slot(). Y los errores traducidos son mejores
-- que una violación de índice cruda.

create or replace function public.create_organization_role(
  p_organization_id uuid,
  p_name text,
  p_can_view_payments boolean default true,
  p_can_manage_payments boolean default true,
  p_can_manage_bookings boolean default true,
  p_can_manage_customers boolean default true,
  p_can_manage_attendance boolean default true
)
returns public.organization_roles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.organization_roles;
begin
  if not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'ROLE_NAME_REQUIRED';
  end if;

  if char_length(trim(p_name)) > 60 then
    raise exception 'ROLE_NAME_TOO_LONG';
  end if;

  if p_can_manage_payments and not p_can_view_payments then
    raise exception 'MANAGE_PAYMENTS_REQUIRES_VIEW';
  end if;

  begin
    insert into public.organization_roles (
      organization_id, name, is_default, created_by,
      can_view_payments, can_manage_payments, can_manage_bookings,
      can_manage_customers, can_manage_attendance
    ) values (
      p_organization_id, trim(p_name), false, auth.uid(),
      p_can_view_payments, p_can_manage_payments, p_can_manage_bookings,
      p_can_manage_customers, p_can_manage_attendance
    )
    returning * into v_role;
  exception
    when unique_violation then
      raise exception 'ROLE_NAME_TAKEN';
  end;

  return v_role;
end;
$$;

revoke execute on function public.create_organization_role(uuid, text, boolean, boolean, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.create_organization_role(uuid, text, boolean, boolean, boolean, boolean, boolean)
  to authenticated;

create or replace function public.update_organization_role(
  p_role_id uuid,
  p_name text default null,
  p_can_view_payments boolean default null,
  p_can_manage_payments boolean default null,
  p_can_manage_bookings boolean default null,
  p_can_manage_customers boolean default null,
  p_can_manage_attendance boolean default null,
  p_is_active boolean default null
)
returns public.organization_roles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.organization_roles;
  v_view boolean;
  v_manage boolean;
  v_constraint text;
begin
  select * into v_role from public.organization_roles where id = p_role_id;
  if not found then
    raise exception 'ROLE_NOT_FOUND';
  end if;

  if not public.is_organization_owner(v_role.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if char_length(trim(coalesce(p_name, ''))) > 60 then
    raise exception 'ROLE_NAME_TOO_LONG';
  end if;

  v_view := coalesce(p_can_view_payments, v_role.can_view_payments);
  v_manage := coalesce(p_can_manage_payments, v_role.can_manage_payments);
  if v_manage and not v_view then
    raise exception 'MANAGE_PAYMENTS_REQUIRES_VIEW';
  end if;

  begin
    update public.organization_roles
       set name = coalesce(nullif(trim(coalesce(p_name, '')), ''), name),
           can_view_payments = v_view,
           can_manage_payments = v_manage,
           can_manage_bookings = coalesce(p_can_manage_bookings, can_manage_bookings),
           can_manage_customers = coalesce(p_can_manage_customers, can_manage_customers),
           can_manage_attendance = coalesce(p_can_manage_attendance, can_manage_attendance),
           is_active = coalesce(p_is_active, is_active)
     where id = p_role_id
     returning * into v_role;
  exception
    when unique_violation then
      raise exception 'ROLE_NAME_TAKEN';
    when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'organization_roles_default_is_active' then
        -- Desactivar el rol por defecto exige mover el default primero.
        raise exception 'DEFAULT_ROLE_REQUIRED';
      end if;
      raise;
  end;

  return v_role;
end;
$$;

revoke execute on function public.update_organization_role(uuid, text, boolean, boolean, boolean, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.update_organization_role(uuid, text, boolean, boolean, boolean, boolean, boolean, boolean)
  to authenticated;

create or replace function public.set_organization_role_default(p_role_id uuid)
returns public.organization_roles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.organization_roles;
begin
  select * into v_role from public.organization_roles where id = p_role_id;
  if not found then
    raise exception 'ROLE_NOT_FOUND';
  end if;

  if not public.is_organization_owner(v_role.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if not v_role.is_active then
    raise exception 'ROLE_INACTIVE';
  end if;

  -- Desmarcar y después marcar, en ese orden: el índice parcial único es
  -- inmediato. El constraint trigger que exige "exactamente uno" es
  -- diferido, así que ve el estado final y no el intermedio.
  update public.organization_roles
     set is_default = false
   where organization_id = v_role.organization_id and is_default and id <> p_role_id;

  update public.organization_roles
     set is_default = true
   where id = p_role_id
   returning * into v_role;

  return v_role;
end;
$$;

revoke execute on function public.set_organization_role_default(uuid) from public, anon;
grant execute on function public.set_organization_role_default(uuid) to authenticated;

create or replace function public.set_member_role(p_member_id uuid, p_role_id uuid)
returns public.organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member public.organization_members;
begin
  select * into v_member from public.organization_members where id = p_member_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;

  if not public.is_organization_owner(v_member.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Un OWNER no tiene rol configurable: corta antes de mirarlo, así que
  -- asignarle uno sólo generaría la confusión de "le puse el rol Profesor
  -- al dueño y sigue viendo todo" (ADR-0033 riesgo 4).
  if v_member.role = 'OWNER' then
    raise exception 'OWNER_HAS_NO_ROLE';
  end if;

  if p_role_id is not null and not exists (
    select 1 from public.organization_roles r
    where r.id = p_role_id
      and r.organization_id = v_member.organization_id
      and r.is_active
  ) then
    raise exception 'ROLE_NOT_FOUND';
  end if;

  update public.organization_members
     set role_id = p_role_id
   where id = p_member_id
   returning * into v_member;

  return v_member;
end;
$$;

revoke execute on function public.set_member_role(uuid, uuid) from public, anon;
grant execute on function public.set_member_role(uuid, uuid) to authenticated;

-- ============================================================
-- 9. organization_team(): el nombre del rol efectivo
-- ============================================================
-- Cambio de contrato (dos columnas nuevas) -> frontend-engineer, docs/api.md.
-- `role_name` es el rol EFECTIVO: el asignado, o el por defecto cuando
-- role_id es null. Un OWNER no tiene rol y devuelve null en las dos.

drop function if exists public.organization_team(uuid);

create function public.organization_team(p_organization_id uuid)
returns table (
  member_id uuid,
  profile_id uuid,
  full_name text,
  role public.organization_member_role,
  is_active boolean,
  role_id uuid,
  role_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    om.id,
    om.profile_id,
    coalesce(p.full_name, 'Sin nombre'),
    om.role,
    om.is_active,
    case when om.role = 'OWNER' then null else r.id end,
    case when om.role = 'OWNER' then null else r.name end
  from public.organization_members om
  join public.profiles p on p.id = om.profile_id
  left join public.organization_roles r
    on r.id = coalesce(
         om.role_id,
         (select d.id from public.organization_roles d
           where d.organization_id = om.organization_id and d.is_default limit 1)
       )
  where om.organization_id = p_organization_id
    and public.is_organization_member(p_organization_id)
  order by om.role asc, p.full_name asc;
$$;

revoke execute on function public.organization_team(uuid) from public, anon;
grant execute on function public.organization_team(uuid) to authenticated;

-- ============================================================
-- 10. invite_member_by_email(): con rol configurable
-- ============================================================
-- Un parámetro nuevo no entra con `create or replace` (crearía una segunda
-- función y la llamada de 3 argumentos quedaría ambigua), así que va
-- drop + create. `p_role_id` tiene DEFAULT null, de modo que la llamada de
-- 3 argumentos que hace hoy frontend/app/actions/admin.ts sigue
-- resolviendo: el miembro queda con role_id null, o sea el rol por
-- defecto. No es un cambio de contrato roto, es aditivo.

drop function if exists public.invite_member_by_email(uuid, text, public.organization_member_role);

create function public.invite_member_by_email(
  p_organization_id uuid,
  p_email text,
  p_role public.organization_member_role default 'STAFF',
  p_role_id uuid default null
)
returns public.organization_members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
  v_member public.organization_members;
  v_role_id uuid;
begin
  -- Sumar equipo sigue siendo OWNER-only, y por eso mismo elegir el rol
  -- del invitado también lo es.
  if not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Un OWNER nunca lleva rol configurable (CHECK
  -- organization_members_owner_has_no_role).
  v_role_id := case when p_role = 'OWNER' then null else p_role_id end;

  if v_role_id is not null and not exists (
    select 1 from public.organization_roles r
    where r.id = v_role_id and r.organization_id = p_organization_id and r.is_active
  ) then
    raise exception 'ROLE_NOT_FOUND';
  end if;

  select id into v_profile_id from auth.users where lower(email) = lower(trim(p_email));
  if v_profile_id is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;

  select * into v_member from public.organization_members
    where organization_id = p_organization_id and profile_id = v_profile_id;

  if found then
    update public.organization_members
      set role = p_role,
          role_id = v_role_id,
          is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
      where id = v_member.id
      returning * into v_member;
    return v_member;
  end if;

  insert into public.organization_members (organization_id, profile_id, role, role_id, created_by)
  values (p_organization_id, v_profile_id, p_role, v_role_id, auth.uid())
  returning * into v_member;

  return v_member;
end;
$$;

revoke execute on function public.invite_member_by_email(uuid, text, public.organization_member_role, uuid)
  from public, anon;
grant execute on function public.invite_member_by_email(uuid, text, public.organization_member_role, uuid)
  to authenticated;

-- ============================================================
-- 11. Endurecimiento: policies de pagos
-- ============================================================
-- La rama del cliente NO se toca: ADR-0006 de dos capas sigue igual.
-- Sólo la rama de staff pasa de "es miembro" a "es miembro con el
-- permiso".

drop policy if exists payments_select_self_or_staff on public.payments;

create policy payments_select_self_or_staff
  on public.payments for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = payments.customer_id and c.profile_id = auth.uid()
    )
    or public.has_org_permission(organization_id, 'VIEW_PAYMENTS')
  );

drop policy if exists payments_insert_staff on public.payments;

create policy payments_insert_staff
  on public.payments for insert
  with check (public.has_org_permission(organization_id, 'MANAGE_PAYMENTS'));

drop policy if exists payments_update_staff on public.payments;

create policy payments_update_staff
  on public.payments for update
  using (public.has_org_permission(organization_id, 'MANAGE_PAYMENTS'))
  with check (public.has_org_permission(organization_id, 'MANAGE_PAYMENTS'));

-- payment_service_coverage: cada fila es la consecuencia de un pago y dice
-- qué período pagó quién. Es dato de pago, así que la rama de staff va
-- detrás de VIEW_PAYMENTS igual que payments.
drop policy if exists payment_service_coverage_select_self_or_staff on public.payment_service_coverage;

create policy payment_service_coverage_select_self_or_staff
  on public.payment_service_coverage for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = payment_service_coverage.customer_id and c.profile_id = auth.uid()
    )
    or public.has_org_permission(organization_id, 'VIEW_PAYMENTS')
  );

-- plan_change_requests (ADR-0035): "este cliente pidió cambiarse a este
-- plan, que cuesta tanto" es la cola de trabajo del mostrador, y la fila
-- trae precios y plan actual. Leerla es VIEW_PAYMENTS.
drop policy if exists plan_change_requests_select_self_or_staff on public.plan_change_requests;

create policy plan_change_requests_select_self_or_staff
  on public.plan_change_requests for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = plan_change_requests.customer_id and c.profile_id = auth.uid()
    )
    or public.has_org_permission(organization_id, 'VIEW_PAYMENTS')
  );

-- ============================================================
-- 12. Endurecimiento: policy de escritura de clientes
-- ============================================================
-- La lectura del padrón (customers_select_self_or_staff) no se toca: sin
-- ver a los clientes no hay trabajo que hacer, y un rol que no puede pasar
-- lista porque no ve a la gente no es un rol (ADR-0033 §4.3).

drop policy if exists customers_write_staff on public.customers;

create policy customers_write_staff
  on public.customers for all
  using (public.has_org_permission(organization_id, 'MANAGE_CUSTOMERS'))
  with check (public.has_org_permission(organization_id, 'MANAGE_CUSTOMERS'));

-- ============================================================
-- 13. Endurecimiento: precios de plan, OWNER en la BASE
-- ============================================================
-- ADR-0033 resolución 3. Hoy el gate de OWNER sobre planes vive sólo en
-- TypeScript (frontend/app/actions/service-plans.ts:324,424,481), mientras
-- create_service_plan() y las policies service_plans_*_staff sólo exigen
-- is_organization_member(): cualquier STAFF cambia el precio de un plan con
-- un `PATCH /rest/v1/service_plans` sin pasar por el panel. La decisión de
-- producto ya estaba tomada; lo que faltaba era ponerla donde se aplica.
-- "Hiding the button is not enforcement" (enforce_plan_limit, phase10:170).
--
-- Nota que hay que decirle al usuario: esto NO es "no ver precios".
-- service_plans_select_public sigue siendo `is_active or
-- is_organization_member(...)`: la lista de precios de los planes activos
-- es pública, la ve cualquier visitante del calendario.

drop policy if exists service_plans_insert_staff on public.service_plans;

create policy service_plans_insert_owner
  on public.service_plans for insert
  with check (public.is_organization_owner(organization_id));

drop policy if exists service_plans_update_staff on public.service_plans;

create policy service_plans_update_owner
  on public.service_plans for update
  using (public.is_organization_owner(organization_id))
  with check (public.is_organization_owner(organization_id));

drop policy if exists service_plan_services_write_staff on public.service_plan_services;

create policy service_plan_services_write_owner
  on public.service_plan_services for all
  using (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_owner(sp.organization_id)
  ))
  with check (exists (
    select 1 from public.service_plans sp
    where sp.id = service_plan_id and public.is_organization_owner(sp.organization_id)
  ));

-- El gate de OWNER sobre la RPC va como TRIGGER y no reescribiendo
-- create_service_plan(): esa función es `security definer`, o sea que
-- bypassea RLS y las policies de arriba no la alcanzan -- pero un trigger
-- SIEMPRE se dispara, venga la escritura de la RPC o de un
-- `PATCH /rest/v1/service_plans` directo. Mismo patrón (y mismo motivo)
-- que check_service_billing_override_owner() en la Fase 25, con la ventaja
-- extra de que no duplica el cuerpo de una función que otras migraciones
-- siguen evolucionando.
--
-- `auth.uid() is null` no se bloquea: ese es el camino sin JWT (backfills
-- de migración, el job diario, un cliente service_role -- que ya
-- bypassea RLS por definición). Toda request real de un panel lleva su
-- `sub`.
create or replace function public.check_service_plan_write_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if auth.uid() is not null and not public.is_organization_owner(new.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  return new;
end;
$BODY$;

comment on function public.check_service_plan_write_owner() is
  'ADR-0033 resolución 3: el precio y el nombre de un ServicePlan sólo los toca el OWNER, y ahora en la base. Antes el gate vivía sólo en frontend/app/actions/service-plans.ts, mientras create_service_plan() y las policies service_plans_*_staff pedían nada más is_organization_member(): cualquier STAFF cambiaba un precio por PostgREST sin pasar por el panel.';

drop trigger if exists service_plans_write_owner on public.service_plans;
create trigger service_plans_write_owner
  before insert or update on public.service_plans
  for each row
  execute function public.check_service_plan_write_owner();

-- ============================================================
-- 14. Endurecimiento: RPCs de pagos (SECURITY DEFINER bypassea RLS)
-- ============================================================
-- Éste es el modo de fallar más probable de toda la feature (ADR-0033
-- riesgo 1): una RPC `security definer` corre como dueña de la tabla y
-- bypassea RLS por completo, así que endurecer la policy de payments no
-- alcanza. Si se olvidara una, la pestaña quedaría escondida y el dato
-- seguiría saliendo por POST /rest/v1/rpc/...

create or replace function public.organization_payment_summary(
  p_organization_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  customer_id uuid,
  customer_name text,
  is_active boolean,
  services_count int,
  total numeric,
  paid numeric,
  pending numeric,
  rollup_status text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    c.id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    c.is_active,
    count(distinct pay.service_id)::int,
    coalesce(sum(pay.amount) filter (where pay.status <> 'VOID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status = 'PAID'), 0),
    coalesce(sum(pay.amount) filter (where pay.status in ('PENDING', 'OVERDUE')), 0),
    case
      when count(pay.id) filter (where pay.status <> 'VOID') = 0 then 'NO_PAYMENTS'
      when count(pay.id) filter (where pay.status = 'OVERDUE') > 0 then 'OVERDUE'
      when count(pay.id) filter (where pay.status in ('PENDING', 'OVERDUE')) = 0 then 'PAID'
      when count(pay.id) filter (where pay.status = 'PAID') = 0 then 'PENDING'
      else 'PARTIAL'
    end
  from public.customers c
  left join public.profiles p on p.id = c.profile_id
  left join public.payments pay
    on pay.customer_id = c.id
   and pay.period_start <= p_period_end
   and pay.period_end >= p_period_start
  where c.organization_id = p_organization_id
    and public.has_org_permission(p_organization_id, 'VIEW_PAYMENTS')
  group by c.id, c.display_name, p.full_name, c.is_active
  order by coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre') asc;
$BODY$;

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
    and public.has_org_permission(pay.organization_id, 'VIEW_PAYMENTS')
  order by coalesce(s.name, sp.name, 'Plan') asc, pay.period_start desc;
$BODY$;

create or replace function public.set_payment_status(
  p_payment_id uuid,
  p_status public.payment_status
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments where id = p_payment_id;
  if not found then
    raise exception 'PAYMENT_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_payment.organization_id, 'MANAGE_PAYMENTS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.payments set status = p_status where id = p_payment_id
    returning * into v_payment;

  return v_payment;
end;
$BODY$;

-- customer_billing_horizon(): NO lleva chequeo de permiso, y es
-- deliberado. No está otorgada a nadie (sólo al dueño de la función) --
-- es un helper interno que evaluate_payment_coverage() y compañía llaman
-- dentro del camino de reserva de un cliente, donde auth.uid() es el
-- cliente y no un miembro. Un has_org_permission() acá rompería el
-- booking de cualquier cliente. La puerta es el REVOKE, y se deja
-- explícito para que un `grant ... to authenticated` futuro tenga que ser
-- una decisión y no un descuido.
revoke execute on function public.customer_billing_horizon(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- plan_change_requests (ADR-0035): leer la cola es VIEW_PAYMENTS,
-- cerrarla es MANAGE_PAYMENTS. El comentario original decía "cerrar un
-- pedido es trabajo de mostrador, no de dueño" -- sigue siendo cierto, y
-- ahora "mostrador" tiene un nombre.
create or replace function public.organization_plan_change_requests(
  p_organization_id uuid,
  p_include_resolved boolean default false
)
returns table (
  request_id uuid,
  customer_id uuid,
  customer_name text,
  requested_plan_id uuid,
  requested_plan_name text,
  requested_plan_price numeric,
  requested_plan_kind public.service_plan_kind,
  requested_weekly_quota int,
  current_plan_id uuid,
  current_plan_name text,
  current_plan_price numeric,
  currency text,
  note text,
  created_at timestamptz,
  resolution public.plan_change_request_resolution,
  resolved_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    r.id,
    c.id,
    coalesce(nullif(trim(c.display_name), ''), p.full_name, 'Sin nombre'),
    sp.id,
    sp.name,
    sp.price,
    sp.plan_kind,
    sp.weekly_quota,
    cur.id,
    cur.name,
    cur.price,
    o.currency,
    r.note,
    r.created_at,
    r.resolution,
    r.resolved_at
  from public.plan_change_requests r
  join public.organizations o on o.id = r.organization_id
  join public.customers c on c.id = r.customer_id
  left join public.profiles p on p.id = c.profile_id
  join public.service_plans sp on sp.id = r.service_plan_id
  left join public.service_plans cur on cur.id = r.current_service_plan_id
  where r.organization_id = p_organization_id
    and public.has_org_permission(p_organization_id, 'VIEW_PAYMENTS')
    and (p_include_resolved or r.resolved_at is null)
  order by r.resolved_at nulls first, r.created_at desc;
$BODY$;

create or replace function public.resolve_plan_change_request(
  p_request_id uuid,
  p_resolution public.plan_change_request_resolution
)
returns public.plan_change_requests
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_row public.plan_change_requests;
begin
  select * into v_row from public.plan_change_requests where id = p_request_id;
  if not found then
    raise exception 'PLAN_CHANGE_REQUEST_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_row.organization_id, 'MANAGE_PAYMENTS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_row.resolved_at is not null then
    return v_row;
  end if;

  update public.plan_change_requests
    set resolved_at = now(),
        resolved_by = auth.uid(),
        resolution = p_resolution
    where id = p_request_id
    returning * into v_row;

  return v_row;
end;
$BODY$;

-- ============================================================
-- 15. Endurecimiento: RPCs de reservas de mostrador (MANAGE_BOOKINGS)
-- ============================================================

create or replace function public.admin_book_for_customer(
  p_slot_occurrence_id uuid,
  p_customer_id uuid,
  p_use_makeup_credit boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_coverage public.can_book_reason;
  v_makeup_credit_id uuid;
  v_active_count int;
  v_booking public.bookings;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return jsonb_build_object('status', 'OCCURRENCE_NOT_AVAILABLE');
  end if;

  if not public.has_org_permission(v_occurrence.organization_id, 'MANAGE_BOOKINGS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if not exists (
    select 1 from public.customers
    where id = p_customer_id and organization_id = v_occurrence.organization_id and is_active
  ) then
    return jsonb_build_object('status', 'NOT_A_CUSTOMER');
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';
  if v_active_count >= v_occurrence.capacity then
    return jsonb_build_object('status', 'SLOT_FULL');
  end if;

  if exists (
    select 1 from public.bookings
    where customer_id = p_customer_id and slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED'
  ) then
    return jsonb_build_object('status', 'ALREADY_BOOKED');
  end if;

  select reason, makeup_credit_id into v_coverage, v_makeup_credit_id
  from public.evaluate_payment_coverage_with_credit(
    p_customer_id, v_occurrence.service_id, p_slot_occurrence_id, null, false, p_use_makeup_credit
  );
  if v_coverage <> 'OK' then
    return jsonb_build_object('status', v_coverage);
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, status, created_by
  )
  values (
    v_occurrence.organization_id, p_customer_id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
  )
  on conflict (customer_id, slot_occurrence_id) where status = 'CONFIRMED' do nothing
  returning * into v_booking;

  if v_booking.id is null then
    return jsonb_build_object('status', 'DUPLICATE');
  end if;

  if v_makeup_credit_id is not null then
    update public.makeup_credits
      set status = 'CONSUMED', consumed_booking_id = v_booking.id, consumed_at = now()
      where id = v_makeup_credit_id and status = 'AVAILABLE';

    if not found then
      raise exception 'MAKEUP_CREDIT_RACE_LOST';
    end if;
  end if;

  return jsonb_build_object(
    'status', 'OK',
    'booking', to_jsonb(v_booking),
    'makeup_credit_id', v_makeup_credit_id
  );
end;
$BODY$;

create or replace function public.admin_create_recurring_booking(
  p_schedule_rule_id uuid,
  p_customer_id uuid
)
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
  v_today date := current_date;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_rule.organization_id, 'MANAGE_BOOKINGS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id and organization_id = v_rule.organization_id and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  if public.customer_standing_series_on_rule(p_customer_id, p_schedule_rule_id, v_today) is not null then
    raise exception 'ALREADY_HAS_STANDING_RESERVATION';
  end if;

  perform public.assert_series_within_plan_quota(p_customer_id, v_rule.service_id, v_today);

  insert into public.recurring_bookings (organization_id, customer_id, schedule_rule_id, created_by)
  values (v_rule.organization_id, p_customer_id, p_schedule_rule_id, auth.uid())
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

-- El preview es la antesala de admin_create_recurring_booking(): mismo
-- permiso, o sería un "probá y fijate" para un rol que no puede anotar.
-- Devuelve vacío (no excepción) igual que antes para un no-miembro.
create or replace function public.admin_preview_recurring_booking(
  p_schedule_rule_id uuid,
  p_customer_id uuid,
  p_count int default 12
)
returns table (slot_occurrence_id uuid, start_at timestamptz, can_book public.can_book_reason)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_existing_series uuid;
  v_rec record;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found or not public.has_org_permission(v_rule.organization_id, 'MANAGE_BOOKINGS') then
    return;
  end if;

  v_existing_series := public.customer_standing_series_on_rule(
    p_customer_id, p_schedule_rule_id, current_date
  );

  for v_rec in
    select so.id, so.start_at as occ_start
    from public.slot_occurrences so
    where so.schedule_rule_id = p_schedule_rule_id
      and so.status = 'ACTIVE'
      and so.start_at >= now()
    order by so.start_at asc
    limit p_count
  loop
    slot_occurrence_id := v_rec.id;
    start_at := v_rec.occ_start;
    can_book := public.evaluate_customer_booking(
      v_rec.id,
      p_customer_id,
      v_existing_series,
      v_existing_series is null
    );
    return next;
  end loop;
end;
$BODY$;

-- cancel_booking(): la rama del propio cliente NO se toca. Un STAFF que
-- además es cliente de la organización sigue pudiendo soltar SU reserva
-- sin MANAGE_BOOKINGS; lo que pasa a exigir permiso es cancelar la de
-- otra persona.
create or replace function public.cancel_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_updated public.bookings;
  v_customer public.customers;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'BOOKING_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_booking.customer_id;

  if v_customer.profile_id = auth.uid() then
    null;
  elsif public.has_org_permission(v_booking.organization_id, 'MANAGE_BOOKINGS') then
    null;
  else
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_booking.status = 'CANCELLED' then
    return v_booking;
  end if;

  update public.bookings
    set status = 'CANCELLED',
        cancelled_at = now(),
        cancelled_by = auth.uid(),
        cancellation_reason = 'CUSTOMER_REQUEST'
    where id = p_booking_id
    returning * into v_updated;

  update public.makeup_credits
    set status = 'AVAILABLE', consumed_at = null
    where consumed_booking_id = p_booking_id and status = 'CONSUMED';

  perform public.issue_makeup_credit(v_updated, 'CUSTOMER_RELEASE', true);

  return v_updated;
end;
$BODY$;

create or replace function public.cancel_recurring_booking(p_recurring_booking_id uuid)
returns public.recurring_bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rb public.recurring_bookings;
  v_customer public.customers;
  v_reason public.recurring_booking_cancellation_reason;
  v_cancelled_booking_id uuid;
begin
  select * into v_rb from public.recurring_bookings where id = p_recurring_booking_id;
  if not found then
    raise exception 'RECURRING_BOOKING_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_rb.customer_id;

  if v_customer.profile_id = auth.uid() then
    v_reason := 'CUSTOMER_REQUEST';
  elsif public.has_org_permission(v_rb.organization_id, 'MANAGE_BOOKINGS') then
    v_reason := 'ORGANIZATION_REMOVED';
  else
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_rb.status = 'CANCELLED' then
    return v_rb;
  end if;

  update public.recurring_bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_reason
    where id = p_recurring_booking_id
    returning * into v_rb;

  for v_cancelled_booking_id in
    update public.bookings b
      set status = 'CANCELLED',
          cancelled_at = now(),
          cancelled_by = auth.uid(),
          cancellation_reason = 'SERIES_CANCELLED'
      from public.slot_occurrences so
      where b.slot_occurrence_id = so.id
        and b.recurring_booking_id = p_recurring_booking_id
        and so.start_at >= now()
        and b.status = 'CONFIRMED'
      returning b.id
  loop
    -- Sin llamada a issue_makeup_credit(): una cascada de serie no
    -- acuña nada, la pida quien la pida.
    update public.makeup_credits
      set status = 'AVAILABLE', consumed_at = null
      where consumed_booking_id = v_cancelled_booking_id and status = 'CONSUMED';
  end loop;

  return v_rb;
end;
$BODY$;

create or replace function public.cancel_slot_occurrence(
  p_slot_occurrence_id uuid,
  p_reason public.slot_occurrence_cancellation_reason default 'SLOT_CANCELLED'
)
returns public.slot_occurrences
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_booking_reason public.booking_cancellation_reason;
  v_cancelled_booking public.bookings;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found then
    raise exception 'SLOT_OCCURRENCE_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_occurrence.organization_id, 'MANAGE_BOOKINGS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
    where id = p_slot_occurrence_id
    returning * into v_occurrence;

  v_booking_reason := case p_reason
    when 'SLOT_CANCELLED' then 'SLOT_CANCELLED'::public.booking_cancellation_reason
    else 'RULE_DISCONTINUED'::public.booking_cancellation_reason
  end;

  for v_cancelled_booking in
    update public.bookings
      set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = v_booking_reason
      where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED'
      returning *
  loop
    update public.makeup_credits
      set status = 'AVAILABLE', consumed_at = null
      where consumed_booking_id = v_cancelled_booking.id and status = 'CONSUMED';

    perform public.issue_makeup_credit(v_cancelled_booking, 'ORGANIZATION_CANCELLED', false);
  end loop;

  return v_occurrence;
end;
$BODY$;

-- retry_not_generated_booking(): reintentar una fecha ajena es operar
-- sobre la reserva de otra persona. La rama sin JWT (el job diario) y la
-- del propio cliente no cambian.
create or replace function public.retry_not_generated_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_customer public.customers;
  v_occurrence public.slot_occurrences;
  v_rb public.recurring_bookings;
  v_active_count int;
  v_coverage public.can_book_reason;
  v_reason public.not_generated_reason;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    return v_booking;
  end if;

  select * into v_customer from public.customers where id = v_booking.customer_id;

  if auth.uid() is null then
    null;
  elsif v_customer.profile_id = auth.uid() then
    null;
  elsif public.has_org_permission(v_booking.organization_id, 'MANAGE_BOOKINGS') then
    null;
  else
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_booking.status <> 'NOT_GENERATED' or v_booking.recurring_booking_id is null then
    return v_booking;
  end if;

  select * into v_rb from public.recurring_bookings
    where id = v_booking.recurring_booking_id and status = 'ACTIVE';
  if not found then
    return v_booking;
  end if;

  -- Same lock as book_slot (ADR-0004).
  select * into v_occurrence from public.slot_occurrences
    where id = v_booking.slot_occurrence_id for update;
  if not found or v_occurrence.status <> 'ACTIVE' or v_occurrence.start_at < now() then
    return v_booking;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = v_occurrence.id and status = 'CONFIRMED';

  v_coverage := public.evaluate_payment_coverage(
    v_booking.customer_id, v_occurrence.service_id, v_occurrence.id, v_booking.recurring_booking_id, false
  );

  if v_coverage in ('OVER_PLAN_QUOTA', 'OUTSIDE_PLAN_QUOTA') then
    v_reason := 'OVER_PLAN_QUOTA';
  elsif v_coverage <> 'OK' then
    v_reason := 'PAYMENT_REQUIRED';
  elsif exists (
    select 1 from public.bookings
    where customer_id = v_booking.customer_id
      and slot_occurrence_id = v_occurrence.id
      and status = 'CONFIRMED'
  ) then
    v_reason := 'DUPLICATE';
  elsif v_active_count >= v_occurrence.capacity then
    v_reason := 'SLOT_FULL';
  else
    v_reason := null;
  end if;

  if v_reason is not null then
    if v_reason is distinct from v_booking.not_generated_reason then
      update public.bookings set not_generated_reason = v_reason
        where id = p_booking_id
        returning * into v_booking;
    end if;
    return v_booking;
  end if;

  update public.bookings
    set status = 'CONFIRMED', not_generated_reason = null
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

-- ============================================================
-- 16. Endurecimiento: asistencia (MANAGE_ATTENDANCE)
-- ============================================================
-- ADR-0033 resolución 4: configurable. El caso inverso al pedido
-- ("recepción cobra pero no pasa lista") es igual de real.
-- occurrence_attendance_summary() y service_attendance_history() siguen
-- siendo de todo miembro: son la agenda, no la escritura.

create or replace function public.mark_attendance(
  p_booking_id uuid,
  p_status public.attendance_status
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'BOOKING_NOT_FOUND';
  end if;

  if not public.has_org_permission(v_booking.organization_id, 'MANAGE_ATTENDANCE') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_booking.status <> 'CONFIRMED' then
    raise exception 'BOOKING_NOT_CONFIRMED';
  end if;

  update public.bookings
    set attendance_status = p_status,
        attendance_marked_at = case when p_status = 'PENDING' then null else now() end,
        attendance_marked_by = case when p_status = 'PENDING' then null else auth.uid() end
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

-- ============================================================
-- 17. Endurecimiento: alta/baja de clientes (MANAGE_CUSTOMERS)
-- ============================================================
-- Leer el padrón sigue abierto a todo miembro (§4.3). Lo que pasa a
-- exigir permiso es crear, enrolar y emitir/revocar links de activación
-- -- un link de activación es acceso a la cuenta de un cliente.

create or replace function public.create_managed_customer(
  p_organization_id uuid,
  p_display_name text,
  p_phone text default null
)
returns public.customers
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer public.customers;
  v_name text;
  v_phone text;
begin
  if not public.has_org_permission(p_organization_id, 'MANAGE_CUSTOMERS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  v_name := nullif(trim(p_display_name), '');
  if v_name is null then
    raise exception 'DISPLAY_NAME_REQUIRED';
  end if;

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if v_phone is not null then
    if left(v_phone, 1) <> '+' then
      v_phone := '+' || v_phone;
    end if;
    if v_phone !~ '^\+[1-9][0-9]{6,14}$' then
      raise exception 'INVALID_PHONE';
    end if;
  end if;

  if v_phone is not null then
    select * into v_customer
      from public.customers
      where organization_id = p_organization_id and phone = v_phone;

    if found then
      if not v_customer.is_active then
        update public.customers
          set is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
          where id = v_customer.id
          returning * into v_customer;
      end if;
      return v_customer;
    end if;
  end if;

  insert into public.customers (organization_id, display_name, phone, created_by)
  values (p_organization_id, v_name, v_phone, auth.uid())
  returning * into v_customer;

  return v_customer;
end;
$BODY$;

create or replace function public.enroll_customer_by_email(
  p_organization_id uuid,
  p_email text
)
returns public.customers
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_profile_id uuid;
  v_customer public.customers;
begin
  if not public.has_org_permission(p_organization_id, 'MANAGE_CUSTOMERS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select id into v_profile_id from auth.users where lower(email) = lower(trim(p_email));
  if v_profile_id is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers
    where organization_id = p_organization_id and profile_id = v_profile_id;

  if found then
    if not v_customer.is_active then
      update public.customers
        set is_active = true, cancelled_at = null, cancelled_by = null, cancellation_reason = null
        where id = v_customer.id
        returning * into v_customer;
    end if;
    return v_customer;
  end if;

  insert into public.customers (organization_id, profile_id, created_by)
  values (p_organization_id, v_profile_id, auth.uid())
  returning * into v_customer;

  return v_customer;
end;
$BODY$;

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

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_hash := extensions.digest(v_token, 'sha256');
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

create or replace function public.revoke_customer_activation(p_activation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_act public.customer_activations;
begin
  select * into v_act from public.customer_activations where id = p_activation_id;
  if not found then
    return;
  end if;

  if not public.has_org_permission(v_act.organization_id, 'MANAGE_CUSTOMERS') then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_act.redeemed_at is not null or v_act.revoked_at is not null then
    return;
  end if;

  update public.customer_activations
    set revoked_at = now(), revoked_by = auth.uid()
    where id = p_activation_id;
end;
$BODY$;

notify pgrst, 'reload schema';
