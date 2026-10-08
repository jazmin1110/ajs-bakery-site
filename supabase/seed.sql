-- seed.sql: starting menu data from CLAUDE.md. Safe to re-run (it updates in place).
-- Run AFTER migrations/001_init.sql.

-- Per-cookie prices. Kinder Bueno carries a +30 surcharge inside box totals
-- (125 = the 95 base + 30). Slugs match the ids in js/config.js.
insert into public.flavors (slug, name, price, surcharge, active) values
  ('choc-chip',    'Brown Butter Choc Chip',        95,  0, true),
  ('double-choc',  'Brown Butter Double Chocolate', 100, 0, true),
  ('kinder-bueno', 'Brown Butter Kinder Bueno',     125, 30, true)
on conflict (slug) do update
  set name = excluded.name, price = excluded.price,
      surcharge = excluded.surcharge, active = excluded.active;

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
