-- ============================================================================
-- 002_multi_box_orders.sql: one order can hold up to 3 boxes, and an order
-- that doesn't fit this Sunday rolls over to the next Sunday with room.
--
-- Run AFTER 001_init.sql. Changes:
--   1. New table order_boxes (one row per box in an order, with its own gift note).
--   2. order_items now belongs to a box (the same flavor can appear in 2 boxes).
--   3. orders.gift_note is removed (notes are per box now).
--   4. place_order() takes a list of boxes instead of a single box.
--   5. Rollover: if the whole order doesn't fit under the 45-cookie cap on the
--      upcoming Sunday, the DB books it on the first later Sunday that has room.
--      An order is never split across two Sundays.
--   6. current_sunday_info() also reports which Sunday an order would land on.
--
-- Safe to run now: no orders exist yet. (If real orders existed, step 2 would
-- need a data backfill first.)
-- ============================================================================


-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- One row per box inside an order.
create table public.order_boxes (
  id        bigint generated always as identity primary key,
  order_id  bigint not null references public.orders (id) on delete cascade,
  position  smallint not null check (position between 1 and 3),   -- Box 1, 2, 3
  size      int not null check (size > 0),
  price     numeric(8,2) not null check (price >= 0),  -- this box: flat price + surcharges
  gift_note text check (char_length(gift_note) <= 500),
  unique (order_id, position)
);

-- order_items now hang off a box. order_id stays too, so "cookies per Sunday"
-- (cookies_taken) keeps working with a simple join.
alter table public.order_items drop constraint order_items_order_id_flavor_id_key;
alter table public.order_items
  add column order_box_id bigint not null references public.order_boxes (id) on delete cascade;
alter table public.order_items add unique (order_box_id, flavor_id);  -- one row per flavor per box

-- Gift notes live on each box now.
alter table public.orders drop column gift_note;


-- ============================================================================
-- 2. HELPERS (internal; not callable by the browser)
-- ============================================================================

-- Most boxes in one order. Lives in one place, like cap_per_sunday().
create function public.max_boxes_per_order()
returns int language sql immutable set search_path = ''
as $$ select 3 $$;

-- Validates ONE box and returns its price: flat box price + flavor surcharges,
-- all from DB values. Raises a friendly error if anything is off.
-- p_items looks like: [{"flavor_slug":"choc-chip","qty":2}, ...]
create function public.quote_box(p_size int, p_items jsonb)
returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  v_box_price numeric;
  v_sum       bigint;   -- cookies picked
  v_lines     bigint;   -- distinct flavors requested
  v_known     bigint;   -- how many of those exist and are active
  v_surcharge numeric;
begin
  select b.price into v_box_price
  from public.boxes b where b.size = p_size and b.active;
  if not found then
    raise exception 'That box size isn''t available.' using hint = 'invalid_box';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Please pick your flavors.' using hint = 'invalid_items';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as x(flavor_slug text, qty int)
    where x.flavor_slug is null or x.qty is null or x.qty < 1
  ) then
    raise exception 'Each flavor needs a quantity of at least 1.' using hint = 'invalid_items';
  end if;

  -- Merge duplicate slugs, then look the flavors up (left join so unknown or
  -- inactive slugs show up as v_known < v_lines).
  select coalesce(sum(a.qty), 0), count(*), count(f.id), coalesce(sum(a.qty * f.surcharge), 0)
    into v_sum, v_lines, v_known, v_surcharge
  from (
    select x.flavor_slug, sum(x.qty) as qty
    from jsonb_to_recordset(p_items) as x(flavor_slug text, qty int)
    group by x.flavor_slug
  ) a
  left join public.flavors f on f.slug = a.flavor_slug and f.active;

  if v_known <> v_lines then
    raise exception 'One of those flavors isn''t available.' using hint = 'unknown_flavor';
  end if;
  if v_sum <> p_size then
    raise exception 'A box of % needs exactly % cookies, but you picked %.',
      p_size, p_size, v_sum using hint = 'wrong_quantity';
  end if;

  return v_box_price + v_surcharge;
end $$;


-- ============================================================================
-- 3. place_order(...): now takes a list of boxes
-- ============================================================================
-- Old 8-argument version goes away; the browser must call this one.
drop function public.place_order(text, text, text, text, text, text, int, jsonb);

-- p_boxes looks like:
--   [ {"size": 4, "gift_note": "For Tita", "items": [{"flavor_slug":"choc-chip","qty":2},
--                                                    {"flavor_slug":"kinder-bueno","qty":2}]},
--     {"size": 6, "items": [{"flavor_slug":"double-choc","qty":6}]} ]
-- There is NO price anywhere in the input: every price comes from the DB.
-- Whole call = one transaction: any RAISE EXCEPTION undoes everything.
create function public.place_order(
  p_name        text,
  p_ig_handle   text,
  p_phone       text,
  p_fulfillment text,
  p_address     text,
  p_boxes       jsonb
)
returns table (ref_code text, total numeric, sunday_date date)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_name     text := btrim(coalesce(p_name, ''));
  v_phone    text := btrim(coalesce(p_phone, ''));
  v_address  text := nullif(btrim(coalesce(p_address, '')), '');
  v_box      jsonb;
  v_pos      bigint;
  v_size     int;
  v_note     text;
  v_price    numeric;
  v_prices   numeric[] := '{}';   -- price of each box, in order
  v_total    numeric := 0;
  v_cookies  int := 0;            -- cookies in the whole order
  v_sunday   date;
  v_found    boolean := false;
  v_ref      text;
  v_order_id bigint;
  v_box_id   bigint;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O/1/I to avoid mixups
  v_bytes    bytea;
  i          int;
