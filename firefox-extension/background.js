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
const EXTENSION_CAPABILITIES = ["single-startup-launch-v1", "hide-distractions-v1", "add-as-you-go-v1", "website-features-v1", "firefox-window-minimize-bootstrap-v1"];
const browserSessionID = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
// A profile survives browser restarts; numeric tab IDs and browserSessionID do not.
let browserProfileID = null;
let browserProfilePromise = null;
function validBrowserProfileID(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
    && value !== "00000000-0000-0000-0000-000000000000";
}
async function ensureBrowserProfileIdentity() {
  if (browserProfileID) return browserProfileID;
  if (!browserProfilePromise) browserProfilePromise = (async () => {
    const stored = await browser.storage.local.get("intentBrowserProfileID");
    if (validBrowserProfileID(stored.intentBrowserProfileID)) {
      browserProfileID = stored.intentBrowserProfileID.toLowerCase();
      return browserProfileID;
    }
    const generated = globalThis.crypto?.randomUUID?.();
    if (!validBrowserProfileID(generated)) return null;
    // Never publish an unpersisted fallback identity after a storage failure.
    await browser.storage.local.set({ intentBrowserProfileID: generated });
    const saved = await browser.storage.local.get("intentBrowserProfileID");
    if (saved.intentBrowserProfileID !== generated) return null;
    browserProfileID = generated;
    return browserProfileID;
  })().catch(() => null).finally(() => { browserProfilePromise = null; });
  return browserProfilePromise;
}
let hostSupportsQuickSelection = false;
let hostSupportsTabPreview = false;
let hostSupportsTabCreation = false;
let hostSupportsNativeFinder = false;
let hostSupportsFinderObserve = false;
let creationRulesActive = true;
let hostSupportsNativeTabGroups = false;
let hostSupportsSessionIdentity = false;
let hostSupportsNativeVisibility = false;
function advertisedCapabilities() {
  const ready = [...EXTENSION_CAPABILITIES, ...(hostSupportsNativeFinder && hostSupportsFinderObserve && browser.storage.session && typeof browser.webNavigation?.getFrame === "function" ? ["native-website-finder-observe-v1"] : []), ...(hostSupportsNativeFinder && browser.storage.session && typeof IntentNativeFinder !== "undefined" ? ["native-website-finder-v1"] : []), ...(hostSupportsTabCreation && browser.storage.session && typeof IntentTabCreation !== "undefined" ? ["background-tab-create-v1"] : []), ...(hostSupportsNativeVisibility && browser.storage.session
    && nativeWindowVisibility?.identity() ? ["native-window-visibility-v1"] : [])];
  return hostSupportsQuickSelection && hostSupportsSessionIdentity && browserSessionID
    ? [...ready, "quick-selection-tabs-v1", "blacklist-selection-tabs-v1", ...(hostSupportsNativeTabGroups ? ["native-tab-groups-v1"] : []), ...(hostSupportsSessionIdentity && browserSessionID ? ["tab-session-identity-v1"] : []), ...(hostSupportsTabPreview ? ["tab-preview-v1"] : [])] : ready;
}

const {
  isAllowedURL,
  isSearchStagingURL
} = IntentBrowserRules;

const nativeWindowVisibility = typeof IntentNativeWindowVisibility !== "undefined"
  ? new IntentNativeWindowVisibility(browser, postCommandPort, () => browserSessionID) : null;
const tabVisibility = typeof IntentTabVisibility !== "undefined" ? new IntentTabVisibility(browser, true, nativeWindowVisibility) : null;
const minimizeBootstrap = typeof IntentFirefoxMinimizeBootstrap !== 'undefined'
  ? new IntentFirefoxMinimizeBootstrap(browser,{send:postCommandPort,identity:()=>nativeWindowVisibility?.identity(),
      validate:offer=>tabVisibility?.validateBootstrap(offer) ?? false}) : null;
