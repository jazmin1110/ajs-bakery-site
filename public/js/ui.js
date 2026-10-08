// Shared UI helpers: formatting, the Sunday banner, and menu/box cards.
// Prices passed in here come from the database and are shown for display only.
import { CONFIG } from "./config.js";

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

export function renderBanner(el, ordering) {
  const lead = ordering.isFull
    ? `This Sunday is full, ordering for <strong>${esc(ordering.label)}</strong>`
    : `Now ordering for <strong>${esc(ordering.label)}</strong>`;
  const small = `Orders by ${esc(ordering.cutoffLabel)} go to this Sunday · ${CONFIG.weeklyCapPerFlavor} of each flavor, once they're gone, they're gone`;
  el.innerHTML = `${lead}<small>${small}</small>`;
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

function flavorInfo(slug) {
  return CONFIG.flavorInfo[slug] || { emoji: "🍪", description: "" };
}

// A flavor photo, or its emoji if there's no photo (or it fails to load).
// cls = the CSS class for the <img>.
export function flavorPhoto(slug, name, cls) {
  const info = flavorInfo(slug);
  if (!info.image) return `<span aria-hidden="true">${info.emoji}</span>`;
  return `<img class="${cls}" src="${esc(info.image)}" alt="${esc(name)}" loading="lazy"
    onerror="this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${info.emoji}'}))">`;
}

// "Sold out" at 0, "3 left" when 5 or fewer remain, nothing otherwise
export function stockLabel(remaining) {
  if (remaining == null) return "";
  if (remaining <= 0) return "Sold out";
  return remaining <= 5 ? `${remaining} left` : "";
}

// The cheapest a cookie gets inside a box: the best box's per-cookie price plus the flavor's
// box surcharge (e.g. 380 / 4 = 95; Bueno Mucho adds 30 -> 125). For the "or from ₱95 each" label.
export function boxEachPrice(flavor, boxes) {
  if (!boxes.length) return null;
  const perCookie = Math.min(...boxes.map((b) => b.price / b.size));
  return Math.round((perCookie + flavor.surcharge) * 100) / 100;
}

// One card per flavor: single price, "or from ₱X each in a box", and a stepper + Add button for singles.
export function renderMenu(container, flavors, boxes = [], availability = {}) {
  container.innerHTML = flavors
    .map((f) => {
      const info = flavorInfo(f.slug);
      const left = availability[f.slug] ? availability[f.slug].remaining : null;
      const stock = stockLabel(left);
      const each = boxEachPrice(f, boxes);
      const inBox = each != null ? `from ${peso(each)} each in a box` : "";
      const canSingle = f.single_price != null;
      return `
      <article class="card" data-slug="${esc(f.slug)}">
        <div class="card-photo">${flavorPhoto(f.slug, f.name, "card-img")}</div>
        <div class="card-body">
          <h3>${esc(f.name)} ${stock ? `<span class="stock${left <= 0 ? " stock-out" : ""}" data-stock>${stock}</span>` : `<span class="stock" data-stock hidden></span>`}</h3>
          <p>${esc(info.description)}</p>
          ${canSingle
            ? `<div class="price">${peso(f.single_price)} <small>each</small></div>
               <p class="box-each">${inBox ? `or ${esc(inBox)}` : ""}</p>
               <div class="single-add">
                 <div class="stepper">
                   <button type="button" data-single-step="-1" aria-label="One fewer ${esc(f.name)}">&minus;</button>
                   <output aria-label="${esc(f.name)} quantity">1</output>
                   <button type="button" data-single-step="1" aria-label="One more ${esc(f.name)}">+</button>
                 </div>
                 <button type="button" class="btn btn-small" data-add-single>Add to cart</button>
               </div>`
            : `<div class="price">Box only</div>
               <p class="box-each">${esc(inBox)}</p>`}
          <span class="tag">Macro label coming soon</span>
        </div>
      </article>`;
    })
    .join("");
}

export function renderBoxes(container, noteEl, boxes, flavors) {
  container.innerHTML = boxes
    .map(
      (b) => `
      <article class="card box-card">
        <div class="card-body">
          <div class="box-size">Box of ${b.size}</div>
          <div class="price">${peso(b.price)}</div>
          <p>${esc(CONFIG.boxBlurbs[b.size] || "")}</p>
          <a class="btn" href="box.html?size=${b.size}">Build this box</a>
        </div>
      </article>`
    )
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
