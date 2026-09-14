import { describe, expect, it } from "vitest";
import { createOrganizationSchema, organizationSlugSchema, signUpSchema, timezoneSchema } from "./schemas";

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
