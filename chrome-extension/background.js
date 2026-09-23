importScripts("rule-helpers.js", "tab-visibility.js");

const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "com.google.Chrome";
const RECONNECT_MS = 1000;
const MAX_RECONNECT_MS = 30000;
// Stay inside Intent's five-second readiness window without waking every two seconds.
const HEARTBEAT_MS = 3000;
const TAB_SNAPSHOT_DEBOUNCE_MS = 40;
const NEW_TAB_GRACE_MS = 250;
const DYNAMIC_RULE_ID_START = 12000;
const STARTUP_SESSION_RULE_ID_START = 22000;
const STARTUP_SESSION_RULE_ID_END = 22999;
const SITE_RECORD_THROTTLE_MS = 30000;
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const EXTENSION_CAPABILITIES = ["single-startup-launch-v1", "hide-distractions-v1"];
let browserSessionID = null;
let browserSessionPromise = null;
async function ensureBrowserSessionIdentity() {
  if (browserSessionID) return browserSessionID;
  if (!chrome.storage.session) return null;
  if (!browserSessionPromise) browserSessionPromise = (async () => {
    const stored = await chrome.storage.session.get("intentBrowserSessionID");
    browserSessionID = stored.intentBrowserSessionID || (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`);
    await chrome.storage.session.set({ intentBrowserSessionID: browserSessionID });
    return browserSessionID;
  })().catch(() => { browserSessionPromise = null; return null; });
  return browserSessionPromise;
}
let hostSupportsQuickSelection = false;
let hostSupportsTabPreview = false;
let hostSupportsNativeTabGroups = false;
let hostSupportsSessionIdentity = false;
function advertisedCapabilities() {
  return hostSupportsQuickSelection && hostSupportsSessionIdentity && browserSessionID
    ? [...EXTENSION_CAPABILITIES, "quick-selection-tabs-v1", "blacklist-selection-tabs-v1", ...(hostSupportsNativeTabGroups ? ["native-tab-groups-v1"] : []), ...(hostSupportsSessionIdentity && browserSessionID ? ["tab-session-identity-v1"] : []), ...(hostSupportsTabPreview ? ["tab-preview-v1"] : [])] : EXTENSION_CAPABILITIES;
}

const { normalizeRule, isAllowedURL, isSearchStagingURL } = IntentBrowserRules;

const tabVisibility = typeof IntentTabVisibility !== "undefined" ? new IntentTabVisibility(chrome, false) : null;
let rules = inactiveRules();
let guardEnabled = true;
let initialized = false;
let nativePort = null;
let reconnectTimer = null;
let reconnectDelayMs = RECONNECT_MS;
let nativeConnectionConfirmed = false;
let lastForegroundReconnectAt = -Infinity;
function guardStatus() {
  return { enabled: guardEnabled, connected: Boolean(nativePort && nativeConnectionConfirmed) };
}
// A foreground action can shorten a long retry delay, without every tab event
// defeating exponential backoff. Never replace a healthy native connection.
function recoverForegroundConnection() {
  if (nativePort || Date.now() - lastForegroundReconnectAt < 3000) return;
  lastForegroundReconnectAt = Date.now();
  if (reconnectTimer !== null) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  reconnectDelayMs = RECONNECT_MS;
  connectNativeHost();
}

let lastAllowedTabId = null;
let enforcing = false;
let freshBlankTabIds = new Set();
let rulesFingerprint = fingerprintRules(rules);
let dnrFingerprint = "";
const lastAllowedURLByTab = new Map();
const searchSessionTabs = new Set();
const committedURLByTab = new Map();

// Chrome can also reuse a discarded or half-restored startup tab. Track the
// intentional navigation so its old completion event cannot cancel the load.
const startupNavigationURLByTab = new Map();
const pendingRuleRequests = new Set();
let synchronizingStartupTabs = false;
let completedStartupSessionID = null;
let completedStartupFingerprint = null;
let ruleRefreshPromise = null;
let snapshotTimer = null;
let snapshotForcePending = false;
let lastSnapshotFingerprint = null;
const recentlyRecordedSites = new Map();
let nextStartupSessionRuleID = STARTUP_SESSION_RULE_ID_START;

function inactiveRules() {
  return {
    active: false,
    accessMode: "whitelist",
    allowedWebsites: [],
    startupWebsites: [],
    startupSessionID: null,
    blockTabSwitching: false,
    blockNavigation: false,
    blockNewTabs: false,
    allowGoogleSearchTabs: false
  };
}

function fingerprintRules(value) {
  return JSON.stringify(value);
}

async function ensureInitialized() {
  if (initialized) return;
  try {
    const stored = await chrome.storage.local.get({
      guardEnabled: true,
      completedStartupSessionID: null
    });
    guardEnabled = stored.guardEnabled !== false;
    completedStartupSessionID = stored.completedStartupSessionID || null;
  } catch (_) {
    guardEnabled = true;
  }
  await ensureBrowserSessionIdentity();
  initialized = true;
  await clearStaleStartupNavigationRules();
  connectNativeHost();
  chrome.tabs.query({}).then((tabs) => tabs.forEach((tab) => recordWebsiteVisit(tab))).catch(() => {});
}

function connectNativeHost() {
  if (nativePort || reconnectTimer !== null) return;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    nativePort = port;
    hostSupportsQuickSelection = false;
    nativeConnectionConfirmed = false;
    port.onMessage.addListener((message) => {
      if (nativePort !== port) return;
      nativeConnectionConfirmed = true;
      reconnectDelayMs = RECONNECT_MS;
      if (message?.active !== true && message?.bundledExtensionVersion && message.bundledExtensionVersion !== chrome.runtime.getManifest().version) {
        const version = message.bundledExtensionVersion;
        chrome.storage.local.get("lastBundleReload").then((stored) => {
          if (stored.lastBundleReload !== version) {
            chrome.storage.local.set({lastBundleReload: version}).then(() => chrome.runtime.reload());
          }
        }).catch(() => {});
      }
      const supported = message?.hostCapabilities?.includes("quick-selection-host-v1") === true;
      const previewSupported = message?.hostCapabilities?.includes("tab-preview-host-v1") === true;
      const groupsSupported = message?.hostCapabilities?.includes("native-tab-groups-host-v1") === true;
      const identitySupported = message?.hostCapabilities?.includes("tab-session-identity-host-v1") === true;
      if (identitySupported !== hostSupportsSessionIdentity || supported !== hostSupportsQuickSelection || previewSupported !== hostSupportsTabPreview || groupsSupported !== hostSupportsNativeTabGroups) {
        hostSupportsQuickSelection = supported;
        hostSupportsTabPreview = previewSupported;
        hostSupportsNativeTabGroups = groupsSupported;
        hostSupportsSessionIdentity = identitySupported;
        sendHeartbeat();
      }
      if (message?.tabCommand) handleRequestedTab(message.tabCommand);
      applyNativeRules(message);
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = null;
      nativeConnectionConfirmed = false;
      settleRuleRequests();
      applyNativeRules(inactiveRules());
      scheduleReconnect();
    });
    postNative({ type: "setGuardEnabled", enabled: guardEnabled });
    requestRules();
  } catch (_) {
    nativePort = null;
    applyNativeRules(inactiveRules());
    scheduleReconnect();
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, delay);
}

function postNative(message) {
  if (!nativePort) return false;
  try {
    nativePort.postMessage({
      ...message,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER,
      extensionVersion: EXTENSION_VERSION,
      extensionCapabilities: advertisedCapabilities()
    });
    return true;
  } catch (_) {
    nativePort = null;
    scheduleReconnect();
    return false;
  }
}

function recordWebsiteVisit(tab) {
  if (!guardEnabled || !tab?.url) return;
  let parsed;
  try {
    parsed = new URL(tab.url);
  } catch (_) {
    return;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return;
  const host = parsed.hostname.toLowerCase().replace(/^www\./, "");
  if (!host || host === "localhost" || host === "127.0.0.1" || host === "::1") return;
  const now = Date.now();
  if (now - (recentlyRecordedSites.get(host) || 0) < SITE_RECORD_THROTTLE_MS) return;
  recentlyRecordedSites.set(host, now);
  postNative({
    type: "recordWebsiteVisit",
    url: `https://${host}`,
    title: tab.title || host
  });
}

function requestRules() {
  if (!postNative({ type: "getRules" })) connectNativeHost();
}

async function refreshRules() {
  await ensureInitialized();
  if (!nativePort) connectNativeHost();
  if (!nativePort) return;

  if (ruleRefreshPromise) return ruleRefreshPromise;
  ruleRefreshPromise = new Promise((resolve) => {
    pendingRuleRequests.add(resolve);
    if (!postNative({ type: "getRules" })) {
      pendingRuleRequests.delete(resolve);
      resolve();
    }
  });
  try {
    await ruleRefreshPromise;
  } finally {
    ruleRefreshPromise = null;
  }
}

function settleRuleRequests() {
  for (const resolve of pendingRuleRequests) resolve();
  pendingRuleRequests.clear();
}

function sendHeartbeat() {
  tabVisibility?.sync(rules, isRuntimeAllowedTab);
  if (rules.active && Array.isArray(rules.selectedTabIDs)) {
    chrome.tabs.query({ active: true, lastFocusedWindow: true }).then(tabs => {
      if (tabs.some(tab => tab.active && !isRuntimeAllowedTab(tab))) returnToAllowedTab();
    }).catch(() => {});
  }
  if (!nativePort) connectNativeHost();
  postNative({ type: "heartbeat" });
}

let previewBusy = false;
let previewSelectionWatch = null;
let previewGeneration = 0;
let deferredSnapshotPending = false;
let deferredSnapshotDiscovery = false;
let deferredSnapshotFlight = null;
let publishedSnapshotGeneration = -1;
let publishedSnapshotDiscovery = false;

function deferSnapshotForPreview(discovery, overlapping = false) {
  // A fresh post-preview reply already satisfies older overlapping requests.
  if (overlapping && !previewBusy && publishedSnapshotGeneration === previewGeneration
      && (!discovery || publishedSnapshotDiscovery)) return;
  if (!previewBusy && deferredSnapshotFlight?.generation === previewGeneration
      && (!discovery || deferredSnapshotFlight.discovery)) return;
  deferredSnapshotPending = true;
  deferredSnapshotDiscovery ||= discovery;
  flushDeferredPreviewSnapshot();
}

function flushDeferredPreviewSnapshot() {
  if (previewBusy || !deferredSnapshotPending || deferredSnapshotFlight) return;
  const flight = { generation: previewGeneration, discovery: deferredSnapshotDiscovery };
  deferredSnapshotPending = false;
  deferredSnapshotDiscovery = false;
  deferredSnapshotFlight = flight;
  publishTabSnapshot(true, flight.discovery).catch(() => {}).finally(() => {
    if (deferredSnapshotFlight === flight) deferredSnapshotFlight = null;
    flushDeferredPreviewSnapshot();
  });
}

async function captureTabPreview(message) {
  const result = { requestID: message.id };
  if (previewBusy || rules.active) {
    postNative({ type: "tabPreview", preview: { ...result, error: "Preview unavailable during a session." } });
    return;
  }
  previewBusy = true;
  previewGeneration += 1;
  let previous = null;
  let tab = null;
  let originalHighlightedIDs = [];
  let selectionWatch = null;
  try {
    tab = await chrome.tabs.get(message.tabID);
    if (tab.windowId !== message.windowID || tab.incognito || tab.discarded || !/^https?:\/\//.test(tab.url || "")) {
      throw new Error("This tab cannot be previewed.");
    }
    selectionWatch = { windowID: tab.windowId, targetID: tab.id, activationRequested: false, interfered: false };
    previewSelectionWatch = selectionWatch;
    const originalWindowTabs = await chrome.tabs.query({ windowId: tab.windowId });
    if (selectionWatch.interfered) throw new Error("Tab selection changed.");
    previous = originalWindowTabs.find(candidate => candidate.active);
    if (previous?.id !== tab.id) {
      originalHighlightedIDs = originalWindowTabs.filter(candidate => candidate.highlighted === true).map(candidate => candidate.id);
      if (!previous || !originalHighlightedIDs.includes(previous.id) || typeof chrome.tabs.highlight !== "function") {
        throw new Error("Cannot preserve this window's tab selection.");
      }
      selectionWatch.activationRequested = true;
      await chrome.tabs.update(tab.id, { active: true });
    }
    await new Promise(resolve => setTimeout(resolve, 180));
    const current = await chrome.tabs.get(tab.id);
    if (rules.active || !current.active || current.windowId !== message.windowID || current.url !== tab.url) throw new Error("Tab changed");
    result.image = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 65 });
  } catch (_) {
    result.error = "Preview unavailable. Open the tab once, then try again.";
  } finally {
    // Activating a Chrome tab collapses native multi-selection. Restore that
    // exact group by current IDs/indices, but only while our temporary selection
    // remains untouched. Never apply stale indices after a move or close.
    if (selectionWatch?.activationRequested && previous && tab) {
      const currentWindowTabs = await chrome.tabs.query({ windowId: message.windowID }).catch(() => []);
      const current = currentWindowTabs.find(candidate => candidate.id === tab.id);
      const highlighted = currentWindowTabs.filter(candidate => candidate.highlighted === true);
      const restoreIDs = [previous.id, ...originalHighlightedIDs.filter(id => id !== previous.id)];
      const restoreTabs = restoreIDs.map(id => currentWindowTabs.find(candidate => candidate.id === id));
      if (!selectionWatch.interfered && current?.active && current.windowId === message.windowID
          && highlighted.length === 1 && highlighted[0].id === tab.id
          && restoreTabs.every(candidate => candidate?.windowId === message.windowID && Number.isInteger(candidate.index) && candidate.index >= 0)
          && message.browserSessionID === browserSessionID && !rules.active) {
        await chrome.tabs.highlight({ windowId: message.windowID, tabs: restoreTabs.map(candidate => candidate.index) }).catch(() => {});
      }
    }
    previewSelectionWatch = null;
    previewBusy = false;
    previewGeneration += 1;
    // Includes failed/interrupted captures: never strand requested discovery.
    flushDeferredPreviewSnapshot();
  }
  postNative({ type: "tabPreview", preview: result });
}

