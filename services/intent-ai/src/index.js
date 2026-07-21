const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const MAX_DESCRIPTION_LENGTH = 4_000;
const MAX_APPS = 600;

export const intentionSchema = {
  type: "object",
  properties: {
    intentions: {
      type: "array",
      minItems: 1,
      maxItems: 1,
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
          restrictions: {
            type: "array",
            maxItems: 4,
            items: {
              type: "object",
              properties: {
                kind: {
                  type: "string",
                  enum: ["allowBrowserSearches", "dontStartUp", "coolDown", "timer"],
                },
                durationMinutes: { type: "integer" },
                resourceIDs: { type: "array", items: { type: "string" } },
              },
              required: ["kind", "durationMinutes", "resourceIDs"],
              additionalProperties: false,
            },
          },
          frictions: {
            type: "array",
            maxItems: 3,
            items: {
              type: "object",
              properties: {
                kind: {
                  type: "string",
                  enum: ["typedPhrase", "countdown", "reasonPrompt", "taskChecklist", "timeBudget"],
                },
                text: { type: "string" },
                seconds: { type: "integer" },
                minutes: { type: "integer" },
                tasks: { type: "array", items: { type: "string" } },
              },
              required: ["kind", "text", "seconds", "minutes", "tasks"],
              additionalProperties: false,
            },
          },
        },
        required: [
          "name",
          "purpose",
          "appBundleIdentifiers",
          "websites",
          "allowBrowserSearches",
          "restrictions",
          "frictions",
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

Turn the person's request into exactly one specific, reusable intention. An intention is one concrete outcome such as Reply to messages, Write an assignment, or Review pull requests. Do not create a vague category such as Work or Productivity.

Choose only applications from the installed-app catalog supplied by the user. Copy bundle identifiers exactly. Include only apps genuinely needed for the outcome. Suggest narrow website hosts or paths only when a selected installed app is a browser, and assign each website to that browser's exact bundle identifier. Do not invent applications or bundle identifiers. Keep the name short.

Translate explicit requests into connected restrictions. A timer limits the session and a cooldown delays reuse after it ends. Only add allowBrowserSearches when the person explicitly asks to search, browse, Google, look something up, or do research. Never infer browser-search permission merely because a browser or website is needed. Use durationMinutes for timer and coolDown, and use 0 for restrictions without a duration. Use resourceIDs only for dontStartUp and otherwise return an empty array. Keep allowBrowserSearches consistent with the matching restriction.

Translate explicit friction requests into frictions. For distracting games, YouTube, Instagram, or similarly addictive resources, suggest one light editable friction such as a countdown, reason prompt, time budget, or typed commitment phrase unless the person says not to. For unused friction fields, return an empty string, 0, or an empty array.
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
    return json(applyExplicitRequestRules(plan, body.description, body.installedApps));
  } catch {
    return json({ error: "Intent AI returned an unreadable plan. Please try again." }, 502);
  }
}

export function applyExplicitRequestRules(plan, description, installedApps = []) {
  const explicitlyRequestsSearch = /\b(search|searches|searching|google|browse|browsing|research|look\s+up)\b/i
    .test(description);
  const requestsGmail = /\bgmail\b/i.test(description);
  const requestsAppleMail = /\b(apple\s+mail|mail\s+app)\b/i.test(description);
  const requestsDistractingResource = /\b(instagram|youtube|tiktok|reddit|roblox|game|gaming|social\s+media)\b/i
    .test(description);
  const rejectsFriction = /\b(no|without)\s+friction\b/i.test(description);
  const availableIDs = new Set(installedApps.map((app) => app.bundleIdentifier));
  const browserPriority = [
    "com.google.Chrome",
    "org.mozilla.firefox",
    "com.apple.Safari",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser",
  ];

  return {
    ...plan,
    intentions: plan.intentions.map((intention) => {
      let appBundleIdentifiers = [...intention.appBundleIdentifiers];
      let websites = [...intention.websites];

      if (requestsGmail) {
        const selectedBrowser = browserPriority.find((id) => appBundleIdentifiers.includes(id));
        const availableBrowser = browserPriority.find((id) => availableIDs.has(id));
        const browserBundleIdentifier = selectedBrowser || availableBrowser;
        if (browserBundleIdentifier) {
          if (!requestsAppleMail) {
            appBundleIdentifiers = appBundleIdentifiers.filter((id) => id !== "com.apple.mail");
          }
          if (!appBundleIdentifiers.includes(browserBundleIdentifier)) {
            appBundleIdentifiers.push(browserBundleIdentifier);
          }
          websites = websites.filter((website) => website.value !== "mail.google.com");
          websites.push({ value: "mail.google.com", browserBundleIdentifier });
        }
      }

      let frictions = [...intention.frictions];
      if (requestsDistractingResource && !rejectsFriction && frictions.length === 0) {
        frictions = [{
          kind: "reasonPrompt",
          text: "What are you here to do?",
          seconds: 0,
          minutes: 0,
          tasks: [],
        }];
      }

      return {
        ...intention,
        appBundleIdentifiers,
        websites,
        allowBrowserSearches: explicitlyRequestsSearch ? intention.allowBrowserSearches : false,
        restrictions: explicitlyRequestsSearch
          ? intention.restrictions
          : intention.restrictions.filter((restriction) =>
              restriction.kind !== "allowBrowserSearches"
            ),
        frictions,
      };
    }),
  };
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
    plan.intentions.length === 1 &&
    plan.intentions.every((item) =>
      item && typeof item.name === "string" && typeof item.purpose === "string" &&
      Array.isArray(item.appBundleIdentifiers) && Array.isArray(item.websites) &&
      typeof item.allowBrowserSearches === "boolean" &&
      Array.isArray(item.restrictions) && Array.isArray(item.frictions)
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
