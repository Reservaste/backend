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

// ---------------------------------------------------------------
// Phase 2: Service, Resource, ServiceEntitlement
// ---------------------------------------------------------------

export type ResourceCancellationReason = "DISCONTINUED_BY_ORGANIZATION";

export interface Resource {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: ResourceCancellationReason | null;
}

export type ServiceCancellationReason = "DISCONTINUED_BY_ORGANIZATION";

export interface Service {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
  /** ADR-0008: null means "use the Organization's default". */
  publicAvailabilityDisplayOverride: PublicAvailabilityDisplay | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: ServiceCancellationReason | null;
}

// ---------------------------------------------------------------
// Phase 3: ScheduleRule, ScheduleException, SlotOccurrence
// ---------------------------------------------------------------

export type ScheduleRuleCancellationReason = "DISCONTINUED_BY_ORGANIZATION";

export interface ScheduleRule {
  id: string;
  organizationId: string;
  serviceId: string;
  resourceId: string;
  /** 0 = Sunday, matches JS Date#getDay(). */
  weekday: number;
  /** Wall-clock local time, e.g. "09:00:00". Ref: ADR-0014. */
  localStartTime: string;
  durationMinutes: number;
  capacity: number;
  validFrom: string;
  validUntil: string | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: ScheduleRuleCancellationReason | null;
}

export type ScheduleExceptionType = "CANCELLED" | "MODIFIED";

export interface ScheduleException {
  id: string;
  organizationId: string;
  scheduleRuleId: string;
  exceptionDate: string;
  exceptionType: ScheduleExceptionType;
  modifiedLocalStartTime: string | null;
  modifiedDurationMinutes: number | null;
  modifiedCapacity: number | null;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
}

export type SlotOccurrenceStatus = "ACTIVE" | "BLOCKED" | "CANCELLED";
export type SlotOccurrenceCancellationReason = "SLOT_CANCELLED" | "RULE_DISCONTINUED";

export interface SlotOccurrence {
  id: string;
  organizationId: string;
  scheduleRuleId: string;
  serviceId: string;
  resourceId: string;
  startAt: string;
  endAt: string;
  generatedTimezone: string;
  capacity: number;
  status: SlotOccurrenceStatus;
  scheduleExceptionId: string | null;
  createdAt: string;
  updatedAt: string;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: SlotOccurrenceCancellationReason | null;
}

// ---------------------------------------------------------------
// Phase 4: public calendar shapes (from organizations_public,
// services_public, get_public_availability -- never the base tables)
// ---------------------------------------------------------------

export interface PublicOrganization {
  id: string;
  slug: string;
  name: string;
  timezone: string;
}

export interface PublicService {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
}

/**
 * Shape of one row from get_public_availability(). `remaining`/`capacity`
 * are only ever non-null when `mode === "EXACT"` -- the database itself
 * enforces this (ADR-0008), not this type. `status` is only set for
 * LIMITED/BOOLEAN modes.
 */
export interface PublicAvailabilitySlot {
  slotOccurrenceId: string;
  serviceId: string;
  startAt: string;
  endAt: string;
  mode: PublicAvailabilityDisplay;
  status: "AVAILABLE" | "LOW" | "FULL" | null;
  remaining: number | null;
  capacity: number | null;
}

// ---------------------------------------------------------------
// Phase 5: Booking
// ---------------------------------------------------------------

export type BookingStatus = "CONFIRMED" | "CANCELLED";
export type BookingCancellationReason = "CUSTOMER_REQUEST" | "SLOT_CANCELLED" | "RULE_DISCONTINUED";

export interface Booking {
  id: string;
  organizationId: string;
  customerId: string;
  slotOccurrenceId: string;
  status: BookingStatus;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: BookingCancellationReason | null;
}

/** Reason codes returned by can_customer_book() / book_slot(). Ref: ADR-0005, ADR-0013. */
export type CanBookReason =
  | "OK"
  | "AUTH_REQUIRED"
  | "NOT_A_CUSTOMER"
  | "ORGANIZATION_INACTIVE"
  | "SERVICE_INACTIVE"
  | "OCCURRENCE_NOT_AVAILABLE"
  | "NO_ENTITLEMENT"
  | "SLOT_FULL"
  | "ALREADY_BOOKED";

export interface BookSlotResult {
  status: CanBookReason | "DUPLICATE";
  booking?: Booking;
}

export type EntitlementType = "TIME" | "CREDITS";
export type EntitlementCancellationReason = "CUSTOMER_REQUEST" | "ORGANIZATION_REVOKED";

export interface ServiceEntitlement {
  id: string;
  organizationId: string;
  customerId: string;
  serviceId: string;
  entitlementType: EntitlementType;
  /** ADR-0013: whether canCustomerBook() (Phase 7) also requires a covering Payment. */
  requiresActivePayment: boolean;
  /** Set when entitlementType is "TIME", null otherwise. */
  validFrom: string | null;
  validUntil: string | null;
  /** Set when entitlementType is "CREDITS", null otherwise. */
  creditsTotal: number | null;
  creditsRemaining: number | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: EntitlementCancellationReason | null;
}
