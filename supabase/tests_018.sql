-- ===========================================================================
-- tests_018.sql: proves migration 018 works (bake plan counts what's baked,
-- delete / change unit of a stock item, edit an order, reopen over the cap).
-- Same rules as tests.sql: paste ONE block at a time; each ends in ROLLBACK.
-- Run on a dev/empty project after seed.sql and seed_ops.sql.
-- ===========================================================================


-- ===========================================================================
-- (a) Bake plan: cookies already baked for the Sunday aren't asked for again
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  wk   date := (now() at time zone 'Asia/Manila')::date + (7 - extract(dow from (now() at time zone 'Asia/Manila'))::int) % 7 + 7;
  f_id bigint := (select id from public.flavors where slug = 'choc-chip');
  it record; plan jsonb; pf jsonb; bag jsonb; y int;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  select yield into y from public.recipes where flavor_id = f_id;

  -- Plenty of stock, so nothing is short
  for it in select ri.ingredient_id as id, ri.qty_per_batch as q, i.perishable from public.recipe_items ri
            join public.ingredients i on i.id = ri.ingredient_id where ri.flavor_id = f_id loop
    perform public.admin_receive_stock(it.id, it.q * 5, null, case when it.perishable then wk + 30 end);
  end loop;

  -- 10 Chimp Chips ordered and paid
  perform * from public.admin_create_order(wk, 'Plan test', null, null, 'walk_in', 'pickup', null,
    '[]', '[{"flavor_slug":"choc-chip","qty":10}]', 'paid', 'cash', p_allow_over_cap => true);

  plan := public.admin_production_plan(wk);
  select e into pf from jsonb_array_elements(plan -> 'flavors') e where (e ->> 'flavor_id')::bigint = f_id;
  if (pf ->> 'to_make')::int <> 10 or (pf ->> 'baked')::int <> 0 then raise exception 'FAIL (a): before baking %', pf; end if;

  -- Make one batch, bake the 10 for that Sunday
  perform public.admin_record_batch(f_id, 1);
  perform public.admin_use_dough(f_id, 10, wk);

  plan := public.admin_production_plan(wk);
  select e into pf from jsonb_array_elements(plan -> 'flavors') e where (e ->> 'flavor_id')::bigint = f_id;
  if (pf ->> 'baked')::int <> 10 or (pf ->> 'still_to_bake')::int <> 0
     or (pf ->> 'to_make')::int <> 0 or (pf ->> 'batches')::int <> 0 then
    raise exception 'FAIL (a): after baking all 10 the plan still asks for more %', pf;
  end if;
  if (pf ->> 'dough_on_hand')::int <> y - 10 then raise exception 'FAIL (a): spare dough %', pf; end if;
  -- Bags: the 10 baked already took theirs, so the plan needs none for them
  select e into bag from jsonb_array_elements(plan -> 'shopping') e where e ->> 'name' = 'Plastic bag (single cookie)';
  if bag is not null and (bag ->> 'needed')::numeric <> 0 then raise exception 'FAIL (a): bags counted again %', bag; end if;
  if (plan -> 'totals' ->> 'baked')::int < 10 then raise exception 'FAIL (a): totals.baked %', plan -> 'totals'; end if;

  -- 3 more ordered: only those 3 are left to bake, and the spare dough covers them
  perform * from public.admin_create_order(wk, 'Plan test 2', null, null, 'walk_in', 'pickup', null,
    '[]', '[{"flavor_slug":"choc-chip","qty":3}]', 'paid', 'cash', p_allow_over_cap => true);
  plan := public.admin_production_plan(wk);
  select e into pf from jsonb_array_elements(plan -> 'flavors') e where (e ->> 'flavor_id')::bigint = f_id;
  if (pf ->> 'still_to_bake')::int <> 3 or (pf ->> 'to_make')::int <> greatest(3 - (y - 10), 0) then
    raise exception 'FAIL (a): 3 more ordered %', pf;
  end if;

  reset role;
  raise notice 'PASS (a) bake plan counts what is already baked';
end $$;
rollback;


