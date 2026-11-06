-- ===========================================================================
-- 028: packaging rules. Bags, stickers, boxes and cards are used per single cookie,
-- per box (optionally one box size), per order or per gift note, not just "per cookie".
--
-- Before: ingredients.per_cookie was the only rule, so every cookie counted a bag and a
-- sticker (even cookies inside a box), and boxes / thank-you cards weren't tracked.
--
-- Now: packaging_rules says how each packaging item is used. One item can have several
-- rules (the sticker: 1 per single cookie AND 1 per box).
--   cookie    = every cookie baked          (taken out of stock at "I baked these", like before)
--   single    = every loose single cookie   (taken out when the order is packed)
--   box       = every box, or only boxes of box_size   (taken out when the order is packed)
--   order     = once per order, e.g. a thank-you card  (taken out when the order is packed)
--   gift_note = every box that has a gift note          (taken out when the order is packed)
-- "Packed" = the first time an order moves to Ready, Out for delivery or Done. It happens
-- once per order (orders.packed_at), and what it cost is kept on the order
-- (orders.packaging_cost) so the Sales page can count it against that Sunday.
--
-- ingredients.per_cookie is kept (old code reads it) but no longer used: its values move
-- into 'cookie' rules and it is set to 0.
-- ===========================================================================

begin;

-- ---- 1. The rules ----------------------------------------------------------------
create table public.packaging_rules (
  id            bigint generated always as identity primary key,
  ingredient_id bigint not null references public.ingredients(id) on delete cascade,
  per           text not null check (per in ('cookie', 'single', 'box', 'order', 'gift_note')),
  box_size      int check (box_size is null or box_size > 0),                -- only for 'box'; empty = any box
  qty           numeric(12,3) not null default 1 check (qty > 0),
  constraint packaging_rules_size_only_for_box check (per = 'box' or box_size is null)
);
create unique index packaging_rules_one_each on public.packaging_rules (ingredient_id, per, coalesce(box_size, 0));

alter table public.packaging_rules enable row level security;
create policy "admins manage packaging rules" on public.packaging_rules
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.packaging_rules to authenticated;

-- Old per_cookie values become 'cookie' rules, then per_cookie goes quiet
insert into public.packaging_rules (ingredient_id, per, qty)
select id, 'cookie', per_cookie from public.ingredients where per_cookie > 0;
update public.ingredients set per_cookie = 0 where per_cookie > 0;

-- ---- 2. Orders remember when they were packed and what the packaging cost -------------
alter table public.orders
  add column packed_at      timestamptz,
  add column packaging_cost numeric(12,2);

-- New stock log reason for packaging taken out when an order is packed
alter table public.stock_log drop constraint stock_log_reason_check;
alter table public.stock_log add constraint stock_log_reason_check check (reason in
  ('received', 'used_in_batch', 'used_manual', 'count_correction', 'discarded', 'purchase_fix', 'packed'));

-- ---- 3. What one order needs (everything except 'cookie' rules) ----------------------
create function public._order_packaging(p_order_id bigint)
returns table (ingredient_id bigint, qty numeric)
language sql stable security definer set search_path = ''
as $$
  select r.ingredient_id, sum(r.qty * n.cnt) as qty
  from public.packaging_rules r
  join public.ingredients i on i.id = r.ingredient_id and i.active
  cross join lateral (
    select case r.per
      when 'single' then (select coalesce(sum(oi.qty), 0) from public.order_items oi
                          where oi.order_id = p_order_id and oi.order_box_id is null)
      when 'box' then (select count(*) from public.order_boxes b
                       where b.order_id = p_order_id and (r.box_size is null or b.size = r.box_size))
      when 'order' then 1
      when 'gift_note' then (select count(*) from public.order_boxes b
                             where b.order_id = p_order_id and nullif(btrim(coalesce(b.gift_note, '')), '') is not null)
      else 0 end as cnt
  ) n
  where r.per <> 'cookie'
  group by r.ingredient_id
  having sum(r.qty * n.cnt) > 0
