-- ============================================================================
-- seed_content.sql: flavor content, GENERATED from flavor-content.json by supabase/build_seed_content.py.
-- Do not edit by hand: edit the JSON and run the script again.
-- Safe to run more than once. Photos (photo_url, focus_x, focus_y, photo_version) are never touched.
-- Run after migration 013.
-- ============================================================================

insert into public.site_settings (key, value) values
  ('global_allergen_note', $c$Made in a home kitchen that also handles milk, egg, wheat, soy and hazelnuts. If you have a serious allergy, message us before ordering.$c$),
  ('nutrition_note', $c$Estimated per cookie. Calculated from our recipe and the labels of the ingredients we use, not lab tested. Actual values vary a little with each batch.$c$)
on conflict (key) do update set value = excluded.value;

-- Chimp Chips
update public.flavors set
  short_description = $c$Nutty brown butter packed with Callebaut dark chocolate. Soft, chewy, and the one to start with.$c$,
  long_description  = $c$This is the one to start with. We brown the butter until it smells like toasted caramel, then load the dough with chopped Callebaut dark chocolate, the Belgian chocolate bakers love. Soft and chewy, with a nutty, buttery edge and chocolate in every bite.$c$,
  taste_notes       = array[$c$Toasted brown butter$c$, $c$Callebaut dark chocolate$c$, $c$Soft and chewy$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, dark chocolate (cocoa mass, sugar, cocoa butter, soy lecithin, natural vanilla flavouring), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Hazelnuts and other tree nuts$c$]::text[],
  weight_label      = $c$About 60g$c$,
  shelf_life        = $c$Best within 4-5 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 60g)", "calories": 295, "total_carbohydrate_g": 32, "sugars_g": 20, "total_fat_g": 17, "protein_g": 3}$c$::jsonb
where slug in ('chimp-chips', 'choc-chip');

-- Coco Loco
update public.flavors set
  short_description = $c$Dutch cocoa dough with Callebaut dark chocolate chunks. Rich, deep, and not bitter.$c$,
  long_description  = $c$Made for people who take chocolate seriously. Dutch cocoa goes into the dough, then chunks of Callebaut dark chocolate on top of that, all on our brown butter base. Dutch cocoa is the mellow kind, so it's dark and rich without the harsh bitterness. Best with cold milk.$c$,
  taste_notes       = array[$c$Dutch cocoa$c$, $c$Callebaut dark chocolate$c$, $c$Brown butter$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, dark chocolate (cocoa mass, sugar, cocoa butter, soy lecithin, natural vanilla flavouring), brown butter (unsalted butter), dark brown sugar, sugar, eggs, Dutch-process cocoa powder, vanilla extract, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Hazelnuts and other tree nuts$c$]::text[],
  weight_label      = $c$About 60g$c$,
  shelf_life        = $c$Best within 4-5 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 60g)", "calories": 295, "total_carbohydrate_g": 32, "sugars_g": 20, "total_fat_g": 17, "protein_g": 3}$c$::jsonb
where slug in ('coco-loco', 'double-choc');

-- Bueno Mucho
update public.flavors set
  short_description = $c$Half a Kinder Bueno hidden inside, with Kinder Maxi chocolate in the dough. Our biggest cookie.$c$,
  long_description  = $c$The fun one. Brown butter dough loaded with chopped Kinder Maxi chocolate, wrapped around half a Kinder Bueno bar. Bite in and you hit wafer crunch and hazelnut cream. It's our biggest cookie at about 70g, and the wafer goes soft after a few days, so eat it within 2-3 days.$c$,
  taste_notes       = array[$c$Kinder Maxi chocolate$c$, $c$Hazelnut cream$c$, $c$Wafer crunch$c$]::text[],
  ingredients       = $c$Kinder Bueno (milk chocolate, sugar, palm oil, wheat flour, hazelnuts, milk powder, soy lecithin), all-purpose wheat flour, Kinder Maxi milk chocolate (sugar, milk powder, cocoa butter, cocoa mass, palm oil, soy lecithin), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$, $c$Hazelnuts$c$]::text[],
  may_contain       = array[$c$Other tree nuts$c$]::text[],
  weight_label      = $c$About 70g$c$,
  shelf_life        = $c$Best within 2-3 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 70g)", "calories": 355, "total_carbohydrate_g": 39, "sugars_g": 26, "total_fat_g": 20, "protein_g": 4}$c$::jsonb
where slug in ('bueno-mucho', 'kinder-bueno');

do $todo$ begin
  raise notice '=== TODO: things to verify before launch (from flavor-content.json) ===';
  raise notice '%', $c$CHIMP CHIPS:$c$;
  raise notice '%', $c$  [ ] Check your Callebaut 811 pack against the values used (550 kcal, 36.6g fat, 5.1g protein per 100g from Barry Callebaut; 45.8g carbs and 43.1g sugars from UK distributor sheets of the same recipe). Update if your pack differs.$c$;
  raise notice '%', $c$  [ ] Check your Anchor butter pack matches the UK 200g label (744 kcal, 82g fat per 100g).$c$;
  raise notice '%', $c$  [ ] Flour, sugars, eggs and vanilla use standard values because the brands aren't recorded. Add the brands if you want it tighter.$c$;
  raise notice '%', $c$  [ ] Weigh 5 baked cookies and use the average. 60g is dough weight; baked weight is a bit lower. Per-cookie nutrition stays the same as long as you portion 60g each.$c$;
  raise notice '%', $c$COCO LOCO:$c$;
  raise notice '%', $c$  [ ] Same Callebaut 811 and Anchor checks as Chimp Chips.$c$;
  raise notice '%', $c$  [ ] The 500g Dutch cocoa powder from All About Baking: read its pack for brand, per-100g nutrition and any allergen line. I used a standard alkalized cocoa value (228 kcal per 100g).$c$;
  raise notice '%', $c$  [ ] Weigh 5 baked cookies and use the average.$c$;
  raise notice '%', $c$BUENO MUCHO:$c$;
  raise notice '%', $c$  [ ] Same Anchor check as Chimp Chips.$c$;
  raise notice '%', $c$  [ ] Read the Kinder Maxi pack (I used Ferrero's label: 566 kcal, 35g fat, 53.5g carbs, 53.3g sugars, 8.7g protein per 100g) and the Kinder Bueno pack (572 kcal, 37.3g fat, 49.5g carbs, 41.2g sugars, 8.6g protein per 100g). Update if your PH packs differ.$c$;
  raise notice '%', $c$  [ ] Confirm the center piece weighs about 10.75g (half of a 21.5g bar) and weigh 5 baked cookies. Dough is 60g plus the center, so roughly 71g before baking loss.$c$;
  raise notice '%', $c$  [ ] Confirm the shelf life of 2-3 days (the wafer goes soft first) by testing Day 1, 2, 3 and 4 on a batch you keep.$c$;
end $todo$;
