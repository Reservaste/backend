// Fase 33 -- invitaciones de equipo (ADR-0034), verificación de integración
// contra Supabase real.
//
// Lo que se verifica acá es exactamente el listado obligatorio de la tarea,
// más las tres guardas que la propuesta nombró como riesgos:
//   - emitir -> canjear con el email correcto -> miembro con el role_id elegido
//   - canjear con otro email -> INVITE_WRONG_EMAIL
//   - vencido -> INVITATION_EXPIRED
//   - ya canjeado -> ALREADY_REDEEMED (un solo uso) + idempotencia del doble click
//   - el canje NO le pisa el rol a quien ya era miembro
//   - el cupo de plan rechaza la EMISIÓN, no sólo el canje
//   - una invitación no puede llevar rol OWNER (CHECK, no convención)
//   - rate limit de emisión
//   - revocación, read model, gate de OWNER y aislamiento cross-tenant

import { createClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";
import {
  ANON_KEY,
  SUPABASE_URL,
  admin,
  createOrganization,
  createSignedInUser,
  type SignedInUser,
} from "./helpers";

function invitedEmail(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;
}

interface IssuedInvitation {
  invitation_id: string;
  token: string;
  expires_at: string;
}

async function issue(
  issuer: SignedInUser,
  organizationId: string,
  email: string,
  extra: { displayName?: string; phone?: string; roleId?: string | null } = {},
) {
  const { data, error } = await issuer.client.rpc("issue_team_invitation", {
    p_organization_id: organizationId,
    p_email: email,
    p_display_name: extra.displayName ?? null,
    p_phone: extra.phone ?? null,
    p_role_id: extra.roleId ?? null,
  });
  return { data: (data as IssuedInvitation[] | null)?.[0] ?? null, error };
}

describe("Fase 33 -- team invitations (ADR-0034)", () => {
  it("happy path: issue -> claim with the right email -> active STAFF member with the chosen role_id", async () => {
    const owner = await createSignedInUser("owner-team-invite");
    const org = await createOrganization(owner, "org-team-invite");

    const { data: role, error: roleErr } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: "Profesor",
      p_can_view_payments: false,
      p_can_manage_payments: false,
      p_can_manage_bookings: true,
      p_can_manage_customers: true,
      p_can_manage_attendance: true,
    });
    expect(roleErr).toBeNull();
    const roleId = (role as { id: string }).id;

    const email = invitedEmail("profe-nuevo");
    const { data: issued, error: issueErr } = await issue(owner, org.id, email, {
      displayName: "Juan Pérez",
      phone: "+598 99 123 456",
      roleId,
    });
    expect(issueErr).toBeNull();
    expect(issued?.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(issued?.invitation_id).toBeTruthy();

    // 24 h, no 72 h (ADR-0034 resolución 3).
    const ttlHours = (new Date(issued!.expires_at).getTime() - Date.now()) / 3_600_000;
    expect(ttlHours).toBeGreaterThan(23);
    expect(ttlHours).toBeLessThan(25);

    const { data: row } = await admin
      .from("team_invitations")
      .select("email, phone, display_name, role, role_id")
      .eq("id", issued!.invitation_id)
      .single();
    expect(row?.email).toBe(email.toLowerCase());
    expect(row?.phone).toBe("+59899123456");
    expect(row?.display_name).toBe("Juan Pérez");
    expect(row?.role).toBe("STAFF");
    expect(row?.role_id).toBe(roleId);

    // La persona recién ahora se crea la cuenta, con ese mismo email: eso es
    // todo el punto de ADR-0034 (invite_member_by_email() exigiría que ya
    // existiera antes de poder invitarla).
    const staff = await createSignedInUser("staff-claimer", email);

    const { data: claim, error: claimErr } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(claimErr).toBeNull();
    expect((claim as { status?: string })?.status).toBe("OK");
    expect((claim as { organization_slug?: string })?.organization_slug).toBe(org.slug);

    const { data: member } = await admin
      .from("organization_members")
      .select("role, role_id, is_active, created_by")
      .eq("organization_id", org.id)
      .eq("profile_id", staff.id)
      .single();
    expect(member?.role).toBe("STAFF");
    expect(member?.role_id).toBe(roleId);
    expect(member?.is_active).toBe(true);
    // El alta la decidió quien invitó, no quien hizo click.
    expect(member?.created_by).toBe(owner.id);

    // El rol elegido manda de verdad: sin VIEW_PAYMENTS.
    const { data: perms } = await staff.client.rpc("my_organization_permissions", {
      p_organization_id: org.id,
    });
    const resolved = (perms as Array<Record<string, unknown>> | null)?.[0];
    expect(resolved?.role).toBe("STAFF");
    expect(resolved?.role_name).toBe("Profesor");
    expect(resolved?.can_view_payments).toBe(false);
    expect(resolved?.can_manage_attendance).toBe(true);

    // La invitación quedó consumida.
    const { data: after } = await admin
      .from("team_invitations")
      .select("redeemed_at, redeemed_profile_id")
      .eq("id", issued!.invitation_id)
      .single();
    expect(after?.redeemed_at).not.toBeNull();
    expect(after?.redeemed_profile_id).toBe(staff.id);
  });

  it("the phone is normalized to E.164 on the way in", async () => {
    const owner = await createSignedInUser("owner-phone-norm");
    const org = await createOrganization(owner, "org-phone-norm");

    const { data: issued, error } = await issue(owner, org.id, invitedEmail("phone-norm"), {
      phone: "+598 99 123 456",
    });
    expect(error).toBeNull();

    const { data: row } = await admin
      .from("team_invitations")
      .select("phone")
      .eq("id", issued!.invitation_id)
      .single();
    expect(row?.phone).toBe("+59899123456");

    const { error: badPhone } = await issue(owner, org.id, invitedEmail("phone-bad"), {
      phone: "no-es-un-telefono",
    });
    expect(badPhone?.message).toMatch(/INVALID_PHONE/);
  });

  it("claiming with a different email is rejected, and nothing is consumed", async () => {
    const owner = await createSignedInUser("owner-wrong-email");
    const org = await createOrganization(owner, "org-wrong-email");

    const { data: issued } = await issue(owner, org.id, invitedEmail("invitado-real"));
    // Se registró con otro email (el caso típico de Google OAuth).
    const otherPerson = await createSignedInUser("se-registro-con-otro");

    const { error } = await otherPerson.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/INVITE_WRONG_EMAIL/);

    const { data: members } = await admin
      .from("organization_members")
      .select("id")
      .eq("organization_id", org.id)
      .eq("profile_id", otherPerson.id);
    expect(members ?? []).toHaveLength(0);

    // El token sigue vivo: el remedio es que la persona entre con la casilla
    // correcta, o que el dueño reemita. No se quemó por un click equivocado.
    const { data: row } = await admin
      .from("team_invitations")
      .select("redeemed_at, revoked_at")
      .eq("id", issued!.invitation_id)
      .single();
    expect(row?.redeemed_at).toBeNull();
    expect(row?.revoked_at).toBeNull();
  });

  it("an expired token is rejected", async () => {
    const owner = await createSignedInUser("owner-expired");
    const org = await createOrganization(owner, "org-expired");

    const email = invitedEmail("llego-tarde");
    const { data: issued } = await issue(owner, org.id, email);

    await admin
      .from("team_invitations")
      .update({ expires_at: new Date(Date.now() - 60_000).toISOString() })
      .eq("id", issued!.invitation_id);

    const staff = await createSignedInUser("staff-expired", email);
    const { error } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(error!.message).toMatch(/INVITATION_EXPIRED/);

    const { data: members } = await admin
      .from("organization_members")
      .select("id")
      .eq("organization_id", org.id)
      .eq("profile_id", staff.id);
    expect(members ?? []).toHaveLength(0);
  });

  it("one use only: a second person with the same token gets ALREADY_REDEEMED, the same person gets OK again", async () => {
    const owner = await createSignedInUser("owner-one-use");
    const org = await createOrganization(owner, "org-one-use");

    const email = invitedEmail("primero");
    const { data: issued } = await issue(owner, org.id, email);

    const staff = await createSignedInUser("staff-one-use", email);
    const { error: firstErr } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(firstErr).toBeNull();

    // Doble click del MISMO profile: idempotente, no un error de pantalla.
    const { data: second, error: secondErr } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(secondErr).toBeNull();
    expect((second as { status?: string })?.status).toBe("OK");

    // El mismo token en manos de otra cuenta: el email ni se llega a mirar,
    // ALREADY_REDEEMED corta antes.
    const thirdParty = await createSignedInUser("tercero-one-use");
    const { error: thirdErr } = await thirdParty.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(thirdErr!.message).toMatch(/ALREADY_REDEEMED/);

    const { data: members } = await admin
      .from("organization_members")
      .select("profile_id")
      .eq("organization_id", org.id);
    expect((members ?? []).map((m) => m.profile_id).sort()).toEqual([owner.id, staff.id].sort());
  });

  it("a revoked invitation is rejected, and revoking is idempotent", async () => {
    const owner = await createSignedInUser("owner-revoke");
    const org = await createOrganization(owner, "org-revoke");

    const email = invitedEmail("revocado");
    const { data: issued } = await issue(owner, org.id, email);

    const { error: revokeErr } = await owner.client.rpc("revoke_team_invitation", {
      p_invitation_id: issued!.invitation_id,
    });
    expect(revokeErr).toBeNull();
    // Idempotente: revocar dos veces no falla.
    const { error: revokeAgain } = await owner.client.rpc("revoke_team_invitation", {
      p_invitation_id: issued!.invitation_id,
    });
    expect(revokeAgain).toBeNull();

    const staff = await createSignedInUser("staff-revoked", email);
    const { error } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(error!.message).toMatch(/INVITATION_REVOKED/);
  });

  it("re-issuing revokes the previous live link for that email (no two live links at once)", async () => {
    const owner = await createSignedInUser("owner-reissue");
    const org = await createOrganization(owner, "org-reissue");

    const email = invitedEmail("reenviado");
    const { data: first } = await issue(owner, org.id, email);
    const { data: second, error: secondErr } = await issue(owner, org.id, email);
    expect(secondErr).toBeNull();
    expect(second!.invitation_id).not.toBe(first!.invitation_id);

    const staff = await createSignedInUser("staff-reissue", email);
    const { error: oldErr } = await staff.client.rpc("claim_team_invitation", {
      p_token: first!.token,
    });
    expect(oldErr!.message).toMatch(/INVITATION_REVOKED/);

    const { error: newErr } = await staff.client.rpc("claim_team_invitation", {
      p_token: second!.token,
    });
    expect(newErr).toBeNull();
  });

  it("the canje NEVER overwrites the role of someone who is already a member", async () => {
    const owner = await createSignedInUser("owner-no-role-overwrite");
    const org = await createOrganization(owner, "org-no-role-overwrite");

    const { data: roleProfesor } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: "Profesor",
      p_can_view_payments: false,
      p_can_manage_payments: false,
      p_can_manage_bookings: true,
      p_can_manage_customers: true,
      p_can_manage_attendance: true,
    });
    const { data: roleAdmin } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: "Administración",
      p_can_view_payments: true,
      p_can_manage_payments: true,
      p_can_manage_bookings: true,
      p_can_manage_customers: true,
      p_can_manage_attendance: true,
    });
    const profesorId = (roleProfesor as { id: string }).id;
    const adminRoleId = (roleAdmin as { id: string }).id;

    // Ya es miembro, con el rol restringido.
    const existing = await createSignedInUser("ya-era-miembro");
    const { error: inviteErr } = await owner.client.rpc("invite_member_by_email", {
      p_organization_id: org.id,
      p_email: existing.email,
      p_role: "STAFF",
      p_role_id: profesorId,
    });
    expect(inviteErr).toBeNull();

    // Y ahora le llega un link emitido para un rol MAYOR. El canje tiene que
    // devolver OK y no tocarle el rol: si lo pisara, sería un camino de
    // escalada (ADR-0034 riesgo 3).
    const { data: issued } = await issue(owner, org.id, existing.email, { roleId: adminRoleId });
    const { data: claim, error: claimErr } = await existing.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(claimErr).toBeNull();
    expect((claim as { status?: string })?.status).toBe("OK");

    const { data: member } = await admin
      .from("organization_members")
      .select("role, role_id")
      .eq("organization_id", org.id)
      .eq("profile_id", existing.id)
      .single();
    expect(member?.role).toBe("STAFF");
    expect(member?.role_id).toBe(profesorId);
  });

  it("the canje never turns an existing OWNER into STAFF either", async () => {
    const owner = await createSignedInUser("owner-self-claim");
    const org = await createOrganization(owner, "org-self-claim");

    // El dueño se invita a sí mismo (torpeza, no ataque) y hace click.
    const { data: issued, error: issueErr } = await issue(owner, org.id, owner.email);
    expect(issueErr).toBeNull();

    const { data: claim, error: claimErr } = await owner.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(claimErr).toBeNull();
    expect((claim as { status?: string })?.status).toBe("OK");

    const { data: member } = await admin
      .from("organization_members")
      .select("role, role_id")
      .eq("organization_id", org.id)
      .eq("profile_id", owner.id)
      .single();
    expect(member?.role).toBe("OWNER");
    expect(member?.role_id).toBeNull();
  });

  it("an invitation can never carry the OWNER role: the RPC has no enum parameter and the CHECK closes the rest", async () => {
    const owner = await createSignedInUser("owner-never-owner");
    const org = await createOrganization(owner, "org-never-owner");

    // 1. La RPC no expone un parámetro de rol enum. Pedirlo es un 404 de
    //    PostgREST (no existe esa firma), no una invitación de OWNER.
    const { error: noSuchParam } = await owner.client.rpc("issue_team_invitation", {
      p_organization_id: org.id,
      p_email: invitedEmail("aspirante"),
      p_role: "OWNER",
    } as Record<string, unknown>);
    expect(noSuchParam).not.toBeNull();

    // 2. Y el CHECK es la frontera real: ni el service_role (que bypassea
    //    RLS por definición) puede escribir una invitación de OWNER.
    const { error: checkErr } = await admin.from("team_invitations").insert({
      organization_id: org.id,
      email: invitedEmail("aspirante-2"),
      role: "OWNER",
      token_hash: "\\x00112233445566778899aabbccddeeff",
      expires_at: new Date(Date.now() + 3_600_000).toISOString(),
      created_by: owner.id,
    });
    expect(checkErr).not.toBeNull();
    expect(checkErr!.message).toMatch(/team_invitations_never_owner/);
  });

  it("the plan seat limit rejects the EMISSION, not just the click", async () => {
    // starter: max_team_members = 2. El dueño ya ocupa una, así que una
    // invitación viva ocupa la segunda y la siguiente no entra.
    const owner = await createSignedInUser("owner-plan-limit");
    const org = await createOrganization(owner, "org-plan-limit", "starter");

    const firstEmail = invitedEmail("cupo-1");
    const { error: firstErr } = await issue(owner, org.id, firstEmail);
    expect(firstErr).toBeNull();

    const { error: secondErr } = await issue(owner, org.id, invitedEmail("cupo-2"));
    expect(secondErr).not.toBeNull();
    expect(secondErr!.message).toMatch(/PLAN_LIMIT_REACHED/);
    expect(secondErr!.message).toMatch(/personas en el equipo/);

    // Un reenvío a la MISMA persona no cuenta dos plazas: revoca la viva
    // antes de contar. Si no, "no le llegó, mandale de nuevo" sería un
    // callejón sin salida en el plan más chico.
    const { error: resendErr } = await issue(owner, org.id, firstEmail);
    expect(resendErr).toBeNull();
  });

  it("the trigger is still the rule: the seat is also enforced at claim time", async () => {
    const owner = await createSignedInUser("owner-limit-at-claim");
    const org = await createOrganization(owner, "org-limit-at-claim", "starter");

    const email = invitedEmail("llega-sin-cupo");
    const { data: issued } = await issue(owner, org.id, email);

    // El cupo se llenó entre la emisión y el click (alguien más entró por el
    // camino sincrónico de invite_member_by_email()).
    const otherStaff = await createSignedInUser("staff-que-entro-antes");
    const { error: inviteErr } = await owner.client.rpc("invite_member_by_email", {
      p_organization_id: org.id,
      p_email: otherStaff.email,
      p_role: "STAFF",
    });
    expect(inviteErr).toBeNull();

    const staff = await createSignedInUser("staff-sin-cupo", email);
    const { error } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(error!.message).toMatch(/PLAN_LIMIT_REACHED/);
  });

  it("emission is rate limited per organization (10/h)", async () => {
    const owner = await createSignedInUser("owner-rate-limit");
    // Plan sin tope de equipo, para que lo único que corte sea el rate limit.
    const org = await createOrganization(owner, "org-rate-limit", "full");

    for (let i = 0; i < 10; i += 1) {
      const { error } = await issue(owner, org.id, invitedEmail(`rate-${i}`));
      expect(error, `emission #${i + 1} should be allowed`).toBeNull();
    }

    const { error: blocked } = await issue(owner, org.id, invitedEmail("rate-11"));
    expect(blocked).not.toBeNull();
    expect(blocked!.message).toMatch(/RATE_LIMITED_HOURLY/);

    // El límite es por organización, no global: otro tenant no lo hereda.
    const otherOwner = await createSignedInUser("owner-rate-limit-b");
    const otherOrg = await createOrganization(otherOwner, "org-rate-limit-b", "full");
    const { error: unaffected } = await issue(otherOwner, otherOrg.id, invitedEmail("otro-tenant"));
    expect(unaffected).toBeNull();
  }, 60_000);

  it("issuing is OWNER-only; a STAFF member cannot invite and cannot read the invitation list", async () => {
    const owner = await createSignedInUser("owner-gate");
    const org = await createOrganization(owner, "org-gate");

    const staff = await createSignedInUser("staff-gate");
    await owner.client.rpc("invite_member_by_email", {
      p_organization_id: org.id,
      p_email: staff.email,
      p_role: "STAFF",
    });

    const { error: issueErr } = await issue(staff, org.id, invitedEmail("por-staff"));
    expect(issueErr!.message).toMatch(/NOT_AUTHORIZED/);

    const { data: issued } = await issue(owner, org.id, invitedEmail("por-owner"));

    const { error: revokeErr } = await staff.client.rpc("revoke_team_invitation", {
      p_invitation_id: issued!.invitation_id,
    });
    expect(revokeErr!.message).toMatch(/NOT_AUTHORIZED/);

    // El read model tiene emails y teléfonos de gente que no aceptó nada:
    // OWNER-only, y para un no-OWNER es una lista vacía, no un error.
    const { data: staffView } = await staff.client.rpc("organization_team_invitations", {
      p_organization_id: org.id,
    });
    expect(staffView ?? []).toHaveLength(0);

    const { data: ownerView } = await owner.client.rpc("organization_team_invitations", {
      p_organization_id: org.id,
    });
    expect(ownerView).toHaveLength(1);
  });

  it("organization_team_invitations(): visible status, effective role name, and never the token hash", async () => {
    const owner = await createSignedInUser("owner-read-model");
    const org = await createOrganization(owner, "org-read-model");

    const pendingEmail = invitedEmail("pendiente");
    const expiredEmail = invitedEmail("vencida");
    const revokedEmail = invitedEmail("revocada");
    const redeemedEmail = invitedEmail("activada");

    const { data: pending } = await issue(owner, org.id, pendingEmail, {
      displayName: "Pendiente",
    });
    const { data: expired } = await issue(owner, org.id, expiredEmail);
    const { data: revoked } = await issue(owner, org.id, revokedEmail);
    const { data: redeemed } = await issue(owner, org.id, redeemedEmail);

    await admin
      .from("team_invitations")
      .update({ expires_at: new Date(Date.now() - 60_000).toISOString() })
      .eq("id", expired!.invitation_id);
    await owner.client.rpc("revoke_team_invitation", {
      p_invitation_id: revoked!.invitation_id,
    });
    const claimer = await createSignedInUser("claimer-read-model", redeemedEmail);
    await claimer.client.rpc("claim_team_invitation", { p_token: redeemed!.token });

    // Por defecto: sólo lo que nadie usó ni se revocó -- incluidas las
    // vencidas, que son justo las que hay que reenviar.
    const { data: live } = await owner.client.rpc("organization_team_invitations", {
      p_organization_id: org.id,
    });
    const byId = new Map(
      (live as Array<Record<string, unknown>>).map((r) => [r.invitation_id as string, r]),
    );
    expect(byId.size).toBe(2);
    expect(byId.get(pending!.invitation_id)?.status).toBe("PENDING");
    expect(byId.get(expired!.invitation_id)?.status).toBe("EXPIRED");
    expect(byId.get(pending!.invitation_id)?.display_name).toBe("Pendiente");
    // Rol efectivo: se invitó sin elegir, así que es el "Equipo" por defecto
    // que siembra la Fase 32.
    expect(byId.get(pending!.invitation_id)?.role_id).toBeNull();
    expect(byId.get(pending!.invitation_id)?.role_name).toBe("Equipo");
    // Nunca el hash del token.
    expect(Object.keys(byId.get(pending!.invitation_id)!)).not.toContain("token_hash");

    const { data: history } = await owner.client.rpc("organization_team_invitations", {
      p_organization_id: org.id,
      p_include_history: true,
    });
    const statuses = (history as Array<Record<string, unknown>>).map((r) => r.status).sort();
    expect(statuses).toEqual(["EXPIRED", "PENDING", "REDEEMED", "REVOKED"]);
  });

  it("team_invitations is not readable or writable through PostgREST, not even by the OWNER", async () => {
    const owner = await createSignedInUser("owner-no-postgrest");
    const org = await createOrganization(owner, "org-no-postgrest");
    await issue(owner, org.id, invitedEmail("oculta"));

    const { data, error } = await owner.client.from("team_invitations").select("*");
    // Sin grant a `authenticated`: PostgREST responde con un error. Lo que
    // no puede pasar, de ninguna de las dos formas, es que salgan filas.
    expect(error).not.toBeNull();
    expect(data ?? []).toHaveLength(0);

    const { error: writeErr } = await owner.client.from("team_invitations").insert({
      organization_id: org.id,
      email: invitedEmail("a-mano"),
      token_hash: "\\xdeadbeef",
      expires_at: new Date(Date.now() + 3_600_000).toISOString(),
      created_by: owner.id,
    });
    expect(writeErr).not.toBeNull();
  });

  it("a role from another organization cannot be attached to an invitation", async () => {
    const ownerA = await createSignedInUser("owner-cross-role-a");
    const orgA = await createOrganization(ownerA, "org-cross-role-a");
    const ownerB = await createSignedInUser("owner-cross-role-b");
    const orgB = await createOrganization(ownerB, "org-cross-role-b");

    const { data: roleB } = await ownerB.client.rpc("create_organization_role", {
      p_organization_id: orgB.id,
      p_name: "Profesor B",
    });

    const { error } = await issue(ownerA, orgA.id, invitedEmail("cross-role"), {
      roleId: (roleB as { id: string }).id,
    });
    expect(error).not.toBeNull();
    expect(error!.message).toMatch(/ROLE_NOT_FOUND/);
  });

  it("a role deactivated between issuing and clicking fails closed, it does not silently fall back to the default", async () => {
    const owner = await createSignedInUser("owner-role-gone");
    const org = await createOrganization(owner, "org-role-gone");

    const { data: role } = await owner.client.rpc("create_organization_role", {
      p_organization_id: org.id,
      p_name: "Profesor",
      p_can_view_payments: false,
      p_can_manage_payments: false,
      p_can_manage_bookings: true,
      p_can_manage_customers: true,
      p_can_manage_attendance: true,
    });
    const roleId = (role as { id: string }).id;

    const email = invitedEmail("rol-desactivado");
    const { data: issued } = await issue(owner, org.id, email, { roleId });

    const { error: deactivateErr } = await owner.client.rpc("update_organization_role", {
      p_role_id: roleId,
      p_is_active: false,
    });
    expect(deactivateErr).toBeNull();

    const staff = await createSignedInUser("staff-role-gone", email);
    const { error } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect(error!.message).toMatch(/INVITATION_ROLE_UNAVAILABLE/);

    const { data: members } = await admin
      .from("organization_members")
      .select("id")
      .eq("organization_id", org.id)
      .eq("profile_id", staff.id);
    expect(members ?? []).toHaveLength(0);
  });

  it("an unknown token, a blank token and an anonymous caller are all rejected", async () => {
    const staff = await createSignedInUser("staff-bad-token");

    const { error: unknown } = await staff.client.rpc("claim_team_invitation", {
      p_token: "a".repeat(43),
    });
    expect(unknown!.message).toMatch(/INVALID_TOKEN/);

    const { error: blank } = await staff.client.rpc("claim_team_invitation", { p_token: "   " });
    expect(blank!.message).toMatch(/INVALID_TOKEN/);

    const anonClient = createClient(SUPABASE_URL, ANON_KEY);
    const { error: anonErr } = await anonClient.rpc("claim_team_invitation", {
      p_token: "a".repeat(43),
    });
    // ADR-0028: revoke execute from public, anon -- no llega ni a evaluar.
    expect(anonErr).not.toBeNull();
  });

  it("an invitation issued by another organization does not let anyone into this one", async () => {
    const ownerA = await createSignedInUser("owner-tenant-a");
    const orgA = await createOrganization(ownerA, "org-tenant-a");
    const ownerB = await createSignedInUser("owner-tenant-b");
    const orgB = await createOrganization(ownerB, "org-tenant-b");

    const email = invitedEmail("solo-para-b");
    const { data: issued } = await issue(ownerB, orgB.id, email);

    const staff = await createSignedInUser("staff-tenant", email);
    const { data: claim } = await staff.client.rpc("claim_team_invitation", {
      p_token: issued!.token,
    });
    expect((claim as { organization_slug?: string })?.organization_slug).toBe(orgB.slug);

    const { data: inA } = await admin
      .from("organization_members")
      .select("id")
      .eq("organization_id", orgA.id)
      .eq("profile_id", staff.id);
    expect(inA ?? []).toHaveLength(0);
  });

  it("a suspended organization cannot issue invitations", async () => {
    const owner = await createSignedInUser("owner-suspended");
    const org = await createOrganization(owner, "org-suspended");

    await admin.from("organizations").update({ subscription_status: "SUSPENDED" }).eq("id", org.id);

    const { error } = await issue(owner, org.id, invitedEmail("suspendida"));
    expect(error!.message).toMatch(/SUBSCRIPTION_INACTIVE/);
  });
});
