// The flavor detail sheet: a bottom sheet with the photo, description, taste notes, allergens,
// ingredients, a simple nutrition table, shelf life and storage for one flavor.
//
// It is DATA-DRIVEN: everything comes from the flavor object (the columns on the `flavors` table) and
// the two site-wide notes (the `site_settings` table), and `flavorDetailHtml()` turns one flavor into HTML
// without touching the page. So when the sheet becomes its own page later, that page can call the same function.
//
//  * Opens from a tap on a menu row, or from the URL hash (#chimp-chips), and writes the hash
//    when it opens. The phone's back button and Escape close it.
//  * Focus stays inside it while open; it is a labelled dialog for screen readers.
//  * It never touches localStorage/sessionStorage, so it works with storage blocked.
//  * The nutrition numbers are estimates shown for transparency. Only five values are shown.
import { esc, peso, stockLabel, flavorPhoto, flavorHash } from "./ui.js";

const g = (n) => `${n} g`;

// The nutrition table: the serving line, Calories (large), Carbs, "of which sugars" (indented), Fat, Protein.
// Nothing else, and no "% daily value" column. Returns "" if the flavor has no nutrition data.
function nutritionTable(n) {
  if (!n || typeof n !== "object") return "";
  return `
    <table class="nutri-table">
      <caption>${esc(n.serving)}</caption>
      <tbody>
        <tr class="nutri-cal"><th scope="row">Calories</th><td>${esc(n.calories)}</td></tr>
        <tr><th scope="row">Carbs</th><td>${esc(g(n.total_carbohydrate_g))}</td></tr>
        <tr class="nutri-sub"><th scope="row">of which sugars</th><td>${esc(g(n.sugars_g))}</td></tr>
        <tr><th scope="row">Fat</th><td>${esc(g(n.total_fat_g))}</td></tr>
        <tr><th scope="row">Protein</th><td>${esc(g(n.protein_g))}</td></tr>
      </tbody>
    </table>`;
}

// ---- Pure: one flavor in, HTML out -----------------------------------------------------------
// settings = { global_allergen_note, nutrition_note } (either may be missing). No buttons here: those are page-specific.
// Sections with no data are left out (nothing is made up).
export function flavorDetailHtml(flavor, { settings = {} } = {}) {
  const list = (a) => (Array.isArray(a) ? a.filter(Boolean) : []);
  const notes = list(flavor.taste_notes);
  const contains = list(flavor.contains);
  const mayContain = list(flavor.may_contain);
  const table = nutritionTable(flavor.nutrition);
  const facts = [["Shelf life", flavor.shelf_life], ["Storage", flavor.storage_tip]].filter(([, v]) => v);

  return `
    <div class="sheet-photo">${flavorPhoto(flavor, "sheet-img", { width: 480, height: 480, sizes: "240px" })}</div>
    <div class="sheet-main">
      <h2 id="sheet-title">${esc(flavor.name)}</h2>
      <p class="sheet-meta">
        ${flavor.weight_label ? `<span class="sheet-weight">${esc(flavor.weight_label)}</span>` : ""}
        <span class="stock sticker" data-sheet-stock hidden></span>
      </p>
      <p class="sheet-status" data-sheet-status></p>
      ${flavor.long_description ? `<p class="sheet-desc">${esc(flavor.long_description)}</p>` : ""}
      ${notes.length ? `<ul class="taste-chips" aria-label="Taste notes">${notes.map((n) => `<li>${esc(n)}</li>`).join("")}</ul>` : ""}

      ${contains.length ? `<p class="allergen-line allergen-contains"><strong>Contains:</strong> ${esc(contains.join(", "))}</p>` : ""}
      ${mayContain.length ? `<p class="allergen-line"><strong>May contain:</strong> ${esc(mayContain.join(", "))}</p>` : ""}

      ${flavor.ingredients ? `<h3>Ingredients</h3><p class="sheet-ingredients">${esc(flavor.ingredients)}</p>` : ""}

      ${table ? `<h3 id="sheet-nutrition">Nutrition</h3>${table}
        ${settings.nutrition_note ? `<p class="sheet-small">${esc(settings.nutrition_note)}</p>` : ""}` : ""}

      ${facts.length ? `<dl class="sheet-facts">${facts.map(([k, v]) => `<dt>${k}</dt><dd>${esc(v)}</dd>`).join("")}</dl>` : ""}
      ${settings.global_allergen_note ? `<p class="sheet-small sheet-allergen-note">${esc(settings.global_allergen_note)}</p>` : ""}
    </div>`;
}

