-- tests.sql: proves the security and ordering rules actually work.
-- Written for the schema AFTER 001_init.sql + 002_multi_box_orders.sql + seed.sql.
--
-- HOW TO RUN: paste ONE test block at a time into the Supabase SQL editor and
-- run it. Each block says PASS (a NOTICE in the results panel) or fails with
-- an error. Every block ends in ROLLBACK, so no test data is left behind.
-- Run on a dev/empty project: tests (c)-(g) assume no real orders are booked
-- yet for the upcoming Sundays. (Tests that fill a flavor top it up adaptively, so a few
-- real orders won't break them, but a lot of real orders could.)
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
-- (c) The per-flavor weekly cap (migration 007): 15 of each flavor per Sunday.
-- Each test tops a flavor up to a known number of reserved cookies with a fixture
-- (inserted as postgres, so it works even if real orders already exist), then
-- orders as a website visitor.
--   * under the cap: accepted. Over it: rejected, naming the flavor and how many are left.
--   * a different flavor still works while one is full.
--   * box cookies and single cookies share the same per-flavor count.
-- ===========================================================================
begin;
do $$
declare
  v_sunday date := public.ordering_sunday();
  v_choc   bigint := (select id from public.flavors where slug = 'choc-chip');
  v_order  bigint;
  v_have   int := (select reserved from public.flavor_reserved(public.ordering_sunday()) where slug = 'choc-chip');
  r record;
begin
  -- Chimp Chips reserved = 13 (2 left)
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price) values (v_order, null, v_choc, 13 - v_have, 105);

  set local role anon;

  -- 3 Chimp Chips when only 2 are left: rejected, and the message names the flavor and the number left
  begin
    perform 1 from public.place_order('Cap', null, '09176660001', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":3}]'::jsonb);
    raise exception 'FAIL (c): ordering past a flavor cap was accepted';
  exception when others then
    if sqlerrm not like '%only 2 Chimp Chips left%' then raise; end if;
    raise notice 'PASS (c): over the cap is rejected -> %', sqlerrm;
  end;

  -- A different flavor still works while Chimp Chips is nearly gone
  select * into r from public.place_order('Cap', null, '09176660002', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"double-choc","qty":4}]'::jsonb);
  assert r.sunday_date = v_sunday, 'a different flavor should still be orderable on ' || v_sunday;
  raise notice 'PASS (c): a different flavor (Coco Loco) is still orderable';

  -- Exactly the 2 that are left: accepted
  select * into r from public.place_order('Cap', null, '09176660003', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
  raise notice 'PASS (c): taking exactly the last 2 is accepted';

  -- Now Chimp Chips is sold out: the message says so
  begin
    perform 1 from public.place_order('Cap', null, '09176660004', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
    raise exception 'FAIL (c): a sold-out flavor was accepted';
  exception when others then
    if sqlerrm not like '%Chimp Chips is sold out%' then raise; end if;
    raise notice 'PASS (c): sold-out flavor -> %', sqlerrm;
  end;

  -- Box cookies count against the same flavor: a box with 2 Chimp Chips + 2 Coco Loco is rejected too,
  -- and nothing is partly saved
  begin
    perform 1 from public.place_order('Cap', null, '09176660005', 'pickup', null,
      '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"double-choc","qty":2}]}]'::jsonb);
    raise exception 'FAIL (c): a box with a sold-out flavor was accepted';
  exception when others then
    if sqlerrm not like '%Chimp Chips is sold out%' then raise; end if;
    raise notice 'PASS (c): a box containing a sold-out flavor is rejected';
  end;
  reset role;
  assert (select count(*) from public.orders where phone = '09176660005') = 0, 'a rejected order must save nothing';

  -- flavor_availability reports it (as the website sees it)
  set local role anon;
  assert (select remaining from public.flavor_availability() where slug = 'choc-chip') = 0, 'availability: Chimp Chips 0 left';
  assert (select remaining from public.flavor_availability() where slug = 'kinder-bueno') > 0, 'availability: Bueno Mucho still has some';
  reset role;
  raise notice 'PASS (c): flavor_availability shows Chimp Chips at 0';
end $$;
rollback;

-- Singles and box cookies share the same flavor count
begin;
do $$
declare
  v_sunday date := public.ordering_sunday();
  v_have int := (select reserved from public.flavor_reserved(public.ordering_sunday()) where slug = 'kinder-bueno');
  v_bueno bigint := (select id from public.flavors where slug = 'kinder-bueno');
  v_order bigint; r record;
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price) values (v_order, null, v_bueno, 10 - v_have, 135);
  set local role anon;
  -- Bueno Mucho reserved = 10 (5 left). A box with 3 Bueno + 2 singles = 5: fits exactly.
  select * into r from public.place_order('Mix', null, '09176660010', 'pickup', null,
    '[{"size":4,"items":[{"flavor_slug":"kinder-bueno","qty":3},{"flavor_slug":"choc-chip","qty":1}]}]'::jsonb, null,
    '[{"flavor_slug":"kinder-bueno","qty":2}]'::jsonb);
  -- 1 more Bueno single: over the cap
  begin
    perform 1 from public.place_order('Mix', null, '09176660011', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"kinder-bueno","qty":2}]'::jsonb);
    raise exception 'FAIL (c): box + singles went past the flavor cap';
  exception when others then
    if sqlerrm not like '%Bueno Mucho is sold out%' then raise; end if;
    raise notice 'PASS (c): box cookies and single cookies share one per-flavor count';
  end;
  reset role;
