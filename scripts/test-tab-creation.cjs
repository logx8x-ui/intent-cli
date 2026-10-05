const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const Creator = require('../firefox-extension/tab-creation.js');
assert.equal(fs.readFileSync('firefox-extension/tab-creation.js', 'utf8'), fs.readFileSync('chrome-extension/tab-creation.js', 'utf8'));
assert(require('../firefox-extension/manifest.json').background.scripts.includes('tab-creation.js'));

function harness(options = {}) {
  const storage = options.storage || {}, receipts = [], calls = [];
  let active = false, enabled = true, windowID = 4, session = 'profile-a', nextID = 20;
  const api = {
    storage: { session: {
      async get() { if (options.readFails) throw Error(); return structuredClone(storage); },
      async set(value) { if (options.writeFails) throw Error(); Object.assign(storage, structuredClone(value)); await options.afterWrite?.(); }
    } },
    tabs: {
      async get(id) { if (options.closed) throw Error(); return { id, windowId: windowID, cookieStoreId: options.container }; },
      async create(properties) {
        calls.push(properties); await options.duringCreate?.();
        return { id: nextID++, index: 2, title: '', ...properties, windowId: properties.windowId };
      },
      async update() { throw Error('Creation must not activate any tab'); }
    },
    windows: {
      async get(id) { return { id, type: 'normal', left: 1, top: 2, width: 800, height: 600, focused: false }; },
      async update() { throw Error('Creation must never raise a window'); }
    }
  };
  const creator = new Creator(api, { session: () => session, active: () => active, enabled: () => enabled,
    firefox: options.firefox !== false, send: message => receipts.push(message.creation) });
  return { creator, calls, receipts, storage, api, setActive(value) { active = value; },
    moveAnchor(value) { windowID = value; }, setSession(value) { session = value; }, setEnabled(value) { enabled = value; } };
}
function command(overrides = {}) {
  return { id: crypto.randomUUID(), action: 'create', browserSessionID: 'profile-a', tabID: 7, windowID: 4,
    url: 'https://example.org/page', expiresAtUnixMS: Date.now() + 8000, ...overrides };
}
(async () => {
  for (const firefox of [true, false]) {
    const h = harness({ firefox }), request = command();
    await Promise.all([h.creator.handle(request), h.creator.handle(request)]);
    assert.equal(h.calls.length, 1, 'Duplicate asynchronous deliveries create exactly one tab');
    assert.equal(h.calls[0].active, false); assert.equal(h.calls[0].windowId, 4); assert.equal(h.calls[0].openerTabId, 7);
    assert.equal(h.calls[0].discarded, firefox ? true : undefined);
    assert.equal(h.receipts[0].tab.id, h.receipts[1].tab.id, 'Duplicate command returns same receipt');
    const restart = harness({ storage: h.storage, firefox });
    await restart.creator.handle(request);
    assert.equal(restart.calls.length, 0, 'Service-worker restart cannot recreate an acknowledged tab');
    assert.equal(restart.receipts[0].tab.id, h.receipts[0].tab.id);
  }
  for (const overrides of [{ browserSessionID: 'profile-b' }, { expiresAtUnixMS: Date.now() - 1 }, { expiresAtUnixMS: Date.now() + 60000 }, { tabID: -1 }, { windowID: -1 }, { url: 'javascript:alert(1)' }, { url: 'file:///tmp/x' }, { url: 'https://user:pass@example.org' }]) {
    const h = harness(); await h.creator.handle(command(overrides)); assert.equal(h.calls.length, 0, 'Unsafe/stale creation is effect-free');
  }
  for (const options of [{ readFails: true }, { writeFails: true }, { closed: true }, { container: 'firefox-container-1' }]) {
    const h = harness(options); await h.creator.handle(command()); assert.equal(h.calls.length, 0, 'Missing durable claim or unsupported owner never creates');
  }
  const moved = harness(); moved.moveAnchor(5); await moved.creator.handle(command()); assert.equal(moved.calls.length, 0);
  const active = harness(); active.setActive(true); await active.creator.handle(command()); assert.equal(active.calls.length, 0);
  const disabled = harness(); disabled.setEnabled(false); await disabled.creator.handle(command()); assert.equal(disabled.calls.length, 0);
  const cancelled = harness(), cancelledRequest = command();
  await cancelled.creator.handle({ ...cancelledRequest, action: 'cancelCreate' });
  await cancelled.creator.handle(cancelledRequest); assert.equal(cancelled.calls.length, 0);
  let race;
  race = harness({ afterWrite: async () => { race.setActive(true); } });
  await race.creator.handle(command()); assert.equal(race.calls.length, 0, 'Intention starting during durable claim cancels creation');
  let disconnectRace;
  disconnectRace = harness({ afterWrite: async () => { disconnectRace.setEnabled(false); } });
  await disconnectRace.creator.handle(command()); assert.equal(disconnectRace.calls.length, 0, 'Lost native connection during claim revokes creation authority');
  let cancelRace; const raceRequest = command();
  cancelRace = harness({ afterWrite: async () => { await cancelRace.creator.handle({ ...raceRequest, action: 'cancelCreate' }); } });
  await cancelRace.creator.handle(raceRequest); assert.equal(cancelRace.calls.length, 0, 'Cancellation during claim reaches the effect boundary');
  const uncertainRequest = command(), journalKey = 'profile-a:' + uncertainRequest.id;
  const uncertain = harness({ storage: { intentWebsiteCreation: { [journalKey]: {
    fingerprint: JSON.stringify(['profile-a', 7, 4, uncertainRequest.url]), at: Date.now() } } } });
  await uncertain.creator.handle(uncertainRequest); assert.equal(uncertain.calls.length, 0, 'A crash after claim does not cause replay');
  assert.match(uncertain.receipts[0].error, /may already/);
  console.log('Browser tab creation: background-only, exact-owner, expiry, cancellation, durable dedupe and restart checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
