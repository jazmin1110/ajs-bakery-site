-- ============================================================================
-- 007_flavor_caps.sql: the Sunday limit is now PER FLAVOR (15 of each), not 45 total.
--
-- How it works:
--   * flavors.weekly_cap (default 15): how many of that flavor we bake per Sunday.
--   * "Reserved" for a flavor on a Sunday = its cookies in paid orders plus pending
--     orders that haven't expired, counting box cookies AND single cookies.
--   * The ORDERING Sunday is the first Sunday (from the cutoff rule) that still has
--     at least 2 cookies left across all flavors. So when every flavor is sold out,
--     ordering moves to the next Sunday by itself.
--   * place_order checks every flavor in the order against that Sunday. Over a
--     flavor's cap = rejected, with a message that names the flavor and how many are
--     left. (It does NOT silently push a single flavor's overflow to next week.)
--   * flavor_availability() lets the website show "3 left" / "Sold out".
--
-- The old 45-total rule (cap_per_sunday) is removed. Run after 006.
-- ============================================================================

-- ---- 1. the per-flavor cap ----------------------------------------------------
-- The default fills in 15 for the flavors that already exist.
alter table public.flavors
  add column weekly_cap int not null default 15 check (weekly_cap >= 0);

-- ---- 2. helpers (internal) -----------------------------------------------------

-- Per active flavor on one Sunday: its cap, how many are reserved, how many remain.
create function public.flavor_reserved(p_sunday date)
returns table (flavor_id bigint, slug text, name text, weekly_cap int, reserved int, remaining int)
language sql stable set search_path = ''
as $$
  select f.id, f.slug, f.name, f.weekly_cap,
         coalesce(r.qty, 0)::int,
         greatest(f.weekly_cap - coalesce(r.qty, 0), 0)::int
  from public.flavors f
  left join (
    select i.flavor_id, sum(i.qty) as qty
    from public.order_items i
    join public.orders o on o.id = i.order_id
    where o.sunday_date = p_sunday
      and (o.status = 'paid' or (o.status = 'pending' and o.expires_at > now()))
    group by i.flavor_id
  ) r on r.flavor_id = f.id
  where f.active
  order by f.id
$$;

-- The Sunday a new order lands on: the first one (starting from the cutoff rule)
-- that still has at least the minimum order (2 cookies) left across all flavors.
-- Null if the next 12 Sundays are all sold out.
create function public.ordering_sunday()
returns date
language plpgsql stable set search_path = ''
as $$
declare
  v_sunday date := public.next_order_sunday(now());
begin
  for week in 1..12 loop
    if (select coalesce(sum(r.remaining), 0) from public.flavor_reserved(v_sunday) r)
         >= public.min_cookies_per_order() then
      return v_sunday;
    end if;
    v_sunday := v_sunday + 7;
  end loop;
  return null;
end $$;

-- ---- 3. what the website calls: remaining cookies per flavor --------------------
-- For the current ordering Sunday. One row per active flavor.
create function public.flavor_availability()
returns table (sunday_date date, slug text, name text, weekly_cap int, reserved int, remaining int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_sunday date := coalesce(public.ordering_sunday(), public.next_order_sunday(now()));
begin
  return query
    select v_sunday, r.slug, r.name, r.weekly_cap, r.reserved, r.remaining
    from public.flavor_reserved(v_sunday) r;
end $$;

-- ---- 4. place_order: per-flavor limits instead of the 45 total ---------------------
-- Same arguments and return fields as 006. Changes: the Sunday comes from
-- ordering_sunday(), and each flavor in the order is checked against its cap.
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

  -- ---- Order size rules ---------------------------------------------------------
  if v_cookies = 0 then
    raise exception 'Please add something to your order.' using hint = 'empty_order';
  end if;
  if v_cookies < public.min_cookies_per_order() then
    raise exception 'The minimum order is % cookies. You have %.', public.min_cookies_per_order(), v_cookies
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

-- ---- 5. the banner info: totals are now sums across flavors ------------------------------
-- Same columns as before. cap = all flavors' caps added up, remaining = all flavors' leftovers.
-- is_full = fewer than 2 cookies left across all flavors (i.e. effectively sold out).
create or replace function public.current_sunday_info()
returns table (sunday_date date, cutoff_at timestamptz, cap int, cookies_taken int,
               remaining int, is_full boolean,
               ordering_sunday date, ordering_cutoff_at timestamptz, ordering_remaining int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_first    date := public.next_order_sunday(now());
  v_ordering date := coalesce(public.ordering_sunday(), public.next_order_sunday(now()));
  v_cap      int;
  v_taken    int;
  v_left     int;
  v_o_left   int;
begin
  select coalesce(sum(r.weekly_cap), 0), coalesce(sum(r.reserved), 0), coalesce(sum(r.remaining), 0)
    into v_cap, v_taken, v_left
  from public.flavor_reserved(v_first) r;

  select coalesce(sum(r.remaining), 0) into v_o_left from public.flavor_reserved(v_ordering) r;

  return query select
    v_first,
    public.sunday_cutoff(v_first),
    v_cap,
    v_taken,
    v_left,
    v_left < public.min_cookies_per_order(),
    v_ordering,
    public.sunday_cutoff(v_ordering),
    v_o_left;
end $$;

-- ---- 6. admin: bringing an order back needs room in EACH of its flavors ---------------------
create or replace function public.admin_set_order_status(p_ref_code text, p_status text)
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

  -- Is this order currently NOT holding cookies (cancelled, expired, or a pending one
  -- past its deadline) but about to hold them again? Then every flavor needs room.
  if p_status in ('paid', 'pending')
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

-- ---- 7. retire the old 45-total rule -------------------------------------------------------
drop function public.cap_per_sunday();

-- ---- 8. permissions -------------------------------------------------------------------------
revoke all on function
  public.flavor_reserved(date), public.ordering_sunday(), public.flavor_availability()
  from public, anon, authenticated;
grant execute on function public.flavor_availability() to anon, authenticated;
-- flavor_reserved and ordering_sunday stay internal.
