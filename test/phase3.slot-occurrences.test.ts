// Integration tests for Phase 3 (ScheduleRule, ScheduleException,
// SlotOccurrence): the generation function's timezone conversion,
// idempotency, exception reconciliation, and cross-tenant isolation.
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, createOrganization, createSignedInUser, type SignedInUser } from "./helpers";

// The generation function walks forward from `greatest(valid_from, today)`
// to the next matching weekday, so tests target "the weekday two days from
// now" -- close enough to land inside the default 90-day horizon and far
// enough to always be a genuinely future occurrence, regardless of which
// day the suite happens to run on.
function weekdayInTwoDays(): number {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 2);
  return d.getUTCDay();
}

describe("Phase 3: schedule rules and slot occurrence generation", () => {
  let ownerA: SignedInUser;
  let ownerB: SignedInUser;
  let orgA: { id: string; slug: string };
  let orgB: { id: string; slug: string };
  let serviceA: { id: string };
  let resourceA: { id: string };
  const createdUserIds: string[] = [];

  beforeAll(async () => {
    ownerA = await createSignedInUser("p3-owner-a");
    ownerB = await createSignedInUser("p3-owner-b");
    createdUserIds.push(ownerA.id, ownerB.id);

    orgA = await createOrganization(ownerA, "p3-org-a");
    orgB = await createOrganization(ownerB, "p3-org-b");

    const { data: svc } = await ownerA.client
      .from("services")
      .insert({ organization_id: orgA.id, name: "CrossFit", created_by: ownerA.id })
      .select()
      .single();
    serviceA = svc!;

    const { data: res } = await ownerA.client
      .from("resources")
      .insert({ organization_id: orgA.id, name: "Sala principal", created_by: ownerA.id })
      .select()
      .single();
    resourceA = res!;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("generates occurrences synchronously when a ScheduleRule is created, converted to the correct UTC instant", async () => {
    const weekday = weekdayInTwoDays();

    const { data: rule, error: ruleError } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: serviceA.id,
        resource_id: resourceA.id,
        weekday,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 12,
        created_by: ownerA.id,
      })
      .select()
      .single();
    expect(ruleError).toBeNull();

    const { data: occurrences, error: occError } = await ownerA.client
      .from("slot_occurrences")
      .select("*")
      .eq("schedule_rule_id", rule!.id)
      .order("start_at", { ascending: true });

    expect(occError).toBeNull();
    expect(occurrences!.length).toBeGreaterThan(0);

    const first = occurrences![0]!;
    expect(first.capacity).toBe(12);
    expect(first.status).toBe("ACTIVE");
    expect(first.generated_timezone).toBe("America/Montevideo");

    // The whole point of ADR-0014: convert the instant back to the
    // Organization's local time and confirm it really is 09:00 on the
    // configured weekday -- not just "some timestamp got inserted".
    const localParts = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Montevideo",
      weekday: "short",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(first.start_at));
    const partMap = Object.fromEntries(localParts.map((p) => [p.type, p.value]));
    expect(`${partMap.hour}:${partMap.minute}`).toBe("09:00");

    const weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    expect(partMap.weekday).toBe(weekdayNames[weekday]);

    // end_at is exactly duration_minutes after start_at.
    const durationMs = new Date(first.end_at).getTime() - new Date(first.start_at).getTime();
    expect(durationMs).toBe(60 * 60 * 1000);
  });

  it("is idempotent: re-running generation for the same rule does not duplicate occurrences", async () => {
    const weekday = weekdayInTwoDays();

    const { data: rule } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: serviceA.id,
        resource_id: resourceA.id,
        weekday,
        local_start_time: "18:00",
        duration_minutes: 45,
        capacity: 8,
        created_by: ownerA.id,
      })
      .select()
      .single();

    const countOccurrences = async () => {
      const { count } = await ownerA.client
        .from("slot_occurrences")
        .select("id", { count: "exact", head: true })
        .eq("schedule_rule_id", rule!.id);
      return count;
    };

    const initialCount = await countOccurrences();
    expect(initialCount).toBeGreaterThan(0);

    // Re-run the same generation the daily cron/lazy fallback would run --
    // via the service-role client since this function isn't (and
    // shouldn't be) exposed to authenticated users directly.
    const { error } = await admin.rpc("generate_slot_occurrences_for_rule", {
      p_schedule_rule_id: rule!.id,
    });
    expect(error).toBeNull();

    const afterRerunCount = await countOccurrences();
    expect(afterRerunCount).toBe(initialCount);
  });

  it("reconciles a CANCELLED exception onto an already-materialized occurrence", async () => {
    const weekday = weekdayInTwoDays();

    const { data: rule } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: serviceA.id,
        resource_id: resourceA.id,
        weekday,
        local_start_time: "07:00",
        duration_minutes: 30,
        capacity: 5,
        created_by: ownerA.id,
      })
      .select()
      .single();

    const { data: occurrencesBefore } = await ownerA.client
      .from("slot_occurrences")
      .select("id, start_at")
      .eq("schedule_rule_id", rule!.id)
      .order("start_at", { ascending: true });
    const target = occurrencesBefore![0]!;

    // Convert the target occurrence's instant to its local calendar date
    // in the org's timezone -- the exception is keyed by that local date,
    // same as the reconciliation trigger does internally.
    const localDate = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Montevideo" }).format(
      new Date(target.start_at),
    );

    const { error: exceptionError } = await ownerA.client.from("schedule_exceptions").insert({
      organization_id: orgA.id,
      schedule_rule_id: rule!.id,
      exception_date: localDate,
      exception_type: "CANCELLED",
      created_by: ownerA.id,
    });
    expect(exceptionError).toBeNull();

    const { data: reconciled } = await ownerA.client
      .from("slot_occurrences")
      .select("status, cancellation_reason")
      .eq("id", target.id)
      .single();

    expect(reconciled?.status).toBe("CANCELLED");
    expect(reconciled?.cancellation_reason).toBe("SLOT_CANCELLED");
  });

  it("cancel_slot_occurrence sets audit fields, and a direct write to status=CANCELLED is blocked", async () => {
    const { data: rule } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: serviceA.id,
        resource_id: resourceA.id,
        weekday: weekdayInTwoDays(),
        local_start_time: "12:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: ownerA.id,
      })
      .select()
      .single();

    const { data: occurrences } = await ownerA.client
      .from("slot_occurrences")
      .select("id")
      .eq("schedule_rule_id", rule!.id)
      .limit(1);
    const occurrenceId = occurrences![0]!.id;

    // Direct write attempting CANCELLED is rejected by the RLS with-check
    // (must go through the RPC so audit fields are set atomically).
    const { error: directWriteError } = await ownerA.client
      .from("slot_occurrences")
      .update({ status: "CANCELLED" })
      .eq("id", occurrenceId);
    expect(directWriteError).not.toBeNull();

    // BLOCKED is allowed as a direct, reversible toggle.
    const { error: blockError } = await ownerA.client
      .from("slot_occurrences")
      .update({ status: "BLOCKED" })
      .eq("id", occurrenceId);
    expect(blockError).toBeNull();

    const { data: cancelResult, error: rpcError } = await ownerA.client.rpc("cancel_slot_occurrence", {
      p_slot_occurrence_id: occurrenceId,
    });
    expect(rpcError).toBeNull();
    expect(cancelResult.status).toBe("CANCELLED");
    expect(cancelResult.cancelled_by).toBe(ownerA.id);
    expect(cancelResult.cancellation_reason).toBe("SLOT_CANCELLED");
  });

  it("rejects a ScheduleRule pairing a Service and Resource from different organizations", async () => {
    const { data: resourceB } = await ownerB.client
      .from("resources")
      .insert({ organization_id: orgB.id, name: "Otra sala", created_by: ownerB.id })
      .select()
      .single();

    const { error } = await ownerA.client.from("schedule_rules").insert({
      organization_id: orgA.id,
      service_id: serviceA.id,
      resource_id: resourceB!.id,
      weekday: 1,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 10,
    });
    expect(error).not.toBeNull();
  });

  it("blocks an OWNER of a different org from seeing another org's schedule rules and occurrences", async () => {
    const { data: rules, error: rulesError } = await ownerB.client
      .from("schedule_rules")
      .select("id")
      .eq("organization_id", orgA.id);
    expect(rulesError).toBeNull();
    expect(rules).toEqual([]);

    const { data: occurrences, error: occError } = await ownerB.client
      .from("slot_occurrences")
      .select("id")
      .eq("organization_id", orgA.id);
    expect(occError).toBeNull();
    expect(occurrences).toEqual([]);
  });

  it("discontinuing a ScheduleRule cascades to cancel its future occurrences", async () => {
    const { data: rule } = await ownerA.client
      .from("schedule_rules")
      .insert({
        organization_id: orgA.id,
        service_id: serviceA.id,
        resource_id: resourceA.id,
        weekday: weekdayInTwoDays(),
        local_start_time: "20:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: ownerA.id,
      })
      .select()
      .single();

    const { error } = await ownerA.client.rpc("discontinue_schedule_rule", {
      p_schedule_rule_id: rule!.id,
    });
    expect(error).toBeNull();

    const { data: occurrences } = await ownerA.client
      .from("slot_occurrences")
      .select("status, cancellation_reason")
      .eq("schedule_rule_id", rule!.id);

    expect(occurrences!.length).toBeGreaterThan(0);
    for (const occ of occurrences!) {
      expect(occ.status).toBe("CANCELLED");
      expect(occ.cancellation_reason).toBe("RULE_DISCONTINUED");
    }

    const { data: ruleAfter } = await ownerA.client
      .from("schedule_rules")
      .select("is_active, cancellation_reason")
      .eq("id", rule!.id)
      .single();
    expect(ruleAfter?.is_active).toBe(false);
    expect(ruleAfter?.cancellation_reason).toBe("DISCONTINUED_BY_ORGANIZATION");
  });
});
