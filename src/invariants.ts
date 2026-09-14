// Pure domain rules for Phase 1. No I/O, no Supabase client -- these are
// the functions both the frontend server actions and any future backend
// code call so the rule is defined once. Ref: docs/domain.md, docs/security.md.

import type { Customer, OrganizationMember } from "./types.js";

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
