-- ============================================================================
-- 016_real_costs.sql: get the money right
--
--   1. Purchases remember what you paid (total + pack size), can be fixed or
--      removed if you typed something wrong, and buying a different pack size
--      than usual works.
--   2. A recount that finds extra stock asks for an expiry date (perishables).
--   3. Stock value: what's on the shelf is worth (from what you paid).
--   4. Dough remembers what its ingredients REALLY cost (the prices of the exact
--      purchases it used), and every bake / thrown-away dough is logged with its
--      cost against a Sunday (bake_log).
--   5. admin_money_report: per Sunday, money in (paid orders) minus what the
--      cookies baked that week cost, minus waste = profit.
--   6. admin_receive_many: log a whole shopping trip in one go.
--
-- Two prices, on purpose:
--   * ingredients.pack_price = the LATEST price you paid. Used for menu pricing
--     (Recipes page) and the shopping list, because that's what it costs to
--     replace.
--   * ingredient_lots.unit_cost = what THAT purchase cost. Used for real cost,
--     profit, waste and stock value, because that's what you actually spent.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Small helper: which Sunday does a moment belong to?
-- The Sunday on or after it (Manila). After 6pm on a Sunday (pickup is over)
-- it belongs to the next Sunday. Same rule the admin pages use.
-- ----------------------------------------------------------------------------
create function public._week_sunday(p_ts timestamptz)
returns date
language sql stable set search_path = ''
as $$
  select case
    when extract(dow from (p_ts at time zone 'Asia/Manila')) = 0
         and (p_ts at time zone 'Asia/Manila')::time >= time '18:00'
      then (p_ts at time zone 'Asia/Manila')::date + 7
    else (p_ts at time zone 'Asia/Manila')::date
         + ((7 - extract(dow from (p_ts at time zone 'Asia/Manila'))::int) % 7)
  end
$$;
revoke all on function public._week_sunday(timestamptz) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 1. Purchases: remember the total and the pack size; allow fixing
-- ----------------------------------------------------------------------------
alter table public.ingredient_lots
  add column paid_total       numeric(10,2) check (paid_total >= 0),          -- what you paid for this purchase (null = not entered)
  add column pack_size_bought numeric(12,3) check (pack_size_bought > 0),     -- size of one pack THIS time (null = the usual size)
  add column voided           boolean not null default false;                 -- removed because it was a mistake

alter table public.stock_log drop constraint stock_log_reason_check;
alter table public.stock_log add constraint stock_log_reason_check check (reason in
  ('received', 'used_in_batch', 'used_manual', 'count_correction', 'discarded', 'purchase_fix'));

-- "I bought some". New: p_pack_size (a different size than usual, in the item's
-- unit), and the purchase keeps what you paid. If you paid something, the item's
-- price becomes the new price, worked out for the USUAL pack size.
drop function public.admin_receive_stock(bigint, numeric, numeric, date, text);
create function public.admin_receive_stock(
  p_ingredient_id bigint, p_qty numeric, p_unit_cost numeric default null,
  p_expires_on date default null, p_note text default null, p_pack_size numeric default null)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_ing public.ingredients;
  v_lot bigint;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id for update;
  if not found then
    raise exception 'Item not found.' using hint = 'not_found';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity must be more than zero.' using hint = 'bad_qty';
  end if;
  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Cost can''t be negative.' using hint = 'bad_cost';
  end if;
  if p_pack_size is not null and p_pack_size <= 0 then
    raise exception 'Pack size must be more than zero.' using hint = 'bad_qty';
  end if;
  if v_ing.perishable and p_expires_on is null then
    raise exception 'Add an expiry date: % is perishable.', v_ing.name using hint = 'needs_expiry';
  end if;

  insert into public.ingredient_lots
    (ingredient_id, qty_received, qty_remaining, unit_cost, expires_on, note, paid_total, pack_size_bought)
  values (p_ingredient_id, p_qty, p_qty, coalesce(p_unit_cost, v_ing.cost_per_unit), p_expires_on,
          left(nullif(btrim(coalesce(p_note, '')), ''), 200),
          case when p_unit_cost is null then null else round(p_unit_cost * p_qty, 2) end,
          case when p_pack_size is null or p_pack_size = v_ing.pack_size then null else p_pack_size end)
  returning id into v_lot;

  insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
  values (p_ingredient_id, v_lot, p_qty, 'received', left(p_note, 200));

  if p_unit_cost is not null then
    update public.ingredients
       set pack_price = round(p_unit_cost * pack_size, 2), price_confirmed = true
     where id = p_ingredient_id;
  end if;
  return v_lot;
