# AJ's Bakery Ordering Site: Step-by-Step Build Guide + Claude Code Prompts

Last updated: Fri Oct 9, 2026.
Goal: soft launch Mon-Tue Oct 12-13, 2026. Stack: plain HTML/CSS/JS (no build step) + Supabase + Vercel.
Flow modeled on Bakery Sora's layout: home with menu -> box builder -> sticky cart bar -> cart drawer -> short checkout -> payment. Branding, copy and photos are yours.

## Where things stand

- Steps 0-7 (the MVP) are done and live at https://ajs-bakery.vercel.app.
- Steps 8-15 are the upgrades made after the MVP (singles, per-flavor caps, flavor sheet, boxes 3/6/12, image fixes, logo, design pass, UI polish). All done and on `main`.
- Step 16 (blue nav bar + new logo + flavor badges) is built on branch `fix/ui-polish-nav-badges` and waiting for your phone check on the Vercel preview before merge.
- Steps 17-18 (family test, soft launch) are next.

Steps 0-7 keep the original prompts so you can see how it was built. **Where a number in those prompts differs from the "Current rules" below, the current rules win.** Each step has a note saying what changed later.

## How to use this guide

1. One step = one Claude Code session. Start each step with the prompt, let it finish, then run the "Check" list yourself on your phone.
2. After every step that passes, tell Claude Code: "commit this with a clear message." Never stack steps on a broken one.
3. If something breaks, paste the exact error and say: "Fix this, explain the cause in one line."
4. Work on a branch, check the Vercel preview link on your phone, and only merge to `main` when you say OK.
5. Keep `docs/website-roadmap.md` and this file in the site folder so Claude Code can read them. The site folder's `CLAUDE.md` is the source of truth for rules.

## Current rules (these override older numbers further down)

- Flavors: Chimp Chips (brown butter choc chip), Coco Loco (double chocolate), Bueno Mucho (Kinder Bueno).
- Boxes: 3 = ₱285, 6 = ₱570, 12 = ₱1,080. The box of 4 is retired. Bueno Mucho adds +₱30 per cookie inside a box.
- Singles: Chimp Chips ₱105, Coco Loco ₱110, Bueno Mucho ₱135.
- Minimum: pickup 1 cookie; delivery 2 cookies or ₱200.
- Cap: 15 of each flavor per Sunday (boxes and singles both count). Sold-out flavors show "Sold out"; when all three are out, ordering moves to the next Sunday. (The original plan was 45 cookies total.)
- Order limits: up to 3 boxes plus any singles per order.
- Cutoff: Wed 9:00pm Asia/Manila. A Sunday S accepts orders until S minus 4 days at 21:00.
- Fulfillment: Sunday 3-6pm. Pickup at Corinthian Gardens Village, QC, or customer-booked Lalamove/Grab.
- Payment: GCash QR, customer submits a reference number, you verify by hand. Unpaid orders expire after 24 hours.
- Saved cart: browser localStorage, thrown away after 24 hours and right after an order is placed.
- Look: blue `#2B4C93`, cream `#F7EBD5`, chocolate text `#5C3A22`; Baloo 2 + Nunito Sans; sticker cutouts for flavors.
- Never use "diet", "healthy" or "guilt-free" on the site. The Bueno Mucho badge says "Best seller" by the owner's choice. Never invent ingredients, allergens or nutrition numbers.

---

## STEP 0: Accounts and setup (Tue night, ~45 min, you do this by hand)

> Status: done. Later change: the repo is `jazmin1110/ajs-bakery-site` and the CLAUDE.md config in Prompt 0 was replaced by the Current rules at the top of this guide.

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

> Status: done. Later change: the colors, fonts and look were redone in Step 14. Flavor names are now Chimp Chips, Coco Loco, Bueno Mucho.

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

> Status: done. Later change: the 45-cookie total cap became 15 per flavor (Step 9), singles were added (Step 8), the box of 4 was retired (Step 11). The security tests in tests.sql still apply.

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

> Status: done. Later change: box sizes are now 3 / 6 / 12, the phone layout is compact rows (Step 10), and sold-out states exist (Step 9).

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

