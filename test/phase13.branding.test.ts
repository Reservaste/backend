// Integration tests for Phase 13 (per-organization branding).
//
// Two things are actually at stake here and neither is visual: the accent
// colour is interpolated into a CSS custom property, and the logo lives in
// a shared storage bucket. Both are reachable without going through the
// UI, so both are tested the way an attacker would reach them.
// Requires a running local Supabase (`npx supabase start`).

import { afterAll, describe, expect, it } from "vitest";
import { createClient } from "@supabase/supabase-js";
import {
  ANON_KEY,
  SUPABASE_URL,
  admin,
  createOrganization,
  createSignedInUser,
  type SignedInUser,
} from "./helpers";

const BUCKET = "organization-logos";
const PNG = new Blob([new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])], {
  type: "image/png",
});

async function addStaff(owner: SignedInUser, organizationId: string, prefix: string) {
  const staff = await createSignedInUser(prefix);
  // The email lives in auth.users, not in profiles.
  const { data: user } = await admin.auth.admin.getUserById(staff.id);
  const { error } = await owner.client.rpc("invite_member_by_email", {
    p_organization_id: organizationId,
    p_email: user.user!.email!,
    p_role: "STAFF",
  });
  if (error) throw new Error(`failed to add staff: ${error.message}`);
  return staff;
}

