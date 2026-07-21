import assert from "node:assert/strict";
import test from "node:test";
import worker, { handlePlanRequest, openRouterRequest, validateRequest } from "../src/index.js";

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
});

test("generation route rejects a missing server key without forwarding", async () => {
  const response = await handlePlanRequest(new Request("https://intent.test/v1/intention-plans", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(requestBody),
  }), {});
  assert.equal(response.status, 503);
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
