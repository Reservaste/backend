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
  /**
   * ADR-0033: rol configurable del miembro dentro de `STAFF`. Null = el rol
   * `isDefault` de la organización (no "sin permisos"). Siempre null para un
   * `OWNER`, que corta antes de mirar cualquier permiso.
   */
  roleId: string | null;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
  cancelledAt: string | null;
  cancelledBy: string | null;
  cancellationReason: MemberCancellationReason | null;
}

/**
 * ADR-0033: los cinco permisos configurables del primer corte. El conjunto es
 * cerrado a propósito -- lo que no está acá no es configurable y sigue siendo
 * de todo miembro activo (ver el calendario, la agenda, el padrón, los
 * horarios) o ya es OWNER-only (configuración, branding, invitar equipo,
 * administrar roles, planes y precios, créditos manuales).
 *
 * `MANAGE_PAYMENTS` implica `VIEW_PAYMENTS`: cobrar sin poder ver lo cobrado
 * no es un rol, es un bug (hay un CHECK en la base que lo garantiza).
 */
export type OrgPermission =
  | "VIEW_PAYMENTS"
  | "MANAGE_PAYMENTS"
  | "MANAGE_BOOKINGS"
  | "MANAGE_CUSTOMERS"
  | "MANAGE_ATTENDANCE";

/** Los permisos de un miembro, ya resueltos (rol propio o rol por defecto). */
export interface OrganizationPermissions {
  canViewPayments: boolean;
  canManagePayments: boolean;
  canManageBookings: boolean;
  canManageCustomers: boolean;
  canManageAttendance: boolean;
}

/**
 * ADR-0033: rol configurable por organización, con nombre libre elegido por
 * ella ("Profesor", "Recepción"). Los permisos son columnas booleanas y no un
 * `jsonb`, para que no exista el estado "la clave no está" -- ver ADR-0033
 * §4.2 y el bypass de autorización de ADR-0026/ADR-0028.
 */
export interface OrganizationRole extends OrganizationPermissions {
  id: string;
  organizationId: string;
  name: string;
  /** El rol que recibe un `STAFF` sin `roleId`. Exactamente uno por organización. */
  isDefault: boolean;
  isActive: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: string | null;
}

/** Fila de `my_organization_permissions()`: el rol efectivo + sus permisos. */
export interface MyOrganizationPermissions extends OrganizationPermissions {
  role: OrganizationMemberRole;
  /** Null para un `OWNER`: no tiene rol configurable. */
  roleId: string | null;
  roleName: string | null;
}

/** Fila de `organization_team()`: el miembro con su rol EFECTIVO. */
export interface OrganizationTeamMember {
  memberId: string;
  profileId: string;
  fullName: string;
  role: OrganizationMemberRole;
  isActive: boolean;
  /** Rol efectivo (el asignado, o el por defecto). Null para un `OWNER`. */
  roleId: string | null;
  roleName: string | null;
}

/**
 * ADR-0034: estado derivado de una invitación de equipo. No es una columna —
 * se calcula en `organization_team_invitations()` a partir de
 * `redeemedAt`/`revokedAt`/`expiresAt`, en ese orden de precedencia. Una
 * invitación vencida sigue siendo "pendiente" en el sentido de que nadie la
 * usó: es justo la que hay que reenviar.
 */
export type TeamInvitationStatus = "PENDING" | "REDEEMED" | "REVOKED" | "EXPIRED";

/**
 * ADR-0034: invitación de equipo con link de un solo uso y 24 h de vida, para
 * dar de alta a alguien que todavía no tiene cuenta en la plataforma.
 *
 * Mecanismo separado de la activación de clientes (ADR-0026): lo que otorga
 * este token es acceso a los datos de terceros de todo el tenant, no "sos vos
 * mismo". Nunca puede crear un `OWNER` (hay un CHECK en la base), el canje
 * exige que el email de la sesión coincida, y no lleva `tokenHash`: el hash
 * nunca sale de la base y el token claro existe una sola vez, en el retorno de
 * la RPC de emisión.
 */
export interface TeamInvitation {
  id: string;
  organizationId: string;
  /** Normalizado a minúsculas. Es el vínculo que el canje exige, no el canal. */
  email: string;
  /** E.164 con `+`. Sólo canal de envío (el link de WhatsApp). */
  phone: string | null;
  /** El nombre con el que el dueño dio de alta a la persona. No es identidad. */
  displayName: string | null;
  /** Siempre `"STAFF"`: una invitación nunca crea un `OWNER` (ADR-0034 resolución 5). */
  role: Extract<OrganizationMemberRole, "STAFF">;
  /** Rol configurable elegido al invitar. Null = el rol por defecto de la organización. */
  roleId: string | null;
  expiresAt: string;
  createdAt: string;
  createdBy: string;
  redeemedAt: string | null;
  redeemedProfileId: string | null;
  revokedAt: string | null;
  revokedBy: string | null;
}

