-- Phase 18: retire the CHECK that still governed a column ADR-0024 deprecated
-- Ref: docs/decisions.md ADR-0024, ADR-0022; Phase 14
-- (20260921120000_phase14_service_billing_attendance_groups.sql:161).
--
-- The constraint:
--
--   services_payment_requires_priced_type
--     check (not payment_required or billing_type <> 'FREE')
--
-- It was right under Phase 14's semantics, where services.billing_type
-- *was* the price: "a free service that requires payment is not a
-- configuration, it is a dead end -- nobody could ever book it".
--
-- ADR-0024 moved the price to service_plans and left
-- services.billing_type deprecated, which turns the same constraint into
-- a blocker of something legitimate: billing_type defaults to 'FREE', so
-- a form that no longer asks for a billing mode can never switch
-- payment_required on. The only way past it is to keep writing a column
-- nobody should read again -- the worst of both worlds, because it makes
-- the deprecated value look maintained.
--
-- The invariant is not lost, it changed address and is already
-- implemented: "this service requires payment and has no active plan" is
-- SERVICE_HAS_NO_PLAN in evaluate_payment_coverage() (Phase 17). It is
-- evaluated where it matters -- when someone tries to book -- instead of
-- as a CHECK over a column that is no longer the source of truth for
-- anything. And it is strictly stronger: the old CHECK accepted
-- billing_type = 'MONTHLY' with nothing on sale, which was the same dead
-- end it claimed to prevent.
--
-- This is deliberately its own migration rather than an edit to Phase 14:
-- that one is applied everywhere and is history.

alter table public.services
  drop constraint if exists services_payment_requires_priced_type;

-- Durable marker, so this reads as a decision and not as an oversight
-- six months from now.
comment on column public.services.payment_required is
  'Whether booking requires a Payment covering the slot date (ADR-0022). Deliberately NOT tied to billing_type any more (ADR-0024): the price lives in service_plans, and "requires payment with nothing on sale" is answered at booking time as SERVICE_HAS_NO_PLAN, not by a CHECK over a deprecated column. The Phase 14 constraint services_payment_requires_priced_type was dropped in Phase 18 for that reason.';

-- The other two CHECKs over the deprecated columns
-- (services_billing_cycle_matches_type, services_price_non_negative)
-- are deliberately kept: neither can block a writer that has stopped
-- setting those columns -- the defaults ('FREE', null, null) satisfy
-- both -- so they only keep legacy rows coherent. They belong to the
-- migration that finally drops billing_type/billing_cycle/price, not to
-- this one.

notify pgrst, 'reload schema';
