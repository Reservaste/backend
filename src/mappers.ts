// Converts snake_case rows returned by supabase-js into the camelCase
// domain types in ./types.ts. Keeping this in the shared package means the
// frontend never hand-rolls this mapping per query.

import type {
  Booking,
  Customer,
  Organization,
  OrganizationMember,
  Payment,
  Profile,
  PublicAvailabilitySlot,
  PublicOrganization,
  PublicService,
  RecurringBooking,
  Resource,
  ScheduleException,
  ScheduleRule,
  Service,
  ServiceEntitlement,
  SlotOccurrence,
} from "./types";

export interface OrganizationRow {
  id: string;
  slug: string;
  name: string;
  timezone: string;
  public_availability_display: string;
  low_availability_percentage: number;
  low_availability_fixed_cap: number | null;
  brand_color?: string | null;
  logo_path?: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
}

export function mapOrganization(row: OrganizationRow): Organization {
  return {
    id: row.id,
    slug: row.slug,
    name: row.name,
    timezone: row.timezone,
    publicAvailabilityDisplay: row.public_availability_display as Organization["publicAvailabilityDisplay"],
    lowAvailabilityPercentage: row.low_availability_percentage,
    lowAvailabilityFixedCap: row.low_availability_fixed_cap,
    brandColor: row.brand_color ?? null,
    logoPath: row.logo_path ?? null,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
  };
}