$$;
revoke all on function public._order_packaging(bigint) from public, anon, authenticated;

-- ---- 4. Packing an order takes its packaging out of stock (once) -----------------------
create or replace function public.admin_set_order_prep(p_ref_code text, p_prep text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.orders;
  v_item  record;
  v_mark  bigint;
  v_ids   bigint[] := '{}';
  v_taken numeric;
  v_short numeric := 0;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_prep is null or p_prep not in ('new', 'baking', 'ready', 'out_for_delivery', 'completed') then
    raise exception 'Unknown step.' using hint = 'invalid_prep';
  end if;

  select * into v_order from public.orders
  where ref_code = upper(btrim(coalesce(p_ref_code, ''))) for update;
  if not found then
    raise exception 'Order not found.' using hint = 'order_not_found';
  end if;

  if p_prep <> 'new' and v_order.status <> 'paid' then
    raise exception 'Mark the order paid first.' using hint = 'not_paid';
  end if;
  if p_prep = 'out_for_delivery' and v_order.fulfillment <> 'delivery' then
    raise exception 'This is a pickup order, so it can''t go out for delivery.' using hint = 'pickup_order';
  end if;

  update public.orders
     set prep_status  = p_prep,
         completed_at = case when p_prep = 'completed' then coalesce(completed_at, now()) else null end
   where id = v_order.id;

  -- First time it's packed: take its bags / boxes / stickers / cards out of stock.
  -- Missing stock doesn't block packing (you may just not have logged it); it's costed at today's price.
  if p_prep in ('ready', 'out_for_delivery', 'completed') and v_order.packed_at is null then
    select coalesce(max(id), 0) into v_mark from public.stock_log;
    for v_item in
      select p.ingredient_id, p.qty, i.cost_per_unit
      from public._order_packaging(v_order.id) p join public.ingredients i on i.id = p.ingredient_id
    loop
      v_taken := public._take_stock(v_item.ingredient_id, v_item.qty, 'packed', format('packed %s', v_order.ref_code), true);
      v_short := v_short + (v_item.qty - v_taken) * v_item.cost_per_unit;
      v_ids := v_ids || v_item.ingredient_id;
    end loop;
    update public.orders
       set packed_at = now(),
           packaging_cost = round(public._cost_since(v_mark, v_ids) + v_short, 2)
     where id = v_order.id;
  end if;
end $$;

-- ---- 5. Baking takes 'cookie' rules (was per_cookie) ----------------------------------
create or replace function public.admin_use_dough(p_flavor_id bigint, p_balls integer, p_sunday date default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_left  integer := p_balls;
  v_lot   record;
  v_take  integer;
  v_pack  record;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_dough numeric := 0;
  v_est   boolean := false;
  v_mark  bigint;
  v_packs bigint[] := '{}';
  v_taken numeric;
  v_short numeric := 0;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_balls is null or p_balls < 1 then
    raise exception 'Enter at least 1 dough ball.' using hint = 'bad_qty';
  end if;

  for v_lot in
    select id, balls_left, cost_per_ball, cost_estimated from public.dough_lots
    where flavor_id = p_flavor_id and balls_left > 0 and best_by >= v_today
    order by best_by, id for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.balls_left, v_left);
    update public.dough_lots set balls_left = balls_left - v_take where id = v_lot.id;
    v_dough := v_dough + v_take * coalesce(v_lot.cost_per_ball, public._ball_cost_now(p_flavor_id));
    v_est   := v_est or v_lot.cost_per_ball is null or v_lot.cost_estimated;
    v_left  := v_left - v_take;
  end loop;
  if v_left > 0 then
    raise exception 'Only % usable dough ball(s) in the freezer.', p_balls - v_left using hint = 'no_dough';
  end if;

  select coalesce(max(id), 0) into v_mark from public.stock_log;
  for v_pack in
    select r.ingredient_id as id, sum(r.qty) as per_cookie, i.cost_per_unit
    from public.packaging_rules r join public.ingredients i on i.id = r.ingredient_id
    where r.per = 'cookie' and i.active
    group by r.ingredient_id, i.cost_per_unit
  loop
    v_taken := public._take_stock(v_pack.id, v_pack.per_cookie * p_balls, 'used_in_batch',
      format('packaging for %s baked', p_balls), true);
    v_short := v_short + (v_pack.per_cookie * p_balls - v_taken) * v_pack.cost_per_unit;
    v_packs := v_packs || v_pack.id;
  end loop;

  insert into public.bake_log (flavor_id, kind, balls, ingredient_cost, packaging_cost, estimated, sunday)
  values (p_flavor_id, 'baked', p_balls, round(v_dough, 2),
          round(public._cost_since(v_mark, v_packs) + v_short, 2), v_est or v_short > 0,
          coalesce(p_sunday, public._week_sunday(now())));
end $$;

-- ---- 6. Bake plan shopping list: packaging for the Sunday's orders not packed yet ------
create or replace function public.admin_production_plan(p_sunday date, p_include_pending boolean default true)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_flavors  jsonb;
  v_shopping jsonb;
  v_cutoff   date := greatest(p_sunday, (now() at time zone 'Asia/Manila')::date);
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'flavor_id', c.flavor_id, 'slug', c.slug, 'name', c.name,
           'paid_cookies', c.paid, 'pending_cookies', c.pending, 'cookies_needed', c.needed,
           'baked', c.baked, 'still_to_bake', c.still_to_bake,
           'dough_on_hand', c.dough, 'to_make', c.to_make, 'yield', c.yield,
           'batches', c.batches, 'leftover', c.batches * c.yield - c.to_make,
           'recipe_ready', c.recipe_ready, 'recipe_version', c.version)
         order by c.flavor_id), '[]'::jsonb)
    into v_flavors
  from (
    select b.*,
           greatest(b.needed - b.baked, 0) as still_to_bake,
           greatest(b.needed - b.baked - b.dough, 0) as to_make,
           ceil(greatest(b.needed - b.baked - b.dough, 0)::numeric / b.yield)::int as batches
    from (
      select f.id as flavor_id, f.slug, f.name,
             coalesce(o.paid, 0) as paid, coalesce(o.pending, 0) as pending,
             coalesce(o.paid, 0) + case when p_include_pending then coalesce(o.pending, 0) else 0 end as needed,
             coalesce(bk.balls, 0) as baked,
             coalesce(d.balls, 0) as dough,
             coalesce(r.yield, 15) as yield,
             exists (select 1 from public.recipe_items ri where ri.flavor_id = f.id) as recipe_ready,
             r.version
      from public.flavors f
      left join public.recipes r on r.flavor_id = f.id
      left join (
        select i.flavor_id,
               sum(i.qty) filter (where ord.status = 'paid')::int as paid,
               sum(i.qty) filter (where ord.status = 'pending' and ord.expires_at > now())::int as pending
        from public.order_items i join public.orders ord on ord.id = i.order_id
        where ord.sunday_date = p_sunday
        group by i.flavor_id
      ) o on o.flavor_id = f.id
      left join (
        select flavor_id, sum(balls)::int as balls from public.bake_log
        where kind = 'baked' and sunday = p_sunday group by flavor_id
      ) bk on bk.flavor_id = f.id
      left join (
        select flavor_id, sum(balls_left)::int as balls from public.dough_lots
        where balls_left > 0 and best_by >= v_cutoff group by flavor_id
      ) d on d.flavor_id = f.id
      where f.active
    ) b
  ) c;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ingredient_id', x.id, 'name', x.name, 'category', x.category, 'unit', x.unit,
           'perishable', x.perishable, 'price_confirmed', x.price_confirmed,
           'needed', x.needed, 'on_hand', x.on_hand, 'short', x.short,
           'reorder_level', x.reorder_level, 'topup', x.short > greatest(x.needed - x.on_hand, 0),
           'pack_label', x.pack_label, 'pack_size', x.pack_size,
           'packs_to_buy', x.packs, 'est_cost', x.packs * x.pack_price)
         order by x.category, x.name), '[]'::jsonb)
    into v_shopping
  from (
    select i.id, i.name, i.category, i.unit, i.perishable, i.price_confirmed, i.reorder_level,
           i.pack_label, i.pack_size, i.pack_price,
           n.needed, s.on_hand,
           greatest(n.needed + i.reorder_level - s.on_hand, 0) as short,
           ceil(greatest(n.needed + i.reorder_level - s.on_hand, 0) / i.pack_size) as packs
    from public.ingredients i
    cross join lateral (
      select coalesce((select sum(ri.qty_per_batch * pf.batches)
                       from public.recipe_items ri
                       join jsonb_to_recordset(v_flavors) as pf(flavor_id bigint, batches int)
                         on pf.flavor_id = ri.flavor_id
                       where ri.ingredient_id = i.id), 0)
             -- 'cookie' rules: every cookie still to bake
             + coalesce((select sum(r.qty) from public.packaging_rules r
                         where r.ingredient_id = i.id and r.per = 'cookie'), 0)
               * (select coalesce(sum(pf.still_to_bake), 0) from jsonb_to_recordset(v_flavors) as pf(still_to_bake int))
             -- single / box / order / gift-note rules: every order for this Sunday not packed yet
             + coalesce((select sum(p.qty)
                         from public.orders ord
                         cross join lateral public._order_packaging(ord.id) p
                         where ord.sunday_date = p_sunday and ord.packed_at is null and p.ingredient_id = i.id
                           and (ord.status = 'paid' or (p_include_pending and ord.status = 'pending' and ord.expires_at > now()))), 0)
             as needed
    ) n
    cross join lateral (
      select coalesce(sum(l.qty_remaining), 0) as on_hand from public.ingredient_lots l
      where l.ingredient_id = i.id and (l.expires_on is null or l.expires_on >= v_cutoff)
    ) s
    where i.active and (n.needed > 0 or (i.reorder_level > 0 and s.on_hand <= i.reorder_level))
  ) x;

  return jsonb_build_object(
    'sunday', p_sunday,
    'include_pending', p_include_pending,
    'flavors', v_flavors,
    'shopping', v_shopping,
    'totals', jsonb_build_object(
      'cookies', (select coalesce(sum(pf.cookies_needed), 0) from jsonb_to_recordset(v_flavors) as pf(cookies_needed int)),
      'baked',   (select coalesce(sum(pf.baked), 0)          from jsonb_to_recordset(v_flavors) as pf(baked int)),
      'batches', (select coalesce(sum(pf.batches), 0)        from jsonb_to_recordset(v_flavors) as pf(batches int)),
      'est_shopping_cost', coalesce((select sum((e->>'est_cost')::numeric) from jsonb_array_elements(v_shopping) e), 0)));
