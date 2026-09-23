const HOST_NAME = "intent_native_host";
const BROWSER_BUNDLE_IDENTIFIER = "org.mozilla.firefox";
const RECONNECT_MS = 1000;
const MAX_RECONNECT_MS = 30000;
// Stay inside Intent's five-second readiness window without waking every two seconds.
const HEARTBEAT_MS = 3000;
const TAB_SNAPSHOT_DEBOUNCE_MS = 40;
const NEW_TAB_GRACE_MS = 250;
const SITE_RECORD_THROTTLE_MS = 30000;
const EXTENSION_VERSION = browser.runtime.getManifest().version;
const EXTENSION_CAPABILITIES = ["single-startup-launch-v1", "hide-distractions-v1"];
const browserSessionID = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
let hostSupportsQuickSelection = false;
let hostSupportsTabPreview = false;
let hostSupportsNativeTabGroups = false;
let hostSupportsSessionIdentity = false;
function advertisedCapabilities() {
  return hostSupportsQuickSelection && hostSupportsSessionIdentity && browserSessionID
    ? [...EXTENSION_CAPABILITIES, "quick-selection-tabs-v1", "blacklist-selection-tabs-v1", ...(hostSupportsNativeTabGroups ? ["native-tab-groups-v1"] : []), ...(hostSupportsSessionIdentity && browserSessionID ? ["tab-session-identity-v1"] : []), ...(hostSupportsTabPreview ? ["tab-preview-v1"] : [])] : EXTENSION_CAPABILITIES;
}

const {
  isAllowedURL,
  isSearchStagingURL
} = IntentBrowserRules;

const tabVisibility = typeof IntentTabVisibility !== "undefined" ? new IntentTabVisibility(browser, true) : null;
let rules = inactiveRules();
let lastAllowedTabId = null;
let enforcing = false;
let rulesFingerprint = fingerprintRules(rules);
let guardEnabled = true;
let initialized = false;
let freshBlankTabIds = new Set();
const lastAllowedURLByTab = new Map();
const searchSessionTabs = new Set();
const committedURLByTab = new Map();

// Firefox can deliver the completed about:blank event for a reused startup tab
// after tabs.update() has already begun loading the requested site. Keep the
// startup navigation explicit so that stale event cannot cancel the real load.
const startupNavigationURLByTab = new Map();
let commandPort = null;
let reconnectTimer = null;
let reconnectDelayMs = RECONNECT_MS;
let nativeConnectionConfirmed = false;
let lastForegroundReconnectAt = -Infinity;
function guardStatus() {
  return { enabled: guardEnabled, connected: Boolean(commandPort && nativeConnectionConfirmed) };
}
// A foreground action can shorten a long retry delay, without every tab event
// defeating exponential backoff. Never replace a healthy native connection.
function recoverForegroundConnection() {
  if (commandPort || Date.now() - lastForegroundReconnectAt < 3000) return;
  lastForegroundReconnectAt = Date.now();
  if (reconnectTimer !== null) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  reconnectDelayMs = RECONNECT_MS;
  connectCommandPort();
}

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
  if (commandPort || reconnectTimer !== null) return;
  if (typeof browser.runtime.connectNative !== "function") return;
  try {
    const port = browser.runtime.connectNative(HOST_NAME);
    commandPort = port;
    hostSupportsQuickSelection = false;
    nativeConnectionConfirmed = false;
    port.onMessage.addListener(async (message) => {
      if (commandPort !== port) return;
      nativeConnectionConfirmed = true;
      reconnectDelayMs = RECONNECT_MS;
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
      if (message?.tabCommand) await handleRequestedTab(message.tabCommand);
      await applyNativeRules(message);
      settlePendingRuleRefresh();
    });
    port.onDisconnect.addListener(() => {
      if (commandPort !== port) return;
      commandPort = null;
      nativeConnectionConfirmed = false;
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
      extensionCapabilities: advertisedCapabilities()
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
      extensionCapabilities: advertisedCapabilities()
    });
  } catch (_) {}
}