-- ===========================================================================
-- (b) Delete a stock item: only when it was never used; locked down
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  t1 bigint; t2 bigint; h text;
  butter bigint := (select id from public.ingredients where name = 'Anchor unsalted butter');
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);

  set local role anon;
  begin perform public.admin_delete_ingredient(1); raise exception 'FAIL (b): anon deleted an item';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_change_unit(1, 'g', 1); raise exception 'FAIL (b): anon changed a unit';
  exception when insufficient_privilege then null; end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  insert into public.ingredients (name, unit) values ('Typo item', 'g') returning id into t1;
  perform public.admin_delete_ingredient(t1);
  if exists (select 1 from public.ingredients where id = t1) then raise exception 'FAIL (b): unused item not deleted'; end if;

  insert into public.ingredients (name, unit) values ('Bought once', 'g') returning id into t2;
  perform public.admin_receive_stock(t2, 100, 1);
  begin perform public.admin_delete_ingredient(t2); raise exception 'FAIL (b): item with purchases deleted';
  exception when others then get stacked diagnostics h = pg_exception_hint;
    if h <> 'has_history' then raise; end if; end;

  begin perform public.admin_delete_ingredient(butter); raise exception 'FAIL (b): recipe item deleted';
  exception when others then get stacked diagnostics h = pg_exception_hint;
    if h <> 'in_recipe' then raise; end if; end;

  reset role;
  raise notice 'PASS (b) delete item';
end $$;
rollback;


-- ===========================================================================
-- (c) Change a unit: every amount converts, money stays the same
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  eggs bigint := (select id from public.ingredients where name = 'Eggs');
  f_id bigint := (select id from public.flavors where slug = 'choc-chip');
  before_ing public.ingredients; after_ing public.ingredients;
  v1 numeric; v2 numeric; c1 numeric; c2 numeric; q1 numeric; q2 numeric; h text;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  perform public.admin_count_stock(eggs, 0);
  perform public.admin_receive_stock(eggs, 30, 10, current_date + 20);     -- 30 eggs at P10 each
  perform public.admin_use_stock(eggs, 4);
  update public.ingredients set reorder_level = 6 where id = eggs;
  select * into before_ing from public.ingredients where id = eggs;
  select stock_value into v1 from public.ingredient_stock where ingredient_id = eggs;
  select batch_cost into c1 from public.flavor_costing where flavor_id = f_id;
  select qty_per_batch into q1 from public.recipe_items where flavor_id = f_id and ingredient_id = eggs;

  perform public.admin_change_unit(eggs, 'g', 50);                           -- 1 egg = 50 g

  select * into after_ing from public.ingredients where id = eggs;
  select stock_value into v2 from public.ingredient_stock where ingredient_id = eggs;
  select batch_cost into c2 from public.flavor_costing where flavor_id = f_id;
  select qty_per_batch into q2 from public.recipe_items where flavor_id = f_id and ingredient_id = eggs;
  if after_ing.unit <> 'g' or after_ing.pack_size <> before_ing.pack_size * 50
     or after_ing.reorder_level <> 300 or after_ing.pack_price <> before_ing.pack_price then
    raise exception 'FAIL (c): item not converted %', row_to_json(after_ing);
  end if;
  if (select on_hand from public.ingredient_stock where ingredient_id = eggs) <> 26 * 50 then raise exception 'FAIL (c): stock not converted'; end if;
  if v1 <> v2 then raise exception 'FAIL (c): stock value changed % -> %', v1, v2; end if;
  if q1 is not null and (q2 <> q1 * 50 or abs(c1 - c2) > 0.01) then raise exception 'FAIL (c): recipe % -> %, cost % -> %', q1, q2, c1, c2; end if;
  if (select sum(delta) from public.stock_log where ingredient_id = eggs) <> 26 * 50 then raise exception 'FAIL (c): log not converted'; end if;

  begin perform public.admin_change_unit(eggs, 'g', 2); raise exception 'FAIL (c): same unit accepted';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'bad_unit' then raise; end if; end;
  begin perform public.admin_change_unit(eggs, 'pc', 0); raise exception 'FAIL (c): factor 0 accepted';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'bad_factor' then raise; end if; end;

  reset role;
  raise notice 'PASS (c) change unit';
end $$;
rollback;


