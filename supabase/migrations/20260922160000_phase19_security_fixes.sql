-- ============================================================
-- Phase 19 -- security fixes for pre-existing holes
-- ============================================================
-- This migration does NOT implement ADR-0025 (makeup credits) nor
-- ADR-0026 (managed customers). It closes four holes that already exist
-- in the schema and that the design work for those two phases surfaced.
-- Only resolutions 1 and 2 of ADR-0025 land here, because both are
-- prerequisites: without them the deadline policy of ADR-0025 is
-- decorative and the reason field lies.
--
-- 1. EXECUTE was never revoked from PUBLIC on any function in this repo.
--    Postgres grants EXECUTE to PUBLIC by default and Supabase's default
--    privileges additionally grant it to anon/authenticated/service_role,
--    so *every* RPC was callable by an anonymous PostgREST request -- the
--    `grant execute ... to authenticated` lines scattered through the
--    migrations were documentation, not a restriction. Most functions
--    then fail closed on their own authorization check; several do not.
--    retry_not_generated_booking() is the worst case: SECURITY DEFINER,
--    a write, and no authorization check at all.
-- 2. cancel_booking() skipped authorization entirely when
--    customers.profile_id was NULL (three-valued logic, see below).
-- 3. cancel_booking() let the caller pick the reason for their own
--    cancellation (ADR-0025 resolution 1).
-- 4. booking_cancellation_reason had no value for "the series was
--    cancelled" (ADR-0025 resolution 2).
--
-- Known and deliberately NOT fixed here: customers.profile_id is
-- ON DELETE CASCADE, so deleting an auth.users row deletes the customer,
-- its bookings and its payments -- against domain.md ("a cancelled
-- Booking is never deleted", "a Payment is voided, never deleted"). The
-- fix is ON DELETE SET NULL, which Postgres rejects while the column is
-- NOT NULL. It therefore has to ride along with the migration that makes
-- profile_id nullable (Phase J / ADR-0026), not this one.

-- ============================================================
-- 1. SERIES_CANCELLED (ADR-0025, resolution 2)
-- ============================================================
-- Cancelling a series cascaded to its future children stamping
-- RULE_DISCONTINUED (staff path) or CUSTOMER_REQUEST (customer path).
-- Neither is true: the rule was not discontinued, and the customer did
-- not ask for that individual date. ADR-0010 created cancellation_reason
-- precisely so notification and reporting could be accurate, and
-- ADR-0025 needs the distinction structurally -- "cancelled as part of a
-- series" is exactly the case that must never mint a makeup credit.
--
-- ALTER TYPE ... ADD VALUE may not be *used* by DML or a CHECK in the
-- same transaction. A PL/pgSQL body that mentions the literal is fine:
-- the expression is only parsed on first execution, long after this
-- migration has committed. Nothing below writes the new value.
alter type public.booking_cancellation_reason add value if not exists 'SERIES_CANCELLED';

-- ============================================================
-- 2 + 3. cancel_booking(): NULL-safe authorization, derived reason
-- ============================================================
-- The old body was:
--
--   if v_customer.profile_id <> auth.uid()
--      and not public.is_organization_member(...) then
--     raise exception 'NOT_AUTHORIZED';
--   end if;
--
-- With profile_id IS NULL, `NULL <> auth.uid()` is NULL, `NULL and ...`
-- is NULL, the IF does not fire and the function falls through to the
-- UPDATE: authorization is skipped entirely. It is not exploitable today
-- only because the column is NOT NULL. Phase J makes it nullable, and at
-- that moment any authenticated user could cancel any managed customer's
-- booking in any organization. Fixed before the condition that arms it
-- exists.
--
-- The correct shape already lived in the repo, in
-- cancel_recurring_booking() (Phase 6): the same predicate written as
-- if <owner> / elsif <member> / else raise. A NULL profile_id makes both
-- branches false and lands on the ELSE. Same expression, opposite
-- behaviour.
--
-- Contract change (ADR-0025 resolution 1): p_reason is gone. The reason
-- is derived from the actor, never accepted from an `authenticated`
-- caller -- otherwise a customer cancels ten minutes before the class
-- passing 'SLOT_CANCELLED' and collects the credit the notice period
-- existed to deny them. The organization's own paths
-- (cancel_slot_occurrence, discontinue_schedule_rule, series cascade)
-- keep stamping their own reason, but from inside, never by parameter.
-- Staff cancelling one booking from the counter is still
-- CUSTOMER_REQUEST -- that is what it is, the customer asked -- and
-- cancelled_by already records which profile did it (ADR-0010; note the
-- schema has cancelled_by as an FK to Profile, not the categorical enum
-- domain.md used to describe).
drop function if exists public.cancel_booking(uuid, public.booking_cancellation_reason);

create function public.cancel_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_booking public.bookings;
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

  -- Attendance already marked is left alone: cancelling a booking after
  -- the fact does not un-happen someone having shown up (ADR-0022).
  update public.bookings
    set status = 'CANCELLED',
        cancelled_at = now(),
        cancelled_by = auth.uid(),
        cancellation_reason = 'CUSTOMER_REQUEST'
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$BODY$;

comment on function public.cancel_booking(uuid) is
  'Cancels one Booking. The cancellation reason is derived from the actor and is never a parameter (ADR-0025 res. 1): this entry point is the customer-request path, whoever calls it. Organization-originated cancellations stamp their own reason from inside cancel_slot_occurrence(), discontinue_schedule_rule() and cancel_recurring_booking().';

revoke execute on function public.cancel_booking(uuid) from public, anon;
grant execute on function public.cancel_booking(uuid) to authenticated;

-- ============================================================
-- 4. cancel_recurring_booking(): stamp SERIES_CANCELLED on the cascade
-- ============================================================
-- Unchanged except for the two reasons the cascade writes. The
-- authorization shape here is already the correct one and is what
-- cancel_booking() above was rewritten to match.
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
begin
  select * into v_rb from public.recurring_bookings where id = p_recurring_booking_id;
  if not found then
    raise exception 'RECURRING_BOOKING_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_rb.customer_id;

  -- Who cancelled the series is still recorded, on the series itself,
  -- by recurring_bookings.cancellation_reason. What changes is what the
  -- children get stamped with: both branches now say SERIES_CANCELLED,
  -- because from the child booking's point of view that is the whole
  -- truth -- the rule was not discontinued (staff branch), and the
  -- customer did not ask for that particular date (customer branch).
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

  update public.bookings b
    set status = 'CANCELLED',
        cancelled_at = now(),
        cancelled_by = auth.uid(),
        cancellation_reason = 'SERIES_CANCELLED'
    from public.slot_occurrences so
    where b.slot_occurrence_id = so.id
      and b.recurring_booking_id = p_recurring_booking_id
      and so.start_at >= now()
      and b.status = 'CONFIRMED';

  return v_rb;
end;
$BODY$;

-- ============================================================
-- 5. retry_not_generated_booking(): authorization, at last
-- ============================================================
-- SECURITY DEFINER, writes to bookings, and had no authorization check
-- of any kind. With EXECUTE sitting at its PUBLIC default, any anonymous
-- PostgREST request could flip an arbitrary NOT_GENERATED booking of an
-- arbitrary organization to CONFIRMED (it re-evaluates coverage and
-- capacity, so it cannot overbook -- but it can seat someone the
-- organization deliberately left pending, and it discloses via the
-- returned row whether a given booking id exists and what its state is).
-- This one is in production as-is; it is the most urgent item in this
-- migration.
--
-- Same authorization criterion as its siblings: the booking's own
-- customer, or a member of the organization. The auth.uid() IS NULL
-- branch is the internal caller -- reconcile_pending_recurring_bookings()
-- is SECURITY DEFINER, so by the time it calls this the session may have
-- no JWT at all (the daily job, the service-role client in tests). After
-- the REVOKE below the only roles that can reach this function directly
-- are `authenticated` (which always carries a sub claim) and the owner,
-- so that branch is not a way in.
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
  elsif public.is_organization_member(v_booking.organization_id) then
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
    -- Still blocked, possibly for a different reason than last time.
    -- Keep the recorded reason honest rather than stale.
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

revoke execute on function public.retry_not_generated_booking(uuid) from public, anon, service_role;
grant execute on function public.retry_not_generated_booking(uuid) to authenticated;

-- ============================================================
-- 6. generate_slot_occurrences_for_rule(): tenant check + horizon clamp
-- ============================================================
-- Also SECURITY DEFINER with no authorization and no grant. It writes
-- slot_occurrences (and, through generate_recurring_booking(), bookings)
-- for whatever rule id it is handed, in any organization. p_horizon_days
-- was unbounded, so a single call could be asked to materialize decades
-- of occurrences.
--
-- It cannot simply be revoked from `authenticated`: the AFTER INSERT /
-- AFTER UPDATE triggers on schedule_rules that call it are SECURITY
-- INVOKER, so staff creating a schedule rule through PostgREST needs the
-- privilege. (Making those triggers SECURITY DEFINER would be the
-- cleaner fix, but slot_occurrences has no DELETE policy, so today the
-- regeneration DELETE inside trigger_regenerate_on_schedule_rule_update()
-- silently removes nothing under RLS; flipping it to DEFINER would start
-- deleting occurrences for real, including ones with bookings. That is a
-- separate, pre-existing bug and not this migration's business.)
-- The tenant check inside is therefore the real boundary: anon loses
-- EXECUTE, and an authenticated caller may only generate for a rule of
-- an organization they belong to. auth.uid() IS NULL is the cron job and
-- the service-role client.
--
-- Body is otherwise identical to Phase 6.
create or replace function public.generate_slot_occurrences_for_rule(
  p_schedule_rule_id uuid,
  p_horizon_days int default 90
)
returns void
language plpgsql
security definer
set search_path = public
as $BODY$
declare
  v_rule public.schedule_rules;
  v_org public.organizations;
  v_horizon_days int;
  v_horizon_end date;
  v_day date;
  v_exception public.schedule_exceptions;
  v_local_start_time time;
  v_duration_minutes int;
  v_capacity int;
  v_start_at timestamptz;
  v_new_occurrence_id uuid;
  v_recurring_booking_id uuid;
begin
  select * into v_rule from public.schedule_rules where id = p_schedule_rule_id and is_active;
  if not found then
    return;
  end if;

  if auth.uid() is not null and not public.is_organization_member(v_rule.organization_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- ADR-0009's window is 90 days. Anything past a year is not a horizon,
  -- it is a way to make one call insert a few hundred thousand rows.
  v_horizon_days := least(greatest(coalesce(p_horizon_days, 90), 0), 365);

  select * into v_org from public.organizations where id = v_rule.organization_id;

  v_horizon_end := least(
    current_date + v_horizon_days,
    coalesce(v_rule.valid_until, current_date + v_horizon_days)
  );

  v_day := greatest(v_rule.valid_from, current_date);
  v_day := v_day + ((v_rule.weekday - extract(dow from v_day)::int + 7) % 7);

  while v_day <= v_horizon_end loop
    select * into v_exception
      from public.schedule_exceptions
      where schedule_rule_id = p_schedule_rule_id and exception_date = v_day;

    if found and v_exception.exception_type = 'CANCELLED' then
      v_day := v_day + 7;
      continue;
    end if;

    v_local_start_time := coalesce((case when found then v_exception.modified_local_start_time end), v_rule.local_start_time);
    v_duration_minutes := coalesce((case when found then v_exception.modified_duration_minutes end), v_rule.duration_minutes);
    v_capacity := coalesce((case when found then v_exception.modified_capacity end), v_rule.capacity);

    v_start_at := (v_day + v_local_start_time) at time zone v_org.timezone;

    insert into public.slot_occurrences (
      organization_id, schedule_rule_id, service_id, resource_id,
      start_at, end_at, generated_timezone, capacity,
      schedule_exception_id
    )
    values (
      v_rule.organization_id, v_rule.id, v_rule.service_id, v_rule.resource_id,
      v_start_at, v_start_at + make_interval(mins => v_duration_minutes), v_org.timezone, v_capacity,
      case when found then v_exception.id else null end
    )
    on conflict (schedule_rule_id, start_at) do nothing
    returning id into v_new_occurrence_id;

    -- Only for occurrences this call actually created -- ON CONFLICT
    -- skipping an insert leaves v_new_occurrence_id null, and an
    -- already-existing occurrence already had its recurring bookings
    -- generated the first time it was created.
    if v_new_occurrence_id is not null then
      for v_recurring_booking_id in
        select id from public.recurring_bookings
        where schedule_rule_id = p_schedule_rule_id and status = 'ACTIVE'
      loop
        perform public.generate_recurring_booking(v_recurring_booking_id, v_new_occurrence_id);
      end loop;
    end if;

    v_day := v_day + 7;
  end loop;
end;
$BODY$;

revoke execute on function public.generate_slot_occurrences_for_rule(uuid, int) from public, anon;
grant execute on function public.generate_slot_occurrences_for_rule(uuid, int) to authenticated, service_role;

-- ============================================================
-- 7. Internal helpers: not RPCs, and no longer reachable as one
-- ============================================================
-- Every one of these is SECURITY DEFINER, takes a customer_id / rule_id /
-- booking_id as a parameter, performs no authorization of its own, and
-- had EXECUTE at its PUBLIC default. They were written as building
-- blocks for the granted RPCs, but PostgREST published them all:
--
--  * evaluate_payment_coverage / payment_covers_slot /
--    evaluate_customer_booking / customer_series_* /
--    assert_series_within_plan_quota answer, for an arbitrary customer id
--    of an arbitrary organization, whether that person has paid, what
--    plan they hold and how many standing series they run.
--  * generate_recurring_booking, generate_all_slot_occurrences and
--    reconcile_pending_recurring_bookings write.
--
-- They are only ever called from inside SECURITY DEFINER functions,
-- where privileges are checked against the owner, so revoking EXECUTE
-- from every request role costs nothing and removes them from the API
-- surface entirely. If one of them ever needs to be an RPC, it needs an
-- authorization check first.
revoke execute on function public.assert_series_within_plan_quota(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function public.customer_series_in_force_count(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function public.customer_series_quota_position(uuid, uuid, date, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.customer_standing_series_on_rule(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke execute on function public.evaluate_payment_coverage(uuid, uuid, uuid, uuid, boolean)
  from public, anon, authenticated, service_role;
revoke execute on function public.evaluate_customer_booking(uuid, uuid, uuid, boolean)
  from public, anon, authenticated, service_role;
revoke execute on function public.payment_covers_slot(uuid, uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.generate_recurring_booking(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.generate_all_slot_occurrences(int)
  from public, anon, authenticated, service_role;
revoke execute on function public.reconcile_pending_recurring_bookings(uuid, uuid)
  from public, anon, authenticated, service_role;

-- slot_local_date() is the one helper that must stay reachable: the
-- BEFORE INSERT trigger on payments (fill_payment_service_plan, Phase 17)
-- is SECURITY INVOKER and calls it, so the role inserting the payment
-- needs EXECUTE. It only exposes an occurrence's local date, which
-- get_public_availability() already publishes -- but there is no reason
-- for anon to have it as an RPC.
revoke execute on function public.slot_local_date(uuid) from public, anon;
grant execute on function public.slot_local_date(uuid) to authenticated, service_role;

-- ============================================================
-- 8. Close the anon surface on every remaining business RPC
-- ============================================================
-- The `grant execute ... to authenticated` lines in Phases 1-18 never
-- restricted anything: they added a grant on top of the PUBLIC default
-- instead of replacing it. Each of these functions does check
-- authorization, so an anonymous call fails closed today -- but "fails
-- closed" is one bug away from "fails open", and an unauthenticated
-- attacker should not be able to reach the booking engine, the admin
-- operations or the platform console at all.
--
-- The four policy helpers (is_organization_member, is_organization_owner,
-- is_platform_admin, storage_object_organization) keep PUBLIC execute on
-- purpose: RLS policies call them, policy expressions run as the querying
-- role, and anon evaluates policies on every public-calendar read. They
-- only ever answer about auth.uid(), so they disclose nothing about
-- anyone else.
--
-- get_public_availability() and public_slot_detail() stay granted to
-- anon: they are the public calendar (ADR-0007).
revoke execute on function public.admin_book_for_customer(uuid, uuid) from public, anon;
revoke execute on function public.admin_create_recurring_booking(uuid, uuid) from public, anon;
revoke execute on function public.admin_preview_recurring_booking(uuid, uuid, int) from public, anon;
revoke execute on function public.agenda_occurrences(uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.billing_period_for(uuid, date) from public, anon;
revoke execute on function public.book_slot(uuid) from public, anon;
revoke execute on function public.can_customer_book(uuid) from public, anon;
revoke execute on function public.cancel_recurring_booking(uuid) from public, anon;
revoke execute on function public.cancel_slot_occurrence(uuid, public.slot_occurrence_cancellation_reason) from public, anon;
revoke execute on function public.create_organization_invite(text, text, int, int, text) from public, anon;
revoke execute on function public.create_organization_with_owner(text, text, text, text) from public, anon;
revoke execute on function public.create_recurring_booking(uuid) from public, anon;
revoke execute on function public.create_schedule_rule_group(uuid, uuid, smallint[], time, int, int) from public, anon;
revoke execute on function public.customer_payment_detail(uuid, date, date) from public, anon;
revoke execute on function public.discontinue_schedule_rule(uuid) from public, anon;
revoke execute on function public.discontinue_schedule_rule_group(uuid) from public, anon;
revoke execute on function public.enroll_customer_by_email(uuid, text) from public, anon;
revoke execute on function public.invite_member_by_email(uuid, text, public.organization_member_role) from public, anon;
revoke execute on function public.mark_attendance(uuid, public.attendance_status) from public, anon;
revoke execute on function public.my_bookings(boolean) from public, anon;
revoke execute on function public.my_payments() from public, anon;
revoke execute on function public.my_services() from public, anon;
revoke execute on function public.occurrence_attendance_summary(uuid) from public, anon;
revoke execute on function public.occurrence_bookings(uuid) from public, anon;
revoke execute on function public.organization_can_operate(uuid) from public, anon;
revoke execute on function public.organization_customers(uuid) from public, anon;
revoke execute on function public.organization_payment_summary(uuid, date, date) from public, anon;
revoke execute on function public.organization_team(uuid) from public, anon;
revoke execute on function public.organization_usage(uuid) from public, anon;
revoke execute on function public.platform_invites() from public, anon;
revoke execute on function public.platform_organizations() from public, anon;
revoke execute on function public.preview_recurring_booking(uuid, int) from public, anon;
revoke execute on function public.revoke_member(uuid) from public, anon;
revoke execute on function public.schedule_rule_groups(uuid) from public, anon;
revoke execute on function public.schedule_rule_standing_reservations(uuid) from public, anon;
revoke execute on function public.service_attendance_history(uuid, int) from public, anon;
revoke execute on function public.set_organization_subscription(uuid, text, public.subscription_status, timestamptz) from public, anon;
revoke execute on function public.set_payment_status(uuid, public.payment_status) from public, anon;

-- The public calendar keeps its two doors, explicitly.
grant execute on function public.get_public_availability(text, uuid, timestamptz, timestamptz) to anon, authenticated;
grant execute on function public.public_slot_detail(uuid) to anon, authenticated;