async function handleRequestedTab(message) {
  // Discovery is how Intent learns the current browser lifetime in the first place.
  if (message.action === "snapshot") {
    await publishTabSnapshot(true, true);
    return;
  }
  let tab = null;
  if (typeof message.browserSessionID === "string" && message.browserSessionID.length > 0
      && message.browserSessionID === browserSessionID
      && Number.isInteger(message.tabID) && Number.isInteger(message.windowID)) {
    const current = await chrome.tabs.get(message.tabID).catch(() => null);
    if (current?.windowId === message.windowID) tab = current;
  }
  if (!tab) {
    if (message.action === "preview") postNative({
      type: "tabPreview",
      preview: { requestID: message.id, error: "This tab moved, closed or belongs to a previous browser session. Hover its current row again." }
    });
    return;
  }
  if (message.action === "preview") {
    await captureTabPreview(message);
    return;
  }
  if (message.action === "close") {
    if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await chrome.tabs.remove(tab.id).catch(() => {});
    return;
  }
  if (!isRuntimeAllowedTab(tab)) return;
  await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  // Focusing a window is asynchronous; a user can move/close the target meanwhile.
  const current = await chrome.tabs.get(tab.id).catch(() => null);
  if (current?.windowId !== message.windowID || !isRuntimeAllowedTab(current)) return;
  await chrome.tabs.update(tab.id, { active: true }).catch(() => {});
}

