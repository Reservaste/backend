-- Phase 51: services_public expone si el servicio tiene algun recurso
-- dinamico (ADR-0051, frontend)
--
-- El frontend publico necesita saber, por servicio, si corresponde
-- mandar al cliente al flujo nuevo de disponibilidad dinamica
-- (elegir dia -> ver horarios calculados -> hold -> confirmar) en vez
-- del calendario de grilla de siempre -- un servicio servido unicamente
-- por un Resource con dynamic_availability=true nunca tiene
-- SlotOccurrence pre-generadas, asi que get_public_availability() nunca
-- le va a mostrar nada.
--
-- hasDynamicResource no revela identidad de ningun recurso (ni su
-- nombre, ni su id, ni cuantos hay) -- solo si existe al menos uno, lo
-- mismo que ya decide internamente create_schedule_rules_batch()/
-- get_dynamic_availability() -- no es un dato nuevo que antes estuviera
-- oculto, solo una forma barata de que el frontend sepa a que flujo
-- mandar al cliente sin tener que llamar get_dynamic_availability() para
-- cada servicio de la organizacion solo para ver si vuelve vacio.
--
-- ADR-0036: vista de solo lectura, mismo patron que organizations_public/
-- services_public (phase4, revoke insert/update/delete/truncate en
-- phase36) -- drop+create porque cambia el shape de columnas.

drop view if exists public.services_public;

create view public.services_public as
select
  s.id,
  s.organization_id,
  s.name,
  s.description,
  exists (
    select 1
    from public.service_resources sr
    join public.resources r on r.id = sr.resource_id
    -- r.is_active (fix del gate de seguridad, hallazgo B1): sin este
    -- filtro, un Resource dinamico dado de baja seguia contando como
    -- "este servicio tiene disponibilidad dinamica" -- el frontend lo
    -- mandaba al flujo nuevo, que siempre mostraba "sin horarios" en vez
    -- de caer al calendario de grilla de siempre. get_dynamic_availability()
    -- ya filtra res.is_active (Fase 50b) -- esta vista tiene que estar de
    -- acuerdo con ese mismo criterio.
    where sr.service_id = s.id and r.dynamic_availability and r.is_active
  ) as has_dynamic_resource
from public.services s
where s.is_active;

revoke insert, update, delete, truncate on public.services_public from anon, authenticated;
grant select on public.services_public to anon, authenticated;

comment on view public.services_public is
  'ADR-0008: vista pública del calendario, deliberadamente SIN security_invoker para saltear la RLS de miembro en LECTURA. ADR-0037: la escritura está revocada para anon/authenticated -- un DELETE anonimo borraba en cascada Bookings CONFIRMED y pagos PAID. No poner security_invoker: rompe la lectura anonima. has_dynamic_resource (ADR-0051, Fase 51): true si el servicio tiene al menos un Resource activo con dynamic_availability=true -- no revela identidad de ningun recurso, solo si corresponde mandar al cliente al flujo de disponibilidad dinamica en vez del calendario de grilla.';

notify pgrst, 'reload schema';
