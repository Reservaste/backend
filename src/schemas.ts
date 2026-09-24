// Zod input schemas for Phase 1 operations. Shared between the frontend
// server actions and (where useful) client-side form validation.
// Ref: docs/api.md, docs/decisions.md ADR-0002 (Zod at the transport edge).

import { z } from "zod";

const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export const organizationSlugSchema = z
  .string()
  .min(2, "El slug debe tener al menos 2 caracteres")
  .max(60, "El slug no puede tener más de 60 caracteres")
  .regex(slugPattern, "Solo minúsculas, números y guiones (ej: iron-gym)");

export const timezoneSchema = z
  .string()
  .min(1, "La zona horaria es obligatoria")
  .refine((tz) => {
    try {
      // Throws RangeError for an invalid IANA zone name.
      Intl.DateTimeFormat(undefined, { timeZone: tz });
      return true;
    } catch {
      return false;
    }
  }, "Zona horaria IANA inválida (ej: America/Montevideo)");

export const createOrganizationSchema = z.object({
  slug: organizationSlugSchema,
  name: z.string().min(2, "El nombre debe tener al menos 2 caracteres").max(120),
  timezone: timezoneSchema.default("America/Montevideo"),
});

export type CreateOrganizationInput = z.infer<typeof createOrganizationSchema>;

export const signUpSchema = z.object({
  email: z.string().email("Email inválido"),
  password: z.string().min(8, "La contraseña debe tener al menos 8 caracteres"),
  fullName: z.string().min(1, "El nombre es obligatorio").max(120),
});

export type SignUpInput = z.infer<typeof signUpSchema>;

export const signInSchema = z.object({
  email: z.string().email("Email inválido"),
  password: z.string().min(1, "La contraseña es obligatoria"),
});

export type SignInInput = z.infer<typeof signInSchema>;

export const createServiceSchema = z.object({
  name: z.string().min(2, "El nombre debe tener al menos 2 caracteres").max(120),
  description: z.string().max(2000).optional(),
});

export type CreateServiceInput = z.infer<typeof createServiceSchema>;

export const createResourceSchema = z.object({
  name: z.string().min(2, "El nombre debe tener al menos 2 caracteres").max(120),
  description: z.string().max(2000).optional(),
});

export type CreateResourceInput = z.infer<typeof createResourceSchema>;

const timeEntitlementSchema = z.object({
  entitlementType: z.literal("TIME"),
  validFrom: z.string().date(),
  validUntil: z.string().date().optional(),
});

const creditsEntitlementSchema = z.object({
  entitlementType: z.literal("CREDITS"),
  creditsTotal: z.coerce.number().int().positive("Los créditos deben ser un número positivo"),
});

export const createServiceEntitlementSchema = z
  .object({
    customerId: z.string().uuid(),
    serviceId: z.string().uuid(),
    requiresActivePayment: z.coerce.boolean().default(true),
  })
  .and(z.discriminatedUnion("entitlementType", [timeEntitlementSchema, creditsEntitlementSchema]));

export type CreateServiceEntitlementInput = z.infer<typeof createServiceEntitlementSchema>;

// ADR-0024: the shape of the plan form, not a second implementation of
// the rule. Whether a payment covers a slot is decided only in
// PostgreSQL (payment_covers_slot / evaluate_customer_booking); this
// only keeps a malformed plan from reaching the table -- and the CHECKs
// there are the real defence, since service_plans is writable through
// PostgREST.
const dropInPlanSchema = z.object({
  planKind: z.literal("DROP_IN"),
  billingType: z.literal("ONE_TIME").default("ONE_TIME"),
});

// ADR-0031: the two long cycles join the two monthly ones. They are
// generalizations, not replacements -- a plan that does not name a cycle
// still gets CALENDAR_MONTH, which is what every existing plan is.
const billingCycleSchema = z
  .enum(["CALENDAR_MONTH", "ROLLING_MONTH", "CALENDAR_PERIOD", "ROLLING_PERIOD"])
  .default("CALENDAR_MONTH");

