-- seed.sql: starting menu data from CLAUDE.md. Safe to re-run (it updates in place).
-- Run AFTER the migrations (001 to 007).

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

-- Flat box prices.
insert into public.boxes (size, price, active) values
  (4, 380, true),
  (6, 570, true)
on conflict (size) do update
  set price = excluded.price, active = excluded.active;

-- ---------------------------------------------------------------------------
-- Make yourself an admin (do this by hand, NOT in this file):
-- 1) Supabase dashboard > Authentication > Users > "Add user" with your email.
-- 2) Then run, in the SQL editor, with your real email:
--
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'you@example.com';
-- ---------------------------------------------------------------------------
