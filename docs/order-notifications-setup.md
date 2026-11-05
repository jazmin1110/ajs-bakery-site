# Order notifications: one-time setup (about 10 minutes)

After this, you get an email the moment a website order comes in, and another when the customer types in their GCash reference. Everything runs inside Supabase; nothing else to host.

## 1. Get a Resend API key (free)

1. Sign up at https://resend.com with the email you want the alerts sent to (the free "onboarding@resend.dev" sender can only email the address you signed up with, which is all we need).
2. Dashboard → **API Keys** → **Create API Key** → name it `ajs-bakery`, permission **Sending access** → copy the key (starts with `re_`). You only see it once.

## 2. Store the secrets in Supabase Vault

Supabase dashboard → **SQL Editor** → new query → paste, replacing the two values → **Run**:

```sql
select vault.create_secret('re_PASTE_YOUR_KEY_HERE', 'resend_api_key');
select vault.create_secret('you@example.com',       'notify_to');
```

The key and the address are encrypted in the database and never appear in the site code or in git.

## 3. Run migration 027

Still in the SQL Editor: open `supabase/migrations/027_order_notifications.sql` from this repo, paste the whole file, **Run**. It turns on `pg_net` (lets the database send HTTP requests in the background) and adds the two triggers.

## 4. Test it

SQL Editor:

```sql
select public.notify_owner('Test from AJ''s Bakery', 'If you can read this, order alerts work.');
```

`true` = an email was queued (check your inbox, and spam the first time). `false` = a secret is missing: re-check step 2 with `select name from vault.secrets;`.

## What you'll get

- **New order AJ-K7M2QX · P775 · Sunday Dec 7** when a website order is placed (admin-added orders don't email you).
- **Payment to check AJ-K7M2QX · P775 · ref 1234567890123** when the customer sends their GCash reference. Check GCash, then tap "Payment received, mark paid" in the admin.

## Changing things later

- Different inbox: `select vault.update_secret((select id from vault.secrets where name = 'notify_to'), 'new@example.com');`
- Turn it off: `drop trigger orders_notify_new on public.orders; drop trigger orders_notify_gcash on public.orders;`
- If an email ever fails (Resend down, key revoked) the order is still saved; the failure shows under Supabase → Logs → Postgres as a warning.
- Want it on your phone instead of email? Gmail notifications are the simplest. A Telegram bot is a 15-line change to `notify_owner()` if you ever want that.
