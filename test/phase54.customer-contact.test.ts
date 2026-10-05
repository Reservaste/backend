// Integration tests for ADR-0050: customer_contact(). Email and phone of a
// customer, visible only to the active team (OWNER/STAFF) of the
// customer's own organization.
//
// Requires a running local Supabase (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  createOrganization,
  createSignedInUser,
  SUPABASE_URL,
  type SignedInUser,
} from "./helpers";

describe("ADR-0050: customer_contact()", () => {
  const createdUserIds: string[] = [];
  const anon = createClient(SUPABASE_URL, ANON_KEY);

  let owner: SignedInUser;
  let otherOwner: SignedInUser;
  let accountCustomer: SignedInUser;
  let accountCustomerId: string;
  let managedCustomerId: string;
  let accountPhone: string;
  let staff: SignedInUser;
  let staffMemberId: string;
  let noPhoneCustomerId: string;
  let noPhoneCustomer: SignedInUser;

  beforeAll(async () => {
    owner = await createSignedInUser("p54-owner");
    createdUserIds.push(owner.id);
    const org = await createOrganization(owner, "p54-org");

    otherOwner = await createSignedInUser("p54-other");
    createdUserIds.push(otherOwner.id);
    await createOrganization(otherOwner, "p54-other-org");

    accountCustomer = await createSignedInUser("p54-customer");
    createdUserIds.push(accountCustomer.id);
    // Unique per run so the assertion is about this row, not shared state.
    accountPhone = `+5989${String(Date.now()).slice(-7)}`;
    const { data: row, error } = await admin
      .from("customers")
      .insert({
        organization_id: org.id,
        profile_id: accountCustomer.id,
        phone: accountPhone,
        created_by: owner.id,
      })
      .select()
      .single();
    expect(error).toBeNull();
    accountCustomerId = row!.id as string;

    const managed = await owner.client.rpc("create_managed_customer", {
      p_organization_id: org.id,
      p_display_name: "Cliente Gestionado P54",
      p_phone: "+59899123456",
    });
    expect(managed.error).toBeNull();
    managedCustomerId = managed.data.id as string;

    staff = await createSignedInUser("p54-staff");
    createdUserIds.push(staff.id);
    const { data: member, error: memberError } = await admin
      .from("organization_members")
      .insert({ organization_id: org.id, profile_id: staff.id, role: "STAFF", created_by: owner.id })
      .select()
      .single();
    expect(memberError).toBeNull();
    staffMemberId = member!.id as string;

    noPhoneCustomer = await createSignedInUser("p54-nophone");
    createdUserIds.push(noPhoneCustomer.id);
    const { data: np, error: npError } = await admin
      .from("customers")
      .insert({ organization_id: org.id, profile_id: noPhoneCustomer.id, created_by: owner.id })
      .select()
      .single();
    expect(npError).toBeNull();
    noPhoneCustomerId = np!.id as string;
  });

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  it("gives staff the email and phone of a customer with an account", async () => {
    const { data, error } = await owner.client.rpc("customer_contact", {
      p_customer_id: accountCustomerId,
    });
    expect(error).toBeNull();
    expect(data).toEqual([{ email: accountCustomer.email, phone: accountPhone }]);
  });

  it("gives staff a null email and the phone for a managed customer", async () => {
    const { data, error } = await owner.client.rpc("customer_contact", {
      p_customer_id: managedCustomerId,
    });
    expect(error).toBeNull();
    expect(data).toEqual([{ email: null, phone: "+59899123456" }]);
  });

  it("returns no rows to staff of another organization", async () => {
    for (const id of [accountCustomerId, managedCustomerId]) {
      const { data, error } = await otherOwner.client.rpc("customer_contact", { p_customer_id: id });
      expect(error).toBeNull();
      expect(data).toHaveLength(0);
    }
  });

  it("returns no rows for an unknown customer (same as cross-tenant)", async () => {
    const { data, error } = await owner.client.rpc("customer_contact", {
      p_customer_id: "00000000-0000-0000-0000-000000000000",
    });
    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });

  it("returns no rows to a CUSTOMER, not even for their own record", async () => {
    const { data, error } = await accountCustomer.client.rpc("customer_contact", {
      p_customer_id: accountCustomerId,
    });
    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });

  it("denies anonymous callers", async () => {
    const { data, error } = await anon.rpc("customer_contact", { p_customer_id: accountCustomerId });
    expect(error).not.toBeNull();
    expect(data).toBeNull();
  });

  it("gives an active STAFF member the contact too (not only the OWNER)", async () => {
    const { data, error } = await staff.client.rpc("customer_contact", { p_customer_id: accountCustomerId });
    expect(error).toBeNull();
    expect(data).toEqual([{ email: accountCustomer.email, phone: accountPhone }]);
  });

  it("gives a null phone and the email for an account customer without phone", async () => {
    const { data, error } = await owner.client.rpc("customer_contact", { p_customer_id: noPhoneCustomerId });
    expect(error).toBeNull();
    expect(data).toEqual([{ email: noPhoneCustomer.email, phone: null }]);
  });

  it("returns no rows to a deactivated STAFF member", async () => {
    const { error: updError } = await admin
      .from("organization_members")
      .update({ is_active: false })
      .eq("id", staffMemberId);
    expect(updError).toBeNull();
    const { data, error } = await staff.client.rpc("customer_contact", { p_customer_id: accountCustomerId });
    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });
});