end $$;
rollback;

-- Expired pending orders free their slots; cancelled ones too
begin;
do $$
declare
  boxes jsonb := '[{"size":6,"items":[{"flavor_slug":"double-choc","qty":6}]}]';
  v_have int := (select reserved from public.flavor_reserved(public.ordering_sunday()) where slug = 'double-choc');
  v_sunday date := public.ordering_sunday();
  v_coco bigint := (select id from public.flavors where slug = 'double-choc');
  v_order bigint; a record; r record;
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price) values (v_order, null, v_coco, 9 - v_have, 110);
  set local role anon;
  -- Coco Loco: 9 reserved, 6 left. A pending order takes all 6.
  select * into a from public.place_order('Pend', null, '09176660020', 'pickup', null, boxes);
  begin
    perform 1 from public.place_order('Next', null, '09176660021', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"double-choc","qty":2}]'::jsonb);
    raise exception 'FAIL (c): pending order did not hold its slots';
  exception when others then
    if sqlerrm not like '%Coco Loco is sold out%' then raise; end if;
  end;
  -- 24 hours pass without payment...
  reset role;
  update public.orders set expires_at = now() - interval '1 minute' where ref_code = a.ref_code;
  set local role anon;
  select * into r from public.place_order('Next', null, '09176660021', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"double-choc","qty":2}]'::jsonb);
  raise notice 'PASS (c): an expired pending order frees its slots for the next customer';
  reset role;
end $$;
rollback;