end $$;

-- ---- 7. Recipe costing: packaging per cookie = 'cookie' rules only ---------------------
-- (Bags, boxes and cards depend on how the cookie is sold; the Recipes page adds those per single / per box.)
create or replace view public.flavor_costing as
 select f.id as flavor_id,
    f.slug,
    f.name,
    r.version as recipe_version,
    r.yield,
    count(ri.id)::integer as items,
    coalesce(sum(ri.qty_per_batch * i.cost_per_unit), 0::numeric)::numeric(12,2) as batch_cost,
    (coalesce(sum(ri.qty_per_batch * i.cost_per_unit), 0::numeric) / r.yield::numeric)::numeric(12,2) as ingredient_cost_per_cookie,
    ((select coalesce(sum(pr.qty * p.cost_per_unit), 0::numeric)
        from public.packaging_rules pr join public.ingredients p on p.id = pr.ingredient_id
       where p.active and pr.per = 'cookie'))::numeric(12,2) as packaging_cost_per_cookie,
    count(ri.id) filter (where not i.price_confirmed)::integer as assumed_prices,
    f.single_price,
    f.surcharge
   from public.flavors f
     join public.recipes r on r.flavor_id = f.id
     left join public.recipe_items ri on ri.flavor_id = f.id
     left join public.ingredients i on i.id = ri.ingredient_id
  where f.active
  group by f.id, f.slug, f.name, r.version, r.yield, f.single_price, f.surcharge;

