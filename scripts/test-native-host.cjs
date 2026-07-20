#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const intentDir = path.join(os.homedir(), ".intent");
const rulesPath = path.join(intentDir, "browser-rules.json");
const statePath = path.join(intentDir, "browser-guard-state.json");
const snapshotPath = path.join(intentDir, "browser-tabs-com-google-Chrome.json");
const commandPath = path.join(intentDir, "browser-tab-command-com-google-Chrome.json");
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
const originalSnapshot = readIfExists(snapshotPath);
const originalCommand = readIfExists(commandPath);

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

  fs.writeFileSync(rulesPath, JSON.stringify(activeRules));
  const snapshotResponse = callHost({
    type: "tabsSnapshot",
    browserBundleIdentifier: "com.google.Chrome",
    tabs: [{
      id: 14,
      windowID: 3,
      index: 1,
      title: "Instagram",
      url: "https://instagram.com/direct/inbox/",
      active: true
    }]
  });
  assert.equal(snapshotResponse.active, true, "Tab snapshots should receive current rules");
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  assert.equal(snapshot.browserBundleIdentifier, "com.google.Chrome");
  assert.equal(snapshot.tabs[0].id, 14, "Native host should persist allowed browser tabs for Ctrl+Tab");

  fs.writeFileSync(commandPath, JSON.stringify({
    id: "native-host-spec",
    tabID: 14,
    windowID: 3,
    createdAt: swiftReferenceDateNow()
  }));
  const commandResponse = callHost({
    type: "getRules",
    browserBundleIdentifier: "com.google.Chrome"
  });
  assert.equal(commandResponse.tabCommand.tabID, 14, "Native host should deliver a pending tab switch command");
  assert.equal(fs.existsSync(commandPath), false, "A tab switch command should only be delivered once");

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

  if (originalSnapshot) {
    fs.writeFileSync(snapshotPath, originalSnapshot);
  } else if (fs.existsSync(snapshotPath)) {
    fs.rmSync(snapshotPath);
  }

  if (originalCommand) {
    fs.writeFileSync(commandPath, originalCommand);
  } else if (fs.existsSync(commandPath)) {
    fs.rmSync(commandPath);
  }
}
