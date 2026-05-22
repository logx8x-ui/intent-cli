#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const intentDir = path.join(os.homedir(), ".intent");
const rulesPath = path.join(intentDir, "browser-rules.json");
const statePath = path.join(intentDir, "browser-guard-state.json");
const hostPath = path.join(intentDir, "bin", "IntentNativeHost");
const inactiveRules = {
  active: false,
  allowedWebsites: [],
  blockTabSwitching: false,
  blockNavigation: false,
  blockNewTabs: false,
  allowGoogleSearchTabs: false
};

function swiftReferenceDateNow() {
  return Date.now() / 1000 - 978307200;
}

function readIfExists(filePath) {
  return fs.existsSync(filePath) ? fs.readFileSync(filePath) : null;
}

function writeMessage(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function callHost(message) {
  const result = spawnSync(hostPath, { input: writeMessage(message) });
  assert.equal(result.status, 0, result.stderr.toString());
  const length = result.stdout.readUInt32LE(0);
  return JSON.parse(result.stdout.subarray(4, 4 + length).toString());
}

fs.mkdirSync(intentDir, { recursive: true });
const originalRules = readIfExists(rulesPath);
const originalState = readIfExists(statePath);

try {
  const activeRules = {
    active: true,
    allowedWebsites: ["instagram.com/direct"],
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: true,
    updatedAt: swiftReferenceDateNow()
  };
  fs.writeFileSync(rulesPath, JSON.stringify(activeRules));

  const offResponse = callHost({ type: "setGuardEnabled", enabled: false });
  assert.equal(offResponse.guardEnabled, false, "Native host should persist guard off");

  const rulesResponse = callHost({ type: "getRules" });
  assert.equal(rulesResponse.active, true, "Native host should return active app rules");
  assert.deepEqual(rulesResponse.allowedWebsites, activeRules.allowedWebsites);
  assert.equal(rulesResponse.guardEnabled, false, "Native host should include guard enabled state");

  const staleRules = {
    active: true,
    allowedWebsites: ["instagram.com/direct"],
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: true
  };
  fs.writeFileSync(rulesPath, JSON.stringify(staleRules));
  const staleResponse = callHost({ type: "getRules" });
  assert.equal(staleResponse.active, false, "Native host should ignore stale active rules without a fresh Intent session");

  const onResponse = callHost({ type: "setGuardEnabled", enabled: true });
  assert.equal(onResponse.guardEnabled, true, "Native host should persist guard on");

  console.log("Native host spec passed");
} finally {
  if (originalRules) {
    fs.writeFileSync(rulesPath, originalRules);
  } else {
    fs.writeFileSync(rulesPath, JSON.stringify(inactiveRules));
  }

  if (originalState) {
    fs.writeFileSync(statePath, originalState);
  } else if (fs.existsSync(statePath)) {
    fs.rmSync(statePath);
  }
}
