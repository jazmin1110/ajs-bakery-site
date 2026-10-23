-- 023: put the 4 draft flavors on the menu (Oct 24, 2026). Data only, no schema change.
--   Specials (P135, +P30 in a box): Nutella, Biscoff, Peanut Butter Reese's
--   Classic  (P110, no surcharge):  Banana Bread
-- The owner asked for them to be orderable now and will write the real content later.
-- The old short_description was an internal R&D note ("RD1 draft, not on the menu"), so it is
-- replaced with a customer-facing placeholder. Ingredients, allergens and nutrition stay EMPTY
-- (never invented); the detail sheet simply leaves those parts out until they're filled in.
-- Peanut Butter Reese's says "Contains peanuts" in its description so the allergen is never hidden.
-- Recipes, dough and bake logs point at flavors.id, so changing the slug is safe.
-- Run after 022.

begin;

update public.flavors set name = 'Nutella', slug = 'nutella', active = true,
  short_description = 'New flavor! Full ingredient and allergen details coming soon.'
  where slug = 'draft-nutella';

update public.flavors set name = 'Biscoff', slug = 'biscoff', active = true,
  short_description = 'New flavor! Full ingredient and allergen details coming soon.'
  where slug = 'draft-biscoff';

update public.flavors set name = 'Peanut Butter Reese''s', slug = 'pb-reeses', active = true,
  short_description = 'New flavor! Contains peanuts. Full ingredient and allergen details coming soon.'
  where slug = 'draft-pb-reeses';

update public.flavors set name = 'Banana Bread', slug = 'banana-bread', active = true,
  short_description = 'New flavor! Full ingredient and allergen details coming soon.'
  where slug = 'draft-banana-bread';

commit;
