// Shared UI helpers: formatting, the Sunday banner, and menu/box cards.
// Prices passed in here come from the database and are shown for display only.
import { CONFIG, FLAVOR_BADGES, BADGE_TYPES } from "./config.js";

// 95 -> "₱95"
export function peso(amount) {
  return "₱" + amount.toLocaleString("en-PH");
}

// Escape text before putting it into innerHTML. Anything that came from the
// database or from a customer (names, gift notes) must go through this.
export function esc(text) {
  return String(text).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

// ---- Dates (always Manila-correct) -----------------------------------------

// "2026-10-18" -> "Sunday, Oct 18". Done in UTC so the viewer's own timezone
// can never shift the date by a day.
export function formatSunday(isoDate) {
  return new Date(isoDate + "T00:00:00Z").toLocaleDateString("en-US", {
    weekday: "long", month: "short", day: "numeric", timeZone: "UTC",
  });
}

export function addDays(isoDate, days) {
  const d = new Date(isoDate + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

// A moment in time -> "Wed 9pm", read on the Manila clock
export function formatCutoff(date) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: CONFIG.timezone, weekday: "short", hour: "numeric", minute: "2-digit", hour12: true,
    }).formatToParts(date).map((p) => [p.type, p.value])
  );
  const minutes = parts.minute === "00" ? "" : ":" + parts.minute;
  return `${parts.weekday} ${parts.hour}${minutes}${parts.dayPeriod.toLowerCase()}`;
}

// Turn the database's current_sunday_info row into what the pages show.
// The database says which Sunday a new order would land on (ordering_sunday):
// the upcoming one, or the first later one with room if that one is full.
export function orderingSunday(info) {
  let date = info.ordering_sunday;
  let cutoff = info.ordering_cutoff_at;
  let remaining = info.ordering_remaining;

  // Fallback if the database hasn't got the 002 migration yet: assume next week
  if (date === undefined) {
    date = info.is_full ? addDays(info.sunday_date, 7) : info.sunday_date;
    cutoff = new Date(new Date(info.cutoff_at).getTime() + (info.is_full ? 7 * 24 * 3600 * 1000 : 0));
    remaining = info.remaining;
  }

  return {
    isFull: info.is_full,       // is the UPCOMING Sunday full?
    date,                       // "2026-10-25"
    label: formatSunday(date),  // "Sunday, Oct 25"
    cutoffLabel: formatCutoff(new Date(cutoff)), // "Wed 9pm"
    remaining,
  };
}

// ---- Banner -------------------------------------------------------------------

export function renderBanner(el, ordering, { compact = false } = {}) {
  const lead = ordering.isFull
    ? `This Sunday is full, ordering for <strong>${esc(ordering.label)}</strong>`
    : `Now ordering for <strong>${esc(ordering.label)}</strong>`;
  const small = `Orders by ${esc(ordering.cutoffLabel)} go to this Sunday · ${CONFIG.weeklyCapPerFlavor} of each flavor, once they're gone, they're gone`;
  // compact = one line (the box builder wants its screen space for the flavors)
  el.innerHTML = compact ? `${lead} <span class="banner-by">· by ${esc(ordering.cutoffLabel)}</span>` : `${lead}<small>${small}</small>`;
}

// Shown when we can't reach the database: ordering by Instagram DM is the fallback
export function renderBannerError(el) {
  el.innerHTML = `Ordering is closed right now<small>DM us on Instagram ${esc(CONFIG.instagramHandle)} to order</small>`;
}

// A friendly "closed" card (with the Instagram DM link) for when the menu can't load
export function renderClosed(container) {
  container.innerHTML = `
    <div class="closed-card">
      <h3>Ordering is closed right now</h3>
      <p>We can't reach our order system at the moment, so the menu isn't available here.
         You can still order by message: DM us on Instagram and we'll take your order there.</p>
      <a class="btn" href="${esc(CONFIG.instagramUrl)}" target="_blank" rel="noopener">DM ${esc(CONFIG.instagramHandle)}</a>
    </div>`;
}

// ---- Menu + boxes ---------------------------------------------------------------

export function showError(container, message) {
  container.innerHTML = `<p class="load-error">${esc(message)}</p>`;
}

// "assets/x.jpg" + 3 -> "assets/x.jpg?v=3". A new number is a new URL, so browsers fetch the new file
// instead of showing their cached copy. (No number: the URL is returned unchanged.)
export function withVersion(url, version) {
  if (!url || version == null) return url;
  return `${url}${url.includes("?") ? "&" : "?"}v=${encodeURIComponent(version)}`;
}

