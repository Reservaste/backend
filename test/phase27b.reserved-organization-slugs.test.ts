// Integration tests for Phase 27b: organizations_slug_not_reserved_check --
// una organización no puede tomar como slug un segmento top-level de
// frontend/app/ (capturaría /equipo/[token], /activar/[token], /login...).
// Requiere un Supabase local corriendo (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import { RESERVED_ORGANIZATION_SLUGS } from "../src/schemas";
import { admin, createInvite, createSignedInUser, type SignedInUser } from "./helpers";

const createdUserIds: string[] = [];

afterAll(async () => {
  for (const id of createdUserIds) {
    await admin.auth.admin.deleteUser(id).catch(() => {});
  }
});

async function freshOwner(prefix: string): Promise<SignedInUser> {
  const owner = await createSignedInUser(prefix);
  createdUserIds.push(owner.id);
  return owner;
}

async function tryCreateOrganization(owner: SignedInUser, slug: string) {
  const inviteCode = await createInvite("full");
  return owner.client.rpc("create_organization_with_owner", {
    p_slug: slug,
    p_name: "Test Org",
    p_timezone: "America/Montevideo",
    p_invite_code: inviteCode,
  });
}

describe("Phase 27b: reserved organization slugs", () => {
  it("rechaza cada slug reservado con SLUG_RESERVED (o INVALID_SLUG si ni siquiera tiene formato válido)", async () => {
    const owner = await freshOwner("p27b-reserved");
    for (const slug of RESERVED_ORGANIZATION_SLUGS) {
      const { data, error } = await tryCreateOrganization(owner, slug);
      expect(data, `slug "${slug}" should have been rejected`).toBeNull();
      expect(error, `slug "${slug}"`).not.toBeNull();
      // `_next` no pasa el formato (guion bajo): lo corta el CHECK de la
      // Fase 27 antes. Todos los demás son slugs bien formados que sólo el
      // constraint nuevo rechaza.
      const expected = slug === "_next" ? /INVALID_SLUG/ : /SLUG_RESERVED/;
      expect(error!.message, `slug "${slug}"`).toMatch(expected);
    }

    // Ninguna quedó creada, y la invitación no se consumió en falso.
    const { data: orgs } = await admin
      .from("organizations")
      .select("slug")
      .in("slug", [...RESERVED_ORGANIZATION_SLUGS]);
    expect(orgs).toEqual([]);
  });

  it("el CHECK aplica también a una escritura que no pasa por la RPC", async () => {
    // service_role (BYPASSRLS) insertando directo: sólo el constraint lo para.
    const { data: profile } = await admin.from("profiles").select("id").limit(1).single();
    const { error } = await admin.from("organizations").insert({
      slug: "equipo",
      name: "Directo",
      timezone: "America/Montevideo",
      created_by: profile!.id,
    });
    expect(error).not.toBeNull();
    expect(error!.message).toContain("organizations_slug_not_reserved_check");
  });

  it("un slug que sólo CONTIENE una palabra reservada sigue funcionando", async () => {
    const owner = await freshOwner("p27b-valid");
    const slug = `equipo-norte-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const { data, error } = await tryCreateOrganization(owner, slug);
    expect(error).toBeNull();
    expect((data as { slug: string }).slug).toBe(slug);
  });
});
