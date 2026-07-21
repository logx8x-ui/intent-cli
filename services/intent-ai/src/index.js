const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const MAX_DESCRIPTION_LENGTH = 4_000;
const MAX_APPS = 600;

export const intentionSchema = {
  type: "object",
  properties: {
    intentions: {
      type: "array",
      minItems: 2,
      maxItems: 8,
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          purpose: { type: "string" },
          appBundleIdentifiers: {
            type: "array",
            items: { type: "string" },
          },
          websites: {
            type: "array",
            items: {
              type: "object",
              properties: {
                value: { type: "string" },
                browserBundleIdentifier: { type: "string" },
              },
              required: ["value", "browserBundleIdentifier"],
              additionalProperties: false,
            },
          },
          allowBrowserSearches: { type: "boolean" },
        },
        required: [
          "name",
          "purpose",
          "appBundleIdentifiers",
          "websites",
          "allowBrowserSearches",
        ],
        additionalProperties: false,
      },
    },
  },
  required: ["intentions"],
  additionalProperties: false,
};

const systemPrompt = `
You design focused computer sessions for Intent, an app that lets a person use only the resources needed for one task at a time.

Turn the person's real computer activities into 2 to 8 specific, reusable intentions. An intention is one concrete outcome such as Reply to messages, Write an assignment, or Review pull requests. Do not create vague categories such as Work or Productivity.

Choose only applications from the installed-app catalog supplied by the user. Copy bundle identifiers exactly. Include only apps genuinely needed for the outcome. Suggest narrow website hosts or paths only when a selected installed app is a browser, and assign each website to that browser's exact bundle identifier. Do not invent applications or bundle identifiers. Keep names short and distinct. Allow browser searches only when discovery or research is genuinely part of the task.
`.trim();

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, model: env.OPENROUTER_MODEL || "openai/gpt-5.6-luna" });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/intention-plans") {
      return json({ error: "Not found." }, 404);
    }
    return handlePlanRequest(request, env);
  },
};

export async function handlePlanRequest(request, env) {
  if (!env.OPENROUTER_API_KEY) {
    return json({ error: "Intent AI is temporarily unavailable." }, 503);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send a valid JSON request." }, 400);
  }

  const validationError = validateRequest(body);
  if (validationError) {
    return json({ error: validationError }, 400);
  }

  const rateKey = request.headers.get("CF-Connecting-IP") || body.installationId;
  if (env.INTENT_RATE_LIMITER) {
    const { success } = await env.INTENT_RATE_LIMITER.limit({ key: rateKey });
    if (!success) {
      return json({ error: "Too many AI requests. Wait a minute and try again." }, 429);
    }
  }

  const upstream = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://github.com/logx8x-ui/intent-cli",
      "X-Title": "Intent",
    },
    body: JSON.stringify(openRouterRequest(body, env.OPENROUTER_MODEL)),
  });

  if (!upstream.ok) {
    const upstreamError = await upstream.text();
    console.error("OpenRouter request failed", upstream.status, upstreamError.slice(0, 800));
    return json({ error: "Intent AI could not generate suggestions. Please try again." }, 502);
  }

  let payload;
  try {
    payload = await upstream.json();
    const content = payload?.choices?.[0]?.message?.content;
    const plan = typeof content === "string" ? JSON.parse(content) : content;
    if (!isPlan(plan)) throw new Error("Invalid plan");
    return json(plan);
  } catch {
    return json({ error: "Intent AI returned an unreadable plan. Please try again." }, 502);
  }
}

export function validateRequest(body) {
  if (!body || body.version !== 1) return "This Intent version is not supported.";
  if (typeof body.installationId !== "string" || !/^[0-9a-f-]{36}$/i.test(body.installationId)) {
    return "The installation identifier is invalid.";
  }
  if (typeof body.description !== "string" || !body.description.trim()) {
    return "Describe what you use your Mac for.";
  }
  if (body.description.length > MAX_DESCRIPTION_LENGTH) {
    return "Keep the description under 4,000 characters.";
  }
  if (!Array.isArray(body.installedApps) || body.installedApps.length > MAX_APPS) {
    return "The installed app catalog is invalid.";
  }
  if (!body.installedApps.every((app) =>
    app && typeof app.name === "string" && typeof app.bundleIdentifier === "string" &&
    app.name.length <= 200 && app.bundleIdentifier.length <= 300
  )) {
    return "The installed app catalog is invalid.";
  }
  return null;
}

export function openRouterRequest(body, model = "openai/gpt-5.6-luna") {
  const catalog = body.installedApps
    .slice()
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((app) => `- ${app.name} | ${app.bundleIdentifier}`)
    .join("\n");

  return {
    model: model || "openai/gpt-5.6-luna",
    messages: [
      { role: "system", content: systemPrompt },
      {
        role: "user",
        content: `What this person does on their computer:\n${body.description.trim()}\n\nInstalled applications available to choose from:\n${catalog}`,
      },
    ],
    reasoning: { effort: "low" },
    include_reasoning: false,
    max_completion_tokens: 1_200,
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "intent_intention_plan",
        strict: true,
        schema: intentionSchema,
      },
    },
    provider: {
      require_parameters: true,
      allow_fallbacks: true,
      data_collection: "deny",
      zdr: true,
    },
  };
}

function isPlan(plan) {
  return plan && Array.isArray(plan.intentions) &&
    plan.intentions.length >= 2 && plan.intentions.length <= 8 &&
    plan.intentions.every((item) =>
      item && typeof item.name === "string" && typeof item.purpose === "string" &&
      Array.isArray(item.appBundleIdentifiers) && Array.isArray(item.websites) &&
      typeof item.allowBrowserSearches === "boolean"
    );
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
