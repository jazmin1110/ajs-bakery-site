# AJ's Bakery Ordering Site: Roadmap, Accounts, Pages

Last updated: Fri Oct 9, 2026. Stack: plain HTML/CSS/JS + Supabase + Vercel (built with Claude Code).
Live site: https://ajs-bakery.vercel.app. Repo: jazmin1110/ajs-bakery-site (only `public/` is deployed).
Target: soft launch Mon-Tue Oct 12-13, 2026. Christmas launch is the real deadline.

## Status snapshot

| Area | Status |
|---|---|
| Storefront (menu, flavor detail sheet, box builder, cart, checkout, GCash confirmation) | Done, on `main` |
| Database, RLS, order logic (migrations 001-013) | Done |
| Admin (login, orders, packing view, totals) | Done |
| Singles, per-flavor caps, sold-out, minimums | Done |
| Boxes 3 / 6 / 12 (box of 4 retired) | Done |
| Nutrition, ingredients, allergens per flavor | Done (calculated estimates, not lab tested) |
| Design pass (blue/cream/chocolate, Baloo 2 + Nunito Sans, sticker cutouts, mascot) | Done, on `main` |
| UI polish (button centering, FAQ closed, note widths, step cards, footer clearance, disabled button) | Done, on `main` |
| Blue nav bar + new circular logo + flavor badges | Done, on `main`. Follow-up on branch `fix/ui-polish-nav-badges` (badge moves, transparent cart button, Boxes link removed, new home-screen icons), awaiting OK to merge |
| Family live test | Next |
| Pre-launch review pass (security + edge cases) | Re-run after the nav/badge merge |
| Share image (og-image-v2.jpg exists, pages still point to og-image.jpg) | Open |
| Cookie care FAQ item (storage + reheating) | Open |

## Locked business rules

These live in the database and in `CLAUDE.md` in the site folder. If one changes, change it there first.

| Thing | Value |
|---|---|
| Flavors | Chimp Chips (brown butter choc chip), Coco Loco (double chocolate), Bueno Mucho (Kinder Bueno) |
| Boxes | 3 = ₱285, 6 = ₱570, 12 = ₱1,080. Box of 4 is retired (switched off, old orders still point at it) |
| Bueno Mucho surcharge | +₱30 per cookie inside a box |
| Singles | Chimp Chips ₱105, Coco Loco ₱110, Bueno Mucho ₱135 |
| Minimum order | Pickup: 1 cookie. Delivery: 2 cookies OR ₱200 |
| Cap | 15 of each flavor per Sunday (boxes and singles both count). A flavor at 15 shows Sold out. All three sold out moves ordering to the next Sunday |
| Order limits | Up to 3 boxes plus any singles, per order |
| Cutoff | Wednesday 9:00pm Asia/Manila (a Sunday accepts orders until 4 days before at 9pm) |
| Fulfillment | Sunday 3-6pm. Pickup at Corinthian Gardens Village, QC, or customer-booked Lalamove/Grab |
| Payment | GCash QR, customer enters the reference number, you verify by hand |
| Unpaid orders | Expire after 24 hours and free their slots |
| Shelf life shown to customers | Chimp Chips and Coco Loco 4-5 days, Bueno Mucho 2-3 days |

## Brand and look

