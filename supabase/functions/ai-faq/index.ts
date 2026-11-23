// Public menu/FAQ helper for the AJ's website.
//
// POST { question: string, history?: [{ role: "user"|"assistant", content: string }] }
//   → { answer: string }
//
// Safety switches:
// - OFF until site_settings.ai_faq_enabled = 'true' (flip it in the admin or SQL editor).
// - Answers ONLY from your menu data + the ai_faq_extra text you control in site_settings.
// - Allergy questions always get the "home kitchen / may contain" warning and a nudge to DM.
// - Rate limited per visitor, short answers, cheap model.

import { createClient } from "npm:@supabase/supabase-js@2";
import { callClaude, cors, errorResponse, HttpError, json, manilaToday, textOf } from "../_shared/claude.ts";

// Simple per-IP limit: 8 questions per 10 minutes (resets if the function restarts — good enough).
const hits = new Map<string, number[]>();
function rateLimit(ip: string) {
  const now = Date.now();
  const recent = (hits.get(ip) ?? []).filter((t) => now - t < 10 * 60_000);
  if (recent.length >= 8) throw new HttpError(429, "Too many questions. DM us on IG @ajs.mnl!");
  recent.push(now);
  hits.set(ip, recent);
  if (hits.size > 5000) hits.clear();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.method !== "POST") throw new HttpError(405, "Use POST.");
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);

    // Read settings (public table) — includes the on/off switch and your extra FAQ text
    const { data: settings } = await sb.from("site_settings").select("key,value");
    const s = Object.fromEntries((settings ?? []).map((r) => [r.key, r.value]));
    if (s.ai_faq_enabled !== "true") throw new HttpError(404, "The helper is off right now.");

    const ip = (req.headers.get("x-forwarded-for") ?? "unknown").split(",")[0].trim();
    rateLimit(ip);

    const body = await req.json().catch(() => ({}));
    const question = String(body.question ?? "").trim();
    if (!question) throw new HttpError(400, "Type a question.");
    if (question.length > 400) throw new HttpError(400, "Keep it under 400 characters.");

    // Last few turns only, trimmed, so people can't stuff in huge prompts
    const history = (Array.isArray(body.history) ? body.history : [])
      .slice(-6)
      .filter((m: { role: string; content: unknown }) =>
        (m.role === "user" || m.role === "assistant") && typeof m.content === "string"
      )
      .map((m: { role: string; content: string }) => ({ role: m.role, content: m.content.slice(0, 400) }));

    // Public menu data (RLS only returns active, non-hidden flavors and active boxes)
    const [{ data: flavors }, { data: boxes }, { data: avail }] = await Promise.all([
      sb.from("flavors").select(
        "name,short_description,single_price,surcharge,sold_out,contains,may_contain,weight_label,shelf_life,storage_tip,nutrition",
      ),
      sb.from("boxes").select("size,price,description").order("size"),
      sb.rpc("flavor_availability"),
    ]);

    const menu = (flavors ?? []).map((f) => ({
      name: f.name,
      about: f.short_description,
      single_price: f.single_price,
      extra_in_box: f.surcharge || 0,
      sold_out: f.sold_out,
      contains: f.contains,
      may_contain: f.may_contain,
      weight: f.weight_label,
      shelf_life: f.shelf_life,
      storage: f.storage_tip,
      estimated_nutrition_per_cookie: f.nutrition,
    }));

    const system = `You are the friendly helper on the AJ's website (home-baked brown butter cookies, Metro Manila, IG @ajs.mnl).
Answer ONLY from the info below. If the answer isn't here, say you're not sure and to DM @ajs.mnl on Instagram. Never make up prices, dates, ingredients or policies.

ALLERGIES: Never say a cookie is safe or allergen-free. For any allergy question, list what it contains and may contain, include this exact note: "${s.global_allergen_note ?? "Made in a home kitchen that handles common allergens."}" and tell them to DM before ordering if it's serious.
NUTRITION: These are estimates: "${s.nutrition_note ?? "Estimated, not lab tested."}"
ORDERING: You can't take orders. Point people to the order form on this website.

Keep answers under 80 words. Warm, casual, a little playful. Reply in the customer's language (English or Taglish).

Today: ${manilaToday()}

MENU (JSON):
${JSON.stringify(menu)}

BOXES (JSON):
${JSON.stringify(boxes ?? [])}

THIS WEEK'S AVAILABILITY (JSON):
${JSON.stringify(avail ?? [])}

SHOP INFO (written by AJ's):
${s.ai_faq_extra ?? ""}`;

    const res = await callClaude({
      max_tokens: 300,
      system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
      messages: [...history, { role: "user", content: question }],
    });
    return json({ answer: textOf(res) });
  } catch (err) {
    return errorResponse(err);
  }
});
