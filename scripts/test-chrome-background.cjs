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
  const storage = {
    guardEnabled: options.guardEnabled !== false,
    ...(options.storage || {})
  };
  const nativeMessages = [];
  const dynamicUpdates = [];
  const removedTabs = [];
  const updates = [];
  const focusedWindows = [];
  const intervals = [];
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
      getManifest: () => require("../chrome-extension/manifest.json"),
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
        if (patch.active === false && tab.active && tabs.size === 1) {
          throw new Error("cannot deactivate the only tab");
        }
        Object.assign(tab, patch);
        if (patch.active) setActive(id);
        updates.push({ tabId: id, patch });
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
    setInterval: (callback, delay) => {
      intervals.push({ callback, delay });
      return intervals.length;
    },
    setTimeout: (callback) => { Promise.resolve().then(callback); return 0; },
    clearTimeout: () => {}
  };
  vm.runInNewContext(source, context, { filename: "chrome-extension/background.js" });

  async function settle() {
    for (let index = 0; index < 24; index += 1) await Promise.resolve();
  }

  return {
    tabs, storage, nativeMessages, dynamicUpdates, removedTabs, focusedWindows, intervals, updates,
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
  assert.ok(
    idle.nativeMessages.some((message) =>
      message.extensionVersion === require("../chrome-extension/manifest.json").version &&
      message.extensionCapabilities?.includes("single-startup-launch-v1")
    ),
    "Chrome should identify a startup-safe Browser Guard to the native host"
  );
  assert.equal(idle.dynamicRules.length, 0, "Listening mode must not block anything while Intent is idle");
  assert.deepEqual(
    idle.intervals.map(({ delay }) => delay),
    [3000],
    "Chrome should keep only one low-frequency native heartbeat while idle"
  );

  const lockedRules = {
    active: true,
    startupSessionID: "chrome-startup-session",
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
  assert.equal(
    startup.storage.completedStartupSessionID,
    "chrome-startup-session",
    "Chrome should persist the completed startup session before opening its website"
  );

  const lateChromeWindow = createHarness({
    ...lockedRules,
    startupSessionID: "chrome-late-window-session",
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  }, []);
  await lateChromeWindow.settle();
  await lateChromeWindow.create({ id: 1, active: true, url: "chrome://newtab/" });
  assert.equal(
    lateChromeWindow.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Chrome should spend the one startup launch when its first tab appears late"
  );

  const restartedStartup = createHarness({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  }, [
    { id: 1, active: true, url: "chrome://newtab/" }
  ], { storage: startup.storage });
  await restartedStartup.settle();
  assert.equal(
    restartedStartup.tabs.get(1).url,
    "chrome://newtab/",
    "Restarting Chrome Browser Guard must not reopen a completed session website"
  );

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
  await concurrentStartup.receiveNative({
    ...lockedRules,
    startupSessionID: "chrome-equivalent-startup-session-ready",
    startupWebsites: [
      "https://www.instagram.com/direct/inbox/",
      "https://instagram.com/direct/inbox"
    ]
  });
  assert.equal(
    Array.from(concurrentStartup.tabs.values()).filter((tab) =>
      tab.url.includes("instagram.com/direct/inbox")
    ).length,
    1,
    "Equivalent Chrome startup URLs must create only one copy of the website"
  );
  const locked = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://youtube.com/" }
  ]);
  await locked.settle();
  assert.equal(locked.dynamicRules.some((rule) => rule.action.type === "block"), true, "Active rules need a main-frame block rule");
  assert.equal(locked.dynamicRules.some((rule) => rule.action.type === "allow"), true, "Allowed sites need a higher-priority allow rule");
  const chromeRuleRequestsBeforeActivation = locked.nativeMessages.filter(
    (message) => message?.type === "getRules"
  ).length;
  await locked.activate(2);
  assert.equal(locked.tabs.get(1).active, true, "Unallowed tab activation should return to Instagram");
  assert.equal(
    locked.nativeMessages.filter((message) => message?.type === "getRules").length,
    chromeRuleRequestsBeforeActivation,
    "Chrome tab events should enforce cached rules without polling the native host"
  );

  const redirect = createHarness({
    ...lockedRules,
    startupSessionID: "chrome-outlook-redirect-session",
    allowedWebsites: ["outlook.cloud.microsoft/mail/inbox/id/message"],
    startupWebsites: ["https://outlook.cloud.microsoft/mail/inbox/id/message"]
  }, [
    { id: 1, active: true, url: "chrome://newtab/" }
  ]);
  await redirect.settle();
  const chromeStartupUpdates = () => redirect.updates.filter(
    ({ patch }) => patch.url === "https://outlook.cloud.microsoft/mail/inbox/id/message"
  ).length;
  assert.equal(chromeStartupUpdates(), 1, "Chrome should launch an Outlook startup URL once");
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await redirect.navigate(1, "https://outlook.cloud.microsoft/mail/");
  }
  assert.equal(
    chromeStartupUpdates(),
    1,
    "An Outlook redirect must never make Chrome reload the startup URL"
  );
  assert.equal(redirect.tabs.size, 1, "An Outlook redirect must never create replacement tabs");

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

  const closeOnlyAllowed = createHarness({
    ...lockedRules,
    startupSessionID: "chrome-close-startup-session",
    startupWebsites: ["https://instagram.com/direct/inbox/"]
  }, [
    { id: 1, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://youtube.com/" }
  ]);
  await closeOnlyAllowed.settle();
  await closeOnlyAllowed.remove(1);
  assert.equal(
    Array.from(closeOnlyAllowed.tabs.values()).some((tab) =>
      tab.url === "https://instagram.com/direct/inbox/"
    ),
    false,
    "Closing the final Chrome startup tab must not reopen a website that already started once"
  );

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

  const blacklistRules = {
    ...lockedRules,
    accessMode: "blacklist",
    allowedWebsites: ["youtube.com"],
    startupWebsites: []
  };
  const blacklist = createHarness(blacklistRules, [
    { id: 1, active: true, url: "https://wikipedia.org/wiki/Focus" },
    { id: 2, active: false, url: "https://youtube.com/watch?v=1" }
  ]);
  await blacklist.settle();
  await blacklist.receiveNative(blacklistRules);
  assert.equal(blacklist.tabs.has(1), true, "Chrome blacklist mode should preserve unlisted websites");
  assert.equal(blacklist.tabs.has(2), false, "Chrome blacklist mode should remove already-open blocked websites");
  assert.equal(
    blacklist.dynamicRules.some((rule) =>
      rule.action.type === "block" && String(rule.condition.regexFilter).includes("youtube")
    ),
    true,
    "Chrome blacklist mode should install a direct block rule for each blocked website"
  );
  assert.equal(
    blacklist.dynamicRules.some((rule) => rule.action.type === "allow"),
    false,
    "Chrome blacklist mode should not install whitelist allow rules"
  );
  await blacklist.navigate(1, "https://youtube.com/watch?v=2");
  assert.equal(
    blacklist.tabs.get(1).url,
    "https://wikipedia.org/wiki/Focus",
    "Blocked Chrome navigation should immediately restore the last permitted page"
  );
  const blacklistBlank = createHarness(blacklistRules, [
    { id: 1, active: true, url: "chrome://newtab/" }
  ]);
  await blacklistBlank.settle();
  await blacklistBlank.navigate(1, "https://youtube.com/watch?v=3");
  assert.equal(
    blacklistBlank.tabs.get(1).url.replace(/\/$/, ""),
    "chrome://newtab",
    "A blacklisted site entered from a fresh Chrome tab should return to a clean tab"
  );

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

  const learning = createHarness({ ...lockedRules, active: false }, [
    { id: 9, active: true, title: "Wikipedia, the free encyclopedia", url: "https://en.wikipedia.org/wiki/Intent" }
  ]);
  await learning.settle();
  assert.equal(
    learning.nativeMessages.some((message) =>
      message?.type === "recordWebsiteVisit" &&
      message.url === "https://en.wikipedia.org" &&
      message.title === "Wikipedia, the free encyclopedia"
    ),
    true,
    "Chrome should teach Intent a local domain and readable title without sending page paths"
  );

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
