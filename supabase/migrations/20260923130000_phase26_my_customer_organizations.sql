-- Phase 26: my_customer_organizations() -- the negocios donde ya soy Customer.
-- Ref: docs/decisions.md ADR-0006, ADR-0023.
--
-- Feedback de producción, punto 3 pendiente de la Opción A ("no veo la
-- agenda para reservar"): /me tenía que listar los negocios donde la
-- persona ya es Customer, aun sin haber reservado nunca -- el caso típico
-- es alguien recién activado por WhatsApp (ADR-0026) o enrolado por email
-- (ADR-0021/managed_customers), sin ningún Booking ni Service activo
-- todavía. my_services() no alcanza para esto a propósito: hace
-- `join services ... where s.is_active`, así que un negocio sin servicios
-- publicados (o con todos pausados) desaparece de esa lista aunque el
-- vínculo Customer exista y sea válido.
--
-- No hay forma de resolver esto con una query directa desde el server
-- action: organizations_select_members (Phase 1) restringe el SELECT
-- directo de `organizations` a membership (uso admin) -- un Customer sin
-- membership no puede leer slug/name de la fila aunque su propia fila en
-- `customers` sí sea visible por customers_select_self_or_staff. Mismo
-- patrón que my_bookings()/my_services(): función SECURITY DEFINER que
-- resuelve auth.uid() adentro y expone sólo el shape público mínimo.

create or replace function public.my_customer_organizations()
returns table (
  organization_slug text,
  organization_name text
)
language sql
stable
security definer
set search_path = public
as $BODY$
  select o.slug, o.name
  from public.customers c
  join public.organizations o on o.id = c.organization_id
  where c.profile_id = auth.uid() and c.is_active
  order by o.name asc;
$BODY$;

comment on function public.my_customer_organizations() is
  'Los negocios donde el profile autenticado es Customer activo, sin exigir servicios activos publicados ni cobertura de pago vigente -- a diferencia de my_services(), cubre el caso de alguien recién enrolado que todavía no tiene nada que reservar mostrado.';

-- ADR-0028: EXECUTE es aditivo por default en Postgres -- se deja el mismo
-- par revoke/grant explícito que my_bookings()/my_services() para que esta
-- función nunca quede abierta a public/anon por descuido.
revoke execute on function public.my_customer_organizations() from public, anon;
grant execute on function public.my_customer_organizations() to authenticated;
