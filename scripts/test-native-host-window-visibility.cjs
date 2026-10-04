#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");

const host = process.env.INTENT_NATIVE_HOST_PATH || path.resolve(__dirname, "../.build/release/IntentNativeHost");
const capability = "native-window-visibility-v1", session = "visibility-intention", profile = "visibility-profile";
const directories = [];
const simulatedQAIdentity = { pid: process.pid, launched: 1 };
let qaHost;
const now = () => Date.now() / 1000 - 978307200;
function temporaryDirectory() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "intent-qa-native-visibility-spec-"));
  fs.chmodSync(directory, 0o700);
  fs.writeFileSync(path.join(directory, ".intent-qa-root"), "Intent isolated QA data v1\n", { mode: 0o600 });
  directories.push(directory); return directory;
}
function rules(overrides = {}) {
  return { active: true, hideDistractions: true, nativeWindowVisibility: true,
    accessMode: "whitelist", allowedWebsites: [], startupSessionID: session,
    blockTabSwitching: true, blockNavigation: true, blockNewTabs: true, updatedAt: now(), ...overrides };
}
function writeRules(directory, overrides = {}) {
  fs.writeFileSync(path.join(directory, "browser-rules.json"), JSON.stringify(rules(overrides)));
}
function connect(browser, overrides = {}) {
  return { type: "getRules", browserBundleIdentifier: browser, browserSessionID: profile,
    extensionCapabilities: [capability], ...overrides };
}
function windowDescriptor(windowID, title = `Window ${windowID}`) {
  return { windowID, title, frame: { left: 30, top: 50, width: 900, height: 700 }, state: "normal" };
}
function plan(revision = 1, overrides = {}) {
  return { intentionSessionID: session, revision, windows: [windowDescriptor(11)],
    parkingWindows: [], revealWindowIDs: [], ...overrides };
}
function request(browser, visibilityPlan = plan(), overrides = {}) {
  return { type: "windowVisibilityPlan", browserBundleIdentifier: browser,
    browserSessionID: profile, visibilityPlan, ...overrides };
}
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length); return Buffer.concat([header, body]);
}
function decode(buffer) {
  const messages = []; let offset = 0;
  while (offset + 4 <= buffer.length) {
    const length = buffer.readUInt32LE(offset); offset += 4;
    assert.ok(offset + length <= buffer.length, "Host frames must be complete");
    messages.push(JSON.parse(buffer.subarray(offset, offset + length))); offset += length;
  }
  assert.equal(offset, buffer.length, "Only framed responses may reach stdout"); return messages;
}
function hostEnvironment(directory, production = false, overrides = {}) {
  const environment = { ...process.env, INTENT_NATIVE_HOST_DIRECTORY: directory };
  delete environment.INTENT_QA_ROOT; delete environment.INTENT_QA_BROWSER_PROCESS_IDENTITY;
  if (!production) {
    environment.INTENT_QA_ROOT = directory;
    environment.INTENT_QA_BROWSER_PROCESS_IDENTITY = JSON.stringify(simulatedQAIdentity);
  }
  return { ...environment, ...overrides };
}
function call(directory, messages, { production = false, environment = {} } = {}) {
  const result = spawnSync(production ? host : qaHost, { input: Buffer.concat(messages.map(frame)),
    env: hostEnvironment(directory, production, environment), maxBuffer: 8 * 1024 * 1024, timeout: 10_000 });
  assert.equal(result.status, 0, String(result.stderr || result.error)); return decode(result.stdout);
}
const callProduction = (directory, messages, environment = {}) => call(directory, messages, { production: true, environment });
function recordPath(directory, browser, browserProfile = profile, intention = session) {
  const identity = `${Buffer.byteLength(browserProfile)}:${browserProfile}${intention}`;
  const suffix = crypto.createHash("sha256").update(identity).digest("hex").slice(0, 24);
  return path.join(directory, `browser-window-visibility-${browser.replace(/[^a-zA-Z0-9]/g, "-")}.profile-${suffix}.json`);
}
function readRecord(directory, browser, browserProfile = profile, intention = session) {
  return JSON.parse(fs.readFileSync(recordPath(directory, browser, browserProfile, intention)));
}
function heartbeat(directory, browser) {
  const suffix = browser === "org.mozilla.firefox" ? "" : `-${browser.replace(/[^a-zA-Z0-9]/g, "-")}`;
  return JSON.parse(fs.readFileSync(path.join(directory, `browser-guard-heartbeat${suffix}.json`)));
}
function assertReceipt(messages, revision, accepted, reason) {
  const receipt = messages.findLast(message => message.visibilityPlanReceipt)?.visibilityPlanReceipt;
  assert.deepEqual(receipt, { revision, accepted }, reason);
}
function restartRequest(browser, overrides = {}, outer = {}) {
  return { type: "windowVisibilityRestartRecovery", browserBundleIdentifier: browser,
    browserSessionID: "restarted-profile", visibilityRestartRequest: {
      requestID: "restart-request", intentionSessionID: session, previousBrowserSessionID: profile,
      previousProcessIdentity: { pid: process.pid, launched: 1 }, ...overrides
    }, ...outer };
}
function assertRestartDenied(messages, requestID, reason) {
  const receipt = messages.findLast(message => message.visibilityRestartReceipt)?.visibilityRestartReceipt;
  assert.deepEqual(receipt, { requestID, accepted: false }, reason);
}
function nativeRecoveryRequest(browser, overrides = {}, outer = {}) {
  return { type: "windowVisibilityRecovery", browserBundleIdentifier: browser,
    browserSessionID: "reloaded-profile", visibilityRecoveryRequest: {
      requestID: "native-recovery-request", intentionSessionID: session, previousBrowserSessionID: profile,
      previousProcessIdentity: { pid: process.pid, launched: 1 }, windowIDs: [21], ...overrides
    }, ...outer };
}
function rejectedCase(browser, label, { ruleOverrides = {}, registration = {}, message = request(browser) } = {}) {
  const directory = temporaryDirectory(); writeRules(directory, ruleOverrides);
  const responses = call(directory, [connect(browser, registration), message], { production: label.startsWith("Malformed") });
  assertReceipt(responses, message.visibilityPlan.revision, false, label);
  assert.deepEqual(fs.readdirSync(directory).filter(file => file.startsWith("browser-window-visibility-") && file.endsWith(".json")), [],
    `${label}: rejected plans cannot be persisted`);
  return responses;
}