function scheduleTabSnapshot(force = false) {
  if (!rules.active && !force) return;
  snapshotForcePending ||= force;
  if (snapshotTimer) return;
  snapshotTimer = setTimeout(() => {
    snapshotTimer = null;
    const shouldForce = snapshotForcePending;
    snapshotForcePending = false;
    publishTabSnapshot(shouldForce);
  }, TAB_SNAPSHOT_DEBOUNCE_MS);
}

async function publishTabSnapshot(force = false, discovery = false) {
  await ensureInitialized();
  if (!nativePort) connectNativeHost();
  if (!nativePort) return;
  if (previewBusy) { deferSnapshotForPreview(discovery); return; }
  const generation = previewGeneration;
  const tabs = rules.active || discovery ? await chrome.tabs.query({}) : [];
  // Window identity is supplied by the browser; bounds disambiguate equal titles
  // when matching these IDs to macOS WindowServer preview windows.
  const windows = tabs.length && chrome.windows?.getAll
    ? await chrome.windows.getAll({ populate: false, windowTypes: ["normal", "popup"] }).catch(() => []) : [];
  // Even if capture finished during an API await, its temporary active/native
  // highlighted state must never be published as a user's fresh selection.
  if (previewBusy || generation !== previewGeneration) {
    deferSnapshotForPreview(discovery, true);
    return;
  }
  const windowsByID = new Map(windows.map(window => [window.id, window]));
  const allSnapshotTabs = tabs
    .filter(tab => Number.isInteger(tab.id) && tab.id >= 0 && Number.isInteger(tab.windowId))
    .map((tab) => ({
      id: tab.id,
      windowID: tab.windowId,
      index: tab.index,
      title: tab.title || tab.url || "New Tab",
      url: tab.url || "",
        active: Boolean(tab.active),
        faviconURL: tab.favIconUrl || null,
        highlighted: typeof tab.highlighted === "boolean" ? tab.highlighted : null,
        pinned: Boolean(tab.pinned),
        discarded: Boolean(tab.discarded),
        groupID: Number.isInteger(tab.groupId) ? tab.groupId : null,
        windowFrame: (() => {
          const window = windowsByID.get(tab.windowId);
          return window && [window.left, window.top, window.width, window.height].every(Number.isFinite)
            ? { left: window.left, top: window.top, width: window.width, height: window.height } : null;
        })(),
        windowFocused: windowsByID.get(tab.windowId)?.focused ?? null,
        searchSessionID: rules.active && rules.allowGoogleSearchTabs && searchSessionTabs.has(tab.id) ? rules.startupSessionID : null
    }))
    .sort((left, right) =>
      (left.windowID - right.windowID) || (left.index - right.index) || (left.id - right.id)
    );
  const allowedIDs = new Set(tabs.filter(tab => discovery || isRuntimeAllowedTab(tab)).map(tab => tab.id));
  const snapshotTabs = allSnapshotTabs.filter(tab => allowedIDs.has(tab.id));
  const snapshotFingerprint = JSON.stringify({ tabs: snapshotTabs, allTabs: allSnapshotTabs });
  if (!force && snapshotFingerprint === lastSnapshotFingerprint) return;
  lastSnapshotFingerprint = snapshotFingerprint;
  if (postNative({
    type: "tabsSnapshot",
    browserSessionID,
    tabs: snapshotTabs,
    allTabs: allSnapshotTabs
  })) {
    publishedSnapshotGeneration = generation;
    publishedSnapshotDiscovery = discovery;
  }
}

