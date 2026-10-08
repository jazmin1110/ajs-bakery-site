// Cart UI shared by every page: the header badge, the sticky bottom bar, and
// the slide-in drawer. Call initCartUI() once per page. Totals are display only.
import * as cart from "./cart.js";
import { CONFIG } from "./config.js";
import { peso, esc } from "./ui.js";

let bar, drawer, overlay, closeBtn, lastFocus;

// "2 × Chimp Chips, 2 × Bueno Mucho" (one per line)
const breakdown = (box) => box.items.map((i) => `${i.qty} × ${esc(i.name)}`).join("<br>");

// "Save ₱40 in a box" hint (or "" if singles wouldn't be cheaper as a box)
export function hintHtml() {
  const h = cart.boxHint();
  if (!h) return "";
  return `<p class="hint-save">💡 <strong>Save ${peso(h.saving)} in a box.</strong>
    ${h.size} of your cookies cost ${peso(h.asSingles)} as singles, but a box of ${h.size} is ${peso(h.asBox)}.
    <a href="index.html#boxes">See boxes</a></p>`;
}

// "Minimum order is 2 cookies. Add 1 more to check out." (or "" if the minimum is met)
export function minimumHtml() {
  const short = cart.cookiesShort();
  if (cart.isEmpty() || short === 0) return "";
  return `<p class="min-msg" role="alert">Minimum order is ${cart.MIN_COOKIES} cookies. Add ${short} more to check out.</p>`;
}

