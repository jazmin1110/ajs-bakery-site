# AJ's Bakery Ordering Site: Step-by-Step Build Guide + Claude Code Prompts

Goal: working MVP by Tue Oct 13, 2026. Stack: plain HTML/CSS/JS (no build step) + Supabase + Vercel.
Flow modeled on Bakery Sora's layout: home with menu -> box builder -> sticky cart bar -> cart drawer -> short checkout -> payment. Branding, copy, and photos are yours.

## How to use this guide

1. One step = one Claude Code session. Start each step with the prompt, let it finish, then run the "Check" list yourself on your phone.
2. After every step that passes, tell Claude Code: "commit this with a clear message." Never stack steps on a broken one.
3. If something breaks, paste the exact error and say: "Fix this, explain the cause in one line."
4. Put `website-roadmap.md` and this file in the site folder so Claude Code can read them.

## Decisions baked into the prompts (change them in Step 0 if you disagree)

- Boxes: 4 = P380, 6 = P570. Only boxes sold online (no singles).
- Flavors: Brown Butter Choc Chip (P95), Double Chocolate (P100), Kinder Bueno (P125). The Bueno surcharge is +P30 per Bueno cookie over the base P95 price, applied inside the box total.
- Cap: 45 cookies per Sunday.
- Cutoff: Wed 9:00pm Asia/Manila. A Sunday S accepts orders until S minus 4 days at 21:00. Orders after that go to the next Sunday.
- Fulfillment: Sunday pickup or customer-booked Lalamove/Grab, 3-6pm.
- Payment: GCash QR, customer submits GCash reference number, you verify manually. Unpaid orders expire after 24 hours.

---

## STEP 0: Accounts and setup (Tue night, ~45 min, you do this by hand)

Do:
1. Create a GitHub account if needed, then a private repo `ajs-bakery-site`.
2. Supabase: new project `ajs-bakery`. Save the Project URL and the anon (public) key. Never put the service_role key in the website code.
3. Vercel: sign in with GitHub. Import the repo later (Step 7).
4. Save your GCash QR as `assets/gcash-qr.png`. Put 3 cookie photos in `assets/`. Put the logo in `assets/logo.png` (placeholder is fine).
5. Open Claude Code in the repo folder.

### Prompt 0 (paste into Claude Code)

```
You're helping me build an ordering website for AJ's Bakery, a home-based cookie business in Metro Manila. I'm a beginner vibe coder (basic HTML/CSS/JS, Supabase, Vercel), so keep things simple, comment non-obvious code, and explain decisions in one line.

Stack rules:
- Plain HTML, CSS, vanilla JavaScript. No frameworks, no build step.
- Supabase (JS client loaded from CDN) for database and auth.
- Deploy as a static site on Vercel.
- Timezone is always Asia/Manila.
- Mobile first: most customers arrive from Instagram on phones.

First, create a CLAUDE.md in this repo that records:
1. What the project is and the stack rules above.
2. This business config: boxes of 4 (P380) and 6 (P570); flavors Brown Butter Choc Chip P95, Brown Butter Double Chocolate P100, Brown Butter Kinder Bueno P125 (Bueno carries a +P30 per cookie surcharge over the P95 base inside box totals); cap 45 cookies per Sunday; order cutoff Wednesday 21:00 Asia/Manila (a Sunday S accepts orders until S minus 4 days at 21:00; later orders go to the next Sunday); pickup or customer-booked delivery on Sundays 3-6pm; payment by GCash with a customer-submitted reference number; unpaid orders expire after 24 hours.
3. Security rules: Row Level Security on every table, only the anon key in browser code, admin pages behind Supabase Auth, all price/cap/cutoff logic enforced in the database (never trust the browser).
4. A rule that you commit after each finished step.

Then create this folder structure (empty files with a one-line comment are fine): index.html, box.html, checkout.html, confirmed.html, admin/login.html, admin/orders.html, admin/totals.html, css/styles.css, js/config.js, js/supabase.js, js/cart.js, js/ui.js, assets/. Add a .gitignore. Do not build features yet. Show me the tree when done.
```

Check: CLAUDE.md exists and the folder tree matches. Commit.