> Status: done. Later change: minimums are pickup 1 cookie, delivery 2 cookies or ₱200 (Step 9). Orders can include singles (Step 8).

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

> Status: done. Later change: admin orders, packing view and totals also show singles, and totals now work per flavor against the 15 cap.

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

> Status: done once (commit 18b9a7d). Re-run before launch as Step 17.

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

> Status: done. Live at https://ajs-bakery.vercel.app. Only the `public/` folder is deployed (`vercel.json` sets the output directory).

Do: push the repo to GitHub. In Vercel: Add New Project -> import `ajs-bakery-site` -> Framework: Other -> deploy. No build command, root directory as is. You get a `.vercel.app` link.

### Prompt 7

```
Read CLAUDE.md. Prepare deployment on Vercel as a static site: add a vercel.json if needed (clean URLs, a 404 page, sensible cache headers for assets). In Supabase Auth settings, tell me which Site URL and redirect URLs to add for the Vercel domain. Give me a post-deploy test checklist I can run on my phone: place an order, submit a GCash reference, log in to admin, mark paid, and confirm the customer page updates.
```

Check: run the whole flow on the live link, on mobile data (not your wifi).

---

## STEP 8: Single cookies (done, migration 006)

Why: some people want 1-2 cookies, not a box. Boxes stay cheaper per cookie so they're still the better deal.

### Prompt 8

```
Read CLAUDE.md. Add single-cookie ordering alongside boxes.

1. Database (new migration, never edit old ones): add flavors.single_price (null = not sold as a single). Singles: Chimp Chips 105, Coco Loco 110, Bueno Mucho 135. Update place_order to accept boxes AND singles in one order. Total is computed in the database from box prices, surcharges and single prices. The browser never sends a price.
2. Cart: support singles next to boxes. Show a gentle nudge when a box would be cheaper than the singles in the cart.
3. Menu: each flavor gets a "+ Add" control for singles.
4. Checkout, confirmation and admin (orders, packing view, totals) must show singles as well as boxes.
5. Add tests to supabase/tests.sql for an order with singles only, boxes only, and both.
```

Check: add 1 single + 1 box, confirm the total matches by hand, and confirm admin totals count both.

---

## STEP 9: Per-flavor caps, sold-out, minimums, safer saved cart (done, migrations 007-008)

Why: the cap should protect each batch (15 per flavor), not a vague 45 total. The saved cart also caused a stale ₱410 test box to show up, so it needed hardening.

### Prompt 9

```
Read CLAUDE.md. Change the cap from 45 total to 15 per flavor per Sunday.

1. Database: flavors.weekly_cap (default 15). "Reserved" for a flavor on a Sunday = its cookies in paid orders + pending orders that haven't expired. Expired and cancelled orders free their slots. Boxes and singles both count. place_order rejects an order that takes more of a flavor than is left and names the flavor and how many remain. If ALL flavors are sold out, the ordering Sunday moves to the next one.
2. Minimums, enforced in place_order: pickup needs at least 1 cookie; delivery needs at least 2 cookies OR a total of 200 pesos or more.
3. Storefront: remaining-count stock tags ("5 left") when a flavor is low, "Sold out" styling, boxes unavailable when they can't be filled, and a swap flow that offers another flavor.
4. Saved cart: store savedAt on every change and drop the cart after 24 hours. Clear it right after an order is placed. Every page that loads the menu checks the cart against it: remove retired or sold-out flavors, refresh prices, show a notice. Checkout warns if the ordering Sunday changed since the cart was built. Wrap every localStorage call in try/catch, with fallbacks to window.name, then memory.
5. Tests in supabase/tests.sql: the 16th cookie of one flavor is rejected, other flavors still work, an expired order frees its slot.
```

Check: fill one flavor to 15 and confirm it shows Sold out while the others still sell. Leave a cart for a day (or edit savedAt by hand) and confirm it clears.

---

## STEP 10: Phone layout and the flavor detail sheet (done, migrations 009 and 013)

Why: on a phone, big cards hide the other flavors. Customers also want ingredients, allergens and nutrition before they buy.

### Prompt 10

