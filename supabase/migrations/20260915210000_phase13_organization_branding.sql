-- Phase 13: per-organization branding (accent colour + logo)
-- Ref: docs/decisions.md ADR-0020
--
-- A business puts its own booking page in front of its customers, so it
-- gets to look like itself. Two things and no more: one accent colour and
-- a logo. Everything else stays product-designed, because a tenant-wide
-- theme editor is how a product ends up with unreadable screens it
-- cannot support.

-- ============================================================
-- Columns
-- ============================================================

alter table public.organizations
  add column if not exists brand_color text,
  add column if not exists logo_path text;

comment on column public.organizations.brand_color is
  'Accent colour as #rrggbb, or null for the product default. Never replaces the semantic colours (success/warning/destructive). Ref: ADR-0020.';

comment on column public.organizations.logo_path is
  'Object path inside the organization-logos storage bucket, always scoped to this row''s id. The public URL is derived by the client; storing a whole URL would bake the project host into the data.';

-- Normalizing before validating, so an OWNER pasting "#FFAA00" gets their
-- colour saved instead of a constraint violation they cannot interpret.
create or replace function public.normalize_organization_branding()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.brand_color := nullif(lower(trim(new.brand_color)), '');
  new.logo_path := nullif(trim(new.logo_path), '');
  return new;
end;
$$;

create trigger organizations_normalize_branding
  before insert or update on public.organizations
  for each row
  execute function public.normalize_organization_branding();

-- The colour is interpolated into a CSS custom property. A free-form
-- string there is a style-injection vector ("red;} body{...}"), and the
-- UI is not the place to stop it: PostgREST accepts an update to this
-- column directly. Hence a CHECK, not a Zod schema.
alter table public.organizations
  add constraint organizations_brand_color_format
    check (brand_color is null or brand_color ~ '^#[0-9a-f]{6}$');

-- Scopes the logo to its own organization at the data layer, so a
-- crafted update cannot point one organization's page at another's
-- object (or at an arbitrary path inside the bucket).
alter table public.organizations
  add constraint organizations_logo_path_scoped
    check (logo_path is null or logo_path like id::text || '/%');

-- ============================================================
-- Public exposure
-- ============================================================
-- Branding is public by definition -- it renders for visitors who are not
-- logged in. Added to the existing narrow view rather than widening the
-- base table's RLS (the rule this view exists to keep, Phase 4).

create or replace view public.organizations_public as
select id, slug, name, timezone, brand_color, logo_path
from public.organizations
where is_active;

grant select on public.organizations_public to anon, authenticated;

-- ============================================================
-- Storage bucket
-- ============================================================
-- Limits live on the bucket, which is enforced by the storage service
-- itself -- a direct upload with a forged content-type never reaches a
-- code path we control.
--
-- SVG is deliberately absent. It can carry script, and while an <img> tag
-- will not execute it, the object URL is directly openable: allowing it
-- would put a stored-XSS surface on the storage host for the sake of a
-- file format nobody needs for a logo.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'organization-logos',
  'organization-logos',
  true,
  524288,
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Returns null instead of raising when the first path segment is not a
-- uuid: inside a policy an exception aborts the statement rather than
-- denying it, which turns a junk path into a confusing error instead of a
-- clean refusal.
create or replace function public.storage_object_organization(p_name text)
returns uuid
language sql
immutable
set search_path = public
as $$
  select case
    when (storage.foldername(p_name))[1] ~
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then ((storage.foldername(p_name))[1])::uuid
  end;
$$;

create policy "organization logos are public"
  on storage.objects for select
  using (bucket_id = 'organization-logos');

-- OWNER, not any member: the logo is the business's identity, the same
-- decision level as its name.
create policy "owners upload their organization logo"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'organization-logos'
    and public.is_organization_owner(public.storage_object_organization(name))
  );

create policy "owners replace their organization logo"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'organization-logos'
    and public.is_organization_owner(public.storage_object_organization(name))
  );

create policy "owners delete their organization logo"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'organization-logos'
    and public.is_organization_owner(public.storage_object_organization(name))
  );
