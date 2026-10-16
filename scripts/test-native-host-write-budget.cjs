#!/usr/bin/env node
// Synthetic inventories only. Exercise the real profile/receipt filesystem
// protocol, including atomic-write failure, without daily browser data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {spawn} = require('node:child_process');
const host = process.env.INTENT_NATIVE_HOST_PATH || path.resolve(__dirname, '../.build/release/IntentNativeHost');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const now = () => Date.now() / 1000 - 978307200;
const read = file => { try { return JSON.parse(fs.readFileSync(file)); } catch { return null; } };
async function until(predicate, message) {
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) { if (predicate()) return; await delay(10); }
  throw new Error(message);
}
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length); return Buffer.concat([header, body]);
}
function start(directory, browser, session) {
  const profile = randomUUID(), component = createHash('sha256').update(session).digest('hex').slice(0,24);
  const stem = browser.replace(/[^a-zA-Z0-9]/g, '-');
  const base = path.join(directory, `browser-tabs-${stem}.json`);
  const profileFile = path.join(directory, `browser-tabs-${stem}.profile-${component}.json`);
  const discovery = path.join(directory, `browser-tabs-${stem}.discovery-profile-${component}.json`);
  const command = path.join(directory, `browser-tab-command-${stem}.profile-${component}.json`);
  const heartbeat = profileFile + '.heartbeat', metrics = path.join(directory, `metrics-${component}.json`);
  const child = spawn(host, {env: {...process.env, INTENT_NATIVE_HOST_DIRECTORY: directory, INTENT_NATIVE_HOST_METRICS_FILE: metrics}});
  let buffer = Buffer.alloc(0); const replies = [];
  child.stdout.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
      const length = buffer.readUInt32LE(0);
      replies.push(JSON.parse(buffer.subarray(4, 4 + length))); buffer = buffer.subarray(4 + length);
    }
  });
  child.stderr.resume();
  const exited = new Promise(resolve => child.once('exit', code => resolve(code)));
  const send = message => child.stdin.write(frame({browserBundleIdentifier: browser, browserSessionID: session,
    browserProfileID: profile, extensionVersion: '0.2.46', ...message}));
  send({type: 'getRules'});
  return {base, profileFile, discovery, heartbeat, metrics, send, session, profile,
    async request() {
      const id = randomUUID();
      fs.writeFileSync(command, JSON.stringify({id, tabID: -1, windowID: -1, action: 'snapshot',
        browserSessionID: session, createdAt: now()}));
      await until(() => replies.some(reply => reply.tabCommand?.id === id), 'Correlated command was not delivered');
      return id;
    },
    async activate() {
      const activation = {id: randomUUID(), tabID: 0, windowID: 0, action: 'activate',
        browserSessionID: session, createdAt: now()};
      fs.writeFileSync(command, JSON.stringify(activation));
      await until(() => replies.some(reply => reply.tabCommand?.id === activation.id), 'Activation command was not delivered');
      return activation;
    },
    async close() {
      child.stdin.end();
      const timeout = setTimeout(() => child.kill(), 1500);
      try { assert.equal(await exited, 0, 'Native fixture exits cleanly'); } finally { clearTimeout(timeout); }
      return read(metrics);
    }
  };
}
const tabs = Array.from({length: 96}, (_, id) => ({id, windowID: Math.floor(id / 24), index: id % 24,
  title: `Synthetic tab ${id}`, url: `https://example.test/${id}`, active: id % 24 === 0,
  faviconURL: 'data:image/png;base64,' + 'A'.repeat(2048),
  windowFrame: {left: 30, top: 50, width: 900, height: 700}, windowFocused: id < 24, windowState: 'normal'}));
const snapshot = rows => ({type: 'tabsSnapshot', tabs: rows, allTabs: rows});

