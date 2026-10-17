-- ============================================================================
-- 015_manual_orders_sales.sql
--
-- ADDITIVE. The customer side (place_order, caps, cutoff) is not changed.
--
--   1. MANUAL ORDERS   admin_create_order(): add an order taken by Instagram,
--                      Messenger, walk-in... Same prices and the same 15-per-flavor
--                      cap as the website (with a deliberate "add anyway"), so the
--                      bake plan and "sold out" stay right. You pick the Sunday.
--                      orders.source (website / instagram / messenger / walk_in /
--                      other) and orders.payment_method (gcash / bank / cash / other).
--                      Phone becomes optional for manual orders only.
--   2. PACKAGING       baking dough balls (admin_use_dough) now also takes the
--                      packaging out of stock (per_cookie on each item, e.g. 1 bag).
--   3. RESTOCK         the shopping list also tops items up to their reorder level,
--                      and lists low items even when this week doesn't need them.
--   4. BEST SELLERS    admin_sales_report(from, to): cookies sold per flavor, share,
--                      money, how often it sold out, and a week-by-week series.
--
-- Run after 014.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. MANUAL ORDERS: where the order came from + how it was paid
-- ----------------------------------------------------------------------------
alter table public.orders
  add column source text not null default 'website'
    constraint orders_source_check
    check (source in ('website', 'instagram', 'messenger', 'walk_in', 'other')),
  add column payment_method text
    constraint orders_payment_method_check
    check (payment_method in ('gcash', 'bank', 'cash', 'other'));

-- Phone: still required for website orders (place_order checks it too), optional for
-- orders you enter yourself (an Instagram DM often has no number).
alter table public.orders alter column phone drop not null;
alter table public.orders drop constraint orders_phone_check;
alter table public.orders
  add constraint orders_phone_check
    check (phone is null or char_length(btrim(phone)) between 7 and 20),
  add constraint orders_phone_needed_online
    check (source <> 'website' or phone is not null);

-- The "3 unpaid orders per phone" rule is for the public website, not for you.
create or replace function public.limit_open_orders()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.source <> 'website' or new.phone is null then
    return new;
  end if;
  -- Compare the last 10 digits, so 0917..., +63917... and 63917... count as the same phone
  if (select count(*)
      from public.orders o
      where o.status = 'pending'
        and o.expires_at > now()
        and o.phone is not null
        and right(regexp_replace(o.phone, '\D', '', 'g'), 10)
          = right(regexp_replace(new.phone, '\D', '', 'g'), 10)) >= 3 then
    raise exception 'You already have 3 orders waiting for payment. Please pay for one of them first, or message us on Instagram.'
      using hint = 'too_many_open_orders';
  end if;
  return new;
end $$;

-- Add an order yourself.
--   p_boxes / p_singles: same shape as the website ([{size, items:[{flavor_slug, qty}], gift_note}], [{flavor_slug, qty}])
--   p_payment: 'paid'        = already paid (say how in p_payment_method)
--              'unpaid'      = not paid yet, releases after 24 hours like a website order
--              'pay_on_day'  = pays at pickup/delivery, keeps the slot until that Sunday 6pm
--   p_allow_over_cap: true = go past a flavor's 15 on purpose (you decided to bake extra)
-- Prices are worked out here (quote_box / quote_singles), never sent from the browser.
create function public.admin_create_order(
  p_sunday date, p_name text, p_phone text, p_ig_handle text, p_source text,
  p_fulfillment text, p_address text, p_boxes jsonb, p_singles jsonb,
  p_payment text, p_payment_method text default null, p_gcash_ref text default null,
  p_note text default null, p_allow_over_cap boolean default false)
