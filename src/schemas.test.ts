import { describe, expect, it } from "vitest";
import {
  claimTeamInvitationSchema,
  createOrganizationRoleSchema,
  createOrganizationSchema,
  inviteTeamMemberSchema,
  setMemberRoleSchema,
  organizationSlugSchema,
  RESERVED_ORGANIZATION_SLUGS,
  signUpSchema,
  submitContactRequestSchema,
  timezoneSchema,
  updateOrganizationRoleSchema,
} from "./schemas";

describe("organizationSlugSchema", () => {
  it("accepts lowercase words separated by hyphens", () => {
    expect(organizationSlugSchema.safeParse("iron-gym").success).toBe(true);
  });

  it("rejects uppercase, spaces and leading/trailing hyphens", () => {
    expect(organizationSlugSchema.safeParse("Iron Gym").success).toBe(false);
    expect(organizationSlugSchema.safeParse("-iron-gym").success).toBe(false);
    expect(organizationSlugSchema.safeParse("iron-gym-").success).toBe(false);
    expect(organizationSlugSchema.safeParse("iron--gym").success).toBe(false);
  });

  it("rejects a slug that is too short", () => {
    expect(organizationSlugSchema.safeParse("a").success).toBe(false);
  });

  it("rejects every reserved top-level route segment (Phase 27b)", () => {
    for (const slug of RESERVED_ORGANIZATION_SLUGS) {
      expect(organizationSlugSchema.safeParse(slug).success, slug).toBe(false);
    }
  });

  it("accepts a slug that only contains a reserved word", () => {
    expect(organizationSlugSchema.safeParse("equipo-norte").success).toBe(true);
    expect(organizationSlugSchema.safeParse("mega").success).toBe(true);
  });
});

describe("timezoneSchema", () => {
  it("accepts a real IANA zone", () => {
    expect(timezoneSchema.safeParse("America/Montevideo").success).toBe(true);
  });

  it("rejects a made-up zone name", () => {
    expect(timezoneSchema.safeParse("Not/A_Real_Zone").success).toBe(false);
  });
});

describe("createOrganizationSchema", () => {
  it("defaults timezone to America/Montevideo when omitted", () => {
    const result = createOrganizationSchema.safeParse({ slug: "iron-gym", name: "Iron Gym" });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.timezone).toBe("America/Montevideo");
    }
  });

  it("rejects a name that is too short", () => {
    const result = createOrganizationSchema.safeParse({ slug: "iron-gym", name: "I" });
    expect(result.success).toBe(false);
  });
});

describe("signUpSchema", () => {
  it("rejects a password shorter than 8 characters", () => {
    const result = signUpSchema.safeParse({
      email: "mathias@example.com",
      password: "short",
      fullName: "Mathias",
    });
    expect(result.success).toBe(false);
  });

  it("accepts a valid signup payload", () => {
    const result = signUpSchema.safeParse({
      email: "mathias@example.com",
      password: "supersecret123",
      fullName: "Mathias",
    });
    expect(result.success).toBe(true);
  });
});

describe("submitContactRequestSchema", () => {
  it("accepts a minimal valid payload (no phone, no businessType)", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana Pérez",
      email: "ana@example.com",
      message: "Quiero agendar turnos para mi consultorio.",
    });
    expect(result.success).toBe(true);
  });

  it("accepts phone and businessType as empty strings (optional fields from a form)", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana Pérez",
      email: "ana@example.com",
      message: "Quiero agendar turnos.",
      phone: "",
      businessType: "",
    });
    expect(result.success).toBe(true);
  });

  it("rejects an empty name", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "   ",
      email: "ana@example.com",
      message: "algo",
    });
    expect(result.success).toBe(false);
  });

  it("rejects an invalid email", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana",
      email: "no-es-un-email",
      message: "algo",
    });
    expect(result.success).toBe(false);
  });

  it("rejects an empty message", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana",
      email: "ana@example.com",
      message: "   ",
    });
    expect(result.success).toBe(false);
  });

  it("rejects a message over 4000 characters", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana",
      email: "ana@example.com",
      message: "x".repeat(4001),
    });
    expect(result.success).toBe(false);
  });

  it("accepts a reasonable phone format", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana",
      email: "ana@example.com",
      message: "algo",
      phone: "099 123 456",
    });
    expect(result.success).toBe(true);
  });

  it("rejects a phone with letters", () => {
    const result = submitContactRequestSchema.safeParse({
      name: "Ana",
      email: "ana@example.com",
      message: "algo",
      phone: "abc",
    });
    expect(result.success).toBe(false);
  });
});