function build(showBar) {
  // Sticky bar (hidden until the cart has items)
  bar = document.createElement("div");
  bar.className = "cart-bar";
  bar.hidden = true;
  if (!showBar) bar.dataset.off = "1";
  bar.innerHTML = `
    <button type="button" class="cart-bar-summary" data-open-cart></button>
    <a class="btn cart-bar-checkout" href="checkout.html">Checkout</a>`;

  // Dim background behind the drawer
  overlay = document.createElement("div");
  overlay.className = "drawer-overlay";

  // The drawer itself
  drawer = document.createElement("aside");
  drawer.className = "drawer";
  drawer.setAttribute("role", "dialog");
  drawer.setAttribute("aria-modal", "true");
  drawer.setAttribute("aria-label", "Your cart");
  drawer.innerHTML = `
    <header class="drawer-head">
      <h2>Your cart</h2>
      <button type="button" class="drawer-close" aria-label="Close cart">✕</button>
    </header>
    <div class="drawer-body"></div>
    <footer class="drawer-foot"></footer>`;

  document.body.append(bar, overlay, drawer);
  closeBtn = drawer.querySelector(".drawer-close");

  // Open from the sticky bar or any header cart button
  document.addEventListener("click", (e) => {
    if (e.target.closest("[data-open-cart]")) openCart();
  });
  overlay.addEventListener("click", closeCart);
  closeBtn.addEventListener("click", closeCart);

  // Buttons inside the drawer (event delegation: they're re-drawn on every change)
  drawer.addEventListener("click", (e) => {
    const rm = e.target.closest("[data-remove-box]");
    if (rm) return cart.remove(rm.dataset.removeBox);
    const rs = e.target.closest("[data-remove-single]");
    if (rs) return cart.removeSingle(rs.dataset.removeSingle);
    const step = e.target.closest("[data-single-step]");
    if (step) {
      const line = cart.getSingles().find((s) => s.slug === step.dataset.slug);
      if (line) cart.setSingleQty(line.slug, line.qty + Number(step.dataset.singleStep));
    }
  });

  document.addEventListener("keydown", (e) => {
    if (!drawer.classList.contains("open")) return;
    if (e.key === "Escape") return closeCart();
    if (e.key === "Tab") {
      // Keep keyboard focus inside the drawer while it's open
      const f = [...drawer.querySelectorAll("button:not([disabled]), a[href]")].filter((el) => !el.hidden);
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
}

function boxesSection(boxes) {
  return `
    <section class="cart-section" aria-label="Boxes">
      <h3 class="cart-section-title">Boxes</h3>
      ${boxes.map((b, idx) => `
      <article class="cart-box">
        <div class="cart-box-head">
          <strong>Box ${idx + 1}: box of ${b.size}</strong>
          <span class="price">${peso(b.price)}</span>
        </div>
        <p class="cart-box-items">${breakdown(b)}</p>
        ${b.giftNote ? `<p class="cart-box-note">🎁 ${esc(b.giftNote)}</p>` : ""}
        ${b.unavailable ? `<p class="cart-box-warn">⚠ ${esc(b.unavailable.join(", "))} isn't available anymore. Please remove this box.</p>` : ""}
        <button type="button" class="link-btn" data-remove-box="${esc(b.id)}">Remove</button>
      </article>`).join("")}
      <div class="subtotal"><span>Boxes subtotal</span><span>${peso(cart.boxesTotal())}</span></div>
    </section>`;
}

function singlesSection(singles) {
  return `
    <section class="cart-section" aria-label="Single cookies">
      <h3 class="cart-section-title">Single cookies</h3>
      ${singles.map((s) => `
      <article class="cart-box">
        <div class="cart-box-head">
          <strong>${esc(s.name)}</strong>
          <span class="price">${peso(s.unitPrice * s.qty)}</span>
        </div>
        <div class="cart-line-controls">
          <div class="stepper">
            <button type="button" data-single-step="-1" data-slug="${esc(s.slug)}" aria-label="One fewer ${esc(s.name)}">&minus;</button>
            <output aria-label="${esc(s.name)} quantity">${s.qty}</output>
            <button type="button" data-single-step="1" data-slug="${esc(s.slug)}" aria-label="One more ${esc(s.name)}">+</button>
          </div>
          <span class="cart-line-each">${s.qty} × ${peso(s.unitPrice)}</span>
          <button type="button" class="link-btn" data-remove-single="${esc(s.slug)}">Remove</button>
        </div>
        ${s.unavailable ? `<p class="cart-box-warn">⚠ ${esc(s.name)} isn't available as a single anymore. Please remove it.</p>` : ""}
      </article>`).join("")}
      <div class="subtotal"><span>Singles subtotal</span><span>${peso(cart.singlesTotal())}</span></div>
    </section>`;
}

function render() {
  const boxes = cart.getBoxes();
  const singles = cart.getSingles();
  const cookies = cart.cookieCount();
  const empty = cart.isEmpty();
  const canCheckout = !empty && cart.meetsMinimum() && !cart.hasUnavailable();

  // Header badge (if the page has one): total cookies in the cart
  const badge = document.getElementById("cart-count");
  if (badge) badge.textContent = cookies;

  // Sticky bar: "1 box + 3 cookies · ₱695" and Checkout (or what's missing)
  const barOn = !empty && !bar.dataset.off;      // checkout page turns the bar off
  bar.hidden = !barOn;
  document.body.classList.toggle("has-cart-bar", barOn);
  bar.querySelector(".cart-bar-summary").textContent = `${cart.summaryText()} · ${peso(cart.total())}`;
  const go = bar.querySelector(".cart-bar-checkout");
  if (canCheckout) {
    go.setAttribute("href", "checkout.html"); go.removeAttribute("aria-disabled"); go.classList.remove("is-disabled");
    go.textContent = "Checkout";
  } else {
    // can't check out yet: show why, and make the button inert
    go.removeAttribute("href"); go.setAttribute("aria-disabled", "true"); go.classList.add("is-disabled");
    go.textContent = cart.meetsMinimum() ? "Fix cart" : `Add ${cart.cookiesShort()} more`;
  }

  // Remember which stepper button had focus, so repeated taps on + or − keep working
  const active = document.activeElement;
  const focusKey = active && drawer.contains(active) && active.dataset.singleStep
    ? `[data-single-step="${active.dataset.singleStep}"][data-slug="${active.dataset.slug}"]` : null;

  // Drawer body: boxes and singles as separate sections, each with a subtotal
  const body = drawer.querySelector(".drawer-body");
  body.innerHTML = empty
    ? `<p class="drawer-empty">Your cart is empty. Pick a box or a few single cookies to get started!</p>`
    : (boxes.length ? boxesSection(boxes) : "") + (singles.length ? singlesSection(singles) : "") + hintHtml();

  // Drawer footer: minimum message, total, add-more links, checkout
  const foot = drawer.querySelector(".drawer-foot");
  if (empty) {
    foot.innerHTML = `<a class="btn btn-block" href="index.html#menu">Browse the menu</a>`;
  } else {
    foot.innerHTML = `
      ${minimumHtml()}
      <div class="drawer-total"><span>Total</span><span class="price">${peso(cart.total())}</span></div>
      <a class="drawer-add" href="index.html#menu">+ Add single cookies</a>
      ${cart.isFull()
        ? `<p class="drawer-limit">That's the max of ${CONFIG.maxBoxesPerOrder} boxes per order.</p>`
        : `<a class="drawer-add" href="index.html#boxes">+ Add another box</a>`}
      ${canCheckout
        ? `<a class="btn btn-block" href="checkout.html">Checkout</a>`
        : `<button type="button" class="btn btn-block" disabled>Checkout</button>`}
      <small class="drawer-fine">Final price is confirmed when you place your order.</small>`;
  }

  // If the button the user just pressed was re-drawn, put focus back on it (or inside the drawer)
  if (focusKey) { const again = drawer.querySelector(focusKey); if (again) again.focus(); }
  if (drawer.classList.contains("open") && !drawer.contains(document.activeElement)) closeBtn.focus();
}

export function openCart() {
  lastFocus = document.activeElement;
  drawer.classList.add("open");
  overlay.classList.add("open");
  document.body.style.overflow = "hidden"; // stop the page scrolling behind it
  closeBtn.focus();
}

export function closeCart() {
  drawer.classList.remove("open");
  overlay.classList.remove("open");
  document.body.style.overflow = "";
  if (lastFocus && lastFocus.focus) lastFocus.focus();
}

// showBar: false on the checkout page (the bar's Checkout button would point at itself)
export function initCartUI({ showBar = true } = {}) {
  build(showBar);
  render();
  window.addEventListener("cart:changed", render); // this tab
  window.addEventListener("storage", render);      // other tabs
}
