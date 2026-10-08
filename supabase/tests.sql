-- tests.sql: proves the security and ordering rules actually work.
-- Written for the schema AFTER 001_init.sql + 002_multi_box_orders.sql + seed.sql.
--
-- HOW TO RUN: paste ONE test block at a time into the Supabase SQL editor and
-- run it. Each block says PASS (a NOTICE in the results panel) or fails with
-- an error. Every block ends in ROLLBACK, so no test data is left behind.
-- Run on a dev/empty project: tests (c)-(g) assume no real orders are booked
-- yet for the upcoming Sundays (real orders would eat into the 45-cookie cap).
--
-- "set local role anon" makes the block behave like a website visitor, which
-- is what proves the rules hold for real customers (the SQL editor itself
-- runs as the all-powerful postgres user).
--
-- Orders are now a list of boxes, e.g. a box of 4 with 2 choc chip + 2 bueno:
--   '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":2}]}]'


-- ===========================================================================
-- TEST 0: next_order_sunday gives the right Sunday (the 6 cases from the
-- 001 comments). Read-only.
-- ===========================================================================
do $$
begin
  assert public.next_order_sunday('2026-10-07 20:59+08') = '2026-10-11', 'Wed 20:59 should be Oct 11';
  assert public.next_order_sunday('2026-10-07 21:01+08') = '2026-10-18', 'Wed 21:01 should be Oct 18';
  assert public.next_order_sunday('2026-10-07 21:00+08') = '2026-10-18', 'Wed 21:00 sharp should be Oct 18';
  assert public.next_order_sunday('2026-10-10 12:00+08') = '2026-10-18', 'Saturday should be Oct 18';
  assert public.next_order_sunday('2026-10-11 10:00+08') = '2026-10-18', 'Sunday should be Oct 18';
  assert public.next_order_sunday('2026-10-05 09:00+08') = '2026-10-11', 'Monday should be Oct 11';
  raise notice 'PASS (0): next_order_sunday matches all 6 cases';
end $$;


-- ===========================================================================
-- (a) A website visitor (anon) cannot read or write orders or their boxes.
-- ===========================================================================
begin;
do $$
begin
  set local role anon;
  begin
    perform 1 from public.orders;
    raise exception 'FAIL (a): anon could SELECT from orders';
  exception when insufficient_privilege then
    raise notice 'PASS (a): anon is blocked from orders (permission denied)';
  end;
  begin
    perform 1 from public.order_boxes;
    raise exception 'FAIL (a): anon could SELECT from order_boxes';
  exception when insufficient_privilege then
    raise notice 'PASS (a): anon is blocked from order_boxes';
  end;
  begin
    insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total)
    values ('AJ-HACKED', '2026-10-18', 'x', '09170000000', 'pickup', 0);
    raise exception 'FAIL (a): anon could INSERT into orders';
  exception when insufficient_privilege then
    raise notice 'PASS (a): anon is blocked from inserting into orders';
  end;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (b) A bad flavor sum is rejected (box of 4 with only 3 cookies). A valid
-- two-box order works, and the DB computes the total itself:
--   box of 4 with 2 Bueno = 380 + 2*30 = 440, plus box of 6 = 570  ->  1010
-- ===========================================================================
begin;
do $$
declare r record;
begin
  set local role anon;

  begin
    perform 1 from public.place_order('Test', '@test', '09171234567', 'pickup', null,
      '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"double-choc","qty":1}]}]'::jsonb);
    raise exception 'FAIL (b): a 3-cookie box of 4 was accepted';
  exception when others then
    if sqlerrm not like '%needs exactly%' then raise; end if;   -- re-raise the FAIL above
    raise notice 'PASS (b): bad sum rejected -> %', sqlerrm;
  end;

  select * into r from public.place_order('Test', '@test', '09171234567', 'pickup', null,
    '[{"size":4,"gift_note":"For Tita","items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":2}]},
      {"size":6,"items":[{"flavor_slug":"double-choc","qty":6}]}]'::jsonb);
  assert r.total = 1010, 'total should be 440 + 570 = 1010, got ' || r.total;
  raise notice 'PASS (b): two-box order accepted, ref %, total %, Sunday %', r.ref_code, r.total, r.sunday_date;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (c) The cap and rollover. We pretend 41 cookies are already paid on the
-- upcoming Sunday:
--   * a box of 4 lands EXACTLY on 45 -> allowed, stays on that Sunday
--   * the next box of 4 would be the 46th+ cookie -> NOT rejected any more:
--     it rolls over to the following Sunday
--   * a 2-box order (8 cookies) that doesn't fit moves WHOLE to the next
--     Sunday (never split)
-- ===========================================================================
begin;
do $$
declare
  v_sunday date := public.next_order_sunday();
  v_order  bigint;
  v_flavor bigint := (select id from public.flavors where slug = 'choc-chip');
  v_box    bigint;
  r record;
  box4 text := '{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}';
