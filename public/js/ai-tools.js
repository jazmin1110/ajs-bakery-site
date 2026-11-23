// AJ's admin AI tools, used by admin/ai.html ("AI helper" tab).
// The AI runs in the Supabase Edge Function `ai-admin` (supabase/functions/ai-admin);
// the Claude API key lives there as a secret, never in this file.
//
// Three tabs:
//   1. DM → Order   paste a DM (or screenshot) → AI fills a draft → you fix it → "Create order"
//   2. Payment check upload a GCash screenshot for an order → AI flags anything off
//   3. Ask          "ano best seller this month?" → answers from your real reports
//
// Nothing is saved without you clicking "Create order". Payment check never marks anything paid.

import { CONFIG } from "./config.js";
import { getClient } from "./supabase.js";

// AI calls can take 10-40 seconds (reading a screenshot, several report lookups), longer than
// the 10s timeout the normal Supabase client uses, so these calls use their own fetch with 60s.
const AI_TIMEOUT_MS = 60000;

const css = `
.ajai{font-size:15px;line-height:1.45;color:var(--ink, #5C3A22);max-width:760px}
.ajai *{box-sizing:border-box}
.ajai-tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
.ajai-tabs button{border:1px solid #c9d3ea;background:#fff;border-radius:999px;padding:6px 14px;cursor:pointer}
.ajai-tabs button.on{background:var(--blue, #2B4C93);color:#fff;border-color:var(--blue, #2B4C93)}
.ajai-card{border:1px solid #dfe5f3;border-radius:14px;padding:14px;background:#fff;margin-bottom:12px}
.ajai label{display:block;font-size:12px;color:#5b6580;margin:8px 0 3px}
.ajai input,.ajai select,.ajai textarea{width:100%;padding:8px 10px;border:1px solid #c9d3ea;border-radius:10px;font:inherit}
.ajai textarea{min-height:110px;resize:vertical}
.ajai-row{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.ajai-btn{margin-top:10px;background:var(--blue, #2B4C93);color:#fff;border:0;border-radius:10px;padding:9px 16px;font-weight:600;cursor:pointer}
.ajai-btn.ghost{background:var(--blue-soft, #DCE5F4);color:var(--blue, #2B4C93)}
.ajai-btn:disabled{opacity:.5;cursor:wait}
.ajai-warn{background:#fff6e5;border:1px solid #f3d08b;border-radius:10px;padding:8px 10px;margin-top:8px}
.ajai-bad{background:#fdecec;border:1px solid #f0a8a8;border-radius:10px;padding:8px 10px;margin-top:8px}
.ajai-ok{background:#e9f8ef;border:1px solid #9fd8b4;border-radius:10px;padding:8px 10px;margin-top:8px}
.ajai ul{margin:4px 0 0 18px;padding:0}
.ajai-muted{color:#5b6580;font-size:12px}
.ajai-answer{white-space:pre-wrap}
.ajai-check{display:flex;align-items:center;gap:6px;margin-top:8px}
.ajai-check input{width:auto}
@media(max-width:560px){.ajai-row{grid-template-columns:1fr}}
`;

// ---------- tiny DOM helpers (textContent only, so customer text can't inject HTML) ----------
function h(tag, props = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null) el[k] = v;
  }
  for (const kid of kids.flat()) if (kid != null) el.append(kid instanceof Node ? kid : String(kid));
  return el;
}
const field = (label, input) => h("div", {}, h("label", { textContent: label }), input);
const list = (items) => h("ul", {}, items.map((t) => h("li", { textContent: t })));
const peso = (n) => "₱" + Number(n || 0).toLocaleString("en-PH");

// Shrink screenshots before sending (cheaper + faster). Returns a data URL.
async function fileToDataUrl(file, max = 1600) {
  const img = await createImageBitmap(file);
  const scale = Math.min(1, max / Math.max(img.width, img.height));
  const c = document.createElement("canvas");
  c.width = Math.round(img.width * scale);
  c.height = Math.round(img.height * scale);
  c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
  return c.toDataURL("image/jpeg", 0.85);
}