function effectiveRules(nativeRules) {
  // Browser tab IDs can be reused after restart. Never apply the previous
  // browser session's exact-ID policy to newly created tabs.
  if (Array.isArray(nativeRules?.selectedTabIDs)
      && (!browserSessionID || typeof nativeRules.selectedBrowserSessionID !== "string"
          || nativeRules.selectedBrowserSessionID !== browserSessionID)) return inactiveRules();
  if (!guardEnabled || !nativeRules?.active) return inactiveRules();
  return {
    ...inactiveRules(),
    active: true,
    hideDistractions: Boolean(nativeRules.hideDistractions),
    accessMode: nativeRules.accessMode === "blacklist" ? "blacklist" : "whitelist",
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : [],
    startupWebsites: Array.isArray(nativeRules.startupWebsites) ? nativeRules.startupWebsites : [],
    startupSessionID: typeof nativeRules.startupSessionID === "string" ? nativeRules.startupSessionID : null,
    selectedTabIDs: Array.isArray(nativeRules.selectedTabIDs) ? nativeRules.selectedTabIDs.filter(Number.isInteger) : null,
    blockTabSwitching: Boolean(nativeRules.blockTabSwitching),
    blockNavigation: Boolean(nativeRules.blockNavigation),
    blockNewTabs: Boolean(nativeRules.blockNewTabs),
    allowGoogleSearchTabs: Boolean(nativeRules.allowGoogleSearchTabs)
  };
}

async function applyNativeRules(nativeRules) {
  const nextRules = effectiveRules(nativeRules);
  if (!nextRules.active) await tabVisibility?.sync(nextRules, () => true);
  if (nextRules.startupSessionID !== rules.startupSessionID) searchSessionTabs.clear();
  const nextFingerprint = fingerprintRules(nextRules);
  rules = nextRules;
  settleRuleRequests();
  if (nextFingerprint === rulesFingerprint) return;
  rulesFingerprint = nextFingerprint;

  await updateNetworkRules();
  broadcastRules();
  if (rules.active) {
    await removeAlreadyBlockedTabs();
    await synchronizeStartupTabs();
    await primeAllowedTab();
    for (const tab of await chrome.tabs.query({})) if (!committedURLByTab.has(tab.id) && tab.url) committedURLByTab.set(tab.id, tab.url);
    if (Array.isArray(rules.selectedTabIDs)) await returnToAllowedTab();
  }
  else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
    searchSessionTabs.clear(); committedURLByTab.clear();
    for (const tabId of Array.from(startupNavigationURLByTab.keys())) {
      await endStartupNavigation(tabId);
    }
    completedStartupFingerprint = null;
  }
  await tabVisibility?.sync(rules, isRuntimeAllowedTab);
  scheduleTabSnapshot(true);
}

