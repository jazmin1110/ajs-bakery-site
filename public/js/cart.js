// Cart: the boxes and single cookies the customer has chosen, kept in localStorage.
//
// IMPORTANT: prices in here are for DISPLAY ONLY. When the order is placed, the
// database recalculates everything (box prices, single prices, the 2-cookie
// minimum, each flavor's weekly cap) from its own data and ignores anything
// sent from here.
//
// Shape of the saved cart:
//   {
//     savedAt: 1760000000000,                // when the cart was last changed (ms). Older than 48h = thrown away
//     sunday:  "2026-10-18",                 // the ordering Sunday the customer last saw (to warn if it changes)
//     boxes:   [{ id, size, boxPrice, price, giftNote, items: [{ slug, name, qty, surcharge }] }],
//     singles: [{ slug, name, qty, unitPrice, surcharge }],      // loose cookies
//     boxMenu: [{ size, price }]                                  // box prices, for the "save in a box" hint
//   }
//
// localStorage can throw (private mode, blocked site data, full), so every call
// is wrapped in try/catch. If it's blocked, the cart is parked in window.name so
// it still reaches checkout, and failing that it lives in memory for the page.
import { CONFIG } from "./config.js";

const KEY = "ajs-cart-v1";
const MAX_AGE_MS = 48 * 60 * 60 * 1000;   // carts older than 48 hours are discarded
// If localStorage is blocked (some private modes), the cart is parked in window.name
// instead. window.name survives moving between pages in the SAME tab, so the cart
// still reaches checkout. (It is cleared when you navigate to another website.)
const NAME_PREFIX = "ajs-cart:";
const emptyCart = () => ({ savedAt: Date.now(), sunday: undefined, boxes: [], singles: [], boxMenu: [] });
let memory = emptyCart(); // fallback copy, also the latest known state

// Small messages for the customer ("we cleared your old cart", "a price changed").
// Pages show them via cart-ui.js, which listens for the "cart:notice" event.
let pendingNotices = [];
function notify(messages) {
  const list = [].concat(messages).filter(Boolean);
  if (!list.length) return;
  pendingNotices.push(...list);
  setTimeout(() => window.dispatchEvent(new Event("cart:notice")), 0);  // after the current call finishes
}
export function takeNotices() {
  const out = pendingNotices;
  pendingNotices = [];
  return out;
}

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
    savedAt: isNum(data && data.savedAt) ? data.savedAt : undefined,
    sunday: typeof (data && data.sunday) === "string" ? data.sunday : undefined,
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

// Save to storage WITHOUT announcing a change (used for housekeeping)
function persist(cart) {
  memory = cart;
  try {
    localStorage.setItem(KEY, JSON.stringify(cart));
    if (window.name.startsWith(NAME_PREFIX)) window.name = ""; // storage works again: it's the source of truth
  } catch (e) {
    // storage blocked or full: keep the cart in window.name so other pages in this tab can see it
    try { window.name = NAME_PREFIX + JSON.stringify(cart); } catch (e2) { /* in-memory copy still works */ }
  }
}

// Every real change goes through here: stamps the time, saves, tells the page
function write(cart) {
  cart.savedAt = Date.now();
  persist(cart);
  window.dispatchEvent(new Event("cart:changed")); // UI listens for this
}

// Look at a freshly loaded cart: too old? missing a timestamp? clock weirdness?
function checkAge(cart) {
  const hasItems = cart.boxes.length > 0 || cart.singles.length > 0;
  const now = Date.now();
  if (!hasItems) return cart;
  if (cart.savedAt === undefined || cart.savedAt > now + 5 * 60 * 1000) {
    // No timestamp (a cart from before this feature) or one from the future (clock was changed):
    // start the 48 hours from now rather than guessing
    cart.savedAt = now;
    persist(cart);
    return cart;
  }
  if (now - cart.savedAt > MAX_AGE_MS) {
    // Too old: prices and availability have probably moved on. Start fresh.
    const fresh = emptyCart();
    fresh.boxMenu = cart.boxMenu;
    persist(fresh);
    notify("Your saved cart was more than 2 days old, so we cleared it. Prices and flavors may have changed.");
    return fresh;
  }
  return cart;
}

// Read fresh each time so a second tab's changes show up
function read() {
  try {
    // Set only when the last save couldn't use localStorage, so it's the newest copy
    if (window.name.startsWith(NAME_PREFIX)) {
      memory = checkAge(clean(JSON.parse(window.name.slice(NAME_PREFIX.length))));
      return memory;
    }
  } catch (e) { /* corrupt: fall through to storage */ }
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) memory = checkAge(clean(JSON.parse(raw)));
  } catch (e) {
    // storage blocked or corrupt JSON: keep using the in-memory copy
  }
  return memory;
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

