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
