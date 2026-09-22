-- Phase 20: MakeupCredit -- liberar un cupo a tiempo y recuperarlo (ADR-0025)
-- Ref: docs/decisions.md ADR-0025 (nueve resoluciones del Orchestrator +
-- cinco correcciones de encuadre), docs/proposals/adr-0025-makeup-credits.md.
--
-- Opt-in por organización (makeup_credits_enabled default false): nadie
-- cambia de comportamiento el día del deploy, mismo patrón que el
-- UNLIMITED de ADR-0024.
--
-- Alcance de esta migración (recortado explícitamente contra el reloj de
-- la demo, documentado en el reporte del agente): la emisión, el consumo
-- con su propio lock, la devolución, MANUAL, la agenda pública y el
-- portal quedan completos. quote_booking()/book_slot_paying() (el turno
-- suelto cobrado en el mismo hecho que la reserva) NO están en esta
-- migración -- es la pieza que la propia ADR marca como separable
-- (§2.8, resolución 8 pendiente de ADR-0027) y el motivo por el que
-- "sin cupo, pagás" hoy sigue resolviéndose por carga manual del ADMIN,
-- exactamente como antes de este ADR.
--
-- La corrección más importante que este archivo implementa (ADR-0025
-- §0.1): el FOR UPDATE de book_slot()/admin_book_for_customer() lockea la
-- fila de la ocurrencia, no al cliente. Dos ocurrencias distintas del
-- mismo cliente compitiendo por el mismo crédito son dos locks distintos
-- y cero conflicto entre sí -- el crédito necesita su propio candado, que
-- es la UPDATE condicional al final de cada función de reserva. Se toma
-- siempre *después* del de la ocurrencia, en todos los llamadores, para
-- no invertir el orden de los locks entre dos caminos.

-- ============================================================
-- 1. Tipos
-- ============================================================

create type public.makeup_credit_origin as enum ('CUSTOMER_RELEASE', 'ORGANIZATION_CANCELLED', 'MANUAL');
create type public.makeup_credit_status as enum ('AVAILABLE', 'CONSUMED', 'REVOKED');
-- END_OF_BILLING_PERIOD es la resolución 4 del Orchestrator: forzar todo
-- a mes calendario reintroduciría el desajuste que ADR-0022 evitó a
-- propósito soportando los dos ciclos de facturación.
create type public.makeup_credit_expiry_basis as enum ('END_OF_MONTH', 'END_OF_BILLING_PERIOD', 'DAYS_AFTER');

comment on type public.makeup_credit_origin is
  'CUSTOMER_RELEASE: el cliente liberó a tiempo. ORGANIZATION_CANCELLED: canceló la organización (sin exigir anticipación). MANUAL: cortesía del OWNER, auditada. Ref: ADR-0025.';

-- ============================================================
-- 2. La política, en Organization con override opcional en Service
-- ============================================================
-- Mismo precedente que public_availability_display (ADR-0008): default
-- en la organización, override nullable en el servicio, resuelto como
-- bloque (resolución del §2.2.1 de la propuesta) -- nunca columna por
-- columna, o un DAYS_AFTER con el N de otro modo queda posible.

alter table public.organizations
  add column if not exists makeup_credits_enabled boolean not null default false;

comment on column public.organizations.makeup_credits_enabled is
  'Opt-in del dueño (ADR-0025 resolución 3). false por defecto: nadie empieza a emitir créditos el día del deploy.';

alter table public.organizations
  add column if not exists release_deadline_hours int not null default 12;

alter table public.organizations
  add constraint organizations_release_deadline_hours_range
  check (release_deadline_hours between 0 and 720);

comment on constraint organizations_release_deadline_hours_range on public.organizations is
  'Tope de 30 dias (720h): una anticipacion mayor que el horizonte de reservas volveria imposible ganar un credito, sin que el dueno pudiera notarlo salvo por un reclamo (ADR-0025 S2.2, punto 3).';

alter table public.organizations
  add column if not exists makeup_credit_expiry public.makeup_credit_expiry_basis not null default 'END_OF_MONTH';

alter table public.organizations
  add column if not exists makeup_credit_expiry_days int;

alter table public.organizations
  add constraint organizations_makeup_credit_expiry_days_matches_basis
  check (makeup_credit_expiry_days is null or makeup_credit_expiry_days >= 1);

alter table public.services
  add column if not exists makeup_credits_enabled_override boolean;

alter table public.services
  add column if not exists release_deadline_hours_override int;

alter table public.services
  add constraint services_release_deadline_hours_override_range
  check (release_deadline_hours_override is null or release_deadline_hours_override between 0 and 720);

alter table public.services
  add column if not exists makeup_credit_expiry_override public.makeup_credit_expiry_basis;

alter table public.services
  add column if not exists makeup_credit_expiry_days_override int;

alter table public.services
  add constraint services_makeup_credit_expiry_days_override_range
  check (makeup_credit_expiry_days_override is null or makeup_credit_expiry_days_override >= 1);

