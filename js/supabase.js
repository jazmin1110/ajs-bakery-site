// Supabase client + the few database reads the storefront needs.
// Anon key ONLY. The database decides what this key is allowed to see (RLS).
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { CONFIG } from "./config.js";

let client = null;

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
  if (!client) client = createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey);
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
