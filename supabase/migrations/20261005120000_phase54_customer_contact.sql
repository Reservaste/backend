-- ADR-0050: customer_contact() -- email y telefono de un cliente para la
-- ficha del panel admin, solo para el equipo (OWNER/STAFF activos).
--
-- La organizacion se deriva de customers.organization_id, nunca por
-- parametro. Cliente inexistente o de otra organizacion -> 0 filas (sin
-- oraculo cross-tenant). email viene de auth.users via customers.profile_id
-- (null para clientes gestionados); phone es customers.phone.

create or replace function public.customer_contact(p_customer_id uuid)
returns table (email text, phone text)
language sql
security definer
stable
set search_path = public
as $$
  select u.email::text, c.phone
  from public.customers c
  left join auth.users u on u.id = c.profile_id
  where c.id = p_customer_id
    and public.is_organization_member(c.organization_id);
$$;

revoke all on function public.customer_contact(uuid) from public, anon;
grant execute on function public.customer_contact(uuid) to authenticated;
