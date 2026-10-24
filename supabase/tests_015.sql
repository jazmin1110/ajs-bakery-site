-- ===========================================================================
-- tests_015.sql: proves migration 015 works (manual orders, packaging, restock,
-- best sellers). Same rules as tests.sql: paste ONE block at a time; each ends in
-- ROLLBACK. Run on a dev/empty project after seed_ops.sql. Flavor slugs are read
-- from the flavors table, so it works with old or new slugs.
-- ===========================================================================


-- ===========================================================================
-- (v) Manual orders: admin only, prices from the DB, cap enforced (with override),
--     payment options, phone optional.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid(); other_id uuid := gen_random_uuid();
  s1 text := (select slug from public.flavors where id = (select min(id) from public.flavors where active));
  bu text := (select slug from public.flavors where surcharge > 0 order by id limit 1);
  sun date := public.ordering_sunday() + 7;  -- a week after the open Sunday: empty
  r record; o public.orders; h text; n int;
begin
  insert into auth.users (id) values (admin_id), (other_id);
  insert into public.admins (user_id) values (admin_id);

  set local role anon;
  begin
    perform * from public.admin_create_order(sun, 'X', null, null, 'instagram', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'unpaid');
    raise exception 'FAIL (v): anon created an order';
  exception when insufficient_privilege then null; end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', other_id)::text, true);
  begin
    perform * from public.admin_create_order(sun, 'X', null, null, 'instagram', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'unpaid');
    raise exception 'FAIL (v): non-admin created an order';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  -- Paid by cash, no phone, a box of 3 (2 Bueno + 1 other) + 2 singles: total from the DB
  select * into r from public.admin_create_order(sun, 'Walk In', null, '@walkin', 'walk_in', 'pickup', null,
    jsonb_build_array(jsonb_build_object('size', 3, 'items', jsonb_build_array(
      jsonb_build_object('flavor_slug', bu, 'qty', 2), jsonb_build_object('flavor_slug', s1, 'qty', 1)))),
    jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 2)),
    'paid', 'cash');
  select * into o from public.orders where ref_code = r.ref_code;
  if o.status <> 'paid' or o.payment_method <> 'cash' or o.source <> 'walk_in' or o.phone is not null then
    raise exception 'FAIL (v): saved wrong (% % % %)', o.status, o.payment_method, o.source, o.phone;
  end if;
  if r.total <> (300 + 2 * (select surcharge from public.flavors where slug = bu))
               + 2 * (select single_price from public.flavors where slug = s1) then
    raise exception 'FAIL (v): total % not priced by the DB', r.total;
  end if;

  -- Pays on the day: pending, holds the slot until that Sunday 6pm
  select * into r from public.admin_create_order(sun, 'Later', '09170000001', null, 'messenger', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'pay_on_day');
  select * into o from public.orders where ref_code = r.ref_code;
  if o.status <> 'pending' or o.expires_at <> ((sun + time '18:00') at time zone 'Asia/Manila') then
    raise exception 'FAIL (v): pay_on_day should hold until Sunday 6pm (got % %)', o.status, o.expires_at;
  end if;

  -- Cap: this Sunday now has 4 of s1. 12 more = 16 > 15 -> refused, unless overridden
  begin
    perform * from public.admin_create_order(sun, 'Big', null, null, 'instagram', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 12)), 'unpaid');
    raise exception 'FAIL (v): over-cap order was allowed';
  exception when others then
    get stacked diagnostics h = pg_exception_hint;
    if h <> 'flavor_cap' then raise; end if;
  end;
  perform * from public.admin_create_order(sun, 'Big', null, null, 'instagram', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 12)), 'unpaid', p_allow_over_cap => true);

  -- Bad input
  begin
    perform * from public.admin_create_order(sun + 1, 'X', null, null, 'instagram', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'unpaid');
    raise exception 'FAIL (v): a Monday was accepted';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'invalid_sunday' then raise; end if; end;
  begin
    perform * from public.admin_create_order(sun, 'X', null, null, 'instagram', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'paid');
    raise exception 'FAIL (v): paid without a method was accepted';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'invalid_payment' then raise; end if; end;
  begin
    perform * from public.admin_create_order(sun, 'X', null, null, 'website', 'pickup', null,
      '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 1)), 'unpaid');
    raise exception 'FAIL (v): source website was accepted';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'invalid_source' then raise; end if; end;

  -- Website orders still need a phone (table rule)
  reset role;
  begin
    insert into public.orders (ref_code, sunday_date, name, fulfillment, total) values ('AJ-TSTNOP', sun, 'No Phone', 'pickup', 1);
    raise exception 'FAIL (v): website order without phone saved';
  exception when check_violation then null; end;

  -- admin_orders shows the new fields
  set local role authenticated;
  select count(*) into n from jsonb_array_elements(public.admin_orders(sun)) e where e ? 'source' and e ? 'payment_method';
  if n <> 3 then raise exception 'FAIL (v): admin_orders missing source/payment_method (%)', n; end if;

  reset role;
  raise notice 'PASS (v) manual orders';
end $$;
rollback;


-- ===========================================================================
-- (w) Packaging leaves stock when baking; shopping list tops up to reorder level.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  f_id bigint := (select r.flavor_id from public.recipes r where exists (select 1 from public.recipe_items ri where ri.flavor_id = r.flavor_id) limit 1);
  bag bigint := (select id from public.ingredients where per_cookie > 0 limit 1);
  flour bigint := (select id from public.ingredients where name = 'All-purpose flour');
  sun date := public.ordering_sunday() + 21;
  before numeric; after numeric; plan jsonb; row jsonb;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  perform public.admin_receive_stock(bag, 100);
  perform public.admin_record_batch(f_id, 1, p_force => true);          -- 15 dough balls
  select on_hand into before from public.ingredient_stock where ingredient_id = bag;
  perform public.admin_use_dough(f_id, 10);
  select on_hand into after from public.ingredient_stock where ingredient_id = bag;
  if before - after <> 10 then raise exception 'FAIL (w): baking 10 took % bags, expected 10', before - after; end if;

  -- Baking with no bags logged still works (takes what's there)
  perform public.admin_use_stock(bag, after);
  perform public.admin_use_dough(f_id, 5);

  -- Reorder level: flour low, nothing ordered -> still on the list, topped up to the level
  reset role;
  update public.ingredients set reorder_level = 2000 where id = flour;
  set local role authenticated;
  plan := public.admin_production_plan(sun);
  select e into row from jsonb_array_elements(plan -> 'shopping') e where (e ->> 'ingredient_id')::bigint = flour;
  if row is null then raise exception 'FAIL (w): low flour not on the list'; end if;
  if (row ->> 'topup')::boolean is not true or (row ->> 'short')::numeric < 2000 - (row ->> 'on_hand')::numeric then
    raise exception 'FAIL (w): flour top-up wrong: %', row;
  end if;

  reset role;
  raise notice 'PASS (w) packaging + restock';
end $$;
rollback;


-- ===========================================================================
-- (x) Best sellers: counts paid orders only, ranks by cookies, splits box/single,
--     revenue includes the surcharge, sold-out weeks counted. Admin only.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  s1 text := (select slug from public.flavors where id = (select min(id) from public.flavors where active));
  bu text := (select slug from public.flavors where surcharge > 0 order by id limit 1);
  sun date := public.ordering_sunday() + 14;
  rep jsonb; top jsonb; b jsonb;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role anon;
  begin perform public.admin_sales_report(sun, sun); raise exception 'FAIL (x): anon read sales';
  exception when insufficient_privilege then null; end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  -- 15 of s1 (sold out), paid; 2 Bueno in a box of 3, paid; 5 of s1 unpaid (not counted)
  perform * from public.admin_create_order(sun, 'A', null, null, 'instagram', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 14)), 'paid', 'gcash');
  perform * from public.admin_create_order(sun, 'B', null, null, 'instagram', 'pickup', null,
    jsonb_build_array(jsonb_build_object('size', 3, 'items', jsonb_build_array(
      jsonb_build_object('flavor_slug', bu, 'qty', 2), jsonb_build_object('flavor_slug', s1, 'qty', 1)))),
    '[]', 'paid', 'cash');
  perform * from public.admin_create_order(sun + 7, 'C', null, null, 'instagram', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 5)), 'unpaid');

  rep := public.admin_sales_report(sun, sun + 7);
  top := rep -> 'flavors' -> 0;
  if top ->> 'slug' <> s1 or (top ->> 'cookies')::int <> 15 then raise exception 'FAIL (x): top should be % with 15: %', s1, top; end if;
  if (top ->> 'as_singles')::int <> 14 or (top ->> 'in_boxes')::int <> 1 then raise exception 'FAIL (x): box/single split wrong: %', top; end if;
  if (top ->> 'sold_out_weeks')::int <> 1 then raise exception 'FAIL (x): sold-out week not counted: %', top; end if;
  if (rep ->> 'total_orders')::int <> 2 then raise exception 'FAIL (x): unpaid order counted'; end if;

  select e into b from jsonb_array_elements(rep -> 'flavors') e where e ->> 'slug' = bu;
  -- box of 3 = 300 + 2 x 25; each cookie 100 base, Bueno gets +25 -> 2 x 125 = 250
  if (b ->> 'revenue')::numeric <> 2 * (100 + (select surcharge from public.flavors where slug = bu)) then
    raise exception 'FAIL (x): Bueno revenue % wrong', b ->> 'revenue';
  end if;
  if (rep ->> 'total_cookies')::int <> 17 then raise exception 'FAIL (x): total cookies %', rep ->> 'total_cookies'; end if;

  reset role;
  raise notice 'PASS (x) best sellers';
end $$;
rollback;
