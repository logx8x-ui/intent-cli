#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "chrome-extension/background.js"), "utf8");
const helpers = require(path.join(root, "chrome-extension/rule-helpers.js"));

function event() {
  const listeners = [];
  return { listeners, addListener(listener) { listeners.push(listener); } };
}

function createHarness(nativeRules, initialTabs, options = {}) {
  const tabs = new Map(initialTabs.map((tab) => [tab.id, { ...tab }]));
  const storage = { guardEnabled: options.guardEnabled !== false };
  const nativeMessages = [];
  const dynamicUpdates = [];
  const removedTabs = [];
  const focusedWindows = [];
  let dynamicRules = [];

  const runtimeMessage = event();
  const tabActivated = event();
  const tabUpdated = event();
  const tabCreated = event();
  const tabRemoved = event();
  const beforeNavigate = event();
  const nativeMessage = event();
  const nativeDisconnect = event();

  function setActive(id) {
    for (const tab of tabs.values()) tab.active = tab.id === id;
  }

  const port = {
    onMessage: nativeMessage,
    onDisconnect: nativeDisconnect,
    postMessage(message) {
      nativeMessages.push(message);
      Promise.resolve().then(() => nativeMessage.listeners.forEach((listener) => listener(nativeRules)));
    }
  };

  const chrome = {
    runtime: {
      connectNative: () => port,
      onMessage: runtimeMessage,
      onStartup: event(),
      onInstalled: event()
    },
    storage: { local: {
      get: async (defaults) => ({ ...defaults, ...storage }),
      set: async (values) => Object.assign(storage, values)
    } },
    declarativeNetRequest: {
      getDynamicRules: async () => dynamicRules.map((rule) => ({ ...rule })),
      updateDynamicRules: async ({ removeRuleIds, addRules }) => {
        dynamicRules = dynamicRules.filter((rule) => !removeRuleIds.includes(rule.id)).concat(addRules);
        dynamicUpdates.push({ removeRuleIds, addRules });
      }
    },
    tabs: {
      onActivated: tabActivated,
      onUpdated: tabUpdated,
      onCreated: tabCreated,
      onRemoved: tabRemoved,
      query: async () => Array.from(tabs.values()).map((tab) => ({ ...tab })),
      get: async (id) => tabs.has(id) ? { ...tabs.get(id) } : Promise.reject(new Error("missing tab")),
      update: async (id, patch) => {
        const tab = tabs.get(id);
        if (!tab) throw new Error("missing tab");
        Object.assign(tab, patch);
        if (patch.active) setActive(id);
        return { ...tab };
      },
      create: async (properties) => {
        const id = Math.max(0, ...tabs.keys()) + 1;
        const tab = { id, active: properties.active === true, url: properties.url || "chrome://newtab/" };
        tabs.set(id, tab);
        if (tab.active) setActive(id);
        for (const listener of tabCreated.listeners) await listener({ ...tab });
        return { ...tab };
      },
      remove: async (id) => {
        removedTabs.push(id);
        tabs.delete(id);
        for (const listener of tabRemoved.listeners) await listener(id);
      },
      sendMessage: async () => ({})
    },
    windows: {
      update: async (id, patch) => {
        focusedWindows.push({ id, patch });
        return { id, ...patch };
      }
    },
    webNavigation: { onBeforeNavigate: beforeNavigate }
  };

  const context = {
    chrome,
    IntentBrowserRules: helpers,
    URL,
    importScripts: () => {},
    setInterval: () => 0,
    setTimeout: (callback) => { Promise.resolve().then(callback); return 0; },
    clearTimeout: () => {}
  };
  vm.runInNewContext(source, context, { filename: "chrome-extension/background.js" });

  async function settle() {
    for (let index = 0; index < 8; index += 1) await Promise.resolve();
  }

  return {
    tabs, storage, nativeMessages, dynamicUpdates, removedTabs, focusedWindows,
    get dynamicRules() { return dynamicRules; },
    settle,
    async activate(id) {
      setActive(id);
      for (const listener of tabActivated.listeners) await listener({ tabId: id });
      await settle();
    },
    async create(tab) {
      tabs.set(tab.id, { ...tab });
      if (tab.active) setActive(tab.id);
      for (const listener of tabCreated.listeners) await listener({ ...tab });
      await settle();
    },
    async navigate(id, url) {
      for (const listener of beforeNavigate.listeners) {
        await listener({ tabId: id, frameId: 0, url });
      }
      await settle();
      if (!tabs.has(id)) return;
      const tab = tabs.get(id);
      tab.url = url;
      for (const listener of tabUpdated.listeners) {
        await listener(id, { url }, { ...tab });
      }
      await settle();
    },
    async remove(id) {
      await chrome.tabs.remove(id);
      await settle();
    },
    async message(message) {
      return new Promise((resolve) => {
        for (const listener of runtimeMessage.listeners) {
          const asyncResponse = listener(message, {}, resolve);
          if (asyncResponse !== true) resolve(asyncResponse);
        }
      });
    },
    async receiveNative(message) {
      for (const listener of nativeMessage.listeners) await listener(message);
      await settle();
    },
    async synchronizeStartupTabsConcurrently() {
      await Promise.all([
        context.synchronizeStartupTabs(),
        context.synchronizeStartupTabs()
      ]);
      await settle();
    }
  };
}