export interface OrganizationMemberRow {
  id: string;
  organization_id: string;
  profile_id: string;
  role: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapOrganizationMember(row: OrganizationMemberRow): OrganizationMember {
  return {
    id: row.id,
    organizationId: row.organization_id,
    profileId: row.profile_id,
    role: row.role as OrganizationMember["role"],
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as OrganizationMember["cancellationReason"],
  };
}

export interface ProfileRow {
  id: string;
  full_name: string | null;
  avatar_url: string | null;
  created_at: string;
  updated_at: string;
}

export function mapProfile(row: ProfileRow): Profile {
  return {
    id: row.id,
    fullName: row.full_name,
    avatarUrl: row.avatar_url,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export interface CustomerRow {
  id: string;
  organization_id: string;
  profile_id: string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapCustomer(row: CustomerRow): Customer {
  return {
    id: row.id,
    organizationId: row.organization_id,
    profileId: row.profile_id,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as Customer["cancellationReason"],
  };
}

export interface ResourceRow {
  id: string;
  organization_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapResource(row: ResourceRow): Resource {
  return {
    id: row.id,
    organizationId: row.organization_id,
    name: row.name,
    description: row.description,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as Resource["cancellationReason"],
  };
}

export interface ServiceRow {
  id: string;
  organization_id: string;
  name: string;
  description: string | null;
  public_availability_display_override: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapService(row: ServiceRow): Service {
  return {
    id: row.id,
    organizationId: row.organization_id,
    name: row.name,
    description: row.description,
    publicAvailabilityDisplayOverride:
      row.public_availability_display_override as Service["publicAvailabilityDisplayOverride"],
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as Service["cancellationReason"],
  };
}

export interface ServiceEntitlementRow {
  id: string;
  organization_id: string;
  customer_id: string;
  service_id: string;
  entitlement_type: string;
  requires_active_payment: boolean;
  valid_from: string | null;
  valid_until: string | null;
  credits_total: number | null;
  credits_remaining: number | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapServiceEntitlement(row: ServiceEntitlementRow): ServiceEntitlement {
  return {
    id: row.id,
    organizationId: row.organization_id,
    customerId: row.customer_id,
    serviceId: row.service_id,
    entitlementType: row.entitlement_type as ServiceEntitlement["entitlementType"],
    requiresActivePayment: row.requires_active_payment,
    validFrom: row.valid_from,
    validUntil: row.valid_until,
    creditsTotal: row.credits_total,
    creditsRemaining: row.credits_remaining,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as ServiceEntitlement["cancellationReason"],
  };
}

export interface ScheduleRuleRow {
  id: string;
  organization_id: string;
  service_id: string;
  resource_id: string;
  weekday: number;
  local_start_time: string;
  duration_minutes: number;
  capacity: number;
  valid_from: string;
  valid_until: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapScheduleRule(row: ScheduleRuleRow): ScheduleRule {
  return {
    id: row.id,
    organizationId: row.organization_id,
    serviceId: row.service_id,
    resourceId: row.resource_id,
    weekday: row.weekday,
    localStartTime: row.local_start_time,
    durationMinutes: row.duration_minutes,
    capacity: row.capacity,
    validFrom: row.valid_from,
    validUntil: row.valid_until,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as ScheduleRule["cancellationReason"],
  };
}

export interface ScheduleExceptionRow {
  id: string;
  organization_id: string;
  schedule_rule_id: string;
  exception_date: string;
  exception_type: string;
  modified_local_start_time: string | null;
  modified_duration_minutes: number | null;
  modified_capacity: number | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
}

export function mapScheduleException(row: ScheduleExceptionRow): ScheduleException {
  return {
    id: row.id,
    organizationId: row.organization_id,
    scheduleRuleId: row.schedule_rule_id,
    exceptionDate: row.exception_date,
    exceptionType: row.exception_type as ScheduleException["exceptionType"],
    modifiedLocalStartTime: row.modified_local_start_time,
    modifiedDurationMinutes: row.modified_duration_minutes,
    modifiedCapacity: row.modified_capacity,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
  };
}

export interface SlotOccurrenceRow {
  id: string;
  organization_id: string;
  schedule_rule_id: string;
  service_id: string;
  resource_id: string;
  start_at: string;
  end_at: string;
  generated_timezone: string;
  capacity: number;
  status: string;
  schedule_exception_id: string | null;
  created_at: string;
  updated_at: string;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapSlotOccurrence(row: SlotOccurrenceRow): SlotOccurrence {
  return {
    id: row.id,
    organizationId: row.organization_id,
    scheduleRuleId: row.schedule_rule_id,
    serviceId: row.service_id,
    resourceId: row.resource_id,
    startAt: row.start_at,
    endAt: row.end_at,
    generatedTimezone: row.generated_timezone,
    capacity: row.capacity,
    status: row.status as SlotOccurrence["status"],
    scheduleExceptionId: row.schedule_exception_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as SlotOccurrence["cancellationReason"],
  };
}

export interface PublicOrganizationRow {
  id: string;
  slug: string;
  name: string;
  timezone: string;
  brand_color?: string | null;
  logo_path?: string | null;
}

export function mapPublicOrganization(row: PublicOrganizationRow): PublicOrganization {
  return {
    id: row.id,
    slug: row.slug,
    name: row.name,
    timezone: row.timezone,
    brandColor: row.brand_color ?? null,
    logoPath: row.logo_path ?? null,
  };
}

export interface PublicServiceRow {
  id: string;
  organization_id: string;
  name: string;
  description: string | null;
}

export function mapPublicService(row: PublicServiceRow): PublicService {
  return { id: row.id, organizationId: row.organization_id, name: row.name, description: row.description };
}

export interface PublicAvailabilityRow {
  slot_occurrence_id: string;
  service_id: string;
  start_at: string;
  end_at: string;
  mode: string;
  status: string | null;
  remaining: number | null;
  capacity: number | null;
}

export interface BookingRow {
  id: string;
  organization_id: string;
  customer_id: string;
  slot_occurrence_id: string;
  recurring_booking_id: string | null;
  service_entitlement_id: string | null;
  status: string;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapBooking(row: BookingRow): Booking {
  return {
    id: row.id,
    organizationId: row.organization_id,
    customerId: row.customer_id,
    slotOccurrenceId: row.slot_occurrence_id,
    recurringBookingId: row.recurring_booking_id,
    serviceEntitlementId: row.service_entitlement_id,
    status: row.status as Booking["status"],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as Booking["cancellationReason"],
  };
}

export interface PaymentRow {
  id: string;
  organization_id: string;
  customer_id: string;
  service_entitlement_id: string;
  period_start: string;
  period_end: string;
  status: string;
  amount: number | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
}

export function mapPayment(row: PaymentRow): Payment {
  return {
    id: row.id,
    organizationId: row.organization_id,
    customerId: row.customer_id,
    serviceEntitlementId: row.service_entitlement_id,
    periodStart: row.period_start,
    periodEnd: row.period_end,
    status: row.status as Payment["status"],
    amount: row.amount,
    notes: row.notes,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
  };
}

export interface RecurringBookingRow {
  id: string;
  organization_id: string;
  customer_id: string;
  schedule_rule_id: string;
  status: string;
  start_date: string;
  end_date: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancellation_reason: string | null;
}

export function mapRecurringBooking(row: RecurringBookingRow): RecurringBooking {
  return {
    id: row.id,
    organizationId: row.organization_id,
    customerId: row.customer_id,
    scheduleRuleId: row.schedule_rule_id,
    status: row.status as RecurringBooking["status"],
    startDate: row.start_date,
    endDate: row.end_date,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by,
    cancelledAt: row.cancelled_at,
    cancelledBy: row.cancelled_by,
    cancellationReason: row.cancellation_reason as RecurringBooking["cancellationReason"],
  };
}

export function mapPublicAvailabilitySlot(row: PublicAvailabilityRow): PublicAvailabilitySlot {
  return {
    slotOccurrenceId: row.slot_occurrence_id,
    serviceId: row.service_id,
    startAt: row.start_at,
    endAt: row.end_at,
    mode: row.mode as PublicAvailabilitySlot["mode"],
    status: row.status as PublicAvailabilitySlot["status"],
    remaining: row.remaining,
    capacity: row.capacity,
  };
}