-- ---- 8. Money report: packed orders' packaging counts as a cost of that Sunday ---------
create or replace function public.admin_money_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  with weeks as (
    select d::date as sunday from generate_series(p_from, p_to, interval '7 days') d
    where extract(dow from d) = 0
  ),
  money_in as (
    select o.sunday_date as sunday, sum(o.total) as amount, count(*) as orders
    from public.orders o where o.status = 'paid' and o.sunday_date between p_from and p_to
    group by o.sunday_date
  ),
  sold as (
    select o.sunday_date as sunday, sum(i.qty) as cookies
    from public.orders o join public.order_items i on i.order_id = o.id
    where o.status = 'paid' and o.sunday_date between p_from and p_to
    group by o.sunday_date
  ),
  packed as (                                                     -- new in 028
    select o.sunday_date as sunday, sum(o.packaging_cost) as cost
    from public.orders o where o.packed_at is not null and o.sunday_date between p_from and p_to
    group by o.sunday_date
  ),
  baked as (
    select sunday,
           sum(balls) filter (where kind = 'baked') as balls,
           sum(ingredient_cost + packaging_cost) filter (where kind = 'baked') as cost,
           sum(ingredient_cost) filter (where kind = 'dough_thrown') as dough_waste,
           sum(balls) filter (where kind = 'dough_thrown') as dough_balls_thrown,
           bool_or(estimated) as estimated
    from public.bake_log where sunday between p_from and p_to group by sunday
  ),
  stock as (
    select public._week_sunday(s.created_at) as sunday,
           sum(-s.delta * l.unit_cost) filter (where s.reason = 'discarded') as thrown,
           sum(s.delta * l.unit_cost) filter (where s.reason = 'count_correction') as recount
    from public.stock_log s join public.ingredient_lots l on l.id = s.lot_id
    where s.reason in ('discarded', 'count_correction')
      and public._week_sunday(s.created_at) between p_from and p_to
    group by 1
  ),
  spent as (
    select public._week_sunday(l.created_at) as sunday, sum(l.paid_total) as amount
    from public.ingredient_lots l
    where not l.voided and l.paid_total is not null
      and public._week_sunday(l.created_at) between p_from and p_to
    group by 1
  ),
  rows as (
    select w.sunday,
           coalesce(m.amount, 0)                        as money_in,
           coalesce(m.orders, 0)                        as orders,
           coalesce(so.cookies, 0)                      as cookies_sold,
           coalesce(b.balls, 0)                         as cookies_baked,
           round(coalesce(b.cost, 0), 2)                as cookie_cost,
           round(coalesce(pk.cost, 0), 2)               as packing_cost,
           round(coalesce(st.thrown, 0) + coalesce(b.dough_waste, 0), 2) as waste,
           coalesce(b.dough_balls_thrown, 0)            as dough_balls_thrown,
           round(coalesce(st.recount, 0), 2)            as recount,
           round(coalesce(sp.amount, 0), 2)             as spent,
           coalesce(b.estimated, false)                 as estimated
    from weeks w
    left join money_in m on m.sunday = w.sunday
    left join sold so on so.sunday = w.sunday
    left join packed pk on pk.sunday = w.sunday
    left join baked b on b.sunday = w.sunday
    left join stock st on st.sunday = w.sunday
    left join spent sp on sp.sunday = w.sunday
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'guessed_prices', (select count(*) from public.ingredients where active and not price_confirmed),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
        'sunday', r.sunday, 'money_in', r.money_in, 'orders', r.orders,
        'cookies_sold', r.cookies_sold, 'cookies_baked', r.cookies_baked,
        'cookie_cost', r.cookie_cost, 'packing_cost', r.packing_cost,
        'waste', r.waste, 'dough_balls_thrown', r.dough_balls_thrown,
        'recount', r.recount, 'spent', r.spent, 'estimated', r.estimated,
        'profit', r.money_in - r.cookie_cost - r.packing_cost - r.waste + r.recount) order by r.sunday)
      from rows r), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'money_in', coalesce(sum(money_in), 0), 'cookie_cost', coalesce(sum(cookie_cost), 0),
        'packing_cost', coalesce(sum(packing_cost), 0),
        'waste', coalesce(sum(waste), 0), 'recount', coalesce(sum(recount), 0),
        'spent', coalesce(sum(spent), 0), 'cookies_sold', coalesce(sum(cookies_sold), 0),
        'cookies_baked', coalesce(sum(cookies_baked), 0),
        'profit', coalesce(sum(money_in - cookie_cost - packing_cost - waste + recount), 0),
        'estimated', coalesce(bool_or(estimated), false))
      from rows))
  into v_out;
  return v_out;
