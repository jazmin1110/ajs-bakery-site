-- 025: Specials add +P25 per cookie in a box, down from +P30 (Oct 25, 2026). Data only.
-- Specials cost P25 more than classics as singles (135 vs 110), so a +25 box add-on keeps the
-- box discount the same for every mix: a box saves P30 / P70 / P180 vs singles, classics or specials.
-- Before, +30 made a box of 3 specials save only P15 (P5 a cookie).
-- Old orders keep the price they were placed at (order_boxes stores its own total).
-- Run after 024.

begin;

update public.flavors set surcharge = 25 where surcharge > 0;

commit;
