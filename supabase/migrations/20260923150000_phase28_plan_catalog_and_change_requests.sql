-- ============================================================
-- Phase 28 -- catálogo de planes visible al cliente + solicitud de cambio
-- ============================================================
-- Feedback de producción: "si excedo frecuencia de plan, ofrecer upgrade/
-- downgrade de planes y redireccionar a planes". Hoy un rechazo
-- OVER_PLAN_QUOTA / OUTSIDE_PLAN_QUOTA sólo ofrece "Ver mi plan"
-- (/me/servicios), que muestra el plan que ya tiene -- justo el que no le
-- alcanza. El único lugar donde existen los otros planes es
-- /org/:slug/plans, que es admin-only.
--
-- Esta migración NO toca el motor de reservas ni una sola línea de
-- evaluate_customer_booking() / evaluate_payment_coverage() /
-- assert_series_within_plan_quota(). La decisión de si alguien puede
-- reservar sigue exactamente donde ADR-0024/0029 la dejaron. Acá se agrega
-- (a) una lectura del catálogo y (b) una tabla de solicitudes que no
-- participa de ninguna evaluación de reserva ni de cobertura.
--
-- Alcance elegido (opción (a) del pedido): el cliente VE los planes y
-- PIDE el cambio; el mostrador lo confirma cobrando. El motivo no es
-- prudencia genérica sino ADR-0024 resolución 1: cambiar de plan a mitad
-- de período es VOID + recargar, o sea una operación de dinero. Sin cobro
-- online (ADR-0027, bloqueada por elección de pasarela) un "cambio
-- automático" tendría que crear cobertura que nadie cobró -- exactamente
-- el agujero que "pago != permiso" (ADR-0005/0013) existe para evitar.
-- Una solicitud, en cambio, no habilita nada por sí sola: es un hecho
-- accionable para el negocio, con el mismo patrón de lead que
-- platform_contact_requests (Phase 24), pero dentro del portal y con
-- identidad real (no hace falta rate limit por IP: el autor es un
-- Customer autenticado y el índice parcial de abajo impide duplicados).
--
-- Cuando el mostrador cobra el plan pedido, la solicitud se cierra sola
-- (trigger al final) -- si no, quedarían dos tareas para la misma venta y
-- la lista de pendientes envejecería hasta volverse ruido.

-- ============================================================
-- 1. public_service_plans() -- el catálogo, legible sin login
-- ============================================================
-- RPC y no una vista: hay que resolver applies_to_all_services contra los
-- servicios ACTIVOS (service_plan_covered_service_ids() ya lo hace, pero
-- está revocada de todos los roles a propósito -- ADR-0026 resolución 7)
-- y filtrar de la selección explícita cualquier servicio inactivo, que
-- services_public no muestra. Una vista con el union crudo filtraría de
-- más o de menos según quién pregunte.
--
-- Qué se expone: nombre, descripción, precio, moneda, tipo de plan,
-- frecuencia y qué servicios cubre. Nada de esto es privado -- es la
-- lista de precios que el negocio publica -- y `service_plans_select_public`
-- (Phase 22) ya deja leer los planes activos vía PostgREST a anon. Esta
-- función no amplía la superficie: la ordena y le agrega el conjunto
-- cubierto, que hoy el frontend tiene que armar con dos consultas.
--
-- Planes inactivos nunca salen: is_active es el interruptor de "esto está
-- a la venta". Desactivar un plan sigue sin cortarle la cobertura a quien
-- ya pagó (ADR-0024 §6.d) -- son dos preguntas distintas y esta función
-- responde sólo la primera.

