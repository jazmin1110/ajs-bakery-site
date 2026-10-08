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
| Box of 4 | ₱380 |
| Box of 6 | ₱570 |
| Chimp Chips (brown butter choc chip) | ₱95 per cookie |
| Coco Loco (double chocolate) | ₱100 per cookie |
| Bueno Mucho (Kinder Bueno) | ₱125 per cookie |
| Bueno surcharge | +₱30 per Bueno cookie over the ₱95 base, applied inside box totals |
| Cap | 45 cookies per Sunday |
| Order cutoff | Wednesday 21:00 Asia/Manila |
| Fulfillment | Pickup, or customer-booked delivery, on Sundays 3–6pm |
| Payment | GCash, customer submits a reference number |
| Unpaid orders | Expire after 24 hours (slot is released) |

**Cutoff rule:** a Sunday `S` accepts orders until `S − 4 days at 21:00` Asia/Manila (that's Wednesday 9pm). Orders placed after that go to the next Sunday.

## 3. Security rules

- **Row Level Security (RLS) on every table.** No exceptions, including new tables.
- **Only the anon key** ever appears in browser code. Never the service_role key, never in git.
- **Admin pages sit behind Supabase Auth.** Everything under `admin/` checks for a logged-in session.
- **All price, cap, and cutoff logic is enforced in the database** (Postgres functions/constraints/policies). The browser may calculate totals for display, but never trusts itself: the server recomputes price, checks the cap, and assigns the Sunday.

## 4. Git workflow

**Commit after each finished step.** Small commits, clear messages. Don't batch several steps into one commit.

## 5. Layout

```
index.html          storefront / menu
box.html            box builder
checkout.html       customer details + submit
confirmed.html      order confirmation + GCash instructions
admin/              login, orders, totals (auth required)
css/styles.css      all styles
js/config.js        Supabase URL + anon key, and display copy (flavor text, labels). Prices come from the DB
js/supabase.js      Supabase client setup (anon key only)
js/cart.js          cart state in localStorage (display-only prices)
js/cart-ui.js       sticky cart bar + slide-in drawer
js/admin.js         shared admin helpers (login guard, Sunday picker, totals math)
js/ui.js            shared UI helpers
assets/             logo, flavors/*.jpg (web-sized photos), gcash-qr.png
source-images/      full-size original photos (git-ignored, not deployed)
supabase/           migrations 001-004, seed.sql, tests.sql
```