function checkBrowser(browser) {
  const directory = temporaryDirectory(); writeRules(directory);
  const replies = call(directory, [connect(browser), request(browser)]);
  assert.equal(replies[0].nativeWindowVisibility, true);
  assert.deepEqual(replies[0].browserProcessIdentity, simulatedQAIdentity, "Protocol fixture identity is explicitly QA simulated");
  assert.ok(heartbeat(directory, browser).capabilities.includes(capability), "Verified QA identity and negotiated capability advertise readiness");
  assert.ok(replies[0].hostCapabilities.includes("native-window-visibility-host-v1"));
  assertReceipt(replies, 1, true, "No-parking plans acknowledge durable acceptance immediately");
  const saved = readRecord(directory, browser);
  assert.equal(saved.browserBundleIdentifier, browser); assert.equal(saved.browserSessionID, profile);
  assert.deepEqual(saved.plan, plan()); assert.ok(saved.receivedAt > now() - 10);
  assert.equal(fs.statSync(recordPath(directory, browser)).mode & 0o777, 0o600);
  const originalBytes = fs.readFileSync(recordPath(directory, browser), "utf8");
  for (const item of [plan(0), plan(1, { windows: [windowDescriptor(12)] })]) {
    writeRules(directory);
    assertReceipt(call(directory, [connect(browser), request(browser, item)]), item.revision, false,
      "Restarted hosts cannot roll back or change an accepted revision");
    assert.equal(fs.readFileSync(recordPath(directory, browser), "utf8"), originalBytes);
  }
  writeRules(directory);
  assertReceipt(call(directory, [connect(browser), request(browser)]), 1, true, "Identical retries are idempotent");
  assert.equal(fs.readFileSync(recordPath(directory, browser), "utf8"), originalBytes);
  assertReceipt(call(directory, [connect(browser), request(browser, plan(2, { windows: [] }))]), 2, true);
  assert.deepEqual(readRecord(directory, browser).plan.windows, []);
  const otherProfile = "other-profile";
  assertReceipt(call(directory, [connect(browser, { browserSessionID: otherProfile }),
    request(browser, plan(), { browserSessionID: otherProfile })]), 1, true);
  assert.equal(readRecord(directory, browser).plan.revision, 2);
  assert.equal(readRecord(directory, browser, otherProfile).plan.revision, 1);
  const otherSession = "other-intention"; writeRules(directory, { startupSessionID: otherSession });
  assertReceipt(call(directory, [connect(browser), request(browser, plan(1, { intentionSessionID: otherSession }))]), 1, true);
  assert.equal(readRecord(directory, browser).plan.revision, 2, "New intentions cannot overwrite earlier durable plans");
  assert.equal(readRecord(directory, browser, profile, otherSession).plan.revision, 1);

  for (const ruleOverrides of [{ nativeWindowVisibility: undefined }, { nativeWindowVisibility: false },
    { hideDistractions: false }, { active: false }, { updatedAt: 0 }, { startupSessionID: undefined }]) {
    assert.equal(rejectedCase(browser, `No grant ${JSON.stringify(ruleOverrides)}`, { ruleOverrides })[0].nativeWindowVisibility, false);
  }
  for (const registration of [{ extensionCapabilities: [] }, { browserSessionID: undefined }]) {
    assert.equal(rejectedCase(browser, "Missing capability or profile", { registration })[0].nativeWindowVisibility, true,
      "Required native ownership cannot downgrade during an incomplete handshake");
  }
  for (const [label, message] of [
    ["Wrong intention", request(browser, plan(1, { intentionSessionID: "old-intention" }))],
    ["Wrong profile", request(browser, plan(), { browserSessionID: "wrong-profile" })],
    ["Missing profile", request(browser, plan(), { browserSessionID: undefined })],
    ["Missing browser", request(browser, plan(), { browserBundleIdentifier: undefined })],
    ["Wrong browser", request(browser, plan(), { browserBundleIdentifier: browser === "com.google.Chrome" ? "org.mozilla.firefox" : "com.google.Chrome" })]
  ]) rejectedCase(browser, label, { message });
  rejectedCase(browser, "Plan cannot self-register capability", { registration: { extensionCapabilities: [] },
    message: request(browser, plan(), { extensionCapabilities: [capability] }) });
  rejectedCase(browser, "Overlong profile", { registration: { browserSessionID: "p".repeat(257) },
    message: request(browser, plan(), { browserSessionID: "p".repeat(257) }) });
  for (const [label, invalid] of [
    ["Negative revision", plan(-1)], ["Unsafe revision", plan(Number.MAX_SAFE_INTEGER + 1)],
    ["Negative ID", plan(1, { windows: [windowDescriptor(-1)] })],
    ["Unsafe ID", plan(1, { windows: [windowDescriptor(Number.MAX_SAFE_INTEGER + 1)] })],
    ["Duplicate IDs", plan(1, { windows: [windowDescriptor(11), windowDescriptor(11)] })],
    ["Cross-role duplicate IDs", plan(1, { parkingWindows: [windowDescriptor(11)] })],
    ["Too many windows", plan(1, { windows: Array.from({ length: 257 }, (_, id) => windowDescriptor(id)) })],
    ["Blank title", plan(1, { windows: [windowDescriptor(11, " ")] })],
    ["Overlong title", plan(1, { windows: [windowDescriptor(11, "a".repeat(4097))] })],
    ["Invalid state", plan(1, { windows: [{ ...windowDescriptor(11), state: "closed" }] })],
    ["Invalid frame", plan(1, { windows: [{ ...windowDescriptor(11), frame: { left: 0, top: 0, width: -1, height: 700 } }] })],
    ["Malformed descriptor", plan(1, { windows: [{ windowID: 11 }] })],
    ["Unknown reveal", plan(1, { revealWindowIDs: [999] })]
  ]) rejectedCase(browser, label, { message: request(browser, invalid) });
  rejectedCase(browser, "Oversized message", { message: request(browser, plan(), { padding: "p".repeat(1_000_000) }) });
  const unregistered = temporaryDirectory(); writeRules(unregistered);
  assertReceipt(call(unregistered, [request(browser, plan(), { extensionCapabilities: [capability] })]), 1, false);
  writeRules(directory);
  assertReceipt(call(directory, [connect(browser), connect(browser, { browserSessionID: "swapped-profile" }),
    request(browser, plan(3), { browserSessionID: "swapped-profile" })]), 3, false, "Connection profile is pinned");
}

