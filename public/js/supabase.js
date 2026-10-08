// Supabase client + the few database reads the storefront needs.
// Anon key ONLY. The database decides what this key is allowed to see (RLS).
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { CONFIG } from "./config.js";

let client = null;

// Give up on a request after 10 seconds, so a dead connection shows the
// "Ordering is closed" message quickly instead of spinning for a minute.
// (Safe for orders too: the idempotency key means a retry can't double-order.)
const TIMEOUT_MS = 10000;
function fetchWithTimeout(url, options = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  if (options.signal) options.signal.addEventListener("abort", () => ctrl.abort());
  return fetch(url, { ...options, signal: ctrl.signal }).finally(() => clearTimeout(timer));
}

// False until the real URL and anon key are pasted into js/config.js
export function isConfigured() {
  return (
    /^https:\/\/.+\.supabase\.co$/.test(CONFIG.supabaseUrl) &&
    !!CONFIG.supabaseAnonKey &&
    !CONFIG.supabaseAnonKey.startsWith("PASTE")
  );
}

// Created on first use (not at import) so a missing key shows a friendly
// message on the page instead of crashing the whole script.
export function getClient() {
  if (!isConfigured()) {
    throw new Error("The site isn't connected to its database yet.");
  }
  if (!client) client = createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey, { global: { fetch: fetchWithTimeout } });
  return client;
}

// Active flavors and boxes. Prices come back as numbers for display only.
export async function fetchMenu() {
  const sb = getClient();
  const [flavorsRes, boxesRes] = await Promise.all([
    sb.from("flavors").select("id, slug, name, price, surcharge").eq("active", true).order("id"),
    sb.from("boxes").select("id, size, price").eq("active", true).order("size"),
  ]);
  if (flavorsRes.error) throw flavorsRes.error;
  if (boxesRes.error) throw boxesRes.error;

  return {
    flavors: flavorsRes.data.map((f) => ({
      ...f,
      price: Number(f.price),
      surcharge: Number(f.surcharge),
    })),
    boxes: boxesRes.data.map((b) => ({ ...b, price: Number(b.price) })),
  };
}

// Which Sunday is open, when it closes, and how many cookies are left.
// Calls the database function current_sunday_info() (it returns one row).
export async function fetchSundayInfo() {
  const { data, error } = await getClient().rpc("current_sunday_info");
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) throw new Error("Couldn't load this Sunday's info.");
  return row; // { sunday_date, cutoff_at, cap, cookies_taken, remaining, is_full }
}

// ---- Ordering -----------------------------------------------------------------

// Call a database function and turn any failure into an Error with:
//   err.hint      short machine code from the database (e.g. "sunday_full"), or ""
//   err.isNetwork true when we never got a real answer (offline, timeout...)
// The messages the database raises are written for customers, so err.message
// is safe to show for those.
async function callFunction(name, args) {
  let result;
  try {
    result = await getClient().rpc(name, args);
  } catch (e) {
    const err = new Error("Network problem");
    err.isNetwork = true;
    err.hint = "";
    throw err;
  }
  if (result.error) {
    const err = new Error(result.error.message || "Something went wrong");
    err.hint = result.error.hint || "";
    // Database errors always carry a code (P0001 for our messages). No code = never reached it.
    err.isNetwork = !result.error.code;
    throw err;
  }
  return result.data;
}

// Place an order from the cart. We send ONLY what the customer chose (sizes,
// flavors, quantities, gift notes). No prices: the database prices everything.
// Returns { ref_code, total, sunday_date } (the real Sunday, which can differ
// from the banner if the order didn't fit and rolled over).
export async function placeOrder({ name, igHandle, phone, fulfillment, address, boxes, idempotencyKey }) {
  const data = await callFunction("place_order", {
    p_name: name,
    p_ig_handle: igHandle,
    p_phone: phone,
    p_fulfillment: fulfillment,
    p_address: address || null,
    p_boxes: boxes.map((b) => ({
      size: b.size,
      gift_note: b.giftNote || null,
      items: b.items.map((i) => ({ flavor_slug: i.slug, qty: i.qty })),
    })),
    // Same key on a retry = the database hands back the order it already saved
    // instead of creating a duplicate (see migration 003).
    p_idempotency_key: idempotencyKey || null,
  });
  const row = Array.isArray(data) ? data[0] : data;
  return { ref_code: row.ref_code, total: Number(row.total), sunday_date: row.sunday_date };
}

// Safe lookup by reference code: returns ONLY { ref_code, sunday_date, total, status },
// or null if there's no such order. No personal data.
export async function getOrderStatus(refCode) {
  const data = await callFunction("get_order_status", { p_ref_code: refCode });
  const row = Array.isArray(data) ? data[0] : data;
  return row ? { ...row, total: Number(row.total) } : null;
}

// Save the customer's GCash reference number on their pending order.
export async function submitGcashRef(refCode, gcashRef) {
  await callFunction("submit_gcash_ref", { p_ref_code: refCode, p_gcash_ref: gcashRef });
}
