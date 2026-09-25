-- ============================================================
-- Phase 37 -- my_payments(): LEFT JOIN + descripcion del plan (ADR-0029)
-- ============================================================
-- Pedido original: en /me/pagos (portal del cliente) el pago no dice QUE
-- compro -- solo el monto. Al investigar aparecio un bug mas grave en la
-- misma funcion: my_payments() (Fase 15, phase21_140000:574) joinea
-- services por payments.service_id con INNER JOIN. Desde ADR-0029 (Fase
-- 22) payments.service_id es NULL cuando el pago esta anclado a un plan
-- que cubre varios servicios (o "todos los servicios",
-- applies_to_all_services) -- ese INNER JOIN descarta la fila entera. Un
-- pago real, PAID, de un plan multi-servicio simplemente no aparece en la
-- pantalla de pagos del propio cliente. Nadie lo nota porque no es un
-- error visible, es una fila que nunca llega.
--
-- Mismo bug, mismo fix, que customer_payment_detail() (Fase 25,
-- docs/database.md "4. customer_payment_detail() -- LEFT JOIN, no
-- INNER") del lado admin -- ese fix nunca se replico en el lado cliente
-- porque son dos funciones separadas (RLS de dos capas, ADR-0006:
-- customer_payment_detail() lee por membership, my_payments() por
-- auth.uid() como Customer).
--
-- Cambio de contrato (aditivo, no rompe nada existente):
--   * service_name pasa a poder ser NULL (LEFT JOIN) para el pago cuyo
--     plan no cubre un unico servicio -- pero ya no queda en blanco: cae
--     a coalesce(s.name, sp.name), mismo criterio que
--     customer_payment_detail().
--   * Se agregan cuatro columnas nuevas para que el frontend arme "de que
--     plan vino y que da" incluso cuando no hay un unico servicio:
--     plan_name, plan_kind, weekly_quota (frontend/lib/plan-labels.ts,
--     planSummary()) y plan_applies_to_all_services (alcance, para el
--     caso service_name = null).
--
-- payments.service_plan_id es NOT NULL desde la Fase 7 (todo pago esta
-- anclado a un ServicePlan) -- el LEFT JOIN contra service_plans es
-- solamente defensivo (mismo patron que customer_payment_detail()), nunca
-- deberia perder filas.
--
-- returns table cambia de forma (columnas nuevas): CREATE OR REPLACE no
-- alcanza (Postgres no permite cambiar el tipo de retorno de una funcion
-- existente), hace falta DROP + CREATE -- mismo patron que la Fase 15 ya
-- uso para esta misma funcion. DROP + CREATE resetea los grants a los
-- default de Postgres (PUBLIC tiene EXECUTE por default en funciones), asi
-- que el revoke/grant de abajo son obligatorios en esta misma migracion,
-- no se puede confiar en que el revoke de la Fase 19 siga aplicando a un
-- objeto con OID nuevo.

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
  plan_applies_to_all_services boolean
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
    sp.applies_to_all_services
  from public.payments p
  join public.customers c on c.id = p.customer_id and c.profile_id = auth.uid()
  join public.organizations o on o.id = p.organization_id
  left join public.services s on s.id = p.service_id
  left join public.service_plans sp on sp.id = p.service_plan_id
  order by p.period_start desc;
$BODY$;

comment on function public.my_payments() is
  'Los pagos propios del cliente autenticado (resuelto por auth.uid(), nunca por un customerId del caller -- mismo criterio que ADR-0005). ADR-0029: payments.service_id es NULL en un plan multi-servicio, asi que el join a services es LEFT (antes INNER descartaba esas filas enteras) y service_name cae al nombre del plan en ese caso. plan_name/plan_kind/weekly_quota/plan_applies_to_all_services dejan que el frontend arme que compro el pago (planSummary() en frontend/lib/plan-labels.ts) incluso cuando no hay un unico servicio.';

revoke execute on function public.my_payments() from public, anon;
grant execute on function public.my_payments() to authenticated;
