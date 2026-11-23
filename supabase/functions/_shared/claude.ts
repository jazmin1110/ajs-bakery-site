// Shared helpers for AJ's AI functions.
// - callClaude(): talks to the Claude API using the ANTHROPIC_API_KEY secret
// - HttpError / json() / cors: small helpers so every function answers the same way

export const MODEL = Deno.env.get("AI_MODEL") ?? "claude-haiku-5-5";

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Turns any thrown error into a clean JSON response.
export function errorResponse(err: unknown): Response {
  if (err instanceof HttpError) return json({ error: err.message }, err.status);
  console.error(err);
  return json({ error: "Something went wrong. Try again." }, 500);
}

// deno-lint-ignore no-explicit-any
export type ClaudeResponse = { content: any[]; stop_reason: string; usage?: unknown };

// One call to the Claude Messages API. `body` is everything except the model.
export async function callClaude(body: Record<string, unknown>): Promise<ClaudeResponse> {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) {
    throw new HttpError(
      503,
      "AI isn't set up yet. Add ANTHROPIC_API_KEY in Supabase → Edge Functions → Secrets.",
    );
  }
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: MODEL, ...body }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error("Claude API error", res.status, data);
    if (res.status === 400 && /credit/i.test(data?.error?.message ?? "")) {
      throw new HttpError(402, "Out of API credits. Check the Claude Console billing page.");
    }
    throw new HttpError(502, "The AI didn't answer. Try again in a bit.");
  }
  return data as ClaudeResponse;
}

// When we force Claude to "fill in a form" (a tool), this pulls the filled-in form out.
// deno-lint-ignore no-explicit-any
export function toolInput(data: ClaudeResponse, name: string): any {
  const block = data.content?.find((c) => c.type === "tool_use" && c.name === name);
  if (!block) throw new HttpError(502, "The AI didn't return a result. Try again.");
  return block.input;
}

// Plain text from Claude's reply.
export function textOf(data: ClaudeResponse): string {
  return (data.content ?? [])
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n")
    .trim();
}

const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];

// Accepts a data URL ("data:image/png;base64,....") and returns a Claude image block.
export function imageBlock(dataUrl: unknown) {
  if (typeof dataUrl !== "string") throw new HttpError(400, "Image is missing.");
  const m = dataUrl.match(/^data:(image\/[a-z]+);base64,([A-Za-z0-9+/=]+)$/);
  if (!m || !IMAGE_TYPES.includes(m[1])) {
    throw new HttpError(400, "Use a JPG, PNG, WEBP or GIF screenshot.");
  }
  if (m[2].length > 6_500_000) throw new HttpError(413, "Image is too big (max ~4.5 MB).");
  return { type: "image", source: { type: "base64", media_type: m[1], data: m[2] } };
}

// Today's date in Manila as YYYY-MM-DD.
export function manilaToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Manila" }).format(new Date());
}