let previewBusy = false;
async function captureTabPreview(message) {
  const result = { requestID: message.id };
  if (previewBusy || rules.active) {
    postCommandPort({ type: "tabPreview", preview: { ...result, error: "Preview unavailable during a session." } });
    return;
  }
  previewBusy = true;
  try {
    const tab = await browser.tabs.get(message.tabID);
    if (tab.windowId !== message.windowID || tab.incognito || tab.discarded || !/^https?:\/\//.test(tab.url || "")) {
      throw new Error("This tab cannot be previewed.");
    }
    result.image = await browser.tabs.captureTab(tab.id, { format: "jpeg", quality: 65 });
  } catch (_) {
    result.error = "Preview unavailable. Open the tab once, then try again.";
  } finally {
    previewBusy = false;
  }
  postCommandPort({ type: "tabPreview", preview: result });
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
    const current = await browser.tabs.get(message.tabID).catch(() => null);
    if (current?.windowId === message.windowID) tab = current;
  }
  if (!tab) {
    if (message.action === "preview") postCommandPort({
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
    if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await browser.tabs.remove(tab.id).catch(() => {});
    return;
  }
  if (!isRuntimeAllowedTab(tab)) return;
  await browser.windows.update(tab.windowId, { focused: true }).catch(() => {});
  // Focusing a window is asynchronous; a user can move/close the target meanwhile.
  const current = await browser.tabs.get(tab.id).catch(() => null);
  if (current?.windowId !== message.windowID || !isRuntimeAllowedTab(current)) return;
  await browser.tabs.update(tab.id, { active: true }).catch(() => {});
}

function scheduleTabSnapshot(force = false) {
  if (!rules.active && !force) return;
  snapshotForcePending ||= force;
  if (snapshotTimer !== null) return;
  snapshotTimer = setTimeout(() => {
    const shouldForce = snapshotForcePending;
    snapshotTimer = null;
    snapshotForcePending = false;
    publishTabSnapshot(shouldForce);
  }, TAB_SNAPSHOT_DEBOUNCE_MS);
}

async function publishTabSnapshot(force = false, discovery = false) {
  if (!commandPort) connectCommandPort();
  if (!commandPort) return;
  const tabs = rules.active || discovery ? await browser.tabs.query({}) : [];
  // Window identity is supplied by the browser; bounds disambiguate equal titles
  // when matching these IDs to macOS WindowServer preview windows.
  const windows = tabs.length && browser.windows?.getAll
    ? await browser.windows.getAll({ populate: false, windowTypes: ["normal", "popup"] }).catch(() => []) : [];
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
      .sort((left, right) => (left.windowID - right.windowID) || (left.index - right.index) || (left.id - right.id));
  const allowedIDs = new Set(tabs.filter(tab => discovery || isRuntimeAllowedTab(tab)).map(tab => tab.id));
  const snapshotTabs = allSnapshotTabs.filter(tab => allowedIDs.has(tab.id));
  const nextFingerprint = JSON.stringify({ tabs: snapshotTabs, allTabs: allSnapshotTabs });
  if (!force && nextFingerprint === lastSnapshotFingerprint) return;
  if (postCommandPort({ type: "tabsSnapshot", browserSessionID, tabs: snapshotTabs, allTabs: allSnapshotTabs })) {
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
      extensionCapabilities: advertisedCapabilities()
    });
  } catch (_) {}
}

