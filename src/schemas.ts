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

const weeklyQuotaPlanSchema = z.object({
  planKind: z.literal("WEEKLY_QUOTA"),
  // No upper bound on purpose: a service can have two rules on the same
  // weekday, so "<= 7" would be wrong.
  weeklyQuota: z.coerce.number().int().positive("La frecuencia debe ser al menos 1"),
  billingType: z.literal("MONTHLY").default("MONTHLY"),
  billingCycle: z.enum(["CALENDAR_MONTH", "ROLLING_MONTH"]).default("CALENDAR_MONTH"),
});

const unlimitedPlanSchema = z.object({
  planKind: z.literal("UNLIMITED"),
  billingType: z.literal("MONTHLY").default("MONTHLY"),
  billingCycle: z.enum(["CALENDAR_MONTH", "ROLLING_MONTH"]).default("CALENDAR_MONTH"),
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