returns table (ref_code text, total numeric, sunday_date date)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_name     text := btrim(coalesce(p_name, ''));
  v_phone    text := nullif(btrim(coalesce(p_phone, '')), '');
  v_ig       text := nullif(btrim(coalesce(p_ig_handle, '')), '');
  v_address  text := nullif(btrim(coalesce(p_address, '')), '');
  v_ref_in   text := nullif(regexp_replace(coalesce(p_gcash_ref, ''), '\D', '', 'g'), '');
  v_boxes    jsonb := coalesce(p_boxes, '[]'::jsonb);
  v_singles  jsonb := coalesce(p_singles, '[]'::jsonb);
  v_today    date := (now() at time zone 'Asia/Manila')::date;
  v_box      jsonb;
  v_pos      bigint;
  v_prices   numeric[] := '{}';
  v_price    numeric;
  v_total    numeric := 0;
  v_cookies  bigint := 0;
  v_s_total  numeric := 0;
  v_s_count  bigint := 0;
  v_need     record;
  v_over     text := '';
  v_left     int;
  v_fname    text;
  v_ref      text;
  v_order_id bigint;
  v_box_id   bigint;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes    bytea;
  i          int;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  -- ---- Checks ------------------------------------------------------------------
  if p_sunday is null or extract(dow from p_sunday) <> 0 then
    raise exception 'Pick a Sunday.' using hint = 'invalid_sunday';
  end if;
  if p_sunday < v_today then
    raise exception 'That Sunday has already passed.' using hint = 'invalid_sunday';
  end if;
  if v_name = '' or char_length(v_name) > 100 then
    raise exception 'Enter the customer''s name.' using hint = 'invalid_name';
  end if;
  if v_phone is not null and char_length(v_phone) not between 7 and 20 then
    raise exception 'That phone number doesn''t look right (or leave it blank).' using hint = 'invalid_phone';
  end if;
  if p_source is null or p_source not in ('instagram', 'messenger', 'walk_in', 'other') then
    raise exception 'Where did this order come from?' using hint = 'invalid_source';
  end if;
  if p_fulfillment is null or p_fulfillment not in ('pickup', 'delivery') then
    raise exception 'Choose pickup or delivery.' using hint = 'invalid_fulfillment';
  end if;
  if p_fulfillment = 'delivery' and v_address is null then
    raise exception 'Enter the delivery address.' using hint = 'address_required';
  end if;
  if p_fulfillment = 'pickup' then v_address := null; end if;
  if p_payment is null or p_payment not in ('paid', 'unpaid', 'pay_on_day') then
    raise exception 'Say whether it''s paid.' using hint = 'invalid_payment';
  end if;
  if p_payment = 'paid' and (p_payment_method is null or p_payment_method not in ('gcash', 'bank', 'cash', 'other')) then
    raise exception 'How was it paid? GCash, bank, cash or other.' using hint = 'invalid_payment';
  end if;
  if v_ref_in is not null and v_ref_in !~ '^[0-9]{10,15}$' then
    raise exception 'A GCash reference is 10 to 15 digits (or leave it blank).' using hint = 'invalid_gcash_ref';
  end if;
  if v_ref_in is not null and exists (select 1 from public.orders o where o.gcash_ref = v_ref_in) then
    raise exception 'That GCash reference is already on another order.' using hint = 'duplicate_gcash_ref';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'Note must be 500 characters or fewer.' using hint = 'too_long';
  end if;
  if jsonb_typeof(v_boxes) is distinct from 'array' or jsonb_array_length(v_boxes) > 10 then
    raise exception 'Up to 10 boxes per order.' using hint = 'invalid_boxes';
  end if;

  -- ---- Price it the same way the website does --------------------------------------
  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
  loop
    if jsonb_typeof(v_box -> 'size') is distinct from 'number' then
      raise exception 'Box % is missing its size.', v_pos using hint = 'invalid_boxes';
    end if;
    if char_length(coalesce(v_box ->> 'gift_note', '')) > 500 then
      raise exception 'The gift note on box % is too long.', v_pos using hint = 'note_too_long';
    end if;
    v_price   := public.quote_box((v_box ->> 'size')::int, v_box -> 'items');   -- raises on any problem
    v_prices  := v_prices || v_price;
    v_total   := v_total + v_price;
    v_cookies := v_cookies + (v_box ->> 'size')::int;
  end loop;

  select s.total, s.cookies into v_s_total, v_s_count from public.quote_singles(v_singles) s;
  v_total   := v_total + v_s_total;
  v_cookies := v_cookies + v_s_count;
  if v_cookies < 1 then
    raise exception 'Add at least one cookie.' using hint = 'empty_order';
  end if;

  -- ---- Weekly cap: same lock + count as the website --------------------------------
  perform public.expire_stale_orders();
  perform pg_advisory_xact_lock(hashtext('ajs-cap-' || p_sunday::text));
  for v_need in
    select x.flavor_slug, sum(x.qty)::int as qty
    from (
      select e ->> 'flavor_slug' as flavor_slug, (e ->> 'qty')::int as qty
      from jsonb_array_elements(v_boxes) as bx, jsonb_array_elements(bx -> 'items') as e
      union all
      select e ->> 'flavor_slug', (e ->> 'qty')::int from jsonb_array_elements(v_singles) as e
    ) x
    group by x.flavor_slug
  loop
    select r.remaining, r.name into v_left, v_fname
    from public.flavor_reserved(p_sunday) r where r.slug = v_need.flavor_slug;
    if v_left < v_need.qty then
      v_over := v_over || case when v_over = '' then '' else ', ' end
                || format('%s (%s left, this order has %s)', v_fname, v_left, v_need.qty);
    end if;
  end loop;
  if v_over <> '' and not p_allow_over_cap then
    raise exception 'Over the weekly cap for %: %.', to_char(p_sunday, 'Mon DD'), v_over
      using hint = 'flavor_cap';
  end if;

  -- ---- Save it ---------------------------------------------------------------------
  for attempt in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_ref := 'AJ-';
    for i in 0..5 loop
      v_ref := v_ref || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1);
    end loop;
    begin
      insert into public.orders
        (ref_code, sunday_date, name, ig_handle, phone, fulfillment, address, total,
         status, gcash_ref, expires_at, source, payment_method, admin_note)
      values
        (v_ref, p_sunday, v_name, v_ig, v_phone, p_fulfillment, v_address, v_total,
         case when p_payment = 'paid' then 'paid' else 'pending' end,
         v_ref_in,
         case p_payment
           when 'unpaid' then now() + interval '24 hours'
           -- pays on the day: hold the slot until that Sunday, 6pm Manila
           when 'pay_on_day' then (p_sunday + time '18:00') at time zone 'Asia/Manila'
           else now() + interval '24 hours' end,
         p_source,
         case when p_payment = 'paid' then p_payment_method
              when p_payment = 'pay_on_day' then coalesce(p_payment_method, 'cash') else p_payment_method end,
         nullif(btrim(coalesce(p_note, '')), ''))
      returning id into v_order_id;
      exit;
    exception when unique_violation then
      v_order_id := null;
    end;
  end loop;
  if v_order_id is null then
    raise exception 'Something went wrong, please try again.' using hint = 'ref_code_failed';
  end if;

  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
  loop
    insert into public.order_boxes (order_id, position, size, price, gift_note)
    values (v_order_id, v_pos, (v_box ->> 'size')::int, v_prices[v_pos],
            nullif(btrim(coalesce(v_box ->> 'gift_note', '')), ''))
    returning id into v_box_id;

    insert into public.order_items (order_id, order_box_id, flavor_id, qty)
    select v_order_id, v_box_id, f.id, a.qty
    from (select x.flavor_slug, sum(x.qty) as qty
          from jsonb_to_recordset(v_box -> 'items') as x(flavor_slug text, qty int) group by x.flavor_slug) a
    join public.flavors f on f.slug = a.flavor_slug;
  end loop;

  if v_s_count > 0 then
    insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price)
    select v_order_id, null, f.id, a.qty, f.single_price
    from (select x.flavor_slug, sum(x.qty) as qty
          from jsonb_to_recordset(v_singles) as x(flavor_slug text, qty int) group by x.flavor_slug) a
    join public.flavors f on f.slug = a.flavor_slug;
  end if;

  return query select v_ref, v_total, p_sunday;
