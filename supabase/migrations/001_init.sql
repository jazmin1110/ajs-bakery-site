-- ============================================================================
-- 001_init.sql: AJ's Bakery schema, ordering functions, and security rules.
--
-- The database is the boss: prices, the 45-cookie cap and the Wednesday 9pm
-- cutoff are all decided HERE. The browser only calls the functions below.
-- Run this once in the Supabase SQL editor (or via `supabase db push`).
-- ============================================================================


-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- Cookie flavors. `price` is the standalone per-cookie price (for the menu).
-- `surcharge` is the extra pesos per cookie when the flavor goes inside a box
-- (Kinder Bueno = 30). Box totals use box price + surcharges, NOT `price`.
create table public.flavors (
  id        bigint generated always as identity primary key,
  slug      text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name      text not null,
  price     numeric(8,2) not null check (price >= 0),
  surcharge numeric(8,2) not null default 0 check (surcharge >= 0),
  active    boolean not null default true
);

-- Box sizes and flat prices (4 = 380, 6 = 570).
create table public.boxes (
  id     bigint generated always as identity primary key,
  size   int not null unique check (size > 0),
  price  numeric(8,2) not null check (price >= 0),
  active boolean not null default true
);

-- Who may use the admin pages. Add yourself by hand (see seed.sql notes).
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

create table public.orders (
  id           bigint generated always as identity primary key,
  ref_code     text not null unique,                 -- customer-facing code, e.g. AJ-K7M2QX
  sunday_date  date not null check (extract(dow from sunday_date) = 0),  -- must be a Sunday
  name         text not null check (char_length(btrim(name)) between 1 and 100),
  ig_handle    text check (char_length(ig_handle) <= 60),
  phone        text not null check (char_length(btrim(phone)) between 7 and 20),
  fulfillment  text not null check (fulfillment in ('pickup', 'delivery')),
  address      text check (char_length(address) <= 300),
  gift_note    text check (char_length(gift_note) <= 500),
  total        numeric(10,2) not null check (total >= 0),
  status       text not null default 'pending'
                 check (status in ('pending', 'paid', 'cancelled', 'expired')),
  -- GCash reference numbers are digits only. UNIQUE stops one payment being
  -- claimed by two orders. (Many NULLs are allowed: unique ignores NULL.)
  gcash_ref    text unique check (gcash_ref ~ '^[0-9]{10,15}$'),
  created_at   timestamptz not null default now(),
  -- A column default can't read another column, so this is "now() + 24h".
  -- now() is fixed per transaction, so it equals created_at + 24 hours.
  expires_at   timestamptz not null default now() + interval '24 hours',
  constraint delivery_needs_address
    check (fulfillment <> 'delivery' or nullif(btrim(address), '') is not null)
);

create table public.order_items (
  id        bigint generated always as identity primary key,
  order_id  bigint not null references public.orders (id) on delete cascade,
  flavor_id bigint not null references public.flavors (id),
  qty       int not null check (qty > 0),
  unique (order_id, flavor_id)   -- one row per flavor per order
);

-- Speeds up "how many cookies are booked for this Sunday?"
create index orders_sunday_status_idx on public.orders (sunday_date, status);


-- ============================================================================
-- 2. SMALL HELPERS (internal; not callable by the browser)
-- ============================================================================

-- The cap lives in exactly one place. Change it here if it ever changes.
create function public.cap_per_sunday()
returns int language sql immutable set search_path = ''
as $$ select 45 $$;

-- When does ordering close for a given Sunday? (Sunday - 4 days) at 21:00 Manila.
-- Manila has no daylight saving, so this is always UTC+8.
create function public.sunday_cutoff(p_sunday date)
returns timestamptz language sql immutable set search_path = ''
as $$ select ((p_sunday - 4) + time '21:00') at time zone 'Asia/Manila' $$;

-- Cookies already claimed for a Sunday: paid orders + pending orders that
-- haven't expired yet. Cancelled/expired orders free their cookies.
create function public.cookies_taken(p_sunday date)
returns int language sql stable set search_path = ''
as $$
  select coalesce(sum(oi.qty), 0)::int
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where o.sunday_date = p_sunday
    and (o.status = 'paid' or (o.status = 'pending' and o.expires_at > now()))
$$;

