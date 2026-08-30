#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const hostPath = process.env.INTENT_NATIVE_HOST_PATH || path.join(root, ".build", "release", "IntentNativeHost");
const intentDir = fs.mkdtempSync(path.join(os.tmpdir(), "intent-native-host-spec-"));
const rulesPath = path.join(intentDir, "browser-rules.json");
const snapshotPath = path.join(intentDir, "browser-tabs-com-google-Chrome.json");
const commandPath = path.join(intentDir, "browser-tab-command-com-google-Chrome.json");

function swiftReferenceDateNow() {
  return Date.now() / 1000 - 978307200;
}

function writeMessage(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function decodeMessages(buffer) {
  const messages = [];
  let offset = 0;
  while (offset + 4 <= buffer.length) {
    const length = buffer.readUInt32LE(offset);
    offset += 4;
    assert.ok(offset + length <= buffer.length, "Native host returned a complete framed message");
    messages.push(JSON.parse(buffer.subarray(offset, offset + length).toString()));
    offset += length;
  }
  assert.equal(offset, buffer.length, "Native host output should contain only framed messages");
  return messages;
}

function callHost(messages) {
  const result = spawnSync(hostPath, {
    input: Buffer.concat(messages.map(writeMessage)),
    env: { ...process.env, INTENT_NATIVE_HOST_DIRECTORY: intentDir }
  });
  assert.equal(result.status, 0, result.stderr.toString());
  return decodeMessages(result.stdout);
}

assert.ok(fs.existsSync(hostPath), `Build IntentNativeHost first: missing ${hostPath}`);

try {
  const activeRules = {
    active: true,
    accessMode: "blacklist",
    allowedWebsites: ["instagram.com/direct"],
    allowedWebsitesByBrowser: {
      "org.mozilla.firefox": ["instagram.com/direct"],
      "com.google.Chrome": ["youtube.com"]
    },
    startupWebsitesByBrowser: {
      "org.mozilla.firefox": ["https://www.instagram.com/direct/inbox/"],
      "com.google.Chrome": ["https://www.youtube.com/"]
    },
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: true,
    updatedAt: swiftReferenceDateNow()
  };
  fs.writeFileSync(rulesPath, JSON.stringify(activeRules));

  const [offResponse] = callHost([{ type: "setGuardEnabled", enabled: false }]);
  assert.equal(offResponse.guardEnabled, false, "Native host should persist guard off");

  const [rulesResponse] = callHost([{ type: "getRules" }]);
  assert.equal(rulesResponse.active, true, "Native host should return active app rules");
  assert.equal(rulesResponse.accessMode, "blacklist", "Native host should preserve browser access mode");
  assert.deepEqual(rulesResponse.allowedWebsites, activeRules.allowedWebsites);
  assert.deepEqual(rulesResponse.startupWebsites, activeRules.startupWebsitesByBrowser["org.mozilla.firefox"]);
  assert.equal(rulesResponse.guardEnabled, false, "Native host should include guard enabled state");

  fs.writeFileSync(rulesPath, JSON.stringify({ ...activeRules, updatedAt: 0 }));
  const [staleResponse] = callHost([{ type: "getRules" }]);
  assert.equal(staleResponse.active, false, "Native host should ignore stale active rules");

  const [onResponse] = callHost([{ type: "setGuardEnabled", enabled: true }]);
  assert.equal(onResponse.guardEnabled, true, "Native host should persist guard on");

  fs.writeFileSync(rulesPath, JSON.stringify(activeRules));
  const snapshotResponses = callHost([{
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
  }]);
  assert.equal(snapshotResponses.length, 0, "Snapshots should not generate unused native responses");
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  assert.equal(snapshot.browserBundleIdentifier, "com.google.Chrome");
  assert.equal(snapshot.tabs[0].id, 14, "Native host should persist allowed browser tabs for Ctrl+Tab");

  fs.writeFileSync(commandPath, JSON.stringify({
    id: "native-host-spec",
    tabID: 14,
    windowID: 3,
    createdAt: swiftReferenceDateNow()
  }));
  const [commandResponse] = callHost([{
    type: "getRules",
    browserBundleIdentifier: "com.google.Chrome"
  }]);
  assert.equal(commandResponse.tabCommand.tabID, 14, "Native host should deliver a pending tab switch command");
  assert.equal(fs.existsSync(commandPath), false, "A tab switch command should only be delivered once");

  console.log("Native host spec passed");
} finally {
  fs.rmSync(intentDir, { recursive: true, force: true });
}
