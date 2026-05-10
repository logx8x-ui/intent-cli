const HOST_NAME = "intent_native_host";
const RULE_REFRESH_MS = 1000;
const NEW_TAB_GRACE_MS = 250;
const BLOCKED_URL = "about:blank";

let rules = inactiveRules();
let lastAllowedTabId = null;
let enforcing = false;

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

async function refreshRules() {
  try {
    rules = await browser.runtime.sendNativeMessage(HOST_NAME, { type: "getRules" });
  } catch (_) {
    rules = inactiveRules();
  }
}

function normalizeRule(value) {
  return String(value || "")
    .trim()
    .replace(/^https?:\/\//i, "")
    .replace(/^www\./i, "")
    .replace(/\/+$/g, "")
    .toLowerCase();
}

function normalizedURLParts(url) {
  try {
    if (["about:blank", "about:newtab"].includes(url)) {
      return {
        host: "about",
        path: url.replace("about:", "/")
      };
    }

    const parsed = new URL(url);
    if (!["http:", "https:"].includes(parsed.protocol)) {
      return null;
    }
    return {
      host: parsed.hostname.replace(/^www\./i, "").toLowerCase(),
      path: parsed.pathname.replace(/\/+$/g, "").toLowerCase()
    };
  } catch (_) {
    return null;
  }
}

function isSearchStagingURL(url) {
  return ["about:blank", "about:newtab"].includes(url);
}

function isGoogleSearchURL(url) {
  const parts = normalizedURLParts(url);
  if (!parts) {
    return false;
  }

  const googleHost = parts.host === "google.com" || /^google\.[a-z.]+$/.test(parts.host);
  return googleHost && (parts.path === "" || parts.path === "/" || parts.path === "/search");
}

function isAllowedURL(url) {
  if (!rules.active || rules.allowedWebsites.length === 0) {
    return true;
  }

  if (rules.allowGoogleSearchTabs && (isSearchStagingURL(url) || isGoogleSearchURL(url))) {
    return true;
  }

  const parts = normalizedURLParts(url);
  if (!parts) {
    return false;
  }

  return rules.allowedWebsites.some((rawRule) => {
    const rule = normalizeRule(rawRule);
    if (!rule) {
      return false;
    }

    const slashIndex = rule.indexOf("/");
    const ruleHost = slashIndex === -1 ? rule : rule.slice(0, slashIndex);
    const rulePath = slashIndex === -1 ? "" : rule.slice(slashIndex);
    const hostMatches = parts.host === ruleHost || parts.host.endsWith(`.${ruleHost}`);

    if (!hostMatches) {
      return false;
    }

    return rulePath === "" || parts.path === rulePath || parts.path.startsWith(`${rulePath}/`);
  });
}

async function rememberIfAllowed(tabId) {
  try {
    const tab = await browser.tabs.get(tabId);
    if (tab && tab.url && isAllowedURL(tab.url)) {
      lastAllowedTabId = tabId;
    }
  } catch (_) {}
}

async function returnToAllowedTab() {
  if (enforcing) {
    return;
  }

  enforcing = true;
  try {
    if (lastAllowedTabId !== null) {
      await browser.tabs.update(lastAllowedTabId, { active: true });
      return;
    }

    const tabs = await browser.tabs.query({ currentWindow: true });
    const allowed = tabs.find((tab) => tab.url && isAllowedURL(tab.url));
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
    await rememberIfAllowed(tabId);
    return;
  }

  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (!tab || !tab.url) {
    return;
  }

  if (isAllowedURL(tab.url)) {
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

  if (isAllowedURL(tab.url)) {
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
    if (!latest || !latest.url || isAllowedURL(latest.url)) {
      if (latest && latest.url) {
        lastAllowedTabId = latest.id;
      }
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