// ---- The sheet itself ---------------------------------------------------------------------------
// flavors      : the menu's flavors (with the detail columns)
// getRemaining : slug -> cookies left this Sunday, or null if unknown
// getLimit     : slug -> how many MORE can go in the cart (remaining minus what's already there)
// settings     : { global_allergen_note, nutrition_note } from the site_settings table
// add          : (flavor, qty) -> { ok, error }   (adds single cookies to the cart)
export function initFlavorSheet({ flavors, getRemaining, getLimit, settings = {}, add }) {
  const root = document.createElement("div");
  root.className = "sheet-root";
  root.hidden = true;
  root.innerHTML = `
    <div class="sheet-overlay" data-sheet-close></div>
    <section class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-title" tabindex="-1">
      <button type="button" class="sheet-close" data-sheet-close aria-label="Close flavor details">✕</button>
      <div class="sheet-scroll" data-sheet-content></div>
      <div class="sheet-actions" data-sheet-actions></div>
    </section>`;
  document.body.append(root);

  const panel = root.querySelector(".sheet");
  const content = root.querySelector("[data-sheet-content]");
  const actions = root.querySelector("[data-sheet-actions]");

  let current = null;        // the flavor being shown
  let qty = 1;               // the stepper's number
  let opener = null;         // what had focus before, so we can give it back
  let pushed = false;        // did WE add a history entry? (then closing = going back)
  let inerted = [];          // page parts made un-focusable while the sheet is open

  const flavorFromHash = (hash) => {
    const h = decodeURIComponent((hash || "").replace(/^#/, "")).toLowerCase();
    return h ? flavors.find((f) => flavorHash(f) === h || f.slug === h) || null : null;
  };

  // ---- drawing -------------------------------------------------------------------------------
  function paintStatic() {
    content.innerHTML = flavorDetailHtml(current, { settings });
    actions.innerHTML = current.single_price != null
      ? `<div class="stepper">
           <button type="button" data-sheet-step="-1" aria-label="One fewer ${esc(current.name)}">&minus;</button>
           <output aria-live="polite" aria-label="${esc(current.name)} quantity">${qty}</output>
           <button type="button" data-sheet-step="1" aria-label="One more ${esc(current.name)}">+</button>
         </div>
         <button type="button" class="btn" data-sheet-add>Add</button>`
      : `<p class="soon">This flavor is sold in boxes only.</p>
         <a class="btn" href="index.html#boxes" data-sheet-close>See boxes</a>`;
  }

  // Stock status + stepper limits (called on open, and whenever the numbers change)
  function refresh() {
    if (!current) return;
    const left = getRemaining(current.slug);
    const limit = getLimit(current.slug);
    const soldOut = left !== null && left <= 0;

    const badge = content.querySelector("[data-sheet-stock]");
    const label = stockLabel(left);
    badge.textContent = label; badge.hidden = !label;
    badge.classList.toggle("stock-out", soldOut);

    const status = content.querySelector("[data-sheet-status]");
    status.innerHTML = left === null ? ""
      : soldOut ? `<strong>Sold out for this Sunday.</strong> Unpaid orders release after 24 hours, so check back.`
      : left <= 5 ? `Only <strong>${left} left</strong> for this Sunday.`
      : "Available for this Sunday.";
    panel.classList.toggle("is-soldout", soldOut);

    if (qty > Math.max(limit, 1)) qty = Math.max(limit, 1);
    const out = actions.querySelector("output");
    if (!out) return;                                   // box-only flavor: no stepper
    out.textContent = qty;
    actions.querySelector('[data-sheet-step="-1"]').disabled = qty <= 1;
    actions.querySelector('[data-sheet-step="1"]').disabled = qty >= limit;
    const addBtn = actions.querySelector("[data-sheet-add]");
    if (!addBtn.dataset.busy) {                         // (don't overwrite the "Added ✓" flash)
      addBtn.disabled = limit <= 0;
      addBtn.textContent = soldOut ? "Sold out" : limit <= 0 ? "All in your cart" : `Add · ${peso(current.single_price)}`;
    }
  }

  // ---- open / close (the UI part) --------------------------------------------------------------
  function openUI(flavor, section) {
    current = flavor; qty = 1;
    opener = document.activeElement;
    paintStatic(); refresh();
    root.hidden = false;
    void root.offsetWidth;                                // force a layout so the slide-up animation plays
    root.classList.add("open");
    document.body.classList.add("sheet-open");           // stops the page scrolling behind it
    // Everything outside the sheet becomes un-focusable and hidden from screen readers
    inerted = [...document.body.children].filter((el) => el !== root && !el.hasAttribute("inert"));
    inerted.forEach((el) => el.setAttribute("inert", ""));
    content.scrollTop = 0;
    panel.querySelector(".sheet-close").focus();
    // "Nutrition info" link on a row: open scrolled to the table
    const target = section === "nutrition" ? content.querySelector("#sheet-nutrition") : null;
    if (target) content.scrollTop = target.getBoundingClientRect().top - content.getBoundingClientRect().top + content.scrollTop - 12;
  }

  function closeUI() {
    if (!current) return;
    root.classList.remove("open");
    document.body.classList.remove("sheet-open");
    inerted.forEach((el) => el.removeAttribute("inert"));
    inerted = [];
    setTimeout(() => { if (!current) root.hidden = true; }, 260);   // after the slide-down (unless it was reopened meanwhile)
    current = null; pushed = false;
    if (opener && opener.focus) opener.focus();
  }

  // ---- open / close (the history part: hash + back button) ---------------------------------------
  function open(slug, { section } = {}) {
    const flavor = flavors.find((f) => f.slug === slug);
    if (!flavor || current) return;
    history.pushState({ flavorSheet: true }, "", "#" + flavorHash(flavor));
    pushed = true;
    openUI(flavor, section);
  }

  function close() {
    if (!current) return;
    if (pushed) history.back();                           // popstate below does the closing
    else {                                                // no entry of ours to go back to: just tidy the URL
      history.replaceState(null, "", location.pathname + location.search);
      closeUI();
    }
  }

  // Phone back button / browser back & forward
  window.addEventListener("popstate", () => {
    const flavor = flavorFromHash(location.hash);
    if (flavor && !current) { pushed = true; openUI(flavor); }
    else if (!flavor && current) closeUI();
    else if (flavor && current && flavor !== current) { current = flavor; qty = 1; paintStatic(); refresh(); }
  });

  // ---- events ---------------------------------------------------------------------------------
  root.addEventListener("click", (e) => {
    if (e.target.closest("[data-sheet-close]")) return close();
    const step = e.target.closest("[data-sheet-step]");
    if (step) {
      qty = Math.min(Math.max(qty + Number(step.dataset.sheetStep), 1), Math.max(getLimit(current.slug), 1));
      return refresh();
    }
    const addBtn = e.target.closest("[data-sheet-add]");
    if (addBtn && !addBtn.disabled) {
      const result = add(current, qty);
      addBtn.dataset.busy = "1";
      addBtn.textContent = result.ok ? "Added ✓" : result.error;
      qty = 1;
      setTimeout(() => { delete addBtn.dataset.busy; refresh(); }, 1600);
    }
  });

  document.addEventListener("keydown", (e) => {
    if (!current) return;
    if (e.key === "Escape") { e.preventDefault(); return close(); }
    if (e.key === "Tab") {                                // keep focus inside the sheet
      const items = [...panel.querySelectorAll("button:not([disabled]), a[href], select, input")].filter((el) => !el.hidden && el.offsetParent !== null);
      if (!items.length) return e.preventDefault();
      const first = items[0], last = items[items.length - 1];
      if (e.shiftKey && (document.activeElement === first || document.activeElement === panel)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });

  // ---- a link straight to a flavor: /#chimp-chips -------------------------------------------------
  const linked = flavorFromHash(location.hash);
  if (linked) {
    // Rebuild the history as [page, page#flavor] so Back closes the sheet and stays on the page
    history.replaceState(null, "", location.pathname + location.search);
    history.pushState({ flavorSheet: true }, "", "#" + flavorHash(linked));
    pushed = true;
    openUI(linked);
  }

  return { open, close, refresh, isOpen: () => !!current };
}
