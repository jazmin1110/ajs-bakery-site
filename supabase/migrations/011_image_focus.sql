-- ============================================================================
-- 011_image_focus.sql: where to centre each flavor photo when the site crops it.
--
-- The site shows every flavor photo in a fixed shape (4:3 on menu cards and the detail
-- sheet, square for the builder thumbnails) using CSS object-fit: cover, which crops
-- the picture. focus_x / focus_y say which point of the photo to keep in the middle of
-- that crop: 0 = left / top edge, 50 = centre, 100 = right / bottom edge.
-- Edit them in Supabase (Table Editor > flavors) if a cookie sits off-centre.
-- Run after 010.
-- ============================================================================

alter table public.flavors
  add column focus_x int not null default 50 check (focus_x between 0 and 100),
  add column focus_y int not null default 50 check (focus_y between 0 and 100);

-- Starting values, picked by looking at each photo (where the middle of the cookie is, as a
-- percentage across / down the picture). "and focus_x = 50 and focus_y = 50" means a value
-- you've already changed by hand is never overwritten.
update public.flavors set focus_x = 49, focus_y = 51 where slug = 'choc-chip'    and focus_x = 50 and focus_y = 50;
update public.flavors set focus_x = 51, focus_y = 52 where slug = 'double-choc'  and focus_x = 50 and focus_y = 50;
update public.flavors set focus_x = 48, focus_y = 50 where slug = 'kinder-bueno' and focus_x = 50 and focus_y = 50;
