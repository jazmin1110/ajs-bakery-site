-- ============================================================================
-- 018_admin_fixes.sql: fixes and missing pieces found in a full check of the admin.
--
--   1. BAKE PLAN BUG   Cookies you already baked for a Sunday ("I baked these")
--                      weren't counted, so after baking the plan asked you to
--                      make them AGAIN and the shopping list grew. Now
--                      to make = ordered - already baked - frozen dough.
--   2. DELETE AN ITEM  admin_delete_ingredient: deletes a stock item that was
--                      never used. One with purchases/history can only be hidden
--                      (deleting it would break your real costs and profit).
--   3. CHANGE A UNIT   admin_change_unit: switch an item's unit (e.g. pieces to
--                      grams) and convert every number that uses it: stock,
--                      purchases, history, recipes, pack size, reorder level.
--   4. EDIT AN ORDER   admin_update_order: fix name / phone / Instagram /
--                      pickup or delivery / address, move it to another Sunday,
--                      and change its cookies (re-priced here, cap checked).
--   5. REOPEN OVER CAP admin_set_order_status gets p_allow_over_cap, so a late
--                      payment can be accepted even if the flavor sold out since
--                      (same "add anyway" choice as Add order).
--
-- Customer side (place_order, caps, cutoff) is not touched. Run after 017.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. PRODUCTION PLAN: same as 015, plus cookies already baked for this Sunday
--    (bake_log, kind 'baked') are taken off before working out what to make.
--    Packaging is also only counted for cookies not baked yet (baking already
--    took their bags out of stock).
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
           'baked', c.baked, 'still_to_bake', c.still_to_bake,                 -- new in 018
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
             + i.per_cookie * (select coalesce(sum(pf.still_to_bake), 0)
                               from jsonb_to_recordset(v_flavors) as pf(still_to_bake int)) as needed
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


