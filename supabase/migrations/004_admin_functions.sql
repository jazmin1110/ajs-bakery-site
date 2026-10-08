-- ============================================================================
-- 004_admin_functions.sql: what the admin pages call.
--
-- Every function here checks is_admin() itself, so even someone who is logged
-- in (but not listed in the `admins` table) gets "Not authorized". The browser
-- checks are only for convenience; THIS is the real gate.
--   admin_orders(sunday)                  all orders for a Sunday, with boxes + items
--   admin_set_order_status(ref, status)   Mark Paid / Cancel / Reopen
--   admin_expire_stale_orders()           marks unpaid orders past 24h as expired
-- Run after 003.
-- ============================================================================

-- One JSON list: each order with its boxes, and each box with its flavors.
create function public.admin_orders(p_sunday date)
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


-- Mark an order paid / cancelled, or reopen it (back to pending with a fresh 24h).
-- Bringing a cancelled or expired order back to life needs room under the cap,
-- so an old order can't push a Sunday past 45.
create function public.admin_set_order_status(p_ref_code text, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_order   public.orders;
  v_cookies int;
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

  -- Is this order currently NOT holding cookie slots (cancelled, expired, or a
  -- pending one past its deadline) but about to hold them again?
  if p_status in ('paid', 'pending')
     and (v_order.status in ('cancelled', 'expired')
          or (v_order.status = 'pending' and v_order.expires_at <= now())) then
    perform pg_advisory_xact_lock(hashtext('ajs-cap-' || v_order.sunday_date::text));
    select coalesce(sum(qty), 0) into v_cookies from public.order_items where order_id = v_order.id;
    if public.cookies_taken(v_order.sunday_date) + v_cookies > public.cap_per_sunday() then
      raise exception 'There''s no room left on % for this order (% cookies).',
        to_char(v_order.sunday_date, 'Mon DD'), v_cookies using hint = 'sunday_full';
    end if;
  end if;

  update public.orders
     set status = p_status,
         expires_at = case when p_status = 'pending' then now() + interval '24 hours' else expires_at end
   where id = v_order.id;
end $$;


-- Run this when the admin orders page opens: unpaid orders past 24h become 'expired'.
create function public.admin_expire_stale_orders()
returns int
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return public.expire_stale_orders();
end $$;


-- Only logged-in users can even try to call these (and they still must be admins).
revoke all on function
  public.admin_orders(date),
  public.admin_set_order_status(text, text),
  public.admin_expire_stale_orders()
  from public, anon, authenticated;
grant execute on function
  public.admin_orders(date),
  public.admin_set_order_status(text, text),
  public.admin_expire_stale_orders()
  to authenticated;