-- When EVERY flavor is sold out, ordering moves to the next Sunday by itself
begin;
do $$
declare
  v_sunday date := public.ordering_sunday();
  v_order bigint; f record; r record; i record; av record;
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  for f in select flavor_id, remaining from public.flavor_reserved(v_sunday) loop
    if f.remaining > 0 then
      insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price) values (v_order, null, f.flavor_id, f.remaining, 100);
    end if;
  end loop;
  set local role anon;
  select * into i from public.current_sunday_info();
  assert i.is_full and i.remaining = 0 and i.ordering_sunday = v_sunday + 7, 'banner info: full, ordering the next Sunday';
  select * into r from public.place_order('Roll', null, '09176660030', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
  assert r.sunday_date = v_sunday + 7, 'order should land on ' || (v_sunday + 7) || ', got ' || r.sunday_date;
  select * into av from public.flavor_availability() where slug = 'choc-chip';
  assert av.sunday_date = v_sunday + 7 and av.remaining = av.weekly_cap - 2, 'availability now describes the next Sunday';
  reset role;
  raise notice 'PASS (c): all flavors sold out -> ordering and availability move to the next Sunday (%)', r.sunday_date;
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
    if sqlerrm not like '%at most 3 boxes%' then raise; end if;
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


-- ===========================================================================
-- (i) Admin functions (migration 004): only a listed admin can use them.
-- We make two throwaway logins inside the transaction (one admin, one not).
-- On Supabase, "request.jwt.claims" is how Postgres learns who is logged in.
-- ===========================================================================
begin;
do $$
declare
  admin_id uuid := gen_random_uuid(); other_id uuid := gen_random_uuid();
  o record; j jsonb; n int;
  v_sunday date; v_order bigint; v_box bigint;
  v_flavor bigint := (select id from public.flavors where slug = 'choc-chip');
begin
  insert into auth.users (id) values (admin_id), (other_id);
  insert into public.admins (user_id) values (admin_id);

  -- A customer places an order.
  set local role anon;
  select * into o from public.place_order('Zed', '@zed', '09171234567', 'delivery', '1 Test St',
    '[{"size":4,"gift_note":"Hi","items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":2}]}]'::jsonb);
  v_sunday := o.sunday_date;

  -- Not logged in: can't even call it.
  begin
    perform public.admin_orders(v_sunday);
    raise exception 'FAIL (i): anon called admin_orders';
  exception when insufficient_privilege then
    raise notice 'PASS (i): anon cannot call admin functions';
  end;

  -- Logged in but NOT an admin: refused.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', other_id)::text, true);
  begin
    perform public.admin_orders(v_sunday);
    raise exception 'FAIL (i): non-admin read orders';
  exception when insufficient_privilege then
    raise notice 'PASS (i): a logged-in non-admin gets "Not authorized"';
  end;
  begin
    perform public.admin_set_order_status(o.ref_code, 'paid');
    raise exception 'FAIL (i): non-admin changed a status';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform 1 from public.orders;   -- direct table read: RLS hides every row
    select count(*) into n from public.orders;
    assert n = 0, 'non-admin must see 0 orders directly, saw ' || n;
    raise notice 'PASS (i): non-admin sees 0 rows in orders';
  end;

  -- The admin.
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  j := public.admin_orders(v_sunday);
  assert jsonb_array_length(j) = 1 and j -> 0 ->> 'ref_code' = o.ref_code, 'admin should see the order';
  assert j -> 0 -> 'boxes' -> 0 ->> 'gift_note' = 'Hi'
     and jsonb_array_length(j -> 0 -> 'boxes' -> 0 -> 'items') = 2
     and j -> 0 ->> 'address' = '1 Test St', 'order json should include box, items, note, address';
  raise notice 'PASS (i): admin sees the order with its box, flavors, note and address';

  perform public.admin_set_order_status(o.ref_code, 'paid');
  assert (select status from public.orders where ref_code = o.ref_code) = 'paid', 'should be paid';
  begin
    perform public.admin_set_order_status(o.ref_code, 'expired');
    raise exception 'FAIL (i): admin set status to expired by hand';
  exception when others then
    if sqlerrm not like '%pending, paid or cancelled%' then raise; end if;
  end;
  perform public.admin_set_order_status(o.ref_code, 'cancelled');
  assert (select status from public.orders where ref_code = o.ref_code) = 'cancelled', 'should be cancelled';
  raise notice 'PASS (i): Mark Paid and Cancel work';

  -- Expiry: backdate a pending order, then run the expire function.
  reset role;
  update public.orders set status = 'pending', expires_at = now() - interval '1 hour' where ref_code = o.ref_code;
  set local role authenticated;
  n := public.admin_expire_stale_orders();
  assert n = 1 and (select status from public.orders where ref_code = o.ref_code) = 'expired', 'should expire 1 order';
  raise notice 'PASS (i): admin_expire_stale_orders expired the overdue order';

  -- Reopening needs room in each flavor: sell out Chimp Chips, then try to bring the order back.
  reset role;
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  insert into public.order_boxes (order_id, position, size, price) values (v_order, 1, 6, 0) returning id into v_box;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty) values (v_order, v_box, v_flavor, 45);
  set local role authenticated;
  begin
    perform public.admin_set_order_status(o.ref_code, 'paid');
    raise exception 'FAIL (i): reopened an order past the cap';
  exception when others then
    if sqlerrm not like '%no room left%' then raise; end if;
    raise notice 'PASS (i): cannot bring back an order when the Sunday is full -> %', sqlerrm;
  end;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (0b) Timezone: next_order_sunday must give the SAME answer no matter what
