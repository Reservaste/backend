// Converts snake_case rows returned by supabase-js into the camelCase
// domain types in ./types.ts. Keeping this in the shared package means the
// frontend never hand-rolls this mapping per query.

import type {
  Customer,
  Organization,
  OrganizationMember,
  Profile,
  Resource,
  Service,
  ServiceEntitlement,
} from "./types";

export interface OrganizationRow {
  id: string;
  slug: string;
  name: string;
  timezone: string;
  public_availability_display: string;
  low_availability_percentage: number;
  low_availability_fixed_cap: number | null;
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
