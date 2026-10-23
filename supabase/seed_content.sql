-- ============================================================================
-- seed_content.sql: flavor content, GENERATED from flavor-content.json by supabase/build_seed_content.py.
-- Do not edit by hand: edit the JSON and run the script again.
-- Safe to run more than once. Photos (photo_url, focus_x, focus_y, photo_version) are never touched.
-- Run after migration 013.
-- ============================================================================

insert into public.site_settings (key, value) values
  ('global_allergen_note', $c$Made in a home kitchen that also handles milk, egg, wheat, soy, hazelnuts and peanuts. If you have a serious allergy, message us before ordering.$c$),
  ('nutrition_note', $c$Estimated per cookie. Calculated from our recipe and the labels of the ingredients we use, not lab tested. Actual values vary a little with each batch.$c$)
on conflict (key) do update set value = excluded.value;

-- Chimp Chips
update public.flavors set
  short_description = $c$Nutty brown butter packed with Callebaut dark chocolate. Soft, chewy, and the one to start with.$c$,
  long_description  = $c$This is the one to start with. We brown the butter until it smells like toasted caramel, then load the dough with chopped Callebaut dark chocolate, the Belgian chocolate bakers love. Soft and chewy, with a nutty, buttery edge and chocolate in every bite.$c$,
  taste_notes       = array[$c$Toasted brown butter$c$, $c$Callebaut dark chocolate$c$, $c$Soft and chewy$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, dark chocolate (cocoa mass, sugar, cocoa butter, soy lecithin, natural vanilla flavouring), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Peanuts$c$, $c$Hazelnuts and other tree nuts$c$]::text[],
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
  may_contain       = array[$c$Peanuts$c$, $c$Hazelnuts and other tree nuts$c$]::text[],
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
  may_contain       = array[$c$Peanuts$c$, $c$Other tree nuts$c$]::text[],
  weight_label      = $c$About 70g$c$,
  shelf_life        = $c$Best within 2-3 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 70g)", "calories": 355, "total_carbohydrate_g": 39, "sugars_g": 26, "total_fat_g": 20, "protein_g": 4}$c$::jsonb
where slug in ('bueno-mucho', 'kinder-bueno');

-- Banana Bread
update public.flavors set
  short_description = $c$Banana bread in cookie form: ripe banana, a little cinnamon and Callebaut dark chocolate on our brown butter base.$c$,
  long_description  = $c$Everything you love about a warm slice of banana bread, squeezed into a cookie. We cook down very ripe bananas so the flavor gets deep and jammy, add a pinch of cinnamon, then fold in Callebaut dark chocolate. Soft, cozy and a little nostalgic.$c$,
  taste_notes       = array[$c$Ripe banana$c$, $c$Cinnamon$c$, $c$Callebaut dark chocolate$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, dark chocolate (cocoa mass, sugar, cocoa butter, soy lecithin, natural vanilla flavouring), brown butter (unsalted butter), dark brown sugar, ripe banana, sugar, eggs, vanilla extract, cinnamon, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Peanuts$c$, $c$Hazelnuts and other tree nuts$c$]::text[],
  weight_label      = $c$About 60g$c$,
  shelf_life        = $c$Best within 3-4 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 60g)", "calories": 285, "total_carbohydrate_g": 33, "sugars_g": 20, "total_fat_g": 15, "protein_g": 3}$c$::jsonb
where slug in ('banana-bread');

-- Nutella
update public.flavors set
  short_description = $c$A melty Nutella center hiding inside brown butter dough with Callebaut dark chocolate, finished with flaky salt.$c$,
  long_description  = $c$For the Nutella-from-the-jar crowd. Each cookie hides a frozen disc of Nutella that melts into a gooey hazelnut chocolate center as it bakes, wrapped in our brown butter dough with chopped Callebaut dark chocolate. A pinch of flaky salt on top keeps it from being too sweet.$c$,
  taste_notes       = array[$c$Gooey Nutella center$c$, $c$Callebaut dark chocolate$c$, $c$Flaky salt$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, Nutella (sugar, palm oil, hazelnuts, skimmed milk powder, fat-reduced cocoa, soy lecithin, vanillin), dark chocolate (cocoa mass, sugar, cocoa butter, soy lecithin, natural vanilla flavouring), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, baking soda, salt, flaky sea salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$, $c$Hazelnuts$c$]::text[],
  may_contain       = array[$c$Peanuts$c$, $c$Other tree nuts$c$]::text[],
  weight_label      = $c$About 70g$c$,
  shelf_life        = $c$Best within 3-4 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 70g)", "calories": 355, "total_carbohydrate_g": 39, "sugars_g": 27, "total_fat_g": 20, "protein_g": 4}$c$::jsonb
where slug in ('nutella');