create or replace function public.public_service_plans(
  p_organization_slug text,
  p_service_id uuid default null
)
returns table (
  plan_id uuid,
  name text,
  description text,
  price numeric,
  currency text,
  plan_kind public.service_plan_kind,
  weekly_quota int,
  quota_scope public.plan_quota_scope,
  billing_type public.billing_type,
  billing_cycle public.billing_cycle,
  applies_to_all_services boolean,
  sort_order int,
  service_ids uuid[],
  service_names text[]
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    sp.id,
    sp.name,
    sp.description,
    sp.price,
    o.currency,
    sp.plan_kind,
    sp.weekly_quota,
    sp.quota_scope,
    sp.billing_type,
    sp.billing_cycle,
    sp.applies_to_all_services,
    sp.sort_order,
    covered.ids,
    covered.names
  from public.organizations o
  join public.service_plans sp
    on sp.organization_id = o.id and sp.is_active
  join lateral (
    select
      coalesce(array_agg(s.id order by s.name), '{}'::uuid[]) as ids,
      coalesce(array_agg(s.name order by s.name), '{}'::text[]) as names
    from public.services s
    where s.organization_id = o.id
      and s.is_active
      and (
        sp.applies_to_all_services
        or exists (
          select 1 from public.service_plan_services sps
          where sps.service_plan_id = sp.id and sps.service_id = s.id
        )
      )
  ) covered on true
  where o.slug = p_organization_slug
    and o.is_active
    -- Un plan cuyos servicios están todos inactivos no es una oferta:
    -- sería una fila con precio y nada que reservar detrás.
    and cardinality(covered.ids) > 0
    and (p_service_id is null or p_service_id = any (covered.ids))
  order by sp.sort_order asc, sp.price asc, sp.name asc;
$BODY$;

comment on function public.public_service_plans(text, uuid) is
  'ADR-0024/ADR-0029: la lista de precios que una organización publica, con el conjunto de servicios activos que cada plan cubre ya resuelto (applies_to_all_services incluido). Pública por diseño -- mismo nivel de disclosure que service_plans_select_public, sin datos de ningún Customer. p_service_id filtra a los planes que cubren ese servicio.';

revoke execute on function public.public_service_plans(text, uuid) from public;
grant execute on function public.public_service_plans(text, uuid) to anon, authenticated;

-- ============================================================
-- 2. plan_change_requests -- la solicitud
-- ============================================================

create type public.plan_change_request_resolution as enum ('APPLIED', 'DISMISSED');

create table public.plan_change_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  -- ON DELETE RESTRICT igual que payments.service_plan_id: la solicitud
  -- tiene que poder explicar hacia atrás qué se pidió. Un plan no se
  -- borra nunca de todas formas (no hay policy de DELETE).
  service_plan_id uuid not null references public.service_plans (id) on delete restrict,
  -- El plan que lo cubría en el momento de pedir, resuelto en la base
  -- (nunca enviado por el caller). Es lo que convierte la fila en
  -- "upgrade" o "downgrade" a los ojos del mostrador. Null = no tenía
  -- ninguno vigente, que también es información.
  current_service_plan_id uuid references public.service_plans (id) on delete restrict,
  note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id),
  resolution public.plan_change_request_resolution,
  constraint plan_change_requests_note_length
    check (note is null or length(trim(note)) between 1 and 500),
  -- Mismo par nullable que cancelledAt/cancelledBy: nunca "resuelta" sin
  -- decir cómo, nunca un resultado sin fecha.
  constraint plan_change_requests_resolution_consistent check (
    (resolved_at is null and resolution is null and resolved_by is null)
    or (resolved_at is not null and resolution is not null)
  ),
  constraint plan_change_requests_plan_differs
    check (current_service_plan_id is null or current_service_plan_id <> service_plan_id)
);

comment on table public.plan_change_requests is
  'Pedido de un Customer para pasarse a otro ServicePlan. No habilita ni cubre nada: ninguna función de decisión de reserva la lee (ADR-0024 resolución 1 mantiene el cambio de plan como VOID + recargar, una operación de dinero del mostrador). Se escribe sólo vía request_plan_change() y se cierra vía resolve_plan_change_request() o sola al registrarse el pago del plan pedido.';
comment on column public.plan_change_requests.current_service_plan_id is
  'El plan vigente del cliente al momento de pedir, resuelto server-side con resolve_covering_service_plan() sobre los servicios que cubre el plan pedido. Nunca un parámetro del caller.';
comment on column public.plan_change_requests.resolution is
  'APPLIED: el mostrador cobró el plan nuevo (o lo marcó a mano). DISMISSED: se conversó y no se hace. Null = pendiente.';