begin
  -- Fixture (runs as postgres, bypassing the rules): a paid order of 41 cookies.
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid')
  returning id into v_order;
  insert into public.order_boxes (order_id, position, size, price) values (v_order, 1, 6, 0)
  returning id into v_box;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty) values (v_order, v_box, v_flavor, 41);

  set local role anon;

  -- 41 + 4 = 45: allowed, stays on this Sunday.
  select * into r from public.place_order('Test', null, '09171234567', 'pickup', null, ('[' || box4 || ']')::jsonb);
  assert r.sunday_date = v_sunday, 'exactly 45 should stay on ' || v_sunday || ', got ' || r.sunday_date;
  raise notice 'PASS (c): order reaching exactly 45 stays on % ', r.sunday_date;

  -- 45 + 4 would be the 46th+ cookie: rolls over to next Sunday.
  select * into r from public.place_order('Test2', null, '09171234567', 'pickup', null, ('[' || box4 || ']')::jsonb);
  assert r.sunday_date = v_sunday + 7, 'should roll to ' || (v_sunday + 7) || ', got ' || r.sunday_date;
  raise notice 'PASS (c): the 46th cookie rolls over to % (a week later)', r.sunday_date;

  -- Banner function agrees: upcoming Sunday is full, ordering Sunday is the next one.
  declare i record; begin
    select * into i from public.current_sunday_info();
    assert i.is_full and i.sunday_date = v_sunday and i.ordering_sunday = v_sunday + 7,
      'current_sunday_info should say full and point to the next Sunday';
    raise notice 'PASS (c): current_sunday_info says full, ordering for %', i.ordering_sunday;
  end;

  reset role;
end $$;
rollback;

-- Whole-order rollover (never split a 2-box order across Sundays)
begin;
do $$
declare
  v_sunday date := public.next_order_sunday();
  v_order  bigint;
  v_flavor bigint := (select id from public.flavors where slug = 'choc-chip');
  v_box    bigint;
  r record;
  box4 text := '{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}';
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid')
  returning id into v_order;
  insert into public.order_boxes (order_id, position, size, price) values (v_order, 1, 6, 0)
  returning id into v_box;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty) values (v_order, v_box, v_flavor, 41);

  set local role anon;
  -- 41 + 8 = 49 > 45: the whole order moves to next Sunday.
  select * into r from public.place_order('Test', null, '09171234567', 'pickup', null,
    ('[' || box4 || ',' || box4 || ']')::jsonb);
  assert r.sunday_date = v_sunday + 7, 'whole 2-box order should roll to ' || (v_sunday + 7);
  reset role;
  assert (select count(*) from public.orders where sunday_date = v_sunday and ref_code <> 'AJ-FIXTURE') = 0,
    'nothing should have been split onto the full Sunday';
  raise notice 'PASS (c): 2-box order that does not fit moved whole to %', r.sunday_date;
end $$;
rollback;


-- ===========================================================================
-- (d) A GCash reference number can't be reused on a second order.
-- Also checks bad formats are rejected.
-- ===========================================================================
begin;
do $$
declare a record; b record;
begin
  set local role anon;

  select * into a from public.place_order('Ana', null, '09171234567', 'pickup', null,
    '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}]'::jsonb);
  select * into b from public.place_order('Ben', null, '09179876543', 'pickup', null,
    '[{"size":4,"items":[{"flavor_slug":"double-choc","qty":4}]}]'::jsonb);

  perform public.submit_gcash_ref(a.ref_code, '1234567890123');
  raise notice 'PASS (d): first use of the GCash ref saved';

  begin
    perform public.submit_gcash_ref(b.ref_code, '1234567890123');
    raise exception 'FAIL (d): reused GCash ref was accepted';
  exception when others then
    if sqlerrm not like '%already linked%' then raise; end if;
    raise notice 'PASS (d): reused GCash ref rejected -> %', sqlerrm;
  end;

  begin
    perform public.submit_gcash_ref(b.ref_code, '12345');
    raise exception 'FAIL (d): a 5-digit GCash ref was accepted';
  exception when others then
    if sqlerrm not like '%10 to 15 digits%' then raise; end if;
    raise notice 'PASS (d): too-short GCash ref rejected';
  end;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (e) Extras: delivery needs an address, and get_order_status leaks no
