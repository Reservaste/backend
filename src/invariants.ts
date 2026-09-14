// Pure domain rules for Phase 1. No I/O, no Supabase client -- these are
// the functions both the frontend server actions and any future backend
// code call so the rule is defined once. Ref: docs/domain.md, docs/security.md.

import type { Customer, OrganizationMember, ServiceEntitlement } from "./types";

/** True if the member row grants admin-side access to its organization. */
export function isActiveMember(member: Pick<OrganizationMember, "isActive">): boolean {
  return member.isActive;
}

export function isOwner(member: Pick<OrganizationMember, "role" | "isActive">): boolean {
  return member.isActive && member.role === "OWNER";
}

export function isStaffOrOwner(member: Pick<OrganizationMember, "role" | "isActive">): boolean {
  return member.isActive && (member.role === "OWNER" || member.role === "STAFF");
}

/** True if the customer row still represents an active relationship with the org. */
export function isActiveCustomer(customer: Pick<Customer, "isActive">): boolean {
  return customer.isActive;
}

/**
 * True if the entitlement is currently usable: active, and within its
 * vigencia (TIME: today falls in [validFrom, validUntil]; CREDITS: at
 * least one credit remaining). Does not check Payment -- that is
 * `requiresActivePayment` + Payment, evaluated separately by
 * canCustomerBook() in Phase 7. Ref: docs/domain.md, ADR-0013.
 */
export function isEntitlementCurrentlyValid(
  entitlement: Pick<
    ServiceEntitlement,
    "isActive" | "entitlementType" | "validFrom" | "validUntil" | "creditsRemaining"
  >,
  asOf: Date = new Date(),
): boolean {
  if (!entitlement.isActive) {
    return false;
  }

  if (entitlement.entitlementType === "TIME") {
    const asOfDate = asOf.toISOString().slice(0, 10);
    const fromOk = entitlement.validFrom === null || asOfDate >= entitlement.validFrom;
    const untilOk = entitlement.validUntil === null || asOfDate <= entitlement.validUntil;
    return fromOk && untilOk;
  }

  return (entitlement.creditsRemaining ?? 0) > 0;
}