-- Resuelve la política efectiva como UN bloque (nunca columna por
-- columna): si el servicio hace override del modo de vencimiento, se
-- usan modo Y días *del servicio*; si no, los dos de la organización.
-- Internal: sólo lo llaman otras funciones security definer.
create or replace function public.resolve_makeup_credits_policy(p_service_id uuid)
returns table (
  enabled boolean,
  deadline_hours int,
  expiry_basis public.makeup_credit_expiry_basis,
  expiry_days int
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    coalesce(s.makeup_credits_enabled_override, o.makeup_credits_enabled),
    coalesce(s.release_deadline_hours_override, o.release_deadline_hours),
    case when s.makeup_credit_expiry_override is not null then s.makeup_credit_expiry_override
         else o.makeup_credit_expiry end,
    case when s.makeup_credit_expiry_override is not null then s.makeup_credit_expiry_days_override
         else o.makeup_credit_expiry_days end
  from public.services s
  join public.organizations o on o.id = s.organization_id
  where s.id = p_service_id;
$BODY$;

revoke execute on function public.resolve_makeup_credits_policy(uuid)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 3. makeup_credits
-- ============================================================

create table public.makeup_credits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  -- Propio, no derivado de source_booking_id: MANUAL no tiene reserva de
  -- origen, y el servicio es el *alcance* del crédito, no un dato de su
  -- procedencia (mismo criterio que payments.service_id, ADR-0024).
  service_id uuid not null references public.services (id) on delete cascade,

  origin public.makeup_credit_origin not null,
  -- NULL exactamente cuando origin = 'MANUAL'. ON DELETE RESTRICT (no
  -- CASCADE): las ocurrencias se cancelan, nunca se borran, y borrar una
  -- que le costó un crédito a alguien tiene que fallar ruidosamente
  -- (mismo criterio que payments.slot_occurrence_id, Fase H).
  source_booking_id uuid references public.bookings (id) on delete restrict,
  issued_at timestamptz not null default now(),
  issued_by uuid references public.profiles (id),

  -- Congelado al emitir (decisión 2 del Orchestrator). No se recalcula
  -- nunca desde la política vigente -- ver el trigger de inmutabilidad.
  expires_on date not null,
  -- Auditoría únicamente: nada vuelve a leer estas dos columnas para
  -- calcular un vencimiento. Si alguna función lo hiciera, rompió la
  -- decisión 2 del Orchestrator.
  expiry_basis public.makeup_credit_expiry_basis not null,
  expiry_basis_days int,

  status public.makeup_credit_status not null default 'AVAILABLE',
  -- No se limpia al devolver un crédito CONSUMED -> AVAILABLE: conserva
  -- el rastro de en qué se usó, y el índice único parcial (más abajo)
  -- sólo se aplica sobre CONSUMED, así que puede volver a usarse.
  consumed_booking_id uuid references public.bookings (id) on delete restrict,
  consumed_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id),
  note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint makeup_credits_status_consumed_consistent check (
    (status = 'CONSUMED') = (consumed_booking_id is not null and consumed_at is not null)
  ),
  constraint makeup_credits_status_revoked_consistent check (
    (status = 'REVOKED') = (revoked_at is not null)
  ),
  constraint makeup_credits_manual_has_no_source check (
    (origin = 'MANUAL') = (source_booking_id is null)
  ),
  constraint makeup_credits_manual_requires_note check (
    origin <> 'MANUAL' or note is not null
  ),
  constraint makeup_credits_expiry_days_matches_basis check (
    (expiry_basis = 'DAYS_AFTER') = (expiry_basis_days is not null)
  )
);

comment on table public.makeup_credits is
  'El derecho a UNA reserva extra (ADR-0024) sobre un Service, ganado al liberar un cupo a tiempo o al cancelar la organizacion. NO es un paquete prepago: no se compra, no se recarga, no se vende, y su cantidad nunca supera la de reservas que el cliente efectivamente perdio (ADR-0025). RLS de solo SELECT: nace unicamente de una RPC.';

comment on column public.makeup_credits.expires_on is
  'Congelado al emitir, ANCLADO a la fecha local de la ocurrencia liberada (nunca a issued_at). Nunca se recalcula desde la politica vigente.';

comment on column public.makeup_credits.expiry_basis_days is
  'Copia de auditoria de la politica al momento de emitir. Nada vuelve a leerla para calcular expires_on -- si algo lo hace, rompio la decision 2 del Orchestrator.';

create trigger makeup_credits_set_updated_at
  before update on public.makeup_credits
  for each row execute function public.set_updated_at();

-- El invariante anti-inflación: una liberación ⇒ a lo sumo un crédito,
-- sin importar cuántas veces se llame a la emisión (issue_makeup_credit
-- es idempotente contra este índice, no contra un chequeo de aplicación).
create unique index makeup_credits_one_per_source_idx
  on public.makeup_credits (source_booking_id)
  where source_booking_id is not null;

-- Parcial sobre CONSUMED a propósito: un crédito devuelto conserva el
-- rastro de quién lo usó y aun así puede volver a consumirse.
create unique index makeup_credits_one_per_consumer_idx
  on public.makeup_credits (consumed_booking_id)
  where status = 'CONSUMED';

-- El camino caliente: se ejecuta dentro del lock de book_slot().
create index makeup_credits_usable_idx
  on public.makeup_credits (customer_id, service_id, expires_on)
  where status = 'AVAILABLE';

create index makeup_credits_organization_idx
  on public.makeup_credits (organization_id, status, expires_on);

