-- 019: Oct 22, 2026 price list + recipes (data only, no schema change).
-- Source of truth: ../context/ingredient-prices.md and ../context/recipes-current.md.
-- Prices are set directly (not through admin_receive_stock) on purpose: these are shelf/receipt
-- prices, not new purchases, so no stock is added.
-- Draft flavors are added as INACTIVE flavors: they never show on the storefront or in orders.

begin;

-- 1. Fix the stale / guessed prices -------------------------------------------------------
update public.ingredients set pack_label = 'Member''s Value 2kg', pack_size = 2000, pack_price = 159,
  price_confirmed = true, supplier = 'S&R Shaw', notes = 'Price as of Oct 20, 2026.' where name = 'Dark brown sugar';
update public.ingredients set pack_label = 'Member''s Value 2kg', pack_size = 2000, pack_price = 172,
  price_confirmed = true, supplier = 'S&R Shaw', notes = 'Refined white sugar. Price as of Oct 20, 2026.' where name = 'Granulated sugar';
update public.ingredients set pack_price = 280, price_confirmed = true,
  notes = 'Price as of Oct 20, 2026. A recipe with 1 whole egg + 1 extra yolk uses 2 eggs.' where name = 'Eggs';
update public.ingredients set pack_label = 'Master Chef 500g', pack_size = 500, pack_price = 35,
  price_confirmed = true, supplier = 'S&R Shaw', notes = 'Price as of Oct 20, 2026.' where name = 'Baking soda';
update public.ingredients set pack_label = 'box of 16 bars (344g)', pack_size = 16, pack_price = 499,
  price_confirmed = true, supplier = 'S&R Shaw',
  notes = '1 pc = 1 whole 21.5g bar. Bueno Mucho uses half a bar per cookie (7.5 bars a batch). Price as of Oct 20, 2026.'
  where name = 'Kinder Bueno';
update public.ingredients set notes = 'Oct 3 price. RE-CHECK next time you buy (it is about 45% of a Bueno Mucho batch).'
  where name = 'Kinder Max (milk chocolate)';
update public.ingredients set pack_label = 'Ellie unbleached 1kg' where name = 'All-purpose flour';
update public.ingredients set notes = 'Still a guess: about P12 a batch (1.5 tsp). Enter the bottle size and price when you have it.'
  where name = 'Vanilla extract';
update public.ingredients set pack_price = 0.05,
  notes = 'Still a guess: about P0.20 a batch. Enter the real pack price when you have it.' where name = 'Fine sea salt';

-- 2. Add the missing ingredients (all S&R Shaw, Oct 20, 2026) -----------------------------
insert into public.ingredients (name, category, unit, pack_label, pack_size, pack_price, price_confirmed, perishable, supplier, notes, active) values
  ('Nutella',                    'ingredient', 'g',  'jar 900g',            900, 549, true, true, 'S&R Shaw', 'P549 promo price (regular P599). Nutella draft: 15g frozen disc center.', true),
  ('Nutella Chocolate Biscuits', 'ingredient', 'pc', '276g box, 20 pcs',     20, 329, true, true, 'S&R Shaw', 'Nutella draft topper option (half or whole).', true),
  ('Nutella B-ready',            'ingredient', 'pc', '6 ct',                  6, 194, true, true, 'S&R Shaw', 'DROPPED as a topper (too expensive). Kept for the record.', false),
  ('Biscoff spread',             'ingredient', 'g',  'Lotus crunchy 700g',  700, 541, true, true, 'S&R Shaw', 'Biscoff draft: 15g frozen disc center. Smooth wraps better if available.', true),
  ('Biscoff cookies',            'ingredient', 'g',  'Lotus 997g',          997, 849, true, true, 'S&R Shaw', 'Biscoff draft: crushed into the dough (+ topper option).', true),
  ('Reese''s Giant bar',         'ingredient', 'pc', '208.9g bar, 15 pcs',   15, 199, true, true, 'S&R Shaw', 'Peanut butter draft: 1 bar (15 pcs) per batch.', true),
  ('Reese''s Miniature Cups',    'ingredient', 'g',  'family pack 498g',    498, 549, true, true, 'S&R Shaw', 'Peanut butter draft topper. Cups per pack not confirmed (~64?).', true),
  ('Skippy creamy peanut butter','ingredient', 'g',  'jar 1.36kg',         1360, 477, true, true, 'S&R Shaw', 'Peanut butter draft.', true),
  ('Marshmallows',               'ingredient', 'g',  'Guandy 340g',         340,  89, true, true, 'S&R Shaw', 'No recipe uses it yet.', true)
on conflict (name) do nothing;

-- 3. Live recipes: Coco Loco and Bueno Mucho ----------------------------------------------
-- Helper: insert a recipe line by ingredient name (skips if the line is already there)
create temporary table _lines (flavor_id bigint, ingredient text, qty numeric, note text) on commit drop;