// Keep the CSS variable --bar-h equal to the real height of a sticky bottom bar (the cart bar or the box builder's bar),
// so the page's bottom padding is always exactly enough for the bar never to cover the footer or the last row.
// The bar's height changes (a second line of text, the iOS safe area, a rotated phone): ResizeObserver tells us.
export function trackBarHeight(bar) {
  const set = () => document.documentElement.style.setProperty("--bar-h", bar.hidden ? "0px" : `${bar.offsetHeight}px`);
  set();
  if ("ResizeObserver" in window) new ResizeObserver(set).observe(bar);
  window.addEventListener("resize", set);
  return set;
}

// Photos that aren't flavor photos, with their version from config.js (assetVersions)
const ASSET_PATHS = { logo: "assets/stickers/logo-badge-new-96.webp", logo2x: "assets/stickers/logo-badge-new-192.webp", gcashQr: "assets/gcash-qr.png" };
export function assetUrl(name) {
  return withVersion(ASSET_PATHS[name], CONFIG.assetVersions[name]);
}
// Give every <img data-asset="logo"> its versioned src (they start without a src on purpose)
export function applyAssetVersions() {
  document.querySelectorAll("img[data-asset]").forEach((img) => {
    img.src = assetUrl(img.dataset.asset);
    // the logo comes in two sizes (96px for 1x screens, 192px for 2x phones); both share the logo's version number
    if (img.dataset.asset === "logo") img.srcset = `${assetUrl("logo")} 96w, ${withVersion(ASSET_PATHS.logo2x, CONFIG.assetVersions.logo)} 192w`;
  });
}

function flavorInfo(slug) {
  return CONFIG.flavorInfo[slug] || { emoji: "🍪", description: "" };
}

// The sticker file name for a flavor: "assets/flavors/chimp-chips.jpg" -> "chimp-chips"
// (the flavor's photo path in the database decides it, because the sticker files share the photo's name).
function stickerBase(flavor) {
  const path = flavor.photo_url || (CONFIG.flavorInfo[flavor.slug] || {}).image || "";
  return path.split("/").pop().replace(/\.[a-z0-9]+$/i, "");
}

// Sticker image URLs for a flavor at 240 or 480 wide (null if the flavor has no photo to name them after).
// The version number (photo_version) makes a replaced sticker show up straight away.
export function stickerSrc(flavor, width = 240) {
  const base = stickerBase(flavor);
  return base ? withVersion(`assets/stickers/${base}-sticker-${width}.webp`, flavor.photo_version) : null;
}

// A flavor's cookie sticker (a cutout with its die-cut outline already baked in, so no frame is added), or its emoji
// if there is none. If the cutout fails to load, it falls back to the plain jpg, then to the emoji.
//   cls    = the CSS class for the <img> (the CSS gives it its size, shadow and tilt)
//   sizes  = how wide it is shown, so a phone downloads the 240w file and big screens the 480w one
//   lazy   = true for stickers below the fold (the browser loads them as they scroll into view)
// width/height are a ratio hint that stops the page jumping while the image loads.
export function flavorPhoto(flavor, cls, { width = 240, height = 240, sizes = "96px", lazy = false } = {}) {
  const info = flavorInfo(flavor.slug);
  const jpg = flavor.photo_url || info.image;           // the plain photo: the fallback
  const small = stickerSrc(flavor, 240), big = stickerSrc(flavor, 480);
  if (!jpg || !small) return `<span aria-hidden="true">${info.emoji}</span>`;
  const jpgUrl = withVersion(jpg, flavor.photo_version);
  const fallback = `if(!this.dataset.fb){this.dataset.fb=1;this.removeAttribute('srcset');this.classList.add('is-fallback');this.src='${esc(jpgUrl)}';}`
    + `else{this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${info.emoji}'}))}`;
  return `<img class="${cls}" src="${esc(small)}" srcset="${esc(small)} 240w, ${esc(big)} 480w" sizes="${esc(sizes)}"
    alt="${esc(flavor.name)}" width="${width}" height="${height}"${lazy ? ' loading="lazy" decoding="async"' : ""}
    onerror="${fallback}">`;
}

