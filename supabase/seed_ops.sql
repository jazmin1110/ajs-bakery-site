-- ============================================================================
-- seed_ops.sql: starting ingredients, packaging and recipes for the back office.
-- Run after migration 014. Safe to run more than once (it never overwrites
-- prices or quantities you've edited; it only adds what's missing).
--
-- WHERE THE NUMBERS COME FROM
--   * Confirmed prices: context/ingredient-prices.md + pricing-analysis.md
--     (Anchor butter, Callebaut 811, Dutch cocoa, AP flour, plastic bags,
--     Kinder Max, Kinder Bueno).
--   * price_confirmed = false: the "assumed (CONFIRM)" list in
--     pricing-analysis.md (sugars, eggs, vanilla, baking soda, salt). The admin
--     pages flag these. Replace them with real prices on the Inventory page.
--   * Only Chimp Chips has a recipe here: brown-butter-chocolate-chip-RD1
--     (200g fresh butter, AP flour only). Coco Loco and Bueno Mucho are left
--     EMPTY on purpose: their RD1 files still show bread flour and older
--     yields, so their quantities are for you to enter (Recipes page).
-- ============================================================================

insert into public.ingredients
  (name, category, unit, pack_label, pack_size, pack_price, price_confirmed, perishable, supplier, notes, per_cookie)
values
  ('Anchor unsalted butter',        'ingredient', 'g',   'pack 200g',       200,   184.40, true,  true,  'Unimart Capital Commons', null, 0),
  ('Callebaut 811 dark chocolate',  'ingredient', 'g',   'bag 2.5kg',       2500,  3710.00, true, true,  'All About Baking Shangri-La', null, 0),
  ('Dutch cocoa powder',            'ingredient', 'g',   'pack 500g',       500,   495.00, true,  false, 'All About Baking Shangri-La', null, 0),
  ('All-purpose flour',             'ingredient', 'g',   'kg',              1000,  87.00,  true,  false, null, null, 0),
  ('Dark brown sugar',              'ingredient', 'g',   'kg',              1000,  90.00,  false, false, null, 'Price is a guess. Replace with the real one.', 0),
  ('Granulated sugar',              'ingredient', 'g',   'kg',              1000,  75.00,  false, false, null, 'Price is a guess. Replace with the real one.', 0),
  ('Eggs',                          'ingredient', 'pc',  'tray of 30',      30,    300.00, false, true,  null, 'Price is a guess (about 10 each). A recipe with 1 whole egg + 1 extra yolk uses 2 eggs.', 0),
  ('Vanilla extract',               'ingredient', 'tsp', 'per tsp',         1,     8.00,   false, false, null, 'Placeholder. Enter your bottle size and price (e.g. 250ml = about 50 tsp).', 0),
  ('Baking soda',                   'ingredient', 'g',   'per g',           1,     0.30,   false, false, null, 'Placeholder price. Soda + salt were a lump P2 per batch in the pricing sheet.', 0),
  ('Fine sea salt',                 'ingredient', 'g',   'per g',           1,     0.24,   false, false, null, 'Placeholder price. See baking soda.', 0),
  ('Kinder Max (milk chocolate)',   'ingredient', 'g',   'bar 756g',        756,   1500.00, true,  true,  null, null, 0),
  ('Kinder Bueno',                  'ingredient', 'pc',  'pack of 2 bars',  2,     75.00,  true,  true,  null, '1 pc = 1 whole 21.5g bar. Bueno Mucho uses half a bar per cookie.', 0),
  ('Plastic bag (single cookie)',   'packaging',  'pc',  'pack of 100',     100,   33.00,  true,  false, null, 'Assumes 1 bag per cookie sold.', 1)
on conflict (name) do nothing;

-- One recipe row per flavor (version RD1, 15 cookies per batch)
insert into public.recipes (flavor_id, version, yield, notes)
select f.id, 'RD1', 15,
  case
    when f.slug in ('choc-chip', 'chimp-chips')
      then 'From brown-butter-chocolate-chip-RD1: 200g fresh butter, all-purpose flour only, 60g dough balls.'
    else 'RD1 file still shows bread flour and older yields. Enter the quantities you actually use.'
  end
from public.flavors f
on conflict (flavor_id) do nothing;

-- Chimp Chips items (per batch of 15). Skipped if the recipe already has items.
insert into public.recipe_items (flavor_id, ingredient_id, qty_per_batch, note)
select f.id, i.id, v.qty, v.note
from public.flavors f
join (values
  ('Anchor unsalted butter',       200,   'Fresh weight, before browning'),
  ('Dark brown sugar',             147,   null),
  ('Granulated sugar',             73,    null),
  ('Eggs',                         2,     '1 whole egg + 1 extra yolk'),
  ('Vanilla extract',              1.5,   null),
  ('All-purpose flour',            227,   null),
  ('Baking soda',                  3.7,   null),
  ('Fine sea salt',                3.7,   null),
  ('Callebaut 811 dark chocolate', 205,   null)
) as v(ing, qty, note) on true
join public.ingredients i on i.name = v.ing
where f.slug in ('choc-chip', 'chimp-chips')
  and not exists (select 1 from public.recipe_items ri where ri.flavor_id = f.id);