describe("Phase 13: organization branding", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("an owner sets an accent colour and it is normalized to lowercase", async () => {
    const owner = await createSignedInUser("p13-color");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-color");

    const { error } = await owner.client
      .from("organizations")
      .update({ brand_color: "  #FFAA00 " })
      .eq("id", org.id);
    expect(error).toBeNull();

    const { data } = await owner.client.from("organizations").select("brand_color").eq("id", org.id).single();
    // Normalized before the CHECK runs, so pasting an uppercase hex saves
    // rather than failing with a constraint error nobody can interpret.
    expect(data?.brand_color).toBe("#ffaa00");
  });

  it("rejects anything that is not #rrggbb, including a CSS escape", async () => {
    const owner = await createSignedInUser("p13-inject");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-inject");

    for (const value of ["red", "#fa0", "#gggggg", "#ffaa00; } body { display:none", "url(x)"]) {
      const { error } = await owner.client
        .from("organizations")
        .update({ brand_color: value })
        .eq("id", org.id);
      expect(error?.message).toContain("organizations_brand_color_format");
    }

    // Clearing it is how you go back to the product default.
    const cleared = await owner.client.from("organizations").update({ brand_color: null }).eq("id", org.id);
    expect(cleared.error).toBeNull();
  });

  it("refuses a logo path belonging to another organization", async () => {
    const owner = await createSignedInUser("p13-path");
    const other = await createSignedInUser("p13-path-other");
    createdUserIds.push(owner.id, other.id);
    const org = await createOrganization(owner, "p13-path");
    const foreign = await createOrganization(other, "p13-path-other");

    const stolen = await owner.client
      .from("organizations")
      .update({ logo_path: `${foreign.id}/logo.png` })
      .eq("id", org.id);
    expect(stolen.error?.message).toContain("organizations_logo_path_scoped");

    const wandering = await owner.client
      .from("organizations")
      .update({ logo_path: "logo.png" })
      .eq("id", org.id);
    expect(wandering.error?.message).toContain("organizations_logo_path_scoped");

    const own = await owner.client
      .from("organizations")
      .update({ logo_path: `${org.id}/logo.png` })
      .eq("id", org.id);
    expect(own.error).toBeNull();
  });

  it("a STAFF member cannot change the branding", async () => {
    const owner = await createSignedInUser("p13-staff");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-staff");
    const staff = await addStaff(owner, org.id, "p13-staff-member");
    createdUserIds.push(staff.id);

    // Identity is an owner-level decision, the same as the name. RLS makes
    // the update match zero rows rather than raising.
    await staff.client.from("organizations").update({ brand_color: "#ff0000" }).eq("id", org.id);

    const { data } = await owner.client.from("organizations").select("brand_color").eq("id", org.id).single();
    expect(data?.brand_color).toBeNull();
  });

  it("branding is visible to anonymous visitors, and nothing else is", async () => {
    const owner = await createSignedInUser("p13-public");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-public");
    await owner.client
      .from("organizations")
      .update({ brand_color: "#0b3d91", logo_path: `${org.id}/logo.png` })
      .eq("id", org.id);

    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { data } = await anon.from("organizations_public").select("*").eq("id", org.id).single();

    expect(data?.brand_color).toBe("#0b3d91");
    expect(data?.logo_path).toBe(`${org.id}/logo.png`);
    // The view is the boundary: adding branding to it must not have
    // dragged internal columns along.
    expect(Object.keys(data!).sort()).toEqual(
      ["brand_color", "id", "logo_path", "name", "slug", "timezone"].sort(),
    );

    // The base table stays closed to anonymous readers.
    const { data: leaked } = await anon.from("organizations").select("*").eq("id", org.id);
    expect(leaked).toEqual([]);
  });

  it("an owner uploads a logo into their own folder and anyone can read it", async () => {
    const owner = await createSignedInUser("p13-upload");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-upload");

    const path = `${org.id}/logo.png`;
    const { error } = await owner.client.storage
      .from(BUCKET)
      .upload(path, PNG, { contentType: "image/png", upsert: true });
    expect(error).toBeNull();

    // Public bucket: the booking page renders for visitors with no session.
    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const { data: url } = anon.storage.from(BUCKET).getPublicUrl(path);
    const response = await fetch(url.publicUrl);
    expect(response.status).toBe(200);
  });

  it("nobody can write into another organization's logo folder", async () => {
    const owner = await createSignedInUser("p13-storage-owner");
    const attacker = await createSignedInUser("p13-storage-attacker");
    createdUserIds.push(owner.id, attacker.id);
    const org = await createOrganization(owner, "p13-storage-owner");
    await createOrganization(attacker, "p13-storage-attacker");

    const target = `${org.id}/logo.png`;
    await owner.client.storage.from(BUCKET).upload(target, PNG, { contentType: "image/png", upsert: true });

    // The obvious move once you know the path convention: the victim's
    // organization id is public (organizations_public exposes it).
    const overwrite = await attacker.client.storage
      .from(BUCKET)
      .upload(target, PNG, { contentType: "image/png", upsert: true });
    expect(overwrite.error).not.toBeNull();

    const removed = await attacker.client.storage.from(BUCKET).remove([target]);
    // remove() reports what it actually deleted; the policy must leave the
    // object untouched rather than reporting a successful no-op deletion.
    expect(removed.data ?? []).toHaveLength(0);

    const anon = createClient(SUPABASE_URL, ANON_KEY);
    const stillThere = await fetch(anon.storage.from(BUCKET).getPublicUrl(target).data.publicUrl);
    expect(stillThere.status).toBe(200);
  });

  it("a path that is not scoped to a uuid is refused, not an error", async () => {
    const owner = await createSignedInUser("p13-junkpath");
    createdUserIds.push(owner.id);
    await createOrganization(owner, "p13-junkpath");

    // storage_object_organization() returns null instead of raising on a
    // non-uuid first segment: inside a policy an exception aborts the
    // statement rather than denying it.
    const { error } = await owner.client.storage
      .from(BUCKET)
      .upload("not-a-uuid/logo.png", PNG, { contentType: "image/png" });
    expect(error).not.toBeNull();
  });

  it("refuses a file type that is not a raster image", async () => {
    const owner = await createSignedInUser("p13-mime");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p13-mime");

    // SVG can carry script and the object URL is directly openable, so it
    // is excluded at the bucket level rather than in the upload form.
    const svg = new Blob(["<svg xmlns='http://www.w3.org/2000/svg'></svg>"], { type: "image/svg+xml" });
    const { error } = await owner.client.storage
      .from(BUCKET)
      .upload(`${org.id}/logo.svg`, svg, { contentType: "image/svg+xml" });
    expect(error).not.toBeNull();
  });
});
