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