end $$;

-- Fix a purchase you typed wrong (amount, price, expiry), or remove it.
--   p_qty_received : the real amount bought (in the item's unit). Whatever has
--                    already been used stays used; it can't go below that.
--   p_unit_cost    : the real price per unit (null = keep)
--   p_remove       : true = this purchase never happened (only if nothing used)
-- If it's the item's latest purchase, the item's price follows the fix.
create function public.admin_fix_lot(
  p_lot_id bigint, p_qty_received numeric default null, p_unit_cost numeric default null,
  p_expires_on date default null, p_clear_expiry boolean default false, p_remove boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_lot     public.ingredient_lots;
  v_ing     public.ingredients;
  v_used    numeric;
  v_new_qty numeric;
  v_delta   numeric;
  v_expiry  date;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_lot from public.ingredient_lots where id = p_lot_id for update;
  if not found or v_lot.voided then
    raise exception 'Purchase not found.' using hint = 'not_found';
  end if;
  select * into v_ing from public.ingredients where id = v_lot.ingredient_id for update;
  v_used := v_lot.qty_received - v_lot.qty_remaining;

  if p_remove then
    if v_used > 0 then
      raise exception 'Some of this was already used (% %). Fix the amount instead.', trim_scale(v_used), v_ing.unit
        using hint = 'already_used';
    end if;
    if v_lot.qty_remaining > 0 then
      insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
      values (v_lot.ingredient_id, v_lot.id, -v_lot.qty_remaining, 'purchase_fix', 'purchase removed');
    end if;
    update public.ingredient_lots set qty_remaining = 0, voided = true where id = v_lot.id;
    -- It was the latest price? Go back to the price of the purchase before it.
    if v_lot.paid_total is not null and not exists (
         select 1 from public.ingredient_lots
         where ingredient_id = v_lot.ingredient_id and not voided and paid_total is not null and id > v_lot.id) then
      update public.ingredients i
         set pack_price = round(p.unit_cost * i.pack_size, 2)
        from (select unit_cost from public.ingredient_lots
              where ingredient_id = v_lot.ingredient_id and not voided and paid_total is not null
              order by id desc limit 1) p
       where i.id = v_lot.ingredient_id;
    end if;
    return;
  end if;

  v_new_qty := coalesce(p_qty_received, v_lot.qty_received);
  if v_new_qty <= 0 then
    raise exception 'Amount must be more than zero (or remove the purchase).' using hint = 'bad_qty';
  end if;
  if v_new_qty < v_used then
    raise exception '% % of this was already used, so the amount can''t be less than that.', trim_scale(v_used), v_ing.unit
      using hint = 'already_used';
  end if;
  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Cost can''t be negative.' using hint = 'bad_cost';
  end if;
  v_expiry := case when p_clear_expiry then null else coalesce(p_expires_on, v_lot.expires_on) end;
  if v_ing.perishable and v_expiry is null then
    raise exception 'Add an expiry date: % is perishable.', v_ing.name using hint = 'needs_expiry';
  end if;

  v_delta := v_new_qty - v_lot.qty_received;
  update public.ingredient_lots
     set qty_received  = v_new_qty,
         qty_remaining = qty_remaining + v_delta,
         unit_cost     = coalesce(p_unit_cost, unit_cost),
         paid_total    = case when p_unit_cost is not null then round(p_unit_cost * v_new_qty, 2)
                              when paid_total is not null then round(unit_cost * v_new_qty, 2) else null end,
         expires_on    = v_expiry
   where id = v_lot.id;
  if v_delta <> 0 then
    insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
    values (v_lot.ingredient_id, v_lot.id, v_delta, 'purchase_fix', 'purchase amount fixed');
  end if;

  -- Latest real purchase of this item? Then the item's price follows.
  if p_unit_cost is not null and v_lot.id = (
       select max(id) from public.ingredient_lots
       where ingredient_id = v_lot.ingredient_id and not voided and paid_total is not null) then
    update public.ingredients set pack_price = round(p_unit_cost * pack_size, 2), price_confirmed = true
     where id = v_lot.ingredient_id;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 2. Recount: extra stock found on a perishable needs an expiry date
-- ----------------------------------------------------------------------------
drop function public.admin_count_stock(bigint, numeric, text);
create function public.admin_count_stock(
  p_ingredient_id bigint, p_actual numeric, p_note text default null, p_expires_on date default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_today   date := (now() at time zone 'Asia/Manila')::date;
  v_ing     public.ingredients;
  v_current numeric;
  v_lot     bigint;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_actual is null or p_actual < 0 then
    raise exception 'Count can''t be negative.' using hint = 'bad_qty';
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id for update;
  if not found then
    raise exception 'Item not found.' using hint = 'not_found';
  end if;

  select coalesce(sum(qty_remaining), 0) into v_current
  from public.ingredient_lots
  where ingredient_id = p_ingredient_id and (expires_on is null or expires_on >= v_today);

  if p_actual < v_current then
    perform public._take_stock(p_ingredient_id, v_current - p_actual, 'count_correction', p_note, true);
  elsif p_actual > v_current then
    if v_ing.perishable and p_expires_on is null then
      raise exception 'You found extra %. Add its expiry date (it''s perishable).', v_ing.name using hint = 'needs_expiry';
    end if;
    insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining, unit_cost, expires_on, note)
    values (p_ingredient_id, p_actual - v_current, p_actual - v_current, v_ing.cost_per_unit, p_expires_on,
            coalesce(p_note, 'Stock take'))
    returning id into v_lot;
    insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
    values (p_ingredient_id, v_lot, p_actual - v_current, 'count_correction', p_note);
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 3. Stock list + what it's worth (usable stock x what you paid for it)
-- Same view as 014 with stock_value added at the end.
-- ----------------------------------------------------------------------------
create or replace view public.ingredient_stock with (security_invoker = true) as
select
  i.id as ingredient_id, i.name, i.category, i.unit, i.perishable, i.active,
  i.pack_label, i.pack_size, i.pack_price, i.cost_per_unit, i.price_confirmed,
  i.reorder_level, i.per_cookie, i.supplier, i.notes,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on is null or l.expires_on >= t.today), 0)::numeric(12,3) as on_hand,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on < t.today), 0)::numeric(12,3)                         as expired_qty,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on >= t.today and l.expires_on <= t.today + 7), 0)::numeric(12,3) as expiring_soon_qty,
  min(l.expires_on) filter (where l.qty_remaining > 0 and (l.expires_on is null or l.expires_on >= t.today)) as next_expiry,
  (i.reorder_level > 0 and
   coalesce(sum(l.qty_remaining) filter (where l.expires_on is null or l.expires_on >= t.today), 0) <= i.reorder_level) as is_low,
  round(coalesce(sum(l.qty_remaining * l.unit_cost) filter (where l.expires_on is null or l.expires_on >= t.today), 0), 2) as stock_value
