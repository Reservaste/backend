-- ============================================================
-- Phase 30 -- audit_log (ADR-0032, Aceptada)
-- ============================================================
-- Hoy el sistema conserva *estados*, no *hechos*: un Payment anulado dice
-- que está VOID pero no quién lo anuló; una reserva creada por el
-- mostrador guarda created_by y nada más; organizations.subscription_status
-- cambia sin rastro; y un cambio de PRECIO de un ServicePlan (libre por
-- ADR-0024 resolución 5) no deja absolutamente nada.
--
-- El hallazgo que decide el diseño (verificado en el código, no supuesto):
-- la mitad de las escrituras del alcance NO pasan por ninguna RPC --
-- el alta de pago (`INSERT payments` de PostgREST), la anulación
-- (`UPDATE payments SET status='VOID'`) y los dos updates de plan
-- (precio/nombre y activar/desactivar) son escrituras directas desde
-- `frontend/app/actions/billing.ts` y `service-plans.ts`. Un insert
-- explícito de auditoría dentro de cada RPC dejaría afuera justo eso, o
-- sea la mayoría de lo que se pidió auditar. Por eso el hecho lo escribe
-- un TRIGGER (no evadible: si la fila cambió, la auditoría existe) y la
-- RPC sólo puede agregar *intención* opcional vía
-- set_config('app.audit_note', ..., true).
--
-- Alcance cerrado por el ADR (no ampliar "de paso"): pagos (alta y cambio
-- de estado, incluida la anulación), reservas de mostrador (alta y
-- cancelación cuando el actor NO es el propio cliente), planes (alta,
-- precio/nombre/orden, activar/desactivar) y suscripción SaaS de la
-- organización. Fuera: asistencia (alto volumen), créditos de recupero
-- (makeup_credits YA es su propio log), acciones del propio cliente,
-- altas de cliente/servicio/horario/branding, logins y lecturas.
--
-- Mapa "qué acción registra qué trigger" -> `docs/database.md`, sección
-- Fase 30. Es a propósito que esa tabla viva en un documento y no haya
-- que leer ocho funciones para contestar "¿esto se audita?".

-- ============================================================
-- 1. Enum de acciones
-- ============================================================
-- Enum y no texto libre: un texto libre convierte cada consulta en un
-- `like` y cada typo en una fila que no se encuentra nunca. Ocho valores;
-- agregar uno es una migración de una línea.

create type public.audit_action as enum (
  'PAYMENT_CREATED',
  'PAYMENT_STATUS_CHANGED',            -- incluye la anulación (VOID)
  'BOOKING_CREATED_BY_STAFF',
  'BOOKING_CANCELLED_BY_STAFF',
  'SERVICE_PLAN_CREATED',
  'SERVICE_PLAN_UPDATED',              -- precio, nombre, orden
  'SERVICE_PLAN_DEACTIVATED',          -- y su inverso: metadata dice from/to
  'ORGANIZATION_SUBSCRIPTION_CHANGED'
);

-- ============================================================
-- 2. La tabla
-- ============================================================

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  -- Nullable: una acción de plataforma la hace alguien que no es miembro
  -- de la organización. Igual se completa en todos los casos del alcance
  -- actual -- los ocho tienen organización.
  organization_id uuid references public.organizations (id) on delete cascade,
  -- auth.uid() del momento. NULL = lo hizo el sistema (job/cron de
  -- ADR-0009/ADR-0019), que es información: escribir un UUID sintético de
  -- "sistema" sería una mentira con forma de dato.
  actor_id uuid references public.profiles (id),
  action public.audit_action not null,
  -- target_table + target_id en vez de cuatro FK nullables: "una de estas
  -- cuatro" en cuatro columnas no se consulta uniformemente y tres siempre
  -- están vacías. Se acepta no tener integridad referencial sobre el
  -- target A PROPÓSITO: un log de auditoría tiene que sobrevivir al
  -- borrado de lo que audita, y una FK con cascade borraría justo la
  -- evidencia.
  target_table text not null,
  target_id uuid not null,
  -- Sólo el diff mínimo, nunca la fila entera y nunca datos personales
  -- (nombres, mails, teléfonos): esos viven en sus tablas con su RLS y
  -- copiarlos acá los saca de ese control. El diff lo arma una función
  -- por tabla, jamás un to_jsonb(new) genérico.
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Sin updated_at ni cancelled_at: una fila de auditoría es inmutable por
-- definición, y darle columnas de ciclo de vida invita a editarla.

