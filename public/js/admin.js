// Shared helpers for the admin pages (login, orders, totals).
//
// NOTE: redirecting people who aren't logged in is a CONVENIENCE only. Anyone
// can open these pages' source. The real protection is in the database: every
// admin function checks is_admin(), and Row Level Security hides the data from
// everyone else (see supabase/migrations/004_admin_functions.sql).
import { getClient, isConfigured } from "./supabase.js";
import { esc, formatSunday, addDays } from "./ui.js";

export const BATCH_SIZE = 15;   // cookies per baking batch

// ---- Login / access ---------------------------------------------------------------

// Call at the top of every admin page. Resolves with the session if the user is
// a logged-in admin; otherwise sends them to the login page and never resolves.
export async function requireAdmin() {
  if (!isConfigured()) {
    document.body.innerHTML = `<main class="container"><p class="load-error">The site isn't connected to its database yet.</p></main>`;
    return new Promise(() => {});
  }
  const sb = getClient();
  const { data } = await sb.auth.getSession();
  if (!data.session) return goToLogin();

  const { data: ok, error } = await sb.rpc("is_admin");
  if (error || ok !== true) {
    await sb.auth.signOut();
    return goToLogin("?denied=1");
  }

  // If the session ends (logged out in another tab, expired), leave the page
  sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_OUT") goToLogin(); });
  return data.session;
}

function goToLogin(query = "") {
  location.replace("login.html" + query);
  return new Promise(() => {});   // stop the page script from carrying on
}

export async function signOut() {
  await getClient().auth.signOut();
  goToLogin();
}

// ---- Sundays -----------------------------------------------------------------------

// Today's date in Manila as "YYYY-MM-DD". Reads the phone's clock but always
// formats it as Manila time, so the phone's TIMEZONE doesn't matter.
export function manilaToday(now = new Date()) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Manila" }).format(now);
}

// The Sunday on or after a date (a Sunday gives itself)
export function sundayOnOrAfter(iso) {
  const dow = new Date(iso + "T00:00:00Z").getUTCDay(); // Sunday = 0
  return addDays(iso, (7 - dow) % 7);
}

// "Current" Sunday = the next one on or after today (Manila). It's the one being baked.
export function currentSunday() {
  return sundayOnOrAfter(manilaToday());
}

// Which Sunday to show: ?sunday=YYYY-MM-DD in the address, else the current one
export function selectedSunday() {
  const q = new URLSearchParams(location.search).get("sunday");
  return /^\d{4}-\d{2}-\d{2}$/.test(q || "") ? q : currentSunday();
}

// Fill a <select> with Sundays (4 weeks back, 8 ahead) and keep the URL in sync
export function setupSundayPicker(select, onChange) {
  const current = currentSunday();
  const chosen = selectedSunday();
  const dates = [];
  for (let w = -4; w <= 8; w++) dates.push(addDays(current, w * 7));
  if (!dates.includes(chosen)) dates.push(chosen);
  dates.sort();
  select.innerHTML = dates.map((d) =>
    `<option value="${d}"${d === chosen ? " selected" : ""}>${esc(formatSunday(d))}${d === current ? " (this Sunday)" : ""}</option>`
  ).join("");
  select.addEventListener("change", () => {
    const url = new URL(location.href);
    url.searchParams.set("sunday", select.value);
    history.replaceState(null, "", url);
    syncNav();
    onChange(select.value);
  });
  syncNav();
}

// ---- Nav bar ---------------------------------------------------------------------------

// The pages in the menu. `sunday: true` = the page works on one Sunday, so the
// chosen Sunday is carried along when you switch to it.
const NAV_PAGES = [
  // In the order you use them in a week: orders in, plan + bake, stock, recipes. Totals = the numbers at a glance.
  { page: "orders",     label: "Orders",     sunday: true },
  { page: "production", label: "Bake plan",  sunday: true },
  { page: "inventory",  label: "Stock",      sunday: false },
  { page: "recipes",    label: "Recipes",    sunday: false },
  { page: "totals",     label: "Totals",     sunday: true },
];

export function renderNav(active) {
  const nav = document.getElementById("admin-nav");
  nav.innerHTML = NAV_PAGES.map((p) =>
    `<a href="${p.page}.html" data-page="${p.page}"${p.sunday ? ' data-sunday="1"' : ""}${active === p.page ? ' aria-current="page"' : ""}>${p.label}</a>`
  ).join("");
  // Log out sits on the logo row (top right) so the menu row only holds the pages
  if (!document.getElementById("logout-btn")) {
    nav.insertAdjacentHTML("beforebegin", `<button type="button" class="link-btn admin-logout" id="logout-btn">Log out</button>`);
  }
  document.getElementById("logout-btn").addEventListener("click", signOut);
  syncNav();
}

// Keep the chosen Sunday when switching between the Sunday-based pages
function syncNav() {
  const q = new URLSearchParams(location.search).get("sunday");
  document.querySelectorAll("#admin-nav a").forEach((a) => {
    a.href = a.dataset.page + ".html" + (q && a.dataset.sunday ? `?sunday=${q}` : "");
  });
}

// ---- Data ------------------------------------------------------------------------------

// Turn a database error into a message a human can read
export function fail(error) {
  const err = new Error(error.message || "Something went wrong");
  err.hint = error.hint || "";
  err.isNetwork = !error.code;
  return err;
}

