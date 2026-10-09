-- ============================================================================
-- 013_flavor_content.sql: the written content for each flavor's detail sheet, plus two
-- site-wide notes.
--
-- Why 013 and not 004: migrations 001-012 already exist.
-- Some of these columns already exist from migration 009 (long_description, ingredients,
-- shelf_life, storage_tip), so every column here uses "if not exists".
-- The older text column `allergens` (009) is no longer used by the site: allergens are now
-- the two lists `contains` and `may_contain`. It is left in place, empty.
--
-- Nutrition is a calculated estimate, stored as jsonb with EXACTLY these keys and no others:
--   serving, calories, total_carbohydrate_g, sugars_g, total_fat_g, protein_g
-- (no saturated fat, trans fat, fibre or sodium).
-- Run after 012. The words themselves come from supabase/seed_content.sql.
-- ============================================================================

alter table public.flavors
  add column if not exists short_description text,      -- the one-liner on the menu row
  add column if not exists long_description  text,      -- the paragraph on the detail sheet
  add column if not exists taste_notes       text[],    -- small chips: {"Nutty brown butter", ...}
  add column if not exists ingredients       text,
  add column if not exists contains          text[],    -- allergens in the recipe
  add column if not exists may_contain       text[],    -- possible cross-contact
  add column if not exists weight_label      text,      -- e.g. "About 60g"
  add column if not exists shelf_life        text,
  add column if not exists storage_tip       text,
  add column if not exists nutrition         jsonb;     -- see above

-- The nutrition object must have exactly the six keys, with a text serving line and numbers for the rest.
-- (A CHECK can't contain a subquery, so the rule lives in a small function.)
create function public.nutrition_is_valid(n jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select n is null or (
    jsonb_typeof(n) = 'object'
    and (select count(*) from jsonb_object_keys(n)) = 6
    and n ?& array['serving', 'calories', 'total_carbohydrate_g', 'sugars_g', 'total_fat_g', 'protein_g']
    and jsonb_typeof(n -> 'serving') = 'string'
    and jsonb_typeof(n -> 'calories') = 'number'
    and jsonb_typeof(n -> 'total_carbohydrate_g') = 'number'
    and jsonb_typeof(n -> 'sugars_g') = 'number'
    and jsonb_typeof(n -> 'total_fat_g') = 'number'
    and jsonb_typeof(n -> 'protein_g') = 'number'
  )
$$;
revoke all on function public.nutrition_is_valid(jsonb) from public, anon, authenticated;
alter table public.flavors add constraint flavors_nutrition_shape check (public.nutrition_is_valid(nutrition));

-- Site-wide notes (the allergen note and the nutrition note). One row per note.
-- Visitors can read them; only you (SQL editor / dashboard) can change them.
create table public.site_settings (
  key   text primary key,
  value text not null
);
alter table public.site_settings enable row level security;
revoke all on public.site_settings from public, anon, authenticated;
grant select on public.site_settings to anon, authenticated;
create policy "anyone reads site settings" on public.site_settings for select using (true);