const weeklyQuotaPlanSchema = z.object({
  planKind: z.literal("WEEKLY_QUOTA"),
  // No upper bound on purpose: a service can have two rules on the same
  // weekday, so "<= 7" would be wrong.
  weeklyQuota: z.coerce.number().int().positive("La frecuencia debe ser al menos 1"),
  billingType: z.literal("MONTHLY").default("MONTHLY"),
  billingCycle: billingCycleSchema,
});

const unlimitedPlanSchema = z.object({
  planKind: z.literal("UNLIMITED"),
  billingType: z.literal("MONTHLY").default("MONTHLY"),
  billingCycle: billingCycleSchema,
});

// ADR-0029: a plan covers one, several, or all of the organization's
// services -- appliesToAllServices and serviceIds are mutually exclusive
// (the database is the real defence, via validate_service_plan_scope()).
// Left loose here rather than encoded as a second discriminated union on
// top of planKind's, for the same reason the rest of this schema reads
// back from FormData instead of narrowing an intersection-of-unions: the
// server action builds the exact RPC call explicitly.
export const createServicePlanSchema = z
  .object({
    appliesToAllServices: z.coerce.boolean().default(false),
    serviceIds: z.array(z.string().uuid()).default([]),
    name: z.string().min(2, "El nombre debe tener al menos 2 caracteres").max(120),
    description: z.string().max(2000).optional(),
    price: z.coerce.number().min(0, "El precio no puede ser negativo"),
    sortOrder: z.coerce.number().int().default(0),
    // Required only when the plan covers more than one service and is
    // WEEKLY_QUOTA (ADR-0029 §3) -- the database enforces "non-null iff
    // WEEKLY_QUOTA"; this only adds the finer "iff more than one service"
    // half so the form can require it exactly when it is shown.
    quotaScope: z.enum(["PER_SERVICE", "SHARED_ACROSS_SERVICES"]).optional(),
    // ADR-0031. Read only for the two long cycles; the server action drops
    // them otherwise. The real defence is in the database (the biconditional
    // with billing_cycle, the 1..12 range and "divides 12" for a calendar
    // cycle), same as everything else in this schema -- here it only keeps a
    // typo from reaching the table and produces a readable message.
    billingPeriodMonths: z.coerce
      .number()
      .int()
      .min(1, "El ciclo tiene que ser de al menos 1 mes")
      .max(12, "El ciclo no puede pasar de 12 meses")
      .optional(),
    billingAnchorMonth: z.coerce
      .number()
      .int()
      .min(1, "Mes de inicio inválido")
      .max(12, "Mes de inicio inválido")
      .optional(),
  })
  .and(
    z.discriminatedUnion("planKind", [
      dropInPlanSchema,
      weeklyQuotaPlanSchema,
      unlimitedPlanSchema,
    ]),
  );

export type CreateServicePlanInput = z.infer<typeof createServicePlanSchema>;

/**
 * Editing a plan. plan_kind and weekly_quota are deliberately absent:
 * they are immutable once the plan has non-VOID payments (ADR-0024,
 * resolution 5), enforced by trigger. Correcting them = deactivate the
 * plan and create another, which cuts nobody's coverage.
 */
export const updateServicePlanSchema = z.object({
  name: z.string().min(2).max(120).optional(),
  description: z.string().max(2000).nullable().optional(),
  price: z.coerce.number().min(0, "El precio no puede ser negativo").optional(),
  sortOrder: z.coerce.number().int().optional(),
  isActive: z.coerce.boolean().optional(),
});

export type UpdateServicePlanInput = z.infer<typeof updateServicePlanSchema>;

/** ISO 4217, as stored in organizations.currency (ADR-0024). */
export const currencySchema = z
  .string()
  .regex(/^[A-Z]{3}$/, "Código de moneda ISO 4217 inválido (ej: UYU)");

