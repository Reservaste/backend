-- ============================================================
-- Phase 23: my_services() shows the plan the customer actually bought
-- ============================================================
-- Bug, not just stale copy: my_services() (Phase 15) still reads
-- services.billing_type/billing_cycle/price, deprecated since ADR-0024
-- and only ever correct for a service with exactly one UNLIMITED plan.
-- A service that sells several plans (the pilates case ADR-0024 was
-- built for) shows the same number to every customer regardless of
-- which plan they actually paid for -- silently wrong, not just outdated.
--
-- The coverage check had a second, independent bug: it queried
-- payments.service_id with a hand-rolled date range instead of going
-- through payment_service_coverage (ADR-0029), so a customer covered by
-- a plan that only exists post-Phase-22 could read as uncovered here
-- while the real booking path (evaluate_payment_coverage) said otherwise
-- -- two answers to the same question, from two different queries.

drop function if exists public.my_services();

create or replace function public.my_services()
returns table (
  service_id uuid,
  service_name text,
  organization_slug text,
  organization_name text,
  currency text,
  payment_required boolean,
  plan_id uuid,
  plan_name text,
  plan_price numeric,
  plan_kind public.service_plan_kind,
  covered_until date,
  is_covered_today boolean
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select
    s.id,
    s.name,
    o.slug,
    o.name,
    o.currency,
    s.payment_required,
    covering.plan_id,
    covering.plan_name,
    covering.plan_price,
    covering.plan_kind,
    covering.covered_until,
    not s.payment_required or covering.plan_id is not null
  from public.customers c
  join public.organizations o on o.id = c.organization_id
  join public.services s on s.organization_id = o.id and s.is_active
  -- Same join resolve_covering_service_plan() (ADR-0029) documents as the
  -- one true way to answer "what plan currently covers this customer for
  -- this service" -- written out here instead of calling that function
  -- directly because this also needs the period's end date, which its
  -- `service_plans` return type doesn't carry. Not a second source of
  -- truth for whether a booking is allowed (evaluate_payment_coverage()
  -- keeps that job entirely); this is read-only reporting of the same
  -- underlying data for a person to look at.
  left join lateral (
    select
      sp.id as plan_id,
      sp.name as plan_name,
      sp.price as plan_price,
      sp.plan_kind,
      psc.period_end as covered_until
    from public.payments p
    join public.payment_service_coverage psc on psc.payment_id = p.id
    join public.service_plans sp on sp.id = p.service_plan_id
    where psc.customer_id = c.id
      and psc.service_id = s.id
      and p.status = 'PAID'
      and psc.period_start <= (now() at time zone o.timezone)::date
      and psc.period_end >= (now() at time zone o.timezone)::date
    order by psc.period_start desc, p.created_at desc
    limit 1
  ) covering on true
  where c.profile_id = auth.uid() and c.is_active
  order by o.name asc, s.name asc;
$BODY$;

comment on function public.my_services() is
  'What a customer sees about their own services: the plan actually covering them today (name, price, plan_kind, until when), resolved through payment_service_coverage (ADR-0029) -- not the deprecated services.billing_type/billing_cycle/price, which stopped being the source of truth for price the day a service could sell more than one plan (ADR-0024).';

-- DROP FUNCTION above wipes any grants the old definition had, including
-- Phase 19's revoke from public/anon (ADR-0028: EXECUTE is additive, the
-- Postgres default leaves it open to PUBLIC unless explicitly revoked).
-- Re-stating both, not just the grant, so this migration can't silently
-- reopen the exact hole that one closed.
revoke execute on function public.my_services() from public, anon;
grant execute on function public.my_services() to authenticated;
