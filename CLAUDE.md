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
| Box of 4 | ₱380 (₱95 per cookie) |
| Box of 6 | ₱570 (₱95 per cookie) |
| Bueno surcharge | +₱30 per Bueno Mucho cookie inside a box (so ₱125 each in a box) |
| **Single cookie: Chimp Chips** (brown butter choc chip) | **₱105** |
| **Single cookie: Coco Loco** (double chocolate) | **₱110** |
| **Single cookie: Bueno Mucho** (Kinder Bueno) | **₱135** |
| **Minimum order** | **2 cookies**, singles and boxes combined |
| Cap | 45 cookies per Sunday. **Singles count toward it**, same as box cookies |
| Order limits | Up to 3 boxes per order, plus any single cookies (45 cookies max per order) |
| Order cutoff | Wednesday 21:00 Asia/Manila |
| Fulfillment | Pickup, or customer-booked delivery, on Sundays 3–6pm |
| Payment | GCash, customer submits a reference number |
| Unpaid orders | Expire after 24 hours (slot is released) |

**Singles vs boxes:** an order can hold boxes, loose single cookies, or both. A box is cheaper per cookie than singles (that is the point of boxes), so the cart nudges people toward a box when singles would cost more. `flavors.single_price` is the single price (null = not sold as a single). The old `flavors.price` column is unused legacy; ignore it.

**All prices, the 2-cookie minimum and the cap are computed in the database** (`place_order`). The browser shows prices for display only and never sends a price.

**Cutoff rule:** a Sunday `S` accepts orders until `S − 4 days at 21:00` Asia/Manila (that's Wednesday 9pm). Orders placed after that go to the next Sunday.

## 3. Security rules

- **Row Level Security (RLS) on every table.** No exceptions, including new tables.
- **Only the anon key** ever appears in browser code. Never the service_role key, never in git.
- **Admin pages sit behind Supabase Auth.** Everything under `admin/` checks for a logged-in session.
- **All price, cap, and cutoff logic is enforced in the database** (Postgres functions/constraints/policies). The browser may calculate totals for display, but never trusts itself: the server recomputes price, checks the cap, and assigns the Sunday.

## 4. Git workflow

**Commit after each finished step.** Small commits, clear messages. Don't batch several steps into one commit.

## 5. Layout

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
  js/admin.js                shared admin helpers (login guard, Sunday picker, totals math)
  assets/                    flavors/*.jpg, gcash-qr.png, og-image.jpg
  robots.txt, sitemap.xml
supabase/                    migrations 001-006, seed.sql, tests.sql  (NOT deployed)
docs/                        planning docs                            (NOT deployed)
source-images/               full-size original photos, git-ignored   (NOT deployed)
vercel.json                  output folder + security headers
```

Preview locally: `python3 -m http.server 8000 --directory public`, then open http://localhost:8000