export const createScheduleRuleSchema = z.object({
  serviceId: z.string().uuid(),
  resourceId: z.string().uuid(),
  weekday: z.coerce.number().int().min(0).max(6),
  localStartTime: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/, "Formato de hora inválido (HH:MM)"),
  durationMinutes: z.coerce.number().int().positive(),
  capacity: z.coerce.number().int().positive(),
  validFrom: z.string().date().optional(),
  validUntil: z.string().date().optional(),
});

export type CreateScheduleRuleInput = z.infer<typeof createScheduleRuleSchema>;

export const createScheduleExceptionSchema = z
  .object({
    scheduleRuleId: z.string().uuid(),
    exceptionDate: z.string().date(),
  })
  .and(
    z.discriminatedUnion("exceptionType", [
      z.object({ exceptionType: z.literal("CANCELLED") }),
      z.object({
        exceptionType: z.literal("MODIFIED"),
        modifiedLocalStartTime: z
          .string()
          .regex(/^([01]\d|2[0-3]):[0-5]\d$/, "Formato de hora inválido (HH:MM)")
          .optional(),
        modifiedDurationMinutes: z.coerce.number().int().positive().optional(),
        modifiedCapacity: z.coerce.number().int().positive().optional(),
      }),
    ]),
  );

export type CreateScheduleExceptionInput = z.infer<typeof createScheduleExceptionSchema>;

// ADR-0030 resolution 2: the /contacto landing form. Edge validation only
// -- the real defence is submit_platform_contact_request() in
// backend/supabase/migrations, which re-validates format/length and is
// the only thing PostgREST actually lets anon/authenticated call (RLS on
// platform_contact_requests has zero policies, so a direct insert is
// rejected regardless of what this schema allows). Bounds mirror the SQL
// CHECK constraints exactly so a rejection here and a rejection there
// mean the same thing.
export const submitContactRequestSchema = z.object({
  name: z.string().trim().min(1, "Contanos tu nombre").max(200),
  email: z.string().trim().max(320).email("Email inválido"),
  message: z.string().trim().min(1, "Contanos brevemente qué necesitás").max(4000),
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9 ()-]{6,20}$/, "Formato de teléfono inválido")
    .optional()
    .or(z.literal("")),
  businessType: z.string().trim().max(120).optional().or(z.literal("")),
});

export type SubmitContactRequestInput = z.infer<typeof submitContactRequestSchema>;

// ============================================================
// ADR-0033 -- roles configurables por organización
// ============================================================
// Los límites espejan los CHECK de organization_roles en la Fase 32, para
// que un rechazo acá y uno en la base signifiquen lo mismo. La regla
// "MANAGE_PAYMENTS implica VIEW_PAYMENTS" está en los tres lugares donde
// puede aplicarse (schema, RPC y CHECK de tabla) a propósito: la base es la
// que manda, esto es lo que hace que el formulario lo explique en vez de
// devolver un error de constraint.

export const organizationRoleNameSchema = z
  .string()
  .trim()
  .min(1, "El nombre del rol es obligatorio")
  .max(60, "El nombre del rol no puede tener más de 60 caracteres");

export const organizationRolePermissionsSchema = z
  .object({
    canViewPayments: z.boolean(),
    canManagePayments: z.boolean(),
    canManageBookings: z.boolean(),
    canManageCustomers: z.boolean(),
    canManageAttendance: z.boolean(),
  })
  .refine((p) => !p.canManagePayments || p.canViewPayments, {
    message: "Un rol que registra pagos tiene que poder verlos",
    path: ["canViewPayments"],
  });

export const createOrganizationRoleSchema = z
  .object({
    name: organizationRoleNameSchema,
    canViewPayments: z.boolean().default(true),
    canManagePayments: z.boolean().default(true),
    canManageBookings: z.boolean().default(true),
    canManageCustomers: z.boolean().default(true),
    canManageAttendance: z.boolean().default(true),
  })
  .refine((p) => !p.canManagePayments || p.canViewPayments, {
    message: "Un rol que registra pagos tiene que poder verlos",
    path: ["canViewPayments"],
  });