-- Marks pending orders past their 24h window as 'expired'. place_order calls
-- this first, so slots free up on their own. (Optional: also run it on a
-- schedule with pg_cron.) Reads never depend on it: capacity ignores stale
-- pending orders anyway, and get_order_status reports them as expired.
create function public.expire_stale_orders()
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  update public.orders set status = 'expired'
  where status = 'pending' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Is the logged-in user listed in `admins`? SECURITY DEFINER so it can read
-- the admins table even though normal users can't see other admins.
create function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;


-- ============================================================================
-- 3. next_order_sunday(ts)
-- ============================================================================
-- Returns the earliest Sunday S whose cutoff ((S - 4 days) at 21:00 Manila)
-- is LATER than ts. Orders placed exactly at the cutoff instant are too late.
--
-- How: take Manila local time, jump to the Sunday on/after that day, and if
-- that Sunday's cutoff has already passed, use the following Sunday.
--
-- TEST CASES (calendar: Sun Oct 11 2026, Wed Oct 7 2026 is its cutoff day):
--   1. Wed 2026-10-07 20:59 Manila  -> 2026-10-11  (1 min before cutoff)
--   2. Wed 2026-10-07 21:01 Manila  -> 2026-10-18  (1 min after cutoff)
--   3. Wed 2026-10-07 21:00 Manila  -> 2026-10-18  (exactly at cutoff = too late)
--   4. Sat 2026-10-10 12:00 Manila  -> 2026-10-18  (Oct 11's cutoff passed days ago)
--   5. Sun 2026-10-11 10:00 Manila  -> 2026-10-18  (baking day; next Sunday)
--   6. Mon 2026-10-05 09:00 Manila  -> 2026-10-11  (plenty of time left)
-- Run them: select public.next_order_sunday('2026-10-07 20:59+08');
-- (supabase/tests.sql checks all six automatically.)
create function public.next_order_sunday(ts timestamptz default now())
returns date language plpgsql stable set search_path = ''
as $$
declare
  local_ts timestamp := ts at time zone 'Asia/Manila';  -- wall-clock time in Manila
  sunday   date;
begin
  -- dow: Sunday = 0 ... Saturday = 6. (7 - dow) % 7 = days until next Sunday (0 if today).
  sunday := local_ts::date + ((7 - extract(dow from local_ts)::int) % 7);
  if ((sunday - 4) + time '21:00') <= local_ts then
    sunday := sunday + 7;
  end if;
  return sunday;
end $$;


-- ============================================================================
-- 4. place_order(...): the ONLY way to create an order
-- ============================================================================
-- Called from the browser with the anon key. SECURITY DEFINER = it runs with
-- the owner's rights, so it can write to orders even though anon cannot.
-- Prices from the browser are never accepted: there's no price parameter.
-- A function call is one transaction: any RAISE EXCEPTION undoes everything.
--
-- p_items looks like: [{"flavor_slug":"choc-chip","qty":2}, {"flavor_slug":"kinder-bueno","qty":2}]
-- Errors carry a short machine code in the `hint` field (e.g. 'sunday_full').
create function public.place_order(
  p_name       text,
  p_ig_handle  text,
  p_phone      text,
  p_fulfillment text,
  p_address    text,
  p_gift_note  text,
  p_box_size   int,
  p_items      jsonb
)
returns table (ref_code text, total numeric, sunday_date date)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_name      text := btrim(coalesce(p_name, ''));
  v_phone     text := btrim(coalesce(p_phone, ''));
  v_address   text := nullif(btrim(coalesce(p_address, '')), '');
  v_box_price numeric;
  v_sum       bigint;   -- cookies in the order
  v_lines     bigint;   -- distinct flavors requested
  v_known     bigint;   -- how many of those exist and are active
  v_surcharge numeric;
  v_sunday    date;
  v_taken     int;
  v_total     numeric;
  v_ref       text;
  v_order_id  bigint;
  v_alphabet  text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O/1/I to avoid mixups
  v_bytes     bytea;
  i           int;
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

  -- ---- Box: price comes from the DB --------------------------------------
  select b.price into v_box_price
  from public.boxes b where b.size = p_box_size and b.active;
  if not found then
    raise exception 'That box size isn''t available.' using hint = 'invalid_box';
  end if;

  -- ---- Items --------------------------------------------------------------
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
  if v_sum <> p_box_size then
    raise exception 'A box of % needs exactly % cookies, but you picked %.',
      p_box_size, p_box_size, v_sum using hint = 'wrong_quantity';
  end if;

  -- ---- Which Sunday, and is there room? -----------------------------------
  v_sunday := public.next_order_sunday(now());

  -- Lock per Sunday so two people ordering at the same instant can't both
  -- squeeze past the cap. The lock auto-releases when this transaction ends.
  perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_sunday::text));

  v_taken := public.cookies_taken(v_sunday);
  if v_taken + p_box_size > public.cap_per_sunday() then
    raise exception 'Sorry, Sunday % % (we have % of % left).',
      to_char(v_sunday, 'Mon DD'),
      case when v_taken >= public.cap_per_sunday() then 'is sold out' else 'doesn''t have enough room for that box' end,
      greatest(public.cap_per_sunday() - v_taken, 0), public.cap_per_sunday()
      using hint = 'sunday_full';
  end if;

  -- ---- Total: box price + surcharges, all from DB values -------------------
  v_total := v_box_price + v_surcharge;

  -- ---- Unique, hard-to-guess ref code: AJ- + 6 random characters ----------
  -- (Random, not 1042, 1043... because the code is the only "password" for
  -- looking up an order and attaching a GCash number to it.)
  for attempt in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');  -- random bytes
    v_ref := 'AJ-';
    for i in 0..5 loop
      -- 256 % 32 = 0, so mapping a byte onto 32 characters is unbiased
      v_ref := v_ref || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % 32), 1);
    end loop;

    begin
      insert into public.orders
        (ref_code, sunday_date, name, ig_handle, phone, fulfillment, address, gift_note, total)
      values
        (v_ref, v_sunday, v_name, nullif(btrim(coalesce(p_ig_handle, '')), ''), v_phone,
         p_fulfillment, v_address, nullif(btrim(coalesce(p_gift_note, '')), ''), v_total)
      returning id into v_order_id;
      exit;  -- inserted fine
    exception when unique_violation then
      v_order_id := null;  -- code collision: loop and try a new code
    end;
  end loop;

  if v_order_id is null then
    raise exception 'Something went wrong, please try again.' using hint = 'ref_code_failed';
  end if;

  insert into public.order_items (order_id, flavor_id, qty)
  select v_order_id, f.id, a.qty
  from (
    select x.flavor_slug, sum(x.qty) as qty
    from jsonb_to_recordset(p_items) as x(flavor_slug text, qty int)
    group by x.flavor_slug
  ) a
  join public.flavors f on f.slug = a.flavor_slug;

  return query select v_ref, v_total, v_sunday;
