// Cart UI shared by every page: the header badge, the sticky bottom bar, and
// the slide-in drawer. Call initCartUI() once per page. Totals are display only.
import * as cart from "./cart.js";
import { CONFIG } from "./config.js";
import { peso, esc } from "./ui.js";

let bar, drawer, overlay, closeBtn, lastFocus;

const boxesWord = (n) => (n === 1 ? "1 box" : `${n} boxes`);

// "2 × Brown Butter Choc Chip, 2 × Brown Butter Kinder Bueno"
const breakdown = (box) => box.items.map((i) => `${i.qty} × ${esc(i.name)}`).join("<br>");

function build() {
  // Sticky bar (hidden until the cart has items)
  bar = document.createElement("div");
  bar.className = "cart-bar";
  bar.hidden = true;
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

  // Remove button inside the drawer (event delegation: buttons are re-drawn)
  drawer.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-remove-box]");
    if (btn) cart.remove(btn.dataset.removeBox);
  });

  document.addEventListener("keydown", (e) => {
    if (!drawer.classList.contains("open")) return;
    if (e.key === "Escape") return closeCart();
    if (e.key === "Tab") {
      // Keep keyboard focus inside the drawer while it's open
      const f = [...drawer.querySelectorAll("button, a[href]")].filter((el) => !el.hidden);
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
}

function render() {
  const boxes = cart.getBoxes();
  const n = boxes.length;

  // Header badge (if the page has one)
  const badge = document.getElementById("cart-count");
  if (badge) badge.textContent = n;

  // Sticky bar
  bar.hidden = n === 0;
  document.body.classList.toggle("has-cart-bar", n > 0);
  bar.querySelector(".cart-bar-summary").textContent = `${boxesWord(n)} · ${peso(cart.total())}`;

  // Drawer body
  const body = drawer.querySelector(".drawer-body");
  body.innerHTML = n === 0
    ? `<p class="drawer-empty">Your cart is empty. Pick a box to get started!</p>`
    : boxes.map((b, idx) => `
      <article class="cart-box">
        <div class="cart-box-head">
          <strong>Box ${idx + 1}: box of ${b.size}</strong>
          <span class="price">${peso(b.price)}</span>
        </div>
        <p class="cart-box-items">${breakdown(b)}</p>
        ${b.giftNote ? `<p class="cart-box-note">🎁 ${esc(b.giftNote)}</p>` : ""}
        <button type="button" class="link-btn" data-remove-box="${esc(b.id)}">Remove</button>
      </article>`).join("");

  // Drawer footer: total, add-another link (or the limit note), checkout
  const foot = drawer.querySelector(".drawer-foot");
  if (n === 0) {
    foot.innerHTML = `<a class="btn btn-block" href="index.html#boxes">Browse boxes</a>`;
  } else {
    foot.innerHTML = `
      <div class="drawer-total"><span>Total</span><span class="price">${peso(cart.total())}</span></div>
      ${cart.isFull()
        ? `<p class="drawer-limit">That's the max of ${CONFIG.maxBoxesPerOrder} boxes per order.</p>`
        : `<a class="drawer-add" href="index.html#boxes">+ Add another box</a>`}
      <a class="btn btn-block" href="checkout.html">Checkout</a>
      <small class="drawer-fine">Final price is confirmed when you place your order.</small>`;
  }

  // If the button the user just pressed (Remove) was re-drawn, keep focus in the drawer
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

export function initCartUI() {
  build();
  render();
  window.addEventListener("cart:changed", render); // this tab
  window.addEventListener("storage", render);      // other tabs
}