-- ----------------------------------------------------------------------------
-- 2. DELETE A STOCK ITEM
-- Only if it was never bought, used or put in a recipe (a typo, a test item).
-- Anything with history is hidden instead, so old costs and profit stay right.
-- ----------------------------------------------------------------------------
create function public.admin_delete_ingredient(p_ingredient_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_ing     public.ingredients;
  v_recipes text;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id for update;
  if not found then
    raise exception 'Item not found.' using hint = 'not_found';
  end if;

  select string_agg(f.name, ', ' order by f.id) into v_recipes
  from public.recipe_items ri join public.flavors f on f.id = ri.flavor_id
  where ri.ingredient_id = p_ingredient_id;
  if v_recipes is not null then
    raise exception '% is in the % recipe. Take it out on the Recipes page first.', v_ing.name, v_recipes
      using hint = 'in_recipe';
  end if;

  if exists (select 1 from public.ingredient_lots where ingredient_id = p_ingredient_id)
     or exists (select 1 from public.stock_log where ingredient_id = p_ingredient_id) then
    raise exception '% has purchases in its history, so it can''t be deleted (your costs use them). Hide it instead.', v_ing.name
      using hint = 'has_history';
  end if;

  delete from public.ingredients where id = p_ingredient_id;
end $$;


-- ----------------------------------------------------------------------------
-- 3. CHANGE AN ITEM'S UNIT
-- p_factor = how many of the NEW unit make one of the OLD unit.
--   pieces -> grams, one egg is 50 g     : p_factor = 50
--   grams  -> ml,    1 g is about 1 ml   : p_factor = 1
--   tsp    -> g,     1 tsp salt is 6 g   : p_factor = 6
-- Every amount is multiplied by it and every per-unit price divided by it, so
-- what you paid, stock value and costs stay exactly the same.
-- ----------------------------------------------------------------------------
create function public.admin_change_unit(p_ingredient_id bigint, p_unit text, p_factor numeric)
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
  exception when check_violation then
    raise exception 'That makes some amounts too small to store (under 0.001 %). Check the number.', p_unit
      using hint = 'bad_factor';
  end;
end $$;


-- ----------------------------------------------------------------------------
-- 4. EDIT AN ORDER
--   Customer details: name, phone, Instagram, pickup/delivery, address.
--   p_sunday       : move it to another Sunday (null = keep)
--   p_boxes/p_singles: the new cookies, same shape as admin_create_order.
--                    Both null = cookies unchanged (not re-priced).
--   p_allow_over_cap: go past a flavor's cap on purpose.
-- The cap is only checked when the order holds cookies (paid, or unpaid and not
-- expired) and its cookies or Sunday change. The order's own cookies don't
-- count against it. Returns the new and the old total, so the page can say
-- "collect P30 more" or "give back P30" on a paid order.
-- ----------------------------------------------------------------------------
create function public.admin_update_order(
  p_ref_code text, p_name text, p_phone text, p_ig_handle text, p_fulfillment text, p_address text,
  p_sunday date default null, p_boxes jsonb default null, p_singles jsonb default null,
  p_allow_over_cap boolean default false)
returns table (ref_code text, total numeric, old_total numeric, sunday_date date)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_order    public.orders;
  v_name     text := btrim(coalesce(p_name, ''));
  v_phone    text := nullif(btrim(coalesce(p_phone, '')), '');
  v_ig       text := nullif(btrim(coalesce(p_ig_handle, '')), '');
  v_address  text := nullif(btrim(coalesce(p_address, '')), '');
  v_sunday   date;
  v_today    date := (now() at time zone 'Asia/Manila')::date;
  v_items    boolean := p_boxes is not null or p_singles is not null;
  v_boxes    jsonb := coalesce(p_boxes, '[]'::jsonb);
  v_singles  jsonb := coalesce(p_singles, '[]'::jsonb);
  v_live     boolean;
  v_box      jsonb;
  v_pos      bigint;
  v_prices   numeric[] := '{}';
  v_price    numeric;
  v_total    numeric;
  v_cookies  bigint := 0;
  v_s_total  numeric := 0;
  v_s_count  bigint := 0;
  v_need     record;
  v_over     text := '';
  v_box_id   bigint;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select * into v_order from public.orders
  where ref_code = upper(btrim(coalesce(p_ref_code, ''))) for update;
  if not found then
    raise exception 'Order not found.' using hint = 'order_not_found';
  end if;
  v_sunday := coalesce(p_sunday, v_order.sunday_date);
  v_total  := v_order.total;

  -- ---- Checks ------------------------------------------------------------------
  if v_name = '' or char_length(v_name) > 100 then
    raise exception 'Enter the customer''s name.' using hint = 'invalid_name';
  end if;
  if v_phone is not null and char_length(v_phone) not between 7 and 20 then
    raise exception 'That phone number doesn''t look right.' using hint = 'invalid_phone';
  end if;
  if v_phone is null and v_order.source = 'website' then
    raise exception 'Website orders need a phone number.' using hint = 'invalid_phone';
  end if;
  if char_length(coalesce(v_ig, '')) > 60 then
    raise exception 'Instagram handle is too long.' using hint = 'too_long';
  end if;
  if p_fulfillment is null or p_fulfillment not in ('pickup', 'delivery') then
    raise exception 'Choose pickup or delivery.' using hint = 'invalid_fulfillment';
  end if;
  if p_fulfillment = 'delivery' and v_address is null then
    raise exception 'Enter the delivery address.' using hint = 'address_required';
  end if;
  if char_length(coalesce(v_address, '')) > 300 then
    raise exception 'Address must be 300 characters or fewer.' using hint = 'too_long';
  end if;
  if p_fulfillment = 'pickup' then v_address := null; end if;
  if extract(dow from v_sunday) <> 0 then
    raise exception 'Pick a Sunday.' using hint = 'invalid_sunday';
  end if;
  if v_sunday <> v_order.sunday_date and v_sunday < v_today then
    raise exception 'That Sunday has already passed.' using hint = 'invalid_sunday';
  end if;
  -- A pickup order that's already out for delivery would be stuck: put it back to Ready
  if p_fulfillment = 'pickup' and v_order.prep_status = 'out_for_delivery' then
    update public.orders set prep_status = 'ready' where id = v_order.id;
  end if;

  -- ---- New cookies: price them exactly like a new order ---------------------------
  if v_items then
    if jsonb_typeof(v_boxes) is distinct from 'array' or jsonb_array_length(v_boxes) > 10 then
      raise exception 'Up to 10 boxes per order.' using hint = 'invalid_boxes';
    end if;
    v_total := 0;
    for v_box, v_pos in
      select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
    loop
      if jsonb_typeof(v_box -> 'size') is distinct from 'number' then
        raise exception 'Box % is missing its size.', v_pos using hint = 'invalid_boxes';
      end if;
      if char_length(coalesce(v_box ->> 'gift_note', '')) > 500 then
        raise exception 'The gift note on box % is too long.', v_pos using hint = 'note_too_long';
      end if;
      v_price   := public.quote_box((v_box ->> 'size')::int, v_box -> 'items');
      v_prices  := v_prices || v_price;
      v_total   := v_total + v_price;
      v_cookies := v_cookies + (v_box ->> 'size')::int;
    end loop;
    select s.total, s.cookies into v_s_total, v_s_count from public.quote_singles(v_singles) s;
    v_total   := v_total + v_s_total;
    v_cookies := v_cookies + v_s_count;
    if v_cookies < 1 then
      raise exception 'An order needs at least one cookie. To drop it, cancel it instead.' using hint = 'empty_order';
    end if;
  end if;

  -- ---- Cap: only when it holds cookies and what it holds (or where) changes -------
  v_live := v_order.status = 'paid' or (v_order.status = 'pending' and v_order.expires_at > now());
  if v_live and (v_items or v_sunday <> v_order.sunday_date) then
    perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_sunday::text));
    for v_need in
      with want as (
        select e ->> 'flavor_slug' as slug, (e ->> 'qty')::int as qty
        from jsonb_array_elements(v_boxes) as bx, jsonb_array_elements(bx -> 'items') as e where v_items
        union all
        select e ->> 'flavor_slug', (e ->> 'qty')::int from jsonb_array_elements(v_singles) as e where v_items
        union all                                                   -- cookies unchanged: what it has now
        select f.slug, i.qty from public.order_items i join public.flavors f on f.id = i.flavor_id
        where i.order_id = v_order.id and not v_items
      )
      select f.name, f.weekly_cap, sum(w.qty)::int as qty,
             coalesce((select sum(i.qty) from public.order_items i join public.orders o on o.id = i.order_id
                       where i.flavor_id = f.id and o.sunday_date = v_sunday and o.id <> v_order.id
                         and (o.status = 'paid' or (o.status = 'pending' and o.expires_at > now()))), 0)::int as others
      from want w join public.flavors f on f.slug = w.slug
      group by f.id, f.name, f.weekly_cap
    loop
      if v_need.others + v_need.qty > v_need.weekly_cap then
        v_over := v_over || case when v_over = '' then '' else ', ' end
                  || format('%s (%s left, this order has %s)', v_need.name,
                            greatest(v_need.weekly_cap - v_need.others, 0), v_need.qty);
      end if;
    end loop;
    if v_over <> '' and not p_allow_over_cap then
      raise exception 'Over the weekly cap for %: %.', to_char(v_sunday, 'Mon DD'), v_over using hint = 'flavor_cap';
    end if;
  end if;

  -- ---- Save --------------------------------------------------------------------------
  update public.orders
     set name = v_name, phone = v_phone, ig_handle = v_ig, fulfillment = p_fulfillment,
         address = v_address, sunday_date = v_sunday, total = v_total,
         -- "pays on the day" holds the slot until that Sunday 6pm: follow the move
         expires_at = case when status = 'pending' and v_sunday <> v_order.sunday_date
                             and expires_at = (v_order.sunday_date + time '18:00') at time zone 'Asia/Manila'
                           then (v_sunday + time '18:00') at time zone 'Asia/Manila' else expires_at end
   where id = v_order.id;

  if v_items then
    delete from public.order_items where order_id = v_order.id;      -- singles + box cookies
    delete from public.order_boxes where order_id = v_order.id;
    for v_box, v_pos in
      select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
    loop
      insert into public.order_boxes (order_id, position, size, price, gift_note)
      values (v_order.id, v_pos, (v_box ->> 'size')::int, v_prices[v_pos],
              nullif(btrim(coalesce(v_box ->> 'gift_note', '')), ''))
      returning id into v_box_id;
      insert into public.order_items (order_id, order_box_id, flavor_id, qty)
      select v_order.id, v_box_id, f.id, a.qty
      from (select x.flavor_slug, sum(x.qty) as qty
            from jsonb_to_recordset(v_box -> 'items') as x(flavor_slug text, qty int) group by x.flavor_slug) a
      join public.flavors f on f.slug = a.flavor_slug;
    end loop;
    if v_s_count > 0 then
      insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price)
      select v_order.id, null, f.id, a.qty, f.single_price
      from (select x.flavor_slug, sum(x.qty) as qty
            from jsonb_to_recordset(v_singles) as x(flavor_slug text, qty int) group by x.flavor_slug) a
      join public.flavors f on f.slug = a.flavor_slug;
    end if;
  end if;

  return query select v_order.ref_code, v_total, v_order.total, v_sunday;