```
Read CLAUDE.md and flavor-content.json. Two changes.

1. Phone layout (under 700px): flavors and boxes as compact rows, with a "+ Add" pill that turns into a - qty + stepper. From 700px up, keep cards. Several flavors must be visible in one screen on a 390px phone. Descriptions clamp on whole words.
2. Flavor detail sheet: tap a flavor name to open a bottom sheet (js/flavor-sheet.js) with the photo, descriptions, taste notes, ingredients, contains / may contain, weight, shelf life, storage tip, and a nutrition table. Deep link with #chimp-chips. Content comes from the flavors table (new migration adds the columns), loaded from flavor-content.json by supabase/build_seed_content.py. Wording and numbers are used exactly as written in the JSON. Never reword, shorten or invent anything. The nutrition table shows exactly five values: calories, carbs, sugar, fat, protein, plus serving size. Site-wide notes (allergen note, "calculated estimate, not lab tested") live in a site_settings table. A CHECK constraint rejects any other nutrition key.
3. Update the FAQ answer about nutrition and allergens. Tap targets at least 44px.
```

Check: open each sheet on your phone, compare every number to your recipe sheet, and confirm no word like "diet" or "healthy" appears.

---

## STEP 11: Box sizes 3 / 6 / 12 (done, migration 010)

### Prompt 11

```
Read CLAUDE.md. Change boxes from 4 and 6 to 3, 6 and 12.

1. New migration: box of 3 = 285, box of 6 = 570, box of 12 = 1080. Retire the box of 4 by setting active = false (do not delete it: old orders point at it).
2. Box cards on the menu are driven by the boxes table, not hardcoded. Show the saving vs buying singles.
3. box.html and the cart must handle a retired size gracefully (a saved cart with a box of 4 gets a notice and the box is removed).
4. Keep the "can't add until the count is exact" rule in the builder, now for 3, 6 and 12. The 12-box builder must stay usable on a phone (compact steppers, sticky bar).
```

Check: build each size on your phone, confirm the prices, and confirm an old saved cart with a box of 4 doesn't break the page.

---

## STEP 12: Image alignment and stale photos (done, migrations 011-012)

Why: photos were uneven sizes and old photos kept showing after replacing the files (browser cache).

### Prompt 12

```
Read CLAUDE.md. Fix flavor images.

1. Every flavor photo shows in a fixed shape with object-fit: cover: 4:3 on menu cards and the detail sheet, 1:1 for builder thumbnails, with explicit width/height so nothing jumps. flavors.focus_x and focus_y (0-100, default 50) pick the point that stays centered. Cards sit straight (a --card-tilt variable set to 0deg).
2. Resize photos in public/assets/flavors to at most 1200px wide, about 150KB JPEG. Keep untouched originals in public/assets/originals (git-ignored, not deployed).
3. Cache: vercel.json makes /assets/ revalidate on every visit, and the site adds ?v=<number> to each photo URL. Use flavors.photo_version for photos and nutrition_version for nutrition labels. The logo and GCash QR use assetVersions in js/config.js.
4. Explain in CLAUDE.md how to publish a new photo: replace the file, deploy, then run update public.flavors set photo_version = photo_version + 1 where slug = '<slug>';
```

Check: replace one photo, deploy, bump the version, and confirm the new one shows on your phone without clearing the cache.

---

## STEP 13: Logo, favicons and the correct URL (done)

### Prompt 13

```
Read CLAUDE.md. Put the logo from public/assets/logo.png in the header and footer (48px and 40px), show it in the hero on phone and laptop, and generate favicons and an apple-touch-icon from it. Fix og:url and og:image on every page to https://ajs-bakery.vercel.app (they pointed at the old ajs-bakery-site.vercel.app). Remove any duplicate "Pickup & delivery" section.
```

Check: share the link in an IG DM and check the title, image and tab icon.

---

## STEP 14: Design pass (done, on `main`)

Why: the site worked but didn't feel like AJ's. Direction: hand-drawn die-cut sticker style, blue anchor, cream and chocolate, monkey mascot.

### Prompt 14

