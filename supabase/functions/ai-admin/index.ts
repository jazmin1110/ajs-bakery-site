// AJ's admin AI tools. Only logged-in admins can use this (checked with is_admin()).
//
// POST { action: "draft_order",   text?: string, image?: dataUrl }
//   → reads an IG/Messenger DM (text or screenshot) and returns a DRAFT order.
//     Nothing is saved. The admin page shows it, you fix it, then it calls admin_create_order.
//
// POST { action: "check_payment", ref_code: "AJ-XXXXXX", image: dataUrl }
//   → reads a GCash receipt screenshot and compares it with the order.
//     It only FLAGS problems. A screenshot is not proof — always check your GCash app.
//
// POST { action: "ask", question: string }
//   → answers questions about sales/money/orders using your existing read-only reports.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  callClaude,
  cors,
  errorResponse,
  HttpError,
  imageBlock,
  json,
  manilaToday,
  textOf,
  toolInput,
} from "../_shared/claude.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.method !== "POST") throw new HttpError(405, "Use POST.");

    // Run every DB call as the logged-in user, so your existing RLS + is_admin() rules apply.
    const auth = req.headers.get("Authorization") ?? "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: auth } },
    });
    const { data: isAdmin, error: adminErr } = await sb.rpc("is_admin");
    if (adminErr || isAdmin !== true) throw new HttpError(403, "Admins only.");

    const body = await req.json().catch(() => ({}));
    switch (body.action) {
      case "draft_order":
        return json(await draftOrder(sb, body));
      case "check_payment":
        return json(await checkPayment(sb, body));
      case "ask":
        return json(await ask(sb, body));
      default:
        throw new HttpError(400, "Unknown action.");
    }
  } catch (err) {
    return errorResponse(err);
  }
});

// ---------------------------------------------------------------------------
// 1) DM → draft order
// ---------------------------------------------------------------------------

type Flavor = {
  slug: string;
  name: string;
  single_price: number | null;
  surcharge: number;
  hidden: boolean;
  sold_out: boolean;
};
type Box = { size: number; price: number };
type Line = { flavor_slug: string; qty: number };

const DRAFT_TOOL = {
  name: "draft_order",
  description: "Fill in a draft order from the customer's message.",
  input_schema: {
    type: "object",
    properties: {
      name: { type: ["string", "null"], description: "Customer name. null if not given." },
      ig_handle: { type: ["string", "null"], description: "Instagram handle without @, if visible." },
      phone: { type: ["string", "null"] },
      source: { type: "string", enum: ["instagram", "messenger", "other"] },
      fulfillment: { type: ["string", "null"], enum: ["pickup", "delivery", null] },
      address: { type: ["string", "null"], description: "Full delivery address, only if delivery." },
      sunday: {
        type: ["string", "null"],
        description: "YYYY-MM-DD of the Sunday they want it. null if they didn't say.",
      },
      boxes: {
        type: "array",
        description: "Boxes ordered. Items in a box must add up to the box size.",
        items: {
          type: "object",
          properties: {
            size: { type: "integer" },
            items: {
              type: "array",
              items: {
                type: "object",
                properties: { flavor_slug: { type: "string" }, qty: { type: "integer" } },
                required: ["flavor_slug", "qty"],
              },
            },
            gift_note: { type: ["string", "null"] },
          },
          required: ["size", "items"],
        },
      },
      singles: {
        type: "array",
        description: "Loose cookies not in a box.",
        items: {
          type: "object",
          properties: { flavor_slug: { type: "string" }, qty: { type: "integer" } },
          required: ["flavor_slug", "qty"],
        },
      },
      gcash_ref: { type: ["string", "null"], description: "GCash reference number if the customer sent one." },
      note: { type: ["string", "null"], description: "Anything else worth remembering (requests, timing)." },
      missing: {
        type: "array",
        items: { type: "string" },
        description: "Info you still need to ask the customer for, in plain words.",
      },
      warnings: {
        type: "array",
        items: { type: "string" },
        description: "Anything unclear or that you had to guess.",
      },
      customer_reply: {
        type: "string",
        description:
          "Short friendly reply Jazmin can send back: confirm the order and ask for anything missing. Match the customer's language (English or Taglish).",
      },
    },
    required: ["source", "boxes", "singles", "missing", "warnings", "customer_reply"],
  },
};