let rules = inactiveRules();
const tabCreation = typeof IntentTabCreation !== "undefined" ? new IntentTabCreation(browser, {
  session: () => browserSessionID, active: () => creationRulesActive || rules.active,
  enabled: () => guardEnabled && hostSupportsTabCreation && nativeConnectionConfirmed && Boolean(commandPort), firefox: true, send: postCommandPort,
  snapshot: () => publishTabSnapshot(true, true)
}) : null;
let lastAllowedTabId = null;
let enforcing = false;
let rulesFingerprint = fingerprintRules(rules);
const nativeFinder = typeof IntentNativeFinder !== "undefined" ? new IntentNativeFinder(browser, {
  session: () => browserSessionID, active: () => creationRulesActive || rules.active,
  enabled: () => guardEnabled && hostSupportsNativeFinder && nativeConnectionConfirmed && Boolean(commandPort),
  firefox: true, send: postCommandPort, snapshot: () => publishTabSnapshot(true, true)
}) : null;
let guardEnabled = true;
let initialized = false;
let initializationPromise = null;
let freshBlankTabIds = new Set();
const lastAllowedURLByTab = new Map();
const searchSessionTabs = new Set();
let searchLedgerSession = null;
let searchLedgerWrites = Promise.resolve();
async function restoreSearchLedger(nextRules) {
  if (nextRules.startupSessionID === searchLedgerSession && nextRules.active) return;
  searchSessionTabs.clear(); freshBlankTabIds.clear();
  searchLedgerSession = nextRules.active ? nextRules.startupSessionID : null;
  if (searchLedgerSession && browser.storage.session) {
    const saved = (await browser.storage.session.get('intentSearchTabs').catch(() => ({}))).intentSearchTabs;
    if (saved?.session === searchLedgerSession && saved.browser === browserSessionID) {
      for (const id of saved.ids || []) if (Number.isInteger(id)) searchSessionTabs.add(id);
    }
  }
}
function saveSearchLedger() {
  if (!browser.storage.session) return Promise.resolve();
  const record = {session: searchLedgerSession, browser: browserSessionID, ids: [...searchSessionTabs]};
  searchLedgerWrites = searchLedgerWrites.then(() => browser.storage.session.set({intentSearchTabs: record})).catch(() => {});
  return searchLedgerWrites;
}
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
  if (initialized) return;
  if (!initializationPromise) initializationPromise = (async () => {
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

    await ensureBrowserProfileIdentity();
    initialized = true;
    connectCommandPort();
    await notifyNativeGuardState();
    browser.tabs.query({}).then((tabs) => tabs.forEach((tab) => recordWebsiteVisit(tab))).catch(() => {});
  })().finally(() => { initializationPromise = null; });
  return initializationPromise;
}

