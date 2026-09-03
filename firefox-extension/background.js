const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "org.mozilla.firefox";
const RECONNECT_MS = 1000;
const MAX_RECONNECT_MS = 30000;
const HEARTBEAT_MS = 2000;
const TAB_SNAPSHOT_DEBOUNCE_MS = 40;
const NEW_TAB_GRACE_MS = 250;
const SITE_RECORD_THROTTLE_MS = 30000;
const EXTENSION_VERSION = browser.runtime.getManifest().version;
const EXTENSION_CAPABILITIES = ["single-startup-launch-v1"];

const {
  isAllowedURL,
  isSearchStagingURL
} = IntentBrowserRules;

let rules = inactiveRules();
let lastAllowedTabId = null;
let enforcing = false;
let rulesFingerprint = fingerprintRules(rules);
let guardEnabled = true;
let initialized = false;
let freshBlankTabIds = new Set();
const lastAllowedURLByTab = new Map();
let commandPort = null;
let reconnectTimer = null;
let reconnectDelayMs = RECONNECT_MS;
let synchronizingStartupTabs = false;
let completedStartupSessionID = null;
let completedStartupFingerprint = null;
let snapshotTimer = null;
let snapshotForcePending = false;
let lastSnapshotFingerprint = null;
let pendingRuleRefresh = null;
let resolvePendingRuleRefresh = null;
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
  if (initialized) {
    return;
  }

  try {
    const stored = await browser.storage.local.get({
      guardEnabled: true,
      completedStartupSessionID: null
    });
    guardEnabled = stored.guardEnabled !== false;
    completedStartupSessionID = stored.completedStartupSessionID || null;
  } catch (_) {
    guardEnabled = true;
  }

  initialized = true;
  connectCommandPort();
  await notifyNativeGuardState();
  browser.tabs.query({}).then((tabs) => tabs.forEach((tab) => recordWebsiteVisit(tab))).catch(() => {});
}

function connectCommandPort() {
  if (commandPort) return;
  if (typeof browser.runtime.connectNative !== "function") return;
  try {
    const port = browser.runtime.connectNative(HOST_NAME);
    commandPort = port;
    port.onMessage.addListener(async (message) => {
      reconnectDelayMs = RECONNECT_MS;
      if (message?.tabCommand) await handleRequestedTab(message.tabCommand);
      await applyNativeRules(message);
      settlePendingRuleRefresh();
    });
    port.onDisconnect.addListener(() => {
      if (commandPort !== port) return;
      commandPort = null;
      settlePendingRuleRefresh();
      scheduleCommandReconnect();
    });
    postCommandPort({ type: "getRules" });
  } catch (_) {
    commandPort = null;
    scheduleCommandReconnect();
  }
}

function scheduleCommandReconnect() {
  if (reconnectTimer) return;
  const delay = reconnectDelayMs;
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectCommandPort();
  }, delay);
}

function postCommandPort(message) {
  if (!commandPort) return false;
  try {
    commandPort.postMessage({
      ...message,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER,
      extensionVersion: EXTENSION_VERSION,
      extensionCapabilities: EXTENSION_CAPABILITIES
    });
    return true;
  } catch (_) {
    commandPort = null;
    scheduleCommandReconnect();
    return false;
  }
}

async function recordWebsiteVisit(tab) {
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

  const message = {
    type: "recordWebsiteVisit",
    url: `https://${host}`,
    title: tab.title || host
  };
  if (postCommandPort(message)) return;
  if (typeof browser.runtime.connectNative === "function") return;
  try {
    await browser.runtime.sendNativeMessage(HOST_NAME, {
      ...message,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER,
      extensionVersion: EXTENSION_VERSION,
      extensionCapabilities: EXTENSION_CAPABILITIES
    });
  } catch (_) {}
}

async function handleRequestedTab(message) {
  const tab = await browser.tabs.get(message.tabID).catch(() => null);
  if (!tab) return;
  if (message.action === "close") {
    await browser.tabs.remove(tab.id).catch(() => {});
    return;
  }
  if (!isRuntimeAllowedTab(tab)) return;
  if (tab.windowId != null) {
    await browser.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
  await browser.tabs.update(tab.id, { active: true }).catch(() => {});
}

function scheduleTabSnapshot(force = false) {
  snapshotForcePending ||= force;
  if (snapshotTimer !== null) return;
  snapshotTimer = setTimeout(() => {
    const shouldForce = snapshotForcePending;
    snapshotTimer = null;
    snapshotForcePending = false;
    publishTabSnapshot(shouldForce);
  }, TAB_SNAPSHOT_DEBOUNCE_MS);
}

async function publishTabSnapshot(force = false) {
  if (!commandPort) connectCommandPort();
  if (!commandPort) return;
  const tabs = rules.active ? await browser.tabs.query({}) : [];
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
      .sort((left, right) => left.id - right.id);
  const nextFingerprint = JSON.stringify(snapshotTabs);
  if (!force && nextFingerprint === lastSnapshotFingerprint) return;
  if (postCommandPort({ type: "tabsSnapshot", tabs: snapshotTabs })) {
    lastSnapshotFingerprint = nextFingerprint;
  }
}

async function notifyNativeGuardState() {
  if (postCommandPort({ type: "setGuardEnabled", enabled: guardEnabled })) return;
  if (typeof browser.runtime.connectNative === "function") return;
  try {
    await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "setGuardEnabled",
      enabled: guardEnabled,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER,
      extensionVersion: EXTENSION_VERSION,
      extensionCapabilities: EXTENSION_CAPABILITIES
    });
  } catch (_) {}
}