- Hand-drawn die-cut sticker style, blue anchor. Blue `#2B4C93`, cream `#F7EBD5`, paper `#FDF6E8`, chocolate text `#5C3A22`, cookie-dough accent `#E2B074` (fills only, never text).
- Fonts: Baloo 2 (headings) + Nunito Sans (body), self-hosted.
- Header: blue bar, cream text and icons, circular monkey badge logo.
- Badges (set in `FLAVOR_BADGES` in `js/config.js`, no markup to touch): chef-hat monkey = "AJ's Pick" on Coco Loco; tongue-out monkey = "Best seller" on Bueno Mucho (the owner's choice); Chimp Chips has none.
- Never use "diet", "healthy" or "guilt-free".

## Accounts

1. Supabase: project `ajs-bakery`. Free tier. Only the anon key goes in the site code.
2. Vercel: project `ajs-bakery`, deploys from the GitHub repo. (An older duplicate project was removed, so only one URL now.)
3. GitHub: private repo `ajs-bakery-site`.
4. GCash: personal QR saved as `assets/gcash-qr.png`. Consider GCash for Business if volume grows.
5. Instagram: link in bio.
6. Later: Resend (email notifications), domain (~₱700-1,000/yr).

## Database (Supabase)

Migrations `supabase/migrations/001`-`013`, plus `seed.sql`, `seed_content.sql` (generated from `flavor-content.json`) and `tests.sql`.

- `flavors`: name, slug, box price, single price, surcharge, weekly cap, photo and focus fields, plus the detail-sheet content (descriptions, ingredients, allergens, shelf life, storage, nutrition).
- `boxes`: size, price, active.
- `orders` and `order_items`: ref code, Sunday, customer details, fulfillment, total, status, GCash reference, expiry.
- `site_settings`: site-wide allergen and nutrition notes.
- `admins`: who can use the admin pages.

Security: RLS on every table. Anon can read flavors, boxes and settings, and call a handful of functions (`place_order`, `submit_gcash_ref`, `get_order_status`, Sunday/capacity lookup). Anon cannot read orders. Price, cap, minimums and Sunday assignment are all computed in the database. The browser never sends a price.

## Pages

Public: `/` (menu, boxes, how it works, FAQ), `/box.html` (box builder), `/checkout.html`, `/confirmed.html?ref=AJ-XXXX`, `/404.html`.
Admin (login required, noindex): `/admin/login.html`, `/admin/orders.html` (filter, mark paid or cancel, packing view), `/admin/totals.html` (cookies per flavor, batches needed, box counts).
Not linked: `/design-lab.html` (font comparison, noindex).

## Roadmap from here

| When | Goal | Output |
|---|---|---|
| Fri Oct 9 | Preview and merge nav/badges | Check the Vercel preview on your phone, then say OK to merge |
| Fri-Sat Oct 9-10 | Family live test | 3-5 real orders on the live link, on mobile data. Fix what they hit |
| Sat-Sun Oct 10-11 | Pre-launch pass | Re-run the security and edge-case review. Fix share image, add care FAQ |
| Mon-Tue Oct 12-13 | Soft launch | Link in IG bio, pinned post about the Wednesday 9pm cutoff |
| After launch | Watch week one | Note confusing wording, wrong payments, wrong-Sunday questions |

## Before you tell people the link

- Place a full order on your phone using mobile data, not wifi: box, singles, pickup and delivery.
- Try a bad GCash reference and a reused one (both must be rejected).
- Log in to admin, mark paid, and confirm the customer page flips to Paid.
- Check the nav on a real phone at 375px and 430px widths.
- Confirm a sold-out flavor can't be added and the other flavors still can.
- Share the link in an IG DM to yourself and check the preview image and title.

## Later (in this order)

1. Recipes and shopping list in admin (recipes x batches, rounded to purchase units).
2. Email or SMS alert to you on every new order.
3. Payment proof screenshot upload.
4. PayMongo or Xendit for automatic GCash matching.
5. A "look up your order" page (decide if worth it once real customers ask).
6. Custom domain.
7. Joint pop-up with Rocwood (The 7th Street market) once online ordering is steady.

## Risks

- Customer expects the wrong Sunday: the date is on every page and in the confirmation.
- Unpaid orders clogging a flavor's 15 slots: 24-hour expiry releases them.
- Outage = lost orders: keep an IG DM fallback and a manual sheet for the first 2 weeks.
- Nutrition numbers are estimates: keep the "calculated estimate, not lab tested" note visible.
- Never put the service_role key in the repo or the browser.