-- Una sola solicitud pendiente por (cliente, plan): el doble click y el
-- "insisto" no son dos ventas.
create unique index plan_change_requests_one_pending_idx
  on public.plan_change_requests (customer_id, service_plan_id)
  where resolved_at is null;

-- Listado del mostrador: pendientes primero, por fecha.
create index plan_change_requests_organization_idx
  on public.plan_change_requests (organization_id, resolved_at, created_at desc);

-- Listado del cliente y el cierre automático por pago.
create index plan_change_requests_customer_idx
  on public.plan_change_requests (customer_id, created_at desc);

-- Integridad cruzada: el Customer y el plan tienen que ser de la misma
-- organización que la fila. Hoy sólo escribe request_plan_change(), que
-- deriva las tres cosas del mismo lugar -- esto es la red, no el camino.
create or replace function public.check_plan_change_request_same_org()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if not exists (
    select 1 from public.customers c
    where c.id = new.customer_id and c.organization_id = new.organization_id
  ) then
    raise exception 'PLAN_CHANGE_REQUEST_CUSTOMER_ORG_MISMATCH';
  end if;

  if not exists (
    select 1 from public.service_plans sp
    where sp.id = new.service_plan_id and sp.organization_id = new.organization_id
  ) then
    raise exception 'PLAN_CHANGE_REQUEST_PLAN_ORG_MISMATCH';
  end if;

  if new.current_service_plan_id is not null and not exists (
    select 1 from public.service_plans sp
    where sp.id = new.current_service_plan_id and sp.organization_id = new.organization_id
  ) then
    raise exception 'PLAN_CHANGE_REQUEST_PLAN_ORG_MISMATCH';
  end if;

  return new;
end;
$BODY$;

-- `update of <columnas>` y no `update` a secas, por seguridad y no por
-- rendimiento: el trigger `payments_close_plan_change_request` (sección 7)
-- hace un UPDATE de esta tabla **dentro de la transacción de un INSERT en
-- payments**, así que cualquier `raise` alcanzable desde un BEFORE UPDATE
-- de acá puede abortar el registro de un pago real. Verificado en base
-- local: con la fila apuntando a otra organización, el UPDATE de
-- resolución falla con PLAN_CHANGE_REQUEST_CUSTOMER_ORG_MISMATCH, y ese
-- error sube hasta el INSERT del pago. Acotado a las cuatro columnas que
-- el chequeo realmente mira, el UPDATE de resolución
-- (resolved_at/resolved_by/resolution) ni siquiera dispara el trigger, y
-- la integridad que protege queda igual de cubierta: son las únicas
-- columnas que pueden romperla.
create trigger plan_change_requests_same_org
  before insert
      or update of organization_id, customer_id, service_plan_id, current_service_plan_id
  on public.plan_change_requests
  for each row execute function public.check_plan_change_request_same_org();

-- RLS de dos capas (ADR-0006): el cliente ve las suyas, el negocio ve las
-- de su organización. Cero policies de escritura a propósito -- cada fila
-- nace y se cierra por una RPC SECURITY DEFINER, igual que makeup_credits.
alter table public.plan_change_requests enable row level security;

create policy plan_change_requests_select_self_or_staff
  on public.plan_change_requests for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = plan_change_requests.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );

grant select on public.plan_change_requests to authenticated;

-- ============================================================
-- 3. request_plan_change() -- CUSTOMER
-- ============================================================
-- Nunca recibe un customer_id (ADR-0005): resuelve el Customer desde
-- auth.uid() y la organización del plan pedido. Un caller no puede pedir
-- un cambio en nombre de otro ni siquiera equivocándose.