end $$;

-- ---- 9. Changing an item's unit also converts its packaging rules ----------------------
create or replace function public.admin_change_unit(p_ingredient_id bigint, p_unit text, p_factor numeric)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_ing public.ingredients;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id for update;
  if not found then
    raise exception 'Item not found.' using hint = 'not_found';
  end if;
  if p_unit is null or p_unit not in ('g', 'ml', 'pc', 'tsp') then
    raise exception 'Pick grams, millilitres, pieces or teaspoons.' using hint = 'bad_unit';
  end if;
  if p_unit = v_ing.unit then
    raise exception 'It''s already counted in %.', p_unit using hint = 'bad_unit';
  end if;
  if p_factor is null or p_factor <= 0 or p_factor > 100000 then
    raise exception 'Say how many % make one %.', p_unit, v_ing.unit using hint = 'bad_factor';
  end if;

  begin
    update public.ingredients
       set unit = p_unit,
           pack_size = round(pack_size * p_factor, 3),           -- pack_price stays: same pack, same price
           reorder_level = round(reorder_level * p_factor, 3),
           per_cookie = round(per_cookie * p_factor, 3)
     where id = p_ingredient_id;
    update public.ingredient_lots
       set qty_received = round(qty_received * p_factor, 3),
           qty_remaining = round(qty_remaining * p_factor, 3),
           pack_size_bought = round(pack_size_bought * p_factor, 3),
           unit_cost = unit_cost / p_factor                         -- paid_total stays: same money
     where ingredient_id = p_ingredient_id;
    update public.stock_log set delta = round(delta * p_factor, 3) where ingredient_id = p_ingredient_id;
    update public.recipe_items set qty_per_batch = round(qty_per_batch * p_factor, 3) where ingredient_id = p_ingredient_id;
    update public.packaging_rules set qty = round(qty * p_factor, 3) where ingredient_id = p_ingredient_id;   -- new in 028
  exception when check_violation then
    raise exception 'That makes some amounts too small to store (under 0.001 %). Check the number.', p_unit
      using hint = 'bad_factor';
  end;
end $$;

-- ---- 10. The owner's packing (Nov 7, 2026) ---------------------------------------------
-- Box cookies aren't bagged. Singles: 1 plastic bag + 1 sticker each. Boxes: 1 sticker each.
-- (The box items and thank-you card are added on the Stock page once there's a price for them.)
delete from public.packaging_rules
 where ingredient_id in (select id from public.ingredients where category = 'packaging'
                         and name in ('Plastic bag (single cookie)', 'Stickers'))
   and per = 'cookie';
insert into public.packaging_rules (ingredient_id, per, qty)
select id, 'single', 1 from public.ingredients where category = 'packaging' and name = 'Plastic bag (single cookie)';
insert into public.packaging_rules (ingredient_id, per, qty)
select id, 'single', 1 from public.ingredients where category = 'packaging' and name = 'Stickers';
insert into public.packaging_rules (ingredient_id, per, qty)
select id, 'box', 1 from public.ingredients where category = 'packaging' and name = 'Stickers';

commit;
