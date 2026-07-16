const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "org.mozilla.firefox";
const RULE_REFRESH_MS = 1000;
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
let recoveryBlankTabIds = new Set();
let creatingRecoveryBlankTab = false;

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
  await notifyNativeGuardState();
}

async function notifyNativeGuardState() {
  try {
    await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "setGuardEnabled",
      enabled: guardEnabled,
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER
    });
  } catch (_) {}
}

function effectiveRules(nativeRules) {
  if (!guardEnabled) {
    return inactiveRules();
  }

  return nativeRules || inactiveRules();
}

async function refreshRules() {
  await ensureInitialized();
  const previousFingerprint = rulesFingerprint;
  try {
    const nativeRules = await browser.runtime.sendNativeMessage(HOST_NAME, {
      type: "getRules",
      browserBundleIdentifier: BROWSER_BUNDLE_IDENTIFIER
    });
    rules = effectiveRules(nativeRules);
  } catch (_) {
    rules = inactiveRules();
  }

  rulesFingerprint = fingerprintRules(rules);
  if (rulesFingerprint === previousFingerprint) {
    return;
  }

  if (rules.active) {
    await primeAllowedTab();
  } else {
    lastAllowedTabId = null;
  }
}

async function getAllowedTab(tabId) {
  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (!tab || !isRuntimeAllowedTab(tab)) {
    return null;
  }
  return tab;
}

function isRecoveryBlankTab(tab) {
  return Boolean(tab?.id && recoveryBlankTabIds.has(tab.id) && tab.url === "about:blank");
}

function isRuntimeAllowedTab(tab) {
  return Boolean(
    tab?.url &&
    (isAllowedURL(tab.url, rules) || isRecoveryBlankTab(tab))
  );
}

async function primeAllowedTab() {
  const tabs = await browser.tabs.query({});
  const activeAllowed = tabs.find((tab) => tab.active && isRuntimeAllowedTab(tab));
  const firstAllowed = activeAllowed || tabs.find((tab) => isRuntimeAllowedTab(tab));
  lastAllowedTabId = firstAllowed?.id ?? null;
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

    await openRecoveryBlankTab();
  } catch (_) {
    lastAllowedTabId = null;
  } finally {
    enforcing = false;
  }
}

async function openRecoveryBlankTab() {
  creatingRecoveryBlankTab = true;
  try {
    const tab = await browser.tabs.create({ url: "about:blank", active: true });
    recoveryBlankTabIds.add(tab.id);
    lastAllowedTabId = tab.id;
  } finally {
    creatingRecoveryBlankTab = false;
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

  if (rules.allowGoogleSearchTabs && (!tab.url || isSearchStagingURL(tab.url) || isAllowedURL(tab.url, rules))) {
    await returnToAllowedTab();
    return;
  }

  try {
    await browser.tabs.remove(tabId);
  } catch (_) {
    await returnToAllowedTab();
  }
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
    recoveryBlankTabIds.delete(tabId);
    lastAllowedTabId = tabId;
    return;
  }

  if (isRecoveryBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockTabSwitching) {
    await returnToAllowedTab();
  }
});

browser.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url && changeInfo.status !== "complete") {
    return;
  }

  await refreshRules();
  if (!rules.active || !tab.url) {
    return;
  }

  if (isAllowedURL(tab.url, rules)) {
    recoveryBlankTabIds.delete(tabId);
    lastAllowedTabId = tabId;
    return;
  }

  if (isRecoveryBlankTab(tab)) {
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockNavigation) {
    await returnToAllowedTab();
  }
});

browser.tabs.onCreated.addListener(async (tab) => {
  await refreshRules();
  if (!rules.active || !rules.blockNewTabs) {
    return;
  }

  if (isRecoveryBlankTab(tab) || (creatingRecoveryBlankTab && tab.url === "about:blank")) {
    recoveryBlankTabIds.add(tab.id);
    return;
  }

  if (rules.allowGoogleSearchTabs && (!tab.url || isSearchStagingURL(tab.url))) {
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
});

browser.tabs.onRemoved.addListener(async (tabId) => {
  await refreshRules();
  if (!rules.active) {
    return;
  }

  recoveryBlankTabIds.delete(tabId);

  if (lastAllowedTabId === tabId) {
    lastAllowedTabId = null;
  }

  setTimeout(returnToAllowedTab, 0);
});

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
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