-- Shared base dough (same as Chimp Chips), flour left out so each flavor sets its own
insert into _lines
select f.id, b.ingredient, b.qty, b.note
from (values (2), (3)) f(id),
     (values ('Anchor unsalted butter', 200::numeric, 'Fresh weight, before browning'),
             ('Dark brown sugar', 147, null), ('Granulated sugar', 73, null),
             ('Eggs', 2, '1 whole egg + 1 extra yolk'), ('Vanilla extract', 1.5, null),
             ('Baking soda', 3.7, null), ('Fine sea salt', 3.7, null)) b(ingredient, qty, note);

insert into _lines values
  (2, 'All-purpose flour', 206, '21g of the flour is swapped for cocoa'),
  (2, 'Dutch cocoa powder', 21, null),
  (2, 'Callebaut 811 dark chocolate', 205, null),
  (3, 'All-purpose flour', 227, null),
  (3, 'Kinder Max (milk chocolate)', 200, 'Chopped into the dough'),
  (3, 'Kinder Bueno', 7.5, 'Half a bar in the center of each cookie');

update public.recipes set notes = 'Brown butter base, 206g flour + 21g Dutch cocoa, 205g Callebaut 811. 15 x 60g. Bake 14 min at 175C from frozen. Shelf life 4-5 days.'
  where flavor_id = 2;
update public.recipes set notes = 'Brown butter base + 200g Kinder Max chopped + half-bar Kinder Bueno center (locked Oct 11). 60g dough + ~10.75g center. Bake 15-16 min, cool 8 min on pan. Shelf life 2-3 days.'
  where flavor_id = 3;

-- 4. Draft flavors (hidden: active = false) -----------------------------------------------
insert into public.flavors (slug, name, price, active, single_price, short_description)
select v.slug, v.name, 0, false, null, v.descr
from (values
  ('draft-nutella', 'Nutella (draft)', 'RD1 draft, not on the menu.'),
  ('draft-biscoff', 'Biscoff (draft)', 'RD1 draft, not on the menu. Pick a new menu name (Biscoff is a Lotus trademark).'),
  ('draft-pb-reeses', 'Peanut Butter Reese''s (draft)', 'RD1 draft, not on the menu. Peanut allergen decision needed first.')
) v(slug, name, descr)
where not exists (select 1 from public.flavors f where f.slug = v.slug);

insert into public.recipes (flavor_id, version, yield, dough_freezer_days, notes)
select f.id, 'RD1', 15, 28, v.notes
from public.flavors f join (values
  ('draft-nutella', 'Untested. Base + 150g Callebaut + 15 x 15g frozen Nutella discs, flaky salt on top (not priced). ~56g dough + 15g. Topper option: Nutella biscuit half or whole, pressed on after baking (not in this list).'),
  ('draft-biscoff', 'Untested. Base, no chocolate + 120g crushed Biscoff cookies + 15 x 15g frozen Biscoff spread discs. Optional 1/2 tsp cinnamon (not priced). ~54g dough + 15g. Topper option: half or whole biscuit.'),
  ('draft-pb-reeses', 'Untested. Version A: base with 247g flour + 150g Skippy creamed in + 1 Reese''s Giant bar (1 pc per cookie). Version B adds a 15g frozen Skippy center (+225g). Topper: 1 Reese''s mini cup + flaky salt.')
) v(slug, notes) on v.slug = f.slug
on conflict (flavor_id) do nothing;

insert into _lines
select f.id, b.ingredient, b.qty, b.note
from public.flavors f,
     (values ('Anchor unsalted butter', 200::numeric, 'Fresh weight, before browning'),
             ('Dark brown sugar', 147, null), ('Granulated sugar', 73, null),
             ('Eggs', 2, '1 whole egg + 1 extra yolk'), ('Vanilla extract', 1.5, null),
             ('Baking soda', 3.7, null), ('Fine sea salt', 3.7, null)) b(ingredient, qty, note)
where f.slug in ('draft-nutella', 'draft-biscoff', 'draft-pb-reeses');

insert into _lines
select f.id, v.ingredient, v.qty, v.note
from public.flavors f join (values
  ('draft-nutella', 'All-purpose flour', 227::numeric, null),
  ('draft-nutella', 'Callebaut 811 dark chocolate', 150, 'Oct 20 cost table used 205g'),
  ('draft-nutella', 'Nutella', 225, '15 x 15g frozen discs, center'),
  ('draft-biscoff', 'All-purpose flour', 227, null),
  ('draft-biscoff', 'Biscoff cookies', 120, 'Crushed into the dough'),
  ('draft-biscoff', 'Biscoff spread', 225, '15 x 15g frozen discs, center'),
  ('draft-pb-reeses', 'All-purpose flour', 247, null),
  ('draft-pb-reeses', 'Skippy creamy peanut butter', 150, 'Creamed in with the sugars'),
  ('draft-pb-reeses', 'Reese''s Giant bar', 15, 'Whole bar, 1 piece per cookie')
) v(slug, ingredient, qty, note) on v.slug = f.slug;

insert into public.recipe_items (flavor_id, ingredient_id, qty_per_batch, note)
select l.flavor_id, i.id, l.qty, l.note
from _lines l join public.ingredients i on i.name = l.ingredient
where not exists (select 1 from public.recipe_items r where r.flavor_id = l.flavor_id and r.ingredient_id = i.id);

commit;