// How many cookies of one flavor are in the cart (inside boxes AND as singles)
export function flavorQty(slug) {
  let n = 0;
  for (const b of getBoxes()) for (const i of b.items) if (i.slug === slug) n += i.qty;
  for (const s of getSingles()) if (s.slug === slug) n += s.qty;
  return n;
}

// Every flavor in the cart with its total quantity: { slug: { name, qty } }
export function flavorTotals() {
  const out = {};
  const add = (slug, name, qty) => { out[slug] ??= { name, qty: 0 }; out[slug].qty += qty; };
  for (const b of getBoxes()) for (const i of b.items) add(i.slug, i.name, i.qty);
  for (const s of getSingles()) add(s.slug, s.name, s.qty);
  return out;
}

// Order minimums (display copy: the database enforces the real rules):
//   pickup   = at least 1 cookie
//   delivery = at least 2 cookies OR at least ₱200 (either one is enough)
export const MIN_PICKUP_COOKIES = CONFIG.minPickupCookies;
export const MIN_DELIVERY_COOKIES = CONFIG.minDeliveryCookies;
export const MIN_DELIVERY_TOTAL = CONFIG.minDeliveryTotal;
export function cookiesShort() { return Math.max(0, MIN_PICKUP_COOKIES - cookieCount()); }
export function meetsMinimum() { return cookieCount() >= MIN_PICKUP_COOKIES; }   // the pickup minimum