end $$;

-- admin_orders: same as 014, plus source and payment_method
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
        'prep_status',    o.prep_status,
        'courier',        o.courier,
        'delivery_ref',   o.delivery_ref,
        'delivery_slot',  o.delivery_slot,
        'admin_note',     o.admin_note,
        'completed_at',   o.completed_at,
        'source',         o.source,          -- new in 015
        'payment_method', o.payment_method,  -- new in 015
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


-- ----------------------------------------------------------------------------
-- 2. PACKAGING leaves stock when you bake
-- Same as 014, plus: every item with per_cookie > 0 (e.g. 1 bag per cookie) is taken
-- out for each dough ball baked. Takes whatever is logged if it's short (never blocks baking).
-- ----------------------------------------------------------------------------
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

  for v_pack in
    select id, per_cookie from public.ingredients where active and per_cookie > 0
  loop
    perform public._take_stock(v_pack.id, v_pack.per_cookie * p_balls, 'used_in_batch',
      format('packaging for %s baked', p_balls), true);
  end loop;
end $$;


-- Fix from 014: "save anyway" with many ingredients short made the dough note longer
-- than its 200-character limit, so the save failed. Same function, note cut to 200.
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
          case when v_short <> '' then left('Forced. Short on: ' || v_short, 200) else null end)  -- note max is 200 characters
  returning id into v_lot;
  return v_lot;
end $$;