-- timezone the database session (or a visitor's phone) is set to, because it
-- always converts to Asia/Manila itself.
-- ===========================================================================
do $$
declare tz text;
begin
  foreach tz in array array['UTC', 'Asia/Manila', 'America/Los_Angeles', 'Pacific/Auckland', 'Europe/London'] loop
    perform set_config('timezone', tz, true);
    assert public.next_order_sunday('2026-10-07 20:59:59.999+08') = '2026-10-11', 'Wed 20:59:59 should be Oct 11 in ' || tz;
    assert public.next_order_sunday('2026-10-07 21:00:00+08')     = '2026-10-18', 'Wed 21:00:00 sharp should be Oct 18 in ' || tz;
    assert public.next_order_sunday('2026-10-07T13:00:00Z')       = '2026-10-18', 'same instant in UTC (Wed 13:00Z = 21:00 Manila) in ' || tz;
    assert public.next_order_sunday('2026-10-07T12:59:59Z')       = '2026-10-11', 'one second earlier in ' || tz;
    assert public.sunday_cutoff('2026-10-11') = '2026-10-07T13:00:00Z'::timestamptz, 'cutoff instant in ' || tz;
  end loop;
  raise notice 'PASS (0b): next_order_sunday and sunday_cutoff identical under 5 different session timezones';
end $$;


-- ===========================================================================
-- (j) Migration 005: a phone number can have at most 3 open (unpaid) orders,
-- however the number is written; and admin_orders reports overdue from the DB clock.
-- ===========================================================================
begin;
do $$
declare
  boxes jsonb := '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":4}]}]';
  boxes2 jsonb := '[{"size":4,"items":[{"flavor_slug":"double-choc","qty":4}]}]';
  boxes3 jsonb := '[{"size":4,"items":[{"flavor_slug":"kinder-bueno","qty":4}]}]';
  admin_id uuid := gen_random_uuid(); r record; j jsonb;
begin
  set local role anon;
  perform public.place_order('A', null, '+639171234567', 'pickup', null, boxes);
  perform public.place_order('A', null, '09171234567',  'pickup', null, boxes2);
  perform public.place_order('A', null, '63 917 123 4567', 'pickup', null, boxes3);
  begin
    perform public.place_order('A', null, '0917-123-4567', 'pickup', null, boxes);
    raise exception 'FAIL (j): a 4th open order from the same phone was accepted';
  exception when others then
    if sqlerrm not like '%3 orders waiting%' then raise; end if;
    raise notice 'PASS (j): 4th open order from the same phone rejected -> %', sqlerrm;
  end;
  -- A different phone is unaffected.
  perform public.place_order('B', null, '09179998888', 'pickup', null, boxes2);
  reset role;

  -- Expired orders don't count against the limit.
  update public.orders set expires_at = now() - interval '1 minute'
   where ref_code = (select ref_code from public.orders where phone = '+639171234567' limit 1);
  set local role anon;
  perform public.place_order('A', null, '09171234567', 'pickup', null, boxes);
  reset role;
  raise notice 'PASS (j): an expired order frees up a slot';

  -- admin_orders: overdue flag comes from the database clock.
  -- (Backdate one still-pending order; place_order would have flipped an overdue one to 'expired'.)
  update public.orders set expires_at = now() - interval '1 minute'
   where ref_code = (select ref_code from public.orders where status = 'pending' order by id limit 1);
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  j := public.admin_orders((select min(sunday_date) from public.orders));
  assert exists (select 1 from jsonb_array_elements(j) e where (e ->> 'overdue')::boolean), 'one order should be overdue';
  assert exists (select 1 from jsonb_array_elements(j) e where not (e ->> 'overdue')::boolean and (e ->> 'seconds_left')::int > 80000),
    'a fresh order should have about 24h left';
  reset role;
  raise notice 'PASS (j): admin_orders reports overdue and seconds_left from the DB clock';
end $$;
rollback;


-- ===========================================================================
-- (k) Single cookies (migration 006).
--   single prices: Chimp Chips 105, Coco Loco 110, Bueno Mucho 135
--   minimum 2 cookies per order; singles count toward the 45 cap;
--   the browser can never set a price.
-- ===========================================================================
begin;
do $$
declare r record; n int;
begin
  set local role anon;

  -- Single-only order: 2 Chimp Chips = 2 x 105 = 210
  select * into r from public.place_order('Sam', null, '09175550001', 'pickup', null, '[]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
  assert r.total = 210, 'two Chimp Chips should be 210, got ' || r.total;
  raise notice 'PASS (k): single-only order total = % (2 x 105)', r.total;

  -- Mixed order: box of 4 (2 Chimp + 2 Bueno = 380 + 60 = 440) + singles (1 Coco 110 + 1 Bueno 135 = 245) = 685
  select * into r from public.place_order('Sam', null, '09175550002', 'pickup', null,
    '[{"size":4,"items":[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":2}]}]'::jsonb, null,
    '[{"flavor_slug":"double-choc","qty":1},{"flavor_slug":"kinder-bueno","qty":1}]'::jsonb);
  assert r.total = 685, 'box 440 + singles 245 should be 685, got ' || r.total;
  raise notice 'PASS (k): box + singles total = % (440 + 245)', r.total;

  -- Duplicate slugs are merged; 3 Coco Loco = 330
  select * into r from public.place_order('Sam', null, '09175550003', 'pickup', null, '[]'::jsonb, null,
    '[{"flavor_slug":"double-choc","qty":1},{"flavor_slug":"double-choc","qty":2}]'::jsonb);
  assert r.total = 330, 'merged Coco Loco singles should be 330, got ' || r.total;
  reset role;

  -- Stored as loose items (no box) with the price they were sold at.
  select count(*) into n from public.order_items where order_box_id is null and unit_price = 135;
  assert n = 1, 'the Bueno single should be stored with unit_price 135';
  select count(*) into n from public.order_items where order_box_id is not null and unit_price is not null;
  assert n = 0, 'box items must not carry a unit price';
  raise notice 'PASS (k): singles stored with order_box_id null and their unit_price';
end $$;
rollback;

-- Minimums (migration 008): pickup = 1 cookie; delivery = 2 cookies OR P200. Plus other order-size sanity checks.
begin;
do $$
begin
  set local role anon;
  declare r record;
  begin
    -- PICKUP: 1 cookie is enough
    select * into r from public.place_order('Min', null, '09175550101', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"choc-chip","qty":1}]'::jsonb);
    assert r.total = 105, 'one Chimp Chips for pickup should be 105, got ' || r.total;
    raise notice 'PASS (k): pickup accepts a single cookie (total %)', r.total;

    -- DELIVERY: 1 cookie under P200 is rejected
    begin
      perform 1 from public.place_order('Min', null, '09175550102', 'delivery', '1 Test St', '[]'::jsonb, null,
        '[{"flavor_slug":"choc-chip","qty":1}]'::jsonb);
      raise exception 'FAIL (k): a 1-cookie delivery order under P200 was accepted';
    exception when others then
      if sqlerrm not like '%Delivery orders need at least 2 cookies or ₱200%' then raise; end if;
      raise notice 'PASS (k): delivery of 1 cookie (P105) rejected -> %', sqlerrm;
    end;
    begin
      perform 1 from public.place_order('Min', null, '09175550102', 'delivery', '1 Test St', '[]'::jsonb, null,
        '[{"flavor_slug":"kinder-bueno","qty":1}]'::jsonb);
      raise exception 'FAIL (k): a 1-cookie delivery order (P135) was accepted';
    exception when others then
      if sqlerrm not like '%Delivery orders need%' then raise; end if;
    end;

    -- DELIVERY: 2 cookies is enough
    select * into r from public.place_order('Min', null, '09175550103', 'delivery', '1 Test St', '[]'::jsonb, null,
      '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
    raise notice 'PASS (k): delivery accepts 2 cookies';
  end;
  -- DELIVERY: 1 cookie is enough if it costs P200 or more (we make Bueno Mucho P250 for this test)
  reset role;
  update public.flavors set single_price = 250 where slug = 'kinder-bueno';
  set local role anon;
  declare r2 record;
  begin
    select * into r2 from public.place_order('Min', null, '09175550104', 'delivery', '1 Test St', '[]'::jsonb, null,
      '[{"flavor_slug":"kinder-bueno","qty":1}]'::jsonb);
    assert r2.total = 250, 'one P250 cookie by delivery should be accepted at 250';
    raise notice 'PASS (k): delivery accepts 1 cookie when it costs P200 or more';
  end;
  begin
    perform 1 from public.place_order('Min', null, '09175550004', 'pickup', null, '[]'::jsonb);
    raise exception 'FAIL (k): an empty order was accepted';
  exception when others then
    if sqlerrm not like '%add something%' then raise; end if;
    raise notice 'PASS (k): empty order rejected';
  end;
  begin
    perform 1 from public.place_order('Min', null, '09175550004', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"choc-chip","qty":0}]'::jsonb);
    raise exception 'FAIL (k): qty 0 accepted';
  exception when others then
    if sqlerrm not like '%at least 1%' then raise; end if;
  end;
  begin
    perform 1 from public.place_order('Min', null, '09175550004', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"choc-chip","qty":-5},{"flavor_slug":"double-choc","qty":9}]'::jsonb);
    raise exception 'FAIL (k): negative qty accepted';
  exception when others then
    if sqlerrm not like '%at least 1%' then raise; end if;
    raise notice 'PASS (k): zero / negative quantities rejected';
  end;
  begin
    perform 1 from public.place_order('Min', null, '09175550004', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"choc-chip","qty":46}]'::jsonb);
    raise exception 'FAIL (k): 46 Chimp Chips in one order accepted';
  exception when others then
    if sqlerrm not like '%Chimp Chips left%' and sqlerrm not like '%Chimp Chips is sold out%' then raise; end if;
    raise notice 'PASS (k): an order bigger than a flavor cap is rejected (%)', sqlerrm;
  end;
  begin
    perform 1 from public.place_order('Min', null, '09175550004', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"matcha-cookie","qty":2}]'::jsonb);
    raise exception 'FAIL (k): unknown single flavor accepted';
  exception when others then
    if sqlerrm not like '%as a single cookie%' then raise; end if;
    raise notice 'PASS (k): unknown flavor rejected';
  end;
  reset role;