// What the cart is missing for DELIVERY, or null if it already qualifies.
// { moreCookies, morePeso }: adding either amount (cookies OR pesos) would be enough.
export function deliveryShortfall() {
  const cookies = cookieCount(), pesos = total();
  if (cookies >= MIN_DELIVERY_COOKIES || pesos >= MIN_DELIVERY_TOTAL) return null;
  return { moreCookies: MIN_DELIVERY_COOKIES - cookies, morePeso: MIN_DELIVERY_TOTAL - pesos };
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

// ---- The Sunday the customer last saw ------------------------------------------------------------
// The ordering Sunday can move (the Wednesday cutoff passes, or every flavor sells out).
// We remember the date the cart was built for, and checkout warns if it's different now.

// Pages call this with the current ordering Sunday. It only records the date while
// the cart is EMPTY, so a cart that already has things in it keeps the date it was built for.
export function rememberSunday(date) {
  const cart = read();
  if (isEmpty() && cart.sunday !== date) { cart.sunday = date; persist(cart); }
  else if (!isEmpty() && !cart.sunday) { cart.sunday = date; persist(cart); }   // an older cart with no date yet
}

// If the cart was built for a different Sunday than `currentDate`, returns the old date
// (a "YYYY-MM-DD" string). Otherwise null.
export function sundayChangedFrom(currentDate) {
  const cart = read();
  return !isEmpty() && cart.sunday && cart.sunday !== currentDate ? cart.sunday : null;
}

// The customer has been told about the new date; remember it so we don't warn again
export function acknowledgeSunday(date) {
  const cart = read();
  if (cart.sunday !== date) { cart.sunday = date; persist(cart); }
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
  if (cookieCount() + size > CONFIG.maxCookiesInCart) {
    return { ok: false, error: "That's a lot of cookies for one order! Please check out first, then order again." };
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
  if (cookieCount() + qty > CONFIG.maxCookiesInCart) {
    return { ok: false, error: "That's a lot of cookies for one order! Please check out first, then order again." };
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
  if (qty > line.qty && cookieCount() + (qty - line.qty) > CONFIG.maxCookiesInCart) return false;
  if (qty === 0) cart.singles = cart.singles.filter((s) => s.slug !== slug);
  else line.qty = qty;
  write(cart);
  return true;
}

export function removeSingle(slug) { setSingleQty(slug, 0); }

// Swap every cookie of one flavor in the cart for another flavor ("sold out, pick something else").
// Singles move to the new flavor's line (at its single price); inside boxes the flavor is replaced
// (so box totals change if the surcharge differs). `to` = { slug, name, single_price, surcharge }.
// Returns how many cookies were moved (0 = nothing to swap, or the new flavor can't be a single).
export function swapFlavor(fromSlug, to) {
  if (fromSlug === to.slug) return 0;
  const cart = read();
  let moved = 0;

  const single = cart.singles.find((s) => s.slug === fromSlug);
  if (single && to.single_price != null) {
    moved += single.qty;
    cart.singles = cart.singles.filter((s) => s.slug !== fromSlug);
    const target = cart.singles.find((s) => s.slug === to.slug);
    if (target) target.qty += single.qty;
    else cart.singles.push({ slug: to.slug, name: to.name, qty: single.qty, unitPrice: to.single_price, surcharge: to.surcharge });
  }

  for (const b of cart.boxes) {
    const item = b.items.find((i) => i.slug === fromSlug);
    if (!item) continue;
    moved += item.qty;
    b.items = b.items.filter((i) => i.slug !== fromSlug);
    const target = b.items.find((i) => i.slug === to.slug);
    if (target) target.qty += item.qty;
    else b.items.push({ slug: to.slug, name: to.name, qty: item.qty, surcharge: to.surcharge });
    b.price = priceFor(b.boxPrice, b.items);
  }

  if (moved) write(cart);
  return moved;
}

// Empty the whole cart (the "Clear cart" button, and after an order is placed)
export function clear() {
  const cart = read();
  write({ ...emptyCart(), boxMenu: cart.boxMenu });
}

// Check the saved cart against today's menu from the database. Call it whenever a page
// has just loaded the menu:
//   * a box or single whose flavor (or box size) is no longer sold is REMOVED
//   * names and prices are refreshed to today's
//   * if anything changed, the customer gets a small notice saying what
// Prices are still display-only (the database prices the real order); this just keeps
// what the customer SEES honest. Returns { changed, notices }.
export function syncWithMenu({ flavors, boxes }) {
  const cart = read();
  const notices = [];
  let changed = false;

  // Remember the box prices for the "save in a box" hint (not worth a notice)
  const boxMenu = boxes.map((b) => ({ size: b.size, price: b.price }));
  const menuChanged = JSON.stringify(boxMenu) !== JSON.stringify(cart.boxMenu);
  cart.boxMenu = boxMenu;

  const peso = (n) => "₱" + n.toLocaleString("en-PH");
  const removed = [];

  const retired = [];                                // box sizes that are no longer sold (e.g. the old box of 4)
  cart.boxes = cart.boxes.filter((b, idx) => {
    const menuBox = boxes.find((x) => x.size === b.size);
    if (!menuBox) {
      // A size we stopped selling: say so, and point at the closest size that is on sale
      if (!retired.includes(b.size)) retired.push(b.size);
      return false;
    }
    const gone = [];
    for (const i of b.items) if (!flavors.some((f) => f.slug === i.slug)) gone.push(i.name);
    if (gone.length) { removed.push(`Box ${idx + 1} (${gone.join(", ")})`); return false; }

    // still sellable: refresh names and prices
    for (const i of b.items) {
      const f = flavors.find((x) => x.slug === i.slug);
      i.name = f.name; i.surcharge = f.surcharge;
    }
    b.boxPrice = menuBox.price;
    const price = priceFor(b.boxPrice, b.items);
    if (price !== b.price) { notices.push(`Box of ${b.size} (box ${idx + 1}) is now ${peso(price)} (was ${peso(b.price)}).`); b.price = price; }
    return true;
  });

  cart.singles = cart.singles.filter((s) => {
    const f = flavors.find((x) => x.slug === s.slug);
    if (!f || f.single_price == null) { removed.push(`${s.name} (single cookies)`); return false; }
    s.name = f.name; s.surcharge = f.surcharge;
    if (s.unitPrice !== f.single_price) {
      notices.push(`${f.name} singles are now ${peso(f.single_price)} each (was ${peso(s.unitPrice)}).`);
      s.unitPrice = f.single_price;
    }
    return true;
  });

  // One short line per retired size: "Box of 4 is retired, pick a Box of 3 instead."
  retired.forEach((size) => {
    const near = boxes.length ? boxes.reduce((a, b) => (Math.abs(b.size - size) < Math.abs(a.size - size) ? b : a)).size : null;
    notices.unshift(`Box of ${size} is retired${near ? `, pick a Box of ${near} instead` : ""}.`);
  });
  changed = changed || retired.length > 0;
  if (removed.length) notices.unshift(`Removed from your cart because they're no longer available: ${removed.join("; ")}.`);
  changed = changed || removed.length > 0 || notices.length > 0;

  if (changed) write(cart);               // saves + refreshes the drawer, bar and badge
  else if (menuChanged) persist(cart);    // quiet housekeeping
  if (notices.length) notify(notices);
  return { changed, notices };
}