async function draftOrder(sb: SupabaseClient, body: { text?: string; image?: string }) {
  const text = typeof body.text === "string" ? body.text.trim().slice(0, 4000) : "";
  if (!text && !body.image) throw new HttpError(400, "Paste the DM or add a screenshot.");

  const [{ data: flavors }, { data: boxes }, { data: sunday }] = await Promise.all([
    sb.from("flavors").select("slug,name,single_price,surcharge,hidden,sold_out").eq("active", true),
    sb.from("boxes").select("size,price").eq("active", true).order("size"),
    sb.rpc("ordering_sunday"),
  ]);
  const fl = (flavors ?? []) as Flavor[];
  const bx = (boxes ?? []) as Box[];

  const menu = fl
    .map((f) =>
      `- ${f.slug}: "${f.name}"${f.hidden ? " (NOT on the menu right now)" : ""}${
        f.sold_out ? " (SOLD OUT)" : ""
      }, single ₱${f.single_price ?? "n/a"}${f.surcharge ? `, +₱${f.surcharge} each inside a box` : ""}`
    )
    .join("\n");
  const boxList = bx.map((b) => `- box of ${b.size}: ₱${b.price}`).join("\n");

  const system = `You read Instagram/Messenger DMs for AJ's, a home cookie business in Metro Manila, and fill in a DRAFT order. Jazmin reviews every draft before saving, so never guess silently: put doubts in "warnings" and unknowns in "missing".

Menu (use these slugs exactly):
${menu}

Boxes:
${boxList}

Rules:
- Customers use nicknames and Taglish. "choco chip"/"chimp" = choc-chip, "double choco"/"coco loco" = double-choc, "kinder"/"bueno" = kinder-bueno. If a flavor isn't on the menu or is sold out, still list it but add a warning.
- "Box of 6" etc → a box. Box items must add up exactly to the box size. If they didn't say the mix, split as evenly as the message suggests and add a warning.
- Cookies not in a box → singles.
- Orders are for a Sunday. Today is ${manilaToday()}. The next open Sunday is ${sunday ?? "unknown"}. Only fill "sunday" if the customer clearly says which day; otherwise null and add it to missing only if it matters.
- fulfillment: pickup or delivery. Delivery needs a full address. Delivery is a rider the customer books (Lalamove/Grab).
- Never mark anything as paid. If they mention a GCash reference, put the digits in gcash_ref.
- Don't invent names, phones or addresses.`;

  // deno-lint-ignore no-explicit-any
  const content: any[] = [];
  if (body.image) content.push(imageBlock(body.image));
  content.push({ type: "text", text: text ? `Customer message:\n"""\n${text}\n"""` : "The order is in the screenshot." });

  const res = await callClaude({
    max_tokens: 1500,
    system,
    tools: [DRAFT_TOOL],
    tool_choice: { type: "tool", name: "draft_order" },
    messages: [{ role: "user", content }],
  });
  const d = toolInput(res, "draft_order");

  // --- Double-check the AI's work with plain code (the AI never does the math) ---
  const bySlug = new Map(fl.map((f) => [f.slug, f]));
  const warnings: string[] = Array.isArray(d.warnings) ? [...d.warnings] : [];
  const cleanLines = (lines: unknown): Line[] =>
    (Array.isArray(lines) ? lines : [])
      .filter((l) => {
        const ok = l && bySlug.has(l.flavor_slug) && Number.isInteger(l.qty) && l.qty > 0;
        if (!ok && l?.flavor_slug) warnings.push(`Dropped unknown flavor "${l.flavor_slug}".`);
        return ok;
      })
      .map((l) => ({ flavor_slug: l.flavor_slug, qty: l.qty }));

  let estimated = 0;
  const outBoxes = (Array.isArray(d.boxes) ? d.boxes : []).map((b: { size: number; items: unknown; gift_note?: string }) => {
    const items = cleanLines(b.items);
    const box = bx.find((x) => x.size === b.size);
    const count = items.reduce((s, l) => s + l.qty, 0);
    if (!box) warnings.push(`There's no active box of ${b.size}.`);
    if (count !== b.size) warnings.push(`Box of ${b.size} has ${count} cookies in it — fix the mix.`);
    const extra = items.reduce((s, l) => s + l.qty * (bySlug.get(l.flavor_slug)?.surcharge ?? 0), 0);
    estimated += (box?.price ?? 0) + extra;
    return { size: b.size, items, gift_note: b.gift_note ?? null };
  });
  const singles = cleanLines(d.singles);
  for (const s of singles) estimated += s.qty * (bySlug.get(s.flavor_slug)?.single_price ?? 0);

  for (const l of [...singles, ...outBoxes.flatMap((b: { items: Line[] }) => b.items)]) {
    const f = bySlug.get(l.flavor_slug)!;
    if (f.hidden) warnings.push(`${f.name} isn't on the menu right now.`);
    if (f.sold_out) warnings.push(`${f.name} is marked sold out.`);
  }
  const gcash = typeof d.gcash_ref === "string" ? d.gcash_ref.replace(/\D/g, "") : "";

  return {
    // Ready to pass to admin_create_order (after you review it)
    draft: {
      p_sunday: d.sunday ?? sunday ?? null,
      p_name: d.name ?? "",
      p_phone: d.phone ?? null,
      p_ig_handle: d.ig_handle ?? null,
      p_source: d.source ?? "instagram",
      p_fulfillment: d.fulfillment ?? "pickup",
      p_address: d.address ?? null,
      p_boxes: outBoxes,
      p_singles: singles,
      p_payment: "unpaid",
      p_payment_method: null,
      p_gcash_ref: /^[0-9]{10,15}$/.test(gcash) ? gcash : null,
      p_note: d.note ?? null,
    },
    estimated_total: estimated,
    missing: Array.isArray(d.missing) ? d.missing : [],
    warnings: [...new Set(warnings)],
    customer_reply: d.customer_reply ?? "",
  };
}

