// Integration tests for Phase 30b: keyset pagination of
// `organization_audit_log()` by (created_at, id). Requiere un Supabase local
// corriendo (`npx supabase start`).
//
// El bug que cierra: cancel_slot_occurrence() cancela N reservas en un solo
// UPDATE, así que el trigger escribe N filas de audit_log con el MISMO
// created_at (now() = inicio de la transacción). Con el corte viejo
// `created_at < p_before`, si el límite de página caía dentro de ese grupo,
// el resto del grupo no aparecía en ninguna página.

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  createOrganization,
  createSignedInUser,
  firstFutureOccurrence,
  type SignedInUser,
} from "./helpers";

interface AuditLogRpcRow {
  id: string;
  action: string;
  target_id: string;
  created_at: string;
}

const BOOKINGS = 7;
const PAGE = 3;

describe("Phase 30b: organization_audit_log() keyset cursor", () => {
  const createdUserIds: string[] = [];
  let owner: SignedInUser;
  let orgId: string;
  let bookingIds: string[] = [];

  beforeAll(async () => {
    owner = await createSignedInUser("p30b");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p30b-org");
    orgId = org.id;

    const { data: service } = await owner.client
      .from("services")
      .insert({ organization_id: orgId, name: "Pilates", created_by: owner.id })
      .select()
      .single();
    const { data: resource } = await owner.client
      .from("resources")
      .insert({ organization_id: orgId, name: "Sala", created_by: owner.id })
      .select()
      .single();
    const { data: rule } = await owner.client
      .from("schedule_rules")
      .insert({
        organization_id: orgId,
        service_id: service!.id,
        resource_id: resource!.id,
        weekday: (new Date().getUTCDay() + 2) % 7,
        local_start_time: "09:00",
        duration_minutes: 60,
        capacity: 10,
        created_by: owner.id,
      })
      .select()
      .single();

    const occ = await firstFutureOccurrence(owner, rule!.id as string);

    // Clientes gestionados (profile_id NULL): la reserva y la cancelación
    // son del mostrador, así que las dos se auditan.
    for (let i = 0; i < BOOKINGS; i++) {
      const { data: customer, error: customerErr } = await owner.client.rpc(
        "create_managed_customer",
        { p_organization_id: orgId, p_display_name: `Cliente ${i}`, p_phone: null },
      );
      expect(customerErr).toBeNull();
      const booked = await owner.client.rpc("admin_book_for_customer", {
        p_slot_occurrence_id: occ.id,
        p_customer_id: customer!.id,
      });
      expect(booked.error).toBeNull();
      expect(booked.data.status).toBe("OK");
      bookingIds.push(booked.data.booking.id as string);
    }

    // Una sola transacción cancela las N reservas.
    const cancelled = await owner.client.rpc("cancel_slot_occurrence", {
      p_slot_occurrence_id: occ.id,
    });
    expect(cancelled.error).toBeNull();
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("las N cancelaciones de una misma transacción comparten created_at (precondición del bug)", async () => {
    const { data, error } = await admin
      .from("audit_log")
      .select("created_at")
      .eq("organization_id", orgId)
      .eq("action", "BOOKING_CANCELLED_BY_STAFF");
    expect(error).toBeNull();
    expect(data).toHaveLength(BOOKINGS);
    expect(new Set(data!.map((r) => r.created_at)).size).toBe(1);
  });

  it("paginando con un límite chico, todas las filas aparecen exactamente una vez", async () => {
    const { data: all } = await admin.from("audit_log").select("id").eq("organization_id", orgId);
    const expectedIds = new Set(all!.map((r) => r.id as string));
    // BOOKINGS altas + BOOKINGS cancelaciones.
    expect(expectedIds.size).toBe(BOOKINGS * 2);

    const seen: AuditLogRpcRow[] = [];
    let cursor: { created_at: string; id: string } | null = null;
    for (let guard = 0; guard < 20; guard++) {
      const { data, error } = await owner.client.rpc("organization_audit_log", {
        p_organization_id: orgId,
        p_limit: PAGE,
        p_before_created_at: cursor?.created_at ?? null,
        p_before_id: cursor?.id ?? null,
      });
      expect(error).toBeNull();
      const page = (data ?? []) as AuditLogRpcRow[];
      seen.push(...page);
      if (page.length < PAGE) break;
      // El cursor se pasa TAL CUAL vino (string con microsegundos).
      const last = page.at(-1)!;
      cursor = { created_at: last.created_at, id: last.id };
    }

    const seenIds = seen.map((r) => r.id);
    expect(new Set(seenIds).size).toBe(seenIds.length); // sin duplicados
    expect(new Set(seenIds)).toEqual(expectedIds); // sin faltantes

    const cancelledTargets = seen
      .filter((r) => r.action === "BOOKING_CANCELLED_BY_STAFF")
      .map((r) => r.target_id)
      .sort();
    expect(cancelledTargets).toEqual([...bookingIds].sort());

    // Orden total: created_at desc, id desc, sin saltos entre páginas.
    for (let i = 1; i < seen.length; i++) {
      const prev = seen[i - 1]!;
      const cur = seen[i]!;
      const prevT = Date.parse(prev.created_at);
      const curT = Date.parse(cur.created_at);
      expect(prevT >= curT).toBe(true);
      if (prev.created_at === cur.created_at) {
        expect(prev.id > cur.id).toBe(true);
      }
    }
  });

  it("rechaza un cursor a medias con INVALID_CURSOR", async () => {
    const onlyDate = await owner.client.rpc("organization_audit_log", {
      p_organization_id: orgId,
      p_limit: PAGE,
      p_before_created_at: new Date().toISOString(),
      p_before_id: null,
    });
    expect(onlyDate.error?.message).toContain("INVALID_CURSOR");

    const onlyId = await owner.client.rpc("organization_audit_log", {
      p_organization_id: orgId,
      p_limit: PAGE,
      p_before_created_at: null,
      p_before_id: bookingIds[0],
    });
    expect(onlyId.error?.message).toContain("INVALID_CURSOR");
  });

  it("la firma vieja (p_before) ya no existe", async () => {
    const old = await owner.client.rpc("organization_audit_log", {
      p_organization_id: orgId,
      p_limit: PAGE,
      p_before: new Date().toISOString(),
    });
    expect(old.error).not.toBeNull();
  });
});