// ADR-0033
describe("createOrganizationRoleSchema", () => {
  it("rejects a role that charges but cannot see what it charged", () => {
    const result = createOrganizationRoleSchema.safeParse({
      name: "Profesor",
      canViewPayments: false,
      canManagePayments: true,
      canManageBookings: true,
      canManageCustomers: true,
      canManageAttendance: true,
    });
    expect(result.success).toBe(false);
  });

  it("accepts the role the user actually asked for: a teacher with no payments", () => {
    const result = createOrganizationRoleSchema.safeParse({
      name: "Profesor",
      canViewPayments: false,
      canManagePayments: false,
      canManageBookings: true,
      canManageCustomers: true,
      canManageAttendance: true,
    });
    expect(result.success).toBe(true);
  });

  it("defaults to the current STAFF behaviour when nothing is said", () => {
    const result = createOrganizationRoleSchema.safeParse({ name: "Equipo" });
    expect(result.success).toBe(true);
    expect(result.data).toMatchObject({
      canViewPayments: true,
      canManagePayments: true,
      canManageBookings: true,
      canManageCustomers: true,
      canManageAttendance: true,
    });
  });

  it("rejects a blank name", () => {
    expect(createOrganizationRoleSchema.safeParse({ name: "   " }).success).toBe(false);
  });
});

describe("updateOrganizationRoleSchema", () => {
  it("rejects turning MANAGE on while turning VIEW off in the same edit", () => {
    const result = updateOrganizationRoleSchema.safeParse({
      roleId: "11111111-1111-4111-8111-111111111111",
      canManagePayments: true,
      canViewPayments: false,
    });
    expect(result.success).toBe(false);
  });

  it("allows a partial edit that says nothing about payments", () => {
    const result = updateOrganizationRoleSchema.safeParse({
      roleId: "11111111-1111-4111-8111-111111111111",
      name: "Recepción",
    });
    expect(result.success).toBe(true);
  });
});

describe("setMemberRoleSchema", () => {
  it("accepts null as 'back to the default role'", () => {
    const result = setMemberRoleSchema.safeParse({
      memberId: "11111111-1111-4111-8111-111111111111",
      roleId: null,
    });
    expect(result.success).toBe(true);
  });
});

describe("inviteTeamMemberSchema (ADR-0034)", () => {
  const organizationId = "11111111-1111-4111-8111-111111111111";

  it("normalizes the email to lowercase, so the border and the base agree on which invitation is 'the same'", () => {
    const result = inviteTeamMemberSchema.safeParse({
      organizationId,
      email: "  Profe@Example.COM ",
      displayName: "Juan Pérez",
    });
    expect(result.success).toBe(true);
    expect(result.success && result.data.email).toBe("profe@example.com");
  });

  it("accepts an invitation with no phone: the channel is optional, the email is not", () => {
    expect(
      inviteTeamMemberSchema.safeParse({ organizationId, email: "profe@example.com" }).success,
    ).toBe(true);
    expect(inviteTeamMemberSchema.safeParse({ organizationId }).success).toBe(false);
  });

  it("accepts roleId null as 'the organization's default role'", () => {
    const result = inviteTeamMemberSchema.safeParse({
      organizationId,
      email: "profe@example.com",
      roleId: null,
    });
    expect(result.success).toBe(true);
  });

  it("rejects a malformed email and a malformed phone", () => {
    expect(
      inviteTeamMemberSchema.safeParse({ organizationId, email: "no-arroba" }).success,
    ).toBe(false);
    expect(
      inviteTeamMemberSchema.safeParse({
        organizationId,
        email: "profe@example.com",
        phone: "cero-nueve-nueve",
      }).success,
    ).toBe(false);
  });
});

describe("claimTeamInvitationSchema (ADR-0034)", () => {
  it("accepts a 43-character base64url token (32 bytes, no padding)", () => {
    const token = "a".repeat(40) + "_-Z";
    expect(claimTeamInvitationSchema.safeParse({ token }).success).toBe(true);
  });

  it("rejects anything that cannot be one of our tokens", () => {
    expect(claimTeamInvitationSchema.safeParse({ token: "short" }).success).toBe(false);
    // '+' and '/' are base64, not base64url: our tokens never contain them.
    expect(
      claimTeamInvitationSchema.safeParse({ token: "a".repeat(42) + "+" }).success,
    ).toBe(false);
    expect(claimTeamInvitationSchema.safeParse({ token: "" }).success).toBe(false);
  });
});
