import { describe, expect, it } from "vitest";
import { isActiveCustomer, isActiveMember, isOwner, isStaffOrOwner } from "./invariants";

describe("isOwner", () => {
  it("is true for an active OWNER", () => {
    expect(isOwner({ role: "OWNER", isActive: true })).toBe(true);
  });

  it("is false for an active STAFF", () => {
    expect(isOwner({ role: "STAFF", isActive: true })).toBe(false);
  });

  it("is false for an inactive OWNER (revoked membership)", () => {
    expect(isOwner({ role: "OWNER", isActive: false })).toBe(false);
  });
});

describe("isStaffOrOwner", () => {
  it("is true for an active STAFF", () => {
    expect(isStaffOrOwner({ role: "STAFF", isActive: true })).toBe(true);
  });

  it("is true for an active OWNER", () => {
    expect(isStaffOrOwner({ role: "OWNER", isActive: true })).toBe(true);
  });

  it("is false once the membership is cancelled, regardless of role", () => {
    expect(isStaffOrOwner({ role: "OWNER", isActive: false })).toBe(false);
    expect(isStaffOrOwner({ role: "STAFF", isActive: false })).toBe(false);
  });
});

describe("isActiveMember / isActiveCustomer", () => {
  it("mirror the isActive flag directly", () => {
    expect(isActiveMember({ isActive: true })).toBe(true);
    expect(isActiveMember({ isActive: false })).toBe(false);
    expect(isActiveCustomer({ isActive: true })).toBe(true);
    expect(isActiveCustomer({ isActive: false })).toBe(false);
  });
});
