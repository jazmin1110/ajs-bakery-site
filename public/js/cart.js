// Cart: boxes the customer has built, kept in localStorage.
//
// IMPORTANT: prices in here are for DISPLAY ONLY. When the order is placed,
// the database recalculates the total from its own prices and ignores these.
//
// Shape of a cart box:
//   { id, size, boxPrice, price, giftNote,
//     items: [{ slug, name, qty, surcharge }] }
//
// localStorage can throw (private mode, blocked site data, full), so every
// call is wrapped in try/catch. If it fails, the cart still works in memory
// for the current page, it just won't survive navigation.
import { CONFIG } from "./config.js";

const KEY = "ajs-cart-v1";
// If localStorage is blocked (some private modes), the cart is parked in window.name
// instead. window.name survives moving between pages in the SAME tab, so the cart
// still reaches checkout. (It is cleared when you navigate to another website.)
const NAME_PREFIX = "ajs-cart:";
let memory = { boxes: [] }; // fallback copy, also the latest known state

// Price of one box = flat box price + per-cookie surcharges (e.g. Bueno +30)
export function priceFor(boxPrice, items) {
  return boxPrice + items.reduce((sum, i) => sum + i.surcharge * i.qty, 0);
}

function countCookies(items) {
  return items.reduce((n, i) => n + i.qty, 0);
}

// Keep only well-formed boxes, in case storage held junk or an old format
function clean(data) {
  const boxes = Array.isArray(data && data.boxes) ? data.boxes : [];
  return {
    boxes: boxes.filter(
      (b) =>
        b && typeof b.id === "string" && Number.isInteger(b.size) &&
        typeof b.boxPrice === "number" && typeof b.price === "number" &&
        Array.isArray(b.items) &&
        b.items.every((i) => i && typeof i.slug === "string" && typeof i.name === "string" &&
          Number.isInteger(i.qty) && i.qty > 0 && typeof i.surcharge === "number") &&
        countCookies(b.items) === b.size
    ).slice(0, CONFIG.maxBoxesPerOrder),
  };
}

// Read fresh each time so a second tab's changes show up
function read() {
  try {
    // Set only when the last save couldn't use localStorage, so it's the newest copy
    if (window.name.startsWith(NAME_PREFIX)) {
      memory = clean(JSON.parse(window.name.slice(NAME_PREFIX.length)));
      return memory;
    }
  } catch (e) { /* corrupt: fall through to storage */ }
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) memory = clean(JSON.parse(raw));
  } catch (e) {
    // storage blocked or corrupt JSON: keep using the in-memory copy
  }
  return memory;
}

function write(cart) {
  memory = cart;
  try {
    localStorage.setItem(KEY, JSON.stringify(cart));
    if (window.name.startsWith(NAME_PREFIX)) window.name = ""; // storage works again: it's the source of truth
  } catch (e) {
    // storage blocked or full: keep the cart in window.name so other pages in this tab can see it
    try { window.name = NAME_PREFIX + JSON.stringify(cart); } catch (e2) { /* in-memory copy still works */ }
  }
  window.dispatchEvent(new Event("cart:changed")); // UI listens for this
}

export function getBoxes() {
  return read().boxes;
}

export function count() {
  return getBoxes().length;
}

export function total() {
  return getBoxes().reduce((sum, b) => sum + b.price, 0);
}

export function isFull() {
  return count() >= CONFIG.maxBoxesPerOrder;
}

// Add a finished box. Returns { ok: true, box } or { ok: false, error }.
export function add({ size, boxPrice, items, giftNote = "" }) {
  const cart = read();
  if (cart.boxes.length >= CONFIG.maxBoxesPerOrder) {
    return { ok: false, error: `You can order up to ${CONFIG.maxBoxesPerOrder} boxes at a time.` };
  }
  const picked = items.filter((i) => i.qty > 0);
  if (countCookies(picked) !== size) {
    return { ok: false, error: `A box of ${size} needs exactly ${size} cookies.` };
  }
  const box = {
    id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    size,
    boxPrice,
    price: priceFor(boxPrice, picked),
    giftNote: giftNote.trim().slice(0, 500),
    items: picked.map(({ slug, name, qty, surcharge }) => ({ slug, name, qty, surcharge })),
  };
  write({ boxes: [...cart.boxes, box] });
  return { ok: true, box };
}

export function remove(boxId) {
  write({ boxes: read().boxes.filter((b) => b.id !== boxId) });
}

// Change the flavor quantities of a box already in the cart.
// The new quantities must still add up to exactly the box size; returns false if not.
export function changeQuantity(boxId, newItems) {
  const cart = read();
  const box = cart.boxes.find((b) => b.id === boxId);
  const picked = newItems.filter((i) => i.qty > 0);
  if (!box || countCookies(picked) !== box.size) return false;
  box.items = picked.map(({ slug, name, qty, surcharge }) => ({ slug, name, qty, surcharge }));
  box.price = priceFor(box.boxPrice, box.items);
  write(cart);
  return true;
}

export function clear() {
  write({ boxes: [] });
}

// Compare the cart with today's menu from the database (names, prices, flavors
// that were removed). Call it whenever a page has just loaded the menu.
// Prices are still display-only; this just keeps what the customer SEES honest.
// Boxes containing a flavor (or box size) that no longer exists get an
// `unavailable` list, which checkout uses to block ordering until they're removed.
export function syncWithMenu({ flavors, boxes }) {
  const cart = read();
  let changed = false;

  for (const b of cart.boxes) {
    const menuBox = boxes.find((x) => x.size === b.size);
    const gone = menuBox ? [] : [`box of ${b.size}`];
    for (const i of b.items) {
      const f = flavors.find((x) => x.slug === i.slug);
      if (!f) { gone.push(i.name); continue; }
      if (i.name !== f.name || i.surcharge !== f.surcharge) { i.name = f.name; i.surcharge = f.surcharge; changed = true; }
    }
    if (menuBox && b.boxPrice !== menuBox.price) { b.boxPrice = menuBox.price; changed = true; }

    const price = priceFor(b.boxPrice, b.items);
    if (price !== b.price) { b.price = price; changed = true; }

    const flag = gone.length ? gone : undefined;
    if (JSON.stringify(b.unavailable) !== JSON.stringify(flag)) { b.unavailable = flag; changed = true; }
  }

  if (changed) write(cart);
  return { changed, unavailable: cart.boxes.filter((b) => b.unavailable).map((b) => b.id) };
}
