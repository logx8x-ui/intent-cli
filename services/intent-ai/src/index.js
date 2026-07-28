const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const MAX_DESCRIPTION_LENGTH = 4_000;
const MAX_CONTEXT_LENGTH = 20_000;
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

When a current intention is supplied, modify that intention instead of creating a different one. Preserve its name, apps, websites, restrictions, and frictions unless the person's latest request explicitly adds, changes, or removes them. Return the complete updated intention, not a partial patch.

If the request mentions an intention with @Name or includes [intention-id:...], treat that as the single target intention. If more than one intention is clearly referenced and the target is ambiguous, keep the current intention unchanged and leave its fields intact rather than inventing a merge.

Choose only applications from the installed-app catalog supplied by the user. Copy bundle identifiers exactly. Include only apps genuinely needed for the outcome. Suggest narrow website hosts or paths only when a selected installed app is a browser, and assign each website to that browser's exact bundle identifier. Do not invent applications or bundle identifiers. Keep the name short.

Translate explicit requests into connected restrictions. A timer limits the session and a cooldown delays reuse after it ends. Only add allowBrowserSearches when the person explicitly asks to search, browse, Google, look something up, or do research. Never infer browser-search permission merely because a browser or website is needed. Use durationMinutes for timer and coolDown, and use 0 for restrictions without a duration. Use resourceIDs only for dontStartUp and otherwise return an empty array. Keep allowBrowserSearches consistent with the matching restriction.

Translate only explicit friction requests into frictions. Never infer or suggest friction from the selected apps, websites, or task. If the person does not explicitly request friction, return an empty frictions array. For unused friction fields, return an empty string, 0, or an empty array.
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

  let lastFailure = "No response";
  const completionBudgets = [800, 600, 450];
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const upstream = await fetch(OPENROUTER_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://github.com/logx8x-ui/intent-cli",
          "X-Title": "Intent",
        },
        body: JSON.stringify(openRouterRequest(
          body,
          env.OPENROUTER_MODEL,
          completionBudgets[attempt],
        )),
      });

      if (!upstream.ok) {
        lastFailure = `${upstream.status}: ${(await upstream.text()).slice(0, 800)}`;
        if (!isRetryableStatus(upstream.status)) break;
      } else {
        const payload = await upstream.json();
        const content = payload?.choices?.[0]?.message?.content;
        const plan = typeof content === "string" ? JSON.parse(content) : content;
        if (!isPlan(plan)) throw new Error("Invalid plan");
        return json(applyExplicitRequestRules(
          plan,
          body.description,
          body.installedApps,
          Boolean(body.currentIntention),
        ));
      }
    } catch (error) {
      lastFailure = error instanceof Error ? error.message : String(error);
    }

    if (attempt < 2) await sleep(350 * (attempt + 1));
  }

  console.error("OpenRouter generation failed after retries", lastFailure);
  return json({ error: "Intent AI is taking a moment. Please send that again." }, 503);
}

export function applyExplicitRequestRules(plan, description, installedApps = [], hasCurrentIntention = false) {
  const explicitlyRequestsSearch = /\b(search|searches|searching|google|browse|browsing|research|look\s+up)\b/i
    .test(description);
  const requestsGmail = /\bgmail\b/i.test(description);
  const requestsAppleMail = /\b(apple\s+mail|mail\s+app)\b/i.test(description);
  const explicitlyRequestsFriction = /\b(friction|countdown|commitment\s+phrase|typed?\s+phrase|reason\s+prompt|task\s+checklist|hard\s+mode|double\s+confirmation|write\s+(?:a\s+)?reason|before\s+(?:starting|i\s+can\s+start))\b/i
    .test(description);
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

      const frictions = explicitlyRequestsFriction || hasCurrentIntention
        ? [...intention.frictions]
        : [];

      return {
        ...intention,
        appBundleIdentifiers,
        websites,
        allowBrowserSearches: explicitlyRequestsSearch || hasCurrentIntention
          ? intention.allowBrowserSearches
          : false,
        restrictions: explicitlyRequestsSearch || hasCurrentIntention
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
  if (body.currentIntention != null) {
    let encodedContext;
    try {
      encodedContext = JSON.stringify(body.currentIntention);
    } catch {
      return "The current intention is invalid.";
    }
    if (!body.currentIntention || typeof body.currentIntention !== "object" || encodedContext.length > MAX_CONTEXT_LENGTH) {
      return "The current intention is invalid.";
    }
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

export function openRouterRequest(body, model = "openai/gpt-5.6-luna", maxCompletionTokens = 800) {
  const catalog = body.installedApps
    .slice()
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((app) => `- ${app.name} | ${app.bundleIdentifier}`)
    .join("\n");

  const currentContext = body.currentIntention
    ? `\n\nCurrent intention to modify (preserve all fields unless the latest request changes them):\n${JSON.stringify(body.currentIntention)}`
    : "";

  return {
    model: model || "openai/gpt-5.6-luna",
    messages: [
      { role: "system", content: systemPrompt },
      {
        role: "user",
        content: `Latest request:\n${body.description.trim()}${currentContext}\n\nInstalled applications available to choose from:\n${catalog}`,
      },
    ],
    reasoning: { effort: "low" },
    include_reasoning: false,
    max_completion_tokens: maxCompletionTokens,
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

function isRetryableStatus(status) {
  return status === 402 || status === 408 || status === 409 || status === 425 || status === 429 || status >= 500;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
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