async function removeAlreadyBlockedTabs() {
  // Blacklisting preserves every tab; native blur and activation guards block access.
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function allowedRuleRegex(rawRule) {
  const rule = normalizeRule(rawRule);
  if (!rule) return null;
  const slashIndex = rule.indexOf("/");
  const host = slashIndex === -1 ? rule : rule.slice(0, slashIndex);
  const path = slashIndex === -1 ? "" : rule.slice(slashIndex);
  const hostRegex = `(?:[^/]+\\.)?${escapeRegex(host)}(?::[0-9]+)?`;
  if (!path) return `^https?://${hostRegex}(?:[/?#]|$)`;
  return `^https?://${hostRegex}${escapeRegex(path)}(?:[/?#]|$)`;
}

function desiredNetworkRules() {
  if (!rules.active || !rules.blockNavigation || Array.isArray(rules.selectedTabIDs)) return [];
  const dynamicRules = [];
  let nextID = DYNAMIC_RULE_ID_START;
  if (rules.accessMode === "whitelist") {
    dynamicRules.push({
      id: nextID++,
      priority: 1,
      action: { type: "block" },
      condition: { regexFilter: "^https?://", resourceTypes: ["main_frame"] }
    });
  }

  for (const website of rules.allowedWebsites) {
    const regexFilter = allowedRuleRegex(website);
    if (!regexFilter) continue;
    dynamicRules.push({
      id: nextID++,
      priority: rules.accessMode === "blacklist" ? 1 : 2,
      action: { type: rules.accessMode === "blacklist" ? "block" : "allow" },
      condition: { regexFilter, resourceTypes: ["main_frame"] }
    });
  }

  if (rules.accessMode === "whitelist" && rules.allowGoogleSearchTabs) {
    dynamicRules.push({
      id: nextID,
      priority: 2,
      action: { type: "allow" },
      condition: {
        regexFilter: "^https?://(?:[^/]+\\.)?google\\.[^/]+(?::[0-9]+)?/(?:search(?:[?#]|$)|(?:[?#]|$))",
        resourceTypes: ["main_frame"]
      }
    });
  }
  return dynamicRules;
}

async function updateNetworkRules() {
  // Tab-scoped DNR conditions are session rules, not dynamic rules. This also
  // blocks new, unselected tabs before their first document loads.
  if (typeof chrome.declarativeNetRequest.updateSessionRules === "function") {
    const selected = rules.active && Array.isArray(rules.selectedTabIDs) ? rules.selectedTabIDs : null;
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: [23000],
      addRules: selected === null || (rules.accessMode === "blacklist" && selected.length === 0) ? [] : [{
        id: 23000, priority: 1000, action: { type: "block" },
        condition: { regexFilter: "^https?://", resourceTypes: ["main_frame"],
          ...(rules.accessMode === "blacklist" ? { tabIds: selected } : (selected.length ? { excludedTabIds: selected } : {})) }
      }]
    });
  }
  const nextRules = desiredNetworkRules();
  const nextFingerprint = JSON.stringify(nextRules);
  if (nextFingerprint === dnrFingerprint) return;
  const current = await chrome.declarativeNetRequest.getDynamicRules().catch(() => []);
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: current.map((rule) => rule.id),
    addRules: nextRules
  });
  dnrFingerprint = nextFingerprint;
}

async function clearStaleStartupNavigationRules() {
  if (typeof chrome.declarativeNetRequest.getSessionRules !== "function" ||
      typeof chrome.declarativeNetRequest.updateSessionRules !== "function") return;
  const current = await chrome.declarativeNetRequest.getSessionRules().catch(() => []);
  const staleRuleIDs = current
    .map((rule) => rule.id)
    .filter((id) => id >= STARTUP_SESSION_RULE_ID_START && id <= STARTUP_SESSION_RULE_ID_END);
  if (staleRuleIDs.length === 0) return;
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: staleRuleIDs,
    addRules: []
  }).catch(() => {});
}

function broadcastRules() {
  chrome.tabs.query({}).then((tabs) => {
    for (const tab of tabs) {
      if (tab.id == null) continue;
      chrome.tabs.sendMessage(tab.id, { type: "rulesUpdated", rules }).catch(() => {});
    }
  }).catch(() => {});
}

function isFreshBlankTab(tab) {
  return Boolean(tab?.id && freshBlankTabIds.has(tab.id) && isSearchStagingURL(tab.url));
}

function isRuntimeAllowedTab(tab) {
  // Explicit tab selection follows that tab across URLs, redirects and SPA routes.
  if (rules.active && Array.isArray(rules.selectedTabIDs)) return rules.accessMode === "blacklist" ? !rules.selectedTabIDs.includes(tab?.id) : (rules.selectedTabIDs.includes(tab?.id) || (rules.allowGoogleSearchTabs && searchSessionTabs.has(tab?.id)));
  return Boolean(tab?.url && (isAllowedURL(tab.url, rules) || isFreshBlankTab(tab)));
}

async function primeAllowedTab() {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (tab.id != null && isRuntimeAllowedTab(tab)) lastAllowedURLByTab.set(tab.id, tab.url);
  }
  const activeAllowed = tabs.find((tab) => tab.active && isRuntimeAllowedTab(tab));
  const firstAllowed = activeAllowed || tabs.find((tab) => isRuntimeAllowedTab(tab));
  lastAllowedTabId = firstAllowed?.id ?? null;
}

