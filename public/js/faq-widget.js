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
  padding:12px 18px;font:600 15px var(--font-body, system-ui),sans-serif;cursor:pointer;
  box-shadow:0 0 0 2px var(--cream, #F7EBD5),0 6px 20px rgba(43,76,147,.35)}
/* the cream ring (first shadow) keeps the blue pill visible when it floats over the blue "How it works" section */
.ajfaq-box{position:fixed;right:18px;bottom:76px;z-index:25;width:min(360px,calc(100vw - 36px));height:min(480px,70vh);
  background:#fff;border-radius:18px;box-shadow:0 12px 40px rgba(0,0,0,.18);display:none;flex-direction:column;
  font:14px/1.45 var(--font-body, system-ui),sans-serif;color:var(--ink, #5C3A22);overflow:hidden}
.ajfaq-box.open{display:flex}
.ajfaq-head{background:var(--blue, #2B4C93);color:#fff;padding:12px 14px;font-weight:700;display:flex;justify-content:space-between}
.ajfaq-head{align-items:center;padding:6px 6px 6px 16px}
.ajfaq-head button{background:none;border:0;color:#fff;font-size:24px;line-height:1;width:44px;height:44px;border-radius:50%;cursor:pointer}
.ajfaq-log{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}
.ajfaq-msg{max-width:85%;padding:8px 11px;border-radius:14px;white-space:pre-wrap}
.ajfaq-me{align-self:flex-end;background:var(--blue, #2B4C93);color:#fff;border-bottom-right-radius:4px}
.ajfaq-bot{align-self:flex-start;background:var(--blue-soft, #DCE5F4);border-bottom-left-radius:4px}
.ajfaq-form{display:flex;gap:6px;padding:10px;border-top:1px solid #e6eaf5}
/* 16px on purpose: iPhones zoom the whole page in when you tap a text box with smaller text */
.ajfaq-form input{flex:1;min-width:0;padding:10px 14px;border:1px solid #c9d3ea;border-radius:999px;font:inherit;font-size:16px;color:inherit;background:#fff}
.ajfaq-form button{background:var(--blue, #2B4C93);color:#fff;border:0;border-radius:999px;padding:0 16px;min-height:44px;font:600 15px var(--font-body, system-ui),sans-serif;cursor:pointer}
.ajfaq-form button:disabled{opacity:.5;cursor:wait}
.ajfaq-typing{opacity:.7;font-style:italic}
.ajfaq-backdrop{display:none}
.ajfaq-foot{font-size:11px;color:#7a839a;text-align:center;padding:0 10px 8px}
body.has-cart-bar .ajfaq-btn{bottom:calc(var(--bar-h, 4.5rem) + 12px)}
body.has-cart-bar .ajfaq-box{bottom:calc(var(--bar-h, 4.5rem) + 70px);height:min(480px,calc(100vh - var(--bar-h, 4.5rem) - 150px))}
/* Phones: the chat opens as a panel from the bottom edge, full width, over a dimmed page (tap the dim area to close).
   dvh = the height you can actually see, so the panel shrinks instead of running off-screen when the keyboard opens. */
@media (max-width:560px){
  .ajfaq-box,body.has-cart-bar .ajfaq-box{left:0;right:0;bottom:0;width:100%;height:min(560px,85dvh);z-index:41;
    border-radius:18px 18px 0 0;padding-bottom:env(safe-area-inset-bottom)}
  .ajfaq-backdrop.open{display:block;position:fixed;inset:0;z-index:40;background:rgba(58,46,42,.45)}
  html.ajfaq-lock,html.ajfaq-lock body{overflow:hidden}
  .ajfaq-btn.hide{display:none}
}
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
  close.setAttribute("aria-label", "Close chat");
  const backdrop = el("div", "ajfaq-backdrop");
  document.body.append(btn, backdrop, box);

  const history = [];
  const add = (role, text) => {
    log.append(el("div", `ajfaq-msg ${role === "user" ? "ajfaq-me" : "ajfaq-bot"}`, text));
    log.scrollTop = log.scrollHeight;
  };
  add("assistant", "Hi! Ask me anything about our cookies 🍪");

  const isPhone = () => matchMedia("(max-width: 560px)").matches;
  const setOpen = (open) => {
    box.classList.toggle("open", open);
    backdrop.classList.toggle("open", open);
    btn.classList.toggle("hide", open);                                 // on phones the panel covers it anyway
    document.documentElement.classList.toggle("ajfaq-lock", open);     // stop the page scrolling behind the panel (phones only, see CSS)
    if (open && !isPhone()) input.focus();                             // phones: wait for a tap, so the keyboard doesn't jump up
  };
  btn.onclick = () => setOpen(!box.classList.contains("open"));
  close.onclick = () => setOpen(false);
  backdrop.onclick = () => setOpen(false);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && box.classList.contains("open")) setOpen(false); });

  form.onsubmit = async (e) => {
    e.preventDefault();
    const q = input.value.trim();
    if (!q || form.querySelector("button").disabled) return;
    input.value = "";
    add("user", q);
    const sendBtn = form.querySelector("button");
    sendBtn.disabled = true;                       // the text box stays enabled so the phone keyboard doesn't close and reopen
    const typing = el("div", "ajfaq-msg ajfaq-bot ajfaq-typing", "typing…");
    log.append(typing);
    log.scrollTop = log.scrollHeight;
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
      typing.remove();
      add("assistant", answer);
      history.push({ role: "user", content: q }, { role: "assistant", content: answer });
    } finally {
      typing.remove();
      sendBtn.disabled = false;
    }
  };
}
