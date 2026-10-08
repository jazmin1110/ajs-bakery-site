-- ============================================================================
-- 005_review_fixes.sql: two fixes found in the security / timezone review.
--
-- 1. Order spam. place_order is open to the whole internet, and unpaid orders
--    hold cookie slots for 24h. Someone could place orders in a loop and "sell
--    out" every Sunday. Now one phone number can have at most 3 unpaid, not-yet-
--    expired orders at a time. (This stops casual abuse; a determined attacker
--    can still rotate phone numbers. See the review notes about CAPTCHA.)
--
-- 2. Admin pages used the phone's clock to decide "overdue" and "time left".
--    admin_orders now returns those values computed by the database clock, so a
--    phone with the wrong time or timezone can't mislabel orders.
--
-- Run after 004.
-- ============================================================================

-- ---- 1. At most 3 open orders per phone -------------------------------------
create function public.limit_open_orders()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  -- Compare the last 10 digits, so 0917..., +63917... and 63917... count as the same phone
  if (select count(*)
      from public.orders o
      where o.status = 'pending'
        and o.expires_at > now()
        and right(regexp_replace(o.phone, '\D', '', 'g'), 10)
          = right(regexp_replace(new.phone, '\D', '', 'g'), 10)) >= 3 then
    raise exception 'You already have 3 orders waiting for payment. Please pay for one of them first, or message us on Instagram.'
      using hint = 'too_many_open_orders';
  end if;
  return new;
end $$;

create trigger orders_limit_open
  before insert on public.orders
  for each row execute function public.limit_open_orders();

revoke all on function public.limit_open_orders() from public, anon, authenticated;


-- ---- 2. admin_orders: add overdue + seconds_left from the DB clock -----------
-- Same function as 004 plus two fields per order (create or replace: same return type).
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
        -- computed with the database clock, never the viewer's
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
        ), '[]'::jsonb))
      order by o.created_at)
    from public.orders o
    where o.sunday_date = p_sunday
  ), '[]'::jsonb);
end $$;