/** Fila de `organization_team_invitations()`: la invitación + su estado derivado. */
export interface OrganizationTeamInvitation {
  invitationId: string;
  email: string;
  displayName: string | null;
  phone: string | null;
  /** Rol elegido al invitar; null significa "el por defecto". */
  roleId: string | null;
  /** Nombre del rol EFECTIVO (el elegido, o el por defecto de la organización). */
  roleName: string | null;
  status: TeamInvitationStatus;
  createdAt: string;
  expiresAt: string;
  redeemedAt: string | null;
  redeemedProfileId: string | null;
  revokedAt: string | null;
  createdBy: string;
}

export interface Profile {
  id: string;
  fullName: string | null;
  avatarUrl: string | null;
  createdAt: string;
  updatedAt: string;
}

export type CustomerCancellationReason = "CUSTOMER_REQUEST" | "ORGANIZATION_REMOVED";

/**
 * ADR-0026: a Customer can now exist without a Profile ("managed
 * customer") -- created by staff from a name+phone, agendable and
 * chargeable, with no session and nothing visible to them. `profileId`
 * becomes non-null ("activated") only through claim_customer_activation()
 * (or the pre-existing enroll_customer_by_email() self-service path).
 */
export interface Customer {
  id: string;
  organizationId: string;
  /** Null for a managed customer. Ref: ADR-0026. */
  profileId: string | null;
  /** Set only when profileId is null (ADR-0026 customers_identity_or_name). */
  displayName: string | null;
  /** E.164 with leading "+", normalized by create_managed_customer(). */
  phone: string | null;
  /** When this row went from managed to activated, or null. */
  claimedAt: string | null;
  /** Set by merge_customers() on the (now inactive) source row. Ref: ADR-0026 Sec 2.5. */
  mergedIntoCustomerId: string | null;
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
/**
 * ADR-0031: `CALENDAR_PERIOD` and `ROLLING_PERIOD` are the generalizations
 * of the two monthly cycles over `ServicePlan.billingPeriodMonths` (a
 * quarter, a year). `CALENDAR_MONTH`/`ROLLING_MONTH` are neither removed
 * nor deprecated -- they are the `billingPeriodMonths = 1` case and the
 * whole of the existing data.
 */
export type BillingCycle =
  | "CALENDAR_MONTH"
  | "ROLLING_MONTH"
  | "CALENDAR_PERIOD"
  | "ROLLING_PERIOD";

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

// ---------------------------------------------------------------
// Phase 20: MakeupCredit (ADR-0025)
// ---------------------------------------------------------------

export type MakeupCreditOrigin = "CUSTOMER_RELEASE" | "ORGANIZATION_CANCELLED" | "MANUAL";
export type MakeupCreditStatus = "AVAILABLE" | "CONSUMED" | "REVOKED";
export type MakeupCreditExpiryBasis = "END_OF_MONTH" | "END_OF_BILLING_PERIOD" | "DAYS_AFTER";

/**
 * The right to ONE extra booking (ADR-0024's sense of "extra") on a
 * Service, earned by releasing a seat in time or by an organization-side
 * cancellation. Never a prepaid package: it is not bought, not recharged,
 * and its count can never exceed the bookings the customer actually lost.
 * `expiresOn` is frozen at issuance -- nothing recomputes it later.
 */
export interface MakeupCredit {
  id: string;
  organizationId: string;
  customerId: string;
  serviceId: string;
  origin: MakeupCreditOrigin;
  /** Null exactly when origin is "MANUAL". */
  sourceBookingId: string | null;
  issuedAt: string;
  issuedBy: string | null;
  /** Frozen at issuance, anchored to the released occurrence's local date -- never recomputed. */
  expiresOn: string;
  expiryBasis: MakeupCreditExpiryBasis;
  expiryBasisDays: number | null;
  status: MakeupCreditStatus;
  consumedBookingId: string | null;
  consumedAt: string | null;
  revokedAt: string | null;
  revokedBy: string | null;
  note: string | null;
  createdAt: string;
  updatedAt: string;
}

/** One row of my_makeup_credits() / organization_customer_makeup_credits(). is_expired is computed in SQL. */
export interface MyMakeupCreditRow {
  creditId: string;
  organizationName?: string;
  serviceName: string;
  origin: MakeupCreditOrigin;
  status: MakeupCreditStatus;
  issuedAt: string;
  expiresOn: string;
  isExpired: boolean;
  sourceStartAt?: string | null;
  note?: string | null;
}

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
  /**
   * ADR-0025: a seat freed by a customer's own on-time release in the last
   * 72h. No count, no actor, no timestamp -- and null (not false) when
   * ADR-0008 suppresses it: BOOLEAN disclosure mode, or capacity 1 (where
   * "released" would be indistinguishable from "there was a booking and
   * it got cancelled", ADR-0007's original problem).
   */
  recentlyReleased: boolean | null;
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

/**
 * ADR-0029: how a WEEKLY_QUOTA's weeklyQuota is measured when the plan
 * covers more than one Service. PER_SERVICE -- the quota applies to each
 * covered service independently (the pre-ADR-0029 behaviour, generalized).
 * SHARED_ACROSS_SERVICES -- one pool of N series total, spent on any
 * combination of the covered services. Non-null if and only if planKind is
 * "WEEKLY_QUOTA".
 */
export type PlanQuotaScope = "PER_SERVICE" | "SHARED_ACROSS_SERVICES";

export interface ServicePlan {
  id: string;
  organizationId: string;
  /**
   * ADR-0029: a plan covers one, several, or all of the organization's
   * Service. `serviceIds` is the explicit, closed selection
   * (service_plan_services); when `appliesToAllServices` is true it is
   * resolved live against the organization's active services instead
   * (never both -- the database enforces mutual exclusion).
   */
  serviceIds: string[];
  appliesToAllServices: boolean;
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
  /** ADR-0029: required exactly when planKind is "WEEKLY_QUOTA". */
  quotaScope: PlanQuotaScope | null;
  billingType: BillingType;
  billingCycle: BillingCycle | null;
  /**
   * ADR-0031: how many months one billing period spans. `null` means 1 --
   * the behaviour every plan had before this ADR. Non-null exactly for the
   * `CALENDAR_PERIOD`/`ROLLING_PERIOD` cycles (the database enforces the
   * biconditional). Immutable once the plan has non-VOID payments.
   */
  billingPeriodMonths: number | null;
  /**
   * ADR-0031: the month (1-12) a long calendar cycle starts on -- 1 with a
   * quarterly period means Jan-Mar, Apr-Jun, Jul-Sep, Oct-Dec, the same for
   * every customer of the plan. `null` means the cycle starts on the month
   * of the purchase, and then there is never anything to prorate. Only for
   * `CALENDAR_PERIOD`.
   */
  billingAnchorMonth: number | null;
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

/**
 * ADR-0031: what `quote_service_plan_period(planId, from)` answers -- the
 * full period a payment made on `from` buys, and the amount the counter is
 * *suggested* to charge for it.
 *
 * It is a quote, never a charge: `Payment.amount` stays free (ADR-0024
 * resolution 5) and nothing in the database applies the proration on its
 * own. The period is never trimmed to the sign-up date; what gets prorated
 * is the price, by whole months, counting the sign-up month as complete,
 * and only when entering a long *calendar* cycle mid-way (a rolling cycle
 * starts on the day of the purchase, so it has nothing to prorate).
 */
export interface ServicePlanQuote {
  /** Full period, never trimmed to the sign-up date. */
  periodStart: string;
  periodEnd: string;
  /** `ServicePlan.price`, as listed. */
  fullPrice: number;
  /** Suggested amount: never above `fullPrice`, never below 0. */
  proratedPrice: number;
  /** True when `proratedPrice` differs from `fullPrice`. */
  prorated: boolean;
  /** Months charged / months in the whole period ("1 de 3"). */
  unitsCharged: number;
  unitsTotal: number;
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
  /**
   * Derived from the plan and verified by trigger, not a second source of
   * truth. ADR-0029: null when the plan covers more than one service --
   * see PaymentServiceCoverage for the full coverage of that payment.
   */
  serviceId: string | null;
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
  /** ADR-0025: set when the booking was covered by a MakeupCredit, which book_slot()/admin_book_for_customer() then consumed atomically. */
  makeupCreditId?: string | null;
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

// ---------------------------------------------------------------
// Phase 30: audit log (ADR-0032)
// ---------------------------------------------------------------

/**
 * The eight sensitive facts the platform records. Deliberately closed:
 * attendance, make-up credits (which are their own log in
 * `makeup_credits`), customer-side actions, logins and reads are out of
 * scope -- adding one is a migration plus a value here, never a free text.
 */
export type AuditAction =
  | "PAYMENT_CREATED"
  /** Includes voiding (VOID). `metadata.status` carries from/to. */
  | "PAYMENT_STATUS_CHANGED"
  /** Booked by the counter on a customer's behalf, never by the customer themself. */
  | "BOOKING_CREATED_BY_STAFF"
  | "BOOKING_CANCELLED_BY_STAFF"
  | "SERVICE_PLAN_CREATED"
  /** Price, name or ordering. `metadata` carries only what changed. */
  | "SERVICE_PLAN_UPDATED"
  /** And its inverse: `metadata.is_active` carries from/to. */
  | "SERVICE_PLAN_DEACTIVATED"
  | "ORGANIZATION_SUBSCRIPTION_CHANGED";

/**
 * One row of `organization_audit_log()` -- the read the OWNER's screen
 * consumes. Not the raw table: the actor of a platform-side action is
 * masked here (ADR-0032 resolution 2), so `actorId`/`actorName` are null
 * and `actorIsPlatform` is true for those rows.
 *
 * `metadata` is the minimal diff the trigger wrote (never the whole row,
 * never personal data), so it is intentionally untyped per action.
 */
export interface AuditLogEntry {
  id: string;
  action: AuditAction;
  /** Which table the fact is about. No FK: the log outlives what it audits. */
  targetTable: string;
  targetId: string;
  /** Null for a system action (job/cron) and for a platform actor seen by the OWNER. */
  actorId: string | null;
  actorName: string | null;
  /** True when the actor is not a member of this organization (i.e. the platform). */
  actorIsPlatform: boolean;
  metadata: Record<string, unknown>;
  createdAt: string;
}