-- Coherencia de tenant. Es LA barrera cross-tenant de esta tabla.
create or replace function public.check_makeup_credit_same_org()
returns trigger
language plpgsql
set search_path = public
as $BODY$
declare
  v_customer_org uuid;
  v_service_org uuid;
  v_source_org uuid;
  v_consumed_org uuid;
begin
  select organization_id into v_customer_org from public.customers where id = new.customer_id;
  select organization_id into v_service_org from public.services where id = new.service_id;

  if v_customer_org is null or v_customer_org <> new.organization_id
     or v_service_org is null or v_service_org <> new.organization_id then
    raise exception 'MakeupCredit organization_id must match its Customer and Service';
  end if;

  if new.source_booking_id is not null then
    select organization_id into v_source_org from public.bookings where id = new.source_booking_id;
    if v_source_org is null or v_source_org <> new.organization_id then
      raise exception 'MakeupCredit source_booking_id must belong to the same Organization';
    end if;
  end if;

  if new.consumed_booking_id is not null then
    select organization_id into v_consumed_org from public.bookings where id = new.consumed_booking_id;
    if v_consumed_org is null or v_consumed_org <> new.organization_id then
      raise exception 'MakeupCredit consumed_booking_id must belong to the same Organization';
    end if;
  end if;

  return new;
end;
$BODY$;

create trigger makeup_credits_same_org
  before insert or update on public.makeup_credits
  for each row execute function public.check_makeup_credit_same_org();

-- Inmutabilidad de los términos y, sobre todo, de expires_on: la decisión
-- 2 del Orchestrator escrita donde se puede hacer cumplir. Mismo
-- precedente que check_service_plan_terms_immutable().
create or replace function public.check_makeup_credit_immutable_terms()
returns trigger
language plpgsql
set search_path = public
as $BODY$
begin
  if new.customer_id is distinct from old.customer_id
     or new.service_id is distinct from old.service_id
     or new.source_booking_id is distinct from old.source_booking_id
     or new.origin is distinct from old.origin
     or new.issued_at is distinct from old.issued_at
     or new.expires_on is distinct from old.expires_on
  then
    raise exception 'MAKEUP_CREDIT_TERMS_IMMUTABLE';
  end if;

  return new;
end;
$BODY$;

create trigger makeup_credits_immutable_terms
  before update on public.makeup_credits
  for each row execute function public.check_makeup_credit_immutable_terms();

-- RLS: SELECT de dos capas (ADR-0006), CERO policies de escritura. Un
-- crédito es dinero: todo INSERT/UPDATE pasa por una RPC security
-- definer. Un cliente con profile_id nulo (ADR-0026) no matchea nada acá
-- -- exactamente como el resto de las policies de dos capas.
alter table public.makeup_credits enable row level security;

create policy makeup_credits_select_self_or_staff
  on public.makeup_credits for select
  using (
    exists (
      select 1 from public.customers c
      where c.id = makeup_credits.customer_id and c.profile_id = auth.uid()
    )
    or public.is_organization_member(organization_id)
  );

grant select on public.makeup_credits to authenticated;

-- ============================================================
-- 4. Vencimiento: derivado, nunca persistido (mismo criterio que
--    SlotOccurrence.COMPLETED, ADR-0010)
-- ============================================================

create or replace function public.compute_makeup_credit_expiry(
  p_expiry_basis public.makeup_credit_expiry_basis,
  p_expiry_days int,
  p_local_date date,
  p_period_end date
)
returns date
language sql
immutable
as $BODY$
  select case p_expiry_basis
    when 'DAYS_AFTER' then p_local_date + coalesce(p_expiry_days, 30)
    when 'END_OF_BILLING_PERIOD' then coalesce(
      p_period_end,
      (date_trunc('month', p_local_date) + interval '1 month - 1 day')::date
    )
    else (date_trunc('month', p_local_date) + interval '1 month - 1 day')::date
  end;
$BODY$;

revoke execute on function public.compute_makeup_credit_expiry(public.makeup_credit_expiry_basis, int, date, date)
  from public, anon, authenticated, service_role;

-- El crédito que se consume: el de expires_on más próximo, desempate
-- total issued_at/id (§2.4.2) -- para que el preview y el confirm nunca
-- puedan elegir dos créditos distintos para la misma reserva.
create or replace function public.resolve_usable_makeup_credit(
  p_customer_id uuid,
  p_service_id uuid,
  p_local_date date
)
returns uuid
language sql
stable
security definer
set search_path = public
as $BODY$
  select id from public.makeup_credits
  where customer_id = p_customer_id
    and service_id = p_service_id
    and status = 'AVAILABLE'
    and expires_on >= p_local_date
  order by expires_on asc, issued_at asc, id asc
  limit 1;
$BODY$;