---

## STEP 1: Brand, layout shell, and product data (Wed night, ~1.5 hrs)

### Prompt 1

```
Read CLAUDE.md. Build the visual shell and static menu. No database yet.

1. css/styles.css: define brand tokens as CSS variables at the top so I can change them in one place: --blue (anchor color, pick a friendly mid blue), --blue-dark, --cream (background), --ink (text), --accent (a warm cookie-brown or butter-yellow), plus font stacks. Look: playful, organic, homey, handmade-feeling. NOT sleek or corporate. Rounded corners, soft shadows, a rounded display font from Google Fonts for headings, a clean readable font for body. Mobile first.
2. js/config.js: put the business config here (flavors, prices, box sizes, surcharge, cap, cutoff) as one exported object so nothing is hardcoded elsewhere.
3. index.html: header with logo (assets/logo.png) and a cart icon, a banner showing "Now ordering for Sunday, [date]" (use a placeholder date for now), a short tagline, then a Menu section with a card per flavor (photo placeholder, name, short description, price, a "macro label coming soon" tag), then a "Boxes" section with cards for Box of 4 and Box of 6, then a "How it works" section (Order -> Pay via GCash -> We bake Sunday -> Pickup or delivery) that explains the Wednesday 9pm cutoff in plain words, then an FAQ and a footer with Instagram link placeholder.
4. Make it look good on a 390px wide phone first.

When done, tell me how to preview it locally (simplest method).
```

Check: open on your phone (same wifi) or browser mobile view. Tweak the colors and fonts now, since they're easy to change here.

---

## STEP 2: Database, security, and the Sunday logic (Wed night/Thu, ~2 hrs)

Do first: if Claude Code has the Supabase connection, let it apply migrations. If not, it will give you SQL to paste into Supabase -> SQL Editor.

### Prompt 2

```
Read CLAUDE.md. Design and write the Supabase schema as a single SQL migration file (supabase/migrations/001_init.sql). Requirements:

Tables:
- flavors (id, slug, name, price, surcharge default 0, active)
- orders (id, ref_code unique like AJ-1042, sunday_date date, name, ig_handle, phone, fulfillment ('pickup' or 'delivery'), address, gift_note, total numeric, status ('pending','paid','cancelled','expired'), gcash_ref unique nullable, created_at, expires_at default created_at + 24 hours)
- order_items (id, order_id, flavor_id, qty)
- boxes (id, size int, price numeric, active) for the 4 and 6 box prices
- admins (user_id uuid primary key) listing who may use the admin pages

Functions (in SQL, Postgres):
1. next_order_sunday(ts timestamptz default now()): returns the earliest Sunday S such that (S - 4 days) at 21:00 Asia/Manila is later than ts. Show me 5 test cases in comments, including a Wednesday 20:59, Wednesday 21:01, Saturday, and a Sunday.
2. place_order(...) SECURITY DEFINER, callable by anon: takes name, ig_handle, phone, fulfillment, address, gift_note, box_size, and a list of {flavor_slug, qty}. It must: reject if flavor quantities don't sum exactly to box_size; compute total from the DB (box price + surcharges), ignore any price from the browser; compute sunday_date with next_order_sunday; reject if the new cookies would push that Sunday above 45 cookies (count only orders with status 'pending' that haven't expired, plus 'paid'); require address when fulfillment is 'delivery'; generate a unique ref_code; insert order + items; return ref_code, total, sunday_date. Do all of it in one transaction.
3. submit_gcash_ref(ref_code, gcash_ref): callable by anon, saves the customer's GCash reference number on a pending order. Validate it's 10-15 digits. Rely on the unique constraint to reject a reused number and return a friendly error.
4. get_order_status(ref_code): anon-callable, returns only ref_code, sunday_date, total, status for that code. No personal data.
5. A view or function for the current Sunday and remaining capacity that anon can read (for the banner).
6. is_admin() helper.

Row Level Security: ON for all tables. Anon can read flavors and boxes only. Anon cannot read or write orders/order_items directly (only through the functions above). Admins (is_admin()) can read all and update order status.

Also write supabase/seed.sql with the flavors and boxes from CLAUDE.md. Then write supabase/tests.sql with queries I can run to prove: (a) anon cannot select from orders, (b) a bad flavor sum is rejected, (c) the 46th cookie for a Sunday is rejected, (d) reusing a gcash_ref fails.
```