async function until(predicate, message, timeout = 4000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(message);
}
async function withLiveHost(browser, body) {
  const directory = temporaryDirectory(); writeRules(directory);
  const child = spawn(qaHost, { env: hostEnvironment(directory) });
  const replies = []; let pending = Buffer.alloc(0);
  child.stdout.on("data", chunk => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
      const length = pending.readUInt32LE(0);
      replies.push(JSON.parse(pending.subarray(4, 4 + length))); pending = pending.subarray(4 + length);
    }
  });
  child.stderr.resume();
  const send = message => child.stdin.write(frame(message));
  try {
    send(connect(browser)); await until(() => replies.some(reply => reply.nativeWindowVisibility), "Initial grant missing");
    await body({ directory, child, replies, send });
  } finally {
    child.kill("SIGCONT"); child.stdin.end();
    await new Promise(resolve => {
      if (child.exitCode !== null) return resolve();
      child.once("exit", resolve); setTimeout(() => { child.kill(); resolve(); }, 1000).unref();
    });
  }
}
function writeCapture(directory, browser, windowIDs, overrides = {}) {
  const receipt = { browserBundleIdentifier: browser, browserSessionID: profile,
    intentionSessionID: session, windowIDs, ...overrides };
  fs.writeFileSync(recordPath(directory, browser) + ".capture", JSON.stringify(receipt), { mode: 0o600 });
}
async function checkCaptureAndFinish(browser) {
  await withLiveHost(browser, async ({ directory, replies, send }) => {
    const parking = [windowDescriptor(21, "Intent parking")];
    send(request(browser, plan(1, { parkingWindows: parking })));
    await until(() => fs.existsSync(recordPath(directory, browser)), "Plan not persisted before capture");
    assert.equal(replies.some(reply => reply.visibilityPlanReceipt), false, "Persistence alone cannot grant tab moves");
    writeCapture(directory, browser, [21], { browserSessionID: "wrong-profile" });
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(replies.some(reply => reply.visibilityPlanReceipt), false, "Capture must match the registered profile");
    writeCapture(directory, browser, [21]);
    await until(() => replies.some(reply => reply.visibilityPlanReceipt?.revision === 1), "Captured plan was not acknowledged");
    assertReceipt(replies, 1, true);
    writeRules(directory, { active: false });
    send(request(browser, plan(2, { parkingWindows: parking, revealWindowIDs: [21] })));
    await until(() => replies.some(reply => reply.visibilityPlanReceipt?.revision === 2), "Finish reveal ACK missing");
    assertReceipt(replies, 2, true);
    assert.deepEqual(readRecord(directory, browser).plan.revealWindowIDs, [21]);
    for (const mutation of [{ parkingWindows: [windowDescriptor(22)], revealWindowIDs: [22] },
      { windows: [windowDescriptor(12)], parkingWindows: parking, revealWindowIDs: [21] }]) {
      assertReceipt(call(directory, [connect(browser), request(browser, plan(3, mutation))]), 3, false,
        "Inactive reveal cannot change registered identities");
    }
    writeRules(directory, { startupSessionID: "next-intention" });
    assertReceipt(call(directory, [connect(browser), request(browser, plan(1, { intentionSessionID: "next-intention" }))]), 1, true);
    assertReceipt(call(directory, [connect(browser), request(browser, plan(3, { parkingWindows: parking, revealWindowIDs: [21] }))]), 3, true,
      "Prior frozen reveal survives a different active intention");
    assert.equal(readRecord(directory, browser, profile, "next-intention").plan.revision, 1);
    assert.equal(readRecord(directory, browser).plan.revision, 3);
  });
  await withLiveHost(browser, async ({ directory, replies, send }) => {
    const started = Date.now(); send(request(browser, plan(1, { parkingWindows: [windowDescriptor(21)] })));
    send(connect(browser));
    await until(() => replies.filter(reply => !reply.visibilityPlanReceipt).length >= 2,
      "Capture wait must not block subsequent requests");
    await until(() => replies.some(reply => reply.visibilityPlanReceipt), "Missing bounded capture timeout", 2500);
    assertReceipt(replies, 1, false); assert.ok(Date.now() - started < 2200, "Capture timeout stays below extension timeout");
    assert.ok(fs.existsSync(recordPath(directory, browser)), "Timeout retains durable registration for retry");
    writeCapture(directory, browser, [21]); send(request(browser, plan(1, { parkingWindows: [windowDescriptor(21)] })));
    await until(() => replies.some(reply => reply.visibilityPlanReceipt?.accepted), "Captured identical retry was not accepted");
    assertReceipt(replies, 1, true);
  });
  await withLiveHost(browser, async ({ directory, replies, send }) => {
    send(request(browser, plan(1, { parkingWindows: [windowDescriptor(21)] })));
    await until(() => fs.existsSync(recordPath(directory, browser)), "Pending parking plan missing");
    writeRules(directory, { active: false }); writeCapture(directory, browser, [21]);
    await until(() => replies.some(reply => reply.visibilityPlanReceipt), "Stopped pending registration ACK missing");
    assertReceipt(replies, 1, false, "Finish during capture cannot permit a subsequent tab move");
  });
  await withLiveHost(browser, async ({ directory, replies, send }) => {
    send(request(browser, plan(1, { parkingWindows: [windowDescriptor(21)] })));
    await until(() => fs.existsSync(recordPath(directory, browser)), "Pending negotiation plan missing");
    send(connect(browser, { type: "heartbeat", extensionCapabilities: [] }));
    await until(() => !heartbeat(directory, browser).capabilities.includes(capability), "Readiness revocation heartbeat missing");
    writeCapture(directory, browser, [21]);
    await until(() => replies.some(reply => reply.visibilityPlanReceipt), "Negotiation loss ACK missing");
    assertReceipt(replies, 1, false, "Capture ACK still requires negotiated readiness");
    assert.equal(replies.at(-1).nativeWindowVisibility, true, "Readiness loss keeps native ownership required");
    assert.ok(!heartbeat(directory, browser).capabilities.includes(capability));
  });
}
function checkNegotiatedReadiness(browser) {
  const directory = temporaryDirectory(); writeRules(directory);
  const otherCapability = "tab-preview-v1";
  const initial = call(directory, [connect(browser, { extensionCapabilities: [otherCapability] }), request(browser)]);
  assert.equal(initial[0].nativeWindowVisibility, true);
  assert.ok(initial[0].hostCapabilities.includes("native-window-visibility-host-v1"), "Host protocol capability avoids negotiation circularity");
  assert.deepEqual(initial[0].browserProcessIdentity, simulatedQAIdentity);
  assertReceipt(initial, 1, false, "Initial non-negotiated plans cannot be accepted");
  assert.deepEqual(heartbeat(directory, browser).capabilities, [otherCapability]);
  const negotiated = call(directory, [connect(browser, { extensionCapabilities: [otherCapability] }),
    connect(browser, { type: "heartbeat", extensionCapabilities: [otherCapability, capability] }), request(browser)]);
  assertReceipt(negotiated, 1, true);
  assert.ok(heartbeat(directory, browser).capabilities.includes(capability), "Negotiated capability upgrades immediately, including message bursts");
  const revoked = call(directory, [connect(browser, { extensionCapabilities: [otherCapability, capability] }),
    connect(browser, { type: "heartbeat", extensionCapabilities: [otherCapability] }), request(browser, plan(2))]);
  assertReceipt(revoked, 2, false);
  assert.equal(revoked.at(-1).nativeWindowVisibility, true, "Negotiation revocation cannot select legacy restoration");
  assert.deepEqual(heartbeat(directory, browser).capabilities, [otherCapability], "Readiness filtering preserves other capabilities");
  assert.equal(readRecord(directory, browser).plan.revision, 1);
}
async function checkRuleRefresh() {
  await withLiveHost("org.mozilla.firefox", async ({ directory, child, replies, send }) => {
    for (const [revision, overrides] of [[1, { active: false }], [2, { startupSessionID: "replacement-intention" }]]) {
      child.kill("SIGSTOP"); writeRules(directory, overrides); send(request("org.mozilla.firefox", plan(revision))); child.kill("SIGCONT");
      await until(() => replies.some(reply => reply.visibilityPlanReceipt?.revision === revision), "Refreshed-rule rejection missing");
      assertReceipt(replies, revision, false, "Refresh rules before validating messages that beat directory debounce");
      assert.equal(fs.existsSync(recordPath(directory, "org.mozilla.firefox")), false);
    }
  });
}
function checkRestartDenials(browser) {
  const directory = temporaryDirectory(); writeRules(directory);
  const initial = callProduction(directory, [connect(browser), request(browser)]);
  assertReceipt(initial, 1, false, "Production host refuses new ownership without verified process proof");
  assert.equal(initial[0].nativeWindowVisibility, true,
    "Required native mode remains exclusive when proof is unavailable");
  assert.ok(!heartbeat(directory, browser).capabilities.includes(capability),
    "An unverified production parent cannot pass native-readiness preflight");
  assert.equal(initial[0].browserProcessIdentity, undefined,
    "Node parent must not be represented as a verified browser process");
  assert.equal(fs.existsSync(recordPath(directory, browser)), false,
    "Missing parent proof cannot poison an immutable ownership record");
  assertReceipt(call(directory, [connect(browser), request(browser)]), 1, true, "Seed isolated QA ownership fixture");
  const legacy = readRecord(directory, browser); delete legacy.browserProcessIdentity;
  fs.writeFileSync(recordPath(directory, browser), JSON.stringify(legacy));
  writeRules(directory, { active: false });
  const registration = connect(browser, { browserSessionID: "restarted-profile" });
  assertRestartDenied(callProduction(directory, [registration, restartRequest(browser)]), "restart-request",
    "Legacy records without process proof cannot permit browser restart recovery");

  // Trusted-file fixtures exercise negative framing only. They cannot create
  // a verified AppKit browser parent, and there is no production test override.
  const file = recordPath(directory, browser);
  const saved = readRecord(directory, browser);
  saved.browserProcessIdentity = { pid: process.pid, launched: 1 };
  fs.writeFileSync(file, JSON.stringify(saved));
  const before = fs.readFileSync(file, "utf8");
  for (const [label, message, registrationOverride = {}] of [
    ["No verified current parent", restartRequest(browser)],
    ["Same browser session", restartRequest(browser, {}, { browserSessionID: profile }), { browserSessionID: profile }],
    ["Wrong current profile", restartRequest(browser, {}, { browserSessionID: "wrong-profile" })],
    ["Missing current profile", restartRequest(browser, {}, { browserSessionID: undefined })],
    ["Wrong browser", restartRequest(browser, {}, { browserBundleIdentifier: "com.apple.Safari" })],
    ["Wrong previous intention", restartRequest(browser, { intentionSessionID: "unregistered-intention" })],
    ["Wrong previous profile", restartRequest(browser, { previousBrowserSessionID: "unregistered-profile" })],
    ["Wrong previous process", restartRequest(browser, { previousProcessIdentity: { pid: process.pid, launched: 2 } })],
    ["Invalid previous process", restartRequest(browser, { previousProcessIdentity: { pid: -1, launched: 1 } })],
    ["Malformed previous process", restartRequest(browser, { previousProcessIdentity: { pid: process.pid } })],
    ["Missing capabilities", restartRequest(browser), { extensionCapabilities: [] }],
    ["Client-supplied current proof ignored", restartRequest(browser, {}, { browserProcessIdentity: { pid: process.pid, launched: 2 } })],
    ["Oversized request", restartRequest(browser, {}, { padding: "x".repeat(16_384) })]
  ]) {
    const replies = callProduction(directory, [{ ...registration, ...registrationOverride }, message]);
    assertRestartDenied(replies, message.visibilityRestartRequest.requestID, label);
    assert.equal(replies[0].browserProcessIdentity, undefined, `${label}: no fabricated parent identity`);
    assert.equal(fs.readFileSync(file, "utf8"), before, `${label}: permission checks cannot mutate ownership`);
  }
  assertRestartDenied(callProduction(directory, [restartRequest(browser, {}, { extensionCapabilities: [capability] })]), "restart-request",
    "Recovery request cannot establish its own connection capability");
  for (const ruleOverrides of [{ active: true }, { updatedAt: 0 }]) {
    writeRules(directory, ruleOverrides);
    assertRestartDenied(callProduction(directory, [registration, restartRequest(browser)]), "restart-request",
      "Active or expired rules never substitute for verified browser restart evidence");
  }
}
function checkNativeRecoveryDenials(browser) {
  const directory = temporaryDirectory(); writeRules(directory);
  assertReceipt(call(directory, [connect(browser), request(browser)]), 1, true);
  const file = recordPath(directory, browser), saved = readRecord(directory, browser);
  saved.browserProcessIdentity = { pid: process.pid, launched: 1 };
  saved.registeredParkingWindows = [windowDescriptor(21)];
  fs.writeFileSync(file, JSON.stringify(saved)); writeCapture(directory, browser, [21]);
  writeRules(directory, { active: false });
  const before = fs.readFileSync(file, "utf8");
  const registration = connect(browser, { browserSessionID: "reloaded-profile" });
  for (const [label, message, registrationOverride = {}] of [
    ["No verified current browser parent", nativeRecoveryRequest(browser)],
    ["Wrong current profile", nativeRecoveryRequest(browser, {}, { browserSessionID: "wrong-profile" })],
    ["Wrong browser", nativeRecoveryRequest(browser, {}, { browserBundleIdentifier: "com.apple.Safari" })],
    ["Wrong previous profile", nativeRecoveryRequest(browser, { previousBrowserSessionID: "unregistered-profile" })],
    ["Wrong previous process", nativeRecoveryRequest(browser, { previousProcessIdentity: { pid: process.pid, launched: 2 } })],
    ["Malformed process", nativeRecoveryRequest(browser, { previousProcessIdentity: { pid: process.pid } })],
    ["Missing capabilities", nativeRecoveryRequest(browser), { extensionCapabilities: [] }],
    ["Unknown parking ID", nativeRecoveryRequest(browser, { windowIDs: [999] })],
    ["Empty parking IDs", nativeRecoveryRequest(browser, { windowIDs: [] })],
    ["Duplicate parking IDs", nativeRecoveryRequest(browser, { windowIDs: [21, 21] })],
    ["Malformed parking IDs", nativeRecoveryRequest(browser, { windowIDs: ["invalid"] })],
    ["Too many parking IDs", nativeRecoveryRequest(browser, { windowIDs: Array.from({ length: 257 }, (_, id) => id) })],
    ["Oversized recovery request", nativeRecoveryRequest(browser, {}, { padding: "x".repeat(16_384) })]
  ]) {
    const responses = callProduction(directory, [{ ...registration, ...registrationOverride }, message]);
    const receipt = responses.findLast(reply => reply.visibilityRecoveryReceipt)?.visibilityRecoveryReceipt;
    assert.deepEqual(receipt, { requestID: "native-recovery-request", accepted: false }, label);
    assert.ok(responses.every(reply => !reply.visibilityRestartReceipt), "Native recovery is separate from browser-restore permission");
    assert.equal(fs.readFileSync(file, "utf8"), before, `${label}: denial preserves registered ownership`);
  }
  for (const ruleOverrides of [{ active: true }, { active: true, startupSessionID: "different-active-intention" }]) {
    writeRules(directory, ruleOverrides);
    const replies = callProduction(directory, [registration, nativeRecoveryRequest(browser)]);
    assert.deepEqual(replies.at(-1).visibilityRecoveryReceipt, { requestID: "native-recovery-request", accepted: false },
      "Neither active-rule state supplies missing current-process proof");
  }
}
function nativeClosedRequest(browser, overrides = {}, outer = {}) {
  return { type: "windowVisibilityClosed", browserBundleIdentifier: browser,
    browserSessionID: "reloaded-profile", visibilityClosedRequest: {
      requestID: "native-closed-request", intentionSessionID: session, previousBrowserSessionID: profile,
      previousProcessIdentity: simulatedQAIdentity, windowIDs: [21], ...overrides
    }, ...outer };
}
function assertClosedReceipt(messages, requestID, accepted, reason) {
  const receipt = messages.findLast(reply => reply.visibilityClosedReceipt)?.visibilityClosedReceipt;
  assert.deepEqual(receipt, { requestID, accepted }, reason);
  assert.ok(messages.every(reply => !reply.visibilityRecoveryReceipt && !reply.visibilityRestartReceipt),
    "Closure acknowledgment is not a native reveal or browser restoration permission");
}
function checkNativeClosure(browser) {
  const directory = temporaryDirectory(); writeRules(directory);
  assertReceipt(call(directory, [connect(browser), request(browser)]), 1, true);
  const file = recordPath(directory, browser), saved = readRecord(directory, browser);
  saved.registeredParkingWindows = [windowDescriptor(21), windowDescriptor(22)];
  fs.writeFileSync(file, JSON.stringify(saved)); writeCapture(directory, browser, [21]);
  const registration = connect(browser, { browserSessionID: "reloaded-profile" });
  const original = fs.readFileSync(file, "utf8");
  for (const [label, message, registrationOverride = {}] of [
    ["Wrong current profile", nativeClosedRequest(browser, {}, { browserSessionID: "wrong-profile" })],
    ["Missing current profile", nativeClosedRequest(browser, {}, { browserSessionID: undefined })],
    ["Wrong browser", nativeClosedRequest(browser, {}, { browserBundleIdentifier: "com.apple.Safari" })],
    ["Missing browser", nativeClosedRequest(browser, {}, { browserBundleIdentifier: undefined })],
    ["Wrong previous profile", nativeClosedRequest(browser, { previousBrowserSessionID: "unregistered-profile" })],
    ["Wrong intention", nativeClosedRequest(browser, { intentionSessionID: "unregistered-intention" })],
    ["Wrong previous process", nativeClosedRequest(browser, { previousProcessIdentity: { pid: process.pid, launched: 2 } })],
    ["Malformed process", nativeClosedRequest(browser, { previousProcessIdentity: { pid: process.pid } })],
    ["Invalid process", nativeClosedRequest(browser, { previousProcessIdentity: { pid: -1, launched: 1 } })],
    ["Missing capability", nativeClosedRequest(browser), { extensionCapabilities: [] }],
    ["Cannot self-register capability", nativeClosedRequest(browser, {}, { extensionCapabilities: [capability] }), { extensionCapabilities: [] }],
    ["Blank request ID", nativeClosedRequest(browser, { requestID: " " })],
    ["Overlong request ID", nativeClosedRequest(browser, { requestID: "r".repeat(257) })],
    ["Ordinary window", nativeClosedRequest(browser, { windowIDs: [11] })],
    ["Uncaptured parking", nativeClosedRequest(browser, { windowIDs: [22] })],
    ["Unknown parking ID", nativeClosedRequest(browser, { windowIDs: [999] })],
    ["Partly unknown parking IDs", nativeClosedRequest(browser, { windowIDs: [21, 999] })],
    ["Empty parking IDs", nativeClosedRequest(browser, { windowIDs: [] })],
    ["Duplicate parking IDs", nativeClosedRequest(browser, { windowIDs: [21, 21] })],
    ["Malformed parking IDs", nativeClosedRequest(browser, { windowIDs: ["invalid"] })],
    ["Negative parking ID", nativeClosedRequest(browser, { windowIDs: [-1] })],
    ["Unsafe parking ID", nativeClosedRequest(browser, { windowIDs: [Number.MAX_SAFE_INTEGER + 1] })],
    ["Too many parking IDs", nativeClosedRequest(browser, { windowIDs: Array.from({ length: 257 }, (_, id) => id) })],
    ["Oversized closure request", nativeClosedRequest(browser, {}, { padding: "x".repeat(16_384) })]
  ]) {
    assertClosedReceipt(call(directory, [{ ...registration, ...registrationOverride }, message]),
      message.visibilityClosedRequest.requestID, false, label);
    assert.equal(fs.readFileSync(file, "utf8"), original, `${label}: denial preserves registered ownership`);
  }
  assertClosedReceipt(call(directory, [nativeClosedRequest(browser, {}, { extensionCapabilities: [capability] })]),
    "native-closed-request", false, "Closure cannot register its own connection identity");
  assertClosedReceipt(call(directory, [registration, connect(browser, { browserSessionID: "swapped-profile" }),
    nativeClosedRequest(browser, {}, { browserSessionID: "swapped-profile" })]),
    "native-closed-request", false, "Closure cannot replace an authenticated connection profile");
  const changedProcess = { INTENT_QA_BROWSER_PROCESS_IDENTITY: JSON.stringify({ pid: process.pid, launched: 2 }) };
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser)], { environment: changedProcess }),
    "native-closed-request", false, "Different verified process cannot close earlier ownership");
  assertClosedReceipt(callProduction(directory, [registration, nativeClosedRequest(browser)], {
    INTENT_QA_ROOT: directory, INTENT_QA_BROWSER_PROCESS_IDENTITY: JSON.stringify(simulatedQAIdentity)
  }), "native-closed-request", false, "Production host requires a real verified browser parent");
  const proofless = { ...saved }; delete proofless.browserProcessIdentity;
  fs.writeFileSync(file, JSON.stringify(proofless));
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser)]),
    "native-closed-request", false, "Legacy proofless record cannot gain closure authority");
  fs.writeFileSync(file, original);
  const blockedLock = file + ".lock";
  fs.rmSync(blockedLock); fs.mkdirSync(blockedLock);
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser)]),
    "native-closed-request", false, "A failed lock/write cannot acknowledge closure");
  assert.equal(fs.readFileSync(file, "utf8"), original, "Failed closure persistence retains prior ownership");
  fs.rmdirSync(blockedLock);
  // A confirmed empty holder can close while this exact intention is still active.
  assertClosedReceipt(call(directory, [connect(browser), nativeClosedRequest(browser, {}, { browserSessionID: profile })]),
    "native-closed-request", true, "Exact current session can retire captured parking, without relaxing active rules");
  const closed = readRecord(directory, browser);
  assert.deepEqual(closed.closedParkingWindowIDs, [21]);
  assert.deepEqual(closed.plan, saved.plan, "Closure does not advance a plan revision");
  assert.deepEqual(closed.registeredParkingWindows, saved.registeredParkingWindows);
  assert.deepEqual(closed.requestedRevealWindowIDs, [], "Closure cannot request a reveal");
  const closedBytes = fs.readFileSync(file, "utf8");
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser)]), "native-closed-request", true,
    "Closure replay survives worker reload and is idempotent");
  assert.equal(fs.readFileSync(file, "utf8"), closedBytes, "Identical closure must not churn the file watcher");
  assertReceipt(call(directory, [connect(browser), request(browser, plan(2, { windows: [] }))]), 2, true);
  assert.deepEqual(readRecord(directory, browser).closedParkingWindowIDs, [21], "Later active plan preserves closure");
  writeRules(directory, { active: false });
  assertReceipt(call(directory, [connect(browser), request(browser, plan(3, { windows: [] }))]), 3, true);
  assert.deepEqual(readRecord(directory, browser).closedParkingWindowIDs, [21], "Later reveal delivery preserves closure");
  writeCapture(directory, browser, [21, 22]);
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser, { requestID: "second", windowIDs: [22] })]),
    "second", true, "A second captured closure accumulates");
  assert.deepEqual(readRecord(directory, browser).closedParkingWindowIDs, [21, 22]);
  writeRules(directory, { startupSessionID: "new-active-intention" });
  assertClosedReceipt(call(directory, [registration, nativeClosedRequest(browser, { requestID: "replay" })]),
    "replay", true, "Historical closure remains idempotent during a newer intention");
  assert.equal(fs.readdirSync(directory).filter(file => file.startsWith("browser-window-visibility-") && file.endsWith(".json")).length, 1,
    "Closure never registers a new occurrence");
}
function checkQAIdentityIsolation() {
  const browser = "org.mozilla.firefox";
  const injected = JSON.stringify(simulatedQAIdentity);
  const directory = temporaryDirectory(); writeRules(directory);
  for (const environment of [{ INTENT_QA_BROWSER_PROCESS_IDENTITY: injected },
    { INTENT_QA_ROOT: directory, INTENT_QA_BROWSER_PROCESS_IDENTITY: injected }]) {
    const responses = callProduction(directory, [connect(browser), request(browser)], environment);
    assert.equal(responses[0].browserProcessIdentity, undefined, "Production basename ignores QA identity injection");
    assert.equal(responses[0].nativeWindowVisibility, true, "Ignoring an override must not downgrade required ownership");
    assert.ok(!heartbeat(directory, browser).capabilities.includes(capability));
    assertReceipt(responses, 1, false);
    assert.equal(fs.existsSync(recordPath(directory, browser)), false);
  }
  const otherRoot = temporaryDirectory();
  const mismatched = call(directory, [connect(browser), request(browser)], { environment: { INTENT_QA_ROOT: otherRoot } });
  assert.equal(mismatched[0].browserProcessIdentity, undefined, "QA root must equal the host data directory");
  assertReceipt(mismatched, 1, false);
  const unmarked = temporaryDirectory(); writeRules(unmarked); fs.unlinkSync(path.join(unmarked, ".intent-qa-root"));
  const missingMarker = call(unmarked, [connect(browser), request(browser)]);
  assert.equal(missingMarker[0].browserProcessIdentity, undefined, "Renamed helper alone cannot authorize an unmarked root");
  assertReceipt(missingMarker, 1, false);
  const malformed = call(directory, [connect(browser), request(browser)], {
    environment: { INTENT_QA_BROWSER_PROCESS_IDENTITY: JSON.stringify({ pid: -1, launched: 1 }) }
  });
  assert.equal(malformed[0].browserProcessIdentity, undefined, "QA identities must still pass validity checks");
  assertReceipt(malformed, 1, false);
}
(async () => {
  assert.ok(fs.existsSync(host), `Build IntentNativeHost first: missing ${host}`);
  try {
    const helperDirectory = temporaryDirectory(); qaHost = path.join(helperDirectory, "IntentQASpec");
    fs.copyFileSync(host, qaHost); fs.chmodSync(qaHost, 0o700);
    checkQAIdentityIsolation();
    for (const browser of ["org.mozilla.firefox", "com.google.Chrome"]) {
      checkBrowser(browser); checkNegotiatedReadiness(browser); await checkCaptureAndFinish(browser);
      checkRestartDenials(browser); checkNativeRecoveryDenials(browser); checkNativeClosure(browser);
    }
    assert.equal(rejectedCase("com.apple.Safari", "Unsupported browser")[0].nativeWindowVisibility, false);
    await checkRuleRefresh();
    console.log("Native host window visibility: isolated simulated QA identity/protocol/capture fixtures and production identity/restart/native-recovery/closure denials plus cumulative closure receipts passed (not live AppKit acceptance)");
  } finally {
    for (const directory of directories) fs.rmSync(directory, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