function startupURLMatches(existingURL, requestedURL) {
  try {
    const existing = new URL(existingURL);
    const requested = new URL(requestedURL);
    const normalizeHost = (host) => host.toLowerCase().replace(/^www\./, "");
    const normalizePath = (path) => {
      const value = path.replace(/\/+$/, "");
      return value || "/";
    };
    return normalizeHost(existing.hostname) === normalizeHost(requested.hostname) &&
      (normalizePath(requested.pathname) === "/" ||
        normalizePath(existing.pathname) === normalizePath(requested.pathname) ||
        normalizePath(existing.pathname).startsWith(`${normalizePath(requested.pathname)}/`));
  } catch (_) {
    return existingURL === requestedURL;
  }
}

function sameWebsiteHost(existingURL, requestedURL) {
  try {
    const normalizeHost = (host) => host.toLowerCase().replace(/^www\./, "");
    return normalizeHost(new URL(existingURL).hostname) ===
      normalizeHost(new URL(requestedURL).hostname);
  } catch (_) {
    return false;
  }
}

function sameNavigationURL(existingURL, requestedURL) {
  try {
    const normalize = (value) => {
      const url = new URL(value);
      url.hash = "";
      url.hostname = url.hostname.toLowerCase().replace(/^www\./, "");
      url.pathname = url.pathname.replace(/\/+$/, "") || "/";
      return url.href;
    };
    return normalize(existingURL) === normalize(requestedURL);
  } catch (_) {
    return existingURL === requestedURL;
  }
}

async function beginStartupNavigation(tabId, startupURL) {
  await endStartupNavigation(tabId);
  const ruleID = nextStartupSessionRuleID;
  nextStartupSessionRuleID = nextStartupSessionRuleID >= STARTUP_SESSION_RULE_ID_END
    ? STARTUP_SESSION_RULE_ID_START
    : nextStartupSessionRuleID + 1;
  startupNavigationURLByTab.set(tabId, {
    startupURL,
    lastNavigationURL: null,
    ruleID
  });

  let host;
  try {
    host = new URL(startupURL).hostname.toLowerCase();
  } catch (_) {
    return;
  }
  if (typeof chrome.declarativeNetRequest.updateSessionRules !== "function") return;

  // Path-specific starts such as Outlook messages can redirect to a same-host
  // shell while booting. A high-priority, tab-scoped session rule lets only
  // that deliberate first load pass the global DNR block; it is removed as
  // soon as the document completes.
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: [ruleID],
    addRules: [{
      id: ruleID,
      priority: 3,
      action: { type: "allow" },
      condition: {
        requestDomains: [host],
        resourceTypes: ["main_frame"],
        tabIds: [tabId]
      }
    }]
  }).catch(() => {});
}

async function endStartupNavigation(tabId) {
  const pending = startupNavigationURLByTab.get(tabId);
  startupNavigationURLByTab.delete(tabId);
  if (!pending?.ruleID || typeof chrome.declarativeNetRequest.updateSessionRules !== "function") return;
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: [pending.ruleID],
    addRules: []
  }).catch(() => {});
}

function isPendingStartupNavigation(tabId, url) {
  const pending = startupNavigationURLByTab.get(tabId);
  return Boolean(
    pending &&
    (isSearchStagingURL(url) || sameWebsiteHost(url, pending.startupURL))
  );
}

function uniqueStartupURLs(urls) {
  const unique = [];
  for (const url of urls) {
    if (!unique.some((candidate) =>
      startupURLMatches(candidate, url) && startupURLMatches(url, candidate)
    )) {
      unique.push(url);
    }
  }
  return unique;
}

function startupLaunchPending() {
  if (!rules.active || rules.startupWebsites.length === 0) return false;
  if (rules.startupSessionID) {
    return completedStartupSessionID !== rules.startupSessionID;
  }
  return completedStartupFingerprint !== JSON.stringify(rules.startupWebsites);
}

async function synchronizeStartupTabs() {
  const startupFingerprint = JSON.stringify(rules.startupWebsites);
  if (
    synchronizingStartupTabs ||
    !startupLaunchPending()
  ) return;

  synchronizingStartupTabs = true;
  try {
    const tabs = await chrome.tabs.query({});
    if (tabs.length === 0) return;

    completedStartupFingerprint = startupFingerprint;
    if (rules.startupSessionID) {
      completedStartupSessionID = rules.startupSessionID;
      await chrome.storage.local.set({ completedStartupSessionID }).catch(() => {});
    }

    const claimedTabIds = new Set();
    let stagingTabs = tabs.filter((tab) => isSearchStagingURL(tab.url));
    let firstStartupTab = null;

    for (const startupURL of uniqueStartupURLs(rules.startupWebsites)) {
      let tab = tabs.find((candidate) =>
        !claimedTabIds.has(candidate.id) && startupURLMatches(candidate.url || "", startupURL)
      );
      if (tab) {
        await beginStartupNavigation(tab.id, startupURL);
        if (sameNavigationURL(tab.url || "", startupURL)) {
          await chrome.tabs.reload(tab.id);
        } else {
          tab = await chrome.tabs.update(tab.id, {
            url: startupURL,
            active: Boolean(tab.active)
          });
        }
      } else {
        const staging = stagingTabs.shift();
        if (staging) {
          await beginStartupNavigation(staging.id, startupURL);
          tab = await chrome.tabs.update(staging.id, {
            url: startupURL,
            active: Boolean(staging.active)
          });
        } else {
          tab = await chrome.tabs.create({ url: "chrome://newtab/", active: false });
          await beginStartupNavigation(tab.id, startupURL);
          tab = await chrome.tabs.update(tab.id, { url: startupURL, active: false });
        }
      }
      claimedTabIds.add(tab.id);
      freshBlankTabIds.delete(tab.id);
      lastAllowedURLByTab.set(tab.id, startupURL);
      firstStartupTab ||= tab;
    }

    if (firstStartupTab) {
      lastAllowedTabId = firstStartupTab.id;
      await chrome.tabs.update(firstStartupTab.id, { active: true });
    }
  } finally {
    synchronizingStartupTabs = false;
  }
}

