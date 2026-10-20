-- ===========================================================================
-- tests_ops.sql: proves migration 014 (the back office) works and is locked down.
-- Same rules as tests.sql: paste ONE block at a time into the Supabase SQL
-- editor. Each block ends in ROLLBACK, so nothing is left behind.
-- Run on a dev/empty project (the plan test places a few orders on the next
-- Sunday and expects flavor caps to have room).
-- Needs seed_ops.sql loaded (ingredients + the Chimp Chips recipe).
-- ===========================================================================


-- ===========================================================================
-- (r) Security: visitors and non-admins see and change nothing.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid(); other_id uuid := gen_random_uuid();
  n int; ok boolean; h text;
  v_ing bigint := (select id from public.ingredients where name = 'Eggs');
begin
  insert into auth.users (id) values (admin_id), (other_id);
  insert into public.admins (user_id) values (admin_id);

  -- Visitor (anon): blocked from every new table, view and function
  set local role anon;
  begin perform 1 from public.ingredients;     raise exception 'FAIL (r): anon read ingredients';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.ingredient_lots; raise exception 'FAIL (r): anon read lots';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.recipe_items;    raise exception 'FAIL (r): anon read recipe items';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.dough_lots;      raise exception 'FAIL (r): anon read dough';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.ingredient_stock; raise exception 'FAIL (r): anon read stock view';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.flavor_costing;  raise exception 'FAIL (r): anon read costing view';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_production_plan(current_date); raise exception 'FAIL (r): anon ran the plan';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_receive_stock(v_ing, 10, null, current_date + 5); raise exception 'FAIL (r): anon added stock';
  exception when insufficient_privilege then null; end;
  raise notice 'PASS (r): anon is blocked from all back-office tables, views and functions';

  -- Logged in but NOT an admin: sees 0 rows, cannot write, functions say "Not authorized"
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', other_id)::text, true);
  select count(*) into n from public.ingredients;      assert n = 0, 'non-admin saw ingredients';
  select count(*) into n from public.recipe_items;     assert n = 0, 'non-admin saw recipe items';
  select count(*) into n from public.ingredient_stock; assert n = 0, 'non-admin saw the stock view';
  select count(*) into n from public.flavor_costing;   assert n = 0, 'non-admin saw the costing view';
  ok := false;
  begin insert into public.ingredients (name, unit) values ('Hack', 'g'); ok := true;
  exception when others then null; end;
  assert not ok, 'non-admin inserted an ingredient';
  ok := false;
  begin perform public.admin_receive_stock(v_ing, 10, null, current_date + 5); ok := true;
  exception when others then get stacked diagnostics h = message_text; end;
  assert not ok and h = 'Not authorized', 'non-admin must get Not authorized, got ' || coalesce(h, 'success');
  raise notice 'PASS (r): a logged-in non-admin sees 0 rows and gets "Not authorized"';

  -- Admin: can read, and still cannot write stock tables directly (only via functions)
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  select count(*) into n from public.ingredients;   assert n >= 13, 'admin should see the seeded ingredients, saw ' || n;
  select count(*) into n from public.flavor_costing; assert n = 3, 'admin should see 3 flavors in costing, saw ' || n;
  ok := false;
  begin insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining) values (v_ing, 5, 5); ok := true;
  exception when others then null; end;
  assert not ok, 'even an admin must not write lots directly (that skips the stock log)';
  ok := false;
  begin update public.dough_lots set balls_left = 99; ok := true;
  exception when others then null; end;
  assert not ok, 'even an admin must not edit dough directly';
  raise notice 'PASS (r): admin can read; stock and dough only change through the functions';
end $$;
rollback;