-- ===========================================================================
-- (d) Edit an order: details, cookies (re-priced), move Sunday, cap, reopen
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  wk  date := (now() at time zone 'Asia/Manila')::date + (7 - extract(dow from (now() at time zone 'Asia/Manila'))::int) % 7 + 7;
  ref text; ref2 text; r record; o public.orders; h text; cap int;
  p_single numeric := (select single_price from public.flavors where slug = 'double-choc');
  p_box3   numeric := (select price from public.boxes where size = 3 and active);
  bueno_extra numeric := (select surcharge from public.flavors where slug = 'kinder-bueno');
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);

  set local role anon;
  begin perform * from public.admin_update_order('X', 'a', null, null, 'pickup', null); raise exception 'FAIL (d): anon edited an order';
  exception when insufficient_privilege then null; end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  select weekly_cap into cap from public.flavors where slug = 'double-choc';

  select x.ref_code into ref from public.admin_create_order(wk, 'Ana', null, null, 'instagram', 'pickup', null,
    '[]', '[{"flavor_slug":"double-choc","qty":2}]', 'paid', 'gcash') x;

  -- Details only: delivery + address; cookies and total untouched
  select * into r from public.admin_update_order(ref, 'Ana Cruz', '09171234567', '@ana', 'delivery', 'Makati');
  select * into o from public.orders where ref_code = ref;
  if o.name <> 'Ana Cruz' or o.fulfillment <> 'delivery' or o.address <> 'Makati' or o.total <> 2 * p_single or r.total <> r.old_total then
    raise exception 'FAIL (d): details %', row_to_json(o);
  end if;
  begin perform * from public.admin_update_order(ref, 'Ana', null, null, 'delivery', ''); raise exception 'FAIL (d): delivery without address';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'address_required' then raise; end if; end;

  -- New cookies: a box of 3 with 1 Bueno, re-priced; the old singles are gone
  select * into r from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, null,
    '[{"size":3,"items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":1}],"gift_note":"Happy bday"}]', '[]');
  if r.total <> p_box3 + bueno_extra or r.old_total <> 2 * p_single then raise exception 'FAIL (d): re-price %', row_to_json(r); end if;
  if (select count(*) from public.order_items i join public.orders x on x.id = i.order_id where x.ref_code = ref and i.order_box_id is null) <> 0
     or (select gift_note from public.order_boxes b join public.orders x on x.id = b.order_id where x.ref_code = ref) <> 'Happy bday' then
    raise exception 'FAIL (d): items not replaced';
  end if;

  -- Cap: fill double-choc, then try to add more to Ana's order
  select x.ref_code into ref2 from public.admin_create_order(wk, 'Filler', null, null, 'walk_in', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', 'double-choc', 'qty', cap)), 'paid', 'cash', p_allow_over_cap => true) x;
  begin
    perform * from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, null, '[]', '[{"flavor_slug":"double-choc","qty":1}]');
    raise exception 'FAIL (d): edit went over the cap';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'flavor_cap' then raise; end if; end;
  perform * from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, null, '[]',
    '[{"flavor_slug":"double-choc","qty":1}]', true);                        -- "add anyway"

  -- Its own cookies don't count against it: with Ana cancelled, re-saving the full filler is fine
  perform public.admin_set_order_status(ref, 'cancelled');
  perform * from public.admin_update_order(ref2, 'Filler', null, null, 'pickup', null, null, '[]',
    jsonb_build_array(jsonb_build_object('flavor_slug', 'double-choc', 'qty', cap)));

  -- Reopen Ana while double-choc is full: blocked, then allowed on purpose
  begin perform public.admin_set_order_status(ref, 'paid'); raise exception 'FAIL (d): reopened over cap';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'flavor_cap' then raise; end if; end;
  perform public.admin_set_order_status(ref, 'paid', true);
  if (select status from public.orders where ref_code = ref) <> 'paid' then raise exception 'FAIL (d): over-cap reopen not saved'; end if;

  -- Move to the next Sunday
  select * into r from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, wk + 7);
  if (select sunday_date from public.orders where ref_code = ref) <> wk + 7 or r.sunday_date <> wk + 7 then raise exception 'FAIL (d): move'; end if;
  begin perform * from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, wk + 1); raise exception 'FAIL (d): moved to a Monday';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'invalid_sunday' then raise; end if; end;

  -- An empty order is refused (cancel it instead)
  begin perform * from public.admin_update_order(ref, 'Ana Cruz', null, null, 'pickup', null, null, '[]', '[]'); raise exception 'FAIL (d): emptied an order';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'empty_order' then raise; end if; end;

  reset role;
  raise notice 'PASS (d) edit order';
end $$;
rollback;
