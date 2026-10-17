-- ============================================================================
-- 014_admin_operations.sql: the "back office" for AJ's Bakery.
--
-- ADDITIVE ONLY. Nothing existing is dropped or renamed, and the customer side
-- (place_order, get_order_status, caps, expiry) is not touched. The one
-- existing function that changes is admin_orders(): it returns a few extra
-- fields. Everything is admin-only (RLS + is_admin() checks), like 004.
--
-- What this adds:
--   1. ORDER PROGRESS   orders.prep_status (new > baking > ready > out for
--                       delivery > completed) plus courier / booking ref /
--                       time slot / internal note. This is SEPARATE from
--                       orders.status (pending/paid/cancelled/expired), which
--                       stays the payment status.
--   2. INVENTORY        ingredients + lots (batches you bought). Every lot can
--                       have an expiry date; perishable items must have one.
--                       Stock is used earliest-expiry-first (FEFO).
--   3. RECIPES          recipes (one per flavor) + recipe_items (grams etc.
--                       per batch).
--   4. FROZEN DOUGH     dough_lots: dough balls in the freezer, with best-by.
--   5. PRODUCTION PLAN  admin_production_plan(sunday): cookies to make,
--                       batches, ingredients needed, shopping list.
--   6. COSTING          flavor_costing view: cost per cookie vs selling price.
--
-- Run after 013. Seed data (ingredients + the Chimp Chips recipe) is in
-- seed_ops.sql.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. ORDER PROGRESS + DELIVERY DETAILS
-- Delivery is customer-booked (Lalamove/Grab), so we only record who/when/ref,
-- not a fee.
-- ----------------------------------------------------------------------------
alter table public.orders
  add column prep_status text not null default 'new'
    constraint orders_prep_status_check
    check (prep_status in ('new', 'baking', 'ready', 'out_for_delivery', 'completed')),
  add column courier       text,   -- e.g. Lalamove, Grab, "Mom"
  add column delivery_ref  text,   -- booking number or tracking link
  add column delivery_slot text,   -- e.g. "3-4pm"
  add column admin_note    text,   -- internal note, never shown to customers
  add column completed_at  timestamptz;

alter table public.orders
  add constraint orders_courier_len       check (char_length(courier)       <= 60),
  add constraint orders_delivery_ref_len  check (char_length(delivery_ref)  <= 300),
  add constraint orders_delivery_slot_len check (char_length(delivery_slot) <= 60),
  add constraint orders_admin_note_len    check (char_length(admin_note)    <= 500);

-- Same function as before, plus the new fields at the end of each order.
create or replace function public.admin_orders(p_sunday date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'ref_code',    o.ref_code,
        'sunday_date', o.sunday_date,
        'name',        o.name,
        'ig_handle',   o.ig_handle,
        'phone',       o.phone,
        'fulfillment', o.fulfillment,
        'address',     o.address,
        'total',       o.total,
        'status',      o.status,
        'gcash_ref',   o.gcash_ref,
        'created_at',  o.created_at,
        'expires_at',  o.expires_at,
        'overdue',      (o.status = 'pending' and o.expires_at <= now()),
        'seconds_left', greatest(extract(epoch from (o.expires_at - now()))::int, 0),
        -- new in 014
        'prep_status',    o.prep_status,
        'courier',        o.courier,
        'delivery_ref',   o.delivery_ref,
        'delivery_slot',  o.delivery_slot,
        'admin_note',     o.admin_note,
        'completed_at',   o.completed_at,
        'boxes', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'position',  b.position,
              'size',      b.size,
              'price',     b.price,
              'gift_note', b.gift_note,
              'items', coalesce((
                select jsonb_agg(
                  jsonb_build_object('slug', f.slug, 'name', f.name, 'qty', i.qty)
                  order by f.id)
                from public.order_items i
                join public.flavors f on f.id = i.flavor_id
                where i.order_box_id = b.id
              ), '[]'::jsonb))
            order by b.position)
          from public.order_boxes b
          where b.order_id = o.id
        ), '[]'::jsonb),
        'singles', coalesce((
          select jsonb_agg(
            jsonb_build_object('slug', f.slug, 'name', f.name, 'qty', i.qty, 'unit_price', i.unit_price)
            order by f.id)
          from public.order_items i
          join public.flavors f on f.id = i.flavor_id
          where i.order_id = o.id and i.order_box_id is null
        ), '[]'::jsonb))
      order by o.created_at)
    from public.orders o
    where o.sunday_date = p_sunday
  ), '[]'::jsonb);
