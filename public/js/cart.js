// Cart: the boxes and single cookies the customer has chosen, kept in localStorage.
//
// IMPORTANT: prices in here are for DISPLAY ONLY. When the order is placed, the
// database recalculates everything (box prices, single prices, the 2-cookie
// minimum, the cap) from its own data and ignores anything sent from here.
//
// Shape of the saved cart:
//   {
//     boxes:   [{ id, size, boxPrice, price, giftNote, items: [{ slug, name, qty, surcharge }] }],
//     singles: [{ slug, name, qty, unitPrice, surcharge }],      // loose cookies
//     boxMenu: [{ size, price }]                                  // box prices, for the "save in a box" hint
//   }
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
let memory = { boxes: [], singles: [], boxMenu: [] }; // fallback copy, also the latest known state

// Price of one box = flat box price + per-cookie surcharges (e.g. Bueno +30)
export function priceFor(boxPrice, items) {
  return boxPrice + items.reduce((sum, i) => sum + i.surcharge * i.qty, 0);
}

function countCookies(items) {
  return items.reduce((n, i) => n + i.qty, 0);
}

const isNum = (n) => typeof n === "number" && Number.isFinite(n) && n >= 0;

// Keep only well-formed boxes and singles, in case storage held junk or an old format
function clean(data) {
  const boxes = Array.isArray(data && data.boxes) ? data.boxes : [];
  const singles = Array.isArray(data && data.singles) ? data.singles : [];
  const boxMenu = Array.isArray(data && data.boxMenu) ? data.boxMenu : [];
  return {
    boxes: boxes.filter(
      (b) =>
        b && typeof b.id === "string" && Number.isInteger(b.size) &&
        isNum(b.boxPrice) && isNum(b.price) &&
        Array.isArray(b.items) &&
        b.items.every((i) => i && typeof i.slug === "string" && typeof i.name === "string" &&
          Number.isInteger(i.qty) && i.qty > 0 && isNum(i.surcharge)) &&
        countCookies(b.items) === b.size
    ).slice(0, CONFIG.maxBoxesPerOrder),
    singles: singles.filter(
      (s) => s && typeof s.slug === "string" && typeof s.name === "string" &&
        Number.isInteger(s.qty) && s.qty > 0 && isNum(s.unitPrice) && isNum(s.surcharge)
    ),
    boxMenu: boxMenu.filter((m) => m && Number.isInteger(m.size) && isNum(m.price)),
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

// ---- Reading the cart ----------------------------------------------------------------

export function getBoxes() { return read().boxes; }
export function getSingles() { return read().singles; }

export function count() { return getBoxes().length; }           // number of BOXES
export function isFull() { return count() >= CONFIG.maxBoxesPerOrder; }  // 3-box limit

export function boxesTotal() { return getBoxes().reduce((sum, b) => sum + b.price, 0); }
export function singlesTotal() { return getSingles().reduce((sum, s) => sum + s.unitPrice * s.qty, 0); }
export function total() { return boxesTotal() + singlesTotal(); }

export function singlesCookies() { return getSingles().reduce((n, s) => n + s.qty, 0); }
export function cookieCount() { return getBoxes().reduce((n, b) => n + b.size, 0) + singlesCookies(); }
export function isEmpty() { return getBoxes().length === 0 && getSingles().length === 0; }

// The minimum order (display copy: the database enforces the real rule)
export const MIN_COOKIES = CONFIG.minCookiesPerOrder;
export function cookiesShort() { return Math.max(0, MIN_COOKIES - cookieCount()); }
export function meetsMinimum() { return cookieCount() >= MIN_COOKIES; }

// Anything in the cart that the menu no longer offers?
export function hasUnavailable() {
  return getBoxes().some((b) => b.unavailable) || getSingles().some((s) => s.unavailable);
}

// "1 box + 3 cookies", "2 boxes", "3 cookies"
export function summaryText() {
  const boxes = count(), cookies = singlesCookies();
  const parts = [];
  if (boxes) parts.push(boxes === 1 ? "1 box" : `${boxes} boxes`);
  if (cookies) parts.push(cookies === 1 ? "1 cookie" : `${cookies} cookies`);
  return parts.join(" + ") || "Empty";
}

// ---- The "Save ₱X in a box" hint ---------------------------------------------------------
// Looks at the loose singles: if some of those cookies (the priciest ones, since
// that's where a box saves most) would cost less in a box, say how much.
// Returns { saving, size, asSingles, asBox } for the best box size, or null.
export function boxHint() {
  const cart = read();
  const cookies = [];                                   // one entry per single cookie
  for (const s of cart.singles) for (let i = 0; i < s.qty; i++) cookies.push(s);
  cookies.sort((a, b) => b.unitPrice - a.unitPrice);    // priciest first

  let best = null;
  for (const m of cart.boxMenu) {
    if (m.size > cookies.length) continue;              // not enough singles to fill this box
    const chosen = cookies.slice(0, m.size);
    const asSingles = chosen.reduce((sum, c) => sum + c.unitPrice, 0);
    const asBox = m.price + chosen.reduce((sum, c) => sum + c.surcharge, 0);
    const saving = asSingles - asBox;
    if (saving > 0 && (!best || saving > best.saving)) best = { saving, size: m.size, asSingles, asBox };
  }
  return best;
}

// ---- Changing the cart ----------------------------------------------------------------------

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
  if (cookieCount() + size > CONFIG.capPerSunday) {
    return { ok: false, error: `An order can have at most ${CONFIG.capPerSunday} cookies.` };
  }
  const box = {
    id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    size,
    boxPrice,
    price: priceFor(boxPrice, picked),
    giftNote: giftNote.trim().slice(0, 500),
    items: picked.map(({ slug, name, qty, surcharge }) => ({ slug, name, qty, surcharge })),
  };
  write({ ...cart, boxes: [...cart.boxes, box] });
  return { ok: true, box };
}

export function remove(boxId) {
  const cart = read();
  write({ ...cart, boxes: cart.boxes.filter((b) => b.id !== boxId) });
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

// Add loose single cookies. flavor = { slug, name, single_price, surcharge } from the menu.
// Adding the same flavor again just raises its quantity.
export function addSingle(flavor, qty = 1) {
  const cart = read();
  if (!Number.isInteger(qty) || qty < 1) return { ok: false, error: "Pick at least 1 cookie." };
  if (flavor.single_price == null) return { ok: false, error: `${flavor.name} is only sold in boxes.` };
  if (cookieCount() + qty > CONFIG.capPerSunday) {
    return { ok: false, error: `An order can have at most ${CONFIG.capPerSunday} cookies.` };
  }
  const line = cart.singles.find((s) => s.slug === flavor.slug);
  if (line) {
    line.qty += qty;
    line.unitPrice = flavor.single_price;      // keep the display price current
  } else {
    cart.singles.push({ slug: flavor.slug, name: flavor.name, qty, unitPrice: flavor.single_price, surcharge: flavor.surcharge });
  }
  write(cart);
  return { ok: true };
}

// Set a single line's quantity (0 removes it). Returns false if it would go over the cookie limit.
export function setSingleQty(slug, qty) {
  const cart = read();
  const line = cart.singles.find((s) => s.slug === slug);
  if (!line || !Number.isInteger(qty) || qty < 0) return false;
  if (qty > line.qty && cookieCount() + (qty - line.qty) > CONFIG.capPerSunday) return false;
  if (qty === 0) cart.singles = cart.singles.filter((s) => s.slug !== slug);
  else line.qty = qty;
  write(cart);
  return true;
}

export function removeSingle(slug) { setSingleQty(slug, 0); }

export function clear() {
  write({ boxes: [], singles: [], boxMenu: read().boxMenu });
}

// Compare the cart with today's menu from the database (names, prices, flavors
// that were removed). Call it whenever a page has just loaded the menu.
// Prices are still display-only; this just keeps what the customer SEES honest.
// Boxes or single lines containing a flavor (or box size) that is no longer
// offered get an `unavailable` flag, which checkout uses to block ordering
// until they're removed.
export function syncWithMenu({ flavors, boxes }) {
  const cart = read();
  let changed = false;

  // Remember the box prices for the "save in a box" hint
  const boxMenu = boxes.map((b) => ({ size: b.size, price: b.price }));
  if (JSON.stringify(boxMenu) !== JSON.stringify(cart.boxMenu)) { cart.boxMenu = boxMenu; changed = true; }

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

  for (const s of cart.singles) {
    const f = flavors.find((x) => x.slug === s.slug);
    const sellable = !!f && f.single_price != null;
    if (sellable) {
      if (s.name !== f.name || s.unitPrice !== f.single_price || s.surcharge !== f.surcharge) {
        s.name = f.name; s.unitPrice = f.single_price; s.surcharge = f.surcharge; changed = true;
      }
    }
    if (!!s.unavailable !== !sellable) { s.unavailable = !sellable || undefined; changed = true; }
  }

  if (changed) write(cart);
  return {
    changed,
    unavailable: [
      ...cart.boxes.filter((b) => b.unavailable).map((b) => b.id),
      ...cart.singles.filter((s) => s.unavailable).map((s) => s.slug),
    ],
  };
}
