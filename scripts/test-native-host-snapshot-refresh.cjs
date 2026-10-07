const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {createHash} = require('node:crypto');
const host = path.resolve(__dirname, '../.build/release/IntentNativeHost');
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length); return Buffer.concat([header, body]);
}
async function until(predicate, failure = 'Snapshot refresh did not arrive') {
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error(failure);
}
async function check(browser, suffix) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-snapshot-refresh-'));
  const child = spawn(host, {env: {...process.env, INTENT_NATIVE_HOST_DIRECTORY: directory}});
  let output = Buffer.alloc(0), replies = [];
  child.stdout.on('data', chunk => {
    output = Buffer.concat([output, chunk]);
    while (output.length >= 4 && output.length >= 4 + output.readUInt32LE(0)) {
      const length = output.readUInt32LE(0);
      replies.push(JSON.parse(output.subarray(4, 4 + length)));
      output = output.subarray(4 + length);
    }
  });
  child.stderr.resume();
  const file = path.join(directory, `browser-tabs${suffix}.json`);
  const read = () => { try { return JSON.parse(fs.readFileSync(file)); } catch { return null; } };
  const session = 'presence-owner-' + browser;
  const snapshot = {type: 'tabsSnapshot', browserBundleIdentifier: browser, browserSessionID: session,
    tabs: [{id: 1, windowID: 7, index: 0, title: 'Example', url: 'https://example.com', active: true}]};
  try {
    child.stdin.write(frame({type: 'getRules', browserBundleIdentifier: browser, browserSessionID: session}));
    child.stdin.write(frame(snapshot));
    await until(() => read());
    const first = read().updatedAt;
    await new Promise(resolve => setTimeout(resolve, 40));
    const requested = Date.now() / 1000 - 978307200;
    const id = `refresh-${browser}`;
    fs.writeFileSync(path.join(directory, `browser-tab-command${suffix}.json`), JSON.stringify({id, tabID: -1, windowID: -1, action: 'snapshot', createdAt: requested}));
    await until(() => replies.some(reply => reply.tabCommand?.id === id));
    child.stdin.write(frame(snapshot));
    await until(() => read()?.updatedAt > first);
    assert.ok(read().updatedAt >= requested, 'An explicit unchanged snapshot acknowledges this request, not an old one');
    assert.equal(read().tabs[0].id, 1);

    // A background presence query gets its own channel and cannot overwrite
    // a user command waiting for this same browser/profile.
    const component = createHash('sha256').update(session).digest('hex').slice(0,24);
    const normalPath = path.join(directory, `browser-tab-command${suffix}.profile-${component}.json`);
    const presencePath = path.join(directory, `browser-tab-command${suffix}.presence-profile-${component}.json`);
    const queuedAt = Date.now() / 1000 - 978307200;
    const normal = {id:'user-activate',action:'activate',tabID:1,windowID:7,browserSessionID:session,createdAt:queuedAt};
    const presence = {id:'confirm-presence',action:'snapshot',tabID:-1,windowID:-1,browserSessionID:session,createdAt:queuedAt};
    child.kill('SIGSTOP');
    try {
      fs.writeFileSync(normalPath, JSON.stringify(normal));
      fs.writeFileSync(presencePath, JSON.stringify(presence));
      child.stdin.write(frame({type:'getRules',browserBundleIdentifier:browser,browserSessionID:session}));
    } finally { child.kill('SIGCONT'); }
    await until(()=>replies.some(reply=>reply.tabCommand?.id===normal.id),'Pending normal command was lost');
    child.stdin.write(frame({type:'getRules',browserBundleIdentifier:browser,browserSessionID:session}));
    await until(()=>replies.some(reply=>reply.tabCommand?.id===presence.id),'Dedicated presence query did not reach its owner');
    const delivered = replies.filter(reply=>[normal.id,presence.id].includes(reply.tabCommand?.id)).map(reply=>reply.tabCommand.id);
    assert.deepEqual(delivered,[normal.id,presence.id],'Normal command has priority; both commands are delivered once');
    child.stdin.write(frame({...snapshot,allTabs:snapshot.tabs,snapshotRequestIDs:[presence.id]}));
    const discoveryPath = path.join(directory, `browser-tabs${suffix}.discovery-profile-${component}.json`);
    await until(()=>{try{return JSON.parse(fs.readFileSync(discoveryPath)).profileDiscoveryRequestIDs?.includes(presence.id);}catch{return false;}},
      'Dedicated presence reply was not correlated by the native host');

    const rulesFile = path.join(directory, 'browser-rules.json');
    const activeRules = {
      active: true, allowedWebsites: ['example.com'], startupSessionID: 'notification-race',
      blockTabSwitching: true, blockNavigation: true, blockNewTabs: true,
      allowGoogleSearchTabs: false, updatedAt: Date.now() / 1000 - 978307200
    };
    await new Promise(resolve => setTimeout(resolve, 75));
    const beforeStart = replies.length;
    fs.writeFileSync(rulesFile, JSON.stringify(activeRules));
    await until(() => replies.slice(beforeStart).some(reply => reply.active === true));
    await new Promise(resolve => setTimeout(resolve, 75));
    const changeRulesWithMessage = async (nextRules, message) => {
      // Hold only this isolated host so the incoming message and filesystem
      // change are both ready before its directory debounce can publish state.
      child.kill('SIGSTOP');
      try {
        await new Promise(resolve => setTimeout(resolve, 25));
        if (nextRules) fs.writeFileSync(rulesFile, JSON.stringify(nextRules));
        else fs.unlinkSync(rulesFile);
        child.stdin.write(frame(message));
      } finally { child.kill('SIGCONT'); }
    };
    for (const message of [{type: 'heartbeat', browserBundleIdentifier: browser}, snapshot]) {
      const beforeStop = replies.length;
      activeRules.updatedAt = Date.now() / 1000 - 978307200;
      await changeRulesWithMessage(activeRules, message);
      await new Promise(resolve => setTimeout(resolve, 75));
      assert.equal(replies.length, beforeStop, 'A timestamp-only renewal must not push unchanged effective rules');

      await changeRulesWithMessage(null, message);
      await until(() => replies.slice(beforeStop).some(reply => reply.active === false),
        `${browser}: ${message.type} consumed the stop without notifying the browser`);
      await new Promise(resolve => setTimeout(resolve, 75));
      assert.equal(replies.length, beforeStop + 1, 'A stop must be pushed once, even when the watcher follows the message');

      child.stdin.write(frame(message));
      await new Promise(resolve => setTimeout(resolve, 75));
      assert.equal(replies.length, beforeStop + 1, 'Unchanged heartbeats and snapshots must remain silent');

      activeRules.updatedAt = Date.now() / 1000 - 978307200;
      await changeRulesWithMessage(activeRules, message);
      await until(() => replies.slice(beforeStop + 1).some(reply => reply.active === true),
        `${browser}: ${message.type} consumed the start without notifying the browser`);
      await new Promise(resolve => setTimeout(resolve, 75));
      assert.equal(replies.length, beforeStop + 2, 'A start must be pushed once, even when the watcher follows the message');
    }
  } finally {
    child.kill('SIGCONT');
    child.stdin.end();
    await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { child.kill(); resolve(); }, 1000).unref(); });
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
(async () => {
  await check('org.mozilla.firefox', '-org-mozilla-firefox');
  await check('com.google.Chrome', '-com-google-Chrome');
  console.log('Native snapshot freshness and rule notification specs passed for Firefox and Chrome');
})().catch(error => { console.error(error); process.exitCode = 1; });