export type CreateOrganizationRoleInput = z.infer<typeof createOrganizationRoleSchema>;

export const updateOrganizationRoleSchema = z
  .object({
    roleId: z.string().uuid(),
    name: organizationRoleNameSchema.optional(),
    canViewPayments: z.boolean().optional(),
    canManagePayments: z.boolean().optional(),
    canManageBookings: z.boolean().optional(),
    canManageCustomers: z.boolean().optional(),
    canManageAttendance: z.boolean().optional(),
    isActive: z.boolean().optional(),
  })
  .refine((p) => !(p.canManagePayments === true && p.canViewPayments === false), {
    message: "Un rol que registra pagos tiene que poder verlos",
    path: ["canViewPayments"],
  });

export type UpdateOrganizationRoleInput = z.infer<typeof updateOrganizationRoleSchema>;

export const setMemberRoleSchema = z.object({
  memberId: z.string().uuid(),
  /** Null = vuelve al rol por defecto de la organización. */
  roleId: z.string().uuid().nullable(),
});

export type SetMemberRoleInput = z.infer<typeof setMemberRoleSchema>;

// ============================================================
// ADR-0034 -- invitaciones de equipo (alta sin registro previo)
// ============================================================
// Los límites espejan los CHECK de team_invitations en la Fase 33. El email
// se normaliza acá igual que en la RPC (lower + trim) para que el borde y la
// base no puedan discrepar sobre qué invitación es "la misma": la unicidad de
// "un link vivo" es por (organización, email) normalizado.
//
// El teléfono es opcional a propósito: sirve para armar el link de WhatsApp,
// pero el vínculo que el canje exige es el email. Una invitación sin teléfono
// es válida -- el link se copia y se pega.

export const teamInvitationEmailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .max(320)
  .email("Email inválido");

/**
 * E.164 con `+` obligatorio, el mismo formato que el CHECK
 * `team_invitations_phone_e164`. La RPC normaliza (saca espacios, paréntesis y
 * guiones, y agrega el `+` si falta) antes de validar, así que un formulario
 * puede ser más permisivo que esto; este schema es el contrato del server
 * action, no el del campo de texto.
 */
export const teamInvitationPhoneSchema = z
  .string()
  .trim()
  .regex(/^\+?[0-9 ()-]{6,20}$/, "Formato de teléfono inválido");

export const inviteTeamMemberSchema = z.object({
  organizationId: z.string().uuid(),
  email: teamInvitationEmailSchema,
  /** El nombre con el que el dueño da de alta a la persona. */
  displayName: z.string().trim().min(1, "El nombre es obligatorio").max(120).optional(),
  phone: teamInvitationPhoneSchema.optional(),
  /** Null/ausente = el rol por defecto de la organización. */
  roleId: z.string().uuid().nullable().optional(),
});

export type InviteTeamMemberInput = z.infer<typeof inviteTeamMemberSchema>;

export const revokeTeamInvitationSchema = z.object({
  invitationId: z.string().uuid(),
});

export type RevokeTeamInvitationInput = z.infer<typeof revokeTeamInvitationSchema>;

/**
 * El token es 32 bytes en base64url sin padding: 43 caracteres de
 * `[A-Za-z0-9_-]`. Validar la forma en el borde evita ir a la base por algo
 * que no puede ser un token nuestro -- pero el veredicto real (existe, no
 * vencido, no canjeado) sólo lo da `claim_team_invitation()`.
 */
export const claimTeamInvitationSchema = z.object({
  token: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9_-]{43}$/, "Link de invitación inválido"),
});

export type ClaimTeamInvitationInput = z.infer<typeof claimTeamInvitationSchema>;
