// Phase 24 -- landing contact requests (ADR-0030, resolution 2).
// Covers: anonymous insert via RPC, validation, rate limiting, RLS
// (direct table access denied to everyone), and the admin-only read/mark
// functions following the platform_organizations()/platform_invites()
// pattern (Phase 10).

import { createClient } from "@supabase/supabase-js";
import { afterAll, describe, expect, it } from "vitest";
import { ANON_KEY, SUPABASE_URL, admin, createSignedInUser } from "./helpers";

function freshAnon() {
  return createClient(SUPABASE_URL, ANON_KEY);
}

describe("Phase 24 -- platform contact requests (ADR-0030)", () => {
  // The rate limit is a global, time-windowed count(*) over this table (no
  // organization scope -- see the migration). Without cleanup, this file's
  // own rows (plus the deliberate padding in the last test) would still be
  // inside the 1h/1d window on the next run and trip RATE_LIMITED_HOURLY
  // for what should be ordinary, independent test runs. The table is fully
  // test-owned and isolated (no FK from any other table points into it),
  // so clearing it after the suite is safe.
  afterAll(async () => {
    await admin.from("platform_contact_requests").delete().gte("created_at", "1970-01-01T00:00:00Z");
  });

  it("an anonymous visitor can submit a valid contact request", async () => {
    const anon = freshAnon();
    const email = `lead-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;

    const { data, error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Ana Pérez",
      p_email: email,
      p_message: "Quiero agendar turnos para mi consultorio.",
      p_phone: "+59899123456",
      p_business_type: "Consultorio",
    });

    expect(error).toBeNull();
    expect(typeof data).toBe("string");

    // The row exists (verified through service_role, which bypasses RLS),
    // and the phone is normalized/validated the same way
    // create_managed_customer() does (E.164).
    const { data: row } = await admin
      .from("platform_contact_requests")
      .select("email, phone, handled_at")
      .eq("id", data)
      .single();
    expect(row?.email).toBe(email.toLowerCase());
    expect(row?.phone).toBe("+59899123456");
    expect(row?.handled_at).toBeNull();
  });

  it("phone and business_type are optional", async () => {
    const anon = freshAnon();
    const { data, error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Sin Telefono",
      p_email: `lead-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`,
      p_message: "Solo quiero info general.",
    });

    expect(error).toBeNull();
    expect(typeof data).toBe("string");
  });

  it("rejects an invalid email format", async () => {
    const anon = freshAnon();
    const { error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Formato Malo",
      p_email: "no-es-un-email",
      p_message: "algo",
    });
    expect(error?.message).toContain("INVALID_EMAIL");
  });

  it("rejects an empty message", async () => {
    const anon = freshAnon();
    const { error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Sin Mensaje",
      p_email: `lead-${Date.now()}@example.com`,
      p_message: "   ",
    });
    expect(error?.message).toContain("INVALID_MESSAGE");
  });

  it("rejects an empty name", async () => {
    const anon = freshAnon();
    const { error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "  ",
      p_email: `lead-${Date.now()}@example.com`,
      p_message: "algo",
    });
    expect(error?.message).toContain("INVALID_NAME");
  });

  it("rejects an unreasonably long message (no 1MB-of-text abuse)", async () => {
    const anon = freshAnon();
    const { error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Mensaje Largo",
      p_email: `lead-${Date.now()}@example.com`,
      p_message: "x".repeat(4001),
    });
    expect(error?.message).toContain("INVALID_MESSAGE");
  });

  it("rejects a malformed phone (leading zero after normalization)", async () => {
    const anon = freshAnon();
    const { error } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Telefono Malo",
      p_email: `lead-${Date.now()}@example.com`,
      p_message: "algo",
      p_phone: "0123456789",
    });
    expect(error?.message).toContain("INVALID_PHONE");
  });

  it("nobody can read the table directly -- RLS with zero policies, same as customer_activations", async () => {
    const anon = freshAnon();
    const direct = await anon.from("platform_contact_requests").select("*");
    expect(direct.data).toEqual([]);

    const person = await createSignedInUser("p24-nonadmin-read");
    const directAuthed = await person.client.from("platform_contact_requests").select("*");
    expect(directAuthed.data).toEqual([]);

    // Nor can anyone write to it directly, bypassing validation/rate limiting.
    const directInsert = await anon.from("platform_contact_requests").insert({
      name: "Bypass",
      email: "bypass@example.com",
      message: "trying to skip the RPC",
    });
    expect(directInsert.error).not.toBeNull();
  });

  it("a non-admin authenticated user gets an empty list, not an error", async () => {
    const person = await createSignedInUser("p24-nonadmin-list");
    const { data, error } = await person.client.rpc("platform_contact_requests");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("a non-admin cannot mark a request as handled", async () => {
    const anon = freshAnon();
    const { data: id } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Para Marcar",
      p_email: `lead-${Date.now()}@example.com`,
      p_message: "algo",
    });

    const person = await createSignedInUser("p24-nonadmin-mark");
    const { error } = await person.client.rpc("mark_contact_request_handled", { p_id: id });
    expect(error?.message).toContain("NOT_AUTHORIZED");
  });

  it("a platform admin can list and mark a contact request as handled", async () => {
    const anon = freshAnon();
    const email = `lead-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;
    const { data: id, error: submitError } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Cliente Interesado",
      p_email: email,
      p_message: "Quiero una demo.",
    });
    expect(submitError).toBeNull();

    const platformOwner = await createSignedInUser("p24-admin");
    await admin.from("platform_admins").insert({ profile_id: platformOwner.id, note: "test" });

    const list = await platformOwner.client.rpc("platform_contact_requests");
    expect(list.error).toBeNull();
    expect(list.data.some((r: { id: string; email: string }) => r.id === id && r.email === email)).toBe(true);

    const marked = await platformOwner.client.rpc("mark_contact_request_handled", { p_id: id });
    expect(marked.error).toBeNull();
    expect(marked.data.handled_at).not.toBeNull();
    expect(marked.data.handled_by).toBe(platformOwner.id);

    // Idempotent: marking again keeps the original handled_at/handled_by.
    const markedAgain = await platformOwner.client.rpc("mark_contact_request_handled", { p_id: id });
    expect(markedAgain.error).toBeNull();
    expect(markedAgain.data.handled_at).toBe(marked.data.handled_at);
  });

  it("marking a nonexistent request fails explicitly", async () => {
    const platformOwner = await createSignedInUser("p24-admin-missing");
    await admin.from("platform_admins").insert({ profile_id: platformOwner.id, note: "test" });

    const { error } = await platformOwner.client.rpc("mark_contact_request_handled", {
      p_id: "00000000-0000-0000-0000-000000000000",
    });
    expect(error?.message).toContain("CONTACT_REQUEST_NOT_FOUND");
  });

  // The rate limit is now per-origin (see the migration header comment):
  // every request in this whole test file comes from this same test
  // runner, so it shares one origin_ip bucket at the database. These two
  // tests each clear the table first so they're deterministic and don't
  // depend on how many real anon.rpc() calls earlier tests happened to
  // make, and don't interfere with each other either.
  it("rejects submissions once the per-origin hourly rate limit is reached", async () => {
    await admin.from("platform_contact_requests").delete().gte("created_at", "1970-01-01T00:00:00Z");

    const anon = freshAnon();
    // One real submission to learn what origin_ip the database assigned
    // to this test runner, so the padding below lands in the same
    // bucket the rate limit actually checks.
    const { data: firstId, error: firstError } = await anon.rpc("submit_platform_contact_request", {
      p_name: "Primero",
      p_email: `origin-probe-${Date.now()}@example.com`,
      p_message: "learns the origin_ip bucket",
    });
    expect(firstError).toBeNull();
    const { data: firstRow } = await admin
      .from("platform_contact_requests")
      .select("origin_ip")
      .eq("id", firstId)
      .single();
    const originIp = firstRow?.origin_ip;
    expect(originIp).toBeTruthy();

    // Pad up to just below the threshold (5): 1 real row already exists,
    // add 3 more directly (service_role bypasses the RPC/rate limit) so
    // the count is 4 -- the 5th request below should still be allowed.
    const { error: padError } = await admin.from("platform_contact_requests").insert(
      Array.from({ length: 3 }, (_, i) => ({
        name: `Padding ${i}`,
        email: `padding-${Date.now()}-${i}-${Math.random().toString(36).slice(2)}@example.com`,
        message: "padding row for rate limit test",
        origin_ip: originIp,
      })),
    );
    expect(padError).toBeNull();

    const fifth = await anon.rpc("submit_platform_contact_request", {
      p_name: "Quinto",
      p_email: `fifth-${Date.now()}@example.com`,
      p_message: "count is 4, this is the 5th -- should still pass",
    });
    expect(fifth.error).toBeNull();

    const sixth = await anon.rpc("submit_platform_contact_request", {
      p_name: "Deberia Ser Bloqueado",
      p_email: `blocked-${Date.now()}@example.com`,
      p_message: "this should be rate limited",
    });
    expect(sixth.error?.message).toContain("RATE_LIMITED");
  });

  it("rate-limits exactly at the per-origin threshold under concurrency, not more, not less (TOCTOU check)", async () => {
    // Everything in this test runs from the same test runner, so all N
    // requests below share one origin_ip bucket -- the "same origin"
    // case the task asked this test to cover. A count(*)-without-lock
    // implementation would let most/all of these N parallel requests
    // read the same pre-insert count and pass; the advisory-lock
    // serialization in the migration should instead admit exactly the
    // per-origin threshold (5) and reject the rest.
    await admin.from("platform_contact_requests").delete().gte("created_at", "1970-01-01T00:00:00Z");

    const CONCURRENT_REQUESTS = 8;
    const PER_ORIGIN_THRESHOLD = 5;

    const results = await Promise.all(
      Array.from({ length: CONCURRENT_REQUESTS }, (_, i) =>
        freshAnon().rpc("submit_platform_contact_request", {
          p_name: `Concurrente ${i}`,
          p_email: `concurrent-${Date.now()}-${i}-${Math.random().toString(36).slice(2)}@example.com`,
          p_message: "concurrent burst test",
        }),
      ),
    );

    const succeeded = results.filter((r) => r.error === null);
    const rateLimited = results.filter((r) => r.error?.message.includes("RATE_LIMITED"));

    expect(succeeded).toHaveLength(PER_ORIGIN_THRESHOLD);
    expect(rateLimited).toHaveLength(CONCURRENT_REQUESTS - PER_ORIGIN_THRESHOLD);

    const { count: actualRows } = await admin
      .from("platform_contact_requests")
      .select("id", { count: "exact", head: true });
    expect(actualRows).toBe(PER_ORIGIN_THRESHOLD);
  });
});