function effectiveRules(nativeRules) {
  // Browser tab IDs can be reused after restart. Never apply the previous
  // browser session's exact-ID policy to newly created tabs.
  if (Array.isArray(nativeRules?.selectedTabIDs)
      && (!browserSessionID || typeof nativeRules.selectedBrowserSessionID !== "string"
          || nativeRules.selectedBrowserSessionID !== browserSessionID)) return inactiveRules();
  if (!guardEnabled || !nativeRules?.active) {
    return inactiveRules();
  }
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
  tabVisibility?.sync(rules, isRuntimeAllowedTab);
  if (rules.active && Array.isArray(rules.selectedTabIDs)) {
    browser.tabs.query({ active: true, lastFocusedWindow: true }).then(tabs => {
      if (tabs.some(tab => tab.active && !isRuntimeAllowedTab(tab))) returnToAllowedTab();
    }).catch(() => {});
  }
  if (!commandPort) connectCommandPort();
  postCommandPort({ type: "heartbeat" });
}

async function applyNativeRules(nativeRules) {
  const previousFingerprint = rulesFingerprint;
  const nextRules = effectiveRules(nativeRules);
  if (!nextRules.active) await tabVisibility?.sync(nextRules, () => true);
  if (nextRules.startupSessionID !== rules.startupSessionID) searchSessionTabs.clear();
  rules = nextRules;

  rulesFingerprint = fingerprintRules(rules);
  if (rulesFingerprint === previousFingerprint) {
    return;
  }

  if (rules.active) {
    await removeAlreadyBlockedTabs();
    await synchronizeStartupTabs();
    await primeAllowedTab();
    for (const tab of await browser.tabs.query({})) if (!committedURLByTab.has(tab.id) && tab.url) committedURLByTab.set(tab.id, tab.url);
    if (Array.isArray(rules.selectedTabIDs)) await returnToAllowedTab();
  } else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
    searchSessionTabs.clear(); committedURLByTab.clear();
    startupNavigationURLByTab.clear();
    completedStartupFingerprint = null;
  }
  await tabVisibility?.sync(rules, isRuntimeAllowedTab);
  scheduleTabSnapshot(true);
}

async function removeAlreadyBlockedTabs() {
  // Blacklisting preserves every tab; native blur and activation guards block access.
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
  // Explicit tab selection follows that tab across URLs, redirects and SPA routes.
  if (rules.active && Array.isArray(rules.selectedTabIDs)) return rules.accessMode === "blacklist" ? !rules.selectedTabIDs.includes(tab?.id) : (rules.selectedTabIDs.includes(tab?.id) || (rules.allowGoogleSearchTabs && searchSessionTabs.has(tab?.id)));
  return Boolean(
    tab?.url &&
    (isAllowedURL(tab.url, rules) || isFreshBlankTab(tab))
  );
}