// Calls the ai-admin Edge Function as the logged-in admin and returns its JSON (throws a readable error).
async function callAi(supabase, body) {
  const { data } = await supabase.auth.getSession();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), AI_TIMEOUT_MS);
  try {
    const res = await fetch(`${CONFIG.supabaseUrl}/functions/v1/ai-admin`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: CONFIG.supabaseAnonKey,
        Authorization: `Bearer ${data.session?.access_token ?? ""}`,
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(out.error || `The AI helper failed (${res.status}).`);
    return out;
  } catch (e) {
    if (e.name === "AbortError") throw new Error("The AI took too long. Try again.");
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

async function busy(btn, label, fn) {
  const old = btn.textContent;
  btn.disabled = true;
  btn.textContent = label;
  try {
    return await fn();
  } finally {
    btn.disabled = false;
    btn.textContent = old;
  }
}

export function mountAiTools(root) {
  const supabase = getClient();
  if (!document.getElementById("ajai-css")) document.head.append(h("style", { id: "ajai-css", textContent: css }));
  root.replaceChildren();
  root.classList.add("ajai");

  const panels = { "DM → Order": draftPanel(supabase), "Payment check": paymentPanel(supabase), "Ask": askPanel(supabase) };
  const tabs = h("div", { class: "ajai-tabs" });
  const body = h("div");
  const show = (name) => {
    [...tabs.children].forEach((b) => b.classList.toggle("on", b.textContent === name));
    body.replaceChildren(panels[name]);
  };
  for (const name of Object.keys(panels)) tabs.append(h("button", { textContent: name, onclick: () => show(name) }));
  root.append(tabs, body);
  show("DM → Order");
}

// =====================================================================
// 1) DM → Order
// =====================================================================
function draftPanel(supabase) {
  let image = null;
  const text = h("textarea", { placeholder: "Paste the IG/Messenger DM here…" });
  const fileIn = h("input", { type: "file", accept: "image/*" });
  const imgNote = h("div", { class: "ajai-muted" });
  const out = h("div");

  const setImage = async (file) => {
    image = file ? await fileToDataUrl(file) : null;
    imgNote.textContent = file ? `Screenshot added (${file.name || "pasted"})` : "";
  };
  fileIn.addEventListener("change", () => setImage(fileIn.files[0]));
  // Paste a screenshot straight into the text box
  text.addEventListener("paste", (e) => {
    const file = [...(e.clipboardData?.files || [])].find((f) => f.type.startsWith("image/"));
    if (file) {
      e.preventDefault();
      setImage(file);
    }
  });

  const readBtn = h("button", { class: "ajai-btn", textContent: "Read DM" });
  readBtn.onclick = () =>
    busy(readBtn, "Reading…", async () => {
      out.replaceChildren();
      try {
        const res = await callAi(supabase, { action: "draft_order", text: text.value, image });
        out.append(draftForm(supabase, res));
      } catch (e) {
        out.append(h("div", { class: "ajai-bad", textContent: e.message }));
      }
    });

  return h(
    "div",
    {},
    h(
      "div",
      { class: "ajai-card" },
      field("Customer message", text),
      field("…or a screenshot (you can also paste it into the box above)", fileIn),
      imgNote,
      readBtn,
    ),
    out,
  );
}

function draftForm(supabase, res) {
  const d = res.draft;
  const inp = (v, type = "text") => h("input", { type, value: v ?? "" });
  const sel = (v, opts) => {
    const s = h("select", {}, opts.map(([val, lbl]) => h("option", { value: val, textContent: lbl })));
    s.value = v ?? opts[0][0];
    return s;
  };

  const f = {
    name: inp(d.p_name),
    ig: inp(d.p_ig_handle),
    phone: inp(d.p_phone),
    source: sel(d.p_source, [["instagram", "Instagram"], ["messenger", "Messenger"], ["walk_in", "Walk-in"], ["other", "Other"]]),
    fulfillment: sel(d.p_fulfillment, [["pickup", "Pickup"], ["delivery", "Delivery"]]),
    address: inp(d.p_address),
    sunday: inp(d.p_sunday, "date"),
    payment: sel(d.p_payment, [["unpaid", "Unpaid (24h to pay)"], ["pay_on_day", "Pay on the day"], ["paid", "Paid"]]),
    method: sel(d.p_payment_method ?? "gcash", [["gcash", "GCash"], ["bank", "Bank"], ["cash", "Cash"], ["other", "Other"]]),
    gcash: inp(d.p_gcash_ref),
    note: inp(d.p_note),
    items: h("textarea", { value: JSON.stringify({ boxes: d.p_boxes, singles: d.p_singles }, null, 2) }),
    overCap: h("input", { type: "checkbox" }),
  };

  // Human-readable summary of the cookies
  const summary = [
    ...d.p_boxes.map((b) => `Box of ${b.size}: ` + b.items.map((i) => `${i.qty}× ${i.flavor_slug}`).join(", ") + (b.gift_note ? ` — note: "${b.gift_note}"` : "")),
    ...d.p_singles.map((s) => `${s.qty}× ${s.flavor_slug} (single)`),
  ];

  const result = h("div");
  const createBtn = h("button", { class: "ajai-btn", textContent: "Create order" });
  createBtn.onclick = () =>
    busy(createBtn, "Saving…", async () => {
      result.replaceChildren();
      let items;
      try {
        items = JSON.parse(f.items.value);
      } catch (_) {
        result.append(h("div", { class: "ajai-bad", textContent: "The items box isn't valid JSON. Check the brackets and commas." }));
        return;
      }
      const args = {
        p_sunday: f.sunday.value || null,
        p_name: f.name.value,
        p_phone: f.phone.value || null,
        p_ig_handle: f.ig.value.replace(/^@/, "") || null,
        p_source: f.source.value,
        p_fulfillment: f.fulfillment.value,
        p_address: f.address.value || null,
        p_boxes: items.boxes || [],
        p_singles: items.singles || [],
        p_payment: f.payment.value,
        p_payment_method: f.payment.value === "unpaid" ? null : f.method.value,
        p_gcash_ref: f.gcash.value || null,
        p_note: f.note.value || null,
        p_allow_over_cap: f.overCap.checked,
      };
      // Uses your existing admin_create_order function — same checks as the manual form
      const { data, error } = await supabase.rpc("admin_create_order", args);
      if (error) {
        result.append(h("div", { class: "ajai-bad", textContent: error.message }));
        return;
      }
      const row = Array.isArray(data) ? data[0] : data;
      result.append(h("div", { class: "ajai-ok", textContent: `Saved ${row.ref_code} — ${peso(row.total)} for Sunday ${row.sunday_date}.` }));
      createBtn.disabled = true;
    });

  const copyBtn = h("button", { class: "ajai-btn ghost", textContent: "Copy reply" });
  copyBtn.onclick = async () => {
    await navigator.clipboard.writeText(res.customer_reply);
    copyBtn.textContent = "Copied!";
    setTimeout(() => (copyBtn.textContent = "Copy reply"), 1500);
  };

  return h(
    "div",
    { class: "ajai-card" },
    h("strong", { textContent: `Draft order · about ${peso(res.estimated_total)}` }),
    h("div", { class: "ajai-muted", textContent: "Final total is calculated when you save." }),
    summary.length ? list(summary) : h("div", { class: "ajai-bad", textContent: "No cookies found in the message." }),
    res.warnings.length ? h("div", { class: "ajai-warn" }, h("strong", { textContent: "Check these" }), list(res.warnings)) : null,
    res.missing.length ? h("div", { class: "ajai-warn" }, h("strong", { textContent: "Still need from customer" }), list(res.missing)) : null,
    h("div", { class: "ajai-row" }, field("Name", f.name), field("IG handle", f.ig)),
    h("div", { class: "ajai-row" }, field("Phone", f.phone), field("Came from", f.source)),
    h("div", { class: "ajai-row" }, field("Pickup or delivery", f.fulfillment), field("Sunday", f.sunday)),
    field("Delivery address", f.address),
    h("div", { class: "ajai-row" }, field("Payment", f.payment), field("Paid via", f.method)),
    h("div", { class: "ajai-row" }, field("GCash reference", f.gcash), field("Note", f.note)),
    h("details", {}, h("summary", { textContent: "Edit cookies (advanced)" }), f.items),
    h("label", { class: "ajai-check" }, f.overCap, "Allow going over this week's flavor cap"),
    createBtn,
    result,
    res.customer_reply
      ? h("div", { class: "ajai-card", style: "margin-top:12px;background:#f7f9ff" },
        h("strong", { textContent: "Reply to send" }),
        h("div", { class: "ajai-answer", textContent: res.customer_reply }),
        copyBtn)
      : null,
  );
}

// =====================================================================
// 2) Payment check
// =====================================================================
function paymentPanel(supabase) {
  const ref = h("input", { placeholder: "AJ-ABC123" });
  const fileIn = h("input", { type: "file", accept: "image/*" });
  const out = h("div");
  const btn = h("button", { class: "ajai-btn", textContent: "Check screenshot" });

  btn.onclick = () =>
    busy(btn, "Checking…", async () => {
      out.replaceChildren();
      try {
        if (!fileIn.files[0]) throw new Error("Add the GCash screenshot.");
        const image = await fileToDataUrl(fileIn.files[0], 2000);
        const r = await callAi(supabase, { action: "check_payment", ref_code: ref.value, image });
        const tone = r.verdict === "looks_ok" ? "ajai-ok" : "ajai-bad";
        const title = r.verdict === "looks_ok" ? "Nothing looks off" : r.verdict === "unreadable" ? "Couldn't read it" : "Check carefully";
        out.append(
          h(
            "div",
            { class: "ajai-card" },
            h("strong", { textContent: `${r.order.ref_code} · ${r.order.name} · ${peso(r.order.total)} · ${r.order.status}` }),
            h("div", { class: tone }, h("strong", { textContent: title }), r.problems.length ? list(r.problems) : null),
            list([
              `Amount on screenshot: ${r.receipt.amount != null ? peso(r.receipt.amount) : "?"}`,
              `Reference: ${r.receipt.reference_no ?? "?"}`,
              `Date/time: ${r.receipt.paid_at ?? "?"}`,
              `Sent to: ${r.receipt.recipient_name ?? "?"} ${r.receipt.recipient_number ?? ""}`,
            ]),
            h("div", { class: "ajai-warn", textContent: r.reminder }),
          ),
        );
      } catch (e) {
        out.append(h("div", { class: "ajai-bad", textContent: e.message }));
      }
    });

  return h(
    "div",
    {},
    h(
      "div",
      { class: "ajai-card" },
      field("Order code", ref),
      field("GCash screenshot", fileIn),
      btn,
      h("div", { class: "ajai-muted", textContent: "This only flags problems. It never marks an order paid." }),
    ),
    out,
  );
}

// =====================================================================
// 3) Ask about your numbers
// =====================================================================
function askPanel(supabase) {
  const q = h("input", { placeholder: "e.g. Ano best seller this month? Magkano profit last Sunday?" });
  const out = h("div");
  const btn = h("button", { class: "ajai-btn", textContent: "Ask" });
  const go = () =>
    busy(btn, "Thinking…", async () => {
      out.replaceChildren();
      try {
        const r = await callAi(supabase, { action: "ask", question: q.value });
        out.append(h("div", { class: "ajai-card ajai-answer", textContent: r.answer }));
      } catch (e) {
        out.append(h("div", { class: "ajai-bad", textContent: e.message }));
      }
    });
  btn.onclick = go;
  q.addEventListener("keydown", (e) => e.key === "Enter" && go());
  return h(
    "div",
    {},
    h("div", { class: "ajai-card" }, field("Question about sales, money, orders or prep", q), btn,
      h("div", { class: "ajai-muted", textContent: "Read-only. It can look at your reports but can't change anything." })),
    out,
  );
}
