-- ============================================================================
-- 008_pickup_delivery_minimums.sql: new order minimums.
--
--   PICKUP   : at least 1 cookie
--   DELIVERY : at least 2 cookies OR at least P200 (either one is enough)
--
-- (It used to be a flat 2 cookies for everyone.) Both rules are decided here, by
-- the database, using its own prices: the browser only shows the rule.
-- Run after 007.
-- ============================================================================

-- The smallest order that can exist (pickup): 1 cookie. ordering_sunday() and
-- current_sunday_info() use this to decide when a Sunday counts as "sold out".
create or replace function public.min_cookies_per_order()
returns int language sql immutable set search_path = ''
as $$ select 1 $$;

create function public.min_delivery_cookies()
returns int language sql immutable set search_path = ''
as $$ select 2 $$;

create function public.min_delivery_total()
returns numeric language sql immutable set search_path = ''
as $$ select 200::numeric $$;

revoke all on function public.min_delivery_cookies(), public.min_delivery_total()
  from public, anon, authenticated;

-- place_order: same as 007, except the minimum check depends on pickup vs delivery.
create or replace function public.place_order(
  p_name            text,
  p_ig_handle       text,
  p_phone           text,
  p_fulfillment     text,
  p_address         text,
  p_boxes           jsonb,
  p_idempotency_key uuid default null,
  p_singles         jsonb default null
)
returns table (ref_code text, total numeric, sunday_date date)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_name     text := btrim(coalesce(p_name, ''));
  v_phone    text := btrim(coalesce(p_phone, ''));
  v_address  text := nullif(btrim(coalesce(p_address, '')), '');
  v_boxes    jsonb := coalesce(p_boxes, '[]'::jsonb);
  v_box      jsonb;
  v_pos      bigint;
  v_size     int;
  v_note     text;
  v_price    numeric;
  v_prices   numeric[] := '{}';   -- price of each box, in order
  v_total    numeric := 0;
  v_cookies  bigint := 0;         -- cookies in the whole order: boxes + singles
  v_s_total  numeric := 0;        -- what the singles cost
  v_s_count  bigint := 0;         -- how many single cookies
  v_sunday   date;
  v_need     record;              -- one flavor's quantity across the whole order
  v_left     int;
  v_ref      text;
  v_order_id bigint;
  v_box_id   bigint;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O/1/I to avoid mixups
  v_bytes    bytea;
  i          int;
