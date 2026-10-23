-- 020: lock two single-cookie price tiers (Oct 24, 2026). Data only, no schema change.
--   Classics ₱110: Chimp Chips (was 105), Coco Loco (already 110).
--   Specials ₱135: Bueno Mucho (already 135) + the hidden drafts, so they launch at the right price.
-- Box prices are unchanged. Drafts also get the +30 box surcharge Bueno Mucho has, so a special
-- inside a box costs more than a classic once a draft is switched on.

begin;

update public.flavors set single_price = 110 where slug in ('choc-chip', 'double-choc');

update public.flavors set single_price = 135 where slug = 'kinder-bueno';

-- Drafts stay inactive (active = false): they still never show on the storefront.
update public.flavors set single_price = 135, surcharge = 30
  where slug in ('draft-nutella', 'draft-biscoff', 'draft-pb-reeses');

commit;
