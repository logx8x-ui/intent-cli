importScripts("rule-helpers.js");

const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "com.google.Chrome";
const RULE_REFRESH_MS = 1000;
const TAB_SNAPSHOT_MS = 120;
const RECONNECT_MS = 1000;
const NEW_TAB_GRACE_MS = 250;
const DYNAMIC_RULE_ID_START = 12000;

const { normalizeRule, isAllowedURL, isSearchStagingURL } = IntentBrowserRules;

let rules = inactiveRules();
let guardEnabled = true;
let initialized = false;
let nativePort = null;
let reconnectTimer = null;
let lastAllowedTabId = null;
let enforcing = false;
let freshBlankTabIds = new Set();
let rulesFingerprint = fingerprintRules(rules);
let dnrFingerprint = "";
const lastAllowedURLByTab = new Map();
const pendingRuleRequests = new Set();

function inactiveRules() {
  return {
    active: false,
    allowedWebsites: [],
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
    const stored = await chrome.storage.local.get({ guardEnabled: true });
    guardEnabled = stored.guardEnabled !== false;
  } catch (_) {
    guardEnabled = true;
  }
  initialized = true;
  connectNativeHost();
}

function connectNativeHost() {
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    nativePort = port;
    port.onMessage.addListener((message) => {
      if (message?.tabCommand) activateRequestedTab(message.tabCommand);
      applyNativeRules(message);
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = null;
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
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, RECONNECT_MS);
}

function postNative(message) {
  if (!nativePort) return false;
  try {
    nativePort.postMessage({ ...message, browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER });
    return true;
  } catch (_) {
    nativePort = null;
    scheduleReconnect();
    return false;
  }
}

function requestRules() {
  if (!postNative({ type: "getRules" })) connectNativeHost();
}

async function refreshRules() {
  await ensureInitialized();
  if (!nativePort) connectNativeHost();
  if (!nativePort) return;

  await new Promise((resolve) => {
    pendingRuleRequests.add(resolve);
    if (!postNative({ type: "getRules" })) {
      pendingRuleRequests.delete(resolve);
      resolve();
    }
  });
}

function settleRuleRequests() {
  for (const resolve of pendingRuleRequests) resolve();
  pendingRuleRequests.clear();
}

async function activateRequestedTab(message) {
  const tab = await chrome.tabs.get(message.tabID).catch(() => null);
  if (!tab || !isRuntimeAllowedTab(tab)) return;
  if (tab.windowId != null) {
    await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
  await chrome.tabs.update(tab.id, { active: true }).catch(() => {});
}

async function publishTabSnapshot() {
  await ensureInitialized();
  if (!nativePort) connectNativeHost();
  if (!nativePort) return;
  const tabs = rules.active ? await chrome.tabs.query({}) : [];
  postNative({
    type: "tabsSnapshot",
    tabs: tabs
      .filter((tab) => isRuntimeAllowedTab(tab))
      .map((tab) => ({
        id: tab.id,
        windowID: tab.windowId,
        index: tab.index,
        title: tab.title || tab.url || "New Tab",
        url: tab.url || "",
        active: Boolean(tab.active)
      }))
  });
}

function effectiveRules(nativeRules) {
  if (!guardEnabled || !nativeRules?.active) return inactiveRules();
  return {
    ...inactiveRules(),
    active: true,
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : [],
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
  if (rules.active) await primeAllowedTab();
  else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
  }
  await publishTabSnapshot();
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
  const dynamicRules = [{
    id: DYNAMIC_RULE_ID_START,
    priority: 1,
    action: { type: "block" },
    condition: { regexFilter: "^https?://", resourceTypes: ["main_frame"] }
  }];

  let nextID = DYNAMIC_RULE_ID_START + 1;
  for (const website of rules.allowedWebsites) {
    const regexFilter = allowedRuleRegex(website);
    if (!regexFilter) continue;
    dynamicRules.push({
      id: nextID++,
      priority: 2,
      action: { type: "allow" },
      condition: { regexFilter, resourceTypes: ["main_frame"] }
    });
  }

  if (rules.allowGoogleSearchTabs) {
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
    // Keep a still-open Chrome window from exposing an old unallowed tab, but
    // do not manufacture a tab after Chrome fully closes.
    if (tabs.length > 0) {
      await openRecoveryBlankTab();
    }
  } finally {
    enforcing = false;
  }
}

async function openRecoveryBlankTab() {
  const tab = await chrome.tabs.create({ url: "chrome://newtab/", active: true });
  freshBlankTabIds.add(tab.id);
  lastAllowedTabId = tab.id;
}

async function recoverBlockedNavigation(tabId) {
  const fallbackURL = lastAllowedURLByTab.get(tabId);
  if (fallbackURL) {
    await chrome.tabs.update(tabId, { url: fallbackURL, active: true }).catch(returnToAllowedTab);
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
  await refreshRules();
  if (!rules.active) return;
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab?.url) return;
  if (isRuntimeAllowedTab(tab)) {
    if (isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockTabSwitching) {
    await returnToAllowedTab();
  }
  await publishTabSnapshot();
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  await refreshRules();
  if (!rules.active || (!changeInfo.url && changeInfo.status !== "complete") || !tab.url) return;

  if (
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
  await publishTabSnapshot();
});

chrome.tabs.onCreated.addListener(async (tab) => {
  await refreshRules();
  if (!rules.active) return;
  if (!tab.url || isSearchStagingURL(tab.url)) {
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
  await publishTabSnapshot();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  freshBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
  if (lastAllowedTabId === tabId) lastAllowedTabId = null;
  if (rules.active) setTimeout(returnToAllowedTab, 0);
  setTimeout(publishTabSnapshot, 0);
});

chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  refreshRules().then(async () => {
    if (!rules.active || !rules.blockNavigation) return;
    if (
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
  requestRules();
});
setInterval(requestRules, RULE_REFRESH_MS);
setInterval(publishTabSnapshot, TAB_SNAPSHOT_MS);
