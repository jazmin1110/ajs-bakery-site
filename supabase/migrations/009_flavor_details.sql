-- ============================================================================
-- 009_flavor_details.sql: the flavor "detail sheet" content, stored with each flavor.
--
-- The website's detail sheet (tap a flavor card) reads everything from these
-- columns, so the content can be edited in Supabase (Table Editor > flavors, or
-- an UPDATE statement) without touching code, and the sheet can become its own
-- page later. Run after 008.
--
-- NOTHING below is invented. Only things that already exist in the project are
-- filled in (the photo path and the short description you wrote). Ingredients,
-- allergens, weight, shelf life, storage tip and the nutrition label image are
-- left EMPTY (null): the website shows "coming soon" for any empty field until you
-- fill it in. See the template at the bottom of supabase/seed.sql.
-- ============================================================================

alter table public.flavors
  add column long_description     text,
  add column ingredients          text,                                   -- e.g. "Butter, flour, ..." (you write this)
  add column allergens            text,                                   -- e.g. "Contains wheat, milk, eggs" (you write this)
  add column weight_g             int check (weight_g > 0),               -- grams per cookie
  add column shelf_life           text,                                   -- e.g. "3 days at room temperature"
  add column storage_tip          text,
  add column nutrition_image_url  text,                                   -- path or URL of the nutrition label picture
  add column photo_url            text;                                   -- path or URL of the flavor photo

-- Starting values from what the site already uses: the photo files and your short descriptions.
update public.flavors set
  photo_url = 'assets/flavors/chimp-chips.jpg',
  long_description = 'Classic nutty brown butter chocolate chip cookie.'
where slug = 'choc-chip' and photo_url is null;

update public.flavors set
  photo_url = 'assets/flavors/coco-loco.jpg',
  long_description = 'Double chocolate brown butter chocolate chip cookie.'
where slug = 'double-choc' and photo_url is null;

update public.flavors set
  photo_url = 'assets/flavors/bueno-mucho.jpg',
  long_description = 'Nutty brown butter with Kinder Maxi chocolate and a bueno center.'
where slug = 'kinder-bueno' and photo_url is null;

-- No new permissions needed: visitors can already READ the flavors table (active rows only),
-- and still cannot change it. Only you (SQL editor / dashboard) can edit these fields.