function effectiveRules(nativeRules) {
  if (!guardEnabled || !nativeRules?.active) {
    return inactiveRules();
  }
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

async function refreshRules() {
  await ensureInitialized();
  if (commandPort) {
    if (pendingRuleRefresh) return pendingRuleRefresh;
    pendingRuleRefresh = new Promise((resolve) => {
      resolvePendingRuleRefresh = resolve;
    });
    if (!postCommandPort({ type: "getRules" })) {
      settlePendingRuleRefresh();
    }
    return pendingRuleRefresh;
  }
  if (typeof browser.runtime.connectNative === "function") {
    connectCommandPort();
    return;
  }

  // Lightweight background tests and older Firefox builds use one-shot messaging.
  try {
    const nativeRules = await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "getRules",
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER
    });
    await applyNativeRules(nativeRules);
  } catch (_) {
    await applyNativeRules(inactiveRules());
  }
}

function settlePendingRuleRefresh() {
  if (resolvePendingRuleRefresh) resolvePendingRuleRefresh();
  pendingRuleRefresh = null;
  resolvePendingRuleRefresh = null;
}

function sendHeartbeat() {
  if (!commandPort) connectCommandPort();
  postCommandPort({ type: "heartbeat" });
}

async function applyNativeRules(nativeRules) {
  const previousFingerprint = rulesFingerprint;
  rules = effectiveRules(nativeRules);

  rulesFingerprint = fingerprintRules(rules);
  if (rulesFingerprint === previousFingerprint) {
    return;
  }

  if (rules.active) {
    await removeAlreadyBlockedTabs();
    await synchronizeStartupTabs();
    await primeAllowedTab();
  } else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
    completedStartupFingerprint = null;
  }
  scheduleTabSnapshot(true);
}

async function removeAlreadyBlockedTabs() {
  if (rules.accessMode !== "blacklist") return;
  const tabs = await browser.tabs.query({});
  const blocked = tabs.filter((tab) => tab.id != null && tab.url && !isAllowedURL(tab.url, rules));
  for (const tab of blocked) {
    if (tabs.length - blocked.length <= 0 && blocked[blocked.length - 1]?.id === tab.id) {
      await browser.tabs.update(tab.id, { url: "about:newtab", active: tab.active }).catch(() => {});
      freshBlankTabIds.add(tab.id);
    } else {
      await browser.tabs.remove(tab.id).catch(() => {});
    }
  }
}

async function getAllowedTab(tabId) {
  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (!tab || !isRuntimeAllowedTab(tab)) {
    return null;
  }
  return tab;
}

function isFreshBlankTab(tab) {
  return Boolean(tab?.id && freshBlankTabIds.has(tab.id) && isSearchStagingURL(tab.url));
}

function isRuntimeAllowedTab(tab) {
  return Boolean(
    tab?.url &&
    (isAllowedURL(tab.url, rules) || isFreshBlankTab(tab))
  );
}

async function primeAllowedTab() {
  const tabs = await browser.tabs.query({});
  for (const tab of tabs) {
    if (tab.id != null && isAllowedURL(tab.url, rules)) {
      lastAllowedURLByTab.set(tab.id, tab.url);
    }
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
    const tabs = await browser.tabs.query({});
    if (tabs.length === 0) return;

    completedStartupFingerprint = startupFingerprint;
    if (rules.startupSessionID) {
      completedStartupSessionID = rules.startupSessionID;
      await browser.storage.local.set({ completedStartupSessionID }).catch(() => {});
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
          ? await browser.tabs.update(staging.id, { url: startupURL, active: Boolean(staging.active) })
          : await browser.tabs.create({ url: startupURL, active: false });
      }
      claimedTabIds.add(tab.id);
      freshBlankTabIds.delete(tab.id);
      firstStartupTab ||= tab;
    }

    if (firstStartupTab) {
      lastAllowedTabId = firstStartupTab.id;
      await browser.tabs.update(firstStartupTab.id, { active: true });
    }
  } finally {
    synchronizingStartupTabs = false;
  }
}