comment on table public.audit_log is
  'ADR-0032: hechos sensibles (pagos, reservas de mostrador, planes, suscripción). Inmutable: nace sólo desde triggers SECURITY DEFINER, no se actualiza ni se borra. Lee is_platform_admin() (todo) y el OWNER (su organización).';

comment on column public.audit_log.actor_id is
  'auth.uid() del momento. NULL = sistema (job/cron) o un uid sin profile -- la auditoría nunca hace fallar la escritura de negocio que la disparó.';

comment on column public.audit_log.metadata is
  'Diff mínimo ({"status":{"from":"PENDING","to":"VOID"}}). Nunca la fila entera ni datos personales. Puede traer "note" si la RPC seteó app.audit_note.';

-- Índice de la pantalla (y el que un borrado por retención necesitaría:
-- ADR-0032 resolución 3 no define retención todavía, pero el índice queda
-- listo para no tener que agregarlo sobre una tabla ya grande).
create index audit_log_org_time_idx on public.audit_log (organization_id, created_at desc);
-- "¿Qué pasó con ESTE pago / ESTA reserva?"
create index audit_log_target_idx on public.audit_log (target_table, target_id, created_at desc);

-- ============================================================
-- 3. Inmutabilidad -- es la mitad del valor
-- ============================================================
-- Un log que el auditado puede editar no es un log. Mismo patrón que
-- makeup_credits (Fase 20) y plan_change_requests (Fase 28), reforzado:
-- RLS habilitada, CERO policies de escritura para ningún rol, grants de
-- escritura revocados, y un trigger que rechaza UPDATE/DELETE incluso
-- bajo un SECURITY DEFINER futuro.

alter table public.audit_log enable row level security;

revoke insert, update, delete on public.audit_log from anon, authenticated;
-- anon no lee auditoría ni con policy: la policy de abajo ya lo excluye,
-- esto lo saca también de la superficie de PostgREST.
revoke select on public.audit_log from anon;

-- ADR-0032 resolución 1 y 2: la plataforma ve todo; el OWNER ve el log de
-- su organización -- incluidas las filas de
-- ORGANIZATION_SUBSCRIPTION_CHANGED (una suspensión que el dueño no puede
-- rastrear genera desconfianza). STAFF no ve nada: es el sujeto
-- mayoritario del log. El matiz de la resolución 2 -- que la identidad del
-- actor de plataforma no se resuelva a un nombre en la UI del cliente --
-- lo implementa organization_audit_log() (§8), que es lo que consume el
-- frontend; el dato crudo de la tabla queda como está (un UUID que la RLS
-- de `profiles` no deja resolver a nombre igual).
create policy audit_log_select on public.audit_log for select using (
  public.is_platform_admin()
  or (organization_id is not null and public.is_organization_owner(organization_id))
);

create or replace function public.reject_audit_log_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'AUDIT_LOG_IMMUTABLE';
end;
$$;

comment on function public.reject_audit_log_mutation() is
  'ADR-0032 §5: audit_log no se edita ni se borra. service_role NO se exceptúa -- corregir algo exige un superusuario desactivando el trigger, operación que queda registrada fuera del producto, que es exactamente lo que corresponde.';

create trigger audit_log_immutable
  before update or delete on public.audit_log
  for each row execute function public.reject_audit_log_mutation();

create trigger audit_log_immutable_truncate
  before truncate on public.audit_log
  for each statement execute function public.reject_audit_log_mutation();

-- Consecuencia conocida y aceptada: `organization_id` es `on delete
-- cascade`, así que borrar una organización a mano dispara este trigger y
-- falla con AUDIT_LOG_IMMUTABLE. Hoy ninguna policy permite borrar una
-- organización (no existe policy de DELETE sobre `organizations`), así que
-- no rompe ningún camino del producto; si algún día hace falta, es un
-- `alter table public.audit_log disable trigger audit_log_immutable` en
-- una sesión de superusuario, deliberado y fuera de banda -- no algo que
-- una server action pueda hacer.
-- Misma familia de consecuencia en actor_id (FK sin acción de borrado,
-- igual que payments.created_by / bookings.cancelled_by desde la Fase 5):
-- borrar un `auth.users` que dejó filas de auditoría falla. Ya pasaba
-- antes de esta migración por esas otras FK; no es nuevo.

