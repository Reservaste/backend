// Integration tests for Phase 27: organizations_slug_format_check --
// mirrors organizationSlugSchema (backend/src/schemas.ts) as a CHECK
// constraint so create_organization_with_owner() rejects a malformed slug
// even when called directly via PostgREST, bypassing Zod entirely.
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
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

describe("Phase 27: organizations.slug format", () => {
  it("rejects a slug that is an absolute path (open-redirect vector)", async () => {
    const owner = await freshOwner("p27-evil1");
    const { data, error } = await tryCreateOrganization(owner, "/evil.com");
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVALID_SLUG/);
  });

  it("rejects a slug that is protocol-relative (//evil.com)", async () => {
    const owner = await freshOwner("p27-evil2");
    const { data, error } = await tryCreateOrganization(owner, "//evil.com");
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVALID_SLUG/);
  });

  it("rejects a slug with uppercase letters", async () => {
    const owner = await freshOwner("p27-upper");
    const { data, error } = await tryCreateOrganization(owner, "Iron-Gym");
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVALID_SLUG/);
  });

  it("rejects an empty slug", async () => {
    const owner = await freshOwner("p27-empty");
    const { data, error } = await tryCreateOrganization(owner, "");
    expect(data).toBeNull();
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVALID_SLUG/);
  });

  it("rejects a slug starting or ending with a hyphen, and a double hyphen", async () => {
    // None of these ever get inserted (the CHECK rejects them before the
    // unique constraint would even apply), so no uniqueness suffix needed.
    const owner = await freshOwner("p27-hyphen");
    for (const slug of ["-iron-gym", "iron-gym-", "iron--gym"]) {
      const { data, error } = await tryCreateOrganization(owner, slug);
      expect(data, `slug "${slug}" should have been rejected`).toBeNull();
      expect(error).not.toBeNull();
      expect(error!.message).toMatch(/INVALID_SLUG/);
    }
  });

  it("still creates an organization for a valid slug", async () => {
    const owner = await freshOwner("p27-valid");
    const slug = `iron-gym-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const { data, error } = await tryCreateOrganization(owner, slug);
    expect(error).toBeNull();
    expect(data).not.toBeNull();
    expect((data as { slug: string }).slug).toBe(slug);
  });
});