end $$;

-- Move an order along: new > baking > ready > out_for_delivery > completed.
-- Any step can be chosen (so a mis-tap is easy to undo), but:
--   * only PAID orders can leave "new" (you don't bake or ship unpaid orders)
--   * only DELIVERY orders can be "out_for_delivery"
create function public.admin_set_order_prep(p_ref_code text, p_prep text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.orders;
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
end $$;

-- Save courier / booking ref / time slot / internal note (blank = clear it)
create function public.admin_set_order_delivery(
  p_ref_code text, p_courier text, p_delivery_ref text, p_delivery_slot text, p_admin_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_courier text := nullif(btrim(coalesce(p_courier, '')), '');
  v_ref     text := nullif(btrim(coalesce(p_delivery_ref, '')), '');
  v_slot    text := nullif(btrim(coalesce(p_delivery_slot, '')), '');
  v_note    text := nullif(btrim(coalesce(p_admin_note, '')), '');
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if char_length(coalesce(v_courier, '')) > 60 or char_length(coalesce(v_slot, '')) > 60 then
    raise exception 'Courier and time slot must be 60 characters or fewer.' using hint = 'too_long';
  end if;
  if char_length(coalesce(v_ref, '')) > 300 then
    raise exception 'Booking reference must be 300 characters or fewer.' using hint = 'too_long';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'Note must be 500 characters or fewer.' using hint = 'too_long';
  end if;

  update public.orders
     set courier = v_courier, delivery_ref = v_ref, delivery_slot = v_slot, admin_note = v_note
   where ref_code = upper(btrim(coalesce(p_ref_code, '')));
  if not found then
    raise exception 'Order not found.' using hint = 'order_not_found';
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 2. INVENTORY: ingredients and lots
-- A "lot" is one purchase of an ingredient (e.g. 2 packs of butter bought on
-- Oct 12, best before Nov 2). Stock on hand = the sum of the lots' remaining.
-- Everything is counted in the item's base unit (g, ml, pc or tsp).
-- ----------------------------------------------------------------------------
create table public.ingredients (
  id              bigint generated always as identity primary key,
  name            text not null unique check (char_length(btrim(name)) between 1 and 80),
  category        text not null default 'ingredient' check (category in ('ingredient', 'packaging')),
  unit            text not null check (unit in ('g', 'ml', 'pc', 'tsp')),
  -- How you buy it: "bag 2.5kg" = pack_size 2500 (g) at pack_price. Used to
  -- price things and to round the shopping list up to whole packs.
  pack_label      text check (char_length(pack_label) <= 40),
  pack_size       numeric(12,3) not null default 1 check (pack_size > 0),
  pack_price      numeric(10,2) not null default 0 check (pack_price >= 0),
  -- Price per base unit, worked out for you (₱ per g, per pc...)
  cost_per_unit   numeric generated always as (pack_price / pack_size) stored,
  price_confirmed boolean not null default true,    -- false = a guess, check it
  perishable      boolean not null default false,   -- true = every lot needs an expiry date
  reorder_level   numeric(12,3) not null default 0 check (reorder_level >= 0), -- 0 = no alert
  per_cookie      numeric(12,3) not null default 0 check (per_cookie >= 0),    -- packaging used per cookie sold (e.g. 1 bag)
  supplier        text check (char_length(supplier) <= 120),
  notes           text check (char_length(notes) <= 300),
  active          boolean not null default true
);

create table public.ingredient_lots (
  id             bigint generated always as identity primary key,
  ingredient_id  bigint not null references public.ingredients (id),
  qty_received   numeric(12,3) not null check (qty_received > 0),
  qty_remaining  numeric(12,3) not null check (qty_remaining >= 0),
  unit_cost      numeric not null default 0 check (unit_cost >= 0),   -- ₱ per base unit when bought
  received_on    date not null default ((now() at time zone 'Asia/Manila')::date),
  expires_on     date,                                                 -- null = no expiry tracked
  note           text check (char_length(note) <= 200),
  created_at     timestamptz not null default now()
);
create index ingredient_lots_ing_idx on public.ingredient_lots (ingredient_id, expires_on);

-- Every change to stock, for the "what happened to my butter?" question
create table public.stock_log (
  id             bigint generated always as identity primary key,
  ingredient_id  bigint not null references public.ingredients (id),
  lot_id         bigint references public.ingredient_lots (id),
  delta          numeric(12,3) not null,     -- + received, - used
  reason         text not null check (reason in
                   ('received', 'used_in_batch', 'used_manual', 'count_correction', 'discarded')),
  note           text,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);
create index stock_log_ing_idx on public.stock_log (ingredient_id, created_at desc);


-- ----------------------------------------------------------------------------
-- 3. RECIPES (one per flavor; the quantities are per BATCH)
-- ----------------------------------------------------------------------------
create table public.recipes (
  flavor_id          bigint primary key references public.flavors (id),
  version            text not null default 'RD1' check (char_length(version) <= 20),
  yield              integer not null default 15 check (yield > 0),   -- cookies per batch
  dough_freezer_days integer not null default 28 check (dough_freezer_days > 0), -- default best-by for frozen dough
  notes              text check (char_length(notes) <= 500)
);

create table public.recipe_items (
  id             bigint generated always as identity primary key,
  flavor_id      bigint not null references public.recipes (flavor_id) on delete cascade,
  ingredient_id  bigint not null references public.ingredients (id),
  qty_per_batch  numeric(12,3) not null check (qty_per_batch > 0),
  note           text check (char_length(note) <= 200),
  unique (flavor_id, ingredient_id)
);


-- ----------------------------------------------------------------------------
-- 4. FROZEN DOUGH (balls in the freezer)
-- ----------------------------------------------------------------------------
create table public.dough_lots (
  id          bigint generated always as identity primary key,
  flavor_id   bigint not null references public.flavors (id),
  balls_made  integer not null check (balls_made > 0),
  balls_left  integer not null check (balls_left >= 0),
  made_on     date not null default ((now() at time zone 'Asia/Manila')::date),
  best_by     date not null,
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  check (balls_left <= balls_made)
);
create index dough_lots_flavor_idx on public.dough_lots (flavor_id, best_by);


-- ----------------------------------------------------------------------------
-- SECURITY: RLS on every new table. Only admins can see or change anything.
-- Recipe + ingredient setup can be edited straight from the admin pages. Stock
-- and dough tables are READ-only from the browser; they only change through
-- the functions below, so the log can never be skipped.
-- ----------------------------------------------------------------------------
alter table public.ingredients     enable row level security;
alter table public.ingredient_lots enable row level security;
alter table public.stock_log       enable row level security;
alter table public.recipes         enable row level security;
alter table public.recipe_items    enable row level security;
alter table public.dough_lots      enable row level security;

revoke all on public.ingredients, public.ingredient_lots, public.stock_log,
              public.recipes, public.recipe_items, public.dough_lots
  from public, anon, authenticated;

grant select, insert, update, delete on public.ingredients, public.recipes, public.recipe_items to authenticated;
grant select on public.ingredient_lots, public.stock_log, public.dough_lots to authenticated;

create policy "admins manage ingredients" on public.ingredients
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage recipes" on public.recipes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage recipe items" on public.recipe_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins read lots" on public.ingredient_lots
  for select to authenticated using (public.is_admin());
create policy "admins read stock log" on public.stock_log
  for select to authenticated using (public.is_admin());
create policy "admins read dough" on public.dough_lots
  for select to authenticated using (public.is_admin());


-- ----------------------------------------------------------------------------
-- Stock levels per ingredient (what the Inventory page lists).
-- security_invoker = the viewer's own RLS applies, so non-admins get nothing.
-- "usable" = not past its expiry date today (Manila).
-- ----------------------------------------------------------------------------
create view public.ingredient_stock with (security_invoker = true) as
select
  i.id as ingredient_id, i.name, i.category, i.unit, i.perishable, i.active,
  i.pack_label, i.pack_size, i.pack_price, i.cost_per_unit, i.price_confirmed,
  i.reorder_level, i.per_cookie, i.supplier, i.notes,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on is null or l.expires_on >= t.today), 0)::numeric(12,3) as on_hand,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on < t.today), 0)::numeric(12,3)                         as expired_qty,
  coalesce(sum(l.qty_remaining) filter (where l.expires_on >= t.today and l.expires_on <= t.today + 7), 0)::numeric(12,3) as expiring_soon_qty,
  min(l.expires_on) filter (where l.qty_remaining > 0 and (l.expires_on is null or l.expires_on >= t.today)) as next_expiry,
  (i.reorder_level > 0 and
   coalesce(sum(l.qty_remaining) filter (where l.expires_on is null or l.expires_on >= t.today), 0) <= i.reorder_level) as is_low