```
Read CLAUDE.md. Do a design pass on a branch called design-pass and send me the Vercel preview. Do NOT merge to main until I say OK.

1. Brand tokens at the top of css/styles.css: --blue #2B4C93, --cream #F7EBD5, --paper #FDF6E8, --ink #5C3A22 (chocolate text), --accent #E2B074 (fills only, never text). Radius scale 8px / 16px / pill.
2. Fonts: build public/design-lab.html (noindex, unlinked) comparing A) Fraunces, B) Bricolage Grotesque, C) Baloo 2 headings + Nunito Sans body. I pick one. Then self-host it in assets/fonts and preload it in every page's head. (Picked: Baloo 2 + Nunito Sans.)
3. Flavor images become sticker cutouts: transparent background with a cream die-cut outline baked in (never add a CSS border or background to them), WebP at 240w and 480w with srcset. Fall back to the original JPG, then an emoji.
4. Logo becomes a circular badge (blue ring, cream disc). A mascot-only stamp (monkey, no lettering) shows on the empty cart, the confirmation page and the 404 page.
5. A reusable .sticker class for stock tags and the cutoff banner. Everything else stays flat (no heavy shadows, no tilted cards). Only one dashed border is left: the Bueno surcharge note.
6. Add site.webmanifest and icons (192, 512, apple-touch).
```

Check: view the preview on your phone and laptop, then compare to your brand brief. Does it feel handmade and homey, not corporate?

---

## STEP 15: UI polish fixes (done, on `main`)

### Prompt 15

```
Read CLAUDE.md. On a branch, fix these and give me the Vercel preview.

1. .btn labels were off-center (inline-block, left-aligned text). Use inline-flex with align-items and justify-content centered, and even padding.
2. Remove the open attribute from the first FAQ item so all six start closed.
3. The orange cutoff note and the dashed Bueno surcharge note must be width 100% of the content, not narrower.
4. "How it works" cards: number circle level with the title, body text consistent across all cards.
5. The sticky checkout bar must never cover the footer: add bottom clearance.
6. The disabled "Pick N more" button must be legible (at least 4.5:1 contrast) but still look disabled.
7. Test index, box (3, 6, 12), checkout and confirmed at 375px and 430px: no text overflow, tap targets at least 44px, nothing hidden behind the sticky bar. Report what you could not verify.
```

Check: tap through every page on your phone at the end of a long page, and confirm the footer is readable above the sticky bar.

---

## STEP 16: Blue nav, new logo, flavor badges (IN PROGRESS, branch `fix/ui-polish-nav-badges`)

Why: the cream nav blended into the page. A blue nav puts the brand color at the top, and the circular monkey badge pops as a cream disc on blue. Badges give two flavors a reason to be tried.

Before running: save the 3 monkey images into `public/assets/stickers/` as `logo-badge-new.png`, `badge-aj-pick.png` and `badge-tongue.png` (done).

### Prompt 16

```
Work inside the Website folder on a branch called fix/ui-polish-nav-badges. Do NOT push to main. Push the branch only and give me the Vercel preview.

A. Nav + logo
1. Nav bar background var(--blue). Nav text, links, cart icon and cart count in cream. Check contrast on hover, active and focus (focus outline must be cream).
2. Replace the header and footer logo with public/assets/stickers/logo-badge-new.png (WebP at 96px and 192px, srcset, width/height set). The blue ring merges into the blue nav, so it reads as a cream disc; add a thin cream ring if it looks flat.
3. Regenerate favicons and the apple-touch-icon from the new badge.
4. The same nav on every page, including admin.

B. Flavor badges (config-driven)
1. In js/config.js: FLAVOR_BADGES maps a flavor slug to a badge type; BADGE_TYPES defines label and image. Coco Loco = "AJ's Pick" (chef-hat monkey, a bit larger because the hat detail blurs when small). Bueno Mucho = "Best seller" (tongue-out monkey, the owner's choice; the type is called "bestseller"). Chimp Chips has no badge.
2. Small circular stamp, top-right of the flavor image, rotated about -4deg, about 44px on mobile and 56px on desktop. WebP at 96 and 192 with alt text. Must not cover the flavor name or price at 375px.

C. Test at 375px, 430px and 1280px. Report anything you could not verify.
```