async function profileBudget(browser) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-native-profile-write-budget-'));
  const clients = [start(directory, browser, 'budget-a'), start(directory, browser, 'budget-b')];
  const results = [];
  try {
    for (const client of clients) {
      client.send(snapshot(tabs));
      await until(() => read(client.profileFile)?.allTabs.length === tabs.length, 'Profile inventory missing');
    }
    const initial = clients.map(client => fs.readFileSync(client.profileFile, 'utf8'));
    const sizes = initial.map(value => Buffer.byteLength(value));
    // Distinct request IDs intentionally bypass logical snapshot dedup. They
    // should write only one exact receipt per profile, not three full copies.
    for (let iteration = 0; iteration < 12; iteration++) {
      for (const client of clients) {
        const id = await client.request();
        client.send({...snapshot(tabs), snapshotRequestIDs: [id]});
        await until(() => read(client.discovery)?.profileDiscoveryRequestIDs?.includes(id), 'Fresh receipt missing');
        const receipt = read(client.discovery);
        assert.equal(receipt.browserSessionID, client.session);
        assert.equal(receipt.browserProfileID, client.profile);
        assert.equal(receipt.snapshotRequestIDs, undefined, 'No native coverage authority is fabricated');
        assert.equal(receipt.completeWindowInventory, undefined);
      }
    }
    for (let index = 0; index < clients.length; index++) {
      const client = clients[index];
      assert.equal(fs.readFileSync(client.profileFile, 'utf8'), initial[index], 'Receipt renewal leaves ordinary inventory unchanged');
      const result = await client.close(); results.push(result);
      assert.equal(result.snapshotInventoryFileWrites, 2, 'Only initial base and profile inventories are written');
      assert.equal(result.snapshotInventoryBytes, sizes[index] * 2, 'Inventory byte accounting includes every atomic copy');
      assert.equal(result.snapshotReceiptFileWrites, 12, 'Every query receives its own fresh, exactly scoped receipt');
      assert.ok(result.snapshotReceiptBytes >= sizes[index] * 12 && result.snapshotReceiptBytes < (sizes[index] + 1000) * 12,
        'Receipt byte accounting includes the full observed inventory and bounded metadata');
      assert.ok(result.heartbeatWrites <= 6, 'Correlated requests must not force a heartbeat write for every snapshot');
      assert.equal(result.snapshotPersistenceFailures, 0);
    }
    console.log(`${browser}: 2 profiles × 12 correlated queries, ${results.reduce((n,m)=>n+m.snapshotInventoryFileWrites,0)} inventory writes, ${results.reduce((n,m)=>n+m.snapshotReceiptFileWrites,0)} receipt writes`);
  } finally {
    for (let index = results.length; index < clients.length; index++) await clients[index].close().catch(() => {});
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

async function recoverPartialWrite(browser, failReceipt) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-native-write-failure-'));
  const client = start(directory, browser, 'write-failure');
  let result;
  try {
    client.send(snapshot(tabs.slice(0, 2)));
    await until(() => read(client.profileFile)?.allTabs.length === 2, 'Initial failure fixture missing');
    const prior = read(client.profileFile);
    const blocked = failReceipt ? client.discovery : client.profileFile;
    if (fs.existsSync(blocked)) fs.unlinkSync(blocked);
    fs.mkdirSync(blocked); // An atomic file rename cannot replace this directory.
    const id = await client.request();
    const changed = tabs.slice(0, 3);
    client.send({...snapshot(changed), snapshotRequestIDs: [id]});
    await until(() => read(client.base)?.allTabs.length === 3, 'Base write should precede the injected partition failure');
    await until(() => !fs.existsSync(client.heartbeat), 'A failed partition must withdraw profile freshness');
    const baseAfterFailure = fs.statSync(client.base).mtimeMs;
    const profileAfterFailure = failReceipt ? fs.statSync(client.profileFile).mtimeMs : null;
    client.send({type: 'heartbeat'});
    await delay(100);
    assert.equal(fs.existsSync(client.heartbeat), false, 'Heartbeats cannot advance stale/partially persisted profile inventory');
    fs.rmdirSync(blocked);
    // No second snapshot: the host retries the original observation, retaining
    // its actual timestamp and exact request ID rather than inventing freshness.
    await until(() => read(client.discovery)?.profileDiscoveryRequestIDs?.includes(id) && fs.existsSync(client.heartbeat),
      'The required profile/receipt write was not retried after storage recovered');
    assert.equal(read(client.profileFile).allTabs.length, 3);
    assert.equal(read(client.profileFile).updatedAt, read(client.base).updatedAt);
    assert.equal(read(client.discovery).updatedAt, read(client.base).updatedAt);
    assert.ok(read(client.profileFile).updatedAt > prior.updatedAt);
    assert.equal(fs.statSync(client.base).mtimeMs, baseAfterFailure, 'Retry does not rewrite already completed base data');
    if (failReceipt) assert.equal(fs.statSync(client.profileFile).mtimeMs, profileAfterFailure, 'Receipt retry does not rewrite completed profile data');
    const persisted = fs.readFileSync(client.profileFile, 'utf8');
    client.send(snapshot(changed));
    await delay(75);
    assert.equal(fs.readFileSync(client.profileFile, 'utf8'), persisted, 'Only a fully successful transaction advances dedup state');
    result = await client.close();
    assert.ok(result.snapshotPersistenceFailures >= 1 && result.snapshotRetryAttempts >= 1);
    assert.equal(result.snapshotInventoryFileWrites, 4, 'Initial and changed base/profile each persist once despite retries');
    assert.equal(result.snapshotReceiptFileWrites, 1);
    console.log(`${browser}: failed ${failReceipt ? 'receipt' : 'profile'} partition recovers without lending stale freshness`);
  } finally {
    if (!result) await client.close().catch(() => {});
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

async function preserveNewActivationDuringRetry(browser) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-native-activation-write-retry-'));
  const client = start(directory, browser, 'activation-retry');
  let result;
  try {
    client.send(snapshot(tabs.slice(0, 2)));
    await until(() => read(client.profileFile)?.allTabs.length === 2, 'Activation fixture inventory missing');
    fs.unlinkSync(client.profileFile); fs.mkdirSync(client.profileFile);
    const changed = tabs.slice(0, 3);
    client.send(snapshot(changed));
    await until(() => read(client.base)?.allTabs.length === 3 && !fs.existsSync(client.heartbeat), 'Initial partial write did not fail');
    const olderObservation = read(client.base).updatedAt;
    await delay(20);
    const activation = await client.activate();
    // This is the only response to the newer activation. Its rows match the
    // incomplete write, but its post-activation observation cannot be dropped.
    client.send(snapshot(changed));
    await until(() => read(client.base)?.updatedAt >= activation.createdAt && read(client.base)?.updatedAt > olderObservation,
      'New activation response was discarded behind an older same-inventory retry');
    const activationObservation = read(client.base).updatedAt;
    await delay(100);
    assert.equal(fs.existsSync(client.heartbeat), false);
    fs.rmdirSync(client.profileFile);
    await until(() => read(client.profileFile)?.updatedAt === activationObservation && fs.existsSync(client.heartbeat),
      'Storage recovery did not persist the newer activation observation');
    await delay(150);
    assert.equal(read(client.profileFile).updatedAt, activationObservation, 'Superseded retries cannot restore an older observation');
    assert.equal(read(client.base).updatedAt, activationObservation);
    const persisted = fs.readFileSync(client.profileFile, 'utf8');
    client.send(snapshot(changed));
    await delay(75);
    assert.equal(fs.readFileSync(client.profileFile, 'utf8'), persisted, 'Successful newer activation consumes only its own refresh');
    result = await client.close();
    assert.ok(result.snapshotPersistenceFailures >= 2 && result.snapshotRetryAttempts >= 1);
    assert.equal(result.snapshotInventoryFileWrites, 5, 'Only initial inventories, the older base, and newer activation inventories were written');
    console.log(`${browser}: a newer activation supersedes an older failed same-inventory observation`);
  } finally {
    if (!result) await client.close().catch(() => {});
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
(async () => {
  for (const browser of ['org.mozilla.firefox', 'com.google.Chrome']) {
    await profileBudget(browser);
    await recoverPartialWrite(browser, false);
    await recoverPartialWrite(browser, true);
    await preserveNewActivationDuringRetry(browser);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