from public.ingredients i
cross join (select (now() at time zone 'Asia/Manila')::date as today) t
left join public.ingredient_lots l on l.ingredient_id = i.id and l.qty_remaining > 0
group by i.id, t.today;

grant select on public.ingredient_stock to authenticated;
revoke all on public.ingredient_stock from public, anon;


-- ----------------------------------------------------------------------------
-- Internal helper: take stock out, earliest expiry first (FEFO). Lots already
-- past their expiry are skipped. Not callable from the browser.
-- p_allow_short = true takes whatever is there instead of failing.
-- Returns how much was actually taken.
-- ----------------------------------------------------------------------------
create function public._take_stock(
  p_ingredient_id bigint, p_qty numeric, p_reason text, p_note text, p_allow_short boolean)
returns numeric
language plpgsql security definer set search_path = ''
as $$
declare
  v_left  numeric := p_qty;
  v_lot   record;
  v_take  numeric;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  for v_lot in
    select id, qty_remaining from public.ingredient_lots
    where ingredient_id = p_ingredient_id and qty_remaining > 0
      and (expires_on is null or expires_on >= v_today)
    order by expires_on nulls last, received_on, id
    for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.qty_remaining, v_left);
    update public.ingredient_lots set qty_remaining = qty_remaining - v_take where id = v_lot.id;
    insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
    values (p_ingredient_id, v_lot.id, -v_take, p_reason, p_note);
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 and not p_allow_short then
    raise exception 'Not enough stock (short by %).', v_left using hint = 'short_stock';
  end if;
  return p_qty - v_left;