create or replace function public.request_plan_change(
  p_service_plan_id uuid,
  p_note text default null
)
returns public.plan_change_requests
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_plan public.service_plans;
  v_org public.organizations;
  v_customer public.customers;
  v_note text;
  v_today date;
  v_service_id uuid;
  v_current public.service_plans;
  v_current_id uuid;
  v_pending int;
  v_row public.plan_change_requests;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_plan from public.service_plans where id = p_service_plan_id;
  if not found or not v_plan.is_active then
    -- Un plan desactivado ya no está a la venta: pedirlo no es un error
    -- del cliente, pero tampoco algo que el mostrador pueda cobrar.
    raise exception 'SERVICE_PLAN_NOT_AVAILABLE';
  end if;

  select * into v_org from public.organizations where id = v_plan.organization_id;
  if not found or not v_org.is_active then
    raise exception 'ORGANIZATION_INACTIVE';
  end if;

  select * into v_customer
    from public.customers
    where organization_id = v_plan.organization_id
      and profile_id = auth.uid()
      and is_active;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  v_note := nullif(trim(coalesce(p_note, '')), '');
  if v_note is not null and length(v_note) > 500 then
    raise exception 'NOTE_TOO_LONG';
  end if;

  -- El plan vigente hoy, en la fecha local de la organización (ADR-0014):
  -- a las 22:00 en Montevideo ya es mañana en UTC, y a fin de mes eso
  -- resuelve el período equivocado. Se busca sobre los servicios que
  -- cubre el plan pedido, que es exactamente el conjunto donde el cambio
  -- tendría efecto.
  v_today := (now() at time zone v_org.timezone)::date;
  for v_service_id in select public.service_plan_covered_service_ids(v_plan.id) loop
    v_current := public.resolve_covering_service_plan(v_customer.id, v_service_id, v_today);
    if v_current.id is not null then
      v_current_id := v_current.id;
      exit;
    end if;
  end loop;

  if v_current_id = p_service_plan_id then
    raise exception 'ALREADY_ON_PLAN';
  end if;

  -- Serializa el chequeo-y-escritura de abajo por cliente. El índice
  -- parcial ya impide el duplicado exacto; esto es para que el tope de
  -- pendientes no se pueda correr con dos requests simultáneos, mismo
  -- patrón que submit_platform_contact_request() (Phase 24).
  perform pg_advisory_xact_lock(hashtext('plan_change_request:' || v_customer.id::text));

  select id into v_row.id
    from public.plan_change_requests
    where customer_id = v_customer.id
      and service_plan_id = p_service_plan_id
      and resolved_at is null;
  if v_row.id is not null then
    -- Idempotente: volver a pedir lo mismo devuelve la solicitud que ya
    -- está esperando, en vez de un error por un doble click.
    select * into v_row from public.plan_change_requests where id = v_row.id;
    return v_row;
  end if;

  select count(*) into v_pending
    from public.plan_change_requests
    where customer_id = v_customer.id and resolved_at is null;
  if v_pending >= 5 then
    raise exception 'TOO_MANY_PENDING_PLAN_CHANGE_REQUESTS';
  end if;

  insert into public.plan_change_requests (
    organization_id, customer_id, service_plan_id, current_service_plan_id, note
  )
  values (v_plan.organization_id, v_customer.id, p_service_plan_id, v_current_id, v_note)
  returning * into v_row;

  return v_row;
end;
$BODY$;

comment on function public.request_plan_change(uuid, text) is
  'CUSTOMER: "quiero pasarme a este plan". Resuelve el Customer desde auth.uid() (ADR-0005), guarda el plan vigente resuelto en la base, y no habilita nada -- el cambio real sigue siendo VOID + recargar del mostrador (ADR-0024 resolución 1). Idempotente ante un pedido pendiente idéntico.';

revoke execute on function public.request_plan_change(uuid, text) from public, anon;
grant execute on function public.request_plan_change(uuid, text) to authenticated;

-- ============================================================
-- 4. my_plan_change_requests() -- CUSTOMER
-- ============================================================
-- Sin esto el botón es un agujero negro: el cliente pide el cambio y la
-- pantalla no puede decirle que ya lo pidió.

