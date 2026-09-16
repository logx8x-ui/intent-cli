const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const host = path.resolve(__dirname, '../.build/release/IntentNativeHost');
function frame(message) {
  const body = Buffer.from(JSON.stringify(message)), header = Buffer.alloc(4);
  header.writeUInt32LE(body.length); return Buffer.concat([header, body]);
}
async function until(predicate) {
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('Snapshot refresh did not arrive');
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
  const snapshot = {type: 'tabsSnapshot', browserBundleIdentifier: browser,
    tabs: [{id: 1, windowID: 7, index: 0, title: 'Example', url: 'https://example.com', active: true}]};
  try {
    child.stdin.write(frame({type: 'getRules', browserBundleIdentifier: browser}));
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
  } finally {
    child.stdin.end();
    await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { child.kill(); resolve(); }, 1000).unref(); });
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
(async () => {
  await check('org.mozilla.firefox', '-org-mozilla-firefox');
  await check('com.google.Chrome', '-com-google-Chrome');
  console.log('Native snapshot freshness spec passed for Firefox and Chrome');
})().catch(error => { console.error(error); process.exitCode = 1; });