Check on your phone: the nav fits on one line, the logo isn't squished, cart count is readable, and the badges don't cover names or prices. Then say OK and ask Claude Code to merge to `main`.

### Step 16b follow-up (same branch)

- Badges: "AJ's Pick" moved to Coco Loco; Bueno Mucho is "Best seller"; Chimp Chips has none. A thin cream die-cut outline is baked into both badge images (like the cookie stickers), so no CSS ring or circle is used.
- The cart button is transparent on the nav blue (it used to be a `--blue-dark` disc on the `--blue` bar: two close but different blues). Hover and focus use `--blue-dark`; the count bubble is cream with blue text.
- The "Boxes" nav link is gone from every header (the hero "Build a box" button and the #boxes section stay). The header logo links to `/` on every page, admin included.
- Home-screen icons (apple-touch-icon, icon-512) are a solid blue square with a cream monkey; icon-192 is the inverted disc. The tab icons (favicon) were NOT changed: the inverted monkey turns to mush at 16px.

---

## STEP 17: Pre-launch review and family test (next)

### Prompt 17 (run after Step 16 is merged)

```
Read CLAUDE.md. Do a pre-launch review of the live site code. Report first, fix only what I approve.

1. Security: list every table and function, confirm RLS is on, and try the anon key against orders, order_items and admins with fetch calls and show me the results. Confirm no service_role key or secret is anywhere in the repo or git history.
2. Rules: test with supabase/tests.sql that the per-flavor cap, the pickup/delivery minimums, the flavor-sum check on boxes of 3, 6 and 12, GCash reference uniqueness and order expiry all behave as CLAUDE.md says.
3. Timezone: confirm Wednesday 20:59 vs 21:01 Asia/Manila, and that nothing depends on the browser clock.
4. Edge cases: double-click on submit, back button after an order, refreshing confirmed.html, a saved cart with a retired or sold-out flavor, localStorage blocked.
5. Share image: use og-image-v2.jpg (or a new branded one with the badge and the Bueno Mucho sticker) on every page's og:image.
6. Add a FAQ item "How do I store and reheat my cookies?" using my wording: airtight at room temp; Chimp Chips and Coco Loco 4-5 days, Bueno Mucho 2-3 days; reheat in a 150-160°C oven, 150°C air fryer, or microwave 8-10 seconds.
Give me a short list of blockers, nice-to-haves, and what you changed.
```

Family test (you do this, ~30 min): send the link to 3-5 people. Ask each to place a real order on their phone using mobile data: one pickup, one delivery, at least one with singles, one with a box. Watch for confusing wording, wrong amounts paid, wrong-Sunday expectations, and anything they ask you in DMs.

---

## STEP 18: Soft launch (Mon-Tue Oct 12-13)

1. Put the link in your IG bio and pin a post: "Orders by Wed 9pm go out this Sunday. Later orders go next Sunday."
2. Keep a DM-order fallback and a manual sheet for the first 2 weeks.
3. Each Wednesday night after 9pm: open admin totals, check the batches needed per flavor (15 cookies per batch, round up), then buy ingredients and plan the Sunday bake.

---

## Later (in this order)

1. Recipes and shopping list on the admin page (recipes and recipe_ingredients tables, batches x grams, rounded to purchase units).
2. Email or SMS notification to you on every new order.
3. Payment proof screenshot upload (Supabase Storage).
4. PayMongo or Xendit for automatic GCash matching.
5. A "look up your order" page, if customers keep asking where their order is.
6. Custom domain.

## If you run out of time (cut in this order)

1. Flavor badges and mascot stamps.
2. Cart drawer: go straight from the box page to checkout.
3. Admin totals page: tally flavors by hand.
4. Packing view.
5. Multiple boxes per order (limit to 1).
Do NOT cut: the database security tests, the flavor-sum check, the per-flavor cap check, and GCash reference uniqueness.

## Tell Claude Code (or me) when you hit these

- You're unsure which key goes where (anon vs service_role).
- A test in Step 2 or Step 17 fails.
- Claude Code suggests adding a framework or a paid service. Say no and ask for the plain version.
- A design change wants to touch prices, caps or cutoff logic. Those live in the database; design work should never need to.
