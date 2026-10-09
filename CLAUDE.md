# CLAUDE.md — AJ's Bakery ordering site

Read this first. It tells any Claude session what this repo is and the rules for working in it. Brand and business background lives one folder up in `../CLAUDE.md`; build planning lives in `website-roadmap.md` and `claude-code-build-guide.md`.

## 1. What this is

An ordering website for AJ's Bakery, a home-based cookie business in Metro Manila. Most customers arrive from Instagram on their phones, so **mobile first**.

Owner (Jazmin) is a beginner vibe coder (basic HTML/CSS/JS, Supabase, Vercel). So:
- Keep things simple. Comment non-obvious code. Explain each decision in one line.
- No clever abstractions; prefer boring, readable code.

### Stack rules
- Plain HTML, CSS, vanilla JavaScript. **No frameworks, no build step.**
- Supabase (JS client loaded from CDN) for database and auth.
- Deploy as a **static site on Vercel**.
- Timezone is always **Asia/Manila**.
- Mobile first.

## 2. Business config

Single source of truth for the numbers. The database is the enforcer and the storefront reads flavors, boxes, prices and the open Sunday from it; `js/config.js` holds only copy text (e.g. the cutoff wording).

| Thing | Value |
|---|---|
| Box of 3 | ₱285 (₱95 per cookie) |
| Box of 6 | ₱570 (₱95 per cookie) |
| Box of 12 | ₱1,080 (₱90 per cookie) |
| Box of 4 | **Retired** (kept in the `boxes` table, switched off: old orders point at it) |
| Bueno surcharge | +₱30 per Bueno Mucho cookie inside a box (so ₱125 each in a box) |
| **Single cookie: Chimp Chips** (brown butter choc chip) | **₱105** |
| **Single cookie: Coco Loco** (double chocolate) | **₱110** |
| **Single cookie: Bueno Mucho** (Kinder Bueno) | **₱135** |
| **Minimum order** | **Pickup: 1 cookie. Delivery: 2 cookies OR ₱200** (either is enough). Singles and box cookies both count |
| **Cap** | **15 of each flavor per Sunday** (`flavors.weekly_cap`), not a total. Box cookies **and** singles both count toward their flavor's cap. When a flavor hits 15 it shows "Sold out"; the other flavors stay available. When ALL flavors are sold out, ordering moves to the next Sunday |
| Order limits | Up to 3 boxes per order, plus any single cookies. An order can't take more of a flavor than is left (the error names the flavor and how many remain) |
| Order cutoff | Wednesday 21:00 Asia/Manila |
| Fulfillment | Pickup, or customer-booked delivery, on Sundays 3–6pm |
| Payment | GCash, customer submits a reference number |
| Unpaid orders | Expire after 24 hours (slot is released) |

**Singles vs boxes:** an order can hold boxes, loose single cookies, or both. A box is cheaper per cookie than singles (that is the point of boxes), so the cart nudges people toward a box when singles would cost more. `flavors.single_price` is the single price (null = not sold as a single). The old `flavors.price` column is unused legacy; ignore it.

**All prices, the pickup/delivery minimums and each flavor's weekly cap are computed in the database** (`place_order`). "Reserved" for a flavor on a Sunday = its cookies in paid orders plus pending orders that haven't expired; expired and cancelled orders free their slots. The browser shows prices for display only and never sends a price.

**Cutoff rule:** a Sunday `S` accepts orders until `S − 4 days at 21:00` Asia/Manila (that's Wednesday 9pm). Orders placed after that go to the next Sunday.

## Flavor details (the detail sheet)

Each flavor row holds its own content: `long_description`, `ingredients`, `allergens`, `weight_g`, `shelf_life`, `storage_tip`, `nutrition_image_url`, `photo_url`. Anything empty shows "coming soon" on the sheet. **Never invent ingredients, allergens or nutrition numbers: the owner writes them** (template at the bottom of `supabase/seed.sql`). Tapping a menu card opens the sheet; `/#chimp-chips` (the flavor name as a slug) opens it from a link.

## Saved cart (browser)

The cart lives in `localStorage` (falls back to `window.name`, then memory, if storage is blocked). It stores a `savedAt` time and is thrown away after **48 hours**. Every page that loads the menu checks the saved cart against it: retired flavors are removed, prices refreshed, and a notice tells the customer. Checkout warns if the ordering Sunday changed since the cart was built. Prices in the cart are display only.

## 3. Security rules

- **Row Level Security (RLS) on every table.** No exceptions, including new tables.
- **Only the anon key** ever appears in browser code. Never the service_role key, never in git.
- **Admin pages sit behind Supabase Auth.** Everything under `admin/` checks for a logged-in session.
- **All price, cap, and cutoff logic is enforced in the database** (Postgres functions/constraints/policies). The browser may calculate totals for display, but never trusts itself: the server recomputes price, checks the cap, and assigns the Sunday.

## 4. Git workflow

**Commit after each finished step.** Small commits, clear messages. Don't batch several steps into one commit.

## 5. Layout

**Photo rules.** Every flavor photo is shown in a fixed shape with `object-fit: cover`: 4:3 on menu cards and the detail sheet, 1:1 for builder thumbnails (with explicit `width`/`height` attributes so nothing jumps). `flavors.focus_x` / `focus_y` (0-100, default 50) say which point of the photo stays in the middle of the crop. Photos in `public/assets/flavors/` are at most 1200px wide and about 150KB each (JPEG); keep the untouched originals in `public/assets/originals/` (git-ignored). Cards sit straight: `--card-tilt` in `styles.css` is `0deg` (set it to e.g. `0.6deg` for a deliberate tilt).

**Publishing a new photo (cache busting).** `vercel.json` makes everything under `/assets/` revalidate on every visit, and the site adds `?v=<number>` to each photo URL so a replaced file can never show stale. Flavor photos use `flavors.photo_version`, nutrition labels use `flavors.nutrition_version`; the logo, hero and GCash QR use `assetVersions` in `js/config.js`. To publish: replace the file, deploy, then run `update public.flavors set photo_version = photo_version + 1 where slug = '<slug>';`.

Only `public/` is deployed (`vercel.json` sets `outputDirectory: public`). Docs, SQL and original photos stay out of the live site.

```
public/                      <- what Vercel serves
  index.html                 storefront / menu
  box.html                   box builder
  checkout.html              customer details + submit
  confirmed.html             order confirmation + GCash instructions
  404.html                   not-found page
  admin/                     login, orders, totals (auth required, noindex)
  css/styles.css             all styles
  js/config.js               Supabase URL + anon key, display copy (flavor text, pickup area, Instagram)
  js/supabase.js             Supabase client (anon key only) + database calls, 10s timeout
  js/cart.js                 cart in localStorage (window.name fallback), display-only prices
  js/cart-ui.js              sticky cart bar + slide-in drawer
  js/ui.js                   shared UI helpers, banner, "ordering is closed" card
  js/flavor-sheet.js         flavor detail bottom sheet (data-driven from the flavors columns; deep link #chimp-chips)
  js/admin.js                shared admin helpers (login guard, Sunday picker, totals math)
  assets/                    flavors/*.jpg (compressed), gcash-qr.png, og-image.jpg
  assets/originals/          full-size flavor photos before compression, git-ignored (NOT deployed)
  robots.txt, sitemap.xml
supabase/                    migrations 001-012, seed.sql, tests.sql  (NOT deployed)
docs/                        planning docs                            (NOT deployed)
source-images/               full-size original photos, git-ignored   (NOT deployed)
vercel.json                  output folder + security headers
```

Preview locally: `python3 -m http.server 8000 --directory public`, then open http://localhost:8000