end $$;
revoke all on function public._take_stock(bigint, numeric, text, text, boolean) from public, anon, authenticated;


-- Bought more? Add a lot. Perishable items must have an expiry date.
-- If you pass the real unit cost, the item's price is updated to match, so
-- costing follows what you actually paid.
create function public.admin_receive_stock(
  p_ingredient_id bigint, p_qty numeric, p_unit_cost numeric default null,
  p_expires_on date default null, p_note text default null)
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
  if v_ing.perishable and p_expires_on is null then
    raise exception 'Add an expiry date: % is perishable.', v_ing.name using hint = 'needs_expiry';
  end if;

  insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining, unit_cost, expires_on, note)
  values (p_ingredient_id, p_qty, p_qty, coalesce(p_unit_cost, v_ing.cost_per_unit), p_expires_on, p_note)
  returning id into v_lot;

  insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
  values (p_ingredient_id, v_lot, p_qty, 'received', p_note);

  if p_unit_cost is not null then
    update public.ingredients
       set pack_price = round(p_unit_cost * pack_size, 2), price_confirmed = true
     where id = p_ingredient_id;
  end if;
  return v_lot;
end $$;

-- Used some by hand (e.g. a test bake, spilled, gifted). Fails if there isn't enough.
create function public.admin_use_stock(p_ingredient_id bigint, p_qty numeric, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity must be more than zero.' using hint = 'bad_qty';
  end if;
  perform public._take_stock(p_ingredient_id, p_qty, 'used_manual', p_note, false);
end $$;

-- Throw away a lot (expired, spoiled)
create function public.admin_discard_lot(p_lot_id bigint, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_lot public.ingredient_lots;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_lot from public.ingredient_lots where id = p_lot_id for update;
  if not found then
    raise exception 'Lot not found.' using hint = 'not_found';
  end if;
  if v_lot.qty_remaining > 0 then
    insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
    values (v_lot.ingredient_id, v_lot.id, -v_lot.qty_remaining, 'discarded', p_note);
    update public.ingredient_lots set qty_remaining = 0 where id = v_lot.id;
  end if;
end $$;

-- Stock take: you counted and the real number is p_actual. Fixes the usable
-- stock to match. Extra stock is added as a lot with no expiry date.
create function public.admin_count_stock(p_ingredient_id bigint, p_actual numeric, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_today   date := (now() at time zone 'Asia/Manila')::date;
  v_current numeric;
  v_lot     bigint;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_actual is null or p_actual < 0 then
    raise exception 'Count can''t be negative.' using hint = 'bad_qty';
  end if;
  perform 1 from public.ingredients where id = p_ingredient_id for update;
  if not found then
    raise exception 'Item not found.' using hint = 'not_found';
  end if;

  select coalesce(sum(qty_remaining), 0) into v_current
  from public.ingredient_lots
  where ingredient_id = p_ingredient_id and (expires_on is null or expires_on >= v_today);

  if p_actual < v_current then
    perform public._take_stock(p_ingredient_id, v_current - p_actual, 'count_correction', p_note, true);
  elsif p_actual > v_current then
    insert into public.ingredient_lots (ingredient_id, qty_received, qty_remaining, unit_cost, note)
    values (p_ingredient_id, p_actual - v_current, p_actual - v_current,
            (select cost_per_unit from public.ingredients where id = p_ingredient_id),
            coalesce(p_note, 'Stock take'))
    returning id into v_lot;
    insert into public.stock_log (ingredient_id, lot_id, delta, reason, note)
    values (p_ingredient_id, v_lot, p_actual - v_current, 'count_correction', p_note);
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- FROZEN DOUGH
-- ----------------------------------------------------------------------------

-- "I mixed N batches": takes the recipe's ingredients out of stock and puts the
-- dough balls in the freezer. If something is short it says what, and stops,
-- unless p_force = true (use when your real stock isn't logged yet).
create function public.admin_record_batch(
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

  -- 2) Take it out of stock (earliest expiry first)
  for v_item in
    select ri.ingredient_id, ri.qty_per_batch * p_batches as need
    from public.recipe_items ri where ri.flavor_id = p_flavor_id
  loop
    perform public._take_stock(v_item.ingredient_id, v_item.need, 'used_in_batch',
                               format('%s x %s', p_batches, v_flavor), true);
  end loop;

  -- 3) Dough into the freezer
  insert into public.dough_lots (flavor_id, balls_made, balls_left, made_on, best_by, note)
  values (p_flavor_id, p_batches * v_recipe.yield, p_batches * v_recipe.yield, v_made,
          coalesce(p_best_by, v_made + v_recipe.dough_freezer_days),
          case when v_short <> '' then 'Forced. Short on: ' || v_short else null end)
  returning id into v_lot;
  return v_lot;
end $$;

-- Took dough balls out of the freezer to bake. Earliest best-by first.
create function public.admin_use_dough(p_flavor_id bigint, p_balls integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_left  integer := p_balls;
  v_lot   record;
  v_take  integer;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_balls is null or p_balls < 1 then
    raise exception 'Enter at least 1 dough ball.' using hint = 'bad_qty';
  end if;

  for v_lot in
    select id, balls_left from public.dough_lots
    where flavor_id = p_flavor_id and balls_left > 0 and best_by >= v_today
    order by best_by, id for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.balls_left, v_left);
    update public.dough_lots set balls_left = balls_left - v_take where id = v_lot.id;
    v_left := v_left - v_take;
  end loop;
  if v_left > 0 then
    raise exception 'Only % usable dough ball(s) in the freezer.', p_balls - v_left using hint = 'no_dough';
  end if;
end $$;

create function public.admin_discard_dough(p_lot_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  update public.dough_lots set balls_left = 0 where id = p_lot_id;
  if not found then
    raise exception 'Dough lot not found.' using hint = 'not_found';
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 5. PRODUCTION PLAN for one Sunday
--
-- For each flavor:   cookies ordered  -  frozen dough already made
--                    = cookies still to make  >  batches (rounded UP)
-- Then ingredients = batches x recipe, plus packaging per cookie, minus what's
-- in stock (stock that will have expired by that Sunday doesn't count), rounded
-- up to whole packs = the shopping list.
--
-- "Cookies ordered" = paid orders, plus unpaid orders still inside their 24h
-- window if p_include_pending (same rule the caps use).
-- ----------------------------------------------------------------------------
create function public.admin_production_plan(p_sunday date, p_include_pending boolean default true)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_flavors  jsonb;
  v_shopping jsonb;
  -- stock that expires before this date won't be usable when it's needed
  v_cutoff   date := greatest(p_sunday, (now() at time zone 'Asia/Manila')::date);
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  -- Per flavor: cookies ordered, dough already frozen, cookies still to make, batches
  select coalesce(jsonb_agg(jsonb_build_object(
           'flavor_id', c.flavor_id, 'slug', c.slug, 'name', c.name,
           'paid_cookies', c.paid, 'pending_cookies', c.pending, 'cookies_needed', c.needed,
           'dough_on_hand', c.dough, 'to_make', c.to_make, 'yield', c.yield,
           'batches', c.batches, 'leftover', c.batches * c.yield - c.to_make,
           'recipe_ready', c.recipe_ready, 'recipe_version', c.version)
         order by c.flavor_id), '[]'::jsonb)
    into v_flavors
  from (
    select b.*,
           greatest(b.needed - b.dough, 0) as to_make,
           ceil(greatest(b.needed - b.dough, 0)::numeric / b.yield)::int as batches
    from (
      select f.id as flavor_id, f.slug, f.name,
             coalesce(o.paid, 0) as paid, coalesce(o.pending, 0) as pending,
             coalesce(o.paid, 0) + case when p_include_pending then coalesce(o.pending, 0) else 0 end as needed,
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
        select flavor_id, sum(balls_left)::int as balls from public.dough_lots
        where balls_left > 0 and best_by >= v_cutoff group by flavor_id
      ) d on d.flavor_id = f.id
      where f.active
    ) b
  ) c;

  -- Shopping list: what the batches need + packaging per cookie sold,
  -- minus usable stock, rounded UP to whole packs
  select coalesce(jsonb_agg(jsonb_build_object(
           'ingredient_id', x.id, 'name', x.name, 'category', x.category, 'unit', x.unit,
           'perishable', x.perishable, 'price_confirmed', x.price_confirmed,
           'needed', x.needed, 'on_hand', x.on_hand, 'short', x.short,
           'pack_label', x.pack_label, 'pack_size', x.pack_size,
           'packs_to_buy', x.packs, 'est_cost', x.packs * x.pack_price)
         order by x.category, x.name), '[]'::jsonb)
    into v_shopping
  from (
    select i.id, i.name, i.category, i.unit, i.perishable, i.price_confirmed,
           i.pack_label, i.pack_size, i.pack_price,
           n.needed, s.on_hand,
           greatest(n.needed - s.on_hand, 0) as short,
           ceil(greatest(n.needed - s.on_hand, 0) / i.pack_size) as packs
    from public.ingredients i
    cross join lateral (
      select coalesce((select sum(ri.qty_per_batch * pf.batches)
                       from public.recipe_items ri
                       join jsonb_to_recordset(v_flavors) as pf(flavor_id bigint, batches int)
                         on pf.flavor_id = ri.flavor_id
                       where ri.ingredient_id = i.id), 0)
             + i.per_cookie * (select coalesce(sum(pf.cookies_needed), 0)
                               from jsonb_to_recordset(v_flavors) as pf(cookies_needed int)) as needed
    ) n
    cross join lateral (
      select coalesce(sum(l.qty_remaining), 0) as on_hand from public.ingredient_lots l
      where l.ingredient_id = i.id and (l.expires_on is null or l.expires_on >= v_cutoff)
    ) s
    where i.active and n.needed > 0
  ) x;

  return jsonb_build_object(
    'sunday', p_sunday,
    'include_pending', p_include_pending,
    'flavors', v_flavors,
    'shopping', v_shopping,
    'totals', jsonb_build_object(
      'cookies', (select coalesce(sum(pf.cookies_needed), 0) from jsonb_to_recordset(v_flavors) as pf(cookies_needed int)),
      'batches', (select coalesce(sum(pf.batches), 0)        from jsonb_to_recordset(v_flavors) as pf(batches int)),
      'est_shopping_cost', coalesce((select sum((e->>'est_cost')::numeric) from jsonb_array_elements(v_shopping) e), 0)));
end $$;


-- ----------------------------------------------------------------------------
-- 6. COSTING: what a cookie costs you vs what you sell it for
-- (ingredients only. Labor, utilities and box packaging are NOT in here.)
-- ----------------------------------------------------------------------------
create view public.flavor_costing with (security_invoker = true) as
select
  f.id as flavor_id, f.slug, f.name,
  r.version as recipe_version, r.yield,
  count(ri.id)::int as items,
  coalesce(sum(ri.qty_per_batch * i.cost_per_unit), 0)::numeric(12,2) as batch_cost,
  (coalesce(sum(ri.qty_per_batch * i.cost_per_unit), 0) / r.yield)::numeric(12,2) as ingredient_cost_per_cookie,
  (select coalesce(sum(p.per_cookie * p.cost_per_unit), 0) from public.ingredients p
     where p.active and p.per_cookie > 0)::numeric(12,2) as packaging_cost_per_cookie,
  count(ri.id) filter (where not i.price_confirmed)::int as assumed_prices,
  f.single_price, f.surcharge
from public.flavors f
join public.recipes r on r.flavor_id = f.id
left join public.recipe_items ri on ri.flavor_id = f.id
left join public.ingredients i on i.id = ri.ingredient_id
where f.active
group by f.id, f.slug, f.name, r.version, r.yield, f.single_price, f.surcharge;

grant select on public.flavor_costing to authenticated;
revoke all on public.flavor_costing from public, anon;


-- ----------------------------------------------------------------------------
-- Who can call what: signed-in users only (each function also checks is_admin())
-- ----------------------------------------------------------------------------
revoke all on function
  public.admin_set_order_prep(text, text),
  public.admin_set_order_delivery(text, text, text, text, text),
  public.admin_receive_stock(bigint, numeric, numeric, date, text),
  public.admin_use_stock(bigint, numeric, text),
  public.admin_discard_lot(bigint, text),
  public.admin_count_stock(bigint, numeric, text),
  public.admin_record_batch(bigint, integer, date, date, boolean),
  public.admin_use_dough(bigint, integer),
  public.admin_discard_dough(bigint),
  public.admin_production_plan(date, boolean)
  from public, anon;

grant execute on function
  public.admin_set_order_prep(text, text),
  public.admin_set_order_delivery(text, text, text, text, text),
  public.admin_receive_stock(bigint, numeric, numeric, date, text),
  public.admin_use_stock(bigint, numeric, text),
  public.admin_discard_lot(bigint, text),
  public.admin_count_stock(bigint, numeric, text),
  public.admin_record_batch(bigint, integer, date, date, boolean),
  public.admin_use_dough(bigint, integer),
  public.admin_discard_dough(bigint),
  public.admin_production_plan(date, boolean)
  to authenticated;