-- ============================================================
-- 4. El escritor único
-- ============================================================
-- Un solo punto de inserción: resuelve el actor, levanta la nota opcional
-- de la transacción y escribe. Los cuatro triggers sólo deciden QUÉ
-- acción y QUÉ diff.

create or replace function public.audit_write(
  p_organization_id uuid,
  p_action public.audit_action,
  p_target_table text,
  p_target_id uuid,
  p_metadata jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_note text;
  v_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
begin
  -- actor_id es FK a profiles. Si el uid de la sesión no tiene perfil (no
  -- debería pasar: el trigger de alta lo crea), se registra el hecho con
  -- actor nulo en vez de hacer fallar la escritura de negocio: la
  -- auditoría nunca puede ser el motivo por el que un pago no entra.
  if v_actor is not null
     and not exists (select 1 from public.profiles where id = v_actor) then
    v_actor := null;
  end if;

  -- Contexto opcional desde la RPC (ADR-0032 §3). Local a la transacción,
  -- así que no se filtra a la siguiente. Si nadie la setea, la fila se
  -- escribe igual: el contexto es opcional, el hecho no.
  v_note := nullif(btrim(coalesce(current_setting('app.audit_note', true), '')), '');
  if v_note is not null then
    v_metadata := v_metadata || jsonb_build_object('note', left(v_note, 500));
  end if;

  insert into public.audit_log (
    organization_id, actor_id, action, target_table, target_id, metadata
  ) values (
    p_organization_id, v_actor, p_action, p_target_table, p_target_id, v_metadata
  );
end;
$$;

comment on function public.audit_write(uuid, public.audit_action, text, uuid, jsonb) is
  'ADR-0032: único punto de escritura de audit_log. SECURITY DEFINER porque la tabla no tiene policies de escritura. Helper interno: revocado de todos los roles (ADR-0028).';

-- Helper interno (sólo lo llaman funciones SECURITY DEFINER): adentro de
-- un definer los privilegios se chequean contra el dueño, así que
-- revocarlo no cuesta nada y lo saca de la API (regla de la Fase 19).
revoke execute on function public.audit_write(uuid, public.audit_action, text, uuid, jsonb)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 5. payments
-- ============================================================

create or replace function public.audit_payment_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- Monto, estado, plan y período: lo que el mostrador necesita para
    -- reconocer el pago. Ningún dato personal -- customer_id es un id,
    -- el nombre vive en `customers` con su RLS.
    perform public.audit_write(
      new.organization_id,
      'PAYMENT_CREATED',
      'payments',
      new.id,
      jsonb_build_object(
        'customer_id', new.customer_id,
        'service_plan_id', new.service_plan_id,
        'status', new.status,
        'amount', new.amount,
        'period_start', new.period_start,
        'period_end', new.period_end
      )
    );
  else
    perform public.audit_write(
      new.organization_id,
      'PAYMENT_STATUS_CHANGED',
      'payments',
      new.id,
      jsonb_build_object(
        'customer_id', new.customer_id,
        'status', jsonb_build_object('from', old.status, 'to', new.status)
      )
    );
  end if;

  return null;
end;
$$;

-- Dos triggers y no uno con `insert or update`: Postgres rechaza
-- (SQLSTATE 42P17) un WHEN que referencia OLD en un trigger cuyo conjunto
-- de eventos incluye INSERT -- ya documentado en la Fase 25, Fix 2.
create trigger payments_audit_insert
  after insert on public.payments
  for each row execute function public.audit_payment_row();

create trigger payments_audit_status
  after update on public.payments
  for each row
  when (old.status is distinct from new.status)
  execute function public.audit_payment_row();

comment on trigger payments_audit_insert on public.payments is
  'ADR-0032: registra PAYMENT_CREATED. El alta de pago es un INSERT de PostgREST (frontend/app/actions/billing.ts), no una RPC -- por eso se audita acá y no dentro de una función.';

comment on trigger payments_audit_status on public.payments is
  'ADR-0032: registra PAYMENT_STATUS_CHANGED, incluida la anulación (VOID), venga de set_payment_status() o de un UPDATE directo de PostgREST.';

-- ============================================================
-- 6. bookings
-- ============================================================
-- "Por staff, no por el propio cliente" se evalúa comparando auth.uid()
-- contra customers.profile_id. Se escribe `is distinct from`, NUNCA `<>`:
-- con un cliente gestionado (ADR-0026) profile_id es NULL, y
-- `auth.uid() <> profile_id` da NULL -- un `if` con NULL no entra, así que
-- la reserva que por definición hizo el mostrador quedaría sin auditar.
-- Es el mismo error de lógica de tres valores que la Fase 19 encontró en
-- cancel_booking(), donde saltaba la autorización entera.

create or replace function public.audit_booking_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_profile_id uuid;
begin
  select c.profile_id into v_profile_id
  from public.customers c
  where c.id = new.customer_id;

  -- Lo hizo el propio cliente: fuera de alcance (ADR-0032 §7).
  if v_profile_id is not distinct from v_actor then
    return null;
  end if;

  if tg_op = 'INSERT' then
    -- Sin sesión, un INSERT de reserva es el job de horizonte (ADR-0009)
    -- materializando una serie que alguien ya acordó: no es una decisión
    -- nueva de nadie y multiplicaría el volumen del log por dos órdenes
    -- de magnitud. Una CANCELACIÓN sin sesión sí se registra (abajo): es
    -- una decisión que nadie reclama, justo lo que hay que poder rastrear.
    if v_actor is null then
      return null;
    end if;

    perform public.audit_write(
      new.organization_id,
      'BOOKING_CREATED_BY_STAFF',
      'bookings',
      new.id,
      jsonb_build_object(
        'customer_id', new.customer_id,
        'slot_occurrence_id', new.slot_occurrence_id,
        'status', new.status
      )
    );
  else
    perform public.audit_write(
      new.organization_id,
      'BOOKING_CANCELLED_BY_STAFF',
      'bookings',
      new.id,
      jsonb_build_object(
        'customer_id', new.customer_id,
        'slot_occurrence_id', new.slot_occurrence_id,
        'status', jsonb_build_object('from', old.status, 'to', new.status),
        'cancellation_reason', new.cancellation_reason
      )
    );
  end if;

  return null;
end;
$$;

-- `recurring_booking_id is null` en el WHEN: las fechas de una serie las
-- materializa generate_recurring_booking() (una por semana, por serie, por
-- cliente) y son consecuencia de la serie, no un alta de mostrador --
-- además no hay valor de enum que las describa. El alta de la serie en sí
-- tiene su propio estado en `recurring_bookings` (created_by, status).
-- La CANCELACIÓN de una fecha de serie sí se audita: ADR-0032 §7 nombra
-- explícitamente cancel_slot_occurrence() y discontinue_schedule_rule().
create trigger bookings_audit_insert
  after insert on public.bookings
  for each row
  when (new.recurring_booking_id is null)
  execute function public.audit_booking_row();

create trigger bookings_audit_cancel
  after update on public.bookings
  for each row
  when (old.status is distinct from new.status and new.status = 'CANCELLED')
  execute function public.audit_booking_row();

comment on trigger bookings_audit_insert on public.bookings is
  'ADR-0032: registra BOOKING_CREATED_BY_STAFF cuando el actor no es el profile_id del Customer (admin_book_for_customer). Excluye fechas de serie y el job sin sesión.';

comment on trigger bookings_audit_cancel on public.bookings is
  'ADR-0032: registra BOOKING_CANCELLED_BY_STAFF cuando el actor no es el profile_id del Customer (cancel_booking por staff, cancel_slot_occurrence, discontinue_schedule_rule, cascada de serie). La cancelación del propio cliente NO se registra.';

-- ============================================================
-- 7. service_plans y organizations
-- ============================================================

create or replace function public.audit_service_plan_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_diff jsonb := '{}'::jsonb;
begin
  if tg_op = 'INSERT' then
    perform public.audit_write(
      new.organization_id,
      'SERVICE_PLAN_CREATED',
      'service_plans',
      new.id,
      jsonb_build_object(
        'name', new.name,
        'price', new.price,
        'plan_kind', new.plan_kind,
        'weekly_quota', new.weekly_quota,
        'is_active', new.is_active
      )
    );
    return null;
  end if;

  -- El precio es el caso que motivó el pedido: "salía 2500 y ahora 3400,
  -- ¿desde cuándo y quién?". ADR-0024 resolución 5 lo deja cambiar libre
  -- (plan_kind y weekly_quota, en cambio, son inmutables con pagos vivos
  -- por trigger de la Fase 17), así que el rastro es todo lo que hay.
  if old.name is distinct from new.name then
    v_diff := v_diff || jsonb_build_object('name', jsonb_build_object('from', old.name, 'to', new.name));
  end if;
  if old.price is distinct from new.price then
    v_diff := v_diff || jsonb_build_object('price', jsonb_build_object('from', old.price, 'to', new.price));
  end if;
  if old.sort_order is distinct from new.sort_order then
    v_diff := v_diff || jsonb_build_object('sort_order', jsonb_build_object('from', old.sort_order, 'to', new.sort_order));
  end if;

  if v_diff <> '{}'::jsonb then
    perform public.audit_write(
      new.organization_id, 'SERVICE_PLAN_UPDATED', 'service_plans', new.id, v_diff
    );
  end if;

  -- Fila aparte, no un campo más del diff: "dejó de estar a la venta" es
  -- una decisión distinta de "cambió de precio", y una UPDATE que hace las
  -- dos cosas son dos hechos. El enum tiene un solo valor
  -- (SERVICE_PLAN_DEACTIVATED) y el metadata dice from/to, así que la
  -- reactivación se distingue sin agregar un noveno valor.
  if old.is_active is distinct from new.is_active then
    perform public.audit_write(
      new.organization_id,
      'SERVICE_PLAN_DEACTIVATED',
      'service_plans',
      new.id,
      jsonb_build_object('is_active', jsonb_build_object('from', old.is_active, 'to', new.is_active))
    );
  end if;

  return null;
end;
$$;

create trigger service_plans_audit_insert
  after insert on public.service_plans
  for each row execute function public.audit_service_plan_row();

create trigger service_plans_audit_update
  after update on public.service_plans
  for each row
  when (
    old.name is distinct from new.name
    or old.price is distinct from new.price
    or old.sort_order is distinct from new.sort_order
    or old.is_active is distinct from new.is_active
  )
  execute function public.audit_service_plan_row();

comment on trigger service_plans_audit_insert on public.service_plans is
  'ADR-0032: registra SERVICE_PLAN_CREATED (create_service_plan()).';

comment on trigger service_plans_audit_update on public.service_plans is
  'ADR-0032: registra SERVICE_PLAN_UPDATED (precio/nombre/orden) y SERVICE_PLAN_DEACTIVATED (is_active). Los dos updates de plan son UPDATE de PostgREST (frontend/app/actions/service-plans.ts), no RPCs.';

create or replace function public.audit_organization_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_diff jsonb := '{}'::jsonb;
begin
  if old.subscription_status is distinct from new.subscription_status then
    v_diff := v_diff || jsonb_build_object(
      'subscription_status', jsonb_build_object('from', old.subscription_status, 'to', new.subscription_status)
    );
  end if;
  if old.plan_code is distinct from new.plan_code then
    v_diff := v_diff || jsonb_build_object(
      'plan_code', jsonb_build_object('from', old.plan_code, 'to', new.plan_code)
    );
  end if;

  perform public.audit_write(
    new.id, 'ORGANIZATION_SUBSCRIPTION_CHANGED', 'organizations', new.id, v_diff
  );

  return null;
end;
$$;

create trigger organizations_audit_subscription
  after update on public.organizations
  for each row
  when (
    old.subscription_status is distinct from new.subscription_status
    or old.plan_code is distinct from new.plan_code
  )
  execute function public.audit_organization_row();

comment on trigger organizations_audit_subscription on public.organizations is
  'ADR-0032: registra ORGANIZATION_SUBSCRIPTION_CHANGED (set_organization_subscription()). El OWNER la ve; la identidad del actor de plataforma no se le resuelve a nombre (organization_audit_log()).';

-- Los helpers de trigger conservan el grant PUBLIC inerte que Postgres les
-- da: una función de trigger no es invocable por PostgREST (no hay forma
-- de construir un TriggerData desde una llamada REST). Se dejan sin
-- revoke por consistencia con las ~20 funciones de trigger existentes
-- (hallazgo informativo de la Fase 25).

-- ============================================================
-- 8. Lectura para el OWNER (el matiz de la resolución 2)
-- ============================================================
-- La policy ya deja al OWNER leer la tabla por PostgREST, pero el ADR pide
-- que la identidad de un actor de PLATAFORMA no se resuelva a un nombre en
-- la UI del cliente. Esta función es lo que consume el frontend: no
-- joinea `profiles` para un actor que no es miembro de la organización y
-- devuelve `actor_is_platform = true` en su lugar. Para un platform admin
-- devuelve todo.

create or replace function public.organization_audit_log(
  p_organization_id uuid,
  p_limit int default 100,
  p_before timestamptz default null
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
  -- Chequeo explícito y no `where public.is_organization_owner(...)`: acá
  -- "no sos dueño" y "no hay nada registrado" tienen que distinguirse (la
  -- pantalla dice "registro desde tal fecha", no "no pasó nada").
  if not v_is_platform_admin and not public.is_organization_owner(p_organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  return query
  select
    a.id,
    a.action,
    a.target_table,
    a.target_id,
    -- El UUID tampoco se devuelve para un actor de plataforma: no aporta
    -- nada a la pantalla del cliente y es un identificador de una persona
    -- de nuestro lado.
    case when v_is_platform_admin or m.profile_id is not null then a.actor_id end,
    case
      when a.actor_id is null then null
      when v_is_platform_admin or m.profile_id is not null
        -- Mismo coalesce que el resto del panel (Fase 21, Hallazgo B).
        then coalesce(nullif(btrim(p.full_name), ''), 'Sin nombre')
    end,
    (a.actor_id is not null and m.profile_id is null and not v_is_platform_admin),
    a.metadata,
    a.created_at
  from public.audit_log a
  -- Sin filtrar por is_active: un STAFF dado de baja después sigue
  -- teniendo nombre, y sin esto sus acciones se leerían como "plataforma".
  left join public.organization_members m
    on m.organization_id = a.organization_id
   and m.profile_id = a.actor_id
  left join public.profiles p on p.id = a.actor_id
  where a.organization_id = p_organization_id
    and (p_before is null or a.created_at < p_before)
  order by a.created_at desc, a.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200);
end;
$$;

comment on function public.organization_audit_log(uuid, int, timestamptz) is
  'ADR-0032 resolución 1 y 2: el OWNER lee el log de su organización. El actor de plataforma no se resuelve a nombre ni a uuid (actor_is_platform = true). STAFF recibe NOT_AUTHORIZED.';

revoke execute on function public.organization_audit_log(uuid, int, timestamptz) from public, anon;
grant execute on function public.organization_audit_log(uuid, int, timestamptz) to authenticated;

-- ============================================================
-- 9. Un consumidor real del contexto opcional
-- ============================================================
-- `create or replace` (no drop+create): misma firma, así que conserva los
-- grants de la Fase 10 y los revoke de la Fase 19 sin re-declararlos.
-- Único cambio: setea app.audit_note. El trigger la levanta; si esta
-- función no existiera, la fila se escribiría igual sin nota.

create or replace function public.set_organization_subscription(
  p_organization_id uuid,
  p_plan_code text,
  p_status public.subscription_status,
  p_current_period_end timestamptz default null
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if not public.is_platform_admin() then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- ADR-0032 §3: intención que el trigger no puede deducir de la fila.
  -- `true` = local a la transacción, no se filtra a la siguiente.
  perform set_config('app.audit_note', 'PLATFORM_CONSOLE', true);

  update public.organizations
    set plan_code = p_plan_code,
        subscription_status = p_status,
        current_period_end = p_current_period_end
    where id = p_organization_id
    returning * into v_org;

  if not found then
    raise exception 'ORGANIZATION_NOT_FOUND';
  end if;

  return v_org;
end;
$$;
