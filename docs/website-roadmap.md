# AJ's Bakery Ordering Site: Roadmap, Accounts, Pages

Target: rough MVP by Tue Oct 13, 2026. Stack: plain HTML/CSS/JS + Supabase + Vercel (built with Claude Code).

## MVP scope (what's IN vs OUT)

IN: menu, order builder with live total, checkout, GCash payment screen, auto-assigned Sunday, admin orders list with paid toggle, flavor totals per Sunday.
OUT (later): shopping list from recipes, payment screenshot upload, emails/SMS, PayMongo, cap auto-close, domain.

## Roadmap

| When | Goal | Output |
|---|---|---|
| Tue Oct 6 (tonight) | Accounts + decisions | Accounts below done, prices/flavors locked, GCash QR saved as image |
| Wed Oct 7 | Database | Supabase tables + security rules, test data |
| Thu Oct 8 | Storefront | Menu, how-it-works, order builder with live total (static, no saving yet) |
| Fri Oct 9 | Checkout | Customer form saves order to Supabase, confirmation page with GCash QR + reference code |
| Sat Oct 10 | Admin | Login, orders list, paid toggle, flavor totals per Sunday |
| Sun Oct 11 | Test | Place 5 fake orders on your phone, fix what breaks |
| Mon-Tue Oct 12-13 | Soft launch | Send link to 3-5 friends/family, fix issues, put in IG bio |

Buffer note: this is tight. If you slip, cut the admin to a plain orders table and do flavor totals by hand.

## Accounts to set up

1. **Supabase** (have): new project "ajs-bakery". Free tier is fine.
2. **Vercel** (have): hosting. Free hobby tier.
3. **GitHub** (needed): Vercel deploys from a repo. Make a private repo "ajs-bakery-site".
4. **GCash** (have personal): save your QR as an image. Consider GCash for Business later if volume grows.
5. **Domain** (optional, skip for MVP): ~P700-1,000/yr. Use the free vercel.app link first.
6. **Resend** (later): free email tier for order notifications.
7. **Instagram** (have): link goes in bio.

## Decisions to lock before coding

- Box sizes and prices: 4 = P380, 6 = P570.
- Bueno surcharge: +P30 per Bueno cookie (or reprice boxes). Pick one.
- Cap per Sunday: 45.
- Cutoff: Wed 9pm Asia/Manila. Orders after go to next Sunday.
- Flavors for launch: Brown Butter Choc Chip, Double Chocolate, Kinder Bueno.
- Pickup address area + Sunday window 3-6pm.
- 3 product photos (even phone photos on a clean surface).

## Database (Supabase)

- `weeks`: id, sunday_date, cap, status (open/full/closed)
- `orders`: id, ref_code, week_id, name, ig_handle, phone, fulfillment (pickup/delivery), address, gift_note, total, paid (bool), created_at
- `order_items`: id, order_id, flavor, qty
- `flavors`: id, name, price, active
- `recipes` + `recipe_ingredients`: later phase

Security: turn on row-level security. Public can only INSERT orders/items and read flavors/weeks. Only the logged-in admin (Supabase Auth, your email) can read orders. Sunday assignment is computed server-side (Supabase function), timezone Asia/Manila.

## Pages

### Public
1. **/ (home/storefront)**: hero with logo + "Ordering for Sunday, [date]" banner and cutoff countdown; menu cards (photo, notes, price, macro label); how it works; order builder; footer with IG + FAQ.
2. **/checkout**: summary, name, IG handle, phone, pickup/delivery, address, gift note. Submit saves to Supabase.
3. **/confirmed?ref=XXXX**: order reference code, total, GCash QR, instruction "send payment with your ref code as the message", delivery date, note that order is confirmed once paid.

### Admin (login required)
4. **/admin/login**: Supabase Auth.
5. **/admin/orders**: filter by Sunday, list of orders, paid toggle, fulfillment type, address, gift note. Print-friendly packing view.
6. **/admin/totals**: cookies per flavor for the selected Sunday, batches needed (round up per flavor), box counts.
7. **/admin/shopping-list** (phase 2): recipes x batches minus stock.

## Claude Code workflow

1. Open Claude Code in the AJ COOKIES folder (it reads CLAUDE.md).
2. Tell it: "Build from context/website-roadmap.md, one day's section at a time. Plain HTML/CSS/JS, Supabase, Vercel. Comment non-obvious code."
3. After each step: deploy, click through on your phone.
4. Explicitly tell it: RLS on, admin behind Supabase Auth, server-side Sunday logic, Asia/Manila timezone, log/email each new order as a backup.

## Risks

- Customer expects the wrong Sunday: show the date on every page and in the confirmation.
- Unpaid orders clogging the cap: no payment within 24h = release the slot.
- Outage = lost orders: keep an IG DM fallback and a backup notification.
