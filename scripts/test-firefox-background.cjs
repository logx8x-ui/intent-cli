const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const helpers = require("../firefox-extension/rule-helpers.js");
const backgroundSource = fs.readFileSync(
  path.join(__dirname, "../firefox-extension/background.js"),
  "utf8"
);

function createHarness(activeRules, initialTabs, options = {}) {
  const tabs = new Map(initialTabs.map((tab) => [tab.id, { ...tab }]));
  const listeners = {
    onActivated: [],
    onUpdated: [],
    onCreated: [],
    onRemoved: [],
    onBeforeRequest: [],
    onMessage: []
  };
  const updates = [];
  const removals = [];
  const nativeMessages = [];
  const intervals = [];
  const storage = {
    guardEnabled: options.guardEnabled !== false
  };

  function setActiveTab(tabId) {
    for (const tab of tabs.values()) {
      tab.active = tab.id === tabId;
    }
  }

  const browser = {
    runtime: {
      onMessage: { addListener: (listener) => listeners.onMessage.push(listener) },
      sendNativeMessage: async (_hostName, message) => {
        nativeMessages.push(message);
        return activeRules;
      }
    },
    storage: {
      local: {
        get: async (defaults) => ({ ...defaults, ...storage }),
        set: async (values) => {
          Object.assign(storage, values);
        }
      }
    },
    tabs: {
      onActivated: { addListener: (listener) => listeners.onActivated.push(listener) },
      onUpdated: { addListener: (listener) => listeners.onUpdated.push(listener) },
      onCreated: { addListener: (listener) => listeners.onCreated.push(listener) },
      onRemoved: { addListener: (listener) => listeners.onRemoved.push(listener) },
      get: async (tabId) => tabs.get(tabId) ? { ...tabs.get(tabId) } : Promise.reject(new Error("missing tab")),
      query: async () => Array.from(tabs.values()).map((tab) => ({ ...tab })),
      update: async (tabId, patch) => {
        const tab = tabs.get(tabId);
        if (!tab) {
          throw new Error("missing tab");
        }
        Object.assign(tab, patch);
        if (patch.active) {
          setActiveTab(tabId);
        }
        updates.push({ tabId, patch });
        return { ...tab };
      },
      remove: async (tabId) => {
        removals.push(tabId);
        tabs.delete(tabId);
        for (const listener of listeners.onRemoved) {
          await listener(tabId);
        }
      },
      create: async (createProperties = {}) => {
        const id = createProperties.id ?? Math.max(0, ...tabs.keys()) + 1;
        const tab = {
          id,
          active: createProperties.active === true,
          url: createProperties.url ?? "about:blank"
        };
        tabs.set(id, tab);
        if (tab.active) {
          setActiveTab(id);
        }
        for (const listener of listeners.onCreated) {
          await listener({ ...tab });
        }
        return { ...tab };
      }
    },
    webRequest: {
      onBeforeRequest: {
        addListener: (listener) => listeners.onBeforeRequest.push(listener)
      }
    }
  };

  const context = {
    browser,
    IntentBrowserRules: helpers,
    URL,
    setInterval: (callback, delay) => {
      intervals.push({ callback, delay });
      return intervals.length;
    },
    setTimeout: (fn) => {
      Promise.resolve().then(fn);
      return 0;
    }
  };

  vm.runInNewContext(backgroundSource, context, { filename: "firefox-extension/background.js" });

  return {
    tabs,
    listeners,
    updates,
    removals,
    nativeMessages,
    intervals,
    storage,
    async message(message) {
      let response;
      for (const listener of listeners.onMessage) {
        response = await listener(message);
      }
      await Promise.resolve();
      return response;
    },
    async ready() {
      await context.refreshRules();
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async refresh() {
      await context.refreshRules();
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async synchronizeStartupTabsConcurrently() {
      await Promise.all([
        context.synchronizeStartupTabs(),
        context.synchronizeStartupTabs()
      ]);
      await Promise.resolve();
    },
    async activate(tabId) {
      setActiveTab(tabId);
      for (const listener of listeners.onActivated) {
        await listener({ tabId });
      }
      await Promise.resolve();
    },
    async update(tabId, changeInfo) {
      const tab = tabs.get(tabId);
      if (tab && changeInfo.url) {
        for (const listener of listeners.onBeforeRequest) {
          const response = await listener({ tabId, url: changeInfo.url, type: "main_frame" });
          if (response?.cancel) {
            await Promise.resolve();
            return response;
          }
        }
        tab.url = changeInfo.url;
      }
      for (const listener of listeners.onUpdated) {
        await listener(tabId, changeInfo, tab ? { ...tab } : {});
      }
      await Promise.resolve();
    },
    async create(tab) {
      tabs.set(tab.id, { ...tab });
      for (const listener of listeners.onCreated) {
        await listener({ ...tab });
      }
      await Promise.resolve();
      await Promise.resolve();
    },
    async remove(tabId) {
      await browser.tabs.remove(tabId);
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async receiveNative(message) {
      if (message?.tabCommand) {
        await context.handleRequestedTab(message.tabCommand);
      }
      await Promise.resolve();
    }
  };
}

async function run() {
  const lockedRules = {
    active: true,
    allowedWebsites: ["instagram.com/direct"],
    startupWebsites: [],
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: false
  };
  const startupRules = {
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  };

  const startupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  assert.deepEqual(
    startupHarness.intervals.map(({ delay }) => delay),
    [2000],
    "Firefox should keep only one low-frequency native heartbeat while idle"
  );
  await startupHarness.refresh();
  assert.equal(
    startupHarness.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Firefox should replace its startup blank with the first allowed website"
  );
  assert.equal(startupHarness.tabs.size, 1, "Firefox startup should not create an extra blank tab");

  const existingStartupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await existingStartupHarness.refresh();
  assert.equal(existingStartupHarness.tabs.size, 1, "Firefox should not duplicate an open startup website");

  const concurrentStartupHarness = createHarness({
    ...startupRules,
    startupWebsites: [
      "https://www.instagram.com/direct/inbox/",
      "https://instagram.com/direct/inbox"
    ]
  }, [
    { id: 1, active: true, url: "https://example.com/" }
  ]);
  await concurrentStartupHarness.ready();
  concurrentStartupHarness.tabs.clear();
  concurrentStartupHarness.tabs.set(1, { id: 1, active: true, url: "https://example.com/" });
  await concurrentStartupHarness.synchronizeStartupTabsConcurrently();
  assert.equal(
    Array.from(concurrentStartupHarness.tabs.values()).filter((tab) =>
      tab.url.includes("instagram.com/direct/inbox")
    ).length,
    1,
    "Concurrent Firefox startup passes must create only one copy of the same website"
  );

  const activationHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ]);
  await activationHarness.ready();
  const firefoxRuleRequestsBeforeActivation = activationHarness.nativeMessages.filter(
    (message) => message?.type === "getRules"
  ).length;
  await activationHarness.activate(2);
  assert.equal(activationHarness.tabs.get(1).active, true, "Unallowed tab activation should return to the allowed tab");
  assert.equal(
    activationHarness.nativeMessages.filter((message) => message?.type === "getRules").length,
    firefoxRuleRequestsBeforeActivation,
    "Firefox tab events should enforce cached rules without polling the native host"
  );

  const allowedActivationHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.instagram.com/direct/t/123/" }
  ]);
  await allowedActivationHarness.ready();
  await allowedActivationHarness.activate(2);
  assert.equal(allowedActivationHarness.tabs.get(2).active, true, "Allowed tab activation should stay active");
  await allowedActivationHarness.receiveNative({
    tabCommand: { tabID: 2, windowID: 1, action: "close" }
  });
  assert.equal(
    allowedActivationHarness.tabs.has(2),
    false,
    "A native cleanup command should close its session-created Firefox tab"
  );

  const navigationHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await navigationHarness.ready();
  await navigationHarness.activate(1);
  await navigationHarness.update(2, { url: "https://www.instagram.com/explore/" });
  assert.equal(navigationHarness.tabs.get(2).url, "https://www.instagram.com/direct/inbox/", "Unallowed navigation should be cancelled before the page changes");
  assert.equal(navigationHarness.tabs.get(1).active, true, "Blocked navigation should return to the allowed tab");

  const strictNewTabHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await strictNewTabHarness.ready();
  await strictNewTabHarness.create({ id: 3, active: true, url: "about:newtab" });
  assert.equal(strictNewTabHarness.tabs.has(3), true, "New tabs should always be creatable");
  await strictNewTabHarness.update(3, { url: "https://www.instagram.com/direct/inbox/" });
  await strictNewTabHarness.ready();
  assert.equal(strictNewTabHarness.tabs.has(3), true, "Typing an allowed website in a new tab should work without browser-search permission");
  assert.equal(strictNewTabHarness.tabs.get(3).active, true, "The manually opened allowed website should remain active");

  const strictSearchHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await strictSearchHarness.ready();
  await strictSearchHarness.create({ id: 3, active: true, url: "about:newtab" });
  await strictSearchHarness.update(3, { url: "https://www.google.com/search?q=intent" });
  await strictSearchHarness.ready();
  assert.equal(strictSearchHarness.tabs.has(3), false, "A search submission should close when browser searches are disabled");
  assert.equal(strictSearchHarness.tabs.get(1).active, true, "Closing a blocked search should return to an allowed tab");

  const searchRules = {
    ...lockedRules,
    allowGoogleSearchTabs: true
  };
  const searchHarness = createHarness(searchRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await searchHarness.ready();
  await searchHarness.activate(1);
  await searchHarness.create({ id: 3, active: true, url: "about:newtab" });
  assert.equal(searchHarness.tabs.has(3), true, "Google-search mode should allow a new search staging tab");
  await searchHarness.update(3, { url: "https://www.google.com/search?q=github" });
  assert.equal(searchHarness.tabs.get(3).url, "https://www.google.com/search?q=github", "Google result pages should remain usable");
  await searchHarness.update(3, { url: "https://github.com/" });
  assert.equal(searchHarness.tabs.get(3).url, "https://www.google.com/search?q=github", "Clicking through from Google to an unallowed site should be cancelled before the tab leaves search");

  await searchHarness.remove(3);
  assert.equal(searchHarness.tabs.has(3), false, "Search tabs should remain closable");
  assert.equal(searchHarness.tabs.get(1).active, true, "Closing a search tab should return to an allowed tab");

  const closeAllowedHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" },
    { id: 3, active: false, url: "https://www.instagram.com/direct/t/456/" }
  ]);
  await closeAllowedHarness.ready();
  await closeAllowedHarness.activate(1);
  await closeAllowedHarness.remove(1);
  assert.equal(closeAllowedHarness.tabs.has(1), false, "Allowed tabs should be closable");
  assert.equal(closeAllowedHarness.tabs.get(3).active, true, "Closing an allowed tab should land on another allowed tab, not the next unallowed tab");

  const closeOnlyAllowedHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ]);
  await closeOnlyAllowedHarness.ready();
  await closeOnlyAllowedHarness.activate(1);
  await closeOnlyAllowedHarness.remove(1);
  assert.equal(closeOnlyAllowedHarness.tabs.has(1), false, "The final allowed tab should still be closable");
  assert.equal(
    Array.from(closeOnlyAllowedHarness.tabs.values()).some((tab) =>
      tab.active && tab.url === "https://www.instagram.com/direct/inbox/"
    ),
    true,
    "Closing the final allowed tab should restore the startup website instead of exposing an unallowed tab"
  );

  const closeBrowserHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await closeBrowserHarness.ready();
  await closeBrowserHarness.remove(1);
  assert.equal(closeBrowserHarness.tabs.size, 0, "Closing Firefox should not manufacture a recovery tab");

  const typedUrlHarness = createHarness(searchRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await typedUrlHarness.ready();
  await typedUrlHarness.activate(1);
  await typedUrlHarness.create({ id: 4, active: true, url: "about:newtab" });
  await typedUrlHarness.update(4, { url: "https://youtube.com/" });
  assert.equal(typedUrlHarness.tabs.get(4).url, "about:newtab", "Typing an unallowed website should be cancelled before the search tab gets stuck");
  assert.equal(typedUrlHarness.tabs.get(1).active, true, "Blocked typed URL should return to an allowed tab");
  await typedUrlHarness.remove(4);
  assert.equal(typedUrlHarness.tabs.has(4), false, "Blocked search staging tabs should remain closable after a typed URL attempt");

  const disabledHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ], { guardEnabled: false });
  await disabledHarness.activate(2);
  assert.equal(disabledHarness.tabs.get(2).active, true, "Disabled guard should not change active tabs by itself");
  const status = await disabledHarness.message({ type: "getGuardStatus" });
  assert.equal(status.enabled, false, "Popup should report the persisted disabled state");
  await disabledHarness.message({ type: "setGuardEnabled", enabled: true });
  assert.equal(disabledHarness.storage.guardEnabled, true, "Popup toggle should persist the enabled state");
  assert.equal(
    disabledHarness.nativeMessages.some((message) => message?.type === "setGuardEnabled" && message.enabled === true),
    true,
    "Popup toggle should notify the native host"
  );

  const learningHarness = createHarness({ ...lockedRules, active: false }, [
    { id: 9, active: true, title: "OASIS | Curtin University", url: "https://oasis.curtin.edu.au/student" }
  ]);
  await learningHarness.ready();
  assert.equal(
    learningHarness.nativeMessages.some((message) =>
      message?.type === "recordWebsiteVisit" &&
      message.url === "https://oasis.curtin.edu.au" &&
      message.title === "OASIS | Curtin University"
    ),
    true,
    "Firefox should teach Intent a local domain and readable title without sending page paths"
  );
}

run()
  .then(() => {
    console.log("Firefox background behavior spec passed");
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
