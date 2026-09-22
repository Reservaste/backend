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
  /** ISO 4217 code every price of this organization is quoted in. Ref: ADR-0024. */
  currency: string;
  /** Accent colour as #rrggbb, or null for the product default. Ref: ADR-0020. */
  brandColor: string | null;
  /** Object path inside the organization-logos bucket. Ref: ADR-0020. */
  logoPath: string | null;
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

export type BillingType = "FREE" | "ONE_TIME" | "MONTHLY";
export type BillingCycle = "CALENDAR_MONTH" | "ROLLING_MONTH";

export interface Service {
  id: string;
  organizationId: string;
  name: string;
  description: string | null;
  /** @deprecated ADR-0024. The billing period belongs to ServicePlan. */
  billingType: BillingType;
  /** @deprecated ADR-0024. See ServicePlan.billingCycle. */
  billingCycle: BillingCycle | null;
  /** @deprecated ADR-0024. A service has several simultaneous prices; see ServicePlan.price. */
  price: number | null;
  /** Whether a Payment covering the slot's date is needed to book. */
  paymentRequired: boolean;
  /** #rrggbb used to tell services apart on the calendar, or null. */
  color: string | null;
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
  /** Ref: ADR-0020. Branding is public -- it renders for visitors with no session. */
  brandColor: string | null;
  logoPath: string | null;
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
  /** Ref: ADR-0023. The public calendar shows several services at once. */
  serviceName: string;
  serviceColor: string | null;
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

export type BookingStatus = "CONFIRMED" | "CANCELLED" | "NOT_GENERATED";
/**
 * SERIES_CANCELLED (ADR-0025 res. 2, Phase 19) is what the cascade of
 * cancel_recurring_booking() stamps on the series' future children,
 * whoever asked for it. Before it existed the staff path said
 * RULE_DISCONTINUED -- and the rule had not been discontinued -- while
 * the customer path said CUSTOMER_REQUEST, and the customer had not
 * asked for that particular date.
 */
export type BookingCancellationReason =
  | "CUSTOMER_REQUEST"
  | "SLOT_CANCELLED"
  | "RULE_DISCONTINUED"
  | "SERIES_CANCELLED";

export interface Booking {
  id: string;
  organizationId: string;
  customerId: string;
  slotOccurrenceId: string;
  /** Null for a standalone booking; set when generated by a RecurringBooking series. Ref: ADR-0011. */
  recurringBookingId: string | null;
  /** Which entitlement was consumed -- needed to restore a credit on cancellation. */
  serviceEntitlementId: string | null;
  status: BookingStatus;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: BookingCancellationReason | null;
}

// ---------------------------------------------------------------
// Phase 6: RecurringBooking
// ---------------------------------------------------------------

// ---------------------------------------------------------------
// Phase 17: ServicePlan (ADR-0024)
// ---------------------------------------------------------------

/**
 * What a payment buys. `DROP_IN` is a single class, `WEEKLY_QUOTA` is N
 * fixed weekly slots (N RecurringBooking in force), `UNLIMITED` is the
 * pre-ADR-0024 behaviour. Generic by design: a single class, a fixed
 * weekly slot or an unrestricted pass, in any vertical.
 */
export type ServicePlanKind = "DROP_IN" | "WEEKLY_QUOTA" | "UNLIMITED";

export interface ServicePlan {
  id: string;
  organizationId: string;
  /** A plan belongs to exactly one Service (ADR-0024 §2.3). */
  serviceId: string;
  name: string;
  description: string | null;
  /** Rendered with Organization.currency -- the plan has no currency of its own. */
  price: number;
  planKind: ServicePlanKind;
  /**
   * How many RecurringBooking in force this plan allows, counted for the
   * slot's local date. Non-null if and only if planKind is
   * "WEEKLY_QUOTA" -- the database enforces this, not this type.
   */
  weeklyQuota: number | null;
  billingType: BillingType;
  billingCycle: BillingCycle | null;
  /**
   * false means "no longer offered". It never invalidates a payment
   * already made (ADR-0024 §6.d).
   */
  isActive: boolean;
  sortOrder: number;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
}

// ---------------------------------------------------------------
// Phase 7: Payment
// ---------------------------------------------------------------

export type PaymentStatus = "PAID" | "PENDING" | "OVERDUE" | "VOID";

export interface Payment {
  id: string;
  organizationId: string;
  customerId: string;
  /**
   * ADR-0024: the registration anchor -- what was bought. The booking
   * path reads the plan's terms from here.
   */
  servicePlanId: string;
  /** Derived from the plan and verified by trigger, not a second source of truth. */
  serviceId: string;
  /**
   * Set exactly for DROP_IN payments: which class was paid. Its period
   * is the occurrence's local date, on both ends.
   */
  slotOccurrenceId: string | null;
  /** @deprecated ADR-0022. Historical provenance only; null on new payments. */
  serviceEntitlementId: string | null;
  periodStart: string;
  periodEnd: string;
  status: PaymentStatus;
  amount: number | null;
  notes: string | null;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
}

export type RecurringBookingStatus = "ACTIVE" | "CANCELLED";
export type RecurringBookingCancellationReason = "CUSTOMER_REQUEST" | "ORGANIZATION_REMOVED";

export interface RecurringBooking {
  id: string;
  organizationId: string;
  customerId: string;
  scheduleRuleId: string;
  status: RecurringBookingStatus;
  startDate: string;
  endDate: string | null;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: RecurringBookingCancellationReason | null;
}

/** One row of preview_recurring_booking() -- ADR-0012. */
export interface RecurringBookingPreviewSlot {
  slotOccurrenceId: string;
  startAt: string;
  canBook: CanBookReason;
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
  | "ALREADY_BOOKED"
  /** No payment covers the slot's date. Ref: ADR-0013, ADR-0022. */
  | "PAYMENT_REQUIRED"
  /**
   * ADR-0024: the month *is* paid, but this booking is not one of the
   * fixed slots the plan bought. Remedy: pay the single class, use a
   * make-up credit, or wait. Never render this as "you have to pay".
   */
  | "OUTSIDE_PLAN_QUOTA"
  /** ADR-0024: this series exceeds the plan's frequency. Remedy: upgrade the plan or drop a series. */
  | "OVER_PLAN_QUOTA"
  /** ADR-0024: the service demands payment and has no active plan. An owner configuration error. */
  | "SERVICE_HAS_NO_PLAN";

/** Why a recurring date could not be confirmed. Ref: ADR-0018, ADR-0024. */
export type NotGeneratedReason =
  | "SLOT_FULL"
  | "PAYMENT_REQUIRED"
  | "DUPLICATE"
  /** The date belongs to a series that does not fit the plan's quota. */
  | "OVER_PLAN_QUOTA";

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
