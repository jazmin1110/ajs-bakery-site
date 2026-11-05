# AJ's Bakery site review — storefront + admin (Nov 6, 2026)

How this was done: read every page in `public/` and the key database functions, then clicked through the live site (ajs-bakery.vercel.app) on desktop and at phone width: home, flavor sheet, singles add, box builder, cart drawer, checkout validation, confirmation page, 404, and every admin page (Orders incl. the Add-order form, Bake plan, Menu, Stock, Recipes, Sales). No order was placed and nothing in the admin was changed. The admin at phone width could not be checked while logged in (only the login page), so that part is unverified.

Severity: 🔴 fix before Christmas launch · 🟡 worth doing soon · 🟢 polish.

---

## Overall

The build is in genuinely good shape for a one-person home bakery. The hard parts are right: prices, caps and the Sunday cutoff live in the database, the cart survives reloads, idempotent order placement, a working sold-out/swap flow, and an admin that covers orders → bake plan → stock → costing. The design is coherent (blue + cream + sticker cutouts) and reads as a real brand, not a template.

The biggest gaps are **operational, not technical**: nobody gets told when an order arrives, the GCash step relies on a QR alone, and the brand's main differentiator (nutrition transparency) is buried. Those three are the first things to fix.

---

## 🔴 Fix before launch

### 1. No one is notified when an order or a GCash reference comes in
Right now Jazmin only finds out about an order by opening `admin/orders.html`. With a 24-hour payment window and customers waiting for an Instagram DM to confirm, a missed morning means expired orders and annoyed customers.
- **Do:** a Supabase database webhook (or `pg_net` trigger) on `orders` insert and on `gcash_ref` update that sends an email (Resend free tier) or a Telegram/Messenger message. Cheapest useful version: one email per new order with the ref code, total and GCash ref.
- Also add a visible unpaid-order count on the admin Orders page header so she sees "2 to check" the moment she opens it, whatever Sunday is selected (today the summary is per-Sunday only).

### 2. GCash payment page shows a QR and nothing else
`confirmed.html` shows only the QR image. Many Filipinos pay by typing a number into "Send Money", and anyone viewing on the phone they'll pay from can't scan their own screen (the "press and hold to save" tip helps but is fiddly). If the QR image ever fails to load the fallback says "coming soon".
- **Do:** print the GCash mobile number and account name next to the QR, with a tap-to-copy button for the number, and the exact amount already shown. Add "Pay via GCash → Send Money → enter number" as the first instruction, QR second.