from public.ingredients i
cross join (select (now() at time zone 'Asia/Manila')::date as today) t
left join public.ingredient_lots l on l.ingredient_id = i.id and l.qty_remaining > 0
group by i.id, t.today;


-- ----------------------------------------------------------------------------
-- 4. Real cost of dough, and a log of every bake with its cost
-- ----------------------------------------------------------------------------
alter table public.dough_lots
  add column cost_per_ball  numeric check (cost_per_ball >= 0),       -- ingredients only, at the prices you paid
  add column cost_estimated boolean not null default false;           -- true = some of it priced at today's price (stock wasn't logged)

create table public.bake_log (
  id              bigint generated always as identity primary key,
  flavor_id       bigint not null references public.flavors (id),
  kind            text not null check (kind in ('baked', 'dough_thrown')),
  balls           integer not null check (balls > 0),
  ingredient_cost numeric(12,2) not null default 0,
  packaging_cost  numeric(12,2) not null default 0,
  estimated       boolean not null default false,     -- part of the cost is a guess
  sunday          date not null,                      -- the Sunday this belongs to
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid()
);
create index bake_log_sunday_idx on public.bake_log (sunday);

alter table public.bake_log enable row level security;
revoke all on public.bake_log from public, anon, authenticated;
grant select on public.bake_log to authenticated;
create policy "admins read bake log" on public.bake_log
  for select to authenticated using (public.is_admin());

