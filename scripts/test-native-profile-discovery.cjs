const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const host = path.resolve(__dirname, '../.build/release/IntentNativeHost');
const hash = value => crypto.createHash('sha256').update(value).digest('hex').slice(0, 24);
const swiftNow = () => Date.now() / 1000 - 978307200;
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length); return Buffer.concat([header, body]);
}
async function until(predicate, message) {
  const deadline = Date.now() + 3500;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 15));
  }
  throw new Error(message);
}
async function check(browser) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-profile-discovery-'));
  const session = 'saved-owner-' + browser, profile = crypto.randomUUID();
  const stem = browser.replace(/[^a-zA-Z0-9]/g, '-');
  const discovery = path.join(directory, `browser-tabs-${stem}.discovery-profile-${hash(session)}.json`);
  const ordinary = path.join(directory, `browser-tabs-${stem}.profile-${hash(session)}.json`);
  const commandFile = path.join(directory, `browser-tab-command-${stem}.profile-${hash(session)}.json`);
  const read = file => { try { return JSON.parse(fs.readFileSync(file)); } catch { return null; } };
  const child = spawn(host, {env: {...process.env, INTENT_NATIVE_HOST_DIRECTORY: directory}});
  const exited = new Promise(resolve => child.once('exit', resolve));
  let output = Buffer.alloc(0), replies = [];
  child.stdout.on('data', chunk => {
    output = Buffer.concat([output, chunk]);
    while (output.length >= 4 && output.length >= 4 + output.readUInt32LE(0)) {
      const length = output.readUInt32LE(0);
      replies.push(JSON.parse(output.subarray(4, 4 + length))); output = output.subarray(4 + length);
    }
  });
  child.stderr.resume();
  const send = message => child.stdin.write(frame({...message, browserBundleIdentifier: browser,
    browserSessionID: session, browserProfileID: profile}));
  const tab = {id: 9, windowID: 3, index: 0, title: 'Example', url: 'https://example.com', active: true, cookieStoreID: 'firefox-container-2'};
  async function request() {
    const id = crypto.randomUUID();
    fs.writeFileSync(commandFile, JSON.stringify({id, tabID: -1, windowID: -1, action: 'snapshot', browserSessionID: session, createdAt: swiftNow()}));
    await until(() => replies.some(reply => reply.tabCommand?.id === id), 'Owner did not receive its scoped command');
    return id;
  }
  try {
    send({type: 'getRules'});
    send({type: 'tabsSnapshot', tabs: [tab], allTabs: [tab], snapshotRequestIDs: [crypto.randomUUID()]});
    await until(() => read(ordinary), 'Initial profile snapshot missing');
    assert.equal(read(ordinary).browserProfileID, profile);
    assert.equal(read(ordinary).allTabs[0].cookieStoreID, tab.cookieStoreID);
    assert.equal(fs.existsSync(discovery), false, 'Unissued IDs must not manufacture correlated inventory');

    const id = await request();
    send({type: 'tabsSnapshot', tabs: [tab], allTabs: [tab], snapshotRequestIDs: [id]});
    await until(() => read(discovery)?.profileDiscoveryRequestIDs?.includes(id), 'Full owner query did not produce discovery proof');
    const frozen = fs.readFileSync(discovery, 'utf8');
    assert.equal(read(discovery).browserProfileID, profile);
    assert.equal(read(discovery).browserSessionID, session);
    assert.equal(read(discovery).completeWindowInventory, undefined, 'Profile discovery must not manufacture native-window coverage proof');
    assert.equal(read(discovery).snapshotRequestIDs, undefined);

    send({type: 'tabsSnapshot', tabs: [{...tab, title: 'Changed ordinary title'}], allTabs: [{...tab, title: 'Changed ordinary title'}]});
    await until(() => read(ordinary)?.allTabs[0].title === 'Changed ordinary title', 'Ordinary snapshot did not update');
    assert.equal(fs.readFileSync(discovery, 'utf8'), frozen, 'Ordinary refresh cannot overwrite the immutable discovery receipt');

    const incompleteID = await request();
    send({type: 'tabsSnapshot', tabs: [tab], snapshotRequestIDs: [incompleteID]});
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(fs.readFileSync(discovery, 'utf8'), frozen, 'Active-only response cannot prove missing tabs');
    send({type: 'tabsSnapshot', tabs: [], allTabs: [], snapshotRequestIDs: [incompleteID]});
    await until(() => read(discovery)?.profileDiscoveryRequestIDs?.includes(incompleteID), 'Confirmed empty inventory did not replace prior proof');
    assert.deepEqual(read(discovery).allTabs, []);
  } finally {
    child.stdin.end();
    const timeout = setTimeout(() => child.kill(), 1000);
    await exited; clearTimeout(timeout);
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
(async () => {
  await check('org.mozilla.firefox'); await check('com.google.Chrome');
  console.log('Native profile discovery: exact request, profile metadata, complete inventory and immutable sidecar checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
