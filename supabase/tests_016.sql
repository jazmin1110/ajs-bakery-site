-- ===========================================================================
-- tests_016.sql: proves migration 016 works (purchases, fixes, real cost,
-- waste, profit, shopping trip). Same rules as tests.sql: paste ONE block at a
-- time; each ends in ROLLBACK. Run on a dev/empty project after seed_ops.sql.
-- ===========================================================================


-- ===========================================================================
-- (y) Purchases: price + pack size remembered, fix / remove, recount expiry,
--     stock value, shopping trip all-or-nothing, locked down.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  flour  bigint := (select id from public.ingredients where name = 'All-purpose flour');
  butter bigint := (select id from public.ingredients where name = 'Anchor unsalted butter');
  l1 bigint; l2 bigint; v numeric; h text; r public.ingredient_lots; n int;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);

  set local role anon;
  begin perform public.admin_fix_lot(1, 1); raise exception 'FAIL (y): anon fixed a purchase';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_money_report(current_date, current_date); raise exception 'FAIL (y): anon read money';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_receive_many('[]'); raise exception 'FAIL (y): anon received stock';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.bake_log; raise exception 'FAIL (y): anon read bake log';
  exception when insufficient_privilege then null; end;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  perform public.admin_count_stock(flour, 0);                       -- start from nothing

  -- 2 packs (2000 g) for P200 -> P0.10/g, item price P100 per 1kg pack
  l1 := public.admin_receive_stock(flour, 2000, 200.0 / 2000);
  select * into r from public.ingredient_lots where id = l1;
  if r.paid_total <> 200 or r.pack_size_bought is not null then raise exception 'FAIL (y): lot 1 saved wrong %', row_to_json(r); end if;
  if (select pack_price from public.ingredients where id = flour) <> 100 then raise exception 'FAIL (y): item price not updated'; end if;

  -- A 500 g pack (not the usual 1 kg) for P60 -> P0.12/g -> item price P120 per usual 1 kg pack
  l2 := public.admin_receive_stock(flour, 500, 60.0 / 500, p_pack_size => 500);
  select * into r from public.ingredient_lots where id = l2;
  if r.pack_size_bought <> 500 or r.paid_total <> 60 then raise exception 'FAIL (y): lot 2 saved wrong %', row_to_json(r); end if;
  if (select pack_price from public.ingredients where id = flour) <> 120 then raise exception 'FAIL (y): price not per usual pack'; end if;
  if (select stock_value from public.ingredient_stock where ingredient_id = flour) <> 260 then raise exception 'FAIL (y): stock value wrong'; end if;

  -- Use 1500 g (oldest purchase first), then fix purchase 1
  perform public.admin_use_stock(flour, 1500);
  begin perform public.admin_fix_lot(l1, 1000); raise exception 'FAIL (y): fixed below what was used';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'already_used' then raise; end if; end;
  perform public.admin_fix_lot(l1, 1800);
  select * into r from public.ingredient_lots where id = l1;
  if r.qty_remaining <> 300 or r.paid_total <> 180 then raise exception 'FAIL (y): fix amount wrong %', row_to_json(r); end if;

  -- Price fix on the latest purchase moves the item price; on an older one it doesn't
  perform public.admin_fix_lot(l2, p_unit_cost => 0.2);
  if (select pack_price from public.ingredients where id = flour) <> 200 then raise exception 'FAIL (y): latest price fix not applied'; end if;
  perform public.admin_fix_lot(l1, p_unit_cost => 0.05);
  if (select pack_price from public.ingredients where id = flour) <> 200 then raise exception 'FAIL (y): old purchase changed the price'; end if;

  -- Remove: only if nothing was used
  begin perform public.admin_fix_lot(l1, p_remove => true); raise exception 'FAIL (y): removed a used purchase';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'already_used' then raise; end if; end;
  perform public.admin_fix_lot(l2, p_remove => true);
  if (select pack_price from public.ingredients where id = flour) <> 50 then
    raise exception 'FAIL (y): removing the latest purchase should bring back the price before it';
  end if;
  if (select on_hand from public.ingredient_stock where ingredient_id = flour) <> 300 then raise exception 'FAIL (y): removed purchase still counted'; end if;

  -- Recount: extra butter (perishable) needs an expiry date
  begin perform public.admin_count_stock(butter, 999999); raise exception 'FAIL (y): extra perishable without expiry';
  exception when others then get stacked diagnostics h = pg_exception_hint; if h <> 'needs_expiry' then raise; end if; end;
  perform public.admin_count_stock(butter, 999999, null, current_date + 10);

  -- Shopping trip: one bad line (butter without expiry) -> nothing saved
  select count(*) into n from public.ingredient_lots;
  begin
    perform public.admin_receive_many(jsonb_build_array(
      jsonb_build_object('ingredient_id', flour, 'qty', 1000, 'unit_cost', 0.1),
      jsonb_build_object('ingredient_id', butter, 'qty', 200)));
    raise exception 'FAIL (y): bad shopping trip saved';
  exception when others then
    get stacked diagnostics h = pg_exception_hint;
    if h <> 'bad_line' or sqlerrm not like 'Anchor unsalted butter:%' then raise; end if;
  end;
  if (select count(*) from public.ingredient_lots) <> n then raise exception 'FAIL (y): part of a bad trip saved'; end if;
  if public.admin_receive_many(jsonb_build_array(
       jsonb_build_object('ingredient_id', flour, 'qty', 1000, 'unit_cost', 0.1),
       jsonb_build_object('ingredient_id', butter, 'qty', 200, 'expires_on', current_date + 9))) <> 2 then
    raise exception 'FAIL (y): good trip not saved';
  end if;

  reset role;
  raise notice 'PASS (y) purchases';
