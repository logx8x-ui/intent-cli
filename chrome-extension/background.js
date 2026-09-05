importScripts("rule-helpers.js");

const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "com.google.Chrome";
const RECONNECT_MS = 1000;
const MAX_RECONNECT_MS = 30000;
// Stay inside Intent's five-second readiness window without waking every two seconds.
const HEARTBEAT_MS = 3000;
const TAB_SNAPSHOT_DEBOUNCE_MS = 40;
const NEW_TAB_GRACE_MS = 250;
const DYNAMIC_RULE_ID_START = 12000;
const SITE_RECORD_THROTTLE_MS = 30000;
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const EXTENSION_CAPABILITIES = ["single-startup-launch-v1"];

const { normalizeRule, isAllowedURL, isSearchStagingURL } = IntentBrowserRules;

let rules = inactiveRules();
let guardEnabled = true;
let initialized = false;
let nativePort = null;
let reconnectTimer = null;
let reconnectDelayMs = RECONNECT_MS;
let lastAllowedTabId = null;
let enforcing = false;
let freshBlankTabIds = new Set();
let rulesFingerprint = fingerprintRules(rules);
let dnrFingerprint = "";
const lastAllowedURLByTab = new Map();
const pendingRuleRequests = new Set();
let synchronizingStartupTabs = false;
let completedStartupSessionID = null;
let completedStartupFingerprint = null;
let ruleRefreshPromise = null;
let snapshotTimer = null;
let snapshotForcePending = false;
let lastSnapshotFingerprint = null;
const recentlyRecordedSites = new Map();

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
  initialized = true;
  connectNativeHost();
  chrome.tabs.query({}).then((tabs) => tabs.forEach((tab) => recordWebsiteVisit(tab))).catch(() => {});
}