end $$;
rollback;

-- Singles count toward a flavor's weekly cap (the full per-flavor tests are in block (c))
begin;
do $$
declare
  v_sunday date := public.ordering_sunday();
  v_have int := (select reserved from public.flavor_reserved(public.ordering_sunday()) where slug = 'choc-chip');
  v_flavor bigint := (select id from public.flavors where slug = 'choc-chip');
  v_order bigint; r record;
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price) values (v_order, null, v_flavor, 13 - v_have, 105);
  set local role anon;
  select * into r from public.place_order('Cap1', null, '09175550005', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
  assert r.sunday_date = v_sunday, '2 singles that fit under the cap stay on ' || v_sunday;
  begin
    perform 1 from public.place_order('Cap2', null, '09175550006', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
    raise exception 'FAIL (k): singles went past the flavor cap';
  exception when others then
    if sqlerrm not like '%Chimp Chips is sold out%' then raise; end if;
  end;
  reset role;
  raise notice 'PASS (k): single cookies count toward the flavor cap';
end $$;
rollback;

-- Price tampering is ignored: every price comes from the database
begin;
do $$
declare r record; n int;
begin
  set local role anon;
  -- extra "price" fields on singles and on a box, and a fake "total", are never read
  select * into r from public.place_order('Cheat', null, '09175550007', 'pickup', null,
    '[{"size":4,"price":1,"total":1,"items":[{"flavor_slug":"choc-chip","qty":4,"price":1}]}]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":2,"price":1,"unit_price":1,"single_price":1,"total":1}]'::jsonb);
  assert r.total = 380 + 210, 'tampered prices must be ignored: expected 590, got ' || r.total;
  reset role;
  select count(*) into n from public.order_items where unit_price = 1;
  assert n = 0, 'no item may carry the tampered price';
  assert (select unit_price from public.order_items where order_box_id is null limit 1) = 105, 'unit price must be the DB price';
  raise notice 'PASS (k): price tampering ignored (total %, singles priced by the database)', r.total;

  -- The DB, not the browser, decides which flavors can be bought as singles
  reset role;
  update public.flavors set single_price = null where slug = 'kinder-bueno';
  set local role anon;
  begin
    perform 1 from public.place_order('Cheat', null, '09175550008', 'pickup', null, '[]'::jsonb, null,
      '[{"flavor_slug":"kinder-bueno","qty":2}]'::jsonb);
    raise exception 'FAIL (k): a flavor with no single price was sold as a single';
  exception when others then
    if sqlerrm not like '%as a single cookie%' then raise; end if;
    raise notice 'PASS (k): a flavor with no single price cannot be ordered as a single';
  end;
  -- ...but it can still go in a box
  perform public.place_order('Cheat', null, '09175550009', 'pickup', null,
    '[{"size":4,"items":[{"flavor_slug":"kinder-bueno","qty":4}]}]'::jsonb);
  reset role;
end $$;
rollback;

-- Visitors can't call the internal pricing helper, and admins see singles
begin;
do $$
declare admin_id uuid := gen_random_uuid(); o record; j jsonb;
begin
  set local role anon;
  begin
    perform public.quote_singles('[{"flavor_slug":"choc-chip","qty":2}]'::jsonb);
    raise exception 'FAIL (k): anon called quote_singles';
  exception when insufficient_privilege then
    raise notice 'PASS (k): anon cannot call quote_singles';
  end;
  select * into o from public.place_order('Adm', null, '09175550010', 'pickup', null, '[]'::jsonb, null,
    '[{"flavor_slug":"choc-chip","qty":1},{"flavor_slug":"double-choc","qty":2}]'::jsonb);
  reset role;
  insert into auth.users (id) values (admin_id);
  insert into public.admins (user_id) values (admin_id);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', admin_id)::text, true);
  j := public.admin_orders(o.sunday_date);
  assert jsonb_array_length(j -> 0 -> 'singles') = 2 and jsonb_array_length(j -> 0 -> 'boxes') = 0, 'admin should see 2 single lines and no boxes';
  assert (j -> 0 -> 'singles' -> 0 ->> 'unit_price')::numeric = 105 and (j -> 0 -> 'singles' -> 1 ->> 'qty')::int = 2, 'singles detail';
  reset role;
  raise notice 'PASS (k): admin_orders lists singles with quantity and the price they were sold at';
end $$;
rollback;


-- ===========================================================================
-- (l) With only 1 cookie left across all flavors, this Sunday is still open
-- (the smallest order is now 1 cookie for pickup), and that last cookie can be ordered.
-- ===========================================================================
begin;
do $$
declare
  v_sunday date := public.ordering_sunday();
  v_order bigint; v_take int; f record; r record; i record; keep bigint := (select id from public.flavors where slug = 'choc-chip');
begin
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid') returning id into v_order;
  -- sell out everything except exactly 1 Chimp Chips
  for f in select flavor_id, remaining from public.flavor_reserved(v_sunday) loop
    v_take := f.remaining - (case when f.flavor_id = keep then 1 else 0 end);   -- (CASE is kept out of the IF: its THEN would end the IF early)
    if v_take > 0 then
      insert into public.order_items (order_id, order_box_id, flavor_id, qty, unit_price)
      values (v_order, null, f.flavor_id, v_take, 100);
    end if;
  end loop;
  set local role anon;
  select * into i from public.current_sunday_info();
  assert not i.is_full and i.remaining = 1 and i.ordering_sunday = v_sunday, 'with 1 cookie left the Sunday is still open';
  select * into r from public.place_order('Last', null, '09176660040', 'pickup', null, '[]'::jsonb, null, '[{"flavor_slug":"choc-chip","qty":1}]'::jsonb);
  assert r.sunday_date = v_sunday, 'the last cookie is orderable for pickup';
  select * into i from public.current_sunday_info();
  assert i.is_full and i.ordering_sunday = v_sunday + 7, 'now it is sold out and ordering moves on';
  reset role;
  raise notice 'PASS (l): the last single cookie can be ordered for pickup, then ordering moves to the next Sunday';
end $$;
rollback;


-- ===========================================================================
-- (m) Flavor detail columns (migration 009): visitors can read them, nobody but you can
-- change them, and nothing was invented (ingredients/allergens/nutrition start empty).
-- ===========================================================================
begin;
do $$
declare r record;
begin
  set local role anon;
  select photo_url, long_description, ingredients, allergens, weight_g, shelf_life, storage_tip, nutrition_image_url
    into r from public.flavors where slug = 'choc-chip';
  assert r.photo_url = 'assets/flavors/chimp-chips.jpg' and r.long_description is not null, 'photo and description are seeded';
  assert r.ingredients is null and r.allergens is null and r.weight_g is null
     and r.shelf_life is null and r.storage_tip is null and r.nutrition_image_url is null,
    'ingredients, allergens, weight, shelf life, storage tip and the nutrition label must start empty (never invented)';
  raise notice 'PASS (m): detail columns are readable, photo/description seeded, facts left empty';

  begin
    update public.flavors set allergens = 'none' where slug = 'choc-chip';
    raise exception 'FAIL (m): a visitor edited flavor details';
  exception when insufficient_privilege then
    raise notice 'PASS (m): visitors cannot edit flavor details';
  end;
  reset role;
end $$;
rollback;
