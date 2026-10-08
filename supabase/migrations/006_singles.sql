-- ============================================================================
-- 006_singles.sql: order single cookies, alongside boxes.
-- (You asked for "002_singles.sql", but 001-005 already exist, so it's 006.)
--
-- Rules (also in CLAUDE.md):
--   * single prices: Chimp Chips 105, Coco Loco 110, Bueno Mucho 135
--   * minimum 2 cookies per order (singles and boxes combined)
--   * singles count toward the 45-cookie Sunday cap
--   * every price, the minimum and the cap are decided HERE, never by the browser
--
-- How singles are stored: as order_items rows with order_box_id = NULL (loose
-- cookies) and a unit_price (the single price at the moment of the order, so
-- later price changes never rewrite history). Cookies inside boxes keep a box id
-- and no unit_price. cookies_taken() already counts every order_items row, so the
-- cap includes singles with no change.
--
-- Backward compatible: place_order gets an OPTIONAL p_singles argument, so the
-- website code that is live right now keeps working until the new code ships.
-- Run after 005.
-- ============================================================================

-- ---- 1. single prices ---------------------------------------------------------
alter table public.flavors
  add column single_price numeric(8,2) check (single_price >= 0);  -- null = not sold as a single

update public.flavors set single_price = case slug
    when 'choc-chip'    then 105
    when 'double-choc'  then 110
    when 'kinder-bueno' then 135
  end
where slug in ('choc-chip', 'double-choc', 'kinder-bueno');

-- ---- 2. order_items can be loose singles --------------------------------------
alter table public.order_items alter column order_box_id drop not null;
alter table public.order_items add column unit_price numeric(8,2) check (unit_price >= 0);

-- A row is EITHER a box item (has a box, no unit price) OR a single (no box, has a unit price)
alter table public.order_items
  add constraint order_items_box_or_single check ((order_box_id is null) = (unit_price is not null));

-- At most one singles row per flavor per order (box items already have unique(order_box_id, flavor_id))
create unique index order_items_single_unique
  on public.order_items (order_id, flavor_id) where order_box_id is null;

-- ---- 3. helpers (internal) ------------------------------------------------------
create function public.min_cookies_per_order()
returns int language sql immutable set search_path = ''
as $$ select 2 $$;

-- Validates the loose singles and prices them from the DB.
-- p_singles looks like: [{"flavor_slug":"choc-chip","qty":2}, ...]   (null / [] = none)
-- Any "price" field the browser sneaks in is simply never read.
create function public.quote_singles(p_singles jsonb)
returns table (total numeric, cookies bigint)
language plpgsql stable set search_path = ''
as $$
#variable_conflict use_column
declare
  v_lines bigint;
  v_known bigint;
begin
  if p_singles is null or p_singles = '[]'::jsonb then
    return query select 0::numeric, 0::bigint;
    return;
  end if;
  if jsonb_typeof(p_singles) is distinct from 'array' then
    raise exception 'Please check your single cookies.' using hint = 'invalid_items';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_singles) as x(flavor_slug text, qty int)
    where x.flavor_slug is null or x.qty is null or x.qty < 1
  ) then
    raise exception 'Each single cookie needs a quantity of at least 1.' using hint = 'invalid_items';
  end if;

  -- Merge duplicate slugs, then look each flavor up. Left join: a flavor that is
  -- unknown, inactive, or has no single price shows up as v_known < v_lines.
  select count(*), count(f.id) into v_lines, v_known
  from (
    select x.flavor_slug from jsonb_to_recordset(p_singles) as x(flavor_slug text, qty int) group by x.flavor_slug
  ) a
  left join public.flavors f on f.slug = a.flavor_slug and f.active and f.single_price is not null;

  if v_known <> v_lines then
    raise exception 'One of those flavors isn''t available as a single cookie.' using hint = 'unknown_flavor';
  end if;

  return query
    select sum(a.qty * f.single_price), sum(a.qty)::bigint
    from (
      select x.flavor_slug, sum(x.qty) as qty
      from jsonb_to_recordset(p_singles) as x(flavor_slug text, qty int)
      group by x.flavor_slug
    ) a
    join public.flavors f on f.slug = a.flavor_slug;
end $$;

-- ---- 4. place_order: boxes AND singles -------------------------------------------
-- Replaces the 7-argument version from 003 (a new argument list means drop + create).
drop function public.place_order(text, text, text, text, text, jsonb, uuid);

-- p_boxes   : [] or up to 3 boxes, same shape as before
-- p_singles : [] / null or [{"flavor_slug": "...", "qty": n}, ...]
-- There is NO price anywhere in the input. Returns the same three fields as before.
create function public.place_order(
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
  v_found    boolean := false;
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

  -- ---- Order size rules ---------------------------------------------------------
  if v_cookies = 0 then
    raise exception 'Please add something to your order.' using hint = 'empty_order';
  end if;
  if v_cookies < public.min_cookies_per_order() then
    raise exception 'The minimum order is % cookies. You have %.', public.min_cookies_per_order(), v_cookies
      using hint = 'minimum_not_met';
  end if;
  if v_cookies > public.cap_per_sunday() then
    raise exception 'That''s more than the % cookies we bake in a Sunday. Please order fewer.', public.cap_per_sunday()
      using hint = 'too_many_cookies';
  end if;

  -- ---- Which Sunday? First one (from the upcoming one onward) with room ---
  v_sunday := public.next_order_sunday(now());
  for week in 1..12 loop
    -- Lock per Sunday so two people ordering at the same instant can't both
    -- squeeze past the cap. Always locked earliest-first, so no deadlocks.
    perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_sunday::text));
    if public.cookies_taken(v_sunday) + v_cookies <= public.cap_per_sunday() then
      v_found := true;
      exit;
    end if;
    v_sunday := v_sunday + 7;
  end loop;

  if not v_found then
    raise exception 'Sorry, we''re fully booked for the next few weeks.' using hint = 'sunday_full';
  end if;

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

revoke all on function
  public.min_cookies_per_order(), public.quote_singles(jsonb),
  public.place_order(text, text, text, text, text, jsonb, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.place_order(text, text, text, text, text, jsonb, uuid, jsonb)
  to anon, authenticated;
-- min_cookies_per_order and quote_singles stay internal.

-- ---- 5. the banner: "full" now means fewer than the smallest possible order ----------
-- Smallest order is now 2 cookies (two singles), not a box of 4.
create or replace function public.current_sunday_info()
returns table (sunday_date date, cutoff_at timestamptz, cap int, cookies_taken int,
               remaining int, is_full boolean,
               ordering_sunday date, ordering_cutoff_at timestamptz, ordering_remaining int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_first    date := public.next_order_sunday(now());
  v_taken    int  := public.cookies_taken(v_first);
  v_min      int  := public.min_cookies_per_order();
  v_ordering date := v_first;
  v_o_taken  int  := v_taken;
begin
  for week in 1..12 loop
    exit when public.cap_per_sunday() - v_o_taken >= v_min;
    v_ordering := v_ordering + 7;
    v_o_taken  := public.cookies_taken(v_ordering);
  end loop;

  return query select
    v_first,
    public.sunday_cutoff(v_first),
    public.cap_per_sunday(),
    v_taken,
    greatest(public.cap_per_sunday() - v_taken, 0),
    (public.cap_per_sunday() - v_taken) < v_min,
    v_ordering,
    public.sunday_cutoff(v_ordering),
    greatest(public.cap_per_sunday() - v_o_taken, 0);
end $$;

-- ---- 6. admin_orders also returns the singles -----------------------------------------
-- Same as 005 plus 'singles' (loose cookies with the price they were sold at).
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