// ---------------------------------------------------------------------------
// 2) GCash screenshot pre-check
// ---------------------------------------------------------------------------

const RECEIPT_TOOL = {
  name: "read_receipt",
  description: "Read what the payment screenshot shows.",
  input_schema: {
    type: "object",
    properties: {
      is_payment_receipt: { type: "boolean", description: "Is this a GCash/bank payment confirmation at all?" },
      amount: { type: ["number", "null"], description: "Amount sent in pesos." },
      reference_no: { type: ["string", "null"], description: "Reference number, digits only." },
      paid_at: { type: ["string", "null"], description: "Date/time shown, as written." },
      recipient_name: { type: ["string", "null"], description: "Who received the money, as shown (often masked)." },
      recipient_number: { type: ["string", "null"], description: "Recipient number as shown (often masked)." },
      oddities: {
        type: "array",
        items: { type: "string" },
        description:
          "Anything that looks off: mismatched fonts, cropped edges, edited-looking numbers, missing standard parts of a GCash receipt. Empty if nothing.",
      },
    },
    required: ["is_payment_receipt", "oddities"],
  },
};

async function checkPayment(sb: SupabaseClient, body: { ref_code?: string; image?: string }) {
  const ref = String(body.ref_code ?? "").trim().toUpperCase();
  if (!/^AJ-[A-Z0-9]{6}$/.test(ref)) throw new HttpError(400, "Enter the order code, like AJ-ABC123.");
  const img = imageBlock(body.image);

  const { data: order } = await sb
    .from("orders")
    .select("ref_code,name,total,status,gcash_ref,created_at")
    .eq("ref_code", ref)
    .maybeSingle();
  if (!order) throw new HttpError(404, `No order ${ref}.`);

  const res = await callClaude({
    max_tokens: 800,
    system:
      "You read payment screenshots for a small cookie shop. Report only what is visible. Do not guess numbers you can't read.",
    tools: [RECEIPT_TOOL],
    tool_choice: { type: "tool", name: "read_receipt" },
    messages: [{ role: "user", content: [img, { type: "text", text: "Read this payment screenshot." }] }],
  });
  const r = toolInput(res, "read_receipt");

  // Compare with plain code
  const problems: string[] = [];
  const readRef = typeof r.reference_no === "string" ? r.reference_no.replace(/\D/g, "") : "";
  if (!r.is_payment_receipt) problems.push("This doesn't look like a payment receipt.");
  if (r.amount == null) problems.push("Couldn't read the amount.");
  else if (Number(r.amount) !== Number(order.total)) {
    problems.push(`Amount is ₱${r.amount}, order total is ₱${order.total}.`);
  }
  if (!readRef) problems.push("Couldn't read a reference number.");
  else {
    if (order.gcash_ref && order.gcash_ref !== readRef) {
      problems.push(`Reference ${readRef} doesn't match the one the customer typed (${order.gcash_ref}).`);
    }
    const { data: dup } = await sb
      .from("orders")
      .select("ref_code")
      .eq("gcash_ref", readRef)
      .neq("ref_code", ref)
      .limit(1);
    if (dup && dup.length) problems.push(`Reference ${readRef} is already used on order ${dup[0].ref_code}.`);
  }
  for (const o of r.oddities ?? []) problems.push(`Looks off: ${o}`);

  return {
    order: { ref_code: order.ref_code, name: order.name, total: order.total, status: order.status },
    receipt: { ...r, reference_no: readRef || null },
    verdict: !r.is_payment_receipt ? "unreadable" : problems.length ? "check_carefully" : "looks_ok",
    problems,
    reminder: "A screenshot isn't proof. Confirm the money is in your GCash before marking paid.",
  };
}