create or replace function public.my_plan_change_requests()
returns table (
  request_id uuid,
  organization_slug text,
  organization_name text,
  plan_id uuid,
  plan_name text,
  plan_price numeric,
  plan_kind public.service_plan_kind,
  weekly_quota int,
  currency text,
  current_plan_name text,
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
    o.slug,
    o.name,
    sp.id,
    sp.name,
    sp.price,
    sp.plan_kind,
    sp.weekly_quota,
    o.currency,
    cur.name,
    r.note,
    r.created_at,
    r.resolution,
    r.resolved_at
  from public.plan_change_requests r
  join public.customers c on c.id = r.customer_id
  join public.organizations o on o.id = r.organization_id
  join public.service_plans sp on sp.id = r.service_plan_id
  left join public.service_plans cur on cur.id = r.current_service_plan_id
  where c.profile_id = auth.uid()
  order by r.resolved_at nulls first, r.created_at desc;
$BODY$;

comment on function public.my_plan_change_requests() is
  'Las solicitudes de cambio de plan del propio cliente, pendientes primero. Sólo lectura de lo que él mismo pidió.';

revoke execute on function public.my_plan_change_requests() from public, anon;
grant execute on function public.my_plan_change_requests() to authenticated;

-- ============================================================
-- 5. organization_plan_change_requests() -- ADMIN
-- ============================================================

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
    and public.is_organization_member(p_organization_id)
    and (p_include_resolved or r.resolved_at is null)
  order by r.resolved_at nulls first, r.created_at desc;
$BODY$;

comment on function public.organization_plan_change_requests(uuid, boolean) is
  'ADMIN: los pedidos de cambio de plan de la organización, con el plan vigente al lado del pedido para que el mostrador vea si es upgrade o downgrade. is_organization_member() adentro del WHERE: un no-miembro recibe lista vacía, no la de otro.';

revoke execute on function public.organization_plan_change_requests(uuid, boolean) from public, anon;
grant execute on function public.organization_plan_change_requests(uuid, boolean) to authenticated;

-- ============================================================
-- 6. resolve_plan_change_request() -- ADMIN
-- ============================================================

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

  -- Cerrar un pedido es trabajo de mostrador, no de dueño: es la misma
  -- gente que cobra. Poner precios sigue siendo OWNER-only en
  -- service_plans, y esto no cambia ningún precio.
  if not public.is_organization_member(v_row.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if v_row.resolved_at is not null then
    -- Idempotente: no se pisa quién ni cuándo la cerró.
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

comment on function public.resolve_plan_change_request(uuid, public.plan_change_request_resolution) is
  'ADMIN: cierra un pedido de cambio de plan (APPLIED cuando ya se cobró el plan nuevo, DISMISSED cuando se habló y no va). No mueve dinero ni cobertura -- eso sigue siendo el pago (ADR-0024 resolución 1).';

revoke execute on function public.resolve_plan_change_request(uuid, public.plan_change_request_resolution)
  from public, anon;
grant execute on function public.resolve_plan_change_request(uuid, public.plan_change_request_resolution)
  to authenticated;

-- ============================================================
-- 7. El pago del plan pedido cierra el pedido
-- ============================================================
-- Sin esto, vender el plan nuevo deja igual el pedido abierto y la lista
-- de pendientes se llena de trabajo ya hecho -- el mostrador dejaría de
-- mirarla en una semana.
--
-- AFTER INSERT y sólo UPDATE sobre plan_change_requests: no valida nada
-- del pago, no puede rechazarlo y no participa de ninguna decisión de
-- cobertura. Un pago VOID no cierra nada (no vendió nada). El WHERE
-- exige pendiente, así que re-cobrar el mismo plan más adelante no pisa
-- una resolución anterior.

create or replace function public.close_plan_change_request_on_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $BODY$
begin
  if new.service_plan_id is null or new.status = 'VOID' then
    return new;
  end if;

  update public.plan_change_requests
    set resolved_at = now(),
        resolved_by = coalesce(new.created_by, auth.uid()),
        resolution = 'APPLIED'
    where customer_id = new.customer_id
      and service_plan_id = new.service_plan_id
      and resolved_at is null;

  return new;
end;
$BODY$;

create trigger payments_close_plan_change_request
  after insert on public.payments
  for each row execute function public.close_plan_change_request_on_payment();

comment on function public.close_plan_change_request_on_payment() is
  'Cierra como APPLIED el pedido pendiente de ese (cliente, plan) cuando el mostrador registra el pago del plan pedido -- ADR-0024 resolución 1 (VOID + recargar) es justo la forma que tiene el cambio real. Sólo escribe en plan_change_requests: no puede rechazar el pago ni alterar su cobertura.';

notify pgrst, 'reload schema';
