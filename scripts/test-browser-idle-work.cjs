const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

async function harness(browserName, connected) {
  let now = 0;
  let nextID = 1;
  let queries = 0;
  const timers = new Map();
  const intervals = [];
  const attempts = [];
  const messages = [];
  const event = () => ({ addListener() {} });
  const api = {
    runtime: {
      getManifest: () => ({ version: "test" }),
      onMessage: event(), onStartup: event(), onInstalled: event(),
      connectNative() {
        attempts.push(now);
        if (!connected) throw new Error("Host unavailable");
        return { onMessage: event(), onDisconnect: event(), postMessage: m => messages.push(m) };
      }
    },
    storage: { local: { get: async defaults => defaults, set: async () => {} } },
    tabs: {
      query: async () => { queries++; return []; },
      onActivated: event(), onUpdated: event(), onCreated: event(), onRemoved: event()
    },
    webRequest: { onBeforeRequest: event() },
    webNavigation: { onBeforeNavigate: event() },
    declarativeNetRequest: { updateDynamicRules: async () => {}, getDynamicRules: async () => [] }
  };
  const context = {
    browser: api, chrome: api, URL, console,
    IntentBrowserRules: require(`../${browserName}-extension/rule-helpers.js`),
    importScripts() {},
    setTimeout(callback, delay = 0) {
      const id = nextID++;
      timers.set(id, { callback, due: now + delay });
      return id;
    },
    setInterval(callback, delay) { intervals.push({ callback, delay }); return nextID++; }
  };
  const drain = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
  const advance = async end => {
    while (true) {
      const next = [...timers.entries()].sort((a, b) => a[1].due - b[1].due)[0];
      if (!next || next[1].due > end) break;
      now = next[1].due;
      timers.delete(next[0]);
      next[1].callback();
      await drain();
    }
    now = end;
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, `../${browserName}-extension/background.js`), "utf8"), context);
  await drain();
  await advance(100);
  return { context, intervals, attempts, messages, timers, advance, drain, queryCount: () => queries };
}

(async () => {
  for (const name of ["firefox", "chrome"]) {
    const offline = await harness(name, false);
    for (let time = 200; time <= 120000; time += 100) {
      await offline.advance(time);
      // Ordinary browser activity and heartbeats must not bypass reconnect backoff.
      offline.context.scheduleTabSnapshot(true);
      if (time % 3000 === 0) offline.context.sendHeartbeat();
      await offline.drain();
    }
    assert.equal(offline.attempts.length, 8, `${name}: background activity must not trigger extra reconnects`);
    assert.deepEqual(offline.attempts, [0, 1000, 3000, 7000, 15000, 31000, 61000, 91000]);

    const idle = await harness(name, true);
    const queriesBefore = idle.queryCount();
    const timersBefore = idle.timers.size;
    for (let i = 0; i < 1000; i++) idle.context.scheduleTabSnapshot();
    assert.equal(idle.timers.size, timersBefore, `${name}: inactive tab events should schedule no snapshot work`);
    await idle.advance(1000);
    assert.equal(idle.queryCount(), queriesBefore, `${name}: inactive events must not enumerate tabs`);
    assert.equal(idle.intervals[0].delay, 3000);
    assert.ok(idle.intervals[0].delay < 5000, "Heartbeat must remain within the app's five-second freshness window");
    // The forced empty snapshot still clears the native switcher when a session ends.
    idle.context.scheduleTabSnapshot(true);
    await idle.advance(1100);
    assert.ok(idle.messages.some(m => m.type === "tabsSnapshot" && m.tabs.length === 0));
    console.log(`${name}: 8 reconnect attempts / 120s; zero snapshot timers for 1,000 inactive events; heartbeat 20/min`);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