// ---------------------------------------------------------------------------
// 3) Ask about your numbers (read-only: it can only call your existing report functions)
// ---------------------------------------------------------------------------

const DATE = { type: "string", description: "YYYY-MM-DD" };
const REPORT_TOOLS = [
  {
    name: "sales_report",
    description: "Cookies sold and revenue per flavor (paid orders) between two dates, by Sunday.",
    input_schema: { type: "object", properties: { from: DATE, to: DATE }, required: ["from", "to"] },
  },
  {
    name: "money_report",
    description:
      "Per-week money in, cookie cost, packaging cost, waste, ingredient spending and profit between two dates.",
    input_schema: { type: "object", properties: { from: DATE, to: DATE }, required: ["from", "to"] },
  },
  {
    name: "orders_for_sunday",
    description: "All orders for one Sunday (names, items, status, delivery).",
    input_schema: { type: "object", properties: { sunday: DATE }, required: ["sunday"] },
  },
  {
    name: "production_plan",
    description: "What to bake/prep for one Sunday: cookies per flavor, dough and ingredients needed.",
    input_schema: {
      type: "object",
      properties: { sunday: DATE, include_pending: { type: "boolean" } },
      required: ["sunday"],
    },
  },
];

async function runReport(sb: SupabaseClient, name: string, a: Record<string, unknown>) {
  const call = () => {
    switch (name) {
      case "sales_report":
        return sb.rpc("admin_sales_report", { p_from: a.from, p_to: a.to });
      case "money_report":
        return sb.rpc("admin_money_report", { p_from: a.from, p_to: a.to });
      case "orders_for_sunday":
        return sb.rpc("admin_orders", { p_sunday: a.sunday });
      case "production_plan":
        return sb.rpc("admin_production_plan", {
          p_sunday: a.sunday,
          p_include_pending: a.include_pending ?? true,
        });
    }
    return null;
  };
  const q = call();
  if (!q) return { error: "unknown report" };
  const { data, error } = await q;
  if (error) return { error: error.message };
  // Keep it small so a big report doesn't blow up the bill
  const s = JSON.stringify(data);
  return s.length > 30_000 ? s.slice(0, 30_000) + "…(cut)" : s;
}

async function ask(sb: SupabaseClient, body: { question?: string }) {
  const question = String(body.question ?? "").trim().slice(0, 1000);
  if (!question) throw new HttpError(400, "Type a question.");
  const { data: sunday } = await sb.rpc("ordering_sunday");

  const system = `You are the numbers helper for AJ's, Jazmin's home cookie business in Metro Manila. Orders are for Sundays.
Today is ${manilaToday()}. The next open Sunday is ${sunday ?? "unknown"}.
Use the report tools to get real numbers. Never make numbers up. If the reports can't answer it, say so.
Answer short and direct, in the same language as the question (English or Taglish). Use ₱. Bullet points are fine.`;

  // deno-lint-ignore no-explicit-any
  const messages: any[] = [{ role: "user", content: question }];
  for (let turn = 0; turn < 6; turn++) {
    const res = await callClaude({ max_tokens: 1200, system, tools: REPORT_TOOLS, messages });
    if (res.stop_reason !== "tool_use") return { answer: textOf(res) };
    messages.push({ role: "assistant", content: res.content });
    const results = [];
    for (const b of res.content.filter((c) => c.type === "tool_use")) {
      const out = await runReport(sb, b.name, b.input ?? {});
      results.push({
        type: "tool_result",
        tool_use_id: b.id,
        content: typeof out === "string" ? out : JSON.stringify(out),
      });
    }
    messages.push({ role: "user", content: results });
  }
  return { answer: "That question needed too many lookups. Try asking something more specific." };
}