function connectNativeHost() {
  if (nativePort || reconnectTimer !== null) return;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    nativePort = port;
    port.onMessage.addListener((message) => {
      reconnectDelayMs = RECONNECT_MS;
      if (message?.tabCommand) handleRequestedTab(message.tabCommand);
      applyNativeRules(message);
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = null;
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
      extensionCapabilities: EXTENSION_CAPABILITIES
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
  if (!nativePort) connectNativeHost();
  postNative({ type: "heartbeat" });
}

async function handleRequestedTab(message) {
  const tab = await chrome.tabs.get(message.tabID).catch(() => null);
  if (!tab) return;
  if (message.action === "close") {
    await chrome.tabs.remove(tab.id).catch(() => {});
    return;
  }
  if (!isRuntimeAllowedTab(tab)) return;
  if (tab.windowId != null) {
    await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
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

async function publishTabSnapshot(force = false) {
  await ensureInitialized();
  if (!nativePort) connectNativeHost();
  if (!nativePort) return;
  const tabs = rules.active ? await chrome.tabs.query({}) : [];
  const snapshotTabs = tabs
    .filter((tab) => isRuntimeAllowedTab(tab))
    .map((tab) => ({
      id: tab.id,
      windowID: tab.windowId,
      index: tab.index,
      title: tab.title || tab.url || "New Tab",
      url: tab.url || "",
      active: Boolean(tab.active)
    }))
    .sort((left, right) =>
      (left.windowID - right.windowID) || (left.index - right.index) || (left.id - right.id)
    );
  const snapshotFingerprint = JSON.stringify(snapshotTabs);
  if (!force && snapshotFingerprint === lastSnapshotFingerprint) return;
  lastSnapshotFingerprint = snapshotFingerprint;
  postNative({
    type: "tabsSnapshot",
    tabs: snapshotTabs
  });
}

function effectiveRules(nativeRules) {
  if (!guardEnabled || !nativeRules?.active) return inactiveRules();
  return {
    ...inactiveRules(),
    active: true,
    accessMode: nativeRules.accessMode === "blacklist" ? "blacklist" : "whitelist",
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : [],
    startupWebsites: Array.isArray(nativeRules.startupWebsites) ? nativeRules.startupWebsites : [],
    startupSessionID: typeof nativeRules.startupSessionID === "string" ? nativeRules.startupSessionID : null,
    blockTabSwitching: Boolean(nativeRules.blockTabSwitching),
    blockNavigation: Boolean(nativeRules.blockNavigation),
    blockNewTabs: Boolean(nativeRules.blockNewTabs),
    allowGoogleSearchTabs: Boolean(nativeRules.allowGoogleSearchTabs)
  };
}

async function applyNativeRules(nativeRules) {
  const nextRules = effectiveRules(nativeRules);
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
  }
  else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
    completedStartupFingerprint = null;
  }
  scheduleTabSnapshot(true);
}

async function removeAlreadyBlockedTabs() {
  if (rules.accessMode !== "blacklist") return;
  const tabs = await chrome.tabs.query({});
  const blocked = tabs.filter((tab) => tab.id != null && tab.url && !isAllowedURL(tab.url, rules));
  for (const tab of blocked) {
    if (tabs.length - blocked.length <= 0 && blocked[blocked.length - 1]?.id === tab.id) {
      await chrome.tabs.update(tab.id, { url: "chrome://newtab", active: Boolean(tab.active) }).catch(() => {});
      freshBlankTabIds.add(tab.id);
    } else {
      await chrome.tabs.remove(tab.id).catch(() => {});
    }
  }
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
  if (!rules.active || !rules.blockNavigation) return [];
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
  return Boolean(tab?.url && (isAllowedURL(tab.url, rules) || isFreshBlankTab(tab)));
}

async function primeAllowedTab() {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (tab.id != null && isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tab.id, tab.url);
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
      if (!tab) {
        const staging = stagingTabs.shift();
        tab = staging
          ? await chrome.tabs.update(staging.id, { url: startupURL, active: Boolean(staging.active) })
          : await chrome.tabs.create({ url: startupURL, active: false });
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

async function returnToAllowedTab() {
  if (enforcing) return;
  enforcing = true;
  try {
    if (lastAllowedTabId !== null) {
      const lastAllowed = await getAllowedTab(lastAllowedTabId);
      if (lastAllowed) {
        await chrome.tabs.update(lastAllowed.id, { active: true });
        return;
      }
      lastAllowedTabId = null;
    }

    const tabs = await chrome.tabs.query({});
    const allowed = tabs.find((tab) => isRuntimeAllowedTab(tab));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await chrome.tabs.update(allowed.id, { active: true });
      return;
    }
  } finally {
    enforcing = false;
  }
}

async function recoverBlockedNavigation(tabId) {
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
    ensureInitialized().then(() => sendResponse({ enabled: guardEnabled }));
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
      sendResponse({ enabled: guardEnabled });
    });
    return true;
  }
  return false;
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active) return;
  if (!tab?.url) return;
  if (isRuntimeAllowedTab(tab)) {
    if (isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockTabSwitching) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.status === "complete") recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active || (!changeInfo.url && changeInfo.status !== "complete") || !tab.url) return;

  if (
    rules.accessMode === "whitelist" &&
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs &&
    changeInfo.url &&
    !isSearchStagingURL(changeInfo.url) &&
    !isAllowedURL(changeInfo.url, rules)
  ) {
    freshBlankTabIds.delete(tabId);
    await chrome.tabs.remove(tabId).catch(() => {});
    await returnToAllowedTab();
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
    if (isAllowedURL(tab.url, rules)) {
      freshBlankTabIds.delete(tabId);
      lastAllowedURLByTab.set(tabId, tab.url);
    }
    lastAllowedTabId = tabId;
  } else if (rules.blockNavigation) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

chrome.tabs.onCreated.addListener(async (tab) => {
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

  if (isAllowedURL(tab.url, rules)) {
    lastAllowedURLByTab.set(tab.id, tab.url);
    lastAllowedTabId = tab.id;
    return;
  }

  setTimeout(async () => {
    const latest = await chrome.tabs.get(tab.id).catch(() => null);
    if (!latest || isRuntimeAllowedTab(latest)) return;
    await chrome.tabs.remove(tab.id).catch(() => {});
    await returnToAllowedTab();
  }, NEW_TAB_GRACE_MS);
  scheduleTabSnapshot();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  freshBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
  if (lastAllowedTabId === tabId) lastAllowedTabId = null;
  if (rules.active) setTimeout(returnToAllowedTab, 0);
  scheduleTabSnapshot();
});

chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  Promise.resolve().then(async () => {
    if (!rules.active || !rules.blockNavigation) return;
    if (
      rules.accessMode === "whitelist" &&
      freshBlankTabIds.has(details.tabId) &&
      !rules.allowGoogleSearchTabs &&
      !isSearchStagingURL(details.url) &&
      !isAllowedURL(details.url, rules)
    ) {
      freshBlankTabIds.delete(details.tabId);
      await chrome.tabs.remove(details.tabId).catch(() => {});
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