revoke execute on function public.resolve_usable_makeup_credit(uuid, uuid, date)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 5. El veredicto compuesto: (reason, makeup_credit_id) -- nunca un
--    valor nuevo del enum can_book_reason (ADR-0025 §2.4.3)
-- ============================================================
-- Envuelve evaluate_payment_coverage() sin reimplementar nada de
-- ADR-0024: si esa función ya dice OK, el crédito ni se mira (nunca se
-- gasta un crédito si otra cobertura alcanzaba). Si dice uno de los tres
-- motivos rescatables, se pregunta si hay un crédito usable.
--
-- El guard de "nunca para una fecha de serie" vive ACÁ, en el único
-- lugar por el que pasan tanto book_slot() como cada preview -- en vez
-- de confiar en que cada llamador recuerde pasar el flag correcto.
create or replace function public.evaluate_payment_coverage_with_credit(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid,
  p_recurring_booking_id uuid default null,
  p_prospective_series boolean default false,
  p_use_makeup_credit boolean default true
)
returns table (reason public.can_book_reason, makeup_credit_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_reason public.can_book_reason;
  v_local_date date;
  v_credit_id uuid;
begin
  v_reason := public.evaluate_payment_coverage(
    p_customer_id, p_service_id, p_slot_occurrence_id, p_recurring_booking_id, p_prospective_series
  );

  if v_reason <> 'OK'
     and p_use_makeup_credit
     and p_recurring_booking_id is null
     and not p_prospective_series
     and v_reason in ('OUTSIDE_PLAN_QUOTA', 'PAYMENT_REQUIRED', 'SERVICE_HAS_NO_PLAN')
  then
    v_local_date := public.slot_local_date(p_slot_occurrence_id);
    if v_local_date is not null then
      v_credit_id := public.resolve_usable_makeup_credit(p_customer_id, p_service_id, v_local_date);
    end if;
  end if;

  if v_credit_id is not null then
    reason := 'OK';
  else
    reason := v_reason;
  end if;
  makeup_credit_id := v_credit_id;
  return next;
end;
$BODY$;

comment on function public.evaluate_payment_coverage_with_credit(uuid, uuid, uuid, uuid, boolean, boolean) is
  'Compuerta de credito, ultimo recurso de cobertura (ADR-0025 S2.4.1). El veredicto viaja como PAR -- reason nunca es un valor nuevo del enum, porque seis funciones comparan = OK. Nunca gasta un credito si evaluate_payment_coverage() ya daba OK, y nunca rescata una fecha de serie (p_recurring_booking_id / p_prospective_series).';

revoke execute on function public.evaluate_payment_coverage_with_credit(uuid, uuid, uuid, uuid, boolean, boolean)
  from public, anon, authenticated, service_role;

-- payment_covers_slot() mantiene su contrato booleano (ADR-0025 §2.4.3):
-- pasa a devolver true cuando hay crédito usable. Trailing param con
-- default: misma identidad de función (mismo OID), sus privilegios ya
-- revocados de todos los roles no cambian.
-- CREATE OR REPLACE cannot turn a 4-arg function into a 5-arg one: adding
-- a parameter (even with a default) creates a NEW, DISTINCT overload
-- instead of replacing the old one -- Postgres only lets CREATE OR
-- REPLACE keep the same argument list. Left un-dropped, both signatures
-- would coexist and every call with exactly 4 args (which used to be
-- unambiguous) becomes "is not unique". Same fix applied below to every
-- other function this migration adds a trailing parameter to.
drop function if exists public.payment_covers_slot(uuid, uuid, uuid, uuid);

create function public.payment_covers_slot(
  p_customer_id uuid,
  p_service_id uuid,
  p_slot_occurrence_id uuid,
  p_recurring_booking_id uuid default null,
  p_use_makeup_credit boolean default true
)
returns boolean
language sql
stable
security definer
set search_path = public
as $BODY$
  select reason = 'OK'
  from public.evaluate_payment_coverage_with_credit(
    p_customer_id, p_service_id, p_slot_occurrence_id, p_recurring_booking_id, false, p_use_makeup_credit
  );
$BODY$;

-- DROP resets privileges to the Postgres default (EXECUTE to PUBLIC) --
-- re-revoke explicitly (ADR-0028), matching the internal-helper category
-- this function was already in since Phase 19.
revoke execute on function public.payment_covers_slot(uuid, uuid, uuid, uuid, boolean)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 6. Emisión: una sola función, tres llamadores (ADR-0025 §2.3.1)
-- ============================================================
-- Recibe la Booking ya cancelada (status = 'CANCELLED'): todo llamador
-- es una UPDATE ... WHERE status = 'CONFIRMED' que la acaba de cancelar,
-- así que "estaba CONFIRMED" (condición 2) queda garantizado por
-- construcción; el chequeo de acá es sólo defensivo.
--
-- Idempotente vía ON CONFLICT sobre el índice único de source_booking_id:
-- segura de llamar más de una vez para la misma reserva cancelada.
create or replace function public.issue_makeup_credit(
  p_booking public.bookings,
  p_origin public.makeup_credit_origin,
  p_enforce_deadline boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_policy record;
  v_coverage public.can_book_reason;
  v_local_date date;
  v_period_end date;
  v_expires_on date;
  v_credit_id uuid;
begin
  if p_booking.status <> 'CANCELLED' then
    return null;
  end if;

  select * into v_occurrence from public.slot_occurrences where id = p_booking.slot_occurrence_id;
  if not found then
    return null;
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id;
  -- Condición 3: un servicio gratis no tiene nada que el crédito compre.
  if not found or not v_service.payment_required then
    return null;
  end if;

  select * into v_policy from public.resolve_makeup_credits_policy(v_service.id);
  -- Condición 1: el interruptor de la organización/servicio.
  if v_policy.enabled is not true then
    return null;
  end if;

  -- Condición 5: esta reserva ya había consumido un crédito. El remedio
  -- es devolver ESE (lo hace el llamador antes de esta llamada), nunca
  -- acuñar uno nuevo -- si no, cancelar-y-reservar sería la fábrica
  -- infinita que ADR-0025 §0.3 documentó para el caso de la serie.
  if exists (select 1 from public.makeup_credits where consumed_booking_id = p_booking.id) then
    return null;
  end if;

  v_local_date := public.slot_local_date(v_occurrence.id);
  if v_local_date is null then
    return null;
  end if;

  -- Condición 4: se re-pregunta la cobertura de ADR-0024 EN EL MOMENTO
  -- de cancelar, en vez de reimplementar "vino de una serie en cuota".
  -- De yapa cierra el caso límite 10 (pago anulado después de reservar):
  -- sin cobertura vigente ahora, no hay crédito.
  v_coverage := public.evaluate_payment_coverage(
    p_booking.customer_id, v_service.id, v_occurrence.id, p_booking.recurring_booking_id, false
  );
  if v_coverage <> 'OK' then
    return null;
  end if;

  -- Condición 6, sólo cuando el llamador la exige (cancel_booking()):
  -- timestamptz contra timestamptz, sin aritmética de timezone y por lo
  -- tanto sin bug de DST (ADR-0014).
  if p_enforce_deadline and now() > (v_occurrence.start_at - (v_policy.deadline_hours * interval '1 hour')) then
    return null;
  end if;

  if v_policy.expiry_basis = 'END_OF_BILLING_PERIOD' then
    select p.period_end into v_period_end
      from public.payments p
      where p.customer_id = p_booking.customer_id
        and p.service_id = v_service.id
        and p.status = 'PAID'
        and p.slot_occurrence_id is null
        and p.period_start <= v_local_date
        and p.period_end >= v_local_date
      order by p.period_start desc, p.created_at desc
      limit 1;
  end if;

  v_expires_on := public.compute_makeup_credit_expiry(
    v_policy.expiry_basis, v_policy.expiry_days, v_local_date, v_period_end
  );

  insert into public.makeup_credits (
    organization_id, customer_id, service_id, origin, source_booking_id, issued_by,
    expires_on, expiry_basis, expiry_basis_days
  )
  values (
    p_booking.organization_id, p_booking.customer_id, v_service.id, p_origin, p_booking.id, auth.uid(),
    v_expires_on, v_policy.expiry_basis, v_policy.expiry_days
  )
  on conflict (source_booking_id) where source_booking_id is not null do nothing
  returning id into v_credit_id;

  return v_credit_id;
end;
$BODY$;

comment on function public.issue_makeup_credit(public.bookings, public.makeup_credit_origin, boolean) is
  'La UNICA funcion que acuna un MakeupCredit (ADR-0025). Llamada desde cancel_booking() (CUSTOMER_RELEASE, exige anticipacion), cancel_slot_occurrence() y discontinue_schedule_rule() (ORGANIZATION_CANCELLED, sin exigirla). cancel_recurring_booking() NUNCA la llama -- una cascada de serie no emite jamas, la pida quien la pida (S0.3): cancelar y recrear la serie no puede imprimir creditos.';

revoke execute on function public.issue_makeup_credit(public.bookings, public.makeup_credit_origin, boolean)
  from public, anon, authenticated, service_role;

-- ============================================================
-- 7. can_customer_book() / evaluate_customer_booking(): credit-aware
--    para que el preview no-locking de book_slot() no rechace lo que el
--    consumo real sí aceptaría
-- ============================================================
-- Both gain a trailing parameter -- dropped first, same reason as
-- payment_covers_slot() above (CREATE OR REPLACE cannot add an argument).

drop function if exists public.evaluate_customer_booking(uuid, uuid, uuid, boolean);

create function public.evaluate_customer_booking(
  p_slot_occurrence_id uuid,
  p_customer_id uuid,
  p_recurring_booking_id uuid default null,
  p_prospective_series boolean default false,
  p_use_makeup_credit boolean default true
)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_occurrence public.slot_occurrences;
  v_service public.services;
  v_customer public.customers;
  v_coverage public.can_book_reason;
  v_active_count int;
begin
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id;
  if not found or v_occurrence.status <> 'ACTIVE' then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  if v_occurrence.end_at < now() then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  if not exists (select 1 from public.organizations where id = v_occurrence.organization_id and is_active) then
    return 'ORGANIZATION_INACTIVE';
  end if;

  select * into v_service from public.services where id = v_occurrence.service_id and is_active;
  if not found then
    return 'SERVICE_INACTIVE';
  end if;

  select * into v_customer from public.customers
    where id = p_customer_id
      and organization_id = v_occurrence.organization_id
      and is_active;
  if not found then
    return 'NOT_A_CUSTOMER';
  end if;

  select reason into v_coverage
  from public.evaluate_payment_coverage_with_credit(
    v_customer.id, v_service.id, p_slot_occurrence_id, p_recurring_booking_id, p_prospective_series, p_use_makeup_credit
  );
  if v_coverage <> 'OK' then
    return v_coverage;
  end if;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';
  if v_active_count >= v_occurrence.capacity then
    return 'SLOT_FULL';
  end if;

  if exists (
    select 1 from public.bookings
    where customer_id = v_customer.id and slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED'
  ) then
    return 'ALREADY_BOOKED';
  end if;

  return 'OK';
end;
$BODY$;

-- DROP resets privileges to the Postgres default -- re-revoke (ADR-0028):
-- this is the internal helper every preview and every booking RPC funnels
-- through, never a direct PostgREST target.
revoke execute on function public.evaluate_customer_booking(uuid, uuid, uuid, boolean, boolean)
  from public, anon, authenticated, service_role;

drop function if exists public.can_customer_book(uuid);

create function public.can_customer_book(
  p_slot_occurrence_id uuid,
  p_use_makeup_credit boolean default true
)
returns public.can_book_reason
language plpgsql
stable
security definer
set search_path = public
as $BODY$
declare
  v_org uuid;
  v_customer_id uuid;
begin
  if auth.uid() is null then
    return 'AUTH_REQUIRED';
  end if;

  select organization_id into v_org from public.slot_occurrences where id = p_slot_occurrence_id;
  if v_org is null then
    return 'OCCURRENCE_NOT_AVAILABLE';
  end if;

  select id into v_customer_id from public.customers
    where organization_id = v_org and profile_id = auth.uid() and is_active;
  if v_customer_id is null then
    return 'NOT_A_CUSTOMER';
  end if;

  return public.evaluate_customer_booking(p_slot_occurrence_id, v_customer_id, null, false, p_use_makeup_credit);
end;
$BODY$;

revoke execute on function public.can_customer_book(uuid, boolean) from public, anon;
grant execute on function public.can_customer_book(uuid, boolean) to authenticated;

-- ============================================================
-- 8. book_slot() / admin_book_for_customer(): consumo atómico, con el
--    lock PROPIO del crédito (ADR-0025 §0.1 / §2.4.5)
-- ============================================================
-- La UPDATE condicional de más abajo ES el lock: dos transacciones que
-- leyeron el mismo makeup_credit_id (porque están reservando dos
-- ocurrencias DISTINTAS, cada una con su propio FOR UPDATE de la
-- ocurrencia que no conflictúa con la otra) compiten por la misma fila
-- de makeup_credits. Postgres serializa esa UPDATE: la primera en
-- confirmar gana (AVAILABLE -> CONSUMED), la segunda espera el lock de
-- fila, reevalúa el WHERE status = 'AVAILABLE' cuando lo obtiene, ve 0
-- filas y aborta con una excepción -- nunca un "sin crédito" silencioso
-- que dejaría una reserva extra confirmada sin haber pagado nada.

drop function if exists public.book_slot(uuid);

create function public.book_slot(
  p_slot_occurrence_id uuid,
  p_use_makeup_credit boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_reason public.can_book_reason;
  v_coverage public.can_book_reason;
  v_makeup_credit_id uuid;
  v_occurrence public.slot_occurrences;
  v_customer public.customers;
  v_active_count int;
  v_booking public.bookings;
begin
  v_reason := public.can_customer_book(p_slot_occurrence_id, p_use_makeup_credit);
  if v_reason <> 'OK' then
    return jsonb_build_object('status', v_reason);
  end if;

  -- ADR-0004: el lock de la ocurrencia, sin tocar. Serializa esta
  -- ocurrencia, no al cliente -- por eso el crédito necesita el suyo,
  -- más abajo, tomado siempre DESPUÉS de este (mismo orden en todo
  -- llamador, para no dar lugar a un deadlock entre los dos locks).
  select * into v_occurrence from public.slot_occurrences where id = p_slot_occurrence_id for update;

  select * into v_customer from public.customers
    where organization_id = v_occurrence.organization_id and profile_id = auth.uid() and is_active;

  select count(*) into v_active_count
    from public.bookings
    where slot_occurrence_id = p_slot_occurrence_id and status = 'CONFIRMED';

  if v_active_count >= v_occurrence.capacity then
    return jsonb_build_object('status', 'SLOT_FULL');
  end if;

  select reason, makeup_credit_id into v_coverage, v_makeup_credit_id
  from public.evaluate_payment_coverage_with_credit(
    v_customer.id, v_occurrence.service_id, p_slot_occurrence_id, null, false, p_use_makeup_credit
  );
  if v_coverage <> 'OK' then
    return jsonb_build_object('status', v_coverage);
  end if;

  insert into public.bookings (
    organization_id, customer_id, slot_occurrence_id, status, created_by
  )
  values (
    v_occurrence.organization_id, v_customer.id, p_slot_occurrence_id, 'CONFIRMED', auth.uid()
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
      -- ADR-0025 §2.4.5: nunca un status explícito acá. Se aborta TODO,
      -- incluida la Booking recién insertada -- lo contrario deja una
      -- reserva extra confirmada sin haber consumido nada, o sea gratis.
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

revoke execute on function public.book_slot(uuid, boolean) from public, anon;
grant execute on function public.book_slot(uuid, boolean) to authenticated;

drop function if exists public.admin_book_for_customer(uuid, uuid);

create function public.admin_book_for_customer(
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

  if not public.is_organization_member(v_occurrence.organization_id) then
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

revoke execute on function public.admin_book_for_customer(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_book_for_customer(uuid, uuid, boolean) to authenticated;

-- ============================================================
-- 9. Cancelaciones: devolución en todas, emisión sólo donde corresponde
-- ============================================================

-- cancel_booking(): única fecha puntual, siempre CUSTOMER_REQUEST
-- (ADR-0025 resolución 1, ya vigente desde Fase 19) -> origin
-- CUSTOMER_RELEASE, exige anticipación.
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
  elsif public.is_organization_member(v_booking.organization_id) then
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

  -- ADR-0025 §2.5.3: vuelve siempre, sin condición de vencimiento -- el
  -- crédito está congelado desde que se emitió.
  update public.makeup_credits
    set status = 'AVAILABLE', consumed_at = null
    where consumed_booking_id = p_booking_id and status = 'CONSUMED';

  perform public.issue_makeup_credit(v_updated, 'CUSTOMER_RELEASE', true);

  return v_updated;
end;
$BODY$;

comment on function public.cancel_booking(uuid) is
  'Cancela una Booking. El motivo se deriva del actor (ADR-0025 res. 1). Unica fecha puntual: la unica de las cuatro rutas de cancelacion que exige anticipacion para emitir un MakeupCredit (ADR-0025 S2.3.1).';

revoke execute on function public.cancel_booking(uuid) from public, anon;
grant execute on function public.cancel_booking(uuid) to authenticated;

-- cancel_slot_occurrence(): siempre organización, nunca exige
-- anticipación. Se recorre con un loop (no una UPDATE a granel) porque
-- la emisión necesita cada fila.
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

  if not public.is_organization_member(v_occurrence.organization_id) then
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

  -- ADR-0025 §2.3.1: este camino es siempre organización, así que cada
  -- CONFIRMED que se pierde es candidata a crédito, sin anticipación.
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

-- discontinue_schedule_rule(): caso límite 5 de la propuesta -- un
-- crédito por cada Booking CONFIRMED futura perdida, sin anticipación.
-- No es inflación: CONFIRMED ya implicaba cobertura OK al generarse.
create or replace function public.discontinue_schedule_rule(p_schedule_rule_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_cancelled_booking public.bookings;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id;
  if not found then
    raise exception 'SCHEDULE_RULE_NOT_FOUND';
  end if;

  if not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.schedule_rules
    set is_active = false, cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'DISCONTINUED_BY_ORGANIZATION'
    where id = p_schedule_rule_id;

  update public.slot_occurrences
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'RULE_DISCONTINUED'
    where schedule_rule_id = p_schedule_rule_id
      and start_at >= now()
      and status <> 'CANCELLED';

  for v_cancelled_booking in
    update public.bookings b
      set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
          cancellation_reason = 'RULE_DISCONTINUED'
      from public.slot_occurrences so
      where b.slot_occurrence_id = so.id
        and so.schedule_rule_id = p_schedule_rule_id
        and so.start_at >= now()
        and b.status = 'CONFIRMED'
      returning b.*
  loop
    update public.makeup_credits
      set status = 'AVAILABLE', consumed_at = null
      where consumed_booking_id = v_cancelled_booking.id and status = 'CONSUMED';

    perform public.issue_makeup_credit(v_cancelled_booking, 'ORGANIZATION_CANCELLED', false);
  end loop;

  update public.recurring_bookings
    set status = 'CANCELLED', cancelled_at = now(), cancelled_by = auth.uid(),
        cancellation_reason = 'ORGANIZATION_REMOVED'
    where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE';
end;
$BODY$;

-- cancel_recurring_booking(): la cascada de una serie completa NUNCA
-- emite (ADR-0025 §0.3 -- el exploit de imprimir créditos infinitos
-- cancelando y recreando la serie). Sí devuelve cualquier crédito que
-- las fechas canceladas hubieran consumido (§2.5.3 aplica a cualquier
-- cancelación, cascadeada o no).
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
  elsif public.is_organization_member(v_rb.organization_id) then
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

-- ============================================================
-- 10. Portal del cliente
-- ============================================================

create or replace function public.my_makeup_credits()
returns table (
  credit_id uuid,
  organization_name text,
  service_name text,
  origin public.makeup_credit_origin,
  status public.makeup_credit_status,
  issued_at timestamptz,
  expires_on date,
  is_expired boolean,
  source_start_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    mc.id,
    o.name,
    s.name,
    mc.origin,
    mc.status,
    mc.issued_at,
    mc.expires_on,
    mc.expires_on < current_date,
    so.start_at
  from public.makeup_credits mc
  join public.customers c on c.id = mc.customer_id and c.profile_id = auth.uid()
  join public.organizations o on o.id = mc.organization_id
  join public.services s on s.id = mc.service_id
  left join public.bookings b on b.id = mc.source_booking_id
  left join public.slot_occurrences so on so.id = b.slot_occurrence_id
  order by (mc.status = 'AVAILABLE') desc, mc.expires_on asc;
$BODY$;

comment on function public.my_makeup_credits() is
  'Los MakeupCredit del cliente autenticado, en todas las organizaciones de las que es Customer. is_expired calculado en SQL -- si TS lo recalculara, un dia no coincide por timezone (ADR-0025 S2.9).';

revoke execute on function public.my_makeup_credits() from public, anon;
grant execute on function public.my_makeup_credits() to authenticated;

-- Wrapper del cliente para liberar su cupo: TODA la logica de
-- cancelacion y emision vive en cancel_booking()/issue_makeup_credit()
-- (ADR-0018 -- una sola funcion de decision, nunca duplicada). Esta
-- funcion sólo junta la respuesta con el crédito recién emitido, si lo
-- hubo, para el aviso de "hasta cuándo te sirve" en el botón.
create or replace function public.release_my_booking(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
  v_credit public.makeup_credits;
begin
  v_booking := public.cancel_booking(p_booking_id);

  select * into v_credit from public.makeup_credits
    where source_booking_id = p_booking_id
    order by issued_at desc
    limit 1;

  return jsonb_build_object(
    'booking', to_jsonb(v_booking),
    'makeup_credit', case when v_credit.id is null then null else jsonb_build_object(
      'id', v_credit.id,
      'expires_on', v_credit.expires_on
    ) end
  );
end;
$BODY$;

comment on function public.release_my_booking(uuid) is
  'Wrapper del portal del cliente: delega toda la logica en cancel_booking() (ADR-0025) y solo agrega el credito recien emitido a la respuesta, para el aviso "vence el DD/MM" del boton liberar cupo.';

revoke execute on function public.release_my_booking(uuid) from public, anon;
grant execute on function public.release_my_booking(uuid) to authenticated;

-- ============================================================
-- 11. Admin: crédito MANUAL (resolución 5) y ver los de un cliente
-- ============================================================

create or replace function public.grant_manual_makeup_credit(
  p_customer_id uuid,
  p_service_id uuid,
  p_expires_on date,
  p_note text
)
returns public.makeup_credits
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_customer public.customers;
  v_service public.services;
  v_credit public.makeup_credits;
begin
  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception 'NOT_A_CUSTOMER';
  end if;

  -- ADR-0025 resolución 5: OWNER-only y auditado -- es el único remedio
  -- de media docena de casos límite, y por eso mismo la única puerta que
  -- acuña un crédito sin una reserva perdida detrás.
  if not public.is_organization_owner(v_customer.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select * into v_service from public.services
    where id = p_service_id and organization_id = v_customer.organization_id;
  if not found then
    raise exception 'SERVICE_NOT_FOUND';
  end if;

  if p_note is null or btrim(p_note) = '' then
    raise exception 'MAKEUP_CREDIT_NOTE_REQUIRED';
  end if;

  if p_expires_on is null or p_expires_on < current_date then
    raise exception 'MAKEUP_CREDIT_EXPIRES_ON_INVALID';
  end if;

  insert into public.makeup_credits (
    organization_id, customer_id, service_id, origin, source_booking_id, issued_by,
    expires_on, expiry_basis, expiry_basis_days, note
  )
  values (
    v_customer.organization_id, p_customer_id, p_service_id, 'MANUAL', null, auth.uid(),
    p_expires_on, 'DAYS_AFTER', greatest(p_expires_on - current_date, 1), p_note
  )
  returning * into v_credit;

  return v_credit;
end;
$BODY$;

comment on function public.grant_manual_makeup_credit(uuid, uuid, date, text) is
  'Credito de cortesia (origin = MANUAL, ADR-0025 resolucion 5). OWNER-only. expiry_basis se guarda como DAYS_AFTER con el N derivado de la fecha que el OWNER eligio, solo a fines de auditoria -- nada lo vuelve a leer para recalcular expires_on.';

revoke execute on function public.grant_manual_makeup_credit(uuid, uuid, date, text) from public, anon;
grant execute on function public.grant_manual_makeup_credit(uuid, uuid, date, text) to authenticated;

create or replace function public.organization_customer_makeup_credits(p_customer_id uuid)
returns table (
  credit_id uuid,
  service_name text,
  origin public.makeup_credit_origin,
  status public.makeup_credit_status,
  issued_at timestamptz,
  expires_on date,
  is_expired boolean,
  note text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    mc.id, s.name, mc.origin, mc.status, mc.issued_at, mc.expires_on, mc.expires_on < current_date, mc.note
  from public.makeup_credits mc
  join public.customers c on c.id = mc.customer_id
  join public.services s on s.id = mc.service_id
  where mc.customer_id = p_customer_id
    and public.is_organization_member(c.organization_id)
  order by (mc.status = 'AVAILABLE') desc, mc.expires_on asc;
$BODY$;

revoke execute on function public.organization_customer_makeup_credits(uuid) from public, anon;
grant execute on function public.organization_customer_makeup_credits(uuid) to authenticated;

-- ============================================================
-- 12. Agenda pública: recently_released (ADR-0025 §2.7, resolución 9)
-- ============================================================
-- Dropped en vez de reemplazada: agregar una columna cambia los OUT
-- parameters. Cuerpo copiado del de la Fase 16 (que ya advertía sobre
-- esto): reescribir de memoria las reglas de disclosure de ADR-0008 es
-- como cambian en silencio.

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
  recently_released boolean
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
      end as recently_released
    from public.slot_occurrences so
    join public.services s on s.id = so.service_id and s.is_active
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