// The monkey stamp (mascot). size = how wide it is shown, in px.
export function mascotImg(size = 80, cls = "mascot") {
  return `<img class="${cls}" src="assets/stickers/mascot-badge-96.webp" srcset="assets/stickers/mascot-badge-96.webp 96w, assets/stickers/mascot-badge.webp 256w"
    sizes="${size}px" width="${size}" height="${size}" alt="" loading="lazy">`;
}

// A flavor's name as a URL hash: "Chimp Chips" -> "chimp-chips" (used by the detail sheet's deep links)
export function flavorHash(flavor) {
  return flavor.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || flavor.slug;
}

// "Sold out" at 0, "3 left" when 5 or fewer remain, nothing otherwise
export function stockLabel(remaining) {
  if (remaining == null) return "";
  if (remaining <= 0) return "Sold out";
  return remaining <= 5 ? `${remaining} left` : "";
}

// The cheapest a cookie gets inside a box: the best box's per-cookie price plus the flavor's
// box surcharge (e.g. 1080 / 12 = 90; Bueno Mucho adds 30 -> 120). For the "or from ₱90 each" label.
export function boxEachPrice(flavor, boxes) {
  if (!boxes.length) return null;
  const perCookie = Math.min(...boxes.map((b) => b.price / b.size));
  return Math.round((perCookie + flavor.surcharge) * 100) / 100;
}

// "Save ₱30 vs singles" for one box: what the SAME number of cookies would cost as singles,
// minus the box price. Flavors cost different amounts, so this uses the worst case (the flavor
// where a box saves least, after its box surcharge): the saving is never overstated, whatever
// mix the customer picks. null when a box wouldn't save anything. Display only.
export function boxSavings(box, flavors) {
  const perCookie = flavors.filter((f) => f.single_price != null).map((f) => f.single_price - f.surcharge);
  if (!perCookie.length) return null;
  const saving = Math.round(box.size * Math.min(...perCookie) - box.price);
  return saving > 0 ? saving : null;
}

// The monkey stamp for a flavor: a small round badge with its label, tilted to the right, overlapping the top-right
// edge of the cookie a little (placement for phone and cards is in styles.css).
// Which flavor gets which badge is FLAVOR_BADGES in js/config.js ("" = no badge).
function flavorBadge(flavor) {
  const type = BADGE_TYPES[FLAVOR_BADGES[flavorHash(flavor)]];
  if (!type) return "";
  const src = (n) => `assets/stickers/${type.image}-${n}.webp`;
  return `<span class="flavor-badge flavor-badge-${esc(FLAVOR_BADGES[flavorHash(flavor)])}">
    <img src="${src(96)}" srcset="${src(96)} 96w, ${src(192)} 192w" sizes="(min-width: 700px) 56px, 44px" width="96" height="96" alt="${esc(type.label)}" loading="lazy" decoding="async">
    <span class="flavor-badge-label" aria-hidden="true">${esc(type.label)}</span>
  </span>`;
}

// One item per flavor. On phones (CSS, under 700px) the items are rows inside one rounded list: text on
// the left, a square thumbnail on the right. From 700px they are the 3-up cards. The markup is the same.
//   * Tapping the item (not the add control) opens the detail sheet.
//   * The add control is a "+ Add" pill; once the flavor is in the cart it shows a "- N +" stepper.
//     Both are in the page from the start and the page script shows one of them (see index.html).
export function renderMenu(container, flavors, boxes = [], availability = {}) {
  container.innerHTML = flavors
    .map((f) => {
      const info = flavorInfo(f.slug);
      const left = availability[f.slug] ? availability[f.slug].remaining : null;
      const stock = stockLabel(left);
      const each = boxEachPrice(f, boxes);
      const inBox = each != null ? `or from ${peso(each)} each in a box` : "";
      const canSingle = f.single_price != null;
      const desc = f.short_description || f.long_description || info.description;
      return `
      <article class="flavor-item" data-slug="${esc(f.slug)}">
        <div class="fi-body" data-open-sheet>
          <div class="fi-text">
            <h3><button type="button" class="card-open" data-open-sheet aria-haspopup="dialog">${esc(f.name)}</button></h3>
            <p class="fi-desc" data-full="${esc(desc)}">${esc(desc)}</p>
            ${canSingle
              ? `<p class="fi-price"><span class="price">${peso(f.single_price)}</span> <small>each</small></p>`
              : `<p class="fi-price"><span class="price">Box only</span></p>`}
            <p class="box-each">${esc(inBox)}</p>
            <p class="fi-extra">
              <span class="stock sticker${left !== null && left <= 0 ? " stock-out" : ""}" data-stock${stock ? "" : " hidden"}>${stock}</span>
              ${f.nutrition ? `<button type="button" class="nutri-link" data-open-nutrition aria-haspopup="dialog" aria-label="Nutrition info for ${esc(f.name)}">Nutrition info</button>` : ""}
            </p>
          </div>
          <div class="fi-photo">${flavorPhoto(f, "card-img", { lazy: true, sizes: "(min-width: 700px) 180px, 96px" })}</div>
          ${flavorBadge(f)}
        </div>
        ${canSingle ? `
        <div class="fi-add" data-add-slot>
          <button type="button" class="add-pill" data-add-single aria-label="Add one ${esc(f.name)} to your cart">+ Add</button>
          <div class="fi-stepper" data-stepper hidden>
            <button type="button" data-single-step="-1" aria-label="One fewer ${esc(f.name)}">&minus;</button>
            <output aria-live="polite" aria-label="${esc(f.name)} in your cart">0</output>
            <button type="button" data-single-step="1" aria-label="One more ${esc(f.name)}">+</button>
          </div>
        </div>` : ""}
      </article>`;
    })
    .join("");
  clampDescriptions(container);
}

