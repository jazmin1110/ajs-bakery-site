-- ============================================================================
-- 003_idempotent_orders.sql: stop double orders when a phone loses signal.
--
-- The problem: a customer taps "Place order", the database saves it, but the
-- reply never reaches their phone. They tap "Try again" and a SECOND order is
-- created (it holds cookie slots until it expires 24 hours later).
--
-- The fix: the browser makes up a random "idempotency key" (a UUID) for each
-- order attempt and sends the SAME key when retrying. If an order with that key
-- already exists, place_order returns that order instead of creating another.
--
-- Backward compatible: the new parameter is optional (default null), so a call
-- WITHOUT a key behaves exactly as before. Run after 002.
-- ============================================================================

alter table public.orders add column idempotency_key uuid unique;  -- null = no key sent

-- Same function as 002 plus the optional key. The argument list changes, so the
-- old version has to be dropped first.
drop function public.place_order(text, text, text, text, text, jsonb);

create function public.place_order(
  p_name            text,
  p_ig_handle       text,
  p_phone           text,
  p_fulfillment     text,
  p_address         text,
  p_boxes           jsonb,
  p_idempotency_key uuid default null
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
  -- ---- Retry of an order we already saved? Hand back the original. ---------
  -- The lock makes two simultaneous retries line up one behind the other, so
  -- the second one always finds the first one's order.
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
      -- 256 % 32 = 0, so mapping a byte onto 32 characters is unbiased
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

-- Permissions: same as before. Closed to everyone, then opened for the browser.
-- (The idempotency_key column is not readable by anon: orders has no anon grant.)
revoke all on function public.place_order(text, text, text, text, text, jsonb, uuid)
  from public, anon, authenticated;
grant execute on function public.place_order(text, text, text, text, text, jsonb, uuid)
  to anon, authenticated;
