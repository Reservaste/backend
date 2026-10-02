-- Phase 52: Organization.industry -- rubro declarado, puramente
-- informativo (ADR-0049)
--
-- El dueño del SaaS quiere poder identificar el rubro de cada
-- Organization (gimnasio, barbería, consultorio, cancha, etc.) para su
-- propio entendimiento de negocio, analytics y filtrado -- nunca para
-- que el sistema se comporte distinto.
--
-- Texto libre, sin CHECK que lo restrinja a una lista cerrada, a
-- propósito: un enum fijo (GYM | BARBERSHOP | CLINIC | ...) reintroduce
-- exactamente la taxonomía de rubros que el proyecto evita (regla
-- no-negociable de CLAUDE.md: nunca Gym/Member/Trainer/Class como modelo
-- central), y empuja a que alguien, en el futuro, haga
-- `if industry === 'GYM'`. Un campo descriptivo que nadie lee para
-- decidir comportamiento no viola esa regla, igual que
-- organizations.name no la viola.
--
-- Sin RPC nueva: un select/update directo contra la columna alcanza,
-- mismo criterio que otros campos simples de Organization (name,
-- timezone). La policy organizations_update_owner (Fase 1, ADR-0013) ya
-- es `for update using (is_organization_owner(id))` a nivel de fila, sin
-- restricción de columnas salvo las que un trigger dedicado cierra
-- explícitamente (Fase 34: columnas de estado de suscripción). industry
-- no es una de esas columnas, así que el OWNER ya puede escribirla sin
-- tocar la policy ni agregar un trigger nuevo.

alter table public.organizations
  add column if not exists industry text;

comment on column public.organizations.industry is
  'ADR-0049: puramente descriptivo, texto libre sin CHECK a propósito (ver ADR-0049 para el porqué -- un enum fijo reintroduce la taxonomía de rubros que CLAUDE.md prohíbe). Ninguna función, policy, ni componente del frontend puede leer esta columna para cambiar comportamiento -- sólo se lee para mostrarla (panel de admin, analytics interno del dueño del SaaS). Un rubro nuevo nunca requiere migración.';

notify pgrst, 'reload schema';
