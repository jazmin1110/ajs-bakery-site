-- 022: new box prices (Oct 24, 2026). Data only, no schema change.
--   Box of 3  = P300   (was 285; 100 per cookie)
--   Box of 6  = P590   (was 570; ~98 per cookie)
--   Box of 12 = P1140  (was 1080; 95 per cookie)
-- Follows the classic single going to P110 (migration 020), so a box still saves
-- P30 / P70 / P180 against classic singles. Specials still add +P30 per cookie in a box
-- (flavors.surcharge, unchanged). quote_box() and place_order() read prices from this
-- table, so nothing else needs to change. Old orders keep the price they were placed at.
-- Run after 021.

begin;

update public.boxes set price = 300  where size = 3;
update public.boxes set price = 590  where size = 6;
update public.boxes set price = 1140 where size = 12;

commit;
