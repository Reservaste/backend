import { describe, expect, it } from "vitest";
import {
  createOrganizationSchema,
  organizationSlugSchema,
  signUpSchema,
  submitContactRequestSchema,
  timezoneSchema,
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