// Call any admin_* database function. Throws a readable error (with .hint) if it fails.
// The functions check is_admin() themselves, so this is safe to call from any admin page.
export async function rpc(name, args = {}) {
  const { data, error } = await getClient().rpc(name, args);
  if (error) throw fail(error);
  return data;
}

// Read rows with the logged-in admin's session. Row Level Security still decides what comes back.
export async function select(table, columns = "*", build = (q) => q) {
  const { data, error } = await build(getClient().from(table).select(columns));
  if (error) throw fail(error);
  return data || [];
}

// ---- Number formatting (back-office pages) ----------------------------------------

// 2500 -> "2,500", 3.70 -> "3.7", 0.5 -> "0.5" (no pointless trailing zeros)
export function num(n, maxDecimals = 2) {
  return Number(n).toLocaleString("en-PH", { maximumFractionDigits: maxDecimals });
}

// 2500, "g" -> "2.5 kg", 12, "pc" -> "12 pc", 1.5, "tsp" -> "1.5 tsp"
export function fmtQty(n, unit) {
  if (unit === "g" && Math.abs(n) >= 1000) return `${num(n / 1000, 2)} kg`;
  return `${num(n, 2)} ${unit}`;
}

// ₱ with cents when it matters: 37.4 -> "₱37.40", 285 -> "₱285"
export function peso2(amount) {
  const n = Number(amount);
  return "₱" + n.toLocaleString("en-PH", { minimumFractionDigits: Number.isInteger(n) ? 0 : 2, maximumFractionDigits: 2 });
}

// Short date from "2026-11-02" -> "Nov 2" (done in UTC so the viewer's timezone can't shift it)
export function shortDate(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
}

// Days from today (Manila) to a date: 0 = today, 1 = tomorrow, negative = past
export function daysUntil(iso) {
  return Math.round((new Date(iso + "T00:00:00Z") - new Date(manilaToday() + "T00:00:00Z")) / 86400000);
}

// Run this first on the orders page: unpaid orders past 24 hours become "expired"
export async function expireStale() {
  const { error } = await getClient().rpc("admin_expire_stale_orders");
  if (error) throw fail(error);
}

export async function loadOrders(sunday) {
  const { data, error } = await getClient().rpc("admin_orders", { p_sunday: sunday });
  if (error) throw fail(error);
  return data || [];
}

export async function loadFlavors() {
  const { data, error } = await getClient().from("flavors").select("slug, name, weekly_cap").order("id");
  if (error) throw fail(error);
  return data;
}

export async function setStatus(refCode, status) {
  const { error } = await getClient().rpc("admin_set_order_status", { p_ref_code: refCode, p_status: status });
  if (error) throw fail(error);
}

// ---- Small helpers ------------------------------------------------------------------------

// Is this order currently holding cookie slots? Paid, or pending and not yet overdue.
// "overdue" is worked out by the database clock (admin_orders), not this phone's.
export function isLive(order) {
  return order.status === "paid" || (order.status === "pending" && !order.overdue);
}

// "Oct 8, 3:20 PM" on the Manila clock
export function formatWhen(iso) {
  return new Date(iso).toLocaleString("en-US", {
    timeZone: "Asia/Manila", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  });
}

// "23h left", "45m left", or "overdue", from the seconds the database counted
export function timeLeft(secondsLeft) {
  if (secondsLeft <= 0) return "overdue";
  const h = Math.floor(secondsLeft / 3600);
  return h >= 1 ? `${h}h left` : `${Math.max(1, Math.floor(secondsLeft / 60))}m left`;
}

// Roll orders up into the numbers the Totals page shows.
// Cookies per flavor count BOTH box cookies and single cookies; `singles` is the
// loose-cookie part on its own.
export function summarize(orders, flavors) {
  const perFlavor = Object.fromEntries(flavors.map((f) => [f.slug, { name: f.name, cap: f.weekly_cap, paid: 0, pending: 0 }]));
  const boxes = {}; // size -> { paid, pending }
  const singles = { paid: 0, pending: 0 };
  let paid = 0, pending = 0;

  const addCookies = (slug, name, qty, kind) => {
    perFlavor[slug] ??= { name, paid: 0, pending: 0 };
    perFlavor[slug][kind] += qty;
    if (kind === "paid") paid += qty; else pending += qty;
  };

  for (const o of orders) {
    const kind = o.status === "paid" ? "paid" : isLive(o) ? "pending" : null;
    if (!kind) continue;                               // cancelled / expired: ignore
    for (const b of o.boxes) {
      boxes[b.size] ??= { paid: 0, pending: 0 };
      boxes[b.size][kind] += 1;
      for (const i of b.items) addCookies(i.slug, i.name, i.qty, kind);
    }
    for (const sgl of o.singles || []) {
      singles[kind] += sgl.qty;
      addCookies(sgl.slug, sgl.name, sgl.qty, kind);
    }
  }
  return { perFlavor, boxes, singles, paid, pending };
}

// How to pack loose single cookies: a bag for a few, a box from this many up.
// (Change it here if you pack differently.)
export const SINGLES_BOX_FROM = 3;
export function singlesPack(n) {
  return `${n >= SINGLES_BOX_FROM ? "Box" : "Bag"} of ${n}`;
}

// Batches for a number of cookies: round up, and say how many are left over
export function batchesFor(cookies) {
  const batches = Math.ceil(cookies / BATCH_SIZE);
  return { batches, leftover: batches * BATCH_SIZE - cookies };
}
