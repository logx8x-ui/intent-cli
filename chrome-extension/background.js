importScripts("rule-helpers.js");

const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "com.google.Chrome";
const RULE_REFRESH_MS = 1000;
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
let recoveryBlankTabIds = new Set();
let creatingRecoveryBlankTab = false;
let rulesFingerprint = fingerprintRules(rules);
let dnrFingerprint = "";
const lastAllowedURLByTab = new Map();

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
    port.onMessage.addListener((nativeRules) => applyNativeRules(nativeRules));
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

function effectiveRules(nativeRules) {
  if (!guardEnabled || !nativeRules?.active) return inactiveRules();
  return {
    ...inactiveRules(),
    ...nativeRules,
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : []
  };
}

async function applyNativeRules(nativeRules) {
  const nextRules = effectiveRules(nativeRules);
  const nextFingerprint = fingerprintRules(nextRules);
  rules = nextRules;
  if (nextFingerprint === rulesFingerprint) return;
  rulesFingerprint = nextFingerprint;

  await updateNetworkRules();
  broadcastRules();
  if (rules.active) await primeAllowedTab();
  else {
    lastAllowedTabId = null;
    recoveryBlankTabIds.clear();
    lastAllowedURLByTab.clear();
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

function isRecoveryBlankTab(tab) {
  return Boolean(tab?.id && recoveryBlankTabIds.has(tab.id) && isSearchStagingURL(tab.url));
}

function isRuntimeAllowedTab(tab) {
  return Boolean(tab?.url && (isAllowedURL(tab.url, rules) || isRecoveryBlankTab(tab)));
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
    await openRecoveryBlankTab();
  } finally {
    enforcing = false;
  }
}

async function openRecoveryBlankTab() {
  creatingRecoveryBlankTab = true;
  try {
    const tab = await chrome.tabs.create({ url: "chrome://newtab/", active: true });
    recoveryBlankTabIds.add(tab.id);
    lastAllowedTabId = tab.id;
  } finally {
    creatingRecoveryBlankTab = false;
  }
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
  if (!rules.active) return;
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab?.url) return;
  if (isRuntimeAllowedTab(tab)) {
    if (isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockTabSwitching) {
    await returnToAllowedTab();
  }
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!rules.active || (!changeInfo.url && changeInfo.status !== "complete") || !tab.url) return;
  if (isRuntimeAllowedTab(tab)) {
    if (isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  } else if (rules.blockNavigation) {
    await recoverBlockedNavigation(tabId);
  }
});

chrome.tabs.onCreated.addListener((tab) => {
  if (!rules.active || !rules.blockNewTabs) return;
  if (isRecoveryBlankTab(tab) || (creatingRecoveryBlankTab && isSearchStagingURL(tab.url))) {
    recoveryBlankTabIds.add(tab.id);
    return;
  }
  if (rules.allowGoogleSearchTabs && (!tab.url || isSearchStagingURL(tab.url))) return;

  setTimeout(async () => {
    const latest = await chrome.tabs.get(tab.id).catch(() => null);
    if (!latest || isRuntimeAllowedTab(latest)) return;
    await chrome.tabs.remove(tab.id).catch(() => {});
    await returnToAllowedTab();
  }, NEW_TAB_GRACE_MS);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  recoveryBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
  if (lastAllowedTabId === tabId) lastAllowedTabId = null;
  if (rules.active) setTimeout(returnToAllowedTab, 0);
});

chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (details.frameId !== 0 || details.tabId < 0 || !rules.active || !rules.blockNavigation) return;
  if (!isAllowedURL(details.url, rules)) setTimeout(() => recoverBlockedNavigation(details.tabId), 0);
});

chrome.runtime.onStartup.addListener(ensureInitialized);
chrome.runtime.onInstalled.addListener(ensureInitialized);
ensureInitialized().then(async () => {
  await updateNetworkRules();
  requestRules();
});
setInterval(requestRules, RULE_REFRESH_MS);