-- personal data (it returns exactly 4 columns).
-- ===========================================================================
begin;
do $$
declare r record; j jsonb;
begin
  set local role anon;

  begin
    perform 1 from public.place_order('Cara', null, '09171234567', 'delivery', '  ',
      '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}]'::jsonb);
    raise exception 'FAIL (e): delivery without address accepted';
  exception when others then
    if sqlerrm not like '%delivery address%' then raise; end if;
    raise notice 'PASS (e): delivery without an address rejected';
  end;

  select * into r from public.place_order('Cara', '@cara', '09171234567', 'delivery', '1 Test St, Makati',
    '[{"size":6,"items":[{"flavor_slug":"choc-chip","qty":3},{"flavor_slug":"double-choc","qty":3}]}]'::jsonb);
  select to_jsonb(s) into j from public.get_order_status(r.ref_code) s;
  assert (select count(*) from jsonb_object_keys(j)) = 4, 'status should have exactly 4 fields';
  assert j ? 'ref_code' and j ? 'sunday_date' and j ? 'total' and j ? 'status';
  raise notice 'PASS (e): get_order_status returns only %', j;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (f) Internal helper functions can't be called by a website visitor, and
-- the public ones still work.
-- ===========================================================================
begin;
do $$
begin
  set local role anon;
  begin
    perform public.expire_stale_orders();
    raise exception 'FAIL (f): anon could call expire_stale_orders';
  exception when insufficient_privilege then
    raise notice 'PASS (f): anon blocked from expire_stale_orders';
  end;
  begin
    perform public.cookies_taken(current_date);
    raise exception 'FAIL (f): anon could call cookies_taken';
  exception when insufficient_privilege then
    raise notice 'PASS (f): anon blocked from cookies_taken';
  end;
  begin
    perform public.quote_box(4, '[{"flavor_slug":"choc-chip","qty":4}]'::jsonb);
    raise exception 'FAIL (f): anon could call quote_box';
  exception when insufficient_privilege then
    raise notice 'PASS (f): anon blocked from quote_box';
  end;
  perform 1 from public.current_sunday_info();
  perform 1 from public.flavors;
  raise notice 'PASS (f): banner function and flavors are readable by anon';
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (g) Multi-box rules: at most 3 boxes; the same flavor can appear in more
-- than one box; each box keeps its own gift note; prices stored per box.
-- ===========================================================================
begin;
do $$
declare
  r record;
  box4 text := '{"size":4,"items":[{"flavor_slug":"kinder-bueno","qty":4}]}';
begin
  set local role anon;

  -- 4 boxes: rejected.
  begin
    perform 1 from public.place_order('Dan', null, '09171234567', 'pickup', null,
      ('[' || box4 || ',' || box4 || ',' || box4 || ',' || box4 || ']')::jsonb);
    raise exception 'FAIL (g): 4 boxes accepted';
  exception when others then
    if sqlerrm not like '%1 to 3 boxes%' then raise; end if;
    raise notice 'PASS (g): 4 boxes rejected -> %', sqlerrm;
  end;

  -- 3 boxes with the same flavor in each: allowed. 3 x (380 + 4*30) = 1500.
  select * into r from public.place_order('Dan', null, '09171234567', 'pickup', null,
    ('[' || replace(box4, '{"size":4', '{"size":4,"gift_note":"A"') || ',' ||
            replace(box4, '{"size":4', '{"size":4,"gift_note":"B"') || ',' || box4 || ']')::jsonb);
  assert r.total = 1500, 'three bueno boxes should total 1500, got ' || r.total;
  reset role;

  assert (select count(*) from public.order_boxes ob join public.orders o on o.id = ob.order_id where o.ref_code = r.ref_code) = 3;
  assert (select string_agg(coalesce(ob.gift_note, '-'), ',' order by ob.position)
          from public.order_boxes ob join public.orders o on o.id = ob.order_id where o.ref_code = r.ref_code) = 'A,B,-',
    'gift notes should stay with their own box';
  raise notice 'PASS (g): 3 boxes accepted, total %, notes kept per box', r.total;
end $$;
rollback;


-- ===========================================================================
-- (h) Idempotency (migration 003): retrying with the SAME key returns the
-- original order instead of creating a duplicate; a different key (or no key)
-- creates a new order.
-- ===========================================================================
begin;
do $$
declare
  k1 uuid := gen_random_uuid(); k2 uuid := gen_random_uuid();
  a record; b record; c record;
  boxes jsonb := '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}]';
begin
  set local role anon;
  select * into a from public.place_order('Eve', null, '09171234567', 'pickup', null, boxes, k1);
  select * into b from public.place_order('Eve', null, '09171234567', 'pickup', null, boxes, k1);  -- the "retry"
  assert a.ref_code = b.ref_code and a.total = b.total and a.sunday_date = b.sunday_date,
    'same key must return the same order';
  select * into c from public.place_order('Eve', null, '09171234567', 'pickup', null, boxes, k2);
  assert c.ref_code <> a.ref_code, 'a new key must create a new order';
  reset role;
  assert (select count(*) from public.orders) = 2, 'expected exactly 2 orders (retry must not duplicate)';
  assert (select count(*) from public.order_items) = 2, 'retry must not duplicate items';
  raise notice 'PASS (h): retry with the same key returned order % and created no duplicate', a.ref_code;
end $$;
rollback;
