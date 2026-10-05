const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const host = process.env.INTENT_NATIVE_HOST_PATH || path.resolve('.build/release/IntentNativeHost');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-tab-create-protocol-'));
const browser = 'com.google.Chrome', session = 'create-profile';
const envelope = { browserBundleIdentifier: browser, browserSessionID: session,
  extensionCapabilities: ['background-tab-create-v1'], extensionVersion: '0.2.35' };
function frame(value) { const data = Buffer.from(JSON.stringify(value)), header = Buffer.alloc(4); header.writeUInt32LE(data.length); return Buffer.concat([header, data]); }
function call(messages) {
  const result = spawnSync(host, { input: Buffer.concat(messages.map(message => frame({ ...envelope, ...message }))),
    env: { ...process.env, INTENT_NATIVE_HOST_DIRECTORY: root } });
  assert.equal(result.status, 0, result.stderr.toString());
  let offset = 0; const messagesOut = [];
  while (offset < result.stdout.length) { const count = result.stdout.readUInt32LE(offset); offset += 4; messagesOut.push(JSON.parse(result.stdout.subarray(offset, offset + count))); offset += count; }
  return messagesOut;
}
function prepare() {
  const request = { id: crypto.randomUUID(), tabID: 7, windowID: 4, action: 'create', browserSessionID: session,
    url: 'https://example.org/', createdAt: Date.now() / 1000 - 978307200, expiresAtUnixMS: Date.now() + 8000 };
  const channel = 'browser-create-com-google-Chrome-' + crypto.createHash('sha256').update(session).digest('hex').slice(0, 24) + '.json';
  fs.writeFileSync(path.join(root, channel), JSON.stringify([request]));
  const receipt = { requestID: request.id, browserSessionID: session, anchorTabID: 7, windowID: 4, url: request.url,
    tab: { id: 9, windowID: 4, index: 1, title: 'Example', url: request.url, active: false } };
  return { request, receipt, resultPath: path.join(root, 'browser-tab-created-' + request.id + '.json') };
}
try {
  let item = prepare();
  const replies = call([{ type: 'getRules' }, { type: 'tabCreateResult', creation: item.receipt }]);
  assert(replies.some(reply => reply.tabCommand?.id === item.request.id), 'Verified creation reaches the exact native-host connection');
  assert.equal(JSON.parse(fs.readFileSync(item.resultPath)).tab.id, 9, 'Matching receipt persists real created-tab identity');
  for (const patch of [{ browserSessionID: 'other-profile' }, { windowID: 5 }, { anchorTabID: 8 }, { url: 'https://other.example/' }, { tab: { ...item.receipt.tab, active: true } }, { tab: { ...item.receipt.tab, windowID: 5 } }]) {
    item = prepare(); call([{ type: 'getRules' }, { type: 'tabCreateResult', creation: { ...item.receipt, ...patch } }]);
    assert(!fs.existsSync(item.resultPath), 'Wrong profile/window/anchor/URL/foreground receipt is rejected');
  }
  item = prepare();
  call([{ type: 'tabCreateResult', creation: item.receipt }]);
  assert(!fs.existsSync(item.resultPath), 'A receipt cannot acknowledge a command before it has been issued');
  item = prepare();
  fs.writeFileSync(path.join(root, 'browser-rules.json'), JSON.stringify({ active: true, allowedWebsites: [], blockTabSwitching: true,
    blockNavigation: true, blockNewTabs: false, allowGoogleSearchTabs: false, updatedAt: Date.now() / 1000 - 978307200 }));
  const active = call([{ type: 'getRules' }]);
  assert(active.every(reply => !reply.tabCommand), 'Native host does not issue creation during an intention');
  assert(active.some(reply => reply.active), 'Rejected creation does not suppress active-rule delivery');
  item = prepare();
  fs.writeFileSync(path.join(root, 'browser-rules.json'), JSON.stringify({ active: true, allowedWebsites: [], blockTabSwitching: true,
    unrestrictedBrowserBundleIdentifiers: [browser], blockNavigation: true, blockNewTabs: false, allowGoogleSearchTabs: false,
    updatedAt: Date.now() / 1000 - 978307200 }));
  const unrestricted = call([{ type: 'getRules' }]);
  assert(unrestricted.every(reply => !reply.tabCommand && reply.tabCreationAllowed === false), 'Globally active intentions reject creation even for unrestricted browsers');
  console.log('Native tab creation protocol identity and active-session checks passed');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
