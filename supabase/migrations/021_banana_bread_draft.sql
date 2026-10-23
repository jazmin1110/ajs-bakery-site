-- 021: Brown Butter Banana Bread (RD1) as a hidden draft flavor, classics tier (₱110). Data only.
-- Source: ../recipes/brown-butter-banana-bread-RD1.md (not baked yet).
-- Hidden (active = false) like the other drafts: it shows on the admin Recipes page under "Drafts"
-- but never on the storefront until it has its menu name, content and nutrition and is switched on.

begin;

-- 1. New ingredients. Prices are guesses (price_confirmed = false shows "est.").
--    Banana: no price yet (P0). Cinnamon: ~P1 per 1/2 tsp, from ../context/ingredient-prices.md.
insert into public.ingredients (name, category, unit, pack_label, pack_size, pack_price, price_confirmed, perishable, supplier, notes, active) values
  ('Ripe banana',     'ingredient', 'g',   'per g (peeled)', 1, 0, false, true,  null, 'Banana bread draft: ~130g peeled very ripe banana, cooked down to ~70g. Enter the real price when you buy.', true),
  ('Ground cinnamon', 'ingredient', 'tsp', 'per tsp',        1, 2, false, false, null, 'Still a guess: about P1 per 1/2 tsp. Enter the jar size and price when you have it.', true)
on conflict (name) do nothing;

-- 2. The draft flavor ---------------------------------------------------------------------
insert into public.flavors (slug, name, price, surcharge, active, single_price, short_description)
select 'draft-banana-bread', 'Banana Bread (draft)', 0, 0, false, 110,
       'RD1 draft, not on the menu. Classics tier (P110). Pick a menu name before launch.'
where not exists (select 1 from public.flavors where slug = 'draft-banana-bread');

-- 3. Its recipe ---------------------------------------------------------------------------
insert into public.recipes (flavor_id, version, yield, dough_freezer_days, notes)
select f.id, 'RD1', 15, 28,
  'Untested. Chimp Chips base with 237g flour (+10g, a guess) + ~130g ripe banana cooked down to ~70g + 1/2 tsp cinnamon (tiny pinch nutmeg optional, not listed) + 150g Callebaut 811. 15 x 60g. Bake 14 min at 175C from frozen (guess). Shelf life unknown, guess 3-4 days.'
from public.flavors f where f.slug = 'draft-banana-bread'
on conflict (flavor_id) do nothing;

insert into public.recipe_items (flavor_id, ingredient_id, qty_per_batch, note)
select f.id, i.id, v.qty, v.note
from public.flavors f
cross join (values
  ('Anchor unsalted butter', 200::numeric, 'Fresh weight, before browning'),
  ('Dark brown sugar', 147, null), ('Granulated sugar', 73, null),
  ('Eggs', 2, '1 whole egg + 1 extra yolk'), ('Vanilla extract', 1.5, null),
  ('All-purpose flour', 237, '+10g vs Chimp Chips (a guess)'),
  ('Baking soda', 3.7, null), ('Fine sea salt', 3.7, null),
  ('Ripe banana', 130, 'Peeled weight, before cooking down to ~70g'),
  ('Ground cinnamon', 0.5, null),
  ('Callebaut 811 dark chocolate', 150, 'Chopped')
) v(ingredient, qty, note)
join public.ingredients i on i.name = v.ingredient
where f.slug = 'draft-banana-bread'
  and not exists (select 1 from public.recipe_items r where r.flavor_id = f.id and r.ingredient_id = i.id);

commit;
