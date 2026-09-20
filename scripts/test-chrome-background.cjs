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
  const tabs = new Map(initialTabs.map((tab, index) => [tab.id, { index, highlighted: Boolean(tab.active), ...tab }]));
  const storage = {
    guardEnabled: options.guardEnabled !== false,
    ...(options.storage || {})
  };
  const sessionStorage = options.sessionStorage || {};
  // Model a modern native host: each exact-ID policy carries its browser lifetime.
  if (Array.isArray(nativeRules.selectedTabIDs) && nativeRules.selectedBrowserSessionID === undefined) {
    sessionStorage.intentBrowserSessionID ||= `chrome-fixture-${Math.random()}`;
    nativeRules = { ...nativeRules, selectedBrowserSessionID: sessionStorage.intentBrowserSessionID };
  }
  const nativeMessages = [];
  const dynamicUpdates = [];
  const sessionUpdates = [];
  const removedTabs = [];
  const updates = [];
  const reloads = [];
  const extensionReloads = [];
  const focusedWindows = [];
  const highlightUpdates = [];
  let interruptReturnWithTab = null;
  const intervals = [];
  let dynamicRules = [];
  let sessionRules = [];

  const runtimeMessage = event();
  const tabActivated = event();
  const tabUpdated = event();
  const tabCreated = event();
  const tabRemoved = event();
  const tabHighlighted = event();
  const beforeNavigate = event();
  const nativeMessage = event();
  const nativeDisconnect = event();
  const windowFocus = event();

  function setActive(id) {
    const target = tabs.get(id);
    if (!target) return;
    // Chromium ActivateTabAt resets native highlighted selection in this window.
    for (const tab of tabs.values()) if (tab.windowId === target.windowId) {
      tab.active = tab.id === id;
      tab.highlighted = tab.id === id;
    }
    for (const listener of tabHighlighted.listeners) listener({ windowId: target.windowId, tabIds: [id] });
  }

  function setHighlighted(ids, windowId) {
    for (const tab of tabs.values()) if (tab.windowId === windowId) {
      tab.active = tab.id === ids[0];
      tab.highlighted = ids.includes(tab.id);
    }
    for (const listener of tabHighlighted.listeners) listener({ windowId, tabIds: ids });
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
      reload: () => extensionReloads.push(true),
      getManifest: () => require("../chrome-extension/manifest.json"),
      onMessage: runtimeMessage,
      onStartup: event(),
      onInstalled: event()
    },
    storage: { session: { get: async () => ({ ...sessionStorage }), set: async values => Object.assign(sessionStorage, values) }, local: {
      get: async (defaults) => ({ ...defaults, ...storage }),
      set: async (values) => Object.assign(storage, values)
    } },
    declarativeNetRequest: {
      getDynamicRules: async () => dynamicRules.map((rule) => ({ ...rule })),
      updateDynamicRules: async ({ removeRuleIds, addRules }) => {
        dynamicRules = dynamicRules.filter((rule) => !removeRuleIds.includes(rule.id)).concat(addRules);
        dynamicUpdates.push({ removeRuleIds, addRules });
      },
      getSessionRules: async () => sessionRules.map((rule) => ({ ...rule })),
      updateSessionRules: async ({ removeRuleIds, addRules }) => {
        sessionRules = sessionRules.filter((rule) => !removeRuleIds.includes(rule.id)).concat(addRules);
        sessionUpdates.push({ removeRuleIds, addRules });
      }
    },
    tabs: {
      onActivated: tabActivated,
      onUpdated: tabUpdated,
      onCreated: tabCreated,
      onRemoved: tabRemoved,
      onHighlighted: tabHighlighted,
      query: async (query = {}) => {
        const beforeQuery = options.beforeTabQuery?.(query);
        if (beforeQuery) await beforeQuery;
        const result = Array.from(tabs.values())
          .filter(tab => (query.windowId == null || tab.windowId === query.windowId) && (query.active == null || tab.active === query.active))
          .map((tab) => ({ ...tab }));
        options.onTabQuery?.(query, tabs, { highlight: setHighlighted });
        return result;
      },
      captureVisibleTab: async (windowId) => {
        if (options.failPreviewCapture) throw new Error("capture denied");
        const tab = Array.from(tabs.values()).find(tab => tab.windowId === windowId && tab.active);
        return `data:image/jpeg;base64,${Buffer.from(String(tab?.id)).toString("base64")}`;
      },
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
      highlight: async ({ windowId, tabs: indices }) => {
        const selected = Array.from(indices, index => Array.from(tabs.values()).find(tab => tab.windowId === windowId && tab.index === index));
        if (selected.some(tab => !tab)) throw new Error("missing tab index");
        highlightUpdates.push({ windowId, indices: Array.from(indices), tabIDs: selected.map(tab => tab.id) });
        setHighlighted(selected.map(tab => tab.id), windowId);
        return { id: windowId };
      },
      reload: async (id) => {
        if (!tabs.has(id)) throw new Error("missing tab");
        reloads.push(id);
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
      getAll: async () => {
        const pending = options.beforeWindowQuery?.();
        if (pending) await pending;
        return [...new Set(Array.from(tabs.values(), tab => tab.windowId).filter(Number.isInteger))].map(id => ({ id, left: id * 20, top: 50, width: 900, height: 700, focused: id === 1 }));
      },
      onFocusChanged: windowFocus,
      update: async (id, patch) => {
        focusedWindows.push({ id, patch });
        if (interruptReturnWithTab !== null) {
          const tabId = interruptReturnWithTab; interruptReturnWithTab = null;
          setActive(tabId);
          for (const listener of tabActivated.listeners) await listener({ tabId });
        }
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
    setTimeout: (callback, delay) => {
      if (delay === 180 && options.onPreviewDelay) options.onPreviewDelay(tabs, { highlight: setHighlighted });
      if (delay === 180 && options.previewDelayGate) {
        Promise.resolve(options.previewDelayGate).then(callback); return 0;
      }
      Promise.resolve().then(callback); return 0;
    },
    clearTimeout: () => {}
  };
  vm.runInNewContext(source, context, { filename: "chrome-extension/background.js" });

  async function settle() {
    for (let index = 0; index < 48; index += 1) await Promise.resolve();
  }

  return {
    extensionReloads, tabs, storage, nativeMessages, dynamicUpdates, sessionUpdates, removedTabs, focusedWindows, highlightUpdates, intervals, updates, reloads,
    get dynamicRules() { return dynamicRules; },
    get sessionRules() { return sessionRules; },
    settle,
    effectiveRules: context.effectiveRules,
    browserSessionID: () => vm.runInNewContext("browserSessionID", context),
    async command(message) {
      await context.handleRequestedTab(message);
      for (let i = 0; i < 48; i++) await Promise.resolve();
    },
    async snapshot() { await context.publishTabSnapshot(true, true); await settle(); return nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1); },
    interruptNextReturn(tabId) { interruptReturnWithTab = tabId; },
    async focusWindow(id) {
      for (const listener of windowFocus.listeners) await listener(id);
      await settle();
    },
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
    async complete(id) {
      const tab = tabs.get(id);
      if (!tab) return;
      for (const listener of tabUpdated.listeners) {
        await listener(id, { status: "complete" }, { ...tab });
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
      if (Array.isArray(message.selectedTabIDs) && message.selectedBrowserSessionID === undefined) {
        message = { ...message, selectedBrowserSessionID: sessionStorage.intentBrowserSessionID };
      }
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
  const commands = createHarness({ active: false }, [
    { id: 61, windowId: 6, index: 0, active: true, url: "https://example.org/" },
    { id: 62, windowId: 6, index: 1, active: false, url: "https://example.com/" }
  ]);
  await commands.settle();
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
    { id: 3, windowId: 1, index: 2, active: false, url: "chrome://newtab/", highlighted: true },
    { id: 4, windowId: 1, index: 3, active: false, url: "", highlighted: true },
    { id: 5, windowId: 1, index: 4, active: false, url: "https://example.org/", highlighted: true, pinned: true, discarded: true, groupId: 9 }
  ];
  const discovery = createHarness({ active: false }, mixedTabs);
  await discovery.settle();
  const metadata = await discovery.snapshot();
  assert.deepEqual(Array.from(metadata.tabs, tab => tab.id), [1, 2, 3, 4, 5], "Discovery includes local PDF, internal, blank, pinned and discarded actual tabs");
  assert.deepEqual(Array.from(metadata.tabs.filter(tab => tab.highlighted), tab => tab.id), [1, 2, 3, 4, 5], "Native Shift-selected group, including its active tab, reaches Intent intact");
  assert.equal(metadata.tabs[4].groupID, 9);
  assert.equal(metadata.tabs[4].pinned && metadata.tabs[4].discarded, true);
  assert.equal(metadata.tabs[0].windowFrame.left, 20, "Window geometry identifies same-title browser windows");
  assert.equal(metadata.tabs[0].windowFocused, true, "Browser focus disambiguates overlapping windows");
  assert.ok(metadata.browserSessionID, "Every snapshot carries a browser-session identity");
  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1] }).active, false, "Missing identity cannot authorize a potentially reused tab ID");
  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1], selectedBrowserSessionID: "previous-browser-session" }).active, false, "Old exact-ID rules cannot target tabs after restart");
  const resumedWorker = createHarness({ active: false }, mixedTabs, { sessionStorage: { intentBrowserSessionID: metadata.browserSessionID } });
  await resumedWorker.settle();
  assert.equal((await resumedWorker.snapshot()).browserSessionID, metadata.browserSessionID, "Chrome worker suspension preserves the browser session identity");
  const restartedBrowser = createHarness({ active: false }, mixedTabs);
  await restartedBrowser.settle();
  assert.notEqual((await restartedBrowser.snapshot()).browserSessionID, metadata.browserSessionID, "A new Chrome browser session receives a different identity even when tab IDs are reused");
  for (const accessMode of ["whitelist", "blacklist"]) {
    const group = createHarness({ active: true, accessMode, selectedTabIDs: [2, 3, 4, 5], allowedWebsites: [], startupWebsites: [], blockTabSwitching: true, blockNavigation: true, blockNewTabs: true }, mixedTabs);
    await group.settle();
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
  await selectedOnly.settle();
  assert.deepEqual(Array.from(selectedOnly.sessionRules.find(rule => rule.id === 23000).condition.excludedTabIds), [7],
    "Chrome blocks main-frame network navigation outside selected tab IDs");
  assert.equal(selectedOnly.tabs.get(7).active, true, "Starting Quick Focus selects an allowed tab");
  assert.equal(selectedOnly.dynamicRules.length, 0, "URL restrictions must not override selected-tab navigation");
  const nativeSnapshot = selectedOnly.nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1);
  assert.ok(nativeSnapshot.allTabs.some(tab => tab.id === 8), "Native click geometry gets complete tab ordering including forbidden tabs");
  assert.equal(nativeSnapshot.tabs.some(tab => tab.id === 8), false, "Forbidden tabs never enter the allowed Ctrl+Tab switcher snapshot");
  await selectedOnly.activate(8);
  assert.equal(selectedOnly.tabs.get(7).active, true, "Unselected same-URL tabs must not become allowed");
  assert.equal(selectedOnly.tabs.get(8).url, "https://example.org/work", "Existing unselected tabs are preserved");
  selectedOnly.tabs.get(8).windowId = 2;
  selectedOnly.tabs.get(8).active = true;
  await selectedOnly.focusWindow(2);
  assert.equal(selectedOnly.focusedWindows.at(-1).id, 1, "Window focus must return to a selected tab's window");
  await selectedOnly.create({ id: 9, windowId: 1, active: true, url: "https://example.org/work" });
  assert.equal(selectedOnly.tabs.get(7).active, true, "New tabs cannot bypass selected-tab scope");
  selectedOnly.interruptNextReturn(9);
  await selectedOnly.activate(8);
  await selectedOnly.settle();
  assert.equal(selectedOnly.tabs.get(7).active, true, "A blocked activation arriving inside an in-flight return must not be dropped");
  await Promise.all([selectedOnly.activate(8), selectedOnly.activate(9), selectedOnly.activate(8)]);
  await selectedOnly.settle();
  assert.equal(selectedOnly.tabs.get(7).active, true, "Rapid blocked activations finish on a selected tab");
  selectedOnly.tabs.get(7).active = false;
  selectedOnly.tabs.get(8).active = true;
  selectedOnly.intervals[0].callback();
  await selectedOnly.settle();
  assert.equal(selectedOnly.tabs.get(7).active, true, "Heartbeat repairs a missed activation event");
  for (const url of ["https://discord.com/channels/1/2", "https://discord.com/channels/1/3", "https://another-site.example/new"]) {
    await selectedOnly.navigate(7, url);
    assert.equal(selectedOnly.tabs.get(7).url, url, "Selected tab allows channel changes and cross-site navigation");
    await selectedOnly.activate(8);
    assert.equal(selectedOnly.tabs.get(7).active, true, "Navigation never grants another tab access");
  }

  const twoSelected = createHarness({ active: true, accessMode: "whitelist", allowedWebsites: ["youtube.com"], selectedTabIDs: [31, 32], blockTabSwitching: true }, [
    { id: 31, windowId: 4, active: true, url: "https://youtube.com/watch?v=one" },
    { id: 32, windowId: 4, active: false, url: "https://youtube.com/watch?v=two" },
    { id: 33, windowId: 4, active: false, url: "https://youtube.com/watch?v=three" }
  ]);
  await twoSelected.settle();
  await twoSelected.activate(32);
  assert.equal(twoSelected.tabs.get(32).active, true, "Both explicitly selected tabs remain usable");
  await twoSelected.activate(33);
  assert.equal(twoSelected.tabs.get(32).active, true, "An unselected video returns to the last selected video, not any same-site tab");

  const preview = createHarness({ active: false }, [
    { id: 51, windowId: 3, active: true, url: "https://example.com/", favIconUrl: "https://example.com/favicon.ico" },
    { id: 52, windowId: 3, active: false, url: "https://example.org/" }
  ]);
  await preview.settle();
  await preview.receiveNative({ active: false, tabCommand: { browserSessionID: preview.browserSessionID(), id: "preview-test", action: "preview", tabID: 52, windowID: 3 } });
  await preview.settle();
  assert.ok(preview.nativeMessages.some(message => message.preview?.requestID === "preview-test" && message.preview.image), "Hover preview captures the requested tab");
  assert.equal(preview.tabs.get(51).active, true, "Preview restores the original active tab");
  assert.equal(preview.focusedWindows.length, 0, "Preview never focuses a browser window");
  await preview.receiveNative({ active: false, tabCommand: { action: "snapshot" } });
  assert.ok(preview.nativeMessages.some(message => message.tabs?.some(tab => tab.faviconURL === "https://example.com/favicon.ico")), "Snapshot carries the actual site's icon");

  const movingPreview = createHarness({ active: false }, [
    { id: 51, windowId: 3, active: true, url: "https://example.com/" },
    { id: 52, windowId: 3, active: false, url: "https://example.org/" },
    { id: 53, windowId: 3, active: false, url: "https://example.net/" }
  ], { onPreviewDelay(tabs) {
    tabs.get(52).windowId = 4; // User detaches the temporarily previewed tab.
    tabs.get(53).active = true; // User's new choice in the original window.
  } });
  await movingPreview.settle();
  await movingPreview.command({ id: "moved-during-preview", action: "preview", tabID: 52, windowID: 3,
    browserSessionID: movingPreview.browserSessionID() });
  assert.equal(movingPreview.tabs.get(53).active, true, "Preview cleanup must preserve the user's choice after the target moves to another window");
  assert.equal(movingPreview.updates.some(update => update.tabId === 51), false, "Preview cleanup cannot reactivate the old tab across a moved target");
  assert.ok(movingPreview.nativeMessages.some(message => message.preview?.requestID === "moved-during-preview" && message.preview.error), "A moved target produces an explicit preview error");

  const groupPreview = options => createHarness({ active: false }, [
    { id: 51, windowId: 3, index: 0, active: true, highlighted: true, url: "https://example.com/" },
    { id: 52, windowId: 3, index: 1, active: false, highlighted: false, url: "https://example.org/" },
    { id: 53, windowId: 3, index: 2, active: false, highlighted: true, url: "https://example.net/" },
    { id: 54, windowId: 3, index: 3, active: false, highlighted: false, url: "https://example.com/other" },
    { id: 55, windowId: 4, index: 0, active: true, highlighted: true, url: "https://example.org/other-window" },
    { id: 56, windowId: 4, index: 1, active: false, highlighted: false, url: "https://example.net/other-window" }
  ], options);
  async function previewGroup(harness, tabID = 52) {
    await harness.settle();
    await harness.command({ id: "group-preview", action: "preview", tabID, windowID: 3, browserSessionID: harness.browserSessionID() });
  }
  const highlightedIDs = (harness, windowID = 3) => Array.from(harness.tabs.values()).filter(tab => tab.windowId === windowID && tab.highlighted).map(tab => tab.id);
  let temporarySelection;
  const nativeGroupPreview = groupPreview({ onPreviewDelay(tabs) {
    temporarySelection = Array.from(tabs.values()).filter(tab => tab.windowId === 3 && tab.highlighted).map(tab => tab.id);
  } });
  await previewGroup(nativeGroupPreview);
  assert.deepEqual(temporarySelection, [52], "The harness models Chrome activation collapsing native multi-selection");
  assert.deepEqual(highlightedIDs(nativeGroupPreview), [51, 53], "Hover preview restores every originally highlighted native tab");
  assert.equal(nativeGroupPreview.tabs.get(51).active, true, "Restoring a native group preserves its original active tab");
  assert.deepEqual(highlightedIDs(nativeGroupPreview, 4), [55], "Preview selection restoration never changes another window");
  assert.deepEqual(nativeGroupPreview.highlightUpdates[0].tabIDs, [51, 53], "Native restoration targets exact saved IDs rather than only the active tab");

  const alreadyActiveGroup = groupPreview();
  await previewGroup(alreadyActiveGroup, 51);
  assert.deepEqual(highlightedIDs(alreadyActiveGroup), [51, 53], "Previewing the already-active tab leaves native multi-selection untouched");
  assert.equal(alreadyActiveGroup.highlightUpdates.length, 0, "An already-active preview performs no selection restoration");

  const changedGroup = groupPreview({ onPreviewDelay(_tabs, controls) { controls.highlight([52, 54], 3); } });
  await previewGroup(changedGroup);
  assert.deepEqual(highlightedIDs(changedGroup), [52, 54], "A user's new highlighted group during preview must win");
  assert.equal(changedGroup.highlightUpdates.length, 0, "Preview must not restore over an intervening group selection");
  const changedThenReturned = groupPreview({ onPreviewDelay(_tabs, controls) {
    controls.highlight([54], 3);
    controls.highlight([52], 3);
  } });
  await previewGroup(changedThenReturned);
  assert.deepEqual(highlightedIDs(changedThenReturned), [52], "A user gesture remains authoritative even after returning to the temporary tab");
  assert.equal(changedThenReturned.highlightUpdates.length, 0, "Matching final state cannot erase evidence of intervening user selection");

  let interruptedOriginalQuery = false;
  const changedWhileReading = groupPreview({ onTabQuery(query, _tabs, controls) {
    if (query.windowId === 3 && !interruptedOriginalQuery) {
      interruptedOriginalQuery = true;
      controls.highlight([52], 3);
    }
  } });
  await previewGroup(changedWhileReading);
  assert.deepEqual(highlightedIDs(changedWhileReading), [52], "A user selecting the target while original metadata is in flight keeps that new selection");
  assert.equal(changedWhileReading.updates.length, 0, "Interference during the initial query cancels before preview activation");
  assert.equal(changedWhileReading.highlightUpdates.length, 0, "The original metadata response must not restore over newer native selection");

  const reorderedGroup = groupPreview({ onPreviewDelay(tabs) {
    tabs.get(51).index = 2;
    tabs.get(53).index = 0;
  } });
  await previewGroup(reorderedGroup);
  assert.deepEqual(reorderedGroup.highlightUpdates[0].indices, [2, 0], "Restore resolves original IDs to current indices after reordering");
  assert.deepEqual(highlightedIDs(reorderedGroup), [51, 53], "Tab reordering never substitutes a different tab in the restored group");

  for (const mutation of ["move", "close"]) {
    const missingGroupMember = groupPreview({ onPreviewDelay(tabs) {
      if (mutation === "move") tabs.get(53).windowId = 4;
      else tabs.delete(53);
    } });
    await previewGroup(missingGroupMember);
    assert.equal(missingGroupMember.highlightUpdates.length, 0, "A moved or closed group member cannot restore a partial or wrong-window selection");
    assert.equal(missingGroupMember.tabs.get(52).active, true, "An invalidated original group must not cause a stale activation");
  }
  const otherWindowGroup = groupPreview({ onPreviewDelay(_tabs, controls) { controls.highlight([55, 56], 4); } });
  await previewGroup(otherWindowGroup);
  assert.deepEqual(highlightedIDs(otherWindowGroup), [51, 53], "An independent window selection does not invalidate safe restoration here");
  assert.deepEqual(highlightedIDs(otherWindowGroup, 4), [55, 56], "Restoration preserves the user's new selection in another window");

  const deferred = () => {
    let resolve;
    const promise = new Promise(done => { resolve = done; });
    return { promise, resolve };
  };
  const snapshotMessages = harness => harness.nativeMessages.filter(message => message.type === "tabsSnapshot");
  for (const outcome of ["success", "capture-error", "user-interference"]) {
    const captureGate = deferred();
    const delayedPreview = groupPreview({
      previewDelayGate: captureGate.promise,
      failPreviewCapture: outcome === "capture-error",
      onPreviewDelay(_tabs, controls) {
        if (outcome === "user-interference") controls.highlight([52, 54], 3);
      }
    });
    await delayedPreview.settle();
    const before = snapshotMessages(delayedPreview).length;
    const capture = delayedPreview.command({ id: "discovery-during-preview", action: "preview", tabID: 52, windowID: 3,
      browserSessionID: delayedPreview.browserSessionID() });
    await delayedPreview.settle();
    await Promise.all([delayedPreview.snapshot(), delayedPreview.snapshot(), delayedPreview.snapshot()]);
    assert.equal(snapshotMessages(delayedPreview).length, before, "Discovery while preview is busy cannot publish a temporary native group");
    captureGate.resolve();
    await capture;
    await delayedPreview.settle();
    const replies = snapshotMessages(delayedPreview).slice(before);
    assert.equal(replies.length, 1, "Pending discovery is coalesced into one fresh reply after every preview outcome");
    const expected = outcome === "user-interference" ? [52, 54] : [51, 53];
    assert.deepEqual(Array.from(replies[0].allTabs.filter(tab => tab.windowID === 3 && tab.highlighted), tab => tab.id), expected,
      "Post-preview discovery reports the restored group or the user's newer choice, including capture failure");
  }

  for (const alsoRequestWhileBusy of [false, true]) {
    const oldQueryGate = deferred();
    const oldWindowGate = deferred();
    const overlappingCaptureGate = deferred();
    let armOldQuery = false;
    let oldQueryPaused = false;
    let oldWindowPaused = false;
    const overlappingDiscovery = groupPreview({
      previewDelayGate: overlappingCaptureGate.promise,
      beforeTabQuery(query) {
        if (armOldQuery && query.windowId == null && !oldQueryPaused) {
          oldQueryPaused = true;
          return oldQueryGate.promise;
        }
      },
      beforeWindowQuery() {
        if (oldQueryPaused && !oldWindowPaused) {
          oldWindowPaused = true;
          return oldWindowGate.promise;
        }
      }
    });
    await overlappingDiscovery.settle();
    const beforeOverlap = snapshotMessages(overlappingDiscovery).length;
    armOldQuery = true;
    const oldSnapshot = overlappingDiscovery.snapshot();
    await overlappingDiscovery.settle();
    const overlappingCapture = overlappingDiscovery.command({ id: "overlapping-discovery", action: "preview", tabID: 52, windowID: 3,
      browserSessionID: overlappingDiscovery.browserSessionID() });
    await overlappingDiscovery.settle();
    oldQueryGate.resolve(); // The old tab query now reads the preview's temporary group.
    await overlappingDiscovery.settle();
    assert.equal(oldWindowPaused, true, "The overlapping snapshot holds temporary tab metadata across another async API call");
    if (alsoRequestWhileBusy) await overlappingDiscovery.snapshot(); // Optional separate request coalesces until restoration.
    overlappingCaptureGate.resolve();
    await overlappingCapture;
    await overlappingDiscovery.settle();
    oldWindowGate.resolve(); // The old response returns only after preview is no longer busy.
    await oldSnapshot;
    await overlappingDiscovery.settle();
    const overlapReplies = snapshotMessages(overlappingDiscovery).slice(beforeOverlap);
    assert.equal(overlapReplies.length, 1, "An older overlapping API response cannot overwrite or duplicate the fresh post-preview reply");
    assert.deepEqual(Array.from(overlapReplies[0].allTabs.filter(tab => tab.windowID === 3 && tab.highlighted), tab => tab.id), [51, 53],
      "Generation validation rejects temporary metadata even after previewBusy became false");
  }

  const idle = createHarness({ active: false }, [
    { id: 1, windowId: 1, index: 0, active: true, url: "https://youtube.com/" }
  ]);
  await idle.settle();
  assert.equal(idle.nativeMessages.some(message => message.extensionCapabilities?.includes("quick-selection-tabs-v1")), false,
    "An old native host must not be advertised as selected-tab capable");
  await idle.receiveNative({ active: false, hostCapabilities: ["quick-selection-host-v1", "tab-session-identity-host-v1"] });
  assert.ok(idle.nativeMessages.some(message => message.extensionCapabilities?.includes("quick-selection-tabs-v1")),
    "Selected-tab capability requires a matching native host handshake");
  await idle.receiveNative({ active: false, hostCapabilities: ["quick-selection-host-v1", "tab-session-identity-host-v1"],
    tabCommand: { action: "snapshot", tabID: -1, windowID: -1 } });
  assert.ok(idle.nativeMessages.some(message => message.type === "tabsSnapshot" && message.tabs.some(tab => tab.id === 1)),
    "Picker discovery returns idle tabs on demand");
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
  assert.deepEqual(
    existingStartup.reloads,
    [1],
    "Chrome should deliberately load an existing startup tab once instead of trusting a suspended or half-restored page"
  );
  await existingStartup.receiveNative({
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  });
  assert.deepEqual(
    existingStartup.reloads,
    [1],
    "Chrome must not reload an existing startup tab again during the same intention session"
  );

  const existingRootStartup = createHarness({
    ...lockedRules,
    startupSessionID: "chrome-existing-root-session",
    allowedWebsites: ["instagram.com"],
    startupWebsites: ["https://www.instagram.com/"]
  }, [
    { id: 1, active: true, url: "https://www.instagram.com/?variant=following", status: "complete" }
  ]);
  await existingRootStartup.settle();
  assert.equal(existingRootStartup.tabs.size, 1, "A broad website intention should reuse its existing Chrome tab");
  assert.equal(
    existingRootStartup.tabs.get(1).url,
    "https://www.instagram.com/",
    "Reused Chrome website tabs must navigate to the configured startup URL instead of showing stale content"
  );
  assert.equal(
    existingRootStartup.updates.filter(({ patch }) => patch.url === "https://www.instagram.com/").length,
    1,
    "A reused Chrome website tab must load exactly once for the new intention session"
  );

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
  assert.equal(
    redirect.sessionRules.some((rule) => rule.condition.tabIds?.includes(1)),
    true,
    "Chrome should temporarily allow the deliberate startup tab through path-specific network rules"
  );
  assert.deepEqual(
    Array.from(redirect.sessionRules.at(-1)?.condition.requestDomains || []),
    ["outlook.cloud.microsoft"],
    "Chrome's startup exception must stay on the configured host and never allow a cross-site redirect"
  );
  await redirect.navigate(1, "https://outlook.cloud.microsoft/mail/");
  await redirect.complete(1);
  assert.equal(
    chromeStartupUpdates(),
    1,
    "An Outlook redirect must never make Chrome reload the startup URL"
  );
  assert.equal(redirect.tabs.size, 1, "An Outlook redirect must never create replacement tabs");
  assert.equal(
    redirect.sessionRules.length,
    0,
    "Chrome should remove its same-host startup exception once the first document completes"
  );

  const allowed = createHarness(lockedRules, [
    { id: 1, windowId: 7, index: 0, active: true, url: "https://instagram.com/direct/inbox/" },
    { id: 2, windowId: 7, index: 1, active: false, url: "https://instagram.com/direct/t/123/" }
  ]);
  await allowed.settle();
  await allowed.activate(2);
  assert.equal(allowed.tabs.get(2).active, true, "Allowed tabs should remain selectable");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { browserSessionID: allowed.browserSessionID(), tabID: 1, windowID: 7 }
  });
  assert.equal(allowed.tabs.get(1).active, true, "A native Ctrl+Tab command should activate an allowed tab");
  assert.equal(allowed.focusedWindows.at(-1).id, 7, "A native Ctrl+Tab command should focus the tab's browser window");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { browserSessionID: allowed.browserSessionID(), tabID: 99, windowID: 8 }
  });
  assert.equal(allowed.tabs.get(1).active, true, "A stale or unallowed native tab command should do nothing");
  await allowed.receiveNative({
    ...lockedRules,
    tabCommand: { browserSessionID: allowed.browserSessionID(), tabID: 2, windowID: 7, action: "close" }
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
  assert.equal(blacklist.tabs.has(2), true, "Chrome blacklist mode must preserve already-open blocked websites");
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
    "https://youtube.com/watch?v=2",
    "Blacklist recovery must not rewrite or delete a document"
  );
  const blacklistBlank = createHarness(blacklistRules, [
    { id: 1, active: true, url: "chrome://newtab/" }
  ]);
  await blacklistBlank.settle();
  await blacklistBlank.navigate(1, "https://youtube.com/watch?v=3");
  assert.equal(
    blacklistBlank.tabs.get(1).url.replace(/\/$/, ""),
    "https://youtube.com/watch?v=3",
    "Blacklist recovery must preserve the attempted tab document"
  );

  const markedBlockRules = { ...blacklistRules, selectedTabIDs: [2] };
  const markedBlock = createHarness(markedBlockRules, [
    {id: 1, active: true, url: "https://youtube.com/", windowId: 1},
    {id: 2, active: false, url: "https://youtube.com/", windowId: 1},
    {id: 3, active: false, url: "https://example.org/", windowId: 1}
  ]);
  await markedBlock.settle();
  await markedBlock.receiveNative(markedBlockRules);
  await markedBlock.activate(2);
  await markedBlock.settle();
  assert.equal(markedBlock.tabs.has(2), true, "Marked blacklist tab is retained");
  assert.equal(markedBlock.tabs.get(2).url, "https://youtube.com/", "Marked blacklist URL is retained");
  assert.equal(markedBlock.tabs.get(1).active, true, "Same-URL unmarked tab stays usable");
  await markedBlock.activate(3);
  await markedBlock.settle();
  assert.equal(markedBlock.tabs.get(3).active, true, "Unmarked tab stays usable");

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

  // A bundled update asks an old unpacked extension to reload once, never in a loop.
  const upgrade = createHarness({active: false, guardEnabled: true}, []);
  await upgrade.settle();
  const update = {active: false, guardEnabled: true, bundledExtensionVersion: "99.0.0"};
  await upgrade.receiveNative({...update, active: true});
  assert.equal(upgrade.extensionReloads.length, 0, "Never reload the guard during an active intention");
  await upgrade.receiveNative(update);
  await upgrade.receiveNative(update);
  assert.equal(upgrade.extensionReloads.length, 1, "A stale extension must reload once per new bundle version");
  const current = createHarness({active: false, guardEnabled: true}, []);
  await current.settle();
  await current.receiveNative({active: false, guardEnabled: true, bundledExtensionVersion: require('../chrome-extension/manifest.json').version});
  assert.equal(current.extensionReloads.length, 0, "Matching extensions must not reload");
  console.log("Chrome background behavior spec passed");
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