-- What the stock taken out in THIS transaction cost (since log row p_after_id).
-- Uses each purchase's own price.
create function public._cost_since(p_after_id bigint, p_ingredient_ids bigint[] default null)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(-s.delta * l.unit_cost), 0)
  from public.stock_log s join public.ingredient_lots l on l.id = s.lot_id
  where s.id > coalesce(p_after_id, 0) and s.created_at = now() and s.delta < 0
    and (p_ingredient_ids is null or s.ingredient_id = any (p_ingredient_ids))
$$;
revoke all on function public._cost_since(bigint, bigint[]) from public, anon, authenticated;

-- Today's ingredient cost of one dough ball (for old dough made before 016)
create function public._ball_cost_now(p_flavor_id bigint)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(ri.qty_per_batch * i.cost_per_unit), 0) / max(r.yield)
  from public.recipes r
  left join public.recipe_items ri on ri.flavor_id = r.flavor_id
  left join public.ingredients i on i.id = ri.ingredient_id
  where r.flavor_id = p_flavor_id
$$;
revoke all on function public._ball_cost_now(bigint) from public, anon, authenticated;

-- "I made the dough": same as 015, plus the dough remembers its real cost
create or replace function public.admin_record_batch(
  p_flavor_id bigint, p_batches integer default 1, p_made_on date default null,
  p_best_by date default null, p_force boolean default false)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_recipe public.recipes;
  v_flavor text;
  v_made   date := coalesce(p_made_on, (now() at time zone 'Asia/Manila')::date);
  v_today  date := (now() at time zone 'Asia/Manila')::date;
  v_item   record;
  v_short  text := '';
  v_lot    bigint;
  v_mark   bigint;
  v_taken  numeric;
  v_est    numeric := 0;     -- cost of the part that wasn't in stock, at today's price
  v_cost   numeric;
  v_balls  integer;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_batches is null or p_batches < 1 or p_batches > 20 then
    raise exception 'Batches must be between 1 and 20.' using hint = 'bad_qty';
  end if;

  select name into v_flavor from public.flavors where id = p_flavor_id;
  select * into v_recipe from public.recipes where flavor_id = p_flavor_id;
  if v_flavor is null or not found
     or not exists (select 1 from public.recipe_items where flavor_id = p_flavor_id) then
    raise exception 'No recipe entered for % yet. Add it on the Recipes page first.', coalesce(v_flavor, 'this flavor')
      using hint = 'no_recipe';
  end if;

  -- 1) Is there enough of everything?
  for v_item in
    select i.id, i.name, i.unit, ri.qty_per_batch * p_batches as need,
           coalesce((select sum(l.qty_remaining) from public.ingredient_lots l
                     where l.ingredient_id = i.id and (l.expires_on is null or l.expires_on >= v_today)), 0) as have
    from public.recipe_items ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.flavor_id = p_flavor_id
  loop
    if v_item.have < v_item.need then
      v_short := v_short || case when v_short = '' then '' else ', ' end ||
                 format('%s (need %s %s, have %s)', v_item.name, trim_scale(v_item.need), v_item.unit, trim_scale(v_item.have));
    end if;
  end loop;
  if v_short <> '' and not p_force then
    raise exception 'Short on: %.', v_short using hint = 'short_stock';
  end if;

  -- 2) Take it out of stock (earliest expiry first), keeping track of the cost
  select coalesce(max(id), 0) into v_mark from public.stock_log;
  for v_item in
    select ri.ingredient_id, ri.qty_per_batch * p_batches as need, i.cost_per_unit
    from public.recipe_items ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.flavor_id = p_flavor_id
  loop
    v_taken := public._take_stock(v_item.ingredient_id, v_item.need, 'used_in_batch',
                                  format('%s x %s', p_batches, v_flavor), true);
    v_est := v_est + (v_item.need - v_taken) * v_item.cost_per_unit;
  end loop;
  v_cost  := public._cost_since(v_mark) + v_est;
  v_balls := p_batches * v_recipe.yield;

  -- 3) Dough into the freezer
  insert into public.dough_lots (flavor_id, balls_made, balls_left, made_on, best_by, note, cost_per_ball, cost_estimated)
  values (p_flavor_id, v_balls, v_balls, v_made,
          coalesce(p_best_by, v_made + v_recipe.dough_freezer_days),
          case when v_short <> '' then left('Forced. Short on: ' || v_short, 200) else null end,
          round(v_cost / v_balls, 4), v_est > 0)
  returning id into v_lot;
  return v_lot;
