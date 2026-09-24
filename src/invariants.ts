// Pure domain rules for Phase 1. No I/O, no Supabase client -- these are
// the functions both the frontend server actions and any future backend
// code call so the rule is defined once. Ref: docs/domain.md, docs/security.md.

import type {
  Customer,
  OrganizationMember,
  OrganizationPermissions,
  OrgPermission,
  ServiceEntitlement,
} from "./types";

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

// ============================================================
// ADR-0033 -- permisos configurables dentro de STAFF
// ============================================================
// Esto NO es la autorización: la autorización vive en SQL
// (has_org_permission(), las policies y cada RPC security definer). Esto es
// lo que la UI usa para esconder/deshabilitar en vez de mostrar-todo-y-
// fallar-al-guardar. "Hiding the button is not enforcement".

/** El permiso que hace falta para cada acción del panel. Única tabla de verdad. */
export const ORG_PERMISSION_KEYS: Record<OrgPermission, keyof OrganizationPermissions> = {
  VIEW_PAYMENTS: "canViewPayments",
  MANAGE_PAYMENTS: "canManagePayments",
  MANAGE_BOOKINGS: "canManageBookings",
  MANAGE_CUSTOMERS: "canManageCustomers",
  MANAGE_ATTENDANCE: "canManageAttendance",
};

/**
 * Los permisos de un `OWNER`: todos, sin consultar ningún rol. Espeja el
 * `om.role = 'OWNER'` que corta antes en `has_org_permission()` -- la UI no
 * puede llegar a una conclusión distinta de la de la base.
 */
export const ALL_ORG_PERMISSIONS: OrganizationPermissions = {
  canViewPayments: true,
  canManagePayments: true,
  canManageBookings: true,
  canManageCustomers: true,
  canManageAttendance: true,
};

/** Ningún permiso. Lo que corresponde cuando no se pudo resolver la membresía. */
export const NO_ORG_PERMISSIONS: OrganizationPermissions = {
  canViewPayments: false,
  canManagePayments: false,
  canManageBookings: false,
  canManageCustomers: false,
  canManageAttendance: false,
};

/**
 * Si un rol puede algo. Se lee siempre así y nunca con un booleano suelto,
 * para que la UI hable el mismo idioma que el enum `org_permission` de la
 * base y un permiso nuevo sea un error de tipos y no un `undefined`.
 */
export function hasOrgPermission(
  permissions: OrganizationPermissions,
  permission: OrgPermission,
): boolean {
  return permissions[ORG_PERMISSION_KEYS[permission]];
}
