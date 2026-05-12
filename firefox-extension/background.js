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

async function refreshRules() {
  const previousFingerprint = rulesFingerprint;
  try {
    rules = await browser.runtime.sendNativeMessage(HOST_NAME, { type: "getRules" });
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

refreshRules();
setInterval(refreshRules, RULE_REFRESH_MS);
