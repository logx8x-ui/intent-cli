const HOST_NAME = "intent_native_host";
const RULE_REFRESH_MS = 1000;
const NEW_TAB_GRACE_MS = 250;
const BLOCKED_URL = "about:blank";

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
      enabled: guardEnabled
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
    const nativeRules = await browser.runtime.sendNativeMessage(HOST_NAME, { type: "getRules" });
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
  if (!tab || !tab.url || !isAllowedURL(tab.url, rules)) {
    return null;
  }
  return tab;
}

async function primeAllowedTab() {
  const tabs = await browser.tabs.query({});
  const activeAllowed = tabs.find((tab) => tab.active && tab.url && isAllowedURL(tab.url, rules));
  const firstAllowed = activeAllowed || tabs.find((tab) => tab.url && isAllowedURL(tab.url, rules));
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
    const allowed = tabs.find((tab) => tab.url && isAllowedURL(tab.url, rules));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await browser.tabs.update(allowed.id, { active: true });
    }
  } catch (_) {
    lastAllowedTabId = null;
  } finally {
    enforcing = false;
  }
}

async function blockTab(tabId) {
  if (enforcing) {
    return;
  }

  enforcing = true;
  try {
    await browser.tabs.update(tabId, { url: BLOCKED_URL });
  } catch (_) {}
  enforcing = false;
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
    lastAllowedTabId = tabId;
    return;
  }

  if (rules.blockNavigation) {
    await blockTab(tabId);
  }
});

browser.tabs.onCreated.addListener(async (tab) => {
  await refreshRules();
  if (!rules.active || !rules.blockNewTabs) {
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
      await blockTab(latest.id);
    }
    await returnToAllowedTab();
  }, NEW_TAB_GRACE_MS);
});

ensureInitialized().then(refreshRules);
setInterval(refreshRules, RULE_REFRESH_MS);