Check: run the SQL, then run tests.sql. All four tests must behave as described. If (a) fails, stop and fix. That's your customers' phone numbers.

---

## STEP 3: Live menu and box builder (Thu night, ~2 hrs)

### Prompt 3

```
Read CLAUDE.md and the schema. Connect the storefront to Supabase.

1. js/supabase.js: create the client using the project URL and anon key from js/config.js (I'll paste them in).
2. index.html: load flavors and boxes from Supabase instead of config. Show the real banner "Now ordering for Sunday, [date]" and "Orders by Wed 9pm go to this Sunday" using the next-Sunday function and remaining capacity. If the Sunday is full, show "This Sunday is full, ordering for [next date]" and use that date everywhere.
3. box.html?size=4 (and 6): the box builder, like a bakery's "build your box" page. Show a flavor list with a stepper (- qty +) per flavor, a counter "2 of 4 chosen", and a live price that includes the Bueno surcharge. The Add button stays disabled until the count equals the box size exactly. Optional gift note field. Add to cart on click.
4. js/cart.js: cart stored in localStorage (items, box size, flavor quantities, price). Wrap every localStorage call in try/catch. Provide add, remove, change quantity, total, clear.
5. A sticky cart bar at the bottom of the screen that appears when the cart has items ("1 box - P380" and a Checkout button), and a cart drawer that slides in from the right with each box, its flavor breakdown, a remove button, and an "Add another box" link. Limit to 3 boxes per order.

Prices shown in the browser are for display only; the database recalculates them. Mention this in a code comment.
```

Check on phone: you can't add a box until the flavor count is exact; totals match your prices; cart survives a refresh.

---

## STEP 4: Checkout and payment page (Fri night, ~2 hrs)

### Prompt 4

```
Read CLAUDE.md. Build checkout and the payment confirmation.

1. checkout.html: a short single page, like a small bakery order form. Fields: name, mobile (+63 default), Instagram handle (required, starts with @), pickup or delivery (radio). If delivery: address field plus a note "You'll book Lalamove or Grab for the Sunday 3-6pm window; delivery fee is paid by you." If pickup: show the pickup area text from config. Gift note (optional). Show the order summary with each box, the Sunday date in bold ("Ready Sunday, Oct 12"), and the total. Validate in the browser and show friendly errors.
2. On submit: call the place_order function with the cart. Handle errors clearly: Sunday is full (offer the next Sunday), flavor mismatch, network error (keep the cart, show retry). Disable the button while sending to prevent double orders. On success, clear the cart and go to confirmed.html?ref=AJ-XXXX.
3. confirmed.html: show the reference code big, the exact amount to pay, the Sunday date, and assets/gcash-qr.png with plain steps: "1. Pay exactly P___ via GCash. 2. Type your GCash reference number below. 3. Your order is confirmed once we verify the payment." Include a field for the GCash reference number that calls submit_gcash_ref, with friendly errors (wrong length, already used). After submitting, show "Thanks! We'll confirm on Instagram soon." Also show a 24-hour expiry warning, and a copy button for the reference code. Poll get_order_status so the page shows "Paid" once I mark it.
4. Never show other customers' data. confirmed.html may only use get_order_status and submit_gcash_ref.
```

Check: place 3 test orders. Try: a mismatched flavor count (should be blocked), a repeated GCash reference (rejected), and an order on a full Sunday (rejected).

---

## STEP 5: Admin pages (Sat, ~3 hrs)

Do first: in Supabase Auth, create your own user (email + password). Copy your user id and insert it into the `admins` table.

### Prompt 5