end $$;

-- "I baked these": same as 015, plus it logs what the cookies cost (dough at
-- what it really cost + packaging at what you paid) against this week's Sunday
create or replace function public.admin_use_dough(p_flavor_id bigint, p_balls integer)
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
    select id, per_cookie, cost_per_unit from public.ingredients where active and per_cookie > 0
  loop
    v_taken := public._take_stock(v_pack.id, v_pack.per_cookie * p_balls, 'used_in_batch',
      format('packaging for %s baked', p_balls), true);
    v_short := v_short + (v_pack.per_cookie * p_balls - v_taken) * v_pack.cost_per_unit;
    v_packs := v_packs || v_pack.id;
  end loop;

  insert into public.bake_log (flavor_id, kind, balls, ingredient_cost, packaging_cost, estimated, sunday)
  values (p_flavor_id, 'baked', p_balls, round(v_dough, 2),
          round(public._cost_since(v_mark, v_packs) + v_short, 2), v_est or v_short > 0,
          public._week_sunday(now()));
end $$;

-- Throw away a dough lot: same as 014, plus the loss is logged as waste
create or replace function public.admin_discard_dough(p_lot_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_lot public.dough_lots;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_lot from public.dough_lots where id = p_lot_id for update;
  if not found then
    raise exception 'Dough lot not found.' using hint = 'not_found';
  end if;
  if v_lot.balls_left > 0 then
    insert into public.bake_log (flavor_id, kind, balls, ingredient_cost, estimated, sunday)
    values (v_lot.flavor_id, 'dough_thrown', v_lot.balls_left,
            round(v_lot.balls_left * coalesce(v_lot.cost_per_ball, public._ball_cost_now(v_lot.flavor_id)), 2),
            v_lot.cost_per_ball is null or v_lot.cost_estimated, public._week_sunday(now()));
    update public.dough_lots set balls_left = 0 where id = p_lot_id;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 5. Money per Sunday
--   money_in    = what paid orders for that Sunday actually paid (orders.total)
--   cookie_cost = what the cookies baked that week cost (ingredients + packaging,
--                 at the prices you paid). Extra cookies you baked count too.
--   waste       = stock thrown away + dough thrown away that week
--   recount     = stock that went missing (or turned up) at a recount, in pesos
--   profit      = money_in - cookie_cost - waste + recount
--   spent       = cash spent on stock that week (purchases with a total entered)
-- Labor, gas/electricity and delivery aren't included.
-- ----------------------------------------------------------------------------
create function public.admin_money_report(p_from date, p_to date)
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
           round(coalesce(st.thrown, 0) + coalesce(b.dough_waste, 0), 2) as waste,
           coalesce(b.dough_balls_thrown, 0)            as dough_balls_thrown,
           round(coalesce(st.recount, 0), 2)            as recount,
           round(coalesce(sp.amount, 0), 2)             as spent,
           coalesce(b.estimated, false)                 as estimated
    from weeks w
    left join money_in m on m.sunday = w.sunday
    left join sold so on so.sunday = w.sunday
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
        'cookie_cost', r.cookie_cost, 'waste', r.waste, 'dough_balls_thrown', r.dough_balls_thrown,
        'recount', r.recount, 'spent', r.spent, 'estimated', r.estimated,
        'profit', r.money_in - r.cookie_cost - r.waste + r.recount) order by r.sunday)
      from rows r), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'money_in', coalesce(sum(money_in), 0), 'cookie_cost', coalesce(sum(cookie_cost), 0),
        'waste', coalesce(sum(waste), 0), 'recount', coalesce(sum(recount), 0),
        'spent', coalesce(sum(spent), 0), 'cookies_sold', coalesce(sum(cookies_sold), 0),
        'cookies_baked', coalesce(sum(cookies_baked), 0),
        'profit', coalesce(sum(money_in - cookie_cost - waste + recount), 0),
        'estimated', coalesce(bool_or(estimated), false))
      from rows))
  into v_out;
  return v_out;