async function rememberIfAllowed(tabId) {
  if (!rules.active) {
    return;
  }

  const tab = await getAllowedTab(tabId);
  if (tab) {
    if (isAllowedURL(tab.url, rules)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  }
}

async function returnToAllowedTab() {
  if (enforcing) {
    return;
  }

  enforcing = true;
  try {
    if (lastAllowedTabId !== null) {
      const lastAllowed = await getAllowedTab(lastAllowedTabId);
      if (lastAllowed) {
        await browser.tabs.update(lastAllowed.id, { active: true });
        return;
      }
      lastAllowedTabId = null;
    }

    const tabs = await browser.tabs.query({});
    const allowed = tabs.find((tab) => isRuntimeAllowedTab(tab));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await browser.tabs.update(allowed.id, { active: true });
      return;
    }

  } catch (_) {
    lastAllowedTabId = null;
  } finally {
    enforcing = false;
  }
}

function shouldBlockNavigation(url) {
  return Boolean(
    guardEnabled &&
    rules.active &&
    rules.blockNavigation &&
    url &&
    !isAllowedURL(url, rules)
  );
}

async function recoverBlockedNavigation(tabId) {
  if (tabId < 0) {
    await returnToAllowedTab();
    return;
  }

  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (!tab) {
    await returnToAllowedTab();
    return;
  }

  if (
    rules.accessMode === "whitelist" &&
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs
  ) {
    freshBlankTabIds.delete(tabId);
    try {
      await browser.tabs.remove(tabId);
    } catch (_) {}
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
    await browser.tabs.update(tabId, { url: fallbackURL, active: true }).catch(() => {});
    lastAllowedTabId = tabId;
    return;
  }
  if (rules.accessMode === "blacklist") {
    await browser.tabs.update(tabId, { url: "about:newtab", active: true }).catch(() => {});
    freshBlankTabIds.add(tabId);
    lastAllowedTabId = tabId;
    return;
  }

  await returnToAllowedTab();
}

browser.runtime.onMessage.addListener((message) => {
  if (message?.type === "getGuardStatus") {
    return ensureInitialized().then(() => ({ enabled: guardEnabled }));
  }

  if (message?.type === "setGuardEnabled") {
    const enabled = message.enabled !== false;
    return browser.storage.local
      .set({ guardEnabled: enabled })
      .then(async () => {
        guardEnabled = enabled;
        await notifyNativeGuardState();
        await refreshRules();
        return { enabled: guardEnabled };
      });
  }

  return false;
});

browser.tabs.onActivated.addListener(async ({ tabId }) => {
  const tab = await browser.tabs.get(tabId).catch(() => null);
  await recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active) {
    return;
  }
  if (!tab || !tab.url) {
    return;
  }

  if (isAllowedURL(tab.url, rules)) {
    freshBlankTabIds.delete(tabId);
    lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
    return;
  }

  if (isFreshBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockTabSwitching) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

browser.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url && changeInfo.status !== "complete") {
    return;
  }

  await recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active || !tab.url) {
    return;
  }

  if (
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs &&
    changeInfo.url &&
    !isSearchStagingURL(changeInfo.url) &&
    !isAllowedURL(changeInfo.url, rules)
  ) {
    await recoverBlockedNavigation(tabId);
    return;
  }

  if (isAllowedURL(tab.url, rules)) {
    freshBlankTabIds.delete(tabId);
    lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
    return;
  }

  if (isFreshBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockNavigation) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

browser.tabs.onCreated.addListener(async (tab) => {
  scheduleTabSnapshot();
  if (!rules.active) {
    return;
  }

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
    const latest = await browser.tabs.get(tab.id).catch(() => null);
    if (!latest || !latest.url || isAllowedURL(latest.url, rules)) {
      await rememberIfAllowed(tab.id);
      return;
    }

    try {
      await browser.tabs.remove(latest.id);
    } catch (_) {
      await returnToAllowedTab();
    }
    await returnToAllowedTab();
    scheduleTabSnapshot();
  }, NEW_TAB_GRACE_MS);
  scheduleTabSnapshot();
});

browser.tabs.onRemoved.addListener(async (tabId) => {
  scheduleTabSnapshot();
  if (!rules.active) {
    return;
  }

  freshBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);

  if (lastAllowedTabId === tabId) {
    lastAllowedTabId = null;
  }

  setTimeout(returnToAllowedTab, 0);
  scheduleTabSnapshot();
});

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (
      rules.active &&
      freshBlankTabIds.has(details.tabId) &&
      !rules.allowGoogleSearchTabs &&
      details.url &&
      !isSearchStagingURL(details.url) &&
      !isAllowedURL(details.url, rules)
    ) {
      setTimeout(() => recoverBlockedNavigation(details.tabId), 0);
      return { cancel: true };
    }

    if (shouldBlockNavigation(details.url)) {
      setTimeout(() => {
        recoverBlockedNavigation(details.tabId);
      }, 0);
      return { cancel: true };
    }

    return {};
  },
  { urls: ["<all_urls>"], types: ["main_frame"] },
  ["blocking"]
);

ensureInitialized().then(() => {
  if (!commandPort && typeof browser.runtime.connectNative !== "function") {
    refreshRules();
  }
});
setInterval(sendHeartbeat, HEARTBEAT_MS);
