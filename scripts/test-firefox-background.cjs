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
  const reloads = [];
  const removals = [];
  const nativeMessages = [];
  const intervals = [];
  const storage = {
    guardEnabled: options.guardEnabled !== false,
    ...(options.storage || {})
  };

  function setActiveTab(tabId) {
    for (const tab of tabs.values()) {
      tab.active = tab.id === tabId;
    }
  }

  const browser = {
    runtime: {
      getManifest: () => require("../firefox-extension/manifest.json"),
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
        if (patch.active === false && tab.active && tabs.size === 1) {
          throw new Error("cannot deactivate the only tab");
        }
        Object.assign(tab, patch);
        if (patch.active) {
          setActiveTab(tabId);
        }
        updates.push({ tabId, patch });
        return { ...tab };
      },
      reload: async (tabId) => {
        if (!tabs.has(tabId)) throw new Error("missing tab");
        reloads.push(tabId);
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
    reloads,
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
    async emitUpdated(tabId, changeInfo, tabOverride) {
      const tab = tabOverride || tabs.get(tabId) || {};
      for (const listener of listeners.onUpdated) {
        await listener(tabId, changeInfo, { ...tab });
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
    startupSessionID: "firefox-startup-session",
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
    [3000],
    "Firefox should keep only one low-frequency native heartbeat while idle"
  );
  await startupHarness.refresh();
  assert.ok(
    startupHarness.nativeMessages.some((message) =>
      message.extensionVersion === require("../firefox-extension/manifest.json").version &&
      message.extensionCapabilities?.includes("single-startup-launch-v1")
    ),
    "Firefox should identify a startup-safe Browser Guard to the native host"
  );
  assert.equal(
    startupHarness.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Firefox should replace its startup blank with the first allowed website"
  );
  assert.equal(startupHarness.tabs.size, 1, "Firefox startup should not create an extra blank tab");
  await startupHarness.emitUpdated(1, { status: "complete" }, {
    id: 1,
    active: true,
    url: "about:blank"
  });
  assert.equal(
    startupHarness.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "A late completion event from Firefox's replaced blank tab must not interrupt Instagram startup"
  );
  assert.equal(
    startupHarness.storage.completedStartupSessionID,
    startupRules.startupSessionID,
    "Firefox should persist the completed startup session before opening its website"
  );

  const lateFirefoxWindow = createHarness({
    ...startupRules,
    startupSessionID: "firefox-late-window-session"
  }, []);
  await lateFirefoxWindow.refresh();
  await lateFirefoxWindow.create({ id: 1, active: true, url: "about:blank" });
  assert.equal(
    lateFirefoxWindow.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Firefox should spend the one startup launch when its first tab appears late"
  );

  const restartedStartupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "about:blank" }
  ], { storage: startupHarness.storage });
  await restartedStartupHarness.refresh();
  assert.equal(
    restartedStartupHarness.tabs.get(1).url,
    "about:blank",
    "Restarting Firefox Browser Guard must not reopen a completed session website"
  );

  const existingStartupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await existingStartupHarness.refresh();
  assert.equal(existingStartupHarness.tabs.size, 1, "Firefox should not duplicate an open startup website");
  assert.deepEqual(
    existingStartupHarness.reloads,
    [1],
    "Firefox should deliberately load an existing startup tab once instead of trusting a suspended or half-restored page"
  );
  await existingStartupHarness.refresh();
  assert.deepEqual(
    existingStartupHarness.reloads,
    [1],
    "Firefox must not reload an existing startup tab again during the same intention session"
  );

  const existingRootStartupHarness = createHarness({
    ...startupRules,
    startupSessionID: "firefox-existing-root-session",
    allowedWebsites: ["instagram.com"],
    startupWebsites: ["https://www.instagram.com/"]
  }, [
    { id: 1, active: true, url: "https://www.instagram.com/?variant=following", status: "complete" }
  ]);
  await existingRootStartupHarness.refresh();
  assert.equal(existingRootStartupHarness.tabs.size, 1, "A broad website intention should reuse its existing tab");
  assert.equal(
    existingRootStartupHarness.tabs.get(1).url,
    "https://www.instagram.com/",
    "Reused website tabs must navigate to the configured startup URL instead of showing stale content"
  );
  assert.equal(
    existingRootStartupHarness.updates.filter(({ patch }) => patch.url === "https://www.instagram.com/").length,
    1,
    "A reused website tab must load exactly once for the new intention session"
  );

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
  assert.equal(
    Array.from(concurrentStartupHarness.tabs.values()).filter((tab) =>
      tab.url.includes("instagram.com/direct/inbox")
    ).length,
    1,
    "Equivalent Firefox startup URLs must create only one copy of the website"
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

  const redirectHarness = createHarness({
    ...lockedRules,
    startupSessionID: "firefox-outlook-redirect-session",
    allowedWebsites: ["outlook.cloud.microsoft/mail/inbox/id/message"],
    startupWebsites: ["https://outlook.cloud.microsoft/mail/inbox/id/message"]
  }, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  await redirectHarness.refresh();
  await redirectHarness.activate(1);
  const firefoxStartupUpdates = () => redirectHarness.updates.filter(
    ({ patch }) => patch.url === "https://outlook.cloud.microsoft/mail/inbox/id/message"
  ).length;
  assert.equal(firefoxStartupUpdates(), 1, "Firefox should launch an Outlook startup URL once");
  const shellRedirect = await redirectHarness.update(1, {
    url: "https://outlook.cloud.microsoft/mail/"
  });
  assert.equal(shellRedirect?.cancel, undefined, "Outlook's same-host startup shell redirect must load");
  assert.equal(
    redirectHarness.tabs.get(1).url,
    "https://outlook.cloud.microsoft/mail/",
    "Outlook's shell redirect should not leave a partially loaded startup page"
  );
  await redirectHarness.emitUpdated(1, { status: "complete" });
  assert.equal(
    firefoxStartupUpdates(),
    1,
    "An Outlook redirect must never make Firefox reload the startup URL"
  );
  assert.equal(redirectHarness.tabs.size, 1, "An Outlook redirect must never create replacement tabs");
  const laterSameHostEscape = await redirectHarness.update(1, {
    url: "https://outlook.cloud.microsoft/calendar/"
  });
  assert.equal(
    laterSameHostEscape?.cancel,
    true,
    "Same-host navigation outside the configured Outlook path must be blocked after startup settles"
  );

  const crossHostRedirectHarness = createHarness({
    ...lockedRules,
    startupSessionID: "firefox-cross-host-redirect-session",
    allowedWebsites: ["instagram.com"],
    startupWebsites: ["https://www.instagram.com/"]
  }, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  await crossHostRedirectHarness.refresh();
  const crossHostRedirect = await crossHostRedirectHarness.update(1, {
    url: "https://example.com/escape"
  });
  assert.equal(crossHostRedirect?.cancel, true, "Startup grace must not allow cross-site escapes");

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
    false,
    "Closing the final allowed tab must not reopen a website that already started once"
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

  const blacklistRules = {
    ...lockedRules,
    accessMode: "blacklist",
    allowedWebsites: ["youtube.com"],
    startupWebsites: []
  };
  const blacklistHarness = createHarness(blacklistRules, [
    { id: 1, active: true, url: "https://wikipedia.org/wiki/Focus" },
    { id: 2, active: false, url: "https://youtube.com/watch?v=1" }
  ]);
  await blacklistHarness.ready();
  assert.equal(blacklistHarness.tabs.has(1), true, "Firefox blacklist mode should preserve unlisted websites");
  assert.equal(blacklistHarness.tabs.has(2), false, "Firefox blacklist mode should remove already-open blocked websites");
  const blockedNavigation = await blacklistHarness.update(1, { url: "https://youtube.com/watch?v=2" });
  assert.equal(blockedNavigation.cancel, true, "Firefox should cancel blacklisted navigation before it commits");
  assert.equal(
    blacklistHarness.tabs.get(1).url,
    "https://wikipedia.org/wiki/Focus",
    "Firefox should retain the last permitted page after blocking navigation"
  );
  const blacklistBlankHarness = createHarness(blacklistRules, [
    { id: 1, active: true, url: "about:newtab" }
  ]);
  await blacklistBlankHarness.ready();
  const blockedFromBlank = await blacklistBlankHarness.update(1, {
    url: "https://youtube.com/watch?v=3"
  });
  await blacklistBlankHarness.ready();
  assert.equal(blockedFromBlank.cancel, true, "Firefox should cancel a blacklisted URL entered in a new tab");
  assert.equal(
    blacklistBlankHarness.tabs.get(1).url,
    "about:newtab",
    "A blacklisted site entered from a fresh Firefox tab should return to a clean tab"
  );

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
