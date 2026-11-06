-- 029: storefront copy refresh (Nov 7, 2026). Data only, no schema changes.
-- 1. Box of 12 description: "The party box..." -> "The barkada box..." (12 cookies isn't really a crowd).
-- 2. Chimp Chips and Bueno Mucho descriptions, from flavor-content.json (same text as seed_content.sql):
--    Bueno Mucho no longer says "our biggest cookie" (Nutella, Biscoff and PB Reese's are also ~70g),
--    and Chimp Chips no longer says "the one to start with" twice (short + long description).
-- Safe to run more than once.

update public.boxes
  set description = 'The barkada box. Feeds the group chat.'
  where size = 12;

update public.flavors
  set short_description = $c$Our brown butter dough loaded with Callebaut dark chocolate. Soft, chewy, the classic.$c$
  where slug in ('chimp-chips', 'choc-chip');

update public.flavors
  set short_description = $c$Half a Kinder Bueno hidden inside. Wafer crunch, hazelnut cream, all of it.$c$,
      long_description  = $c$The fun one. Brown butter dough loaded with chopped Kinder Maxi chocolate, wrapped around half a Kinder Bueno bar. Bite in and you hit wafer crunch and hazelnut cream. It's a big one at about 70g, and the wafer goes soft after a few days, so eat it within 2-3 days.$c$
  where slug in ('bueno-mucho', 'kinder-bueno');