end $$;


-- ----------------------------------------------------------------------------
-- 6. A whole shopping trip in one go. All or nothing: if one line is wrong,
-- nothing is saved and the error says which item.
-- p_items: [{ingredient_id, qty, unit_cost?, expires_on?, note?, pack_size?}]
-- ----------------------------------------------------------------------------
create function public.admin_receive_many(p_items jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_item jsonb;
  v_n    integer := 0;
  v_name text;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Nothing to add.' using hint = 'bad_qty';
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select name into v_name from public.ingredients where id = (v_item ->> 'ingredient_id')::bigint;
    begin
      perform public.admin_receive_stock(
        (v_item ->> 'ingredient_id')::bigint, (v_item ->> 'qty')::numeric,
        nullif(v_item ->> 'unit_cost', '')::numeric, nullif(v_item ->> 'expires_on', '')::date,
        v_item ->> 'note', nullif(v_item ->> 'pack_size', '')::numeric);
    exception when others then
      raise exception '%: %', coalesce(v_name, 'An item'), sqlerrm using hint = 'bad_line';
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;


-- ----------------------------------------------------------------------------
-- Who can call what
-- ----------------------------------------------------------------------------
revoke all on function
  public.admin_receive_stock(bigint, numeric, numeric, date, text, numeric),
  public.admin_fix_lot(bigint, numeric, numeric, date, boolean, boolean),
  public.admin_count_stock(bigint, numeric, text, date),
  public.admin_money_report(date, date),
  public.admin_receive_many(jsonb)
  from public, anon;
grant execute on function
  public.admin_receive_stock(bigint, numeric, numeric, date, text, numeric),
  public.admin_fix_lot(bigint, numeric, numeric, date, boolean, boolean),
  public.admin_count_stock(bigint, numeric, text, date),
  public.admin_money_report(date, date),
  public.admin_receive_many(jsonb)
  to authenticated;