// Show at most 3 lines of each short description, cutting after a WHOLE word and adding "…"
// (plain CSS line-clamp can cut in the middle of a word). The full text stays in data-full.
// Called after rendering and again when the screen size changes.
export function clampDescriptions(root = document, lines = 3) {
  root.querySelectorAll(".fi-desc[data-full]").forEach((el) => {
    const full = el.dataset.full;
    el.textContent = full;
    if (window.matchMedia("(min-width: 700px)").matches) return;   // cards have room: show the whole sentence
    if (!el.offsetParent) return;                                   // hidden right now: nothing to measure
    const max = parseFloat(getComputedStyle(el).lineHeight) * lines + 1;
    if (el.scrollHeight <= max) return;                             // fits already
    const words = full.split(" ");
    let lo = 1, hi = words.length - 1;
    while (lo < hi) {                                               // most words that still fit with the "…"
      const mid = Math.ceil((lo + hi) / 2);
      el.textContent = words.slice(0, mid).join(" ").replace(/[\s,;:.\-]+$/, "") + "…";
      if (el.scrollHeight <= max) lo = mid; else hi = mid - 1;
    }
    el.textContent = words.slice(0, lo).join(" ").replace(/[\s,;:.\-]+$/, "") + "…";
  });
}

// Boxes: one row per box on phones (name, price, "Save ₱X vs singles", chevron), cards from 700px.
export function renderBoxes(container, noteEl, boxes, flavors) {
  container.innerHTML = boxes
    .map((b) => {
      const save = boxSavings(b, flavors);
      return `
      <article class="card box-card box-item" data-box-size="${b.size}">
        <div class="card-body">
          <div class="box-size">Box of ${b.size}</div>
          <div class="bi-meta">
            <span class="price">${peso(b.price)}</span>
            ${save ? `<span class="save-badge">Save ${peso(save)} vs singles</span>` : ""}
          </div>
          <p class="box-desc">${esc(b.description || "")}</p>
          <p class="box-left" data-box-left hidden></p>
          <a class="btn bi-cta" data-box-cta href="box.html?size=${b.size}" aria-label="Build a box of ${b.size}">
            <span class="bi-cta-text">Build this box</span><span class="bi-chevron" aria-hidden="true">&rsaquo;</span>
          </a>
        </div>
      </article>`;
    })
    .join("");

  // Mention any flavor that costs extra inside a box
  noteEl.innerHTML = flavors
    .filter((f) => f.surcharge > 0)
    .map((f) => `${esc(f.name)} adds <strong>+${peso(f.surcharge)}</strong> per cookie.`)
    .join(" ");
}

// Fill [data-config="key"], [data-cutoff] and [data-weekly-cap] from static config copy
export function renderConfigText() {
  document.querySelectorAll("[data-config]").forEach((el) => {
    const value = CONFIG[el.dataset.config];
    if (value !== undefined) el.textContent = value;
  });
  document.querySelectorAll("[data-cutoff]").forEach((el) => {
    el.textContent = CONFIG.cutoff.label;
  });
  document.querySelectorAll("[data-weekly-cap]").forEach((el) => {
    el.textContent = CONFIG.weeklyCapPerFlavor;
  });
}