### 3. Hidden flavors leak into admin numbers and bake planning
The 4 new flavors (Nutella, Biscoff, PB Reese's, Banana Bread) are hidden via the Menu switches, which is correct for customers. But:
- **Sales → Cookies per flavor** lists them all as "15 of 15 left", which reads as sellable stock.
- **Bake plan** lists all 7 flavors with "Nothing ordered" rows, doubling the page length every week.
- The admin **Add order** single-cookie list includes hidden flavors with no "hidden" tag, so a mis-tap sells a flavor you haven't finished testing.
- **Do:** tag hidden/sold-out flavors in all three places (reuse the Menu page's `tag` style) and collapse "nothing ordered" flavors on the Bake plan behind a "Show all" toggle.

### 4. Stock is empty, so the first bake weekend will fight the system
Every ingredient reads 0 g, stock value ₱0, 4 prices still guessed. That means the first shopping list will tell her to buy everything, and the first "I made the dough" tap will hit the "short stock" warning for every batch.
- **Do (data, not code):** one evening of "Recount" on each ingredient before the first baking weekend, and log the 4 guessed prices (vanilla, salt, banana, cinnamon). This is a to-do, not a bug, but it decides whether the admin is useful or ignored from week one.

### 5. Nutrition transparency is invisible on first screen
The brand positioning is "good-tasting + nutrition transparency", yet the hero says only "Warm cookies, made at home" and nutrition shows up as a small underlined link per card and one FAQ item.
- **Do:** one line under the tagline ("Every cookie comes with its ingredients, allergens and macros. Tap any cookie to see them.") and make the per-card nutrition link a small pill with the calorie number ("300 kcal") so the transparency is seen, not hunted for. Keep the mindful-eating tone, no "healthy"/"diet" words.

---

## 🟡 Worth doing soon

### Storefront — logic & features
6. **Box builder: tapping a flavor name adds a *single*, not a box cookie.** On `box.html`, the flavor name opens the detail sheet, whose "Add · ₱110" button adds a loose single to the cart while you are mid-box. A customer building a box of 3 can end up with 3 in the box plus 1 stray single. Either hide the sheet's add stepper on the builder or make it say "Add to this box".
7. **"Find my order" is missing.** The confirmation page says the link is the only way to look up an order. If the ref is missing it just errors. Add a small form on `confirmed.html` (no ref → "Enter your code AJ-XXXXXX") so customers who lost the tab can get back to the payment step.
8. **Pickup area is revealed too late.** Choosing pickup vs rider depends on where you are, but "Corinthian Gardens, QC" appears only after picking "Pickup" at checkout. Put "Pickup in Corinthian Gardens, Quezon City" in the FAQ and the checkout fulfillment hint, before the choice.
9. **Instagram handle is mandatory.** Mom's Christmas gift list and Messenger/walk-in friends may not have Instagram. Consider "Instagram or Messenger name" with a radio for which one, or make IG optional when a phone is given (admin orders already allow this).
10. **Confirmed page forgets delivery on another device.** The rider/pickup choice is read from `localStorage`, so on a second device the "book your Lalamove" line disappears. Return `fulfillment` from `get_order_status` (it isn't personal data) and drop the localStorage hack.
11. **Cutoff urgency.** The banner shows "Order by Wed, Nov 11, 9pm" but nothing changes as the deadline nears. A simple "closes in 6 hours" from Wednesday noon onward is cheap and drives orders.
12. **Checkout summary has dead remove handlers.** The summary listens for `data-remove-box`/`data-remove-single` clicks but never renders those buttons. Either render "Remove" links (useful) or delete the handler.
13. **Possible lost tap right after closing the sheet.** Closing the sheet calls `history.back()`; the `inert` attributes on the page are only removed when `popstate` fires. A tap on "+ Add" in that gap is swallowed (reproduced once in testing). Remove `inert` in `close()` immediately rather than waiting for popstate.
14. **Meta description is hard-coded to 3 flavors.** When the new flavors go live the Google/Instagram link preview still says "Chimp Chips, Coco Loco and Bueno Mucho". Keep the description generic ("brown butter cookies, 7 flavors, Sunday pickup/delivery in Metro Manila").

### Storefront — design
15. **Desktop menu cards have a dead zone** between "Nutrition info" and the lone "+ Add" pill (about 50px of empty cream). Pull the add control up to sit beside the price row, or give the card a bottom bar with price left / add right.
16. **Hero shows Bueno Mucho but "AJ's Pick" is Coco Loco.** Not wrong, just mixed messaging. Either make the hero cookie the pick, or drop the badge to "Best seller" only.
17. **Box cards on desktop** have the big "Save ₱30 vs singles" badge but no hint of what's inside; the one-line descriptions ("Share it (or don't)") are good, but a tiny row of the three cookie stickers would sell it better than text.
18. **Footer is thin.** Instagram handle only. Add pickup area, order window ("orders open Fri–Wed, cookies every Sunday"), and a Messenger/DM link. This is also where the allergen note belongs ("made in a kitchen that handles peanuts").
19. **"Final price is confirmed when you place your order"** reads like the price might go up. "Prices shown are final; we just double-check stock when you order." is calmer.
20. **Mobile menu descriptions truncate at three lines with "…"** which is fine, but the truncation cuts mid-selling-point ("Soft, chewy, and the one to…"). Shorten `short_description` to two lines of phone text per flavor instead of relying on clamping.

### Admin — logic & features
21. **Default Sunday after the cutoff.** On Friday the storefront is already selling Nov 15, but Orders/Bake plan/Sales open on Nov 8. That is right for baking, but the empty-Sunday hint ("Next orders are for…") only appears when there are zero orders. Add a persistent one-line "Taking orders for Nov 15 · 0 so far" strip at the top of Orders so both Sundays are visible at once.
22. **Sales "All time" ranges disagree.** Best sellers start from 2020, Money from 2026-01-04. Make both "all time" and use the first order date.
23. **Sales shows −₱87 waste with no bakes ever.** Correct (a discarded lot), but with nothing else on the page it looks like a bug. When money in is 0, lead with "Nothing sold yet" and fold cost lines into a details block.
24. **Expiring unpaid orders only happens when an admin page opens or an order is placed.** Capacity math already ignores stale orders so this is safe, but the customer's confirmation page will say "pending" for a long-dead order until something triggers the sweep. A `pg_cron` job every 15 minutes calling `expire_stale_orders()` removes the ambiguity (one line of SQL on Supabase).
25. **No order export.** Christmas gifting will be 30–60 orders; a "Download CSV for this Sunday" button (name, phone, items, paid, pickup/delivery, address) is a 20-line addition and saves re-typing into a spreadsheet for labels/stickers.
26. **Admin pages on phone are unverified.** Logged-in admin could not be tested at phone width in this review. The code has a scrolling nav with fade edges, so it should work, but check the Orders card buttons and the Add-order steppers on an actual phone before launch, since that's where it will be used on a Sunday.

### Admin — design
27. **Orders page empty state is bare.** "No orders for this Sunday yet" and nothing else. Show the "Left to sell" line and the quick actions (Add order, switch Sunday) even when empty.
28. **Recipes page is a very long scroll** (7 cards × full ingredient tables). Collapse each flavor to its cost summary with the ingredient table behind "Edit recipe".
29. **Stock cards repeat four buttons each** (I bought some / Used some / Recount / Edit) × ~25 items. Keep "+ I bought some" as the primary and put the other three behind a "⋯" menu, or a single row of icon buttons.

---

## 🟢 Polish

30. Pin the Supabase CDN import to an exact version (`@supabase/supabase-js@2.x.y`) instead of `@2`; a breaking minor release would take the whole site down with no build step to catch it.
31. Add a Content-Security-Policy header in `vercel.json` (script-src self + jsdelivr; connect-src self + the Supabase host). Cheap insurance for a site that holds customer phone numbers.
32. `index.html` still ships the empty "Coming soon" section markup and the `COMING_SOON` config; drop it or repurpose as a "Next up" teaser once the 4 flavors are test-baked.
33. The Instagram handle `@ajs.mnl` is in config; the schema.org block duplicates it. Fine, just keep them in sync when the handle changes.
34. Phone input placeholder "917 123 4567" is right for PH; consider `autocomplete="tel-national"` already set → also add `pattern` so iOS shows the numeric keypad consistently (inputmode is set, so this is minor).
35. Drawer "Clear cart" uses a browser `confirm()`; swap for an inline "Really clear? Yes / No" so it matches the rest of the UI.
36. Admin `menu.html` has no Sunday context; a tiny "Changes apply to Nov 15 ordering" line avoids the "did I just hide it for this weekend's bake?" doubt.

---

## What's working well (keep it)
- Price, cap and cutoff logic in the database; the browser never sends a price.
- Idempotent order placement and the retry-safe "Try again" flow.
- The sold-out swap panel at checkout and the 30-second availability refresh.
- Cart survives reloads, cleans itself against the live menu, and tells the customer what changed.
- Flavor detail sheet: ingredients, allergens, nutrition, shelf life, swipe-to-close, deep links, back-button support.
- Admin stage pills ("Check payment → To bake → Baking → Ready → Done") with one primary action per card.
- Two-price costing (latest price vs what the lot actually cost) and the "I went shopping" bulk receive.
- Visual identity: the sticker cutouts, mascot badges, Baloo 2 headings and the cream/blue palette are consistent on every page including 404 and admin.

## Suggested order of work
1. Order notifications (#1) and GCash number + name on the payment page (#2) — half a day.
2. Hidden-flavor tags in admin (#3) and the box-builder single-add trap (#6) — a couple of hours.
3. Stock recount + real prices (#4) — one evening, no code.
4. Nutrition line in the hero + calorie pill (#5), pickup area earlier (#8), find-my-order (#7).
5. Everything else as time allows before the December pop-up.
