# Storefront design review — Nov 6, 2026

Checked on the live site at iPhone SE (375×667), iPhone 15 (393×852), iPhone Pro Max (430×932), iPad (820×1180) and desktop (1440). The iOS Simulator could not be used (this Mac has only the Xcode command-line tools), so phones were emulated in the browser at their exact sizes.

## Verdict

The site is clean, consistent and on-brand at the top, and it works at every size. It is not yet *appealing* for one main reason: **after the first screen it stops being AJ's.** The menu shows the best asset (the cookies) at thumbnail size, and everything below the menu (How it works, FAQ, footer) is a stack of identical cream boxes that any bakery template would have. The monkey, the stickers and the blue all disappear after the hero.

Score, as a design juror would (1–10): design 6.5 · usability 7.5 · creativity 6 · content 7 → **6.8 overall**. Real award-level small-shop sites land around 7.5–8.

## What works (keep)

- The sticker cutouts. On cream they look tactile and hand-made, exactly the brand.
- Blue nav + Baloo 2 headings: confident, friendly, readable.
- The tilted "Now ordering for Sunday" sticker banner.
- Clear, honest copy. Prices are easy to find. Steppers and buttons are thumb-sized.
- iPad layout: the 2-line headline and 3-up cookie cards are the best-looking version of the site.

---

## Top 3 (biggest visual payoff)

### 1. Make the cookies big on phones
On a phone each cookie is a ~96px circle on the right of a text-heavy row (photo: iPhone 15, menu). The food is what sells and it's the smallest thing on the card.
- **Do:** on phones, put the sticker on top at ~200–240px, centred, with the badge on it, then name, one-line description, price, and the Add button in one row under it. Three big cookies stacked reads like a menu board, not a spreadsheet.
- Cut the per-card clutter: "or from ₱95 each in a box" appears on every card. Say it once above the list ("Cheaper in a box: from ₱95 each").
- "Nutrition info" as a small pill with the calorie number (e.g. "~280 kcal") instead of an underlined link. That also surfaces the brand's transparency promise.

### 2. Turn "How it works" + the orange cutoff box into one "week" strip
Right now it's four numbered cards (a full phone screen for 20 words) then an orange box repeating the rules. This is the template part of the page.
- **Do:** one horizontal Mon→Sun strip on a full **blue field** (the page's one colour break), with Wednesday marked "Orders close 9pm" and Sunday marked "Bake + pickup 3–6pm", and today highlighted. It shows the whole business model in one glance, it's specific to AJ's weekly drop, and it changes every day you visit (the live element the page is missing).
- On phones it's a compact 7-dot row with two labelled stops; the four steps become one sentence under it.

### 3. Give the page real photos beyond the three cutouts
The only pictures are the three stickers. A food page without a single photo of the food broken open, the box, or the kitchen feels thin, however clean it is.
- **Do (needs photos from you):** 3–4 real shots in the same light: a cookie torn in half (gooey centre), the box of 6 open from above, the cookies on the tray, your hands or the kitchen. Use one big one between the menu and boxes, and one on each box option.
- Until then, the boxes can show the stickers stacked (3, 6, 12 little cookies) so you *see* the size instead of reading "Box of 6".

---

## Everything else

### Hero
- **Headline is generic.** "Warm cookies, made at home" could be any home baker in Manila. Swap the name and it still works. Something only AJ's can say would land harder, e.g. around the Sunday drop or the 15-a-flavor limit ("Fresh every Sunday. Only 15 of each." / "Sunday cookies, 15 at a time."). Your words, your call.
- **4-line headline on every phone.** It pushes the buttons to the bottom of an SE screen. Shorter copy or a slightly smaller phone size gets it to 2–3 lines.
- **Banner + hero compete.** The floating sticker banner is ~90px of three lines on phones, above the headline. Fold the key fact into the hero ("Ordering for Sun, Nov 15 · closes Wed 9pm") and drop the "once they're gone" sentence there (it's repeated lower down).
- **Two equal buttons.** "Order cookies" and "Build a box" look equally important. Pick one primary. Boxes earn more per order, so "Build a box" as the filled one is a reasonable choice.
- The tagline repeats "home" from the headline. Use it for something new (what makes them different: brown butter, Callebaut, nutrition labels).

### Menu
- "Cookies" heading, then "Classics" + "The everyday favorites", then "Specials" + "Loaded with the good stuff": two levels of headings and two filler lines. Drop the sub-lines; let a small "Special" tag on the card do the work.
- iPad: "Classics" sits over two columns and "Specials" over one, so the headings look misaligned. Either one heading over all three or a single row with tags.
- Desktop: the "+ Add" pill floats alone at the bottom-right of each card with empty space beside it. Put price and Add on the same row.
- Bueno Mucho's description truncates mid-sentence on phones ("…Our…"). Shorter short-descriptions beat automatic "…".

### Boxes
- Text-only rows. Show the stacked stickers per size (see #3), and give the box of 6 a "Most popular" or "Best value" sticker so there's an obvious default.
- The dashed "Bueno Mucho adds +₱25" note is the only dashed border on the site. Put the surcharge on the Special tag instead and drop the box.

### FAQ and footer
- Seven identical boxed questions is a full phone screen of the same shape. Plain question rows with space between them (no boxes) look lighter and more confident. Put the top two (delivery, storing/reheating) first.
- The footer is one line. Make it a designed close: the mascot larger, "AJ's" big, the order window ("Orders close Wed 9pm · Sunday pickup 3–6pm, Quezon City"), Instagram and Messenger, and the allergen line.

### Colour and type
- The whole page is cream-on-cream boxes. Blue appears only in the nav and footer. One full blue section (the week strip) gives the page rhythm.
- Too many small text sizes (about six between 13 and 16px). Settle on body + one small size; it'll look calmer.
- Emoji in the UI (🎁 📅 ⏰ ✅ 🐵) clash with the drawn monkey. Use the mascot or nothing.

### Loading and slow connections (seen today on a slow line)
- While loading, the logo shows as a **broken image icon**, the tagline is missing, and an empty "Coming soon" heading flashes. Put the logo `src` straight in the HTML and hide "Coming soon" in HTML, not after the script runs.
- After 10 seconds the banner switches to **"Ordering is closed right now"**. On slow mobile data that tells a real customer the shop is shut when it isn't. Retry once, and if it still fails say "Having trouble loading. Pull to refresh, or DM us" instead.

---

## Suggested order
1. Big cookies on phones + menu clutter cut (#1). Pure CSS/markup, biggest visual gain.
2. Week strip on a blue field replacing How it works + cutoff box (#2).
3. Loading fixes (broken logo, "Coming soon" flash, "closed" on slow load). Small, protects sales.
4. Hero tightening (shorter headline, one primary button, banner folded in). Needs your copy choice.
5. Boxes with stacked stickers, FAQ/footer refresh.
6. Real photos when you have them (#3).
