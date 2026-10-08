-- tests.sql: proves the security and ordering rules actually work.
--
-- HOW TO RUN: run migrations/001_init.sql and seed.sql first. Then paste ONE
-- test block at a time into the Supabase SQL editor and run it.
-- Each block says PASS (a NOTICE in the results panel) or fails with an error.
-- Every block ends in ROLLBACK, so no test data is left behind.
-- Run on a dev/empty project: tests (c)-(e) assume no real orders are booked yet
-- for the upcoming Sunday (real orders would eat into the 45-cookie cap).
--
-- "set local role anon" makes the block behave like a website visitor, which
-- is what proves the rules hold for real customers (the SQL editor itself
-- runs as the all-powerful postgres user).


-- ===========================================================================
-- TEST 0: next_order_sunday gives the right Sunday (the 6 cases from the
-- migration comments). Read-only.
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
-- (a) A website visitor (anon) cannot read the orders table.
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
  -- Bonus: anon can't write to orders directly either.
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
-- (b) A bad flavor sum is rejected: box of 4 but only 3 cookies picked.
-- Also shows a correct order works and the DB computes the total
-- (4 cookies with 2 Bueno = 380 + 2*30 = 440).
-- ===========================================================================
begin;
do $$
declare r record;
begin
  set local role anon;

  begin
    perform 1 from public.place_order('Test', '@test', '09171234567', 'pickup', null, null, 4,
      '[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"double-choc","qty":1}]'::jsonb);
    raise exception 'FAIL (b): a 3-cookie box of 4 was accepted';
  exception when others then
    if sqlerrm not like '%needs exactly%' then raise; end if;   -- re-raise the FAIL above
    raise notice 'PASS (b): bad sum rejected -> %', sqlerrm;
  end;

  select * into r from public.place_order('Test', '@test', '09171234567', 'pickup', null, null, 4,
    '[{"flavor_slug":"choc-chip","qty":2},{"flavor_slug":"kinder-bueno","qty":2}]'::jsonb);
  assert r.total = 440, 'total should be 380 + 2*30 = 440, got ' || r.total;
  raise notice 'PASS (b): valid order accepted, ref %, total %, Sunday %', r.ref_code, r.total, r.sunday_date;
  reset role;
end $$;
rollback;


-- ===========================================================================
-- (c) The cap: 45 cookies per Sunday. We pretend 41 cookies are already paid,
-- so one more box of 4 lands EXACTLY on 45 (allowed) and the next order would
-- push it to 46+ (rejected).
-- ===========================================================================
begin;
do $$
declare
  v_sunday date := public.next_order_sunday();
  v_order  bigint;
  v_flavor bigint := (select id from public.flavors where slug = 'choc-chip');
  r record;
begin
  -- Fixture (runs as postgres, bypassing the rules): a paid order of 41 cookies.
  insert into public.orders (ref_code, sunday_date, name, phone, fulfillment, total, status)
  values ('AJ-FIXTURE', v_sunday, 'Fixture', '09170000000', 'pickup', 0, 'paid')
  returning id into v_order;
  insert into public.order_items (order_id, flavor_id, qty) values (v_order, v_flavor, 41);

  set local role anon;

  -- 41 + 4 = 45: allowed.
  select * into r from public.place_order('Test', null, '09171234567', 'pickup', null, null, 4,
    '[{"flavor_slug":"choc-chip","qty":4}]'::jsonb);
  raise notice 'PASS (c): order reaching exactly 45 accepted (ref %)', r.ref_code;

  -- 45 + 4 = 49 (the 46th cookie and beyond): rejected.
  begin
    perform 1 from public.place_order('Test2', null, '09171234567', 'pickup', null, null, 4,
      '[{"flavor_slug":"choc-chip","qty":4}]'::jsonb);
    raise exception 'FAIL (c): an order past 45 cookies was accepted';
  exception when others then
    if sqlerrm not like 'Sorry, Sunday%' then raise; end if;
    raise notice 'PASS (c): the 46th cookie is rejected -> %', sqlerrm;
  end;
  reset role;
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

  select * into a from public.place_order('Ana', null, '09171234567', 'pickup', null, null, 4,
    '[{"flavor_slug":"choc-chip","qty":4}]'::jsonb);
  select * into b from public.place_order('Ben', null, '09179876543', 'pickup', null, null, 4,
    '[{"flavor_slug":"double-choc","qty":4}]'::jsonb);

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
    perform 1 from public.place_order('Cara', null, '09171234567', 'delivery', '  ', null, 4,
      '[{"flavor_slug":"choc-chip","qty":4}]'::jsonb);
    raise exception 'FAIL (e): delivery without address accepted';
  exception when others then
    if sqlerrm not like '%delivery address%' then raise; end if;
    raise notice 'PASS (e): delivery without an address rejected';
  end;

  select * into r from public.place_order('Cara', '@cara', '09171234567', 'delivery', '1 Test St, Makati', 'Hi!', 6,
    '[{"flavor_slug":"choc-chip","qty":3},{"flavor_slug":"double-choc","qty":3}]'::jsonb);
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
  perform 1 from public.current_sunday_info();
  perform 1 from public.flavors;
  raise notice 'PASS (f): banner function and flavors are readable by anon';
  reset role;
end $$;
rollback;
