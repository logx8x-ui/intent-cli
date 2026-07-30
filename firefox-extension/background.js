const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "org.mozilla.firefox";
const RULE_REFRESH_MS = 1000;
const TAB_SNAPSHOT_MS = 120;
const RECONNECT_MS = 1000;
const NEW_TAB_GRACE_MS = 250;

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
let commandPort = null;
let reconnectTimer = null;

function inactiveRules() {
  return {
    active: false,
    allowedWebsites: [],
    startupWebsites: [],
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
    const stored = await browser.storage.local.get({ guardEnabled: true });
    guardEnabled = stored.guardEnabled !== false;
  } catch (_) {
    guardEnabled = true;
  }

  initialized = true;
  connectCommandPort();
  await notifyNativeGuardState();
}

function connectCommandPort() {
  if (commandPort) return;
  if (typeof browser.runtime.connectNative !== "function") return;
  try {
    const port = browser.runtime.connectNative(HOST_NAME);
    commandPort = port;
    port.onMessage.addListener(async (message) => {
      if (message?.tabCommand) await handleRequestedTab(message.tabCommand);
      await applyNativeRules(message);
    });
    port.onDisconnect.addListener(() => {
      if (commandPort !== port) return;
      commandPort = null;
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
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectCommandPort();
  }, RECONNECT_MS);
}

function postCommandPort(message) {
  if (!commandPort) return false;
  try {
    commandPort.postMessage({ ...message, browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER });
    return true;
  } catch (_) {
    commandPort = null;
    scheduleCommandReconnect();
    return false;
  }
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

async function publishTabSnapshot() {
  if (!commandPort) connectCommandPort();
  if (!commandPort) return;
  const tabs = rules.active ? await browser.tabs.query({}) : [];
  postCommandPort({
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

async function notifyNativeGuardState() {
  if (postCommandPort({ type: "setGuardEnabled", enabled: guardEnabled })) return;
  if (typeof browser.runtime.connectNative === "function") return;
  try {
    await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "setGuardEnabled",
      enabled: guardEnabled,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER
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
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : [],
    startupWebsites: Array.isArray(nativeRules.startupWebsites) ? nativeRules.startupWebsites : [],
    blockTabSwitching: Boolean(nativeRules.blockTabSwitching),
    blockNavigation: Boolean(nativeRules.blockNavigation),
    blockNewTabs: Boolean(nativeRules.blockNewTabs),
    allowGoogleSearchTabs: Boolean(nativeRules.allowGoogleSearchTabs)
  };
}

async function refreshRules() {
  await ensureInitialized();
  if (postCommandPort({ type: "getRules" })) return;
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

async function applyNativeRules(nativeRules) {
  const previousFingerprint = rulesFingerprint;
  rules = effectiveRules(nativeRules);

  rulesFingerprint = fingerprintRules(rules);
  if (rulesFingerprint === previousFingerprint) {
    return;
  }

  if (rules.active) {
    await synchronizeStartupTabs();
    await primeAllowedTab();
  } else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
  }
  await publishTabSnapshot();
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

async function synchronizeStartupTabs() {
  if (!rules.active || rules.startupWebsites.length === 0) return;

  const tabs = await browser.tabs.query({});
  if (tabs.length === 0) return;

  const claimedTabIds = new Set();
  let stagingTabs = tabs.filter((tab) => isSearchStagingURL(tab.url));
  let firstStartupTab = null;

  for (const startupURL of rules.startupWebsites) {
    let tab = tabs.find((candidate) =>
      !claimedTabIds.has(candidate.id) && startupURLMatches(candidate.url || "", startupURL)
    );
    if (!tab) {
      const staging = stagingTabs.shift();
      tab = staging
        ? await browser.tabs.update(staging.id, { url: startupURL, active: false })
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
}

async function rememberIfAllowed(tabId) {
  if (!rules.active) {
    return;
  }

  const tab = await getAllowedTab(tabId);
  if (tab) {
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

    if (tabs.length > 0 && rules.startupWebsites.length > 0) {
      await synchronizeStartupTabs();
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

  if (freshBlankTabIds.has(tabId) && !rules.allowGoogleSearchTabs) {
    freshBlankTabIds.delete(tabId);
    try {
      await browser.tabs.remove(tabId);
    } catch (_) {}
    await returnToAllowedTab();
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
  await refreshRules();
  if (!rules.active) {
    return;
  }

  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (!tab || !tab.url) {
    return;
  }

  if (isAllowedURL(tab.url, rules)) {
    freshBlankTabIds.delete(tabId);
    lastAllowedTabId = tabId;
    return;
  }

  if (isFreshBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockTabSwitching) {
    await returnToAllowedTab();
  }
  await publishTabSnapshot();
});

browser.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url && changeInfo.status !== "complete") {
    return;
  }

  await refreshRules();
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
    lastAllowedTabId = tabId;
    return;
  }

  if (isFreshBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockNavigation) {
    await returnToAllowedTab();
  }
  await publishTabSnapshot();
});

browser.tabs.onCreated.addListener(async (tab) => {
  await refreshRules();
  if (!rules.active) {
    return;
  }

  if (!tab.url || isSearchStagingURL(tab.url)) {
    const tabs = await browser.tabs.query({});
    const hasOtherAllowedTab = tabs.some((candidate) =>
      candidate.id !== tab.id && isAllowedURL(candidate.url, rules)
    );
    if (rules.startupWebsites.length > 0 && !hasOtherAllowedTab) {
      await synchronizeStartupTabs();
      return;
    }
    freshBlankTabIds.add(tab.id);
    lastAllowedTabId = tab.id;
    return;
  }

  if (isAllowedURL(tab.url, rules)) {
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
  }, NEW_TAB_GRACE_MS);
  await publishTabSnapshot();
});

browser.tabs.onRemoved.addListener(async (tabId) => {
  await refreshRules();
  if (!rules.active) {
    return;
  }

  freshBlankTabIds.delete(tabId);

  if (lastAllowedTabId === tabId) {
    lastAllowedTabId = null;
  }

  setTimeout(returnToAllowedTab, 0);
  await publishTabSnapshot();
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

ensureInitialized().then(refreshRules);
setInterval(refreshRules, RULE_REFRESH_MS);
setInterval(publishTabSnapshot, TAB_SNAPSHOT_MS);
