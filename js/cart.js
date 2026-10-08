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
  } catch (e) {
    // storage blocked or full: in-memory copy still works
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
