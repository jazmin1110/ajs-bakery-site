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
  let small = `Orders by ${esc(ordering.cutoffLabel)} go to this Sunday`;
  if (!ordering.isFull && ordering.remaining <= 12) {
    small += ` · only ${ordering.remaining} cookies left`;
  }
  el.innerHTML = `${lead}<small>${small}</small>`;
}

export function renderBannerError(el) {
  el.innerHTML = `Orders are open every week<small>We couldn't load this Sunday's date. Please refresh.</small>`;
}

// ---- Menu + boxes ---------------------------------------------------------------

export function showError(container, message) {
  container.innerHTML = `<p class="load-error">${esc(message)}</p>`;
}

function flavorInfo(slug) {
  return CONFIG.flavorInfo[slug] || { emoji: "🍪", description: "" };
}

export function renderMenu(container, flavors) {
  container.innerHTML = flavors
    .map((f) => {
      const info = flavorInfo(f.slug);
      return `
      <article class="card">
        <div class="card-photo" role="img" aria-label="Photo of ${esc(f.name)} coming soon">${info.emoji}</div>
        <div class="card-body">
          <h3>${esc(f.name)}</h3>
          <p>${esc(info.description)}</p>
          <div class="price">${peso(f.price)} <small>/ cookie</small></div>
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

// Fill [data-config="key"], [data-cutoff] and [data-cap] from static config copy
export function renderConfigText() {
  document.querySelectorAll("[data-config]").forEach((el) => {
    const value = CONFIG[el.dataset.config];
    if (value !== undefined) el.textContent = value;
  });
  document.querySelectorAll("[data-cutoff]").forEach((el) => {
    el.textContent = CONFIG.cutoff.label;
  });
  document.querySelectorAll("[data-cap]").forEach((el) => {
    el.textContent = CONFIG.capPerSunday;
  });
}
