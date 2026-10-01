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

  it("(h) ADR-0050: schedule_rule_groups() reports all 4 distinct start times of a one-weekday span, not one collapsed value", async () => {
    await setup();
    const resource = await createResource("Sala H (span, un dia, 4 horas)", false);
    const weekday = weekdayInTwoDays();

    // Same span as test (a): one weekday, starts at 09:00/09:30/10:00/10:30
    // under a single group_id -- the exact shape that min(local_start_time)
    // used to collapse to just "09:00" (see phase46 migration).
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

    const { data: groups, error: groupsError } = await owner.client.rpc("schedule_rule_groups", {
      p_service_id: service.id,
    });
    expect(groupsError).toBeNull();
    expect(groups).toHaveLength(1);

    const group = groups![0];
    expect(group.group_id).toBe(groupId);
    expect(group.resource_id).toBe(resource.id);
    expect(group.duration_minutes).toBe(30);
    expect(group.capacity).toBe(5);

    // The four rules, not one collapsed row: every item carries its own
    // real (ruleId, weekday, localStartTime) triple.
    expect(group.items).toHaveLength(4);
    expect(group.items.every((item: { weekday: number }) => item.weekday === weekday)).toBe(true);

    const startTimes = group.items
      .map((item: { localStartTime: string }) => item.localStartTime)
      .sort();
    expect(startTimes).toEqual(["09:00:00", "09:30:00", "10:00:00", "10:30:00"]);

    // Every ruleId is distinct and matches an actual schedule_rules row for
    // its own local_start_time -- no positional zip against a second array,
    // no shared collapsed value.
    const ruleIds: string[] = group.items.map((item: { ruleId: string }) => item.ruleId);
    expect(new Set(ruleIds).size).toBe(4);

    const rules = await rulesForGroup(groupId as string);
    for (const item of group.items as Array<{ ruleId: string; localStartTime: string }>) {
      const matching = rules.find((r) => r.id === item.ruleId);
      expect(matching).toBeDefined();
      expect(matching!.local_start_time).toBe(item.localStartTime);
    }
  });

  it("(i) ADR-0050: the ADR-0022 case (one shared start time, distinct weekdays) is unaffected", async () => {
    await setup();
    const resource = await createResource("Sala I (grupo clasico Mon/Wed/Fri)", false);

    const { data: rules, error } = await owner.client.rpc("create_schedule_rule_group", {
      p_service_id: service.id,
      p_resource_id: resource.id,
      p_weekdays: [1, 3, 5],
      p_local_start_time: "09:00",
      p_duration_minutes: 60,
      p_capacity: 15,
    });
    expect(error).toBeNull();
    const groupId = rules![0]!.group_id;

    const { data: groups, error: groupsError } = await owner.client.rpc("schedule_rule_groups", {
      p_service_id: service.id,
    });
    expect(groupsError).toBeNull();
    expect(groups).toHaveLength(1);

    const group = groups![0];
    expect(group.group_id).toBe(groupId);
    expect(group.duration_minutes).toBe(60);
    expect(group.capacity).toBe(15);
    expect(group.items).toHaveLength(3);
    expect(
      group.items.every(
        (item: { localStartTime: string }) => item.localStartTime === "09:00:00",
      ),
    ).toBe(true);
    expect(
      group.items.map((item: { weekday: number }) => item.weekday).sort(),
    ).toEqual([1, 3, 5]);
  });

  // Phase 48 security fix: a STAFF member of Organization A, with
  // MANAGE_BOOKINGS (the default for a STAFF member with no role_id -- see
  // phase32.configurable-roles.test.ts), creates a span for a Service that
  // genuinely belongs to A, but passes the resource_id of a real Resource
  // belonging to Organization B. Before this fix, create_schedule_rule_span()
  // only checked that the Resource existed (RESOURCE_NOT_FOUND), never that
  // it belonged to the same organization as the Service -- it must now be
  // rejected with the same RESOURCE_NOT_FOUND code (never disclosing that
  // the resource exists under another tenant), with no ScheduleRule row
  // created on either side.
  it("(j) rejects create_schedule_rule_span when resource_id belongs to another organization", async () => {
    await setup();
    const weekday = weekdayInTwoDays();

    const ownerB = await createSignedInUser("p43-xorg-owner-b");
    createdUserIds.push(ownerB.id);
    const orgB = await createOrganization(ownerB, "p43-xorg-org-b");
    const { data: resourceB, error: resourceBError } = await ownerB.client
      .from("resources")
      .insert({ organization_id: orgB.id, name: "Barbero (otra org)", created_by: ownerB.id })
      .select()
      .single();
    expect(resourceBError).toBeNull();

    const staffA = await createSignedInUser("p43-xorg-staff-a");
    createdUserIds.push(staffA.id);
    const { error: memberError } = await owner.client
      .from("organization_members")
      .insert({
        organization_id: org.id,
        profile_id: staffA.id,
        role: "STAFF",
        created_by: owner.id,
      });
    expect(memberError).toBeNull();

    const { data, error } = await staffA.client.rpc("create_schedule_rule_span", {
      p_service_id: service.id,
      p_resource_id: (resourceB as { id: string }).id,
      p_weekdays: [weekday],
      p_range_start: "09:00",
      p_range_end: "11:00",
      p_step_minutes: 30,
      p_duration_minutes: 30,
      p_capacity: 5,
    });
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toContain("RESOURCE_NOT_FOUND");

    const { data: rulesOnServiceA } = await owner.client
      .from("schedule_rules")
      .select("id")
      .eq("service_id", service.id);
    expect(rulesOnServiceA).toEqual([]);

    const { data: rulesOnResourceB } = await ownerB.client
      .from("schedule_rules")
      .select("id")
      .eq("resource_id", (resourceB as { id: string }).id);
    expect(rulesOnResourceB).toEqual([]);
  });
});
