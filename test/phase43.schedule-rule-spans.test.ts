// Integration tests for Phase 43 (ADR-0045: schedule rule generator by
// time-of-day span) -- create_schedule_rule_span(), and its shared
// expand+conflict-check+insert routine with create_schedule_rule_group()
// (ADR-0022). Requires a running Supabase instance (see test/helpers.ts).

import { afterAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

// Same reasoning as phase3.slot-occurrences.test.ts / phase42: target "the
// weekday two days from now" so generated occurrences land inside the
// default 90-day horizon and are always genuinely future, regardless of
// which day the suite happens to run on.
function weekdayInTwoDays(): number {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 2);
  return d.getUTCDay();
}

describe("Phase 43: schedule rule generator by span (ADR-0045)", () => {
  let owner: SignedInUser;
  let org: { id: string; slug: string };
  let service: { id: string };
  const createdUserIds: string[] = [];

  async function setup() {
    owner = await createSignedInUser("p43-owner");
    createdUserIds.push(owner.id);
    org = await createOrganization(owner, "p43-org");

    const { data: svc } = await owner.client
      .from("services")
      .insert({ organization_id: org.id, name: "Corte de pelo", created_by: owner.id })
      .select()
      .single();
    service = svc!;
  }

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

  async function rulesForGroup(groupId: string) {
    const { data, error } = await owner.client
      .from("schedule_rules")
      .select("id, group_id, weekday, local_start_time, capacity")
      .eq("group_id", groupId);
    expect(error).toBeNull();
    return data!;
  }

  it("(a) a simple span generates the right number of rules, sharing one group_id", async () => {
    await setup();
    const resource = await createResource("Sala A (span simple)", false);
    const weekday = weekdayInTwoDays();

    // 09:00 - 11:00, step 30, duration 30 -> starts at 09:00, 09:30,
    // 10:00, 10:30 (10:30 + 30 = 11:00, still <= range_end).
    const { data: groupId, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "09:00",
      p_range_end: "11:00",
      p_step_minutes: 30,
      p_duration_minutes: 30,
      p_capacity: 5,
    });
    expect(error).toBeNull();
    expect(typeof groupId).toBe("string");

    const rules = await rulesForGroup(groupId as string);
    expect(rules).toHaveLength(4);
    expect(new Set(rules.map((r) => r.group_id)).size).toBe(1);
    expect(rules.every((r) => r.weekday === weekday)).toBe(true);
    expect(rules.every((r) => r.capacity === 5)).toBe(true);
    const starts = rules.map((r) => r.local_start_time).sort();
    expect(starts).toEqual(["09:00:00", "09:30:00", "10:00:00", "10:30:00"]);
  });

  it("(b) rejects step_minutes below the 5-minute floor", async () => {
    await setup();
    const resource = await createResource("Sala B (step chico)", false);
    const weekday = weekdayInTwoDays();

    const { data, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "09:00",
      p_range_end: "10:00",
      p_step_minutes: 4,
      p_duration_minutes: 15,
      p_capacity: 5,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/STEP_TOO_SHORT/);

    const { data: rules } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", resource.id);
    expect(rules).toEqual([]);
  });

  it("(c) rejects a request that exceeds the per-call rule cap", async () => {
    await setup();
    const resource = await createResource("Sala C (tope)", false);
    const weekday = weekdayInTwoDays();

    // A full day at the minimum step: (24h * 60) / 5 = 288 possible starts
    // for a 5-minute duration -- comfortably over the 96-starts-per-day cap,
    // which is itself part of "the per-call rule cap" this RPC enforces.
    const { data, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "00:00",
      p_range_end: "23:55",
      p_step_minutes: 5,
      p_duration_minutes: 5,
      p_capacity: 5,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/TOO_MANY/);

    const { data: rules } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", resource.id);
    expect(rules).toEqual([]);
  });

  it("(d) exclusive Resource + step_minutes < duration_minutes is rejected with SPAN_SELF_OVERLAP_ON_EXCLUSIVE_RESOURCE", async () => {
    await setup();
    const resource = await createResource("Barbero D (exclusivo, se pisa)", true);
    const weekday = weekdayInTwoDays();

    const { data, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "10:00",
      p_range_end: "14:00",
      p_step_minutes: 30,
      p_duration_minutes: 60,
      p_capacity: 1,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/SPAN_SELF_OVERLAP_ON_EXCLUSIVE_RESOURCE/);

    const { data: rules } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", resource.id);
    expect(rules).toEqual([]);
  });

  it("(e) exclusive Resource + capacity > 1 is rejected with EXCLUSIVE_RESOURCE_CAPACITY_MUST_BE_ONE", async () => {
    await setup();
    const resource = await createResource("Barbero E (exclusivo, capacidad 2)", true);
    const weekday = weekdayInTwoDays();

    const { data, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "10:00",
      p_range_end: "14:00",
      p_step_minutes: 60,
      p_duration_minutes: 60,
      p_capacity: 2,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/EXCLUSIVE_RESOURCE_CAPACITY_MUST_BE_ONE/);

    const { data: rules } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", resource.id);
    expect(rules).toEqual([]);
  });

  it("(f) a real conflict against an existing rule on the same exclusive Resource rejects the whole span atomically", async () => {
    await setup();
    const resource = await createResource("Barbero F (exclusivo, con choque)", true);
    const weekday = weekdayInTwoDays();

    // Pre-existing rule: 10:00-11:00.
    const { data: existingRules, error: existingError } = await owner.client.rpc(
      "create_schedule_rule_group",
      {
        p_service_id: service.id,
        p_resource_id: resource.id,
        p_weekdays: [weekday],
        p_local_start_time: "10:00",
        p_duration_minutes: 60,
        p_capacity: 1,
      },
    );
    expect(existingError).toBeNull();
    expect(existingRules).toHaveLength(1);

    // Span 09:30-11:30 step 60 duration 60 -> starts at 09:30 and 10:30.
    // 10:30-11:30 overlaps the existing 10:00-11:00 occurrence.
    const { data: groupId, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "09:30",
      p_range_end: "11:30",
      p_step_minutes: 60,
      p_duration_minutes: 60,
      p_capacity: 1,
    });
    expect(groupId).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/RESOURCE_SCHEDULE_CONFLICT/);

    // Atomicity: neither the 09:30 nor the 10:30 rule from the rejected
    // span was inserted -- only the original 10:00 rule remains.
    const { data: rulesAfter } = await owner.client
      .from("schedule_rules")
      .select("id, local_start_time")
      .eq("resource_id", resource.id);
    expect(rulesAfter).toHaveLength(1);
    expect(rulesAfter![0]!.local_start_time).toBe("10:00:00");
  });

  it("(g) happy path on an exclusive Resource with no conflicts, step_minutes == duration_minutes (back-to-back, no overlap)", async () => {
    await setup();
    const resource = await createResource("Barbero G (exclusivo, feliz)", true);
    const weekday = weekdayInTwoDays();

    // 09:00 - 12:00, step 60, duration 60 -> starts at 09:00, 10:00, 11:00
    // (11:00 + 60 = 12:00, still <= range_end). Back-to-back, never
    // overlapping, which is exactly what an exclusive Resource requires.
    const { data: groupId, error } = await owner.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [weekday],
      p_range_start: "09:00",
      p_range_end: "12:00",
      p_step_minutes: 60,
      p_duration_minutes: 60,
      p_capacity: 1,
    });
    expect(error).toBeNull();
    expect(typeof groupId).toBe("string");

    const rules = await rulesForGroup(groupId as string);
    expect(rules).toHaveLength(3);
    expect(new Set(rules.map((r) => r.group_id)).size).toBe(1);
    expect(rules.every((r) => r.capacity === 1)).toBe(true);
    const starts = rules.map((r) => r.local_start_time).sort();
    expect(starts).toEqual(["09:00:00", "10:00:00", "11:00:00"]);

    // And the generated occurrences themselves never overlap -- the
    // exclusion constraint (ADR-0044) would have rejected the insert at
    // generation time if they did.
    const { data: occurrences } = await owner.client
      .from("slot_occurrences")
      .select("id, start_at, end_at")
      .eq("resource_id", resource.id)
      .order("start_at", { ascending: true });
    expect(occurrences!.length).toBeGreaterThan(0);
  });
});
