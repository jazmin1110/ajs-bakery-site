-- ===========================================================================
-- tests_028.sql: proves migration 028 (packaging rules) works.
-- One block. It ends by raising 'ALL 028 TESTS PASSED', which ROLLS EVERYTHING BACK,
-- so it can be run right after the migration in the same transaction (dry run) or on
-- a dev project. Any failure raises 'FAIL (...)' instead.
--
-- Checks:
--   (a) the migration moved bag + sticker to "1 per single" (+ sticker "1 per box")
--   (b) the Bake plan shopping list counts packaging from the Sunday's orders
--   (c) packing an order (Ready) takes it out of stock once and keeps its cost
--   (d) moving back and forward again doesn't take it twice; plan stops asking for it
--   (e) the money report counts the packing cost against that Sunday
--   (f) recipe costing no longer adds bag + sticker to every cookie
-- ===========================================================================
do $$
declare
  admin_id uuid := gen_random_uuid();
  wk     date := (now() at time zone 'Asia/Manila')::date + (7 - extract(dow from (now() at time zone 'Asia/Manila'))::int) % 7 + 21;
  fl     text := (select slug from public.flavors where active order by id limit 1);
  bag    bigint := (select id from public.ingredients where category = 'packaging' and name = 'Plastic bag (single cookie)');
  stick  bigint := (select id from public.ingredients where category = 'packaging' and name = 'Stickers');
  card   bigint; small bigint; big bigint;
  r      record; o public.orders; plan jsonb; rep jsonb;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  -- (a) the owner's existing items were converted
  if (select count(*) from public.packaging_rules where ingredient_id = bag and per = 'single' and qty = 1) <> 1
     or (select count(*) from public.packaging_rules where ingredient_id = stick and per in ('single', 'box')) <> 2
     or exists (select 1 from public.packaging_rules where ingredient_id in (bag, stick) and per = 'cookie')
     or exists (select 1 from public.ingredients where per_cookie > 0) then
    raise exception 'FAIL (a): bag/sticker rules not converted';
  end if;

  -- New items: a thank-you card (1 per order), a small box (boxes of 3 and 6), a big box (box of 12)
  insert into public.ingredients (name, category, unit, pack_size, pack_price, price_confirmed)
    values ('TEST thank-you card', 'packaging', 'pc', 50, 100, true) returning id into card;     -- ₱2 each
  insert into public.ingredients (name, category, unit, pack_size, pack_price, price_confirmed)
    values ('TEST small box', 'packaging', 'pc', 10, 150, true) returning id into small;         -- ₱15 each
  insert into public.ingredients (name, category, unit, pack_size, pack_price, price_confirmed)
    values ('TEST big box', 'packaging', 'pc', 10, 300, true) returning id into big;             -- ₱30 each
  insert into public.packaging_rules (ingredient_id, per) values (card, 'order');
  insert into public.packaging_rules (ingredient_id, per, box_size) values (small, 'box', 3), (small, 'box', 6);
  insert into public.packaging_rules (ingredient_id, per, box_size) values (big, 'box', 12);

  -- Plenty of everything in stock, at known prices
  perform public.admin_receive_stock(p_ingredient_id => card,  p_qty => 50,  p_unit_cost => 2);
  perform public.admin_receive_stock(p_ingredient_id => small, p_qty => 10,  p_unit_cost => 15);
  perform public.admin_receive_stock(p_ingredient_id => big,   p_qty => 10,  p_unit_cost => 30);
  perform public.admin_receive_stock(p_ingredient_id => bag,   p_qty => 100, p_unit_cost => 0.33);
  perform public.admin_receive_stock(p_ingredient_id => stick, p_qty => 100, p_unit_cost => 7);

  -- One paid walk-in order: a box of 6 (with a gift note) + 2 singles
  select * into r from public.admin_create_order(wk, 'TEST packing', null, null, 'walk_in', 'pickup', null,
    jsonb_build_array(jsonb_build_object('size', 6, 'gift_note', 'Happy birthday',
      'items', jsonb_build_array(jsonb_build_object('flavor_slug', fl, 'qty', 6)))),
    jsonb_build_array(jsonb_build_object('flavor_slug', fl, 'qty', 2)),
    'paid', 'cash', null, null, true);

  -- (b) shopping list needs: 1 card, 1 small box, 0 big box, 2 bags, 3 stickers (2 singles + 1 box)
  plan := public.admin_production_plan(wk, true);
  if coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = card), 0) <> 1
     or coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = small), 0) <> 1
     or coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = big), 0) <> 0
     or coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = bag), 0) <> 2
     or coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = stick), 0) <> 3 then
    raise exception 'FAIL (b): shopping needs wrong: %', (select jsonb_agg(jsonb_build_object('n', s->>'name', 'need', s->>'needed'))
      from jsonb_array_elements(plan->'shopping') s where (s->>'category') = 'packaging');
  end if;

  -- (c) pack it: Ready takes 1 card, 1 small box, 2 bags, 3 stickers; cost = 2 + 15 + 0.66 + 21 = 38.66
  perform public.admin_set_order_prep(r.ref_code, 'ready');
  select * into o from public.orders where ref_code = r.ref_code;
  if o.packed_at is null or o.packaging_cost <> 38.66 then
    raise exception 'FAIL (c): packed_at % / cost % (expected 38.66)', o.packed_at, o.packaging_cost;
  end if;
  if (select -sum(delta) from public.stock_log where reason = 'packed' and note = 'packed ' || r.ref_code and ingredient_id = stick) <> 3
     or (select -sum(delta) from public.stock_log where reason = 'packed' and note = 'packed ' || r.ref_code and ingredient_id = big) is not null then
    raise exception 'FAIL (c): wrong amounts taken out of stock';
  end if;

  -- (d) back to Baking and Ready again: nothing taken twice; the plan no longer asks for its packaging
  perform public.admin_set_order_prep(r.ref_code, 'baking');
  perform public.admin_set_order_prep(r.ref_code, 'ready');
  perform public.admin_set_order_prep(r.ref_code, 'completed');
  if (select count(distinct created_at) from public.stock_log where reason = 'packed' and note = 'packed ' || r.ref_code) <> 1
     or (select -sum(delta) from public.stock_log where reason = 'packed' and note = 'packed ' || r.ref_code) <> 7 then
    raise exception 'FAIL (d): packaging taken more than once';
  end if;
  plan := public.admin_production_plan(wk, true);
  if coalesce((select (s->>'needed')::numeric from jsonb_array_elements(plan->'shopping') s where (s->>'ingredient_id')::bigint = card), 0) <> 0 then
    raise exception 'FAIL (d): plan still asks for packaging of a packed order';
  end if;

  -- (e) money report: packing cost counted for that Sunday, and taken off profit
  rep := public.admin_money_report(wk, wk);
  if (rep->'weeks'->0->>'packing_cost')::numeric <> 38.66
     or (rep->'weeks'->0->>'profit')::numeric <> (rep->'weeks'->0->>'money_in')::numeric - 38.66 then
    raise exception 'FAIL (e): money report %', rep->'weeks'->0;
  end if;

  -- (f) recipe costing: no cookie-level packaging any more (bag + sticker were the only ones)
  if exists (select 1 from public.flavor_costing where packaging_cost_per_cookie <> 0) then
    raise exception 'FAIL (f): packaging still added per cookie';
  end if;

  raise exception 'ALL 028 TESTS PASSED (rolled back, nothing saved). Packing cost %', o.packaging_cost;
end $$;
