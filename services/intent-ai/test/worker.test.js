import assert from "node:assert/strict";
import test from "node:test";
import worker, {
  applyExplicitRequestRules,
  handlePlanRequest,
  intentionSchema,
  openRouterRequest,
  validateRequest,
} from "../src/index.js";

const requestBody = {
  version: 1,
  installationId: "123e4567-e89b-12d3-a456-426614174000",
  appVersion: "0.7.0",
  description: "I study data science and reply to messages.",
  installedApps: [
    { name: "Messages", bundleIdentifier: "com.apple.MobileSMS" },
    { name: "RStudio", bundleIdentifier: "com.rstudio.desktop" },
  ],
};

test("health endpoint does not require an API key", async () => {
  const response = await worker.fetch(new Request("https://intent.test/health"), {});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, model: "openai/gpt-5.6-luna" });
});

test("request validation accepts the supported contract", () => {
  assert.equal(validateRequest(requestBody), null);
  assert.match(validateRequest({ ...requestBody, description: "" }), /Describe/);
  assert.match(validateRequest({ ...requestBody, installationId: "nope" }), /identifier/);
});

test("OpenRouter request uses strict structured output and privacy routing", () => {
  const request = openRouterRequest(requestBody);
  assert.equal(request.model, "openai/gpt-5.6-luna");
  assert.equal(request.response_format.type, "json_schema");
  assert.equal(request.response_format.json_schema.strict, true);
  assert.equal(request.max_completion_tokens, 1_200);
  assert.equal(request.provider.data_collection, "deny");
  assert.equal(request.provider.require_parameters, true);
  assert.equal(request.provider.zdr, true);
  assert.match(request.messages[1].content, /com\.rstudio\.desktop/);
  assert.equal(intentionSchema.properties.intentions.minItems, 1);
  assert.equal(intentionSchema.properties.intentions.maxItems, 1);
  const itemSchema = intentionSchema.properties.intentions.items;
  assert.ok(itemSchema.required.includes("restrictions"));
  assert.ok(itemSchema.required.includes("frictions"));
  assert.match(request.messages[0].content, /exactly one specific/);
  assert.match(request.messages[0].content, /timer limits the session/);
});

test("generation route rejects a missing server key without forwarding", async () => {
  const response = await handlePlanRequest(new Request("https://intent.test/v1/intention-plans", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(requestBody),
  }), {});
  assert.equal(response.status, 503);
});

test("browser search permission requires an explicit search request", () => {
  const plan = {
    intentions: [{
      name: "Reply to messages",
      purpose: "Reply in Gmail",
      appBundleIdentifiers: ["com.apple.MobileSMS"],
      websites: [],
      allowBrowserSearches: true,
      restrictions: [
        { kind: "allowBrowserSearches", durationMinutes: 0, resourceIDs: [] },
        { kind: "timer", durationMinutes: 3, resourceIDs: [] },
      ],
      frictions: [],
    }],
  };

  const replyPlan = applyExplicitRequestRules(plan, "Reply to Gmail messages for three minutes");
  assert.equal(replyPlan.intentions[0].allowBrowserSearches, false);
  assert.deepEqual(replyPlan.intentions[0].restrictions.map((item) => item.kind), ["timer"]);

  const researchPlan = applyExplicitRequestRules(plan, "Research my assignment with Google searches");
  assert.equal(researchPlan.intentions[0].allowBrowserSearches, true);
  assert.deepEqual(researchPlan.intentions[0].restrictions.map((item) => item.kind), [
    "allowBrowserSearches",
    "timer",
  ]);
});

test("Gmail resolves to an installed browser and distracting resources receive friction", () => {
  const plan = {
    intentions: [{
      name: "Reply to messages",
      purpose: "Reply in Gmail",
      appBundleIdentifiers: ["com.apple.MobileSMS", "com.apple.mail"],
      websites: [],
      allowBrowserSearches: false,
      restrictions: [],
      frictions: [],
    }],
  };
  const installedApps = [
    { name: "Mail", bundleIdentifier: "com.apple.mail" },
    { name: "Messages", bundleIdentifier: "com.apple.MobileSMS" },
    { name: "Google Chrome", bundleIdentifier: "com.google.Chrome" },
  ];

  const gmailPlan = applyExplicitRequestRules(plan, "Reply to iMessages and Gmail", installedApps);
  assert.deepEqual(gmailPlan.intentions[0].appBundleIdentifiers, [
    "com.apple.MobileSMS",
    "com.google.Chrome",
  ]);
  assert.deepEqual(gmailPlan.intentions[0].websites, [{
    value: "mail.google.com",
    browserBundleIdentifier: "com.google.Chrome",
  }]);

  const instagramPlan = applyExplicitRequestRules(plan, "Reply to Instagram messages", installedApps);
  assert.equal(instagramPlan.intentions[0].frictions[0].kind, "reasonPrompt");
});

test("generation route rate limits by Cloudflare client address", async () => {
  let receivedKey;
  const response = await handlePlanRequest(new Request("https://intent.test/v1/intention-plans", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "203.0.113.7",
    },
    body: JSON.stringify(requestBody),
  }), {
    OPENROUTER_API_KEY: "test-key",
    INTENT_RATE_LIMITER: {
      limit: async ({ key }) => {
        receivedKey = key;
        return { success: false };
      },
    },
  });

  assert.equal(receivedKey, "203.0.113.7");
  assert.equal(response.status, 429);
});
