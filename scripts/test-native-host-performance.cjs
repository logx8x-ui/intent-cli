#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const hostPath = process.env.INTENT_NATIVE_HOST_PATH || path.join(root, ".build", "release", "IntentNativeHost");
const intentDir = fs.mkdtempSync(path.join(os.tmpdir(), "intent-native-host-perf-"));
const metricsPath = path.join(intentDir, "metrics.json");

function frame(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

assert.ok(fs.existsSync(hostPath), `Build IntentNativeHost first: missing ${hostPath}`);
fs.writeFileSync(path.join(intentDir, "browser-rules.json"), JSON.stringify({
  active: false,
  allowedWebsites: [],
  blockTabSwitching: false,
  blockNavigation: false,
  blockNewTabs: false,
  allowGoogleSearchTabs: false
}));

const messages = [{ type: "getRules", browserBundleIdentifier: "org.mozilla.firefox" }];
for (let index = 0; index < 50000; index += 1) {
  messages.push({ type: "heartbeat", browserBundleIdentifier: "org.mozilla.firefox" });
}
const snapshot = {
  type: "tabsSnapshot",
  browserBundleIdentifier: "org.mozilla.firefox",
  tabs: [{
    id: 1,
    windowID: 1,
    index: 0,
    title: "Instagram",
    url: "https://instagram.com/direct/inbox/",
    active: true
  }]
};
for (let index = 0; index < 100; index += 1) messages.push(snapshot);

try {
  const result = spawnSync("/usr/bin/time", ["-l", hostPath], {
    input: Buffer.concat(messages.map(frame)),
    env: {
      ...process.env,
      INTENT_NATIVE_HOST_DIRECTORY: intentDir,
      INTENT_NATIVE_HOST_METRICS_FILE: metricsPath
    },
    maxBuffer: 64 * 1024 * 1024
  });
  assert.equal(result.status, 0, result.stderr.toString());

  const metrics = JSON.parse(fs.readFileSync(metricsPath, "utf8"));
  assert.equal(metrics.receivedMessages, messages.length, "Host should process every stress message");
  assert.equal(metrics.sentMessages, 1, "Only getRules should produce a response");
  assert.ok(
    metrics.heartbeatWrites <= 4,
    `50,000 duplicate heartbeats should coalesce to at most four timed writes, got ${metrics.heartbeatWrites}`
  );
  assert.equal(metrics.snapshotWrites, 1, "Unchanged snapshots should be written only once");
  assert.equal(metrics.rulesReads, 1, "Unchanged rules should be decoded only once");

  const timeOutput = result.stderr.toString();
  const residentMatch = timeOutput.match(/(\d+)\s+maximum resident set size/);
  assert.ok(residentMatch, "macOS time output should report maximum resident memory");
  const residentBytes = Number(residentMatch[1]);
  assert.ok(residentBytes < 80 * 1024 * 1024, `Host peak RSS should stay under 80 MiB, got ${residentBytes}`);

  console.log(`Native host performance spec passed (peak RSS ${(residentBytes / 1024 / 1024).toFixed(1)} MiB)`);
} finally {
  fs.rmSync(intentDir, { recursive: true, force: true });
}
