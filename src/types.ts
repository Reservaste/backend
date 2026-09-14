// Domain types for Phase 1 (Auth + Organizations + Roles).
// Ref: docs/domain.md, docs/decisions.md (ADR-0006, ADR-0008, ADR-0010, ADR-0014).
//
// Never introduce Gym/Member/Trainer/Class here -- see CLAUDE.md.
// Field names mirror the snake_case columns from the Supabase schema
// (backend/supabase/migrations) via the mapping helpers in ./mappers.ts,
// so these types intentionally use camelCase for consumers in TypeScript.

export type PublicAvailabilityDisplay = "EXACT" | "LIMITED" | "BOOLEAN";

export interface Organization {
  id: string;
  slug: string;
  name: string;
  /** IANA timezone name, e.g. "America/Montevideo". Ref: ADR-0014. */
  timezone: string;
  /** Default disclosure mode for public availability. Ref: ADR-0008. */
  publicAvailabilityDisplay: PublicAvailabilityDisplay;
  lowAvailabilityPercentage: number;
  lowAvailabilityFixedCap: number | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
}

export type OrganizationMemberRole = "OWNER" | "STAFF";
export type MemberCancellationReason = "REVOKED_BY_ORGANIZATION" | "SELF_REMOVED";

export interface OrganizationMember {
  id: string;
  organizationId: string;
  profileId: string;
  role: OrganizationMemberRole;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: MemberCancellationReason | null;
}

export interface Profile {
  id: string;
  fullName: string | null;
  avatarUrl: string | null;
  createdAt: string;
  updatedAt: string;
}

export type CustomerCancellationReason = "CUSTOMER_REQUEST" | "ORGANIZATION_REMOVED";

export interface Customer {
  id: string;
  organizationId: string;
  profileId: string;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: CustomerCancellationReason | null;
}