end $$;


-- ----------------------------------------------------------------------------
-- 5. ORDER STATUS: same as 007, plus p_allow_over_cap (reopen / accept a late
--    payment even if the flavor sold out in the meantime).
-- ----------------------------------------------------------------------------
drop function public.admin_set_order_status(text, text);
create function public.admin_set_order_status(p_ref_code text, p_status text, p_allow_over_cap boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.orders;
  v_need  record;
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('pending', 'paid', 'cancelled') then
    raise exception 'Status must be pending, paid or cancelled.' using hint = 'invalid_status';
  end if;

  select * into v_order from public.orders
  where ref_code = upper(btrim(coalesce(p_ref_code, ''))) for update;
  if not found then
    raise exception 'Order not found.' using hint = 'order_not_found';
  end if;
  if v_order.status = p_status then
    return;  -- already there, nothing to do
  end if;

  if p_status in ('paid', 'pending') and not p_allow_over_cap
     and (v_order.status in ('cancelled', 'expired')
          or (v_order.status = 'pending' and v_order.expires_at <= now())) then
    perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_order.sunday_date::text));
    for v_need in
      select r.name, r.remaining, sum(i.qty)::int as qty
      from public.order_items i
      join public.flavor_reserved(v_order.sunday_date) r on r.flavor_id = i.flavor_id
      where i.order_id = v_order.id
      group by r.name, r.remaining
    loop
      if v_need.qty > v_need.remaining then
        raise exception 'There''s no room left on % for % (% left, this order has %).',
          to_char(v_order.sunday_date, 'Mon DD'), v_need.name, v_need.remaining, v_need.qty
          using hint = 'flavor_cap';
      end if;
    end loop;
  end if;

  update public.orders
     set status = p_status,
         expires_at = case when p_status = 'pending' then now() + interval '24 hours' else expires_at end
   where id = v_order.id;
end $$;


-- ----------------------------------------------------------------------------
-- Who can call what (each function also checks is_admin())
-- ----------------------------------------------------------------------------
revoke all on function
  public.admin_delete_ingredient(bigint),
  public.admin_change_unit(bigint, text, numeric),
  public.admin_update_order(text, text, text, text, text, text, date, jsonb, jsonb, boolean),
  public.admin_set_order_status(text, text, boolean)
  from public, anon;
grant execute on function
  public.admin_delete_ingredient(bigint),
  public.admin_change_unit(bigint, text, numeric),
  public.admin_update_order(text, text, text, text, text, text, date, jsonb, jsonb, boolean),
  public.admin_set_order_status(text, text, boolean)
  to authenticated;
