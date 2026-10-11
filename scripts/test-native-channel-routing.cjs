const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const hostPath = process.env.INTENT_NATIVE_HOST_PATH;
const probePath = process.env.INTENT_CHANNEL_LEASE_PROBE_PATH;
assert.ok(hostPath && probePath, 'Pass built NativeHost and the isolated lease probe');
const channelResult = spawnSync(hostPath, ['--print-build-channel'], { encoding: 'utf8', timeout: 3000 });
assert.equal(channelResult.status, 0, channelResult.stderr);
const channel = channelResult.stdout.trim();
assert.ok(['launch', 'development'].includes(channel));
const otherChannel = channel === 'launch' ? 'development' : 'launch';
// Keep the system temporary-directory spelling. On macOS Foundation resolves
// an existing /private/var parent to /var, but may retain /private/var for a
// nonexistent child; eagerly realpath-ing this root would fail the safe-root
// validator before the intentionally absent workspace can be tested.
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-native-channel-'));
const engineDir = path.join(root, 'engine');
const storageDir = path.join(root, 'workspace');
const environment = { ...process.env, INTENT_NATIVE_HOST_DIRECTORY: storageDir,
  INTENT_NATIVE_HOST_ENFORCE_OWNER: '1', INTENT_NATIVE_HOST_ENGINE_DIRECTORY: engineDir };
const children = new Set();
function frame(value) {
  const bytes = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4); header.writeUInt32LE(bytes.length);
  return Buffer.concat([header, bytes]);
}
function close(child) {
  if (child.exitCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Owned fixture did not exit')); }, 3000);
    child.once('exit', code => { clearTimeout(timer); resolve(code); });
  });
}
function line(child, expected) {
  return new Promise((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => finish(new Error(`Lease probe did not report ${expected}`)), 3000);
    const receive = bytes => { text += bytes; if (text.split('\n').includes(expected)) finish(); };
    const finish = error => { clearTimeout(timer); child.stdout.off('data', receive); error ? reject(error) : resolve(); };
    child.stdout.on('data', receive);
  });
}
async function hold(selectedChannel) {
  const child = spawn(probePath, ['--hold-lease', engineDir, selectedChannel], { stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(child);
  await line(child, 'ready');
  return child;
}
async function release(owner) { const exited = close(owner); owner.stdin.end('release\n'); assert.equal(await exited, 0); children.delete(owner); }
function once(extra = {}) {
  return spawnSync(hostPath, [], { input: frame({ type: 'getRules' }), env: { ...environment, ...extra }, timeout: 3000 });
}
function request(child) {
  return new Promise((resolve, reject) => {
    let bytes = Buffer.alloc(0);
    const timer = setTimeout(() => finish(new Error('Matching native helper did not answer')), 3000);
    const receive = chunk => {
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length >= 4 && bytes.length >= 4 + bytes.readUInt32LE(0)) {
        try { finish(null, JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32LE(0)).toString())); } catch (error) { finish(error); }
      }
    };
    const finish = (error, value) => { clearTimeout(timer); child.stdout.off('data', receive); error ? reject(error) : resolve(value); };
    child.stdout.on('data', receive);
    child.stdin.write(frame({ type: 'getRules' }));
  });
}
function persistentHost() {
  const child = spawn(hostPath, [], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(child);
  return child;
}
(async () => {
  try {
    const absent = once();
    assert.equal(absent.status, 0); assert.equal(absent.stdout.length, 0);
    assert.equal(fs.existsSync(storageDir), false, 'No owner cannot create even a fixture workspace');
    const unsafe = once({ INTENT_NATIVE_HOST_ENGINE_DIRECTORY: path.join(os.homedir(), '.intent-engine') });
    assert.equal(unsafe.status, 2, 'Enforced fixture must never read the daily lease');
    let owner = await hold(otherChannel);
    const wrong = once();
    assert.equal(wrong.status, 0); assert.equal(wrong.stdout.length, 0);
    assert.equal(fs.existsSync(storageDir), false, 'Other compiled channel cannot route or create storage');
    await release(owner);
    owner = await hold(channel);
    const firstOwner = JSON.parse(fs.readFileSync(path.join(engineDir, 'owner.json')));
    const host = persistentHost();
    assert.equal((await request(host)).active, false, 'Matching live lease answers the actual native protocol');
    const activeAck = line(owner, 'active'); owner.stdin.write('active\n'); await activeAck;
    assert.equal((await request(host)).active, false, 'Active flag changes preserve the same host lifetime');
    const hostExit = close(host);
    await release(owner);
    owner = await hold(channel);
    const secondOwner = JSON.parse(fs.readFileSync(path.join(engineDir, 'owner.json')));
    assert.notEqual(firstOwner.generation, secondOwner.generation);
    assert.equal(await hostExit, 0, 'Old connection exits after lease replacement, even if stdin stays open');
    children.delete(host);
    const replacement = persistentHost();
    assert.equal((await request(replacement)).active, false, 'A new matching helper reconnects to the new engine');
    const replacementExit = close(replacement);
    await release(owner);
    owner = await hold(otherChannel);
    assert.equal(await replacementExit, 0, 'Channel handoff severs the former connection');
    children.delete(replacement);
    assert.equal(once().stdout.length, 0, 'Old compiled helper cannot fall back into the new channel');
    await release(owner);
    console.log('Actual native protocol: absent/wrong owner refused, exact channel connected, status preserved, old generations closed and reconnect succeeded.');
  } finally {
    for (const child of children) child.kill();
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
