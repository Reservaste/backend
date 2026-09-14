import { describe, expect, it } from "vitest";
import { isActiveCustomer, isActiveMember, isEntitlementCurrentlyValid, isOwner, isStaffOrOwner } from "./invariants";

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

describe("isEntitlementCurrentlyValid", () => {
  const asOf = new Date("2026-09-15T12:00:00Z");

  it("is false when the entitlement itself is inactive, regardless of vigencia", () => {
    expect(
      isEntitlementCurrentlyValid(
        { isActive: false, entitlementType: "TIME", validFrom: "2026-01-01", validUntil: null, creditsRemaining: null },
        asOf,
      ),
    ).toBe(false);
  });

  describe("TIME entitlements", () => {
    it("is valid when today falls within [validFrom, validUntil]", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "TIME", validFrom: "2026-09-01", validUntil: "2026-09-30", creditsRemaining: null },
          asOf,
        ),
      ).toBe(true);
    });

    it("is invalid once past validUntil -- the exact 'pago vencido' case from ADR-0013", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "TIME", validFrom: "2026-08-01", validUntil: "2026-08-31", creditsRemaining: null },
          asOf,
        ),
      ).toBe(false);
    });

    it("is invalid before validFrom", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "TIME", validFrom: "2026-10-01", validUntil: null, creditsRemaining: null },
          asOf,
        ),
      ).toBe(false);
    });

    it("is valid indefinitely when validUntil is null", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "TIME", validFrom: "2020-01-01", validUntil: null, creditsRemaining: null },
          asOf,
        ),
      ).toBe(true);
    });
  });

  describe("CREDITS entitlements", () => {
    it("is valid with at least one credit remaining", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "CREDITS", validFrom: null, validUntil: null, creditsRemaining: 1 },
          asOf,
        ),
      ).toBe(true);
    });

    it("is invalid with zero credits remaining", () => {
      expect(
        isEntitlementCurrentlyValid(
          { isActive: true, entitlementType: "CREDITS", validFrom: null, validUntil: null, creditsRemaining: 0 },
          asOf,
        ),
      ).toBe(false);
    });
  });
});
