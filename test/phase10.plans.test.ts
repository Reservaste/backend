// Integration tests for Phase 10 (plans, subscriptions, invite-gated
// organization creation). The two things worth proving: an organization
// can't be created without paying for it, and a lapsed subscription
// blocks the *panel* without breaking the gym's members.
// Requires a running local Supabase (`npx supabase start`).

import { createClient } from "@supabase/supabase-js";
import { afterAll, describe, expect, it } from "vitest";
import {
  admin,
  ANON_KEY,
  createInvite,
  createOrganization,
  createSignedInUser,
  SUPABASE_URL,
  type SignedInUser,
} from "./helpers";

async function setupBookableOrg(prefix: string, planCode = "full") {
  const owner = await createSignedInUser(prefix);
  const org = await createOrganization(owner, `${prefix}-org`, planCode);

  const { data: service } = await owner.client
    .from("services")
    .insert({ organization_id: org.id, name: "CrossFit", created_by: owner.id })
    .select()
    .single();

  const { data: resource } = await owner.client
    .from("resources")
    .insert({ organization_id: org.id, name: "Sala", created_by: owner.id })
    .select()
    .single();

  const weekday = (new Date().getUTCDay() + 2) % 7;
  const { data: rule } = await owner.client
    .from("schedule_rules")
    .insert({
      organization_id: org.id,
      service_id: service!.id,
      resource_id: resource!.id,
      weekday,
      local_start_time: "09:00",
      duration_minutes: 60,
      capacity: 10,
      created_by: owner.id,
    })
    .select()
    .single();

  const { data: occurrences } = await owner.client
    .from("slot_occurrences")
    .select("id")
    .eq("schedule_rule_id", rule!.id)
    .order("start_at", { ascending: true })
    .limit(1);

  return { owner, org, service: service!, occurrenceId: occurrences![0]!.id };
}