-- Biscoff
update public.flavors set
  short_description = $c$Brown butter dough with crushed Lotus biscuits and a gooey cookie butter center. Warm, spiced and caramel-y.$c$,
  long_description  = $c$Cookie butter lovers, this one's yours. Crushed Lotus Biscoff biscuits go into our brown butter dough with a little cinnamon, and every cookie hides a frozen disc of Biscoff spread that turns soft and gooey in the oven. Think caramelized, cinnamon-spiced and very hard to share.$c$,
  taste_notes       = array[$c$Cookie butter center$c$, $c$Crushed Lotus biscuits$c$, $c$Warm cinnamon$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, Biscoff spread (caramelised biscuits (wheat flour, sugar, vegetable oils (palm, rapeseed), candy sugar syrup, raising agent (sodium bicarbonate), soy flour, salt, cinnamon), rapeseed oil, sugar, soy lecithin, citric acid), Lotus Biscoff biscuits (wheat flour, sugar, vegetable oils (palm, rapeseed), candy sugar syrup, raising agent (sodium bicarbonate), soy flour, salt, cinnamon), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, cinnamon, baking soda, salt.$c$,
  contains          = array[$c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Peanuts$c$, $c$Hazelnuts and other tree nuts$c$]::text[],
  weight_label      = $c$About 70g$c$,
  shelf_life        = $c$Best within 3-4 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 70g)", "calories": 345, "total_carbohydrate_g": 40, "sugars_g": 23, "total_fat_g": 19, "protein_g": 3}$c$::jsonb
where slug in ('biscoff');

-- Peanut Butter Reese's
update public.flavors set
  short_description = $c$Peanut butter brown butter dough loaded with chopped Reese's. Salty, sweet and very peanutty. Contains peanuts.$c$,
  long_description  = $c$Made for peanut butter people. Creamy peanut butter goes right into our brown butter dough, then we pack it with chopped Reese's peanut butter cups. Salty-sweet, soft in the middle and seriously peanutty. Please note: this cookie contains peanuts.$c$,
  taste_notes       = array[$c$Creamy peanut butter$c$, $c$Chopped Reese's$c$, $c$Salty-sweet$c$]::text[],
  ingredients       = $c$All-purpose wheat flour, Reese's milk chocolate peanut butter cups (milk chocolate (sugar, cocoa butter, chocolate, skim milk, milk fat, lactose, soy lecithin, PGPR), peanuts, sugar, dextrose, salt, TBHQ), peanut butter (roasted peanuts, sugar, hydrogenated vegetable oils, salt), brown butter (unsalted butter), dark brown sugar, sugar, eggs, vanilla extract, baking soda, salt.$c$,
  contains          = array[$c$Peanuts$c$, $c$Wheat (gluten)$c$, $c$Milk$c$, $c$Egg$c$, $c$Soy$c$]::text[],
  may_contain       = array[$c$Hazelnuts and other tree nuts$c$]::text[],
  weight_label      = $c$About 70g$c$,
  shelf_life        = $c$Best within 4-5 days.$c$,
  storage_tip       = $c$Keep in an airtight container at room temperature.$c$,
  nutrition         = $c${"serving": "1 cookie (about 70g)", "calories": 355, "total_carbohydrate_g": 37, "sugars_g": 22, "total_fat_g": 21, "protein_g": 6}$c$::jsonb
where slug in ('pb-reeses');

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
  raise notice '%', $c$BANANA BREAD:$c$;
  raise notice '%', $c$  [ ] ROUGH PLACEHOLDER from the RD1 draft recipe, before the first test bake. Replace everything with final values after testing.$c$;
  raise notice '%', $c$  [ ] Banana amount and flour are still guesses in RD1: recalculate once the recipe is locked.$c$;
  raise notice '%', $c$  [ ] Shelf life of 3-4 days is a guess (banana makes it moister): test Day 1-5.$c$;
  raise notice '%', $c$  [ ] Pick the final menu name (the recipe notes say to name it before launch).$c$;
  raise notice '%', $c$NUTELLA:$c$;
  raise notice '%', $c$  [ ] ROUGH PLACEHOLDER from the RD1 draft recipe, before the first test bake. Replace everything with final values after testing.$c$;
  raise notice '%', $c$  [ ] If you add a Nutella biscuit topper, add it to the ingredients and nutrition.$c$;
  raise notice '%', $c$  [ ] Check the Nutella jar label from S&R against the values used.$c$;
  raise notice '%', $c$  [ ] Shelf life of 3-4 days is a guess: test it.$c$;
  raise notice '%', $c$BISCOFF:$c$;
  raise notice '%', $c$  [ ] ROUGH PLACEHOLDER from the RD1 draft recipe, before the first test bake. Replace everything with final values after testing.$c$;
  raise notice '%', $c$  [ ] Biscoff is a Lotus trademark: pick your own menu name before this goes much further.$c$;
  raise notice '%', $c$  [ ] Check the Lotus spread and biscuit labels from S&R (crunchy spread values are approximate).$c$;
  raise notice '%', $c$  [ ] Shelf life of 3-4 days is a guess: test it.$c$;
  raise notice '%', $c$PEANUT BUTTER REESE'S:$c$;
  raise notice '%', $c$  [ ] ROUGH PLACEHOLDER from the RD1 draft recipe, before the first test bake. Replace everything with final values after testing.$c$;
  raise notice '%', $c$  [ ] Peanut allergen decision is still open: peanuts are now in the shared kitchen, so every other flavor lists 'Peanuts' under may contain.$c$;
  raise notice '%', $c$  [ ] If you go with version B (PB center) or the mini cup topper, recalculate.$c$;
  raise notice '%', $c$  [ ] Check the Skippy and Reese's Giant labels against the values used.$c$;
end $todo$;