-- ===========================================================================
-- (s) Order progress: new > baking > ready > out_for_delivery > completed.
-- Payment status is separate and unchanged.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  o_pick record; o_del record; j jsonb; ord jsonb;
  ok boolean; h text;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);

  set local role anon;
  select * into o_pick from public.place_order('Pia', null, '09175551001', 'pickup', null, '[]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
  select * into o_del from public.place_order('Dan', null, '09175551002', 'delivery', '1 Test St', '[]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  -- Starts as "new"
  j := public.admin_orders(o_pick.sunday_date);
  select e into ord from jsonb_array_elements(j) e where e->>'ref_code' = o_pick.ref_code;
  assert ord->>'prep_status' = 'new', 'a fresh order should be new';

  -- Unpaid orders can't be baked
  ok := false;
  begin perform public.admin_set_order_prep(o_pick.ref_code, 'baking'); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'not_paid', 'unpaid order must not move on, hint was ' || coalesce(h, 'success');
  raise notice 'PASS (s): an unpaid order cannot be moved to baking';

  -- Paid: walk it through
  perform public.admin_set_order_status(o_pick.ref_code, 'paid');
  perform public.admin_set_order_prep(o_pick.ref_code, 'baking');
  perform public.admin_set_order_prep(o_pick.ref_code, 'ready');

  -- A pickup order cannot go out for delivery
  ok := false;
  begin perform public.admin_set_order_prep(o_pick.ref_code, 'out_for_delivery'); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'pickup_order', 'pickup must not go out for delivery, hint was ' || coalesce(h, 'success');

  -- completed stamps completed_at; stepping back clears it
  perform public.admin_set_order_prep(o_pick.ref_code, 'completed');
  select e into ord from jsonb_array_elements(public.admin_orders(o_pick.sunday_date)) e where e->>'ref_code' = o_pick.ref_code;
  assert ord->>'prep_status' = 'completed' and ord->>'completed_at' is not null, 'completed should stamp completed_at';
  assert ord->>'status' = 'paid', 'payment status must be untouched';
  perform public.admin_set_order_prep(o_pick.ref_code, 'ready');
  select e into ord from jsonb_array_elements(public.admin_orders(o_pick.sunday_date)) e where e->>'ref_code' = o_pick.ref_code;
  assert ord->>'completed_at' is null, 'stepping back should clear completed_at';
  raise notice 'PASS (s): pickup flow works, completed_at is stamped and cleared, payment status untouched';

  -- Delivery orders can go out for delivery; delivery details save and clear
  perform public.admin_set_order_status(o_del.ref_code, 'paid');
  perform public.admin_set_order_prep(o_del.ref_code, 'out_for_delivery');
  perform public.admin_set_order_delivery(o_del.ref_code, '  Lalamove ', 'LLM-123', '3-4pm', 'gate code 4521');
  select e into ord from jsonb_array_elements(public.admin_orders(o_del.sunday_date)) e where e->>'ref_code' = o_del.ref_code;
  assert ord->>'courier' = 'Lalamove' and ord->>'delivery_ref' = 'LLM-123'
     and ord->>'delivery_slot' = '3-4pm' and ord->>'admin_note' = 'gate code 4521', 'delivery details should save (trimmed)';
  perform public.admin_set_order_delivery(o_del.ref_code, '', null, '   ', '');
  select e into ord from jsonb_array_elements(public.admin_orders(o_del.sunday_date)) e where e->>'ref_code' = o_del.ref_code;
  assert ord->>'courier' is null and ord->>'delivery_slot' is null and ord->>'admin_note' is null, 'blank should clear';
  ok := false;
  begin perform public.admin_set_order_delivery(o_del.ref_code, repeat('x', 61), null, null, null); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'too_long', 'a 61 character courier name must be refused';
  raise notice 'PASS (s): delivery order, courier details save, trim, clear and length-check';

  -- A cancelled order can only go back to "new"
  perform public.admin_set_order_status(o_del.ref_code, 'cancelled');
  ok := false;
  begin perform public.admin_set_order_prep(o_del.ref_code, 'baking'); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'not_paid', 'a cancelled order must not move on';
  raise notice 'PASS (s): a cancelled order cannot be moved along';
end $$;
rollback;


-- ===========================================================================
-- (t) Inventory, recipes, frozen dough and the production plan.
-- Uses exactly 2 batches' worth of Chimp Chips ingredients so the numbers are easy to check.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  today date := (now() at time zone 'Asia/Manila')::date;
  v_chip bigint := (select id from public.flavors where slug = 'choc-chip');
  v_coco bigint := (select id from public.flavors where slug = 'double-choc');
  butter bigint := (select id from public.ingredients where name = 'Anchor unsalted butter');
  callebaut bigint := (select id from public.ingredients where name = 'Callebaut 811 dark chocolate');
  flour bigint := (select id from public.ingredients where name = 'All-purpose flour');
  bags bigint := (select id from public.ingredients where name = 'Plastic bag (single cookie)');
  lotA bigint; lotB bigint; lot_id bigint;
  rec record; j jsonb; fl jsonb; sh jsonb; n numeric;
  ok boolean; h text; msg text;
  o_a record; o_b record; v_sunday date;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  -- Perishable items need an expiry date
  ok := false;
  begin perform public.admin_receive_stock(butter, 200); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'needs_expiry', 'perishable stock without expiry must be refused, hint ' || coalesce(h, 'success');
  raise notice 'PASS (t): perishable stock needs an expiry date';

  -- FEFO: two butter lots, the earlier-expiring one is used first
  lotA := public.admin_receive_stock(butter, 200, null, today + 5, 'early');
  lotB := public.admin_receive_stock(butter, 400, null, today + 30, 'late');
  perform public.admin_use_stock(butter, 250, 'test');
  reset role;
  assert (select qty_remaining from public.ingredient_lots where id = lotA) = 0,   'early lot should be used up first';
  assert (select qty_remaining from public.ingredient_lots where id = lotB) = 350, 'late lot should have 350 left';
  assert (select sum(delta) from public.stock_log where ingredient_id = butter) = 350, 'log should net to 350';
  raise notice 'PASS (t): stock is used earliest-expiry-first and every change is logged';

  -- Using more than we have fails and changes nothing
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  ok := false;
  begin perform public.admin_use_stock(butter, 9999); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'short_stock', 'over-using must fail';
  reset role;
  assert (select qty_remaining from public.ingredient_lots where id = lotB) = 350, 'a failed use must not change stock';
  raise notice 'PASS (t): using more than we have is refused and changes nothing';

  -- Expired stock is not counted as on hand, and is shown separately
  insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining, expires_on)
  values (butter, 100, 100, today - 1);
  assert (select on_hand from public.ingredient_stock where ingredient_id = butter) = 350, 'expired butter must not count';
  assert (select expired_qty from public.ingredient_stock where ingredient_id = butter) = 100, 'expired butter shown separately';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_discard_lot((select id from public.ingredient_lots where ingredient_id = butter and expires_on = today - 1), 'expired');
  reset role;
  assert (select expired_qty from public.ingredient_stock where ingredient_id = butter) = 0, 'discarded lot is gone';
  raise notice 'PASS (t): expired stock is excluded from on-hand and can be discarded';

  -- Stock take: count down and up
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_receive_stock(flour, 1000);
  perform public.admin_count_stock(flour, 454, 'count');
  reset role;
  assert (select on_hand from public.ingredient_stock where ingredient_id = flour) = 454, 'count down to 454';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_count_stock(flour, 500, 'count');
  reset role;
  assert (select on_hand from public.ingredient_stock where ingredient_id = flour) = 500, 'count up to 500';
  raise notice 'PASS (t): stock take adjusts up and down';

  -- Stock for exactly 2 Chimp Chips batches (butter: top up to 400 usable, flour to 454)
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_receive_stock(butter, 50, null, today + 30);                 -- 350 + 50 = 400
  perform public.admin_count_stock(flour, 454);
  perform public.admin_receive_stock(callebaut, 410, null, today + 60);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Dark brown sugar'), 294);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Granulated sugar'), 146);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Eggs'), 4, null, today + 14);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Vanilla extract'), 3);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Baking soda'), 7.4);
  perform public.admin_receive_stock((select id from public.ingredients where name = 'Fine sea salt'), 7.4);

  -- A flavor with no recipe cannot be recorded
  ok := false;
  begin perform public.admin_record_batch(v_coco, 1); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'no_recipe', 'a flavor without a recipe must be refused';

  -- Asking for 3 batches when we only have 2 batches of stuff: refused, names what's short, nothing changes
  ok := false;
  begin perform public.admin_record_batch(v_chip, 3); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint, msg = message_text; end;
  assert not ok and h = 'short_stock' and msg like 'Short on: %Callebaut%', 'should name the short items, got ' || coalesce(msg, 'success');
  reset role;
  assert (select count(*) from public.dough_lots) = 0, 'a refused batch must not create dough';
  assert (select on_hand from public.ingredient_stock where ingredient_id = callebaut) = 410, 'a refused batch must not use stock';
  raise notice 'PASS (t): a batch with missing ingredients is refused, names what is short, changes nothing';

  -- Record 1 batch: ingredients drop by one batch, 15 dough balls appear with best-by = today + 28
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  lot_id := public.admin_record_batch(v_chip, 1);
  reset role;
  assert (select on_hand from public.ingredient_stock where ingredient_id = callebaut) = 205, 'one batch of Callebaut used';
  assert (select on_hand from public.ingredient_stock where ingredient_id = butter) = 200, 'one batch of butter used';
  assert (select on_hand from public.ingredient_stock where ingredient_id = flour) = 227, 'one batch of flour used';
  select * into rec from public.dough_lots where id = lot_id;
  assert rec.balls_made = 15 and rec.balls_left = 15 and rec.best_by = today + 28, 'dough lot should be 15 balls, best by today + 28';
  raise notice 'PASS (t): recording a batch uses the recipe, adds 15 dough balls with a 28-day best-by';

  -- Take 10 dough balls out to bake: 5 left
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  -- logged to an old Sunday: since 018 the plan subtracts cookies already baked for ITS Sunday
  perform public.admin_use_dough(v_chip, 10, date '2000-01-02');
  ok := false;
  begin perform public.admin_use_dough(v_chip, 6); ok := true;
  exception when others then get stacked diagnostics h = pg_exception_hint; end;
  assert not ok and h = 'no_dough', 'cannot use more dough than exists';
  reset role;
  assert (select sum(balls_left) from public.dough_lots where flavor_id = v_chip) = 5, '5 dough balls should remain';
  raise notice 'PASS (t): dough balls are used up and over-use is refused';

  -- ===== Production plan =====
  -- Order A: box of 12 Chimp Chips (paid). Order B: 3 single Chimp Chips (left unpaid = pending).
  set local role anon;
  select * into o_a from public.place_order('Ann', null, '09175552001', 'pickup', null,
    '[{"size":12,"items":[{"flavor_slug":"choc-chip","qty":12}]}]'::jsonb);
  select * into o_b from public.place_order('Bo', null, '09175552002', 'pickup', null, '[]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":3}]'::jsonb);
  v_sunday := o_a.sunday_date;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_set_order_status(o_a.ref_code, 'paid');

  j := public.admin_production_plan(v_sunday, true);
  select e into fl from jsonb_array_elements(j->'flavors') e where e->>'slug' = 'choc-chip';
  assert (fl->>'paid_cookies')::int = 12 and (fl->>'pending_cookies')::int = 3 and (fl->>'cookies_needed')::int = 15,
    'plan should see 12 paid + 3 pending = 15, got ' || fl::text;
  assert (fl->>'dough_on_hand')::int = 5 and (fl->>'to_make')::int = 10 and (fl->>'batches')::int = 1 and (fl->>'leftover')::int = 5,
    '15 needed - 5 dough = 10 to make = 1 batch, 5 spare, got ' || fl::text;
  select e into fl from jsonb_array_elements(j->'flavors') e where e->>'slug' = 'double-choc';
  assert (fl->>'recipe_ready')::boolean = false, 'Coco Loco has no recipe yet, plan must say so';
  raise notice 'PASS (t): plan = cookies ordered minus frozen dough, rounded up to batches; flags flavors with no recipe';

  -- Shopping list: 1 batch needs 205g Callebaut (have exactly 205 left) and 15 bags (have none)
  select e into sh from jsonb_array_elements(j->'shopping') e where e->>'name' like 'Callebaut%';
  assert (sh->>'needed')::numeric = 205 and (sh->>'on_hand')::numeric = 205 and (sh->>'packs_to_buy')::numeric = 0,
    'Callebaut: need 205, have 205, buy 0, got ' || sh::text;
  select e into sh from jsonb_array_elements(j->'shopping') e where e->>'name' like 'Plastic bag%';
  assert (sh->>'needed')::numeric = 15 and (sh->>'short')::numeric = 15 and (sh->>'packs_to_buy')::numeric = 1
     and (sh->>'est_cost')::numeric = 33, 'bags: need 15, buy 1 pack of 100 for 33, got ' || sh::text;
  raise notice 'PASS (t): shopping list subtracts stock and rounds up to whole packs';

  -- Paid only: 12 needed - 5 dough = 7 to make = still 1 batch
  j := public.admin_production_plan(v_sunday, false);
  select e into fl from jsonb_array_elements(j->'flavors') e where e->>'slug' = 'choc-chip';
  assert (fl->>'cookies_needed')::int = 12 and (fl->>'to_make')::int = 7 and (fl->>'batches')::int = 1, 'paid-only plan, got ' || fl::text;
  raise notice 'PASS (t): plan can leave out unpaid orders';

  -- Stock that expires before the Sunday does not count toward the plan
  reset role;
  insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining, expires_on)
  values (callebaut, 1000, 1000, v_sunday - 1);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  j := public.admin_production_plan(v_sunday, true);
  select e into sh from jsonb_array_elements(j->'shopping') e where e->>'name' like 'Callebaut%';
  assert (sh->>'on_hand')::numeric = 205, 'stock expiring before the Sunday must not count, got ' || sh::text;
  raise notice 'PASS (t): stock that expires before the Sunday is not counted';

  -- Dough that is past best-by before the Sunday doesn't count either
  reset role;
  update public.dough_lots set best_by = v_sunday - 1 where flavor_id = v_chip;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  j := public.admin_production_plan(v_sunday, true);
  select e into fl from jsonb_array_elements(j->'flavors') e where e->>'slug' = 'choc-chip';
  assert (fl->>'dough_on_hand')::int = 0 and (fl->>'batches')::int = 1, 'old dough must not count, got ' || fl::text;
  raise notice 'PASS (t): dough that is past best-by by the Sunday is not counted';
end $$;
rollback;


-- ===========================================================================
-- (u) Costing: the Chimp Chips batch matches the pricing sheet (about P561 per batch, P37 per cookie).
-- ===========================================================================
begin;
do $$
declare r record;
begin
  select * into r from public.flavor_costing where slug in ('choc-chip', 'chimp-chips');
  -- run as the SQL-editor superuser, which bypasses RLS, so the view returns rows
  assert r.batch_cost between 560 and 562, 'Chimp Chips batch should be about 561, got ' || r.batch_cost;
  assert r.ingredient_cost_per_cookie between 37 and 38, 'about 37.40 per cookie, got ' || r.ingredient_cost_per_cookie;
  assert r.packaging_cost_per_cookie = 0.33, 'one plastic bag = 0.33, got ' || r.packaging_cost_per_cookie;
  assert r.assumed_prices >= 1, 'the sheet marks several prices as assumed';
  raise notice 'PASS (u): Chimp Chips costs % per batch, % per cookie (+% packaging), % assumed prices',
    r.batch_cost, r.ingredient_cost_per_cookie, r.packaging_cost_per_cookie, r.assumed_prices;
end $$;
rollback;