async function primeAllowedTab() {
  const tabs = await browser.tabs.query({});
  for (const tab of tabs) {
    if (tab.id != null && isRuntimeAllowedTab(tab)) {
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

function beginStartupNavigation(tabId, startupURL) {
  startupNavigationURLByTab.set(tabId, {
    startupURL,
    lastNavigationURL: null
  });
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
      if (tab) {
        // An existing matching tab may be discarded by Firefox/Sidebery or
        // incompletely restored. Load it deliberately once for this session.
        beginStartupNavigation(tab.id, startupURL);
        if (sameNavigationURL(tab.url || "", startupURL)) {
          await browser.tabs.reload(tab.id);
        } else {
          tab = await browser.tabs.update(tab.id, {
            url: startupURL,
            active: Boolean(tab.active)
          });
        }
      } else {
        const staging = stagingTabs.shift();
        if (staging) {
          // Mark this before tabs.update: Firefox may emit the old blank tab's
          // completion event before the update promise settles.
          beginStartupNavigation(staging.id, startupURL);
          tab = await browser.tabs.update(staging.id, {
            url: startupURL,
            active: Boolean(staging.active)
          });
        } else {
          tab = await browser.tabs.create({ url: "about:blank", active: false });
          beginStartupNavigation(tab.id, startupURL);
          tab = await browser.tabs.update(tab.id, { url: startupURL, active: false });
        }
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
    if (isRuntimeAllowedTab(tab)) lastAllowedURLByTab.set(tabId, tab.url);
    lastAllowedTabId = tabId;
  }
}

let enforcementPending = false;
async function returnToAllowedTab() {
  if (enforcing) {
    enforcementPending = true;
    return;
  }

  enforcing = true;
  try {
    if (lastAllowedTabId !== null) {
      const lastAllowed = await getAllowedTab(lastAllowedTabId);
      if (lastAllowed) {
        await browser.tabs.update(lastAllowed.id, { active: true });
        if (Array.isArray(rules.selectedTabIDs) && lastAllowed.windowId != null) {
          await browser.windows?.update(lastAllowed.windowId, { focused: true }).catch(() => {});
        }
        return;
      }
      lastAllowedTabId = null;
    }

    const tabs = await browser.tabs.query({});
    const allowed = tabs.find((tab) => isRuntimeAllowedTab(tab));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await browser.tabs.update(allowed.id, { active: true });
      if (Array.isArray(rules.selectedTabIDs) && allowed.windowId != null) {
        await browser.windows?.update(allowed.windowId, { focused: true }).catch(() => {});
      }
      return;
    }

  } catch (_) {
    lastAllowedTabId = null;
  } finally {
    enforcing = false;
    if (enforcementPending) {
      enforcementPending = false;
      if (rules.active && Array.isArray(rules.selectedTabIDs)) setTimeout(returnToAllowedTab, 0);
    }
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
  if (rules.accessMode === "blacklist") { await returnToAllowedTab(); return; }
  // Do not navigate or close an existing unselected tab. Leave it intact for after the session.
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    await returnToAllowedTab();
    return;
  }
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
    !Array.isArray(rules.selectedTabIDs) &&
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs
  ) {
    freshBlankTabIds.delete(tabId);
    try {
      if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await browser.tabs.remove(tabId);
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
    return ensureInitialized().then(() => { recoverForegroundConnection(); postCommandPort({ type: "getRules" }); return guardStatus(); });
  }

  if (message?.type === "setGuardEnabled") {
    const enabled = message.enabled !== false;
    return browser.storage.local
      .set({ guardEnabled: enabled })
      .then(async () => {
        guardEnabled = enabled;
        await notifyNativeGuardState();
        await refreshRules();
        return guardStatus();
      });
  }

  return false;
});

// Focusing an existing window need not emit tabs.onActivated.
browser.windows?.onFocusChanged?.addListener(async (windowId) => {
  if (windowId >= 0) recoverForegroundConnection();
  if (!rules.active || !Array.isArray(rules.selectedTabIDs) || windowId < 0) return;
  const tabs = await browser.tabs.query({});
  const active = tabs.find(tab => tab.windowId === windowId && tab.active);
  if (active && !isRuntimeAllowedTab(active)) await returnToAllowedTab();
});

browser.tabs.onActivated.addListener(async ({ tabId }) => {
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    await returnToAllowedTab();
    return;
  }
  const tab = await browser.tabs.get(tabId).catch(() => null);
  await recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active) {
    return;
  }
  if (!tab || !tab.url) {
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
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

// Selection, pinning and moves can change without navigation or activation.
browser.tabs.onHighlighted?.addListener(() => scheduleTabSnapshot());

browser.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  scheduleTabSnapshot();
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    if (tab.active) await returnToAllowedTab();
    return;
  }
  if (!changeInfo.url && changeInfo.status !== "complete") {
    return;
  }

  await recordWebsiteVisit(tab);
  scheduleTabSnapshot();
  if (!rules.active || !tab.url) {
    return;
  }

  if (isPendingStartupNavigation(tabId, tab.url)) {
    // Ignore Firefox's late completion for the replaced blank document. Also
    // permit a same-host shell redirect (for example Outlook's message URL to
    // /mail/) until the first real document completes. Subsequent navigation is
    // enforced normally.
    const pending = startupNavigationURLByTab.get(tabId);
    if (changeInfo.url && !isSearchStagingURL(tab.url)) {
      pending.lastNavigationURL = tab.url;
    }
    if (
      changeInfo.status === "complete" &&
      pending.lastNavigationURL &&
      sameNavigationURL(tab.url, pending.lastNavigationURL)
    ) {
      startupNavigationURLByTab.delete(tabId);
    }
    return;
  }

  if (startupNavigationURLByTab.has(tabId) && changeInfo.url) {
    startupNavigationURLByTab.delete(tabId);
  }

  if (
    !Array.isArray(rules.selectedTabIDs) &&
    freshBlankTabIds.has(tabId) &&
    !rules.allowGoogleSearchTabs &&
    changeInfo.url &&
    !isSearchStagingURL(changeInfo.url) &&
    !isAllowedURL(changeInfo.url, rules)
  ) {
    await recoverBlockedNavigation(tabId);
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
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
  if (tab.url === browser.runtime.getURL?.('parked.html')) return;
  committedURLByTab.set(tab.id, tab.url || "about:blank");
  if (rules.active && rules.allowGoogleSearchTabs && (!tab.url || isSearchStagingURL(tab.url) || IntentBrowserRules.isGoogleSearchURL(tab.url))) searchSessionTabs.add(tab.id);
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab(tab)) {
    await returnToAllowedTab();
    return;
  }
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

  if (isRuntimeAllowedTab(tab)) {
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
      if (rules.accessMode !== "blacklist" && !rules.hideDistractions) await browser.tabs.remove(latest.id);
    } catch (_) {
      await returnToAllowedTab();
    }
    await returnToAllowedTab();
    scheduleTabSnapshot();
  }, NEW_TAB_GRACE_MS);
  scheduleTabSnapshot();
});