async function getAllowedTab(tabId) {
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  return tab && isRuntimeAllowedTab(tab) ? tab : null;
}

let enforcementPending = false;
async function returnToAllowedTab() {
  if (enforcing) { enforcementPending = true; return; }
  enforcing = true;
  try {
    if (lastAllowedTabId !== null) {
      const lastAllowed = await getAllowedTab(lastAllowedTabId);
      if (lastAllowed) {
        await chrome.tabs.update(lastAllowed.id, { active: true });
        if (Array.isArray(rules.selectedTabIDs) && lastAllowed.windowId != null) {
          await chrome.windows?.update(lastAllowed.windowId, { focused: true }).catch(() => {});
        }
        return;
      }
      lastAllowedTabId = null;
    }

    const tabs = await chrome.tabs.query({});
    const allowed = tabs.find((tab) => isRuntimeAllowedTab(tab));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await chrome.tabs.update(allowed.id, { active: true });
      if (Array.isArray(rules.selectedTabIDs) && allowed.windowId != null) {
        await chrome.windows?.update(allowed.windowId, { focused: true }).catch(() => {});
      }
      return;
    }
  } finally {
    enforcing = false;
    if (enforcementPending) {
      enforcementPending = false;
      if (rules.active && Array.isArray(rules.selectedTabIDs)) setTimeout(returnToAllowedTab, 0);
    }
  }
}

async function recoverBlockedNavigation(tabId) {
  if (rules.accessMode === "blacklist") { await returnToAllowedTab(); return; }
  // Do not navigate or close an existing unselected tab. Leave it intact for after the session.
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    await returnToAllowedTab();
    return;
  }
  const fallbackURL = lastAllowedURLByTab.get(tabId);
  if (fallbackURL) {
    const isStartupFallback = rules.startupWebsites.some((startupURL) =>
      startupURLMatches(fallbackURL, startupURL) && startupURLMatches(startupURL, fallbackURL)
    );
    if (isStartupFallback) {
      lastAllowedURLByTab.delete(tabId);
      await returnToAllowedTab();
      return;
    }
    await chrome.tabs.update(tabId, { url: fallbackURL, active: true }).catch(returnToAllowedTab);
    lastAllowedTabId = tabId;
    return;
  }
  if (rules.accessMode === "blacklist") {
    await chrome.tabs.update(tabId, { url: "chrome://newtab", active: true }).catch(returnToAllowedTab);
    freshBlankTabIds.add(tabId);
    lastAllowedTabId = tabId;
    return;
  }
  await returnToAllowedTab();
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "getGuardStatus") {
    ensureInitialized().then(() => { recoverForegroundConnection(); requestRules(); sendResponse(guardStatus()); });
    return true;
  }
  if (message?.type === "getActiveRules") {
    sendResponse(rules);
    return false;
  }
  if (message?.type === "setGuardEnabled") {
    const enabled = message.enabled !== false;
    chrome.storage.local.set({ guardEnabled: enabled }).then(async () => {
      guardEnabled = enabled;
      postNative({ type: "setGuardEnabled", enabled });
      requestRules();
      if (!enabled) await applyNativeRules(inactiveRules());
      sendResponse(guardStatus());
    });
    return true;
  }
  return false;
});

// Focusing an existing window need not emit tabs.onActivated.
chrome.windows?.onFocusChanged?.addListener(async (windowId) => {
  if (windowId >= 0) recoverForegroundConnection();
  if (!rules.active || !Array.isArray(rules.selectedTabIDs) || windowId < 0) return;
  const tabs = await chrome.tabs.query({});
  const active = tabs.find(tab => tab.windowId === windowId && tab.active);
  if (active && !isRuntimeAllowedTab(active)) await returnToAllowedTab();
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  if (previewBusy && !rules.active) return; // Preview activations are not user browsing history.
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    await returnToAllowedTab();
    return;
  }
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active) return;
  if (!tab?.url) return;
  if (isRuntimeAllowedTab(tab)) {
    lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockTabSwitching) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

