-- ============================================================================
-- 027_order_notifications.sql: email the owner when an order comes in, and again
-- when a customer types in their GCash reference number.
--
-- Why: until now the only way to know about an order was to open the admin page.
-- With a 24-hour payment window, a missed morning = expired orders.
--
-- How it works (all inside the database, no server to run):
--   * pg_net lets Postgres make an HTTP call in the background (async: place_order
--     never waits for it and never fails because of it).
--   * The call goes to Resend (resend.com), a transactional email API with a free tier.
--   * The API key and the "to" address are NOT in this file or in git. They live in
--     Supabase Vault (encrypted secrets). See docs/order-notifications-setup.md.
--   * Two triggers on `orders`: after INSERT (website orders only; orders you add
--     yourself in the admin don't need an email), and after UPDATE of gcash_ref.
--
-- Safe by design: if the secrets aren't set yet, notify_owner() quietly does nothing.
-- If Resend is down or the key is wrong, the order is still saved (errors are swallowed
-- and logged with RAISE WARNING, visible in Supabase > Logs > Postgres).
-- Run after 026.
-- ============================================================================

begin;

-- ---- 1. the async HTTP extension -------------------------------------------------
create extension if not exists pg_net with schema extensions;

-- ---- 2. the sender -------------------------------------------------------------------
-- notify_owner(subject, body): queues one plain-text email to the owner. Returns true if
-- an email was queued, false if the secrets are missing (nothing sent).
--
-- Vault secrets it reads (create them once in the SQL editor, see the setup doc):
--   resend_api_key   your Resend API key (starts with "re_")
--   notify_to        the email address that should get the alerts
--   notify_from      optional. Default "AJ's Bakery <onboarding@resend.dev>", which Resend lets
--                    you use without a domain but ONLY to the email you signed up to Resend with.
create or replace function public.notify_owner(p_subject text, p_body text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_key  text;
  v_to   text;
  v_from text;
begin
  select decrypted_secret into v_key  from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  select decrypted_secret into v_to   from vault.decrypted_secrets where name = 'notify_to'      limit 1;
  select decrypted_secret into v_from from vault.decrypted_secrets where name = 'notify_from'    limit 1;
  if v_key is null or v_to is null then
    return false;                       -- not set up yet: skip quietly
  end if;

  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type',  'application/json'),
    body    := jsonb_build_object(
      'from',    coalesce(v_from, 'AJ''s Bakery <onboarding@resend.dev>'),
      'to',      jsonb_build_array(v_to),
      'subject', p_subject,
      'text',    p_body)
  );
  return true;
exception when others then
  -- Never let a notification problem block an order
  raise warning 'notify_owner failed: %', sqlerrm;
  return false;
end $$;

-- Only the database itself (triggers) calls this; nobody from the browser.
revoke all on function public.notify_owner(text, text) from public, anon, authenticated;

-- ---- 3. what the emails say ------------------------------------------------------------
-- "Mon, Dec 7" style date, so the email is readable at a glance
create or replace function public.order_email_lines(o public.orders)
returns text
language sql stable set search_path = ''
as $$
  select concat_ws(E'\n',
    'Order ' || (o).ref_code,
    'Total: P' || to_char((o).total, 'FM999,990'),
    'For Sunday ' || to_char((o).sunday_date, 'Mon DD'),
    case when (o).fulfillment = 'delivery' then 'Delivery (customer books rider): ' || coalesce((o).address, '')
         else 'Pickup' end,
    'Customer: ' || (o).name
      || coalesce(' · ' || (o).ig_handle, '')
      || coalesce(' · ' || (o).phone, ''),
    -- every cookie in the order (boxes and singles both live in order_items), e.g. "3 × Chimp Chips, 3 × Bueno Mucho"
    'Cookies: ' || coalesce((
      select string_agg(t.qty || ' × ' || t.name, ', ' order by t.name)
      from (select f.name, sum(i.qty) as qty
            from public.order_items i join public.flavors f on f.id = i.flavor_id
            where i.order_id = (o).id group by f.name) t), '(none yet)'),
    '',
    'Open the admin: https://ajs-bakery.vercel.app/admin/orders.html?sunday=' || to_char((o).sunday_date, 'YYYY-MM-DD'))
$$;
revoke all on function public.order_email_lines(public.orders) from public, anon, authenticated;

-- New website order: subject "New order AJ-K7M2QX · P775 · Sunday Dec 7"
create or replace function public.trg_notify_new_order()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.source = 'website' then
    perform public.notify_owner(
      format('New order %s · P%s · Sunday %s', new.ref_code, to_char(new.total, 'FM999,990'), to_char(new.sunday_date, 'Mon DD')),
      'A new order just came in on the website. It is unpaid for now: the customer has 24 hours to pay by GCash.'
        || E'\n\n' || public.order_email_lines(new));
  end if;
  return new;
end $$;

-- GCash reference typed in: subject "Payment to check AJ-K7M2QX · P775 · ref 1234567890123"
create or replace function public.trg_notify_gcash_ref()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.gcash_ref is not null and new.gcash_ref is distinct from old.gcash_ref then
    perform public.notify_owner(
      format('Payment to check %s · P%s · ref %s', new.ref_code, to_char(new.total, 'FM999,990'), new.gcash_ref),
      'The customer says they paid. Check your GCash for this amount and reference, then tap "Payment received, mark paid" in the admin.'
        || E'\n\n' || 'GCash reference: ' || new.gcash_ref
        || E'\n\n' || public.order_email_lines(new));
  end if;
  return new;
end $$;

-- DEFERRED: fires at the end of place_order's transaction, after the cookies (order_items)
-- are saved, so the email can list them. A failed order never emails (it rolls back first).
drop trigger if exists orders_notify_new on public.orders;
create constraint trigger orders_notify_new
  after insert on public.orders
  deferrable initially deferred
  for each row execute function public.trg_notify_new_order();

drop trigger if exists orders_notify_gcash on public.orders;
create trigger orders_notify_gcash
  after update of gcash_ref on public.orders
  for each row execute function public.trg_notify_gcash_ref();

commit;
