-- seed.sql: starting menu data from CLAUDE.md. Safe to re-run (it updates in place).
-- Run AFTER the migrations (001 to 009).

-- Per-cookie prices. Bueno Mucho (Kinder Bueno) carries a +30 surcharge inside box totals
-- (125 = the 95 base + 30). Slugs match the ids in js/config.js.
insert into public.flavors (slug, name, price, surcharge, single_price, weekly_cap, active) values
  ('choc-chip',    'Chimp Chips', 95,  0,  105, 15, true),
  ('double-choc',  'Coco Loco',   100, 0,  110, 15, true),
  ('kinder-bueno', 'Bueno Mucho', 125, 30, 135, 15, true)
on conflict (slug) do update
  set name = excluded.name, price = excluded.price, surcharge = excluded.surcharge,
      single_price = excluded.single_price, weekly_cap = excluded.weekly_cap, active = excluded.active;
-- single_price = price of one loose cookie (migration 006).
-- weekly_cap   = how many of this flavor we bake per Sunday (migration 007).
-- `price` is an unused legacy column.

-- Starting photo and description for the detail sheet (migration 009). "coalesce" means: only fill
-- them in if they're still empty, so re-running this file never overwrites text you wrote yourself.
update public.flavors set photo_url = coalesce(photo_url, 'assets/flavors/chimp-chips.jpg'),
  long_description = coalesce(long_description, 'Classic nutty brown butter chocolate chip cookie.') where slug = 'choc-chip';
update public.flavors set photo_url = coalesce(photo_url, 'assets/flavors/coco-loco.jpg'),
  long_description = coalesce(long_description, 'Double chocolate brown butter chocolate chip cookie.') where slug = 'double-choc';
update public.flavors set photo_url = coalesce(photo_url, 'assets/flavors/bueno-mucho.jpg'),
  long_description = coalesce(long_description, 'Nutty brown butter with Kinder Maxi chocolate and a bueno center.') where slug = 'kinder-bueno';

-- Where to centre each photo in its crop (see migration 011). Only touches flavors still on the
-- default 50/50, so a value you changed by hand is kept.
update public.flavors set focus_x = 49, focus_y = 51 where slug = 'choc-chip'    and focus_x = 50 and focus_y = 50;
update public.flavors set focus_x = 51, focus_y = 52 where slug = 'double-choc'  and focus_x = 50 and focus_y = 50;
update public.flavors set focus_x = 48, focus_y = 50 where slug = 'kinder-bueno' and focus_x = 50 and focus_y = 50;

-- Flat box prices. The box of 4 is retired (kept, switched off: old orders point at it).
insert into public.boxes (size, price, active, description) values
  (3,  285,  true,  'A little treat, or a gift for one.'),
  (4,  380,  false, null),
  (6,  570,  true,  'Share it (or don''t).'),
  (12, 1080, true,  'The party box. Best for gifting a crowd.')
on conflict (size) do update
  set price = excluded.price, active = excluded.active, description = excluded.description;

-- ---------------------------------------------------------------------------
-- Make yourself an admin (do this by hand, NOT in this file):
-- 1) Supabase dashboard > Authentication > Users > "Add user" with your email.
-- 2) Then run, in the SQL editor, with your real email:
--
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'you@example.com';
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FLAVOR DETAILS TO FILL IN (migration 009). The website shows "coming soon" for
-- anything left empty. Nothing here is guessed: these are YOURS to write.
-- Copy one block per flavor into the SQL editor, replace the text, and run it.
-- (Or edit the same columns by hand: Supabase > Table Editor > flavors.)
--
--   update public.flavors set
--     ingredients         = '<write the full ingredient list>',
--     allergens           = '<write every allergen: people rely on this>',
--     weight_g            = <grams per cookie, a number>,
--     shelf_life          = '<how long they keep>',
--     storage_tip         = '<how to store or reheat>',
--     nutrition_image_url = 'assets/nutrition/<file>.jpg'   -- add the picture to public/assets/nutrition/ first
--   where slug = 'choc-chip';        -- choc-chip = Chimp Chips, double-choc = Coco Loco, kinder-bueno = Bueno Mucho
-- ---------------------------------------------------------------------------
