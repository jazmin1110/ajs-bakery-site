-- ============================================================================
-- 010_boxes.sql: new box sizes. Retire the box of 4; sell boxes of 3, 6 and 12.
--
--   Box of 3  = P285   (95 per cookie)
--   Box of 6  = P570   (unchanged)
--   Box of 12 = P1080  (90 per cookie)
--   Bueno Mucho still adds +P30 per cookie in every box (that lives on flavors.surcharge).
--
-- Why a new number and not 003: migrations 003-009 already exist, so this is 010.
--
-- The box of 4 is switched OFF (active = false), not deleted: old orders point at it
-- (order_boxes.size), and the admin pages still need to show them.
--
-- Nothing else needs to change in the database: quote_box() and place_order() already
-- read the allowed sizes and prices from this table, so a box size that is missing or
-- inactive (like 4 now) is refused with "That box size isn't available."
-- Run after 009.
-- ============================================================================

-- A one-line description per box, shown on the website's box cards.
-- Kept in the table so the website has no box sizes written into its code.
alter table public.boxes add column description text check (char_length(description) <= 200);

-- (anon can already read this table; RLS still limits visitors to active rows,
--  and visitors still have no way to change anything.)

update public.boxes set active = false where size = 4;

insert into public.boxes (size, price, active, description) values
  (3,  285,  true, 'A little treat, or a gift for one.'),
  (6,  570,  true, 'Share it (or don''t).'),
  (12, 1080, true, 'The party box. Best for gifting a crowd.')
on conflict (size) do update
  set price = excluded.price, active = excluded.active, description = excluded.description;