for (const event of [browser.tabs.onMoved, browser.tabs.onAttached, browser.tabs.onDetached]) {
  event?.addListener(() => { if (rules.active) scheduleTabSnapshot(true); });
}

browser.tabs.onRemoved.addListener(async (tabId) => {
  searchSessionTabs.delete(tabId); committedURLByTab.delete(tabId);
  scheduleTabSnapshot();
  if (!rules.active) {
    return;
  }

  freshBlankTabIds.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
  startupNavigationURLByTab.delete(tabId);

  if (lastAllowedTabId === tabId) {
    lastAllowedTabId = null;
  }

  setTimeout(returnToAllowedTab, 0);
  scheduleTabSnapshot();
});

browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: details.tabId})) {
      setTimeout(returnToAllowedTab, 0);
      return { cancel: true };
    }
    if (rules.active && Array.isArray(rules.selectedTabIDs) && isRuntimeAllowedTab({id: details.tabId})) return {};
    if (isPendingStartupNavigation(details.tabId, details.url)) {
      startupNavigationURLByTab.get(details.tabId).lastNavigationURL = details.url;
      return {};
    }

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

// Browser-reported transitions distinguish address-bar input from ordinary links
// and SPA navigation; native input guards prevent address editing when Searches is off.
browser.webNavigation?.onCommitted?.addListener(async (details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: details.tabId})) return;
  const previous = committedURLByTab.get(details.tabId);
  const direct = ["typed", "generated", "keyword", "keyword_generated", "auto_bookmark"].includes(details.transitionType)
    || (details.transitionQualifiers || []).includes("from_address_bar");
  if (rules.active && Array.isArray(rules.selectedTabIDs) && direct
      && !(rules.allowGoogleSearchTabs && IntentBrowserRules.isGoogleSearchURL(details.url))) {
    if (previous && previous !== details.url) await browser.tabs.update(details.tabId, {url: previous}).catch(() => {});
    else await returnToAllowedTab();
    return;
  }
  committedURLByTab.set(details.tabId, details.url);
});
