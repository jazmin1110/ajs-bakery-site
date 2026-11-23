// AJ's "Ask us" chat bubble for the public website.
//
// Loaded by index.html. The AI runs in the Supabase Edge Function `ai-faq`.
//
// It stays hidden unless site_settings.ai_faq_enabled = 'true',
// so you can ship this code now and switch it on later (January) without redeploying.

import { CONFIG } from "./config.js";
import { getClient } from "./supabase.js";

// Stacking: z-index 25 sits above the cart bar (20) but under the cart drawer (30/40) and the
// cookie detail sheet (60/61), so it never covers them. When the cart bar is showing
// (body.has-cart-bar), the bubble moves up by the bar's real height (--bar-h, set by ui.js)
// so it never sits on the Checkout button.
const css = `
.ajfaq-btn{position:fixed;right:18px;bottom:18px;z-index:25;background:var(--blue, #2B4C93);color:#fff;border:0;border-radius:999px;
  padding:12px 18px;font:600 15px var(--font-body, system-ui),sans-serif;box-shadow:0 6px 20px rgba(43,76,147,.35);cursor:pointer}
.ajfaq-box{position:fixed;right:18px;bottom:76px;z-index:25;width:min(360px,calc(100vw - 36px));height:min(480px,70vh);
  background:#fff;border-radius:18px;box-shadow:0 12px 40px rgba(0,0,0,.18);display:none;flex-direction:column;
  font:14px/1.45 var(--font-body, system-ui),sans-serif;color:var(--ink, #5C3A22);overflow:hidden}
.ajfaq-box.open{display:flex}
.ajfaq-head{background:var(--blue, #2B4C93);color:#fff;padding:12px 14px;font-weight:700;display:flex;justify-content:space-between}
.ajfaq-head button{background:none;border:0;color:#fff;font-size:18px;cursor:pointer}
.ajfaq-log{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}
.ajfaq-msg{max-width:85%;padding:8px 11px;border-radius:14px;white-space:pre-wrap}
.ajfaq-me{align-self:flex-end;background:var(--blue, #2B4C93);color:#fff;border-bottom-right-radius:4px}
.ajfaq-bot{align-self:flex-start;background:var(--blue-soft, #DCE5F4);border-bottom-left-radius:4px}
.ajfaq-form{display:flex;gap:6px;padding:10px;border-top:1px solid #e6eaf5}
.ajfaq-form input{flex:1;padding:9px 11px;border:1px solid #c9d3ea;border-radius:999px;font:inherit}
.ajfaq-form button{background:var(--blue, #2B4C93);color:#fff;border:0;border-radius:999px;padding:0 14px;font-weight:600;cursor:pointer}
.ajfaq-foot{font-size:11px;color:#7a839a;text-align:center;padding:0 10px 8px}
body.has-cart-bar .ajfaq-btn{bottom:calc(var(--bar-h, 4.5rem) + 12px)}
body.has-cart-bar .ajfaq-box{bottom:calc(var(--bar-h, 4.5rem) + 70px);height:min(480px,calc(100vh - var(--bar-h, 4.5rem) - 150px))}
`;

export async function mountFaqWidget({ label = "Ask us 🍪" } = {}) {
  const supabase = getClient();
  // Only show if switched on
  const { data } = await supabase.from("site_settings").select("value").eq("key", "ai_faq_enabled").maybeSingle();
  if (data?.value !== "true") return;

  document.head.append(Object.assign(document.createElement("style"), { textContent: css }));
  const el = (tag, cls, text) => Object.assign(document.createElement(tag), { className: cls || "", textContent: text || "" });

  const btn = el("button", "ajfaq-btn", label);
  const box = el("div", "ajfaq-box");
  const head = el("div", "ajfaq-head", "AJ's helper");
  const close = el("button", "", "×");
  head.append(close);
  const log = el("div", "ajfaq-log");
  const form = el("form", "ajfaq-form");
  const input = Object.assign(el("input"), { placeholder: "Ask about flavors, allergens, delivery…", maxLength: 400 });
  form.append(input, el("button", "", "Send"));
  const foot = el("div", "ajfaq-foot", "AI helper, can make mistakes. For allergies or anything important, DM @ajs.mnl.");
  box.append(head, log, form, foot);
  document.body.append(btn, box);

  const history = [];
  const add = (role, text) => {
    log.append(el("div", `ajfaq-msg ${role === "user" ? "ajfaq-me" : "ajfaq-bot"}`, text));
    log.scrollTop = log.scrollHeight;
  };
  add("assistant", "Hi! Ask me anything about our cookies 🍪");

  btn.onclick = () => {
    box.classList.toggle("open");
    if (box.classList.contains("open")) input.focus();
  };
  close.onclick = () => box.classList.remove("open");

  form.onsubmit = async (e) => {
    e.preventDefault();
    const q = input.value.trim();
    if (!q) return;
    input.value = "";
    add("user", q);
    input.disabled = true;
    try {
      let answer;
      try {
        // Own fetch with 30s: the shared client gives up after 10s, too short for the AI
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 30000);
        const res = await fetch(`${CONFIG.supabaseUrl}/functions/v1/ai-faq`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            apikey: CONFIG.supabaseAnonKey,
            Authorization: `Bearer ${CONFIG.supabaseAnonKey}`,
          },
          body: JSON.stringify({ question: q, history }),
          signal: ctrl.signal,
        }).finally(() => clearTimeout(timer));
        const out = await res.json().catch(() => ({}));
        answer = out.answer || out.error;
      } catch (_) { /* network trouble: fall through to the default below */ }
      answer = answer || "Sorry, I'm having trouble. DM us on IG @ajs.mnl!";
      add("assistant", answer);
      history.push({ role: "user", content: q }, { role: "assistant", content: answer });
    } finally {
      input.disabled = false;
      input.focus();
    }
  };
}
