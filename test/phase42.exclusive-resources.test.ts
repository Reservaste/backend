// Integration tests for Phase 42 (ADR-0044: exclusive Resources) --
// database-level anti-overlap for Resources that are "occupied one
// booking at a time" (e.g. a single professional, a 1-on-1 court).
// Requires a running Supabase instance (see test/helpers.ts).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

// Same reasoning as phase3.slot-occurrences.test.ts: target "the weekday
// two days from now" so generated occurrences land inside the default
// 90-day horizon and are always genuinely future, regardless of which day
// the suite happens to run on.
function weekdayInTwoDays(): number {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 2);
  return d.getUTCDay();
}

/** The org-local calendar date (America/Montevideo) an instant falls on. */
function localDateOf(isoInstant: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Montevideo" }).format(
    new Date(isoInstant),
  );
}

describe("Phase 42: exclusive Resources (ADR-0044)", () => {
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let serviceA: { id: string };
  let serviceB: { id: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    owner = await createSignedInUser("p42-owner");
    createdUserIds.push(owner.id);

    org = await createOrganization(owner, "p42-org");

    const { data: svcA } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Corte de pelo", created_by: owner.id })
      .select()
      .single();
    serviceA = svcA!;

    const { data: svcB } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Afeitado", created_by: owner.id })
      .select()
      .single();
    serviceB = svcB!;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  async function createResource(name: string, isExclusive: boolean) {
    const { data, error } = await owner.client
      .from("resources")
      .insert({ organization_id: org.id, name, is_exclusive: isExclusive, created_by: owner.id })
      .select()
      .single();
    expect(error).toBeNull();
    return data! as { id: string; is_exclusive: boolean };
  }

  it("(a) rejects two overlapping ACTIVE occurrences of the same exclusive Resource", async () => {
    const resource = await createResource("Barbero exclusivo A", true);

    // A dummy, inactive ScheduleRule purely as the FK anchor -- is_active:
    // false means the AFTER INSERT trigger's generate_slot_occurrences_for_rule
    // call is a no-op (early return on "not found"), so it never
    // auto-generates anything this test does not control.
    const { data: rule } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceA.id,
        resource_id: resource.id,
        weekday: weekdayInTwoDays(),
        local_start_time: "10:00",
        duration_minutes: 60,
        capacity: 1,
        is_active: false,
        created_by: owner.id,
      })
      .select()
      .single();

    const base = new Date();
    base.setUTCDate(base.getUTCDate() + 5);
    base.setUTCHours(10, 0, 0, 0);

    const { data: occ1, error: occ1Error } = await admin
      .from("slot_occurrences")
      .insert({
        organization_id: org.id,
        schedule_rule_id: rule!.id,
        service_id: serviceA.id,
        resource_id: resource.id,
        start_at: base.toISOString(),
        end_at: new Date(base.getTime() + 60 * 60_000).toISOString(),
        generated_timezone: "America/Montevideo",
        capacity: 1,
      })
      .select()
      .single();
    expect(occ1Error).toBeNull();
    // The BEFORE INSERT trigger must have copied is_exclusive from the Resource.
    expect(occ1!.resource_is_exclusive).toBe(true);

    // Overlaps occ1 (10:00-11:00 vs 10:30-11:30), different start_at so it
    // does not collide with the (schedule_rule_id, start_at) unique index --
    // only the exclusion constraint should reject this.
    const overlapStart = new Date(base.getTime() + 30 * 60_000);
    const { error: occ2Error } = await admin.from("slot_occurrences").insert({
      organization_id: org.id,
      schedule_rule_id: rule!.id,
      service_id: serviceA.id,
      resource_id: resource.id,
      start_at: overlapStart.toISOString(),
      end_at: new Date(overlapStart.getTime() + 60 * 60_000).toISOString(),
      generated_timezone: "America/Montevideo",
      capacity: 1,
    });
    expect(occ2Error).not.toBeNull();
    expect(occ2Error!.message).toMatch(/slot_occurrences_exclusive_resource_no_overlap/);

    // '[)' semantics: back-to-back occurrences (11:00-12:00 right after
    // 10:00-11:00) must NOT count as an overlap.
    const backToBackStart = new Date(base.getTime() + 60 * 60_000);
    const { error: backToBackError } = await admin.from("slot_occurrences").insert({
      organization_id: org.id,
      schedule_rule_id: rule!.id,
      service_id: serviceA.id,
      resource_id: resource.id,
      start_at: backToBackStart.toISOString(),
      end_at: new Date(backToBackStart.getTime() + 60 * 60_000).toISOString(),
      generated_timezone: "America/Montevideo",
      capacity: 1,
    });
    expect(backToBackError).toBeNull();
  });

  it("(b) the generator skips a conflicting occurrence without aborting the rest of the rule", async () => {
    const resource = await createResource("Barbero exclusivo B", true);

    // ruleA: auto-generates immediately (is_active defaults to true),
    // weekly on the same weekday at 10:00.
    const weekday = weekdayInTwoDays();
    const { data: ruleA } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceA.id,
        resource_id: resource.id,
        weekday,
        local_start_time: "10:00",
        duration_minutes: 60,
        capacity: 1,
        created_by: owner.id,
      })
      .select()
      .single();

    const { data: occurrencesA } = await owner.client
      .from("slot_occurrences")
      .select("id, start_at")
      .eq("schedule_rule_id", ruleA!.id)
      .order("start_at", { ascending: true });
    expect(occurrencesA!.length).toBeGreaterThan(1);
    const collideDate = localDateOf(occurrencesA![0]!.start_at);

    // ruleB: same weekday, different time (14:00) so it does not
    // ordinarily conflict with ruleA -- created inactive so nothing
    // auto-generates yet.
    const { data: ruleB } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceB.id,
        resource_id: resource.id,
        weekday,
        local_start_time: "14:00",
        duration_minutes: 60,
        capacity: 1,
        is_active: false,
        created_by: owner.id,
      })
      .select()
      .single();

    // Force exactly one of ruleB's future dates (the same calendar date as
    // ruleA's first occurrence) to also start at 10:00 -- an exact
    // collision with ruleA on that single date. Since ruleB has no
    // materialized occurrences yet (is_active was false), the
    // reconciliation trigger on schedule_exceptions finds nothing to
    // update and is a no-op here -- only the generator (invoked below)
    // actually attempts this insert.
    const { error: exceptionError } = await owner.client.from("schedule_exceptions").insert({
      organization_id: org.id,
      schedule_rule_id: ruleB!.id,
      exception_date: collideDate,
      exception_type: "MODIFIED",
      modified_local_start_time: "10:00",
      modified_duration_minutes: 60,
      created_by: owner.id,
    });
    expect(exceptionError).toBeNull();

    // Activate ruleB -- toggling is_active alone does not trigger
    // trigger_regenerate_on_schedule_rule_update (it only watches
    // weekday/local_start_time/duration_minutes/capacity/resource_id/valid_until),
    // so generation has to be invoked explicitly, same as the daily cron would.
    const { error: activateError } = await owner.client
      .from("schedule_rules")
      .update({ is_active: true })
      .eq("id", ruleB!.id);
    expect(activateError).toBeNull();

    const { error: generateError } = await admin.rpc("generate_slot_occurrences_for_rule", {
      p_schedule_rule_id: ruleB!.id,
    });
    // The RPC call itself must succeed even though one date was skipped
    // internally -- this is the whole point of ADR-0044's generator change.
    expect(generateError).toBeNull();

    const { data: occurrencesB } = await owner.client
      .from("slot_occurrences")
      .select("id, start_at")
      .eq("schedule_rule_id", ruleB!.id)
      .order("start_at", { ascending: true });

    // Every other week's occurrence was still created...
    expect(occurrencesB!.length).toBeGreaterThan(1);
    // ...but none of them landed on the colliding date: that one insert
    // hit exclusion_violation and was skipped, not retried, not aborting
    // the rest of the loop.
    const datesB = occurrencesB!.map((o) => localDateOf(o.start_at));
    expect(datesB).not.toContain(collideDate);

    // And ruleA's occurrence on that date is untouched and still the only
    // ACTIVE occurrence of this Resource at that instant.
    const { data: resourceOccurrencesOnCollideDate } = await owner.client
      .from("slot_occurrences")
      .select("id, schedule_rule_id")
      .eq("resource_id", resource.id)
      .eq("status", "ACTIVE")
      .gte("start_at", `${collideDate}T00:00:00Z`)
      .lt("start_at", `${collideDate}T23:59:59Z`);
    const idsOnCollideDate = resourceOccurrencesOnCollideDate!.map((o) => o.schedule_rule_id);
    expect(idsOnCollideDate).toContain(ruleA!.id);
    expect(idsOnCollideDate).not.toContain(ruleB!.id);
  });

  it("(c) check_schedule_rule_conflicts detects a conflict before create_schedule_rule_group inserts anything", async () => {
    const resource = await createResource("Barbero exclusivo C", true);
    const weekday = weekdayInTwoDays();

    const { data: existingRules, error: createError } = await owner.client.rpc(
      "create_schedule_rule_group",
      {
        p_service_id: serviceA.id,
        p_resource_id: resource.id,
        p_weekdays: [weekday],
        p_local_start_time: "10:00",
        p_duration_minutes: 60,
        p_capacity: 1,
      },
    );
    expect(createError).toBeNull();
    expect(existingRules!.length).toBe(1);

    // Direct call: the same weekday+time now conflicts.
    const { data: conflicts, error: conflictsError } = await owner.client.rpc(
      "check_schedule_rule_conflicts",
      {
        p_resource_id: resource.id,
        p_weekday: [weekday],
        p_local_start_time: ["10:00"],
        p_duration_minutes: 60,
      },
    );
    expect(conflictsError).toBeNull();
    expect(conflicts.length).toBeGreaterThan(0);

    // A non-overlapping time has no conflicts.
    const { data: noConflicts, error: noConflictsError } = await owner.client.rpc(
      "check_schedule_rule_conflicts",
      {
        p_resource_id: resource.id,
        p_weekday: [weekday],
        p_local_start_time: ["16:00"],
        p_duration_minutes: 60,
      },
    );
    expect(noConflictsError).toBeNull();
    expect(noConflicts).toEqual([]);

    // create_schedule_rule_group rejects the conflicting request up front,
    // with a readable error -- and, crucially, inserts nothing (no
    // half-created group of rules).
    const { error: secondGroupError } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: serviceB.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_local_start_time: "10:00",
      p_duration_minutes: 60,
      p_capacity: 1,
    });
    expect(secondGroupError).not.toBeNull();
    expect(secondGroupError!.message).toMatch(/RESOURCE_SCHEDULE_CONFLICT/);

    const { data: rulesForServiceB } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("service_id", serviceB.id)
      .eq("resource_id", resource.id);
    expect(rulesForServiceB).toEqual([]);

    // A non-overlapping time succeeds normally.
    const { error: thirdGroupError } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: serviceB.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_local_start_time: "16:00",
      p_duration_minutes: 60,
      p_capacity: 1,
    });
    expect(thirdGroupError).toBeNull();
  });

  it("(d) activating is_exclusive on a Resource with existing overlaps is rejected by the constraint", async () => {
    const resource = await createResource("Sala compartida D", false);
    const weekday = weekdayInTwoDays();

    // Two overlapping rules on a NON-exclusive resource -- allowed, same as
    // pre-ADR-0044 behaviour (e.g. two classes sharing one room).
    const { data: ruleC } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceA.id,
        resource_id: resource.id,
        weekday,
        local_start_time: "10:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: owner.id,
      })
      .select()
      .single();
    const { error: ruleDError } = await owner.client.from("schedule_rules").insert({
      organization_id: org.id,
      service_id: serviceB.id,
      resource_id: resource.id,
      weekday,
      local_start_time: "10:30",
      duration_minutes: 60,
      capacity: 10,
      created_by: owner.id,
    });
    expect(ruleDError).toBeNull();

    const { data: occurrencesC } = await owner.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", ruleC!.id);
    expect(occurrencesC!.length).toBeGreaterThan(0);

    // Flipping is_exclusive to true propagates onto those overlapping
    // future ACTIVE occurrences, which is exactly what the exclusion
    // constraint exists to reject -- surfaced here as a raw Postgres
    // exclusion_violation (SQLSTATE 23P01); the frontend layer maps this
    // to the friendly RESOURCE_HAS_OVERLAPS message per ADR-0044's
    // "Impacto" section.
    const { error: activateError } = await owner.client
      .from("resources")
      .update({ is_exclusive: true })
      .eq("id", resource.id);
    expect(activateError).not.toBeNull();
    expect(activateError!.code).toBe("23P01");
    expect(activateError!.message).toMatch(/slot_occurrences_exclusive_resource_no_overlap/);

    // The whole update was rolled back -- the resource is still not exclusive.
    const { data: resourceAfter } = await owner.client
      .from("resources")
      .select("is_exclusive")
      .eq("id", resource.id)
      .single();
    expect(resourceAfter!.is_exclusive).toBe(false);
  });

  it("(e) a non-exclusive Resource keeps allowing overlapping occurrences freely", async () => {
    const resource = await createResource("Sala compartida E", false);
    const weekday = weekdayInTwoDays();

    const { data: ruleE, error: ruleEError } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceA.id,
        resource_id: resource.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 20,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(ruleEError).toBeNull();

    // Exact same weekday and start time on the same resource -- would
    // conflict instantly if this resource were exclusive.
    const { data: ruleF, error: ruleFError } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: org.id,
        service_id: serviceB.id,
        resource_id: resource.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 20,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(ruleFError).toBeNull();

    const { data: occurrencesE } = await owner.client
      .from("slot_occurrences")
      .select("id, resource_is_exclusive")
      .eq("schedule_rule_id", ruleE!.id);
    const { data: occurrencesF } = await owner.client
      .from("slot_occurrences")
      .select("id, resource_is_exclusive")
      .eq("schedule_rule_id", ruleF!.id);

    expect(occurrencesE!.length).toBeGreaterThan(0);
    expect(occurrencesF!.length).toBeGreaterThan(0);
    for (const occ of [...occurrencesE!, ...occurrencesF!]) {
      expect(occ.resource_is_exclusive).toBe(false);
    }
  });
});