```
Read CLAUDE.md. Build the admin area with Supabase Auth. Plain email/password login only.

1. admin/login.html: login form. After login, check is_admin(); if false, sign out and show "Not authorized". All admin pages must redirect to login if there's no valid admin session. Remember this is client-side convenience only; the real protection is RLS.
2. admin/orders.html: pick a Sunday (default current), list orders for it showing ref_code, name, IG handle, phone, items by flavor, fulfillment/address, gift note, total, status, and the submitted GCash reference. Buttons per order: Mark Paid, Cancel. Filter by status. Highlight in amber any pending order that has a GCash reference (needs checking) and in red any that are expired. Add a "Packing view" button that formats paid orders for printing, one per card, with box contents and gift note.
3. admin/totals.html: for the selected Sunday, show cookies per flavor (paid + pending separately), number of boxes of each size, total cookies versus the 45 cap, and batches needed per flavor (15 cookies per batch, round up) with leftover count.
4. A small script or SQL function that marks pending orders past expires_at as 'expired'. Run it automatically when the admin orders page loads.

Keep the admin simple and readable on a phone. No charts needed.
```

Check: log in on your phone, mark an order paid, confirm the customer's confirmation page flips to Paid. Try opening an admin page logged out (must redirect).

---

## STEP 6: Polish and safety pass (Sun, ~1.5 hrs, before baking, or Mon night)

### Prompt 6

```
Read CLAUDE.md. Do a review pass and fix what you find.

1. Security review: list every table and function, confirm RLS is on and that anon can only do what CLAUDE.md allows. Try the anon key against orders, order_items, and admins using fetch calls and show me the results. Check no service_role key or secret exists anywhere in the repo.
2. Timezone review: write down how next_order_sunday behaves at the Wednesday 21:00 boundary and for a user whose phone is set to another timezone. Fix anything that depends on the browser clock.
3. Edge cases: double-click on submit, back button after order, refreshing confirmed.html, a cart with a deleted flavor, localStorage unavailable.
4. Accessibility and mobile: tap targets at least 44px, readable contrast, works at 360px wide.
5. Add basic SEO and share tags (title, description, Open Graph image from assets/) so the link looks good on Instagram.
6. Add a 404 page and a "Ordering is closed" fallback if Supabase can't be reached, with the Instagram handle to DM.

Give me a short list of what you changed and anything you recommend but did not do.
```

---

## STEP 7: Deploy (Mon night, ~30 min)

Do: push the repo to GitHub. In Vercel: Add New Project -> import `ajs-bakery-site` -> Framework: Other -> deploy. No build command, root directory as is. You get a `.vercel.app` link.

### Prompt 7

```
Read CLAUDE.md. Prepare deployment on Vercel as a static site: add a vercel.json if needed (clean URLs, a 404 page, sensible cache headers for assets). In Supabase Auth settings, tell me which Site URL and redirect URLs to add for the Vercel domain. Give me a post-deploy test checklist I can run on my phone: place an order, submit a GCash reference, log in to admin, mark paid, and confirm the customer page updates.
```

Check: run the whole flow on the live link, on mobile data (not your wifi).

---

## STEP 8: Soft launch (Mon-Tue)

1. Send the link to 3-5 friends or family. Ask them to place real orders for the next Sunday.
2. Watch for: confusing wording, people paying the wrong amount, wrong Sunday expectations, anything they ask you in DMs.
3. Put the link in your IG bio and pin a post: "Orders by Wed 9pm go out this Sunday. Later orders go next Sunday."
4. Fallback if the site fails: DM orders and a manual sheet. Keep it for the first 2 weeks.

---

## Later (after MVP, in this order)

1. Recipes + shopping list on the admin page (recipes and recipe_ingredients tables, batches x grams, rounded to purchase units).
2. Email or SMS notifications to you on every new order.
3. Payment proof screenshot upload (Supabase Storage).
4. PayMongo or Xendit for automatic GCash matching.
5. Custom domain.

## If you run out of time (cut in this order)

1. Cart drawer -> go straight from box page to checkout.
2. Admin totals page -> tally flavors by hand.
3. Packing view.
4. Multiple boxes per order (limit to 1).
Do NOT cut: the database security tests, the flavor-sum check, the cap check, and the GCash reference uniqueness.

## Tell me when you hit these

- You're unsure which key goes where (anon vs service_role).
- A test in Step 2 fails.
- Claude Code suggests adding a framework or paid service. Say no and ask for the plain version.