end $$;


-- ============================================================================
-- 5. submit_gcash_ref(ref_code, gcash_ref)
-- ============================================================================
-- Saves the customer's GCash reference number on an open (pending, not
-- expired) order. Customers can re-submit to fix a typo while it's pending.
-- The UNIQUE constraint on orders.gcash_ref rejects a number used elsewhere.
create function public.submit_gcash_ref(p_ref_code text, p_gcash_ref text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_clean text := regexp_replace(coalesce(p_gcash_ref, ''), '[\s-]', '', 'g');  -- allow "1234 567 890 123"
  n int;
begin
  if v_clean !~ '^[0-9]{10,15}$' then
    raise exception 'A GCash reference number is 10 to 15 digits. Please check and try again.'
      using hint = 'invalid_gcash_ref';
  end if;

  begin
    update public.orders
       set gcash_ref = v_clean
     where ref_code = upper(btrim(coalesce(p_ref_code, '')))
       and status = 'pending'
       and expires_at > now();
    get diagnostics n = row_count;
  exception when unique_violation then
    raise exception 'That GCash reference number is already linked to another order. Please double-check the number.'
      using hint = 'gcash_ref_in_use';
  end;

  if n = 0 then
    raise exception 'We couldn''t find an open order with that code. It may have expired.'
      using hint = 'order_not_open';
  end if;
end $$;


-- ============================================================================
-- 6. get_order_status(ref_code): safe lookup, NO personal data
-- ============================================================================
create function public.get_order_status(p_ref_code text)
returns table (ref_code text, sunday_date date, total numeric, status text)
language sql stable security definer set search_path = ''
as $$
  select o.ref_code, o.sunday_date, o.total,
         -- a pending order past its 24h window counts as expired even if the
         -- cleanup hasn't flipped the column yet
         case when o.status = 'pending' and o.expires_at <= now() then 'expired' else o.status end
  from public.orders o
  where o.ref_code = upper(btrim(coalesce(p_ref_code, '')))
$$;


-- ============================================================================
-- 7. current_sunday_info(): for the "Now ordering for..." banner
-- ============================================================================
create function public.current_sunday_info()
returns table (sunday_date date, cutoff_at timestamptz, cap int, cookies_taken int,
               remaining int, is_full boolean)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_sunday date := public.next_order_sunday(now());
  v_taken  int  := public.cookies_taken(v_sunday);
begin
  return query select
    v_sunday,
    public.sunday_cutoff(v_sunday),
    public.cap_per_sunday(),
    v_taken,
    greatest(public.cap_per_sunday() - v_taken, 0),
    -- smallest box is the smallest order; if even that doesn't fit, it's full
    (public.cap_per_sunday() - v_taken) < (select coalesce(min(b.size), 1) from public.boxes b where b.active);
end $$;


-- ============================================================================
-- 8. ROW LEVEL SECURITY + PRIVILEGES
-- ============================================================================
-- Two layers: (1) GRANTs say which roles may touch a table at all, (2) RLS
-- policies say which rows. Supabase grants everything to anon/authenticated by
-- default, so we start by taking it ALL away, then give back only what's needed.
--
-- Note: "authenticated" = anyone with a Supabase login, which could include
-- strangers if public sign-ups are on. That's why admin rights come from the
-- `admins` table via is_admin(), never from merely being logged in.
-- (Also turn OFF "Allow new users to sign up" in Auth settings.)

alter table public.flavors     enable row level security;
alter table public.boxes       enable row level security;
alter table public.admins      enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

revoke all on public.flavors, public.boxes, public.admins, public.orders, public.order_items
  from anon, authenticated;

-- Menu data: everyone can read active rows.
grant select on public.flavors, public.boxes to anon, authenticated;
create policy "anyone reads active flavors" on public.flavors
  for select using (active);
create policy "anyone reads active boxes" on public.boxes
  for select using (active);
-- Admins also see inactive rows.
create policy "admins read all flavors" on public.flavors
  for select to authenticated using (public.is_admin());
create policy "admins read all boxes" on public.boxes
  for select to authenticated using (public.is_admin());

-- Admins table: a logged-in user can see only their own row (lets the login
-- page check "am I an admin?"). Nobody can write it from the browser; add
-- admins in the SQL editor.
grant select on public.admins to authenticated;
create policy "read own admin row" on public.admins
  for select to authenticated using (user_id = auth.uid());

-- Orders: anon has NO access (no grant, no policy). Admins can read all, and
-- update ONLY the status column (column-level grant).
grant select on public.orders to authenticated;
grant update (status) on public.orders to authenticated;
create policy "admins read orders" on public.orders
  for select to authenticated using (public.is_admin());
create policy "admins update order status" on public.orders
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select on public.order_items to authenticated;
create policy "admins read order items" on public.order_items
  for select to authenticated using (public.is_admin());

-- ---- Function permissions ---------------------------------------------------
-- Postgres lets everyone (PUBLIC) run new functions, and Supabase also grants
-- EXECUTE straight to anon/authenticated by default. Revoke from all three,
-- then open only the ones the browser needs.
revoke all on function
  public.cap_per_sunday(), public.sunday_cutoff(date), public.cookies_taken(date),
  public.expire_stale_orders(), public.is_admin(), public.next_order_sunday(timestamptz),
  public.place_order(text, text, text, text, text, text, int, jsonb),
  public.submit_gcash_ref(text, text), public.get_order_status(text),
  public.current_sunday_info()
  from public, anon, authenticated;

-- The browser (anon key, and logged-in admins) may call these:
grant execute on function
  public.next_order_sunday(timestamptz),
  public.place_order(text, text, text, text, text, text, int, jsonb),
  public.submit_gcash_ref(text, text),
  public.get_order_status(text),
  public.current_sunday_info()
  to anon, authenticated;

-- RLS policies call is_admin() as the calling user, so both roles need it.
grant execute on function public.is_admin() to anon, authenticated;

-- Internal helpers (cap_per_sunday, sunday_cutoff, cookies_taken,
-- expire_stale_orders) stay locked: only the functions above use them.
