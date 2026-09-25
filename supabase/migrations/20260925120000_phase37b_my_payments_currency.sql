-- ============================================================
-- Phase 37b -- my_payments(): expone currency de la organizacion
-- ============================================================
-- Pedido: /me/pagos necesita formatear cada monto en la moneda real de la
-- organizacion que emitio el pago -- un mismo cliente puede tener pagos de
-- varias organizaciones distintas (cada una con su propia
-- organizations.currency, ADR-0024), asi que no hay forma segura de asumir
-- una moneda desde el frontend sin este dato viajando junto al monto.
--
-- my_payments() (Fase 37, 20260925100000) ya hace join contra
-- public.organizations o -- solo falta agregar o.currency al select y al
-- returns table. Mismo patron que my_services() (Fase 23,
-- 20260922210000:26,45) y my_plan_change_requests() ya usan para exponer
-- currency.
--
-- Cambio de contrato: aditivo, agrega una columna (currency) al final del
-- returns table -- no quita ni renombra ninguna existente.
--
-- returns table cambia de forma otra vez: CREATE OR REPLACE no alcanza
-- (Postgres no permite cambiar el tipo de retorno de una funcion
-- existente), hace falta DROP + CREATE -- mismo patron que la Fase 37 (y
-- la Fase 15 antes) ya uso para esta misma funcion. No se edita la
-- migracion de la Fase 37 (20260925100000) porque ya fue revisada y
-- probada -- esta es una migracion nueva, aditiva. DROP + CREATE resetea
-- los grants a los default de Postgres (PUBLIC tiene EXECUTE por default
-- en funciones), asi que el revoke/grant de abajo son obligatorios en esta
-- misma migracion: el objeto queda con un OID nuevo y los grants de la
-- Fase 37 no le aplican.

drop function if exists public.my_payments();

create or replace function public.my_payments()
returns table (
  payment_id uuid,
  organization_name text,
  service_name text,
  period_start date,
  period_end date,
  status public.payment_status,
  amount numeric,
  created_at timestamptz,
  plan_name text,
  plan_kind public.service_plan_kind,
  weekly_quota int,
  plan_applies_to_all_services boolean,
  currency text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    p.id,
    o.name,
    coalesce(s.name, sp.name),
    p.period_start,
    p.period_end,
    p.status,
    p.amount,
    p.created_at,
    sp.name,
    sp.plan_kind,
    sp.weekly_quota,
    sp.applies_to_all_services,
    o.currency
  from public.payments p
  join public.customers c on c.id = p.customer_id and c.profile_id = auth.uid()
  join public.organizations o on o.id = p.organization_id
  left join public.services s on s.id = p.service_id
  left join public.service_plans sp on sp.id = p.service_plan_id
  order by p.period_start desc;
$BODY$;

comment on function public.my_payments() is
  'Los pagos propios del cliente autenticado (resuelto por auth.uid(), nunca por un customerId del caller -- mismo criterio que ADR-0005). ADR-0029: payments.service_id es NULL en un plan multi-servicio, asi que el join a services es LEFT (antes INNER descartaba esas filas enteras) y service_name cae al nombre del plan en ese caso. plan_name/plan_kind/weekly_quota/plan_applies_to_all_services dejan que el frontend arme que compro el pago (planSummary() en frontend/lib/plan-labels.ts) incluso cuando no hay un unico servicio. currency (Fase 37b) es la de la organizacion que emitio el pago -- un mismo cliente puede tener pagos de varias organizaciones, cada una con su propia moneda (ADR-0024), asi que el monto nunca se formatea con una moneda asumida.';

revoke execute on function public.my_payments() from public, anon;
grant execute on function public.my_payments() to authenticated;