-- ----------------------------------------------------------------------------
-- 3. PRODUCTION PLAN: same as 014, but the shopping list now
--    * buys enough to still have the reorder level left after this week, and
--    * lists low items even if this week doesn't use them.
-- ----------------------------------------------------------------------------
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
             + i.per_cookie * (select coalesce(sum(pf.cookies_needed), 0)
                               from jsonb_to_recordset(v_flavors) as pf(cookies_needed int)) as needed
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
      'batches', (select coalesce(sum(pf.batches), 0)        from jsonb_to_recordset(v_flavors) as pf(batches int)),
      'est_shopping_cost', coalesce((select sum((e->>'est_cost')::numeric) from jsonb_array_elements(v_shopping) e), 0)));
end $$;


-- ----------------------------------------------------------------------------
-- 4. BEST SELLERS between two Sundays (inclusive). PAID orders only.
--   cookies     = cookies of that flavor sold (boxes + singles)
--   in_boxes / as_singles = where they were picked (box picks = free choice in a mix box)
--   revenue     = singles at their price; box cookies get an even share of the box
--                 price, plus that flavor's surcharge (e.g. Bueno +30). An estimate.
--   orders      = how many orders had at least one
--   sold_out_weeks = Sundays it reached its cap (demand was at least the cap)
--   weeks       = week-by-week cookies, for the chart
-- ----------------------------------------------------------------------------
create function public.admin_sales_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  with sold as (
    select o.id as order_id, o.sunday_date, i.flavor_id, i.qty,
           (i.order_box_id is not null) as in_box,
           case when i.order_box_id is null then i.qty * coalesce(i.unit_price, 0)
                else i.qty * ((b.price - bs.extra) / b.size + coalesce(f.surcharge, 0)) end as revenue
    from public.orders o
    join public.order_items i on i.order_id = o.id
    join public.flavors f on f.id = i.flavor_id
    left join public.order_boxes b on b.id = i.order_box_id
    left join lateral (       -- the surcharges inside this box, taken off before splitting the box price
      select coalesce(sum(i2.qty * coalesce(f2.surcharge, 0)), 0) as extra
      from public.order_items i2 join public.flavors f2 on f2.id = i2.flavor_id
      where i2.order_box_id = b.id
    ) bs on true
    where o.status = 'paid' and o.sunday_date between p_from and p_to
  ),
  weekly as (
    select sunday_date, flavor_id, sum(qty)::int as cookies from sold group by sunday_date, flavor_id
  ),
  per_flavor as (
    select f.id, f.slug, f.name, f.weekly_cap,
           coalesce(sum(s.qty), 0)::int as cookies,
           coalesce(sum(s.qty) filter (where s.in_box), 0)::int as in_boxes,
           coalesce(sum(s.qty) filter (where not s.in_box), 0)::int as as_singles,
           round(coalesce(sum(s.revenue), 0), 2) as revenue,
           count(distinct s.order_id)::int as orders
    from public.flavors f
    left join sold s on s.flavor_id = f.id
    where f.active or exists (select 1 from sold s2 where s2.flavor_id = f.id)
    group by f.id
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'weeks_with_sales', (select count(distinct sunday_date) from sold),
    'total_cookies', (select coalesce(sum(qty), 0) from sold),
    'total_orders', (select count(distinct order_id) from sold),
    'sundays', coalesce((select jsonb_agg(d order by d) from (select distinct sunday_date as d from sold) x), '[]'::jsonb),
    'flavors', coalesce((
      select jsonb_agg(jsonb_build_object(
        'flavor_id', p.id, 'slug', p.slug, 'name', p.name, 'cap', p.weekly_cap,
        'cookies', p.cookies, 'in_boxes', p.in_boxes, 'as_singles', p.as_singles,
        'revenue', p.revenue, 'orders', p.orders,
        'sold_out_weeks', (select count(*) from weekly w where w.flavor_id = p.id and w.cookies >= p.weekly_cap),
        'weeks', coalesce((select jsonb_agg(jsonb_build_object('sunday', w.sunday_date, 'cookies', w.cookies) order by w.sunday_date)
                           from weekly w where w.flavor_id = p.id), '[]'::jsonb))
        order by p.cookies desc, p.revenue desc, p.name)
      from per_flavor p), '[]'::jsonb))
  into v_out;
  return v_out;
end $$;


-- ----------------------------------------------------------------------------
-- Who can call what
-- ----------------------------------------------------------------------------
revoke all on function
  public.admin_create_order(date, text, text, text, text, text, text, jsonb, jsonb, text, text, text, text, boolean),
  public.admin_sales_report(date, date)
  from public, anon;
grant execute on function
  public.admin_create_order(date, text, text, text, text, text, text, jsonb, jsonb, text, text, text, text, boolean),
  public.admin_sales_report(date, date)
  to authenticated;
