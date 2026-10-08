// Shared UI helpers. Pages call these to draw content from CONFIG,
// so prices and text live in js/config.js only.
import { CONFIG } from "./config.js";

// 95 -> "₱95"
export function peso(amount) {
  return "₱" + amount.toLocaleString("en-PH");
}

// Fill the "Now ordering for..." banner
export function renderBanner() {
  document.querySelectorAll("[data-ordering-date]").forEach((el) => {
    el.textContent = CONFIG.nowOrderingFor;
  });
}

// One card per flavor
export function renderMenu(container) {
  container.innerHTML = CONFIG.flavors
    .map(
      (f) => `
      <article class="card">
        <div class="card-photo" role="img" aria-label="Photo of ${f.name} coming soon">🍪</div>
        <div class="card-body">
          <h3>${f.name}</h3>
          <p>${f.description}</p>
          <div class="price">${peso(f.price)} <small>/ cookie</small></div>
          <span class="tag">Macro label coming soon</span>
        </div>
      </article>`
    )
    .join("");
}

// One card per box size, plus the surcharge note
export function renderBoxes(container, noteEl) {
  container.innerHTML = CONFIG.boxes
    .map(
      (b) => `
      <article class="card box-card">
        <div class="card-body">
          <div class="box-size">Box of ${b.size}</div>
          <div class="price">${peso(b.price)}</div>
          <p>${b.blurb}</p>
          <a class="btn" href="box.html?size=${b.size}">Build this box</a>
        </div>
      </article>`
    )
    .join("");

  // Mention any flavor that costs extra inside a box
  const extras = CONFIG.flavors.filter((f) => f.boxSurcharge > 0);
  noteEl.innerHTML = extras
    .map((f) => `${f.name} adds <strong>+${peso(f.boxSurcharge)}</strong> per cookie.`)
    .join(" ");
}

// Fill any [data-config="key"] text from CONFIG (e.g. data-config="pickupWindow")
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