async function run() {
  const idle = createHarness({ active: false }, [
    { id: 1, active: true, url: "https://youtube.com/" }
  ]);
  await idle.settle();
  assert.equal(idle.dynamicRules.length, 0, "Listening mode must not block anything while Intent is idle");

  const lockedRules = {
    active: true,
    allowedWebsites: ["instagram.com/direct"],
    startupWebsites: [],
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: false
  };
  const startup = createHarness({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  }, [
    { id: 1, active: true, url: "chrome://newtab/" }
  ]);
  await startup.settle();
  await startup.receiveNative({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  });
  assert.equal(
    startup.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Chrome should replace its startup blank with the first allowed website"
  );
  assert.equal(startup.tabs.size, 1, "Chrome startup should not create an extra blank tab");

  const existingStartup = createHarness({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  }, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await existingStartup.settle();
  await existingStartup.receiveNative({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  });
  assert.equal(existingStartup.tabs.size, 1, "Chrome should not duplicate an open startup website");

  const concurrentStartup = createHarness({
    ...lockedRules,
    startupWebsites: [
      "https://www.instagram.com/direct/inbox/",
      "https://instagram.com/direct/inbox"
    ]
  }, [
    { id: 1, active: true, url: "https://example.com/" }
  ]);
  await concurrentStartup.settle();
  concurrentStartup.tabs.clear();
  concurrentStartup.tabs.set(1, { id: 1, active: true, url: "https://example.com/" });
  await concurrentStartup.synchronizeStartupTabsConcurrently();
  assert.equal(
    Array.from(concurrentStartup.tabs.values()).filter((tab) =>
      tab.url.includes("instagram.com/direct/inbox")
    ).length,
    1,
    "Concurrent Chrome startup passes must create only one copy of the same website"
  );
  const locked = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://youtube.com/" }
  ]);
  await locked.settle();
  assert.equal(locked.dynamicRules.some((rule) => rule.action.type === "block"), true, "Active rules need a main-frame block rule");
  assert.equal(locked.dynamicRules.some((rule) => rule.action.type === "allow"), true, "Allowed sites need a higher-priority allow rule");
  await locked.activate(2);
  assert.equal(locked.tabs.get(1).active, true, "Unallowed tab activation should return to Instagram");

  const allowed = createHarness(lockedRules, [
    { id: 1, windowId: 7, index: 0, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, windowId: 7, index: 1, active: false, url: "https://instagram.com/direct/t/123/" }
  ]);
  await allowed.settle();
  await allowed.activate(2);
  assert.equal(allowed.tabs.get(2).active, true, "Allowed tabs should remain selectable");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { tabID: 1, windowID: 7 }
  });
  assert.equal(allowed.tabs.get(1).active, true, "A native Ctrl+Tab command should activate an allowed tab");
  assert.equal(allowed.focusedWindows.at(-1).id, 7, "A native Ctrl+Tab command should focus the tab's browser window");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { tabID: 99, windowID: 8 }
  });
  assert.equal(allowed.tabs.get(1).active, true, "A stale or unallowed native tab command should do nothing");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { tabID: 2, windowID: 7, action: "close" }
  });
  assert.equal(allowed.tabs.has(2), false, "A native cleanup command should close its session-created tab");
  await allowed.remove(2);
  assert.equal(allowed.tabs.get(1).active, true, "Closing an allowed tab should return to another allowed tab");

  const closeBrowser = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" }
  ]);
  await closeBrowser.settle();
  await closeBrowser.remove(1);
  assert.equal(closeBrowser.tabs.size, 0, "Closing Chrome should not manufacture a recovery tab");

  const strictNewTab = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" }
  ]);
  await strictNewTab.settle();
  await strictNewTab.create({ id: 3, active: true, url: "chrome://new-tab-page/" });
  assert.equal(strictNewTab.tabs.has(3), true, "New tabs should always be creatable");
  await strictNewTab.navigate(3, "https://instagram.com/direct/inbox/");
  assert.equal(strictNewTab.tabs.has(3), true, "Typing an allowed website in a new tab should work without browser-search permission");
  assert.equal(strictNewTab.tabs.get(3).active, true, "The manually opened allowed website should remain active");

  const strictSearch = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" }
  ]);
  await strictSearch.settle();
  await strictSearch.create({ id: 3, active: true, url: "chrome://new-tab-page/" });
  await strictSearch.navigate(3, "https://www.google.com/search?q=intent");
  assert.equal(strictSearch.tabs.has(3), false, "A search submission should close when browser searches are disabled");
  assert.equal(strictSearch.tabs.get(1).active, true, "Closing a blocked search should return to an allowed tab");

  const searches = createHarness({ ...lockedRules, allowGoogleSearchTabs: true }, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" }
  ]);
  await searches.settle();
  await searches.create({ id: 3, active: true, url: "chrome://newtab/" });
  assert.equal(searches.tabs.has(3), true, "Search-enabled sessions should keep a Chrome new tab");
  await searches.navigate(3, "https://www.google.com/search?q=intent");
  assert.equal(searches.tabs.get(3).url, "https://www.google.com/search?q=intent", "Browser-search mode should allow Google result pages");
  assert.equal(searches.dynamicRules.some((rule) => String(rule.condition.regexFilter).includes("google")), true, "Google search pages need a DNR exception");

  const chromeTest = createHarness({
    ...lockedRules,
    allowedWebsites: ["youtube.com"]
  }, [
    { id: 1, active: true, url: "https://youtube.com/" },
    { id: 2, active: false, url: "https://github.com/" }
  ]);
  await chromeTest.settle();
  await chromeTest.activate(2);
  assert.equal(chromeTest.tabs.get(1).active, true, "A YouTube-only intention must reject an existing GitHub tab");

  const disabled = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://youtube.com/" }
  ], { guardEnabled: false });
  await disabled.settle();
  await disabled.activate(2);
  assert.equal(disabled.tabs.get(2).active, true, "A disabled guard must not enforce rules");
  await disabled.message({ type: "setGuardEnabled", enabled: true });
  await disabled.settle();
  assert.equal(disabled.storage.guardEnabled, true, "The toolbar toggle must persist in chrome.storage.local");
  assert.equal(disabled.nativeMessages.every((message) => message.browserBundleIdentifier === "com.google.Chrome"), true, "Chrome must identify itself to the native host");

  const contentSource = fs.readFileSync(path.join(root, "chrome-extension/content-guard.js"), "utf8");
  const documentListeners = {};
  const contentRuntimeMessage = event();
  const contentRules = { ...lockedRules, allowGoogleSearchTabs: true };
  const document = {
    addEventListener(type, listener) { documentListeners[type] = listener; }
  };
  const contentChrome = {
    runtime: {
      sendMessage: (_message, callback) => { callback(contentRules); return Promise.resolve(); },
      onMessage: contentRuntimeMessage
    }
  };
  vm.runInNewContext(contentSource, {
    chrome: contentChrome,
    document,
    IntentBrowserRules: helpers
  }, { filename: "chrome-extension/content-guard.js" });

  const blockedClick = {
    target: { closest: () => ({ href: "https://youtube.com/" }) },
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopImmediatePropagation() { this.stopped = true; }
  };
  documentListeners.click(blockedClick);
  assert.equal(blockedClick.prevented && blockedClick.stopped, true, "Unallowed links should do nothing before Chrome navigates");

  const allowedClick = {
    target: { closest: () => ({ href: "https://instagram.com/direct/inbox/" }) },
    prevented: false,
    preventDefault() { this.prevented = true; },
    stopImmediatePropagation() {}
  };
  documentListeners.click(allowedClick);
  assert.equal(allowedClick.prevented, false, "Allowed links should remain clickable");

  console.log("Chrome background behavior spec passed");
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