end $$;
rollback;


-- ===========================================================================
-- (z) Real cost: dough uses the price of the exact purchases it took (oldest
--     expiry first), baking and thrown dough are logged per Sunday, profit adds up.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid();
  f_id   bigint := (select id from public.flavors where slug in ('choc-chip', 'chimp-chips') order by id limit 1);
  butter bigint := (select id from public.ingredients where name = 'Anchor unsalted butter');
  bag    bigint := (select id from public.ingredients where per_cookie > 0 order by id limit 1);
  s1     text := (select slug from public.flavors where id = (select min(id) from public.flavors where active));
  wk     date := public._week_sunday(now());
  it record; d1 bigint; d2 bigint; c1 numeric; c2 numeric; other numeric := 0; rep jsonb; w jsonb; o record;
begin
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);

  -- Empty every recipe item + bags, then buy known prices. Butter twice: P1/g (expires first), then P2/g.
  for it in select ri.ingredient_id as id, ri.qty_per_batch as q, i.perishable from public.recipe_items ri
            join public.ingredients i on i.id = ri.ingredient_id where ri.flavor_id = f_id loop
    perform public.admin_count_stock(it.id, 0);
    if it.id <> butter then
      perform public.admin_receive_stock(it.id, it.q * 2, 0.01, case when it.perishable then current_date + 30 end);
      other := other + it.q * 0.01;
    end if;
  end loop;
  perform public.admin_receive_stock(butter, 200, 1.0, current_date + 10);
  perform public.admin_receive_stock(butter, 200, 2.0, current_date + 20);
  perform public.admin_count_stock(bag, 0);
  perform public.admin_receive_stock(bag, 100, 0.5);

  d1 := public.admin_record_batch(f_id, 1);
  d2 := public.admin_record_batch(f_id, 1);
  select cost_per_ball into c1 from public.dough_lots where id = d1;
  select cost_per_ball into c2 from public.dough_lots where id = d2;
  if c1 <> round((200 * 1.0 + other) / 15, 4) then raise exception 'FAIL (z): batch 1 cost % (should use P1 butter)', c1; end if;
  if c2 <> round((200 * 2.0 + other) / 15, 4) then raise exception 'FAIL (z): batch 2 cost % (should use P2 butter)', c2; end if;

  -- Bake 10 (from batch 1), throw the other 5 of batch 1 away
  perform public.admin_use_dough(f_id, 10);
  select * into o from public.bake_log where kind = 'baked' order by id desc limit 1;
  if o.ingredient_cost <> round(10 * c1, 2) or o.packaging_cost <> 5.00 or o.sunday <> wk or o.estimated then
    raise exception 'FAIL (z): bake log wrong %', row_to_json(o);
  end if;
  perform public.admin_discard_dough(d1);
  if (select ingredient_cost from public.bake_log where kind = 'dough_thrown' order by id desc limit 1) <> round(5 * c1, 2) then
    raise exception 'FAIL (z): thrown dough not costed';
  end if;

  -- A paid order for this week, then the money report
  perform * from public.admin_create_order(wk, 'Cash', null, null, 'walk_in', 'pickup', null,
    '[]', jsonb_build_array(jsonb_build_object('flavor_slug', s1, 'qty', 2)), 'paid', 'cash', p_allow_over_cap => true);
  rep := public.admin_money_report(wk, wk);
  w := rep -> 'weeks' -> 0;
  if (w ->> 'cookie_cost')::numeric <> round(10 * c1, 2) + 5 then raise exception 'FAIL (z): cookie cost %', w; end if;
  if (w ->> 'waste')::numeric <> round(5 * c1, 2) then raise exception 'FAIL (z): waste %', w; end if;
  if (w ->> 'money_in')::numeric < 2 * (select single_price from public.flavors where slug = s1) then raise exception 'FAIL (z): money in %', w; end if;
  if (w ->> 'profit')::numeric <> (w ->> 'money_in')::numeric - (w ->> 'cookie_cost')::numeric
                                  - (w ->> 'waste')::numeric + (w ->> 'recount')::numeric then
    raise exception 'FAIL (z): profit doesn''t add up %', w;
  end if;
  if (w ->> 'spent')::numeric <= 0 then raise exception 'FAIL (z): purchases not counted as spent'; end if;

  reset role;
  raise notice 'PASS (z) real cost + profit';
end $$;
rollback;