// Selection, pinning and moves can change without navigation or activation.
chrome.tabs.onHighlighted?.addListener((selection) => {
  if (previewSelectionWatch && previewSelectionWatch.windowID === selection?.windowId
      && (!previewSelectionWatch.activationRequested || !Array.isArray(selection.tabIds)
          || selection.tabIds.length !== 1 || selection.tabIds[0] !== previewSelectionWatch.targetID)) {
    // Sticky even if the user subsequently returns to the previewed tab: their
    // own selection gesture must win over the original preview snapshot.
    previewSelectionWatch.interfered = true;
  }
  scheduleTabSnapshot();
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  scheduleTabSnapshot();
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    if (tab.active) await returnToAllowedTab();
    return;
  }
  if (changeInfo.url || changeInfo.status === "complete") recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active || (!changeInfo.url && changeInfo.status !== "complete") || !tab.url) return;

  if (isPendingStartupNavigation(tabId, tab.url)) {
    const pending = startupNavigationURLByTab.get(tabId);
    if (changeInfo.url && !isSearchStagingURL(tab.url)) {
      pending.lastNavigationURL = tab.url;
    }
    if (
      changeInfo.status === "complete" &&
      pending.lastNavigationURL &&
      sameNavigationURL(tab.url, pending.lastNavigationURL)
    ) {
      await endStartupNavigation(tabId);
    }
    return;
  }

  if (startupNavigationURLByTab.has(tabId) && changeInfo.url) {
    await endStartupNavigation(tabId);
  }

  if (
    rules.accessMode === "whitelist" &&
    !Array.isArray(rules.selectedTabIDs) &&
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs &&
    changeInfo.url &&
    !isSearchStagingURL(changeInfo.url) &&
    !isAllowedURL(changeInfo.url, rules)
  ) {
    freshBlankTabIds.delete(tabId);
    if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await chrome.tabs.remove(tabId).catch(() => {});
    await returnToAllowedTab();
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
    freshBlankTabIds.delete(tabId);
    lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockNavigation) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

chrome.tabs.onCreated.addListener(async (tab) => {
  if (tab.url === chrome.runtime.getURL?.('parked.html')) return;
  committedURLByTab.set(tab.id, tab.url || "about:blank");
  if (rules.active && rules.allowGoogleSearchTabs && (!tab.url || isSearchStagingURL(tab.url) || IntentBrowserRules.isGoogleSearchURL(tab.url))) searchSessionTabs.add(tab.id);
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab(tab)) {
    await returnToAllowedTab();
    return;
  }
  scheduleTabSnapshot();
  if (!rules.active) return;
  if (!tab.url || isSearchStagingURL(tab.url)) {
    if (startupLaunchPending()) {
      await synchronizeStartupTabs();
      return;
    }
    freshBlankTabIds.add(tab.id);
    lastAllowedTabId = tab.id;
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
    lastAllowedURLByTab.set(tab.id, tab.url);
    lastAllowedTabId = tab.id;
    return;
  }

  setTimeout(async () => {
    const latest = await chrome.tabs.get(tab.id).catch(() => null);
    if (!latest || isRuntimeAllowedTab(latest)) return;
    if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await chrome.tabs.remove(tab.id).catch(() => {});
    await returnToAllowedTab();
  }, NEW_TAB_GRACE_MS);
  scheduleTabSnapshot();
});

for (const event of [chrome.tabs.onMoved, chrome.tabs.onAttached, chrome.tabs.onDetached]) {
  event?.addListener(() => { if (rules.active) scheduleTabSnapshot(true); });
}

chrome.tabs.onRemoved.addListener(async (tabId) => {
  searchSessionTabs.delete(tabId); committedURLByTab.delete(tabId);
  freshBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
  await endStartupNavigation(tabId);
  if (lastAllowedTabId === tabId) lastAllowedTabId = null;
  if (rules.active) setTimeout(returnToAllowedTab, 0);
  scheduleTabSnapshot();
});

chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  Promise.resolve().then(async () => {
    if (!rules.active || !rules.blockNavigation) return;
    if (Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: details.tabId})) {
      await returnToAllowedTab();
      return;
    }
    if (Array.isArray(rules.selectedTabIDs) && isRuntimeAllowedTab({id: details.tabId})) return;
    if (isPendingStartupNavigation(details.tabId, details.url)) {
      startupNavigationURLByTab.get(details.tabId).lastNavigationURL = details.url;
      return;
    }
    if (
      rules.accessMode === "whitelist" &&
      freshBlankTabIds.has(details.tabId) &&
      !rules.allowGoogleSearchTabs &&
      !isSearchStagingURL(details.url) &&
      !isAllowedURL(details.url, rules)
    ) {
      freshBlankTabIds.delete(details.tabId);
      if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await chrome.tabs.remove(details.tabId).catch(() => {});
      await returnToAllowedTab();
      return;
    }
    if (!isAllowedURL(details.url, rules)) {
      await recoverBlockedNavigation(details.tabId);
    }
  });
});

chrome.runtime.onStartup.addListener(ensureInitialized);
chrome.runtime.onInstalled.addListener(ensureInitialized);
ensureInitialized().then(async () => {
  await updateNetworkRules();
  scheduleTabSnapshot(true);
});
setInterval(sendHeartbeat, HEARTBEAT_MS);

// Browser-reported transitions distinguish address-bar input from ordinary links
// and SPA navigation; native input guards prevent address editing when Searches is off.
chrome.webNavigation?.onCommitted?.addListener(async (details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: details.tabId})) return;
  const previous = committedURLByTab.get(details.tabId);
  const direct = ["typed", "generated", "keyword", "keyword_generated", "auto_bookmark"].includes(details.transitionType)
    || (details.transitionQualifiers || []).includes("from_address_bar");
  if (rules.active && Array.isArray(rules.selectedTabIDs) && direct
      && !(rules.allowGoogleSearchTabs && IntentBrowserRules.isGoogleSearchURL(details.url))) {
    if (previous && previous !== details.url) await chrome.tabs.update(details.tabId, {url: previous}).catch(() => {});
    else await returnToAllowedTab();
    return;
  }
  committedURLByTab.set(details.tabId, details.url);
});