begin
  -- ---- Retry of an order we already saved? Hand back the original. ---------
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtext('ajs-idem-' || p_idempotency_key::text));
    return query
      select o.ref_code, o.total, o.sunday_date
      from public.orders o
      where o.idempotency_key = p_idempotency_key;
    if found then
      return;
    end if;
  end if;

  -- Free up slots from orders that were never paid.
  perform public.expire_stale_orders();

  -- ---- Basic field checks ------------------------------------------------
  if v_name = '' or char_length(v_name) > 100 then
    raise exception 'Please enter your name.' using hint = 'invalid_name';
  end if;
  if char_length(v_phone) not between 7 and 20 then
    raise exception 'Please enter a valid phone number.' using hint = 'invalid_phone';
  end if;
  if p_fulfillment is null or p_fulfillment not in ('pickup', 'delivery') then
    raise exception 'Please choose pickup or delivery.' using hint = 'invalid_fulfillment';
  end if;
  if p_fulfillment = 'delivery' and v_address is null then
    raise exception 'Please enter a delivery address.' using hint = 'address_required';
  end if;
  if p_fulfillment = 'pickup' then
    v_address := null;  -- don't store an address nobody needs
  end if;

  -- ---- Boxes: 0 to 3 -------------------------------------------------------
  if jsonb_typeof(v_boxes) is distinct from 'array'
     or jsonb_array_length(v_boxes) > public.max_boxes_per_order() then
    raise exception 'An order can have at most % boxes.', public.max_boxes_per_order()
      using hint = 'invalid_boxes';
  end if;

  -- Pass 1: validate every box and price it from the DB.
  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
  loop
    if jsonb_typeof(v_box) is distinct from 'object'
       or jsonb_typeof(v_box -> 'size') is distinct from 'number'
       or (v_box ->> 'size') !~ '^[0-9]+$' then
      raise exception 'Box % is missing its size.', v_pos using hint = 'invalid_boxes';
    end if;
    if char_length(coalesce(v_box ->> 'gift_note', '')) > 500 then
      raise exception 'The gift note on box % is too long (500 characters max).', v_pos
        using hint = 'note_too_long';
    end if;

    v_size   := (v_box ->> 'size')::int;
    v_price  := public.quote_box(v_size, v_box -> 'items');  -- raises on any problem
    v_prices := v_prices || v_price;
    v_total  := v_total + v_price;
    v_cookies := v_cookies + v_size;
  end loop;

  -- ---- Singles, priced from flavors.single_price -----------------------------
  select s.total, s.cookies into v_s_total, v_s_count from public.quote_singles(p_singles) s;
  v_total   := v_total + v_s_total;
  v_cookies := v_cookies + v_s_count;

  -- ---- Order minimums (pickup: 1 cookie. delivery: 2 cookies or P200) ----------------
  if v_cookies < public.min_cookies_per_order() then
    raise exception 'Please add something to your order.' using hint = 'empty_order';
  end if;
  if p_fulfillment = 'delivery'
     and v_cookies < public.min_delivery_cookies()
     and v_total < public.min_delivery_total() then
    raise exception 'Delivery orders need at least % cookies or ₱%. Add a little more, or switch to pickup.',
      public.min_delivery_cookies(), public.min_delivery_total()::int
      using hint = 'minimum_not_met';
  end if;

  -- ---- Which Sunday? The first one with cookies left (moves on when all flavors sell out) ----
  v_sunday := public.ordering_sunday();
  if v_sunday is null then
    raise exception 'Sorry, we''re fully booked for the next few weeks.' using hint = 'sunday_full';
  end if;

  -- Lock this Sunday so two people ordering the last cookies at the same instant
  -- can't both get them. The lock is released automatically when this call ends.
  perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_sunday::text));

  -- ---- Per-flavor cap: every flavor in the order (boxes + singles together) must fit ----
  for v_need in
    select x.flavor_slug, sum(x.qty)::int as qty
    from (
      select e ->> 'flavor_slug' as flavor_slug, (e ->> 'qty')::int as qty
      from jsonb_array_elements(v_boxes) as bx, jsonb_array_elements(bx -> 'items') as e
      union all
      select e ->> 'flavor_slug', (e ->> 'qty')::int
      from jsonb_array_elements(coalesce(p_singles, '[]'::jsonb)) as e
    ) x
    group by x.flavor_slug
  loop
    select r.remaining into v_left
    from public.flavor_reserved(v_sunday) r
    where r.slug = v_need.flavor_slug;

    if v_left < v_need.qty then
      if v_left = 0 then
        raise exception '% is sold out for Sunday %.',
          (select f.name from public.flavors f where f.slug = v_need.flavor_slug), to_char(v_sunday, 'Mon DD')
          using hint = 'flavor_cap';
      else
        raise exception 'Sorry, only % % left for Sunday %. You asked for %.',
          v_left, (select f.name from public.flavors f where f.slug = v_need.flavor_slug),
          to_char(v_sunday, 'Mon DD'), v_need.qty
          using hint = 'flavor_cap';
      end if;
    end if;
  end loop;

  -- ---- Unique, hard-to-guess ref code: AJ- + 6 random characters ----------
  for attempt in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_ref := 'AJ-';
    for i in 0..5 loop
      v_ref := v_ref || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1);
    end loop;

    begin
      insert into public.orders
        (ref_code, sunday_date, name, ig_handle, phone, fulfillment, address, total, idempotency_key)
      values
        (v_ref, v_sunday, v_name, nullif(btrim(coalesce(p_ig_handle, '')), ''), v_phone,
         p_fulfillment, v_address, v_total, p_idempotency_key)
      returning id into v_order_id;
      exit;  -- inserted fine
    exception when unique_violation then
      v_order_id := null;  -- code collision: loop and try a new code
    end;
  end loop;

  if v_order_id is null then
    raise exception 'Something went wrong, please try again.' using hint = 'ref_code_failed';
  end if;

  -- Pass 2a: save each box and its items (already validated above).
  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(v_boxes) with ordinality as b(value, ordinality)
  loop
    v_note := nullif(btrim(coalesce(v_box ->> 'gift_note', '')), '');

    insert into public.order_boxes (order_id, position, size, price, gift_note)
    values (v_order_id, v_pos, (v_box ->> 'size')::int, v_prices[v_pos], v_note)
    returning id into v_box_id;

    insert into public.order_items (order_id, order_box_id, flavor_id, qty)
    select v_order_id, v_box_id, f.id, a.qty
    from (
      select x.flavor_slug, sum(x.qty) as qty
      from jsonb_to_recordset(v_box -> 'items') as x(flavor_slug text, qty int)
      group by x.flavor_slug
    ) a
    join public.flavors f on f.slug = a.flavor_slug;
  end loop;

  -- Pass 2b: save the loose singles (no box, with the price they were sold at).
  if v_s_count > 0 then
    insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price)
    select v_order_id, null, f.id, a.qty, f.single_price
    from (
      select x.flavor_slug, sum(x.qty) as qty
      from jsonb_to_recordset(p_singles) as x(flavor_slug text, qty int)
      group by x.flavor_slug
    ) a
    join public.flavors f on f.slug = a.flavor_slug;
  end if;

  return query select v_ref, v_total, v_sunday;
end $$;