begin
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

  -- ---- Boxes: 1 to 3 -------------------------------------------------------
  if jsonb_typeof(p_boxes) is distinct from 'array'
     or jsonb_array_length(p_boxes) not between 1 and public.max_boxes_per_order() then
    raise exception 'An order needs 1 to % boxes.', public.max_boxes_per_order()
      using hint = 'invalid_boxes';
  end if;

  -- Pass 1: validate every box and price it from the DB.
  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(p_boxes) with ordinality as b(value, ordinality)
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

  -- ---- Which Sunday? First one (from the upcoming one onward) with room ---
  -- The WHOLE order goes on one Sunday; if it doesn't fit, we try the next.
  v_sunday := public.next_order_sunday(now());
  for week in 1..12 loop
    -- Lock per Sunday so two people ordering at the same instant can't both
    -- squeeze past the cap. Always locked earliest-first, so no deadlocks.
    -- Locks release automatically when this transaction ends.
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
      -- 256 % 32 = 0, so mapping a byte onto 32 characters is unbiased
      v_ref := v_ref || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1);
    end loop;

    begin
      insert into public.orders
        (ref_code, sunday_date, name, ig_handle, phone, fulfillment, address, total)
      values
        (v_ref, v_sunday, v_name, nullif(btrim(coalesce(p_ig_handle, '')), ''), v_phone,
         p_fulfillment, v_address, v_total)
      returning id into v_order_id;
      exit;  -- inserted fine
    exception when unique_violation then
      v_order_id := null;  -- code collision: loop and try a new code
    end;
  end loop;

  if v_order_id is null then
    raise exception 'Something went wrong, please try again.' using hint = 'ref_code_failed';
  end if;

  -- Pass 2: save each box and its items (already validated above).
  for v_box, v_pos in
    select b.value, b.ordinality from jsonb_array_elements(p_boxes) with ordinality as b(value, ordinality)
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

  return query select v_ref, v_total, v_sunday;
end $$;


-- ============================================================================
-- 4. current_sunday_info(): also says where a new order would land
-- ============================================================================
-- sunday_date .. is_full : the UPCOMING Sunday and its capacity (as before)
-- ordering_*             : the first Sunday that still has room for the
--                          smallest box. Same as sunday_date unless that one
--                          is full; this is what the banner should show.
-- (An order bigger than the room left can still roll over; the date returned
-- by place_order is always the real one.)
drop function public.current_sunday_info();

create function public.current_sunday_info()
returns table (sunday_date date, cutoff_at timestamptz, cap int, cookies_taken int,
               remaining int, is_full boolean,
               ordering_sunday date, ordering_cutoff_at timestamptz, ordering_remaining int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_first    date := public.next_order_sunday(now());
  v_taken    int  := public.cookies_taken(v_first);
  v_min_box  int  := (select coalesce(min(b.size), 1) from public.boxes b where b.active);
  v_ordering date := v_first;
  v_o_taken  int  := v_taken;
begin
  -- Walk forward until a Sunday has room for at least the smallest box.
  for week in 1..12 loop
    exit when public.cap_per_sunday() - v_o_taken >= v_min_box;
    v_ordering := v_ordering + 7;
    v_o_taken  := public.cookies_taken(v_ordering);
  end loop;

  return query select
    v_first,
    public.sunday_cutoff(v_first),
    public.cap_per_sunday(),
    v_taken,
    greatest(public.cap_per_sunday() - v_taken, 0),
    (public.cap_per_sunday() - v_taken) < v_min_box,
    v_ordering,
    public.sunday_cutoff(v_ordering),
    greatest(public.cap_per_sunday() - v_o_taken, 0);
end $$;


-- ============================================================================
-- 5. SECURITY for the new table and functions
-- ============================================================================
alter table public.order_boxes enable row level security;
revoke all on public.order_boxes from anon, authenticated;

-- Only admins can read order_boxes (anon: no grant, no policy).
grant select on public.order_boxes to authenticated;
create policy "admins read order boxes" on public.order_boxes
  for select to authenticated using (public.is_admin());

-- Lock new functions from everyone, then open only what the browser needs.
revoke all on function
  public.max_boxes_per_order(), public.quote_box(int, jsonb),
  public.place_order(text, text, text, text, text, jsonb),
  public.current_sunday_info()
  from public, anon, authenticated;

grant execute on function
  public.place_order(text, text, text, text, text, jsonb),
  public.current_sunday_info()
  to anon, authenticated;
-- max_boxes_per_order and quote_box stay internal.
