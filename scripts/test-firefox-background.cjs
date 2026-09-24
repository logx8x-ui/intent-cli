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
    onCommitted: [],
    onActivated: [],
    onUpdated: [],
    onCreated: [],
    onRemoved: [],
    onBeforeRequest: [],
    onMessage: [],
    onWindowFocus: []
  };
  const updates = [];
  const focusedWindows = [];
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
    windows: {
      getAll: async () => [...new Set(Array.from(tabs.values(), tab => tab.windowId).filter(Number.isInteger))].map(id => ({ id, left: id * 20, top: 50, width: 900, height: 700, focused: id === 1 })),
      onFocusChanged: { addListener: listener => listeners.onWindowFocus.push(listener) },
      update: async (id, patch) => { focusedWindows.push(id); return { id, ...patch }; }
    },
    webNavigation: { onCommitted: { addListener: listener => listeners.onCommitted.push(listener) } },
    webRequest: {
      onBeforeRequest: {
        addListener: (listener) => listeners.onBeforeRequest.push(listener)
      }
    }
  };

  if (options.withCommandPort) {
    const messages = [];
    browser.runtime.connectNative = () => ({
      onMessage: { addListener: listener => messages.push(listener) },
      onDisconnect: { addListener() {} },
      postMessage(message) {
        nativeMessages.push(message);
        Promise.resolve().then(() => messages.forEach(listener => listener(activeRules)));
      }
    });
  }
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
  if (Array.isArray(activeRules.selectedTabIDs) && activeRules.selectedBrowserSessionID === undefined) {
    activeRules = { ...activeRules, selectedBrowserSessionID: vm.runInNewContext("browserSessionID", context) };
  }

  return {
    tabs,
    effectiveRules: context.effectiveRules,
    browserSessionID: () => vm.runInNewContext("browserSessionID", context),
    async command(message) {
      await context.handleRequestedTab(message);
      for (let i = 0; i < 48; i++) await Promise.resolve();
    },
    async snapshot() {
      await context.publishTabSnapshot(true, true);
      for (let i = 0; i < 32; i++) await Promise.resolve();
      return nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1);
    },
    listeners,
    updates,
    focusedWindows,
    async focusWindow(id) {
      for (const listener of listeners.onWindowFocus) await listener(id);
    },
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
    async commit(id, url, transitionType) {
      tabs.get(id).url = url;
      for (const listener of listeners.onCommitted) await listener({tabId: id, frameId: 0, url, transitionType});
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
  for (const searches of [false, true]) {
    const navigation = createHarness({active: true, accessMode: "whitelist", selectedTabIDs: [1], allowedWebsites: [], startupWebsites: [], blockNavigation: true, allowGoogleSearchTabs: searches}, [{id: 1, windowId: 1, active: true, url: "https://discord.com/channels/a"}]);
    await navigation.ready();
    await navigation.create({id: 2, windowId: 1, active: false, url: "about:blank"});
    await navigation.commit(2, "https://unrelated.example/", "typed");
    assert.equal(navigation.tabs.get(2).url, searches ? "about:blank" : "https://unrelated.example/", "Search-authorized new tabs reject typed destinations; unselected tabs are never mutated");

    await navigation.commit(1, "https://discord.com/channels/b", "link");
    assert.equal(navigation.tabs.get(1).url, "https://discord.com/channels/b", "Normal links remain usable");
    await navigation.commit(1, "https://unrelated.example/", "typed");
    assert.equal(navigation.tabs.get(1).url, "https://discord.com/channels/b", "Typed arbitrary destinations return to the last committed page");
    await navigation.commit(1, "https://www.google.com/search?q=study", "generated");
    assert.equal(navigation.tabs.get(1).url, searches ? "https://www.google.com/search?q=study" : "https://discord.com/channels/b", "Address-bar searches require Searches");
    if (searches) {
      await navigation.commit(1, "https://unrelated.example/result", "link");
      assert.equal(navigation.tabs.get(1).url, "https://www.google.com/search?q=study", "Search result links stay on results even in a selected tab");
    }
  }

  const commands = createHarness({ active: false }, [
    { id: 61, windowId: 6, index: 0, active: true, url: "https://example.org/" },
    { id: 62, windowId: 6, index: 1, active: false, url: "https://example.com/" }
  ], { withCommandPort: true });
  await commands.ready();
  const initialUpdates = commands.updates.length;
  for (const action of ["activate", "close", "preview"]) {
    for (const invalid of [
      { windowID: 6 },
      { windowID: 6, browserSessionID: "stale-browser-lifetime" },
      { windowID: 99, browserSessionID: commands.browserSessionID() }
    ]) {
      const id = `invalid-${action}-${invalid.windowID}-${invalid.browserSessionID || "missing"}`;
      await commands.command({ action, id, tabID: 62, ...invalid });
      assert.equal(commands.tabs.has(62), true, "A missing/stale/window-mismatched command must never close a current tab");
      assert.equal(commands.tabs.get(61).active, true, "Invalid commands must never activate a reused tab ID");
      if (action === "preview") assert.ok(commands.nativeMessages.some(message => message.preview?.requestID === id && message.preview.error), "Rejected preview replies with an explicit error instead of timing out");
    }
  }
  assert.equal(commands.updates.length, initialUpdates, "Invalid commands perform no tab mutation");
  assert.equal(commands.focusedWindows.length, 0, "Invalid commands never change window focus");
  await commands.command({ action: "activate", tabID: 62, windowID: 6, browserSessionID: commands.browserSessionID() });
  assert.equal(commands.tabs.get(62).active, true, "A current-session command activates the exact current-window target");
  await commands.command({ action: "close", tabID: 62, windowID: 6, browserSessionID: commands.browserSessionID() });
  assert.equal(commands.tabs.has(62), false, "A current-session close command still works for the exact target");
  const mixedTabs = [
    { id: 1, windowId: 1, index: 0, active: true, url: "https://example.org/" },
    { id: 2, windowId: 1, index: 1, active: false, url: "file:///tmp/guide.pdf", highlighted: true },
    { id: 3, windowId: 1, index: 2, active: false, url: "about:newtab", highlighted: true },
    { id: 4, windowId: 1, index: 3, active: false, url: "", highlighted: true },
    { id: 5, windowId: 1, index: 4, active: false, url: "https://example.org/", highlighted: true, pinned: true, discarded: true }
  ];
  const discovery = createHarness({ active: false }, mixedTabs, { withCommandPort: true });
  await discovery.ready();
  const metadata = await discovery.snapshot();
  assert.deepEqual(Array.from(metadata.tabs, tab => tab.id), [1, 2, 3, 4, 5], "Discovery includes local PDF, internal, blank, pinned and discarded actual tabs");
  assert.deepEqual(Array.from(metadata.tabs.filter(tab => tab.highlighted), tab => tab.id), [2, 3, 4, 5], "Native Shift-selected group reaches Intent intact");
  assert.equal(metadata.tabs[4].pinned && metadata.tabs[4].discarded, true);
  assert.equal(metadata.tabs[0].windowFrame.left, 20, "Window geometry identifies same-title browser windows");
  assert.equal(metadata.tabs[0].windowFocused, true, "Browser focus disambiguates overlapping windows");
  assert.ok(metadata.browserSessionID, "Every snapshot carries a browser-session identity");
  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1] }).active, false, "Missing identity cannot authorize a potentially reused tab ID");
  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1], selectedBrowserSessionID: "previous-browser-session" }).active, false, "Old exact-ID rules cannot target tabs after restart");
  const restartedBrowser = createHarness({ active: false }, mixedTabs, { withCommandPort: true });
  await restartedBrowser.ready();
  assert.notEqual((await restartedBrowser.snapshot()).browserSessionID, metadata.browserSessionID, "New Firefox background lifetimes cannot reuse staged tab identities");
  for (const accessMode of ["whitelist", "blacklist"]) {
    const group = createHarness({ active: true, accessMode, selectedTabIDs: [2, 3, 4, 5], allowedWebsites: [], startupWebsites: [], blockTabSwitching: true, blockNavigation: true, blockNewTabs: true }, mixedTabs);
    await group.ready();
    for (const id of [2, 3, 4, 5]) {
      await group.activate(id);
      assert.equal(group.tabs.get(id).active, accessMode === "whitelist", "Every selected group member receives the same allow/block policy, regardless of content");
      assert.equal(group.tabs.has(id), true, "Policy preserves actual selected tabs");
    }
    assert.deepEqual(Array.from(group.tabs.values(), tab => tab.url), mixedTabs.map(tab => tab.url), "Applying the group never rewrites tab URLs");
    if (accessMode === "blacklist") {
      await group.create({ id: 9, windowId: 1, index: 5, active: true, openerTabId: 2, url: "https://child.example/" });
      assert.equal(group.tabs.get(9)?.url, "https://child.example/", "A blocked tab's new child is preserved without closing or URL replacement");
      assert.equal(group.tabs.get(2)?.url, "file:///tmp/guide.pdf", "The original blocked parent is also preserved");
    }
  }

  const selectedOnly = createHarness({
    active: true, accessMode: "whitelist", allowedWebsites: ["example.org/work"],
    startupWebsites: [], selectedTabIDs: [7], blockTabSwitching: true,
    blockNavigation: true, blockNewTabs: true
  }, [
    { id: 7, windowId: 1, index: 0, active: false, url: "https://example.org/work" },
    { id: 8, windowId: 1, index: 1, active: true, url: "https://example.org/work" }
  ]);
  await selectedOnly.refresh();
  assert.equal(selectedOnly.tabs.get(7).active, true, "Starting Quick Focus selects an allowed tab");
  await selectedOnly.activate(8);
  assert.equal(selectedOnly.tabs.get(7).active, true, "Unselected same-URL tabs must not become allowed");
  assert.equal(selectedOnly.tabs.get(8).url, "https://example.org/work", "Existing unselected tabs are preserved");
  selectedOnly.tabs.get(8).windowId = 2;
  selectedOnly.tabs.get(8).active = true;
  await selectedOnly.focusWindow(2);
  assert.equal(selectedOnly.focusedWindows.at(-1), 1, "Window focus must return to a selected tab's window");
  await selectedOnly.create({ id: 9, windowId: 1, active: true, url: "https://example.org/work" });
  assert.equal(selectedOnly.tabs.get(7).active, true, "New tabs cannot bypass selected-tab scope");

  for (const url of ["https://discord.com/channels/1/2", "https://discord.com/channels/1/3", "https://another-site.example/new"]) {
    await selectedOnly.update(7, { url });
    assert.equal(selectedOnly.tabs.get(7).url, url, "Selected tab allows channel changes and cross-site navigation");
    await selectedOnly.activate(8);
    assert.equal(selectedOnly.tabs.get(7).active, true, "Navigation never grants another tab access");
  }

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
    { id: 1, windowId: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, windowId: 1, active: false, url: "https://www.instagram.com/direct/t/123/" }
  ]);
  await allowedActivationHarness.ready();
  await allowedActivationHarness.activate(2);
  assert.equal(allowedActivationHarness.tabs.get(2).active, true, "Allowed tab activation should stay active");
  await allowedActivationHarness.receiveNative({
    tabCommand: { browserSessionID: allowedActivationHarness.browserSessionID(), tabID: 2, windowID: 1, action: "close" }
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
  assert.equal(blacklistHarness.tabs.has(2), true, "Firefox blacklist mode must preserve already-open blocked websites");
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

  const markedBlockRules = { ...blacklistRules, selectedTabIDs: [2] };
  const markedBlock = createHarness(markedBlockRules, [
    {id: 1, active: true, url: "https://youtube.com/", windowId: 1},
    {id: 2, active: false, url: "https://youtube.com/", windowId: 1},
    {id: 3, active: false, url: "https://example.org/", windowId: 1}
  ]);
  await markedBlock.ready();
  await markedBlock.activate(2);
  await markedBlock.ready();
  assert.equal(markedBlock.tabs.has(2), true, "Marked blacklist tab is retained");
  assert.equal(markedBlock.tabs.get(2).url, "https://youtube.com/", "Marked blacklist URL is retained");
  assert.equal(markedBlock.tabs.get(1).active, true, "Same-URL unmarked tab stays usable");
  await markedBlock.activate(3);
  await markedBlock.ready();
  assert.equal(markedBlock.tabs.get(3).active, true, "Unmarked tab stays usable");

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