describe("Phase 10: plans and subscriptions", () => {
  const createdUserIds: string[] = [];

  afterAll(async () => {
    for (const id of createdUserIds) {
      await admin.auth.admin.deleteUser(id).catch(() => {});
    }
  });

  describe("invite-gated creation", () => {
    it("refuses to create an organization without a valid invite", async () => {
      const person = await createSignedInUser("p10-noinvite");
      createdUserIds.push(person.id);

      const { error } = await person.client.rpc("create_organization_with_owner", {
        p_slug: `p10-noinvite-${Date.now()}`,
        p_name: "Sin invitación",
        p_timezone: "America/Montevideo",
        p_invite_code: "NOPE123456",
      });

      expect(error?.message).toContain("INVITE_NOT_FOUND");
    });

    it("burns the invite: a code works once", async () => {
      const person = await createSignedInUser("p10-reuse");
      createdUserIds.push(person.id);
      const code = await createInvite("starter");

      const first = await person.client.rpc("create_organization_with_owner", {
        p_slug: `p10-reuse-a-${Date.now()}`,
        p_name: "Primera",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(first.error).toBeNull();
      expect(first.data.plan_code).toBe("starter");
      expect(first.data.subscription_status).toBe("ACTIVE");

      const second = await person.client.rpc("create_organization_with_owner", {
        p_slug: `p10-reuse-b-${Date.now()}`,
        p_name: "Segunda",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(second.error?.message).toContain("INVITE_ALREADY_USED");
    });

    it("rejects an expired invite", async () => {
      const person = await createSignedInUser("p10-expired");
      createdUserIds.push(person.id);
      const code = await createInvite("starter", {
        expires_at: new Date(Date.now() - 86_400_000).toISOString(),
      });

      const { error } = await person.client.rpc("create_organization_with_owner", {
        p_slug: `p10-expired-${Date.now()}`,
        p_name: "Vencida",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(error?.message).toContain("INVITE_EXPIRED");
    });

    it("an invite locked to an email can't be redeemed by someone else", async () => {
      const buyer = await createSignedInUser("p10-buyer");
      const stranger = await createSignedInUser("p10-stranger");
      createdUserIds.push(buyer.id, stranger.id);

      const { data: buyerUser } = await admin.auth.admin.getUserById(buyer.id);
      const code = await createInvite("pro", { email: buyerUser.user!.email });

      const wrong = await stranger.client.rpc("create_organization_with_owner", {
        p_slug: `p10-wrong-${Date.now()}`,
        p_name: "Ajena",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(wrong.error?.message).toContain("INVITE_WRONG_EMAIL");

      const right = await buyer.client.rpc("create_organization_with_owner", {
        p_slug: `p10-right-${Date.now()}`,
        p_name: "Propia",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(right.error).toBeNull();
      expect(right.data.plan_code).toBe("pro");
    });

    it("an invite with trial_days starts the organization in TRIALING", async () => {
      const person = await createSignedInUser("p10-trial");
      createdUserIds.push(person.id);
      const code = await createInvite("starter", { trial_days: 14 });

      const { data, error } = await person.client.rpc("create_organization_with_owner", {
        p_slug: `p10-trial-${Date.now()}`,
        p_name: "Con prueba",
        p_timezone: "America/Montevideo",
        p_invite_code: code,
      });
      expect(error).toBeNull();
      expect(data.subscription_status).toBe("TRIALING");
      expect(new Date(data.trial_ends_at).getTime()).toBeGreaterThan(Date.now());
    });
  });

  describe("plan limits", () => {
    it("stops at the plan's service limit and says which limit was hit", async () => {
      const owner = await createSignedInUser("p10-limits");
      createdUserIds.push(owner.id);
      // starter: 3 services, 2 resources, 50 customers, 2 team members.
      const org = await createOrganization(owner, "p10-limits-org", "starter");

      for (let i = 1; i <= 3; i++) {
        const { error } = await owner.client
          .from("services")
          .insert({ organization_id: org.id, name: `Servicio ${i}`, created_by: owner.id });
        expect(error).toBeNull();
      }

      const overLimit = await owner.client
        .from("services")
        .insert({ organization_id: org.id, name: "Uno de más", created_by: owner.id });
      expect(overLimit.error?.message).toContain("PLAN_LIMIT_REACHED");
      expect(overLimit.error?.message).toContain("servicios (3/3)");
    });

    it("frees a slot when something is archived, since the limit counts active rows", async () => {
      const owner = await createSignedInUser("p10-archive");
      createdUserIds.push(owner.id);
      const org = await createOrganization(owner, "p10-archive-org", "starter");

      const created = [];
      for (let i = 1; i <= 2; i++) {
        const { data } = await owner.client
          .from("resources")
          .insert({ organization_id: org.id, name: `Sala ${i}`, created_by: owner.id })
          .select()
          .single();
        created.push(data!);
      }

      const blocked = await owner.client
        .from("resources")
        .insert({ organization_id: org.id, name: "Sala 3", created_by: owner.id });
      expect(blocked.error?.message).toContain("PLAN_LIMIT_REACHED");

      await owner.client.from("resources").update({ is_active: false }).eq("id", created[0]!.id);

      const nowAllowed = await owner.client
        .from("resources")
        .insert({ organization_id: org.id, name: "Sala 3", created_by: owner.id });
      expect(nowAllowed.error).toBeNull();
    });

    it("the unlimited plan has no ceiling", async () => {
      const owner = await createSignedInUser("p10-unlimited");
      createdUserIds.push(owner.id);
      const org = await createOrganization(owner, "p10-unlimited-org", "full");

      for (let i = 1; i <= 6; i++) {
        const { error } = await owner.client
          .from("services")
          .insert({ organization_id: org.id, name: `Servicio ${i}`, created_by: owner.id });
        expect(error).toBeNull();
      }
    });
  });

  describe("a lapsed subscription", () => {
    it("blocks the panel but leaves the gym's members untouched", async () => {
      const { owner, org, service, occurrenceId } = await setupBookableOrg("p10-lapsed");
      createdUserIds.push(owner.id);

      // A customer with a booking, set up while the subscription is fine.
      const customer = await createSignedInUser("p10-lapsed-customer");
      createdUserIds.push(customer.id);
      const { data: customerRow } = await owner.client
        .from("customers")
        .insert({ organization_id: org.id, profile_id: customer.id, created_by: owner.id })
        .select()
        .single();
      await owner.client.from("service_entitlements").insert({
        organization_id: org.id,
        customer_id: customerRow!.id,
        service_id: service.id,
        entitlement_type: "TIME",
        valid_from: "2020-01-01",
        requires_active_payment: false,
        created_by: owner.id,
      });

      // The gym stops paying.
      await admin.from("organizations").update({ subscription_status: "PAST_DUE" }).eq("id", org.id);

      // Panel: can't add anything new.
      const newService = await owner.client
        .from("services")
        .insert({ organization_id: org.id, name: "Nuevo", created_by: owner.id });
      expect(newService.error?.message).toContain("SUBSCRIPTION_INACTIVE");

      const newCustomer = await owner.client.rpc("enroll_customer_by_email", {
        p_organization_id: org.id,
        p_email: "alguien@example.com",
      });
      expect(newCustomer.error).not.toBeNull();

      // Members: everything they already had keeps working.
      const booked = await customer.client.rpc("book_slot", { p_slot_occurrence_id: occurrenceId });
      expect(booked.data.status).toBe("OK");

      const anon = createClient(SUPABASE_URL, ANON_KEY);
      const { data: publicSlots } = await anon.rpc("get_public_availability", {
        p_organization_slug: org.slug,
      });
      expect(publicSlots.length).toBeGreaterThan(0);

      // And they can still cancel -- being locked out of your own
      // cancellations because your gym didn't pay would be the worst
      // version of this.
      const cancelled = await customer.client.rpc("cancel_booking", {
        p_booking_id: booked.data.booking.id,
      });
      expect(cancelled.data.status).toBe("CANCELLED");
    });

    it("comes back to life when the platform owner reactivates it", async () => {
      const { owner, org } = await setupBookableOrg("p10-revive");
      createdUserIds.push(owner.id);

      await admin.from("organizations").update({ subscription_status: "SUSPENDED" }).eq("id", org.id);

      const blocked = await owner.client
        .from("resources")
        .insert({ organization_id: org.id, name: "Bloqueada", created_by: owner.id });
      expect(blocked.error?.message).toContain("SUBSCRIPTION_INACTIVE");

      await admin.from("organizations").update({ subscription_status: "ACTIVE" }).eq("id", org.id);

      const allowed = await owner.client
        .from("resources")
        .insert({ organization_id: org.id, name: "Permitida", created_by: owner.id });
      expect(allowed.error).toBeNull();
    });
  });

  describe("platform administration", () => {
    it("organization_usage reports what the plan allows and what's used", async () => {
      const owner = await createSignedInUser("p10-usage");
      createdUserIds.push(owner.id);
      const org = await createOrganization(owner, "p10-usage-org", "starter");

      await owner.client
        .from("services")
        .insert({ organization_id: org.id, name: "Uno", created_by: owner.id });

      const { data, error } = await owner.client.rpc("organization_usage", {
        p_organization_id: org.id,
      });
      expect(error).toBeNull();

      const usage = data[0];
      expect(usage.plan_code).toBe("starter");
      expect(usage.monthly_price_usd).toBe(20);
      expect(usage.services_used).toBe(1);
      expect(usage.services_limit).toBe(3);
      expect(usage.team_used).toBe(1);
      expect(usage.team_limit).toBe(2);
    });

    it("platform RPCs are closed to everyone who isn't a platform admin", async () => {
      const owner = await createSignedInUser("p10-notadmin");
      createdUserIds.push(owner.id);
      const org = await createOrganization(owner, "p10-notadmin-org");

      const invite = await owner.client.rpc("create_organization_invite", { p_plan_code: "starter" });
      expect(invite.error?.message).toContain("NOT_AUTHORIZED");

      const change = await owner.client.rpc("set_organization_subscription", {
        p_organization_id: org.id,
        p_plan_code: "full",
        p_status: "ACTIVE",
      });
      expect(change.error?.message).toContain("NOT_AUTHORIZED");

      // The read-only console returns nothing rather than erroring, so a
      // non-admin simply sees an empty page.
      const orgs = await owner.client.rpc("platform_organizations");
      expect(orgs.data).toEqual([]);
    });

    it("nobody can promote themselves to platform admin through the API", async () => {
      const person = await createSignedInUser("p10-selfpromote");
      createdUserIds.push(person.id);

      // platform_admins has RLS on with no INSERT policy at all, so this
      // is denied by the absence of a rule rather than by one that could
      // be edited wrong later. Granting admin is a deliberate act done
      // directly against the database.
      const insert = await person.client
        .from("platform_admins")
        .insert({ profile_id: person.id, note: "me promuevo solo" });
      expect(insert.error).not.toBeNull();

      const stillNotAdmin = await person.client.rpc("is_platform_admin");
      expect(stillNotAdmin.data).toBe(false);

      // And the table itself is invisible to them, so they can't even
      // enumerate who the admins are.
      const peek = await person.client.from("platform_admins").select("profile_id");
      expect(peek.data).toEqual([]);
    });

    it("an organization OWNER has no platform powers -- the two roles are unrelated", async () => {
      const owner = await createSignedInUser("p10-orgowner");
      createdUserIds.push(owner.id);
      const org = await createOrganization(owner, "p10-orgowner-org");

      // Being OWNER of your own gym is not being the platform owner.
      const isAdmin = await owner.client.rpc("is_platform_admin");
      expect(isAdmin.data).toBe(false);

      const upgradeSelf = await owner.client.rpc("set_organization_subscription", {
        p_organization_id: org.id,
        p_plan_code: "full",
        p_status: "ACTIVE",
      });
      expect(upgradeSelf.error?.message).toContain("NOT_AUTHORIZED");

      const invites = await owner.client.rpc("platform_invites");
      expect(invites.data).toEqual([]);
    });

    it("a platform admin can mint invites and move an organization between plans", async () => {
      const platformOwner = await createSignedInUser("p10-admin");
      createdUserIds.push(platformOwner.id);
      await admin.from("platform_admins").insert({ profile_id: platformOwner.id, note: "test" });

      const invite = await platformOwner.client.rpc("create_organization_invite", {
        p_plan_code: "starter",
        p_note: "vendido por teléfono",
      });
      expect(invite.error).toBeNull();
      expect(invite.data.code).toMatch(/^[A-Z0-9]{10}$/);
      expect(invite.data.plan_code).toBe("starter");

      const buyer = await createSignedInUser("p10-admin-buyer");
      createdUserIds.push(buyer.id);
      const { data: org } = await buyer.client.rpc("create_organization_with_owner", {
        p_slug: `p10-admin-org-${Date.now()}`,
        p_name: "Comprada",
        p_timezone: "America/Montevideo",
        p_invite_code: invite.data.code,
      });
      expect(org.plan_code).toBe("starter");

      const upgraded = await platformOwner.client.rpc("set_organization_subscription", {
        p_organization_id: org.id,
        p_plan_code: "pro",
        p_status: "ACTIVE",
      });
      expect(upgraded.error).toBeNull();
      expect(upgraded.data.plan_code).toBe("pro");

      const listed = await platformOwner.client.rpc("platform_organizations");
      expect(listed.data.some((o: { organization_id: string }) => o.organization_id === org.id)).toBe(true);
    });
  });
});