function connectCommandPort() {
  if (!initialized) { void ensureInitialized(); return; }
  if (commandPort || reconnectTimer !== null) return;
  if (typeof browser.runtime.connectNative !== "function") return;
  try {
    const port = browser.runtime.connectNative(HOST_NAME);
    commandPort = port;
    hostSupportsQuickSelection = false;
    nativeConnectionConfirmed = false;
    port.onMessage.addListener(async (message) => {
      if (commandPort !== port) return;
      const refreshResolver = resolvePendingRuleRefresh;
      const visibilityWasReady = Boolean(nativeWindowVisibility?.identity());
      nativeWindowVisibility?.receive(message);
      nativeConnectionConfirmed = true;
      creationRulesActive = message?.tabCreationAllowed !== true;
      hostSupportsTabCreation = message?.hostCapabilities?.includes("background-tab-create-host-v1") === true;
      hostSupportsNativeFinder = message?.hostCapabilities?.includes("native-website-finder-host-v1") === true;
      hostSupportsFinderObserve = message?.hostCapabilities?.includes("native-website-finder-observe-host-v1") === true;
      reconnectDelayMs = RECONNECT_MS;
      const supported = message?.hostCapabilities?.includes("quick-selection-host-v1") === true;
      const previewSupported = message?.hostCapabilities?.includes("tab-preview-host-v1") === true;
      const groupsSupported = message?.hostCapabilities?.includes("native-tab-groups-host-v1") === true;
      const identitySupported = message?.hostCapabilities?.includes("tab-session-identity-host-v1") === true;
      const visibilitySupported = message?.hostCapabilities?.includes("native-window-visibility-host-v1") === true;
      if (visibilityWasReady !== Boolean(nativeWindowVisibility?.identity()) || visibilitySupported !== hostSupportsNativeVisibility || identitySupported !== hostSupportsSessionIdentity || supported !== hostSupportsQuickSelection || previewSupported !== hostSupportsTabPreview || groupsSupported !== hostSupportsNativeTabGroups) {
        hostSupportsNativeVisibility = visibilitySupported;
        hostSupportsQuickSelection = supported;
        hostSupportsTabPreview = previewSupported;
        hostSupportsNativeTabGroups = groupsSupported;
        hostSupportsSessionIdentity = identitySupported;
        sendHeartbeat();
      }
      const desired = effectiveRules(message);
      minimizeBootstrap?.receive(message,{rules:desired,fingerprint:fingerprintRules(desired)});
      // Register this rule revision in arrival order. A slow snapshot/preview
      // from an older message must not reapply stale rules after Start or Finish.
      const application = applyNativeRules(message).catch(() => {});
      const applicationRevision = ruleApplicationRevision;
      if (message?.finderCommand) void nativeFinder?.handle(message.finderCommand);
      if (message?.tabCommand) await handleRequestedTab(message.tabCommand).catch(() => {});
      await application;
      if (commandPort === port && ruleApplicationRevision === applicationRevision
          && refreshResolver && resolvePendingRuleRefresh === refreshResolver) settlePendingRuleRefresh();
    });
    port.onDisconnect.addListener(() => {
      if (commandPort !== port) return;
      commandPort = null;
      nativeWindowVisibility?.disconnected();
      minimizeBootstrap?.disconnected();
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
      browserSessionID,
      ...(browserProfileID ? { browserProfileID } : {}),
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
      browserSessionID,
      ...(browserProfileID ? { browserProfileID } : {}),
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
  if (message.action === "create" || message.action === "cancelCreate") {
    await tabCreation?.handle(message); return;
  }
  // Discovery is how Intent learns the current browser lifetime in the first place.
  if (message.action === "snapshot") {
    await publishTabSnapshot(true, true, message.id);
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

async function publishTabSnapshot(force = false, discovery = false, requestID = null) {
  await ensureInitialized();
  if (!await ensureBrowserProfileIdentity()) return;
  if (!commandPort) connectCommandPort();
  if (!commandPort) return;
  // The receipt belongs only to this request's own query. Never lend a later
  // request ID to an ordinary or already in-flight inventory.
  const snapshotRequestIDs = discovery && typeof requestID === "string" && requestID.length > 0 && requestID.length <= 256
    ? [requestID] : [];
  const tabs = rules.active || discovery ? await browser.tabs.query({}).catch(() => null) : [];
  if (!Array.isArray(tabs)) return;
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
        cookieStoreID: typeof tab.cookieStoreId === "string" ? tab.cookieStoreId : null,
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
  if (postCommandPort({ type: "tabsSnapshot", browserSessionID, tabs: snapshotTabs, allTabs: allSnapshotTabs, snapshotRequestIDs })) {
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
      browserSessionID,
      ...(browserProfileID ? { browserProfileID } : {}),
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
  const openEnded = nativeRules.addAsYouGo === true && nativeRules.accessMode !== "blacklist";
  return {
    ...inactiveRules(),
    addAsYouGo: openEnded,
    active: true,
    websiteFeaturePolicies: nativeRules.websiteFeaturePolicies || {},
    hideDistractions: Boolean(nativeRules.hideDistractions),
    nativeWindowVisibility: Boolean(nativeWindowVisibility && hostSupportsNativeVisibility && nativeRules.nativeWindowVisibility),
    accessMode: nativeRules.accessMode === "blacklist" ? "blacklist" : "whitelist",
    allowedWebsites: Array.isArray(nativeRules.allowedWebsites) ? nativeRules.allowedWebsites : [],
    startupWebsites: Array.isArray(nativeRules.startupWebsites) ? nativeRules.startupWebsites : [],
    startupSessionID: typeof nativeRules.startupSessionID === "string" ? nativeRules.startupSessionID : null,
    selectedTabIDs: Array.isArray(nativeRules.selectedTabIDs) ? nativeRules.selectedTabIDs.filter(Number.isInteger) : null,
    blockTabSwitching: !openEnded && Boolean(nativeRules.blockTabSwitching),
    blockNavigation: !openEnded && Boolean(nativeRules.blockNavigation),
    blockNewTabs: !openEnded && Boolean(nativeRules.blockNewTabs),
    allowGoogleSearchTabs: !openEnded && Boolean(nativeRules.allowGoogleSearchTabs)
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
      browserSessionID,
      ...(browserProfileID ? { browserProfileID } : {}),
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

async function sendHeartbeat() {
  if (!initialized) await ensureInitialized();
  if (!browserProfileID) await ensureBrowserProfileIdentity();
  syncTabVisibility();
  if (rules.active && Array.isArray(rules.selectedTabIDs)) {
    browser.tabs.query({ active: true, lastFocusedWindow: true }).then(tabs => {
      if (tabs.some(tab => tab.active && !isRuntimeAllowedTab(tab))) returnToAllowedTab();
    }).catch(() => {});
  }
  if (!commandPort) connectCommandPort();
  postCommandPort({ type: "heartbeat" });
}

let ruleApplication = Promise.resolve();
let requestedRulesFingerprint = null;
let ruleApplicationRevision = 0;
const websitePlayback = new IntentWebsitePlayback({api:browser,getRules:()=>rules,isAllowedTab:isRuntimeAllowedTab});
function applyNativeRules(nativeRules) {
  const nextRules = effectiveRules(nativeRules);
  const requestedFingerprint = fingerprintRules(nextRules);
  if (requestedFingerprint === requestedRulesFingerprint) return ruleApplication;
  requestedRulesFingerprint = requestedFingerprint;
  const revision = ++ruleApplicationRevision;
  websitePlayback.clear();
  // Stop enforcement before restoring tabs: restoration emits ordinary tab
  // events, which must not activate anything using the old session's policy.
  if (!nextRules.active) rules = nextRules;
  const apply = async () => {
    if (revision !== ruleApplicationRevision) return;
    await applyEffectiveRules(nextRules, revision);
  };
  ruleApplication = ruleApplication.then(apply, apply).catch(error => {
    if (revision === ruleApplicationRevision) {
      requestedRulesFingerprint = null;
      rulesFingerprint = "";
    }
    throw error;
  });
  return ruleApplication;
}
async function applyEffectiveRules(nextRules, revision) {
  const previousFingerprint = rulesFingerprint;
  rules = nextRules;
  if (!nextRules.active) await tabVisibility?.sync(nextRules, () => true);
  if (revision !== ruleApplicationRevision) return;
  await restoreSearchLedger(nextRules);
  if (revision !== ruleApplicationRevision) return;

  const nextFingerprint = fingerprintRules(rules);
  if (nextFingerprint === previousFingerprint) {
    return;
  }
  rulesFingerprint = nextFingerprint;
  if (rules.active && Object.keys(rules.websiteFeaturePolicies || {}).length) {
    try { await installWebsiteGuards(); } catch (error) { rulesFingerprint = ""; throw error; }
  }

  browser.tabs.query({}).then(tabs => {
    for (const tab of tabs) browser.tabs.sendMessage(tab.id, {type: "rulesUpdated", rules}).catch(() => {});
  }).catch(() => {});

  if (revision !== ruleApplicationRevision) return;
  if (rules.active) {
    await removeAlreadyBlockedTabs();
    if (revision !== ruleApplicationRevision) return;
    await synchronizeStartupTabs();
    if (revision !== ruleApplicationRevision) return;
    await primeAllowedTab();
    if (revision !== ruleApplicationRevision) return;
    for (const tab of await browser.tabs.query({})) if (!committedURLByTab.has(tab.id) && tab.url) committedURLByTab.set(tab.id, tab.url);
    if (Array.isArray(rules.selectedTabIDs)) await returnToAllowedTab();
  } else {
    lastAllowedTabId = null;
    freshBlankTabIds.clear();
    lastAllowedURLByTab.clear();
    searchSessionTabs.clear(); await saveSearchLedger(); committedURLByTab.clear();
    startupNavigationURLByTab.clear();
    completedStartupFingerprint = null;
  }
  if (revision !== ruleApplicationRevision) return;
  await syncTabVisibility();
  if (revision !== ruleApplicationRevision) return;
  scheduleTabSnapshot(true);
}

function syncTabVisibility() {
  // The visibility ledger owns completion, so a failed native receipt retries
  // the original inventory instead of allowing setup to be skipped on heartbeat.
  const current = rules;
  if (current.active && current.addAsYouGo
      && (Array.isArray(current.selectedTabIDs) || current.startupWebsites.length > 0)) {
    return tabVisibility?.syncInitial(current, tab => Array.isArray(current.selectedTabIDs)
      ? current.selectedTabIDs.includes(tab.id)
      : isAllowedURL(tab.url, {...current, addAsYouGo: false}), isRuntimeAllowedTab);
  }
  return tabVisibility?.sync(current, isRuntimeAllowedTab);
}

async function removeAlreadyBlockedTabs() {
  // Blacklisting preserves every tab; native blur and activation guards block access.
}

async function installWebsiteGuards() {
  const current = rules, revision = ruleApplicationRevision;
  if (!current.active || !Object.keys(current.websiteFeaturePolicies || {}).length) return;
  const key = IntentWebsiteFeatures.policyKey(current);
  const stillCurrent = () => revision === ruleApplicationRevision && rules === current;
  for (const tab of await browser.tabs.query({})) {
    if (!stillCurrent()) return;
    if (!isRuntimeAllowedTab(tab) || !current.websiteFeaturePolicies[IntentWebsiteFeatures.siteOf(tab.url)]) continue;
    const requestID = `${browserSessionID}:${revision}:${tab.id}`;
    const message = {type:"rulesUpdated", rules:current, websiteRequestID:requestID};
    const accepted = receipt => receipt?.websiteFeatures === true && receipt.websiteRequestID === requestID
      && receipt.websitePolicyKey === key && receipt.startupSessionID === current.startupSessionID;
    let receipt = await browser.tabs.sendMessage(tab.id, message).catch(() => null);
    if (!stillCurrent()) return;
    if (!accepted(receipt)) {
      await browser.tabs.executeScript(tab.id, {file: "website-features.js", runAt: "document_start"});
      await browser.tabs.executeScript(tab.id, {file: "site-feature-guard.js", runAt: "document_start"});
      if (!stillCurrent()) return;
      receipt = await browser.tabs.sendMessage(tab.id, message);
    }
    if (!stillCurrent()) return;
    if (!accepted(receipt)) throw new Error("Website controls did not acknowledge the current policy");
  }
  if (stillCurrent()) postCommandPort({type: "websitePolicyReady", browserSessionID, appliedWebsitePolicySessionID: current.startupSessionID});
}

function websiteFeatureDestination(url, tabId, current = rules) {
  if (!current.active || !Number.isInteger(tabId) || tabId < 0) return null;
  const destination = IntentWebsiteFeatures.preferredDestination(url, current.websiteFeaturePolicies);
  if (!destination || !isRuntimeAllowedTab({id:tabId,url})) return null;
  const exactAllowedTab = current.accessMode !== "blacklist" && Array.isArray(current.selectedTabIDs)
    && current.selectedTabIDs.includes(tabId);
  if (!exactAllowedTab && (!isAllowedURL(url,current) || !isAllowedURL(destination,current))) return null;
  return destination;
}

async function routeWebsiteFeature(message, sender) {
  const current = rules, revision = ruleApplicationRevision;
  if (!current.active || sender?.frameId > 0 || !Number.isInteger(sender?.tab?.id)
      || message.websitePolicyKey !== IntentWebsiteFeatures.policyKey(current)) return {routed:false};
  const tab = await browser.tabs.get(sender.tab.id).catch(() => null);
  if (revision !== ruleApplicationRevision || rules !== current || !tab || !isRuntimeAllowedTab(tab)) return {routed:false};
  if (tab.url !== message.url) return {routed:false,retry:true};
  const destination = websiteFeatureDestination(tab.url, tab.id, current);
  if (!destination) return {routed:false};
  await browser.tabs.update(tab.id, {url:destination});
  return {routed:true};
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

// Our holding page is infrastructure, never a user-created search tab.
// Browsers can emit onCreated as about:blank before its extension URL loads.
function isHoldingPage(url) {
  const base = browser.runtime.getURL?.('parked.html');
  return Boolean(typeof url === 'string' && base && (url === base
    || (url.startsWith(base) && /^#intent-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(url.slice(base.length)))));
}
function forgetHoldingSearch(tabId) {
  if (searchSessionTabs.delete(tabId)) saveSearchLedger();
  freshBlankTabIds.delete(tabId);
  committedURLByTab.delete(tabId);
  lastAllowedURLByTab.delete(tabId);
}

function searchOnlyNavigation(tabId, url) {
  if (isHoldingPage(url)) { forgetHoldingSearch(tabId); return false; }
  if (!rules.active || !rules.allowGoogleSearchTabs || rules.accessMode === "blacklist") return false;
  if (IntentBrowserRules.isGoogleSearchURL(url) && rules.selectedTabIDs?.includes(tabId)) {
    searchSessionTabs.add(tabId); saveSearchLedger();
  }
  return searchSessionTabs.has(tabId) && !IntentBrowserRules.isSearchStagingURL(url) && !IntentBrowserRules.isGoogleSearchURL(url);
}
async function restoreSearchPage(tabId) {
  const candidates = [lastAllowedURLByTab.get(tabId), committedURLByTab.get(tabId)];
  const previous = candidates.find(url => url && IntentBrowserRules.isGoogleSearchURL(url)) || candidates.find(url => url && isSearchStagingURL(url));
  const url = previous && (IntentBrowserRules.isGoogleSearchURL(previous) || isSearchStagingURL(previous)) ? previous : 'https://www.google.com/';
  await browser.tabs.update(tabId, {url}).catch(() => {});
}

function isRuntimeAllowedTab(tab) {
  if (rules.active && rules.addAsYouGo && rules.accessMode !== "blacklist") return true;
  if (rules.active && rules.allowGoogleSearchTabs && searchSessionTabs.has(tab?.id) && tab?.url
      && !isSearchStagingURL(tab.url) && !IntentBrowserRules.isGoogleSearchURL(tab.url)) return false;
  if (rules.active && rules.allowGoogleSearchTabs && searchSessionTabs.has(tab?.id)) return true;
  // Explicit selections remain independent; search-created tabs are search-only.
  if (rules.active && Array.isArray(rules.selectedTabIDs)) return rules.accessMode === "blacklist" ? !rules.selectedTabIDs.includes(tab?.id) : (rules.selectedTabIDs.includes(tab?.id) || (rules.allowGoogleSearchTabs && searchSessionTabs.has(tab?.id)));
  return Boolean(
    tab?.url &&
    (isAllowedURL(tab.url, {...rules, allowGoogleSearchTabs: false}) || isFreshBlankTab(tab))
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
  const current = rules, revision = ruleApplicationRevision;
  const stillCurrent = () => rules === current && current.active && revision === ruleApplicationRevision;
  const startupFingerprint = JSON.stringify(current.startupWebsites);
  if (
    synchronizingStartupTabs ||
    !startupLaunchPending()
  ) return;

  synchronizingStartupTabs = true;
  try {
    const tabs = await browser.tabs.query({});
    if (!stillCurrent() || tabs.length === 0) return;

    completedStartupFingerprint = startupFingerprint;
    if (current.startupSessionID) {
      completedStartupSessionID = current.startupSessionID;
      await browser.storage.local.set({ completedStartupSessionID }).catch(() => {});
      if (!stillCurrent()) return;
    }

    const claimedTabIds = new Set();
    let stagingTabs = tabs.filter((tab) => isSearchStagingURL(tab.url));
    let firstStartupTab = null;

    for (const startupURL of uniqueStartupURLs(current.startupWebsites)) {
      if (!stillCurrent()) return;
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
          if (!stillCurrent()) return;
          beginStartupNavigation(tab.id, startupURL);
          tab = await browser.tabs.update(tab.id, { url: startupURL, active: false });
        }
      }
      if (!stillCurrent()) return;
      claimedTabIds.add(tab.id);
      freshBlankTabIds.delete(tab.id);
      firstStartupTab ||= tab;
    }

    if (stillCurrent() && firstStartupTab) {
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
    if (tab.active) lastAllowedTabId = tabId;
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
    const generation = rules.startupSessionID;
    const activation = activationRevision;
    const focus = windowFocusRevision;
    const current = (await browser.tabs.query({active: true, lastFocusedWindow: true})).find(tab => tab.active && isRuntimeAllowedTab(tab));
    if (!rules.active || rules.startupSessionID !== generation || focus !== windowFocusRevision || activation !== activationRevision) return;
    if (current) { lastAllowedTabId = current.id; return; }

    if (lastAllowedTabId !== null) {
      const lastAllowed = await getAllowedTab(lastAllowedTabId);
      if (lastAllowed) {
        if (!rules.active || rules.startupSessionID !== generation || focus !== windowFocusRevision || activation !== activationRevision) return;
        await browser.tabs.update(lastAllowed.id, { active: true });
        // Accept our own activation event, but not a newer click on another tab.
        if (!rules.active || rules.startupSessionID !== generation || focus !== windowFocusRevision ||
            (activation !== activationRevision && lastActivatedTabId !== lastAllowed.id)) return;
        if (Array.isArray(rules.selectedTabIDs) && lastAllowed.windowId != null) {
          await browser.windows?.update(lastAllowed.windowId, { focused: true }).catch(() => {});
        }
        return;
      }
      lastAllowedTabId = null;
    }

    const tabs = await browser.tabs.query({});
    if (!rules.active || rules.startupSessionID !== generation || focus !== windowFocusRevision || activation !== activationRevision) return;
    const allowed = tabs.find((tab) => isRuntimeAllowedTab(tab));
    if (allowed) {
      lastAllowedTabId = allowed.id;
      await browser.tabs.update(allowed.id, { active: true });
      // Accept our own activation event, but not a newer click on another tab.
      if (!rules.active || rules.startupSessionID !== generation || focus !== windowFocusRevision ||
          (activation !== activationRevision && lastActivatedTabId !== allowed.id)) return;
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

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.type === "rememberWebsitePlaybackIntent") return websitePlayback.remember(message,sender);
  if (message?.type === "consumeWebsitePlaybackIntent") return websitePlayback.consume(message,sender);
  if (message?.type === "routeWebsiteFeature") return routeWebsiteFeature(message, sender);
  if (message?.type === "getActiveRules") return Promise.resolve(rules);
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
let windowFocusRevision = 0;
browser.windows?.onFocusChanged?.addListener(async (windowId) => {
  // Losing browser focus need not activate another tab. Invalidate pending recovery.
  ++windowFocusRevision;
  minimizeBootstrap?.invalidateWindow(windowId);
  if (windowId >= 0) recoverForegroundConnection();
  if (!rules.active || !Array.isArray(rules.selectedTabIDs) || windowId < 0) return;
  const tabs = await browser.tabs.query({active: true, windowId});
  const active = tabs.find(tab => tab.windowId === windowId && tab.active);
  if (active && !isRuntimeAllowedTab(active)) await returnToAllowedTab();
});

let activationRevision = 0;
let lastActivatedTabId = null;
browser.tabs.onActivated.addListener(async ({ tabId }) => {
  lastActivatedTabId = tabId;
  const activation = ++activationRevision;
  if (rules.active && Array.isArray(rules.selectedTabIDs) && isRuntimeAllowedTab({id: tabId})) lastAllowedTabId = tabId;
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: tabId})) {
    await returnToAllowedTab();
    return;
  }
  const tab = await browser.tabs.get(tabId).catch(() => null);
  if (activation !== activationRevision) return;
  // Recording history is housekeeping, never part of the tab-switch critical path.
  void recordWebsiteVisit(tab);
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
  if (typeof changeInfo.url === 'string') minimizeBootstrap?.invalidateWindow(tab?.windowId);
  if (isHoldingPage(changeInfo.url || tab.url)) { forgetHoldingSearch(tabId); return; }
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
    return;
  }

  if (isFreshBlankTab(tab)) {
    return;
  }

  if (rules.blockNavigation) {
    await recoverBlockedNavigation(tabId);
  }
  scheduleTabSnapshot();
});

browser.tabs.onCreated.addListener(async (tab) => {
  websitePlayback.created(tab);
  minimizeBootstrap?.invalidateWindow(tab?.windowId);
  if (isHoldingPage(tab.url)) return;
  committedURLByTab.set(tab.id, tab.url || "about:blank");
  if (rules.active && rules.allowGoogleSearchTabs && rules.accessMode !== "blacklist" && (!tab.url || isSearchStagingURL(tab.url) || IntentBrowserRules.isGoogleSearchURL(tab.url))) {
    searchSessionTabs.add(tab.id);
    await saveSearchLedger();
  }
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
    if (tab.active) lastAllowedTabId = tab.id;
    return;
  }

  if (isRuntimeAllowedTab(tab)) {
    lastAllowedURLByTab.set(tab.id, tab.url);
    if (tab.active) lastAllowedTabId = tab.id;
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
  event?.addListener((_id,info) => { minimizeBootstrap?.invalidateWindow(info?.windowId ?? info?.oldWindowId ?? info?.newWindowId); if (rules.active) scheduleTabSnapshot(true); });
}

browser.tabs.onRemoved.addListener(async (tabId,info) => {
  websitePlayback.forget(tabId);
  minimizeBootstrap?.invalidateWindow(info?.windowId);
  searchSessionTabs.delete(tabId); saveSearchLedger(); committedURLByTab.delete(tabId);
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
    if (isHoldingPage(details.url)) { forgetHoldingSearch(details.tabId); return {}; }
    if (rules.active && !IntentWebsiteFeatures.permits(details.url, rules.websiteFeaturePolicies)) {
      const destination = websiteFeatureDestination(details.url, details.tabId);
      return destination ? {redirectUrl:destination} : {cancel:true};
    }
    if (searchOnlyNavigation(details.tabId, details.url)) {
      setTimeout(() => restoreSearchPage(details.tabId), 0); return { cancel: true };
    }
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

// SPA route changes do not create main-frame network requests. Wake the page
// guard immediately; its DOM observer also handles dynamically inserted UI.
browser.webNavigation?.onHistoryStateUpdated?.addListener(details => {
  if (details.frameId !== 0 || !rules.active || !Object.keys(rules.websiteFeaturePolicies || {}).length) return;
  browser.tabs.sendMessage(details.tabId, {type: "rulesUpdated", rules}).catch(() => {});
});

// Browser-reported transitions distinguish address-bar input from ordinary links
// and SPA navigation; native input guards prevent address editing when Searches is off.
browser.webNavigation?.onCommitted?.addListener(async (details) => {
  if (details.frameId !== 0 || details.tabId < 0) return;
  if (isHoldingPage(details.url)) { forgetHoldingSearch(details.tabId); return; }
  if (searchOnlyNavigation(details.tabId, details.url)) { await restoreSearchPage(details.tabId); return; }
  if (rules.active && Array.isArray(rules.selectedTabIDs) && !isRuntimeAllowedTab({id: details.tabId})) return;
  const previous = committedURLByTab.get(details.tabId);
  const direct = ["typed", "generated", "keyword", "keyword_generated", "auto_bookmark"].includes(details.transitionType)
    || (details.transitionQualifiers || []).includes("from_address_bar");
  // Exact selections only restrict direct navigation in a fixed whitelist.
  // Blacklists and Add as you go allow navigation in every permitted tab.
  if (rules.active && rules.accessMode === "whitelist" && !rules.addAsYouGo
      && Array.isArray(rules.selectedTabIDs) && direct
      && !(rules.allowGoogleSearchTabs && IntentBrowserRules.isGoogleSearchURL(details.url))) {
    if (previous && previous !== details.url) await browser.tabs.update(details.tabId, {url: previous}).catch(() => {});
    else await returnToAllowedTab();
    return;
  }
  committedURLByTab.set(details.tabId, details.url);
  websitePlayback.committed(details);
});

browser.webNavigation?.onBeforeNavigate?.addListener(details => websitePlayback.beforeNavigate(details));
