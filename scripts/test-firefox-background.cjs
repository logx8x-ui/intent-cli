const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const helpers = require("../firefox-extension/rule-helpers.js");
const backgroundSource = fs.readFileSync(
  path.join(__dirname, "../firefox-extension/background.js"),
  "utf8"
);

function createHarness(activeRules, initialTabs, options = {}) {
  const tabs = new Map(initialTabs.map((tab) => [tab.id, { ...tab }]));
  const listeners = {
    onCommitted: [],
    onActivated: [],
    onUpdated: [],
    onCreated: [],
    onRemoved: [],
    onBeforeRequest: [],
    onMessage: [],
    onWindowFocus: []
  };
  const updates = [];
  const focusedWindows = [];
  const reloads = [];
  const removals = [];
  const nativeMessages = [];
  const websiteMessages = [];
  const profileWrites = [];
  const nativeReceivers = [];
  const nativePorts = [];
  let nativeHostAvailable = options.hostAvailable !== false;
  let nativeConnectAttempts = 0;
  const timeouts = new Map();
  let timeoutSerial = 0;
  const sessionStorage = { ...(options.sessionStorage || {}) };
  const intervals = [];
  const storage = {
    guardEnabled: options.guardEnabled !== false,
    ...(options.storage || {})
  };

  function setActiveTab(tabId) {
    for (const tab of tabs.values()) {
      tab.active = tab.id === tabId;
    }
  }

  const browser = {
    runtime: {
      getURL: path => 'extension://intent/' + path,
      getManifest: () => require("../firefox-extension/manifest.json"),
      onMessage: { addListener: (listener) => listeners.onMessage.push(listener) },
      sendNativeMessage: async (_hostName, message) => {
        nativeMessages.push(message);
        return activeRules;
      }
    },
    storage: {
      local: {
        get: async (defaults) => {
          if (defaults === "intentBrowserProfileID") {
            await options.beforeProfileRead?.();
            if (options.failProfileRead) throw new Error("profile storage unavailable");
          }
          return { ...(typeof defaults === "object" ? defaults : {}), ...storage };
        },
        set: async (values) => {
          if (Object.hasOwn(values, "intentBrowserProfileID")) {
            profileWrites.push(values.intentBrowserProfileID);
            await options.beforeProfileWrite?.();
            if (options.failProfileWrite) throw new Error("profile storage unavailable");
            if (options.dropProfileWrite) return;
          }
          Object.assign(storage, values);
        }
      }
    },
    tabs: {
      executeScript: async () => { options.onWebsiteInject?.(); },
      sendMessage: async (id, message) => {
        websiteMessages.push({id,message});
        return options.websiteReceipt ? options.websiteReceipt(id,message)
          : options.rejectWebsiteGuard ? {} : ({websiteFeatures:true, websiteRequestID:message.websiteRequestID,
            websitePolicyKey:require("../firefox-extension/website-features.js").policyKey(message.rules),
            startupSessionID:message.rules?.startupSessionID || null});
      },
      onActivated: { addListener: (listener) => listeners.onActivated.push(listener) },
      onUpdated: { addListener: (listener) => listeners.onUpdated.push(listener) },
      onCreated: { addListener: (listener) => listeners.onCreated.push(listener) },
      onRemoved: { addListener: (listener) => listeners.onRemoved.push(listener) },
      get: async (tabId) => {
        if (!tabs.has(tabId)) throw new Error("missing tab");
        const result = { ...tabs.get(tabId) };
        await options.afterTabGet?.(result);
        return result;
      },
      query: async () => {
        if (options.failTabQuery) throw new Error("tabs unavailable");
        const result = Array.from(tabs.values()).map((tab) => ({ ...tab }));
        await options.afterTabQuery?.(result);
        return result;
      },
      update: async (tabId, patch) => {
        const tab = tabs.get(tabId);
        if (!tab) {
          throw new Error("missing tab");
        }
        if (patch.active === false && tab.active && tabs.size === 1) {
          throw new Error("cannot deactivate the only tab");
        }
        Object.assign(tab, patch);
        if (patch.active) {
          setActiveTab(tabId);
        }
        updates.push({ tabId, patch });
        if (options.emitActivationOnUpdate && patch.active) { for (const listener of listeners.onActivated) void listener({tabId}); }
        await options.afterTabUpdate?.(patch);
        return { ...tab };
      },
      reload: async (tabId) => {
        if (!tabs.has(tabId)) throw new Error("missing tab");
        reloads.push(tabId);
      },
      remove: async (tabId) => {
        removals.push(tabId);
        tabs.delete(tabId);
        for (const listener of listeners.onRemoved) {
          await listener(tabId);
        }
      },
      create: async (createProperties = {}) => {
        const id = createProperties.id ?? Math.max(0, ...tabs.keys()) + 1;
        const tab = {
          id,
          active: createProperties.active === true,
          url: createProperties.url ?? "about:blank"
        };
        tabs.set(id, tab);
        if (tab.active) {
          setActiveTab(id);
        }
        for (const listener of listeners.onCreated) {
          await listener({ ...tab });
        }
        return { ...tab };
      }
    },
    windows: {
      getAll: async (query) => {
        const windows = [...new Set(Array.from(tabs.values(), tab => tab.windowId).filter(Number.isInteger))].map(id => ({ id, type:"normal", left: id * 20, top: 50, width: 900, height: 700, focused: id === 1,
          ...(query.populate ? {tabs:Array.from(tabs.values()).filter(tab => tab.windowId === id).map(tab => ({...tab}))} : {})}));
        return options.onWindowQuery ? options.onWindowQuery(query, windows) : windows;
      },
      onFocusChanged: { addListener: listener => listeners.onWindowFocus.push(listener) },
      update: async (id, patch) => { focusedWindows.push(id); return { id, ...patch }; }
    },
    webNavigation: { onCommitted: { addListener: listener => listeners.onCommitted.push(listener) } },
    webRequest: {
      onBeforeRequest: {
        addListener: (listener) => listeners.onBeforeRequest.push(listener)
      }
    }
  };

  if (options.nativeVisibility) {
    browser.storage.session = {get: async () => ({...sessionStorage}), set: async value => Object.assign(sessionStorage, value)};
  }
  if (options.withCommandPort) {
    browser.runtime.connectNative = () => {
      nativeConnectAttempts++;
      if (!nativeHostAvailable) throw new Error("native host unavailable");
      const messages = [], disconnects = [];
      const port = {
        messages, disconnects,
        onMessage: { addListener(listener) { messages.push(listener); nativeReceivers.push(listener); } },
        onDisconnect: { addListener: listener => disconnects.push(listener) },
        postMessage(message) {
          if (!nativeHostAvailable) throw new Error("native host unavailable");
          nativeMessages.push(message);
          // Real native host suppresses unchanged state pushes for snapshots and
          // heartbeats. Do not let automatic fixture replies repair stale rules.
          if (options.requestOnlyNativeReplies && !["getRules","setGuardEnabled"].includes(message.type)) return;
          const response = message.type === "windowVisibilityPlan"
            ? {...activeRules, visibilityPlanReceipt: {revision: message.visibilityPlan.revision, accepted: true}} : null;
          Promise.resolve().then(() => messages.forEach(listener => listener(response || activeRules)));
        }
      };
      nativePorts.push(port);
      return port;
    };
  }
  const context = {
    crypto: options.crypto === undefined ? require("node:crypto").webcrypto : options.crypto,
    browser,
    IntentFirefoxMinimizeBootstrap: options.bootstrapObserver ? class {
      receive(message,context) { options.bootstrapObserver(message,context); }
      disconnected() {}
      invalidateWindow() {}
    } : undefined,
    IntentNativeWindowVisibility: options.nativeVisibility ? require("../firefox-extension/native-window-visibility.js") : undefined,
    IntentTabVisibility: options.onVisibilitySync ? class {
      constructor(_api, _firefox, owner) { this.owner = owner; }
      sync(rules) { return options.onVisibilitySync(rules, this.owner, "sync"); }
      syncInitial(rules) { return options.onVisibilitySync(rules, this.owner, "initial"); }
    } : undefined,
    IntentBrowserRules: helpers,
    IntentWebsiteFeatures: require("../firefox-extension/website-features.js"),
    IntentWebsitePlayback: null,
    URL,
    setInterval: (callback, delay) => {
      intervals.push({ callback, delay });
      return intervals.length;
    },
    setTimeout: (fn, delay = 0) => {
      const id = ++timeoutSerial;
      timeouts.set(id, { fn, delay });
      if (!(options.controlReconnectTimers && delay >= 1000)) {
        Promise.resolve().then(() => {
          if (!timeouts.has(id)) return;
          timeouts.delete(id); fn();
        });
      }
      return id;
    },
    clearTimeout: id => timeouts.delete(id)
  };

  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../firefox-extension/website-playback-intent.js"),"utf8"), context);
  vm.runInNewContext(backgroundSource, context, { filename: "firefox-extension/background.js" });
  if (Array.isArray(activeRules.selectedTabIDs) && activeRules.selectedBrowserSessionID === undefined) {
    activeRules = { ...activeRules, selectedBrowserSessionID: vm.runInNewContext("browserSessionID", context) };
  }

  return {
    tabs,
    setNativeRules(next) {
      if (Array.isArray(next.selectedTabIDs) && next.selectedBrowserSessionID === undefined) {
        next = {...next, selectedBrowserSessionID: vm.runInNewContext("browserSessionID", context)};
      }
      activeRules = next;
      return next;
    },
    async applyRules(next) {
      if (Array.isArray(next.selectedTabIDs) && next.selectedBrowserSessionID === undefined) {
        next = {...next, selectedBrowserSessionID: vm.runInNewContext("browserSessionID", context)};
      }
      activeRules = next;
      await context.applyNativeRules(next);
    },
    effectiveRules: context.effectiveRules,
    routeWebsiteFeature: context.routeWebsiteFeature,
    allowedTabIDs: () => [...tabs.values()].filter(context.isRuntimeAllowedTab).map(tab => tab.id),
    browserSessionID: () => vm.runInNewContext("browserSessionID", context),
    browserProfileID: () => vm.runInNewContext("browserProfileID", context),
    profileWrites,
    setHostAvailable(value) { nativeHostAvailable = value; },
    nativeConnectAttempts: () => nativeConnectAttempts,
    nativePorts,
    disconnectPort(index = nativePorts.length - 1) {
      for (const listener of nativePorts[index].disconnects) listener();
    },
    reconnectTimers: () => [...timeouts.entries()].filter(([_id, timer]) => timer.delay >= 1000),
    async runReconnectTimer() {
      const next = [...timeouts.entries()].find(([_id, timer]) => timer.delay >= 1000);
      assert(next, "Expected a scheduled reconnect timer");
      timeouts.delete(next[0]); next[1].fn();
      for (let i = 0; i < 8; i++) await new Promise(setImmediate);
    },
    activeRules: () => vm.runInNewContext("rules", context),
    nativeWindowOwner: () => vm.runInNewContext("nativeWindowVisibility", context),
    sessionStorage,
    async heartbeat() { await context.sendHeartbeat(); },
    async command(message) {
      await context.handleRequestedTab(message);
      for (let i = 0; i < 48; i++) await Promise.resolve();
    },
    async snapshot() {
      await context.publishTabSnapshot(true, true);
      for (let i = 0; i < 32; i++) await Promise.resolve();
      return nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1);
    },
    listeners,
    updates,
    focusedWindows,
    async focusWindow(id) {
      for (const listener of listeners.onWindowFocus) await listener(id);
    },
    reloads,
    removals,
    nativeMessages,
    websiteMessages,
    intervals,
    storage,
    async message(message, sender = {}) {
      let response;
      for (const listener of listeners.onMessage) {
        response = await listener(message, sender);
      }
      await Promise.resolve();
      return response;
    },
    async ready() {
      await context.refreshRules();
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async refresh() {
      await context.refreshRules();
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async synchronizeStartupTabsConcurrently() {
      await Promise.all([
        context.synchronizeStartupTabs(),
        context.synchronizeStartupTabs()
      ]);
      await Promise.resolve();
    },
    async commit(id, url, transitionType) {
      tabs.get(id).url = url;
      for (const listener of listeners.onCommitted) await listener({tabId: id, frameId: 0, url, transitionType});
    },
    async activate(tabId) {
      setActiveTab(tabId);
      for (const listener of listeners.onActivated) {
        await listener({ tabId });
      }
      await Promise.resolve();
    },
    async update(tabId, changeInfo) {
      const tab = tabs.get(tabId);
      if (tab && changeInfo.url) {
        for (const listener of listeners.onBeforeRequest) {
          const response = await listener({ tabId, url: changeInfo.url, type: "main_frame" });
          if (response?.cancel) {
            await Promise.resolve();
            return response;
          }
        }
        tab.url = changeInfo.url;
      }
      for (const listener of listeners.onUpdated) {
        await listener(tabId, changeInfo, tab ? { ...tab } : {});
      }
      await Promise.resolve();
    },
    async emitUpdated(tabId, changeInfo, tabOverride) {
      const tab = tabOverride || tabs.get(tabId) || {};
      for (const listener of listeners.onUpdated) {
        await listener(tabId, changeInfo, { ...tab });
      }
      await Promise.resolve();
    },
    async create(tab) {
      tabs.set(tab.id, { ...tab });
      for (const listener of listeners.onCreated) {
        await listener({ ...tab });
      }
      await Promise.resolve();
      await Promise.resolve();
    },
    async remove(tabId) {
      await browser.tabs.remove(tabId);
      for (let index = 0; index < 12; index += 1) {
        await Promise.resolve();
      }
    },
    async receiveNative(message, portIndex) {
      if (options.withCommandPort) {
        for (const listener of portIndex === undefined ? nativeReceivers : nativePorts[portIndex].messages) await listener(message);
        return;
      }
      if (message?.tabCommand) {
        await context.handleRequestedTab(message.tabCommand);
      }
      await Promise.resolve();
    }
  };
}

async function nativeProfileBootstrapRegression() {
  const initial = [{id:101,windowId:1,index:0,active:true,url:"https://example.test/",title:"Bootstrap actual tab"},
    {id:102,windowId:2,index:0,active:true,url:"https://second.example/"}];
  const snapshots = h => h.nativeMessages.filter(message => message.type === "tabsSnapshot");
  const settle = async () => { for (let i = 0; i < 4; ++i) await new Promise(setImmediate); };
  const base = {withCommandPort:true,controlReconnectTimers:true,requestOnlyNativeReplies:true};
  {
    let reads = 0;
    const h = createHarness({active:false}, initial, {...base,
      onWindowQuery(_query, windows) { reads += 1; return windows; }}); await h.ready(); await settle();
    assert.equal(snapshots(h).length, 1, "A fresh confirmed idle Firefox connection bootstraps its real profile inventory once");
    const first = snapshots(h)[0];
    assert.deepEqual(Array.from(first.allTabs, tab => tab.id), [101,102]);
    assert.deepEqual(Array.from(first.snapshotRequestIDs), []);
    assert.equal(first.completeWindowInventory === true, false, "Bootstrap cannot certify correlated profile absence");
    assert.equal(first.browserProfileID, h.browserProfileID());
    await h.heartbeat(); await h.update(101,{title:"Idle update"}); await settle();
    assert.equal(snapshots(h).length, 1, "Idle heartbeats/events remain quiet after one bootstrap");
    assert.equal(reads, 1, "Successful Firefox bootstrap prevents further idle inventory reads");
    assert.equal(h.updates.length + h.focusedWindows.length + h.removals.length, 0,
      "Bootstrap cannot activate, hide or close tabs/windows");
  }
  for (const failure of ["query-rejected", "transition-empty-tabs", "malformed-window"]) {
    const options = {...base, onWindowQuery(_query, windows) {
      if (failure === "query-rejected") throw new Error("fixture: populated windows unavailable");
      if (failure === "transition-empty-tabs") return windows.map(window => ({...window,tabs:[]}));
      return windows.map(window => ({...window,width:NaN}));
    }};
    const h = createHarness({active:false}, initial, options); await h.ready(); await settle();
    assert.equal(snapshots(h).length, 0, failure + " cannot publish an invented empty bootstrap");
    options.onWindowQuery = (_query, windows) => windows;
    const port = h.nativePorts.at(-1);
    await h.heartbeat(); await settle();
    assert.equal(snapshots(h).length, 1, "A same-port heartbeat recovers failed bootstrap with a fresh inventory");
    assert.equal(h.nativePorts.at(-1), port, "Firefox bootstrap recovery must not replace a healthy profile connection");
    assert.equal(snapshots(h)[0].browserProfileID, h.browserProfileID());
    assert.deepEqual(Array.from(snapshots(h)[0].snapshotRequestIDs), []);
    assert.equal(snapshots(h)[0].completeWindowInventory === true, false);
    await h.heartbeat(); await settle();
    assert.equal(snapshots(h).length, 1, "Successful same-port recovery stops further idle bootstrap reads");
  }
  for (const failure of ["failProfileRead", "failProfileWrite", "dropProfileWrite"]) {
    const options = {...base,[failure]:true};
    const h = createHarness({active:false}, initial, options); await h.ready(); await settle();
    const port = h.nativePorts.at(-1);
    assert(port, "Firefox may establish a port before durable profile storage recovers");
    assert.equal(h.browserProfileID(), null);
    assert.equal(snapshots(h).length, 0);
    options[failure] = false;
    await h.heartbeat(); await settle();
    assert.equal(h.nativePorts.at(-1), port);
    assert.equal(snapshots(h).length, 1, failure + " recovers Firefox bootstrap on the same port after durable UUID persistence");
    assert.equal(snapshots(h)[0].browserProfileID, h.storage.intentBrowserProfileID);
    assert.deepEqual(Array.from(snapshots(h)[0].snapshotRequestIDs), []);
    assert.equal(snapshots(h)[0].completeWindowInventory === true, false);
  }
  {
    let release, started, reads = 0;
    const heldRead = new Promise(resolve => { release = resolve; });
    const captured = new Promise(resolve => { started = resolve; });
    const options = {...base, onWindowQuery() { throw new Error("fixture: initial bootstrap unavailable"); }};
    const h = createHarness({active:false}, initial, options); await h.ready(); await settle();
    options.onWindowQuery = async (_query, windows) => { reads += 1; started(); await heldRead; return windows; };
    await h.heartbeat(); await captured;
    await h.heartbeat(); await h.heartbeat(); await settle();
    assert.equal(reads, 1, "Firefox same-port heartbeat retries coalesce while the inventory read is pending");
    h.disconnectPort(0);
    options.onWindowQuery = () => { throw new Error("fixture: replacement inventory unavailable"); };
    await h.runReconnectTimer(); await settle();
    release(); await settle();
    assert.equal(snapshots(h).length, 0, "Retired Firefox retry cannot consume the replacement profile's pending bootstrap");
    options.onWindowQuery = (_query, windows) => windows;
    h.tabs.set(103,{id:103,windowId:1,index:1,active:false,url:"https://replacement.example/"});
    await h.heartbeat(); await settle();
    assert.equal(snapshots(h).length, 1);
    assert(snapshots(h)[0].allTabs.some(tab => tab.id === 103));
    assert.equal(snapshots(h)[0].browserProfileID, h.browserProfileID());
  }
  {
    const h = createHarness({active:true,accessMode:"whitelist",selectedTabIDs:[101],allowedWebsites:[],startupWebsites:[],
      startupSessionID:"bootstrap-active-policy"}, initial, base); await h.ready(); await settle();
    assert(snapshots(h).some(message => message.allTabs.length === 2));
    assert(snapshots(h).every(message => message.tabs.every(tab => tab.id === 101)),
      "Active Firefox bootstrap cannot admit excluded tabs into the allowed inventory");
  }
  {
    const h = createHarness({active:false}, [], base); await h.ready(); await settle();
    assert.equal(snapshots(h).length, 1, "Actual successful empty Firefox enumeration may identify a connected profile");
    assert.equal(snapshots(h)[0].completeWindowInventory === true, false);
    assert.deepEqual(Array.from(snapshots(h)[0].snapshotRequestIDs), []);
  }
  {
    let release, started, held = true;
    const read = new Promise(resolve => { release = resolve; });
    const captured = new Promise(resolve => { started = resolve; });
    const h = createHarness({active:false}, initial, {...base, async onWindowQuery(_query, windows) {
      if (held) { held = false; started(); await read; }
      return windows;
    }});
    await captured; h.disconnectPort(0);
    h.tabs.set(103,{id:103,windowId:1,index:1,active:false,url:"https://replacement.example/"});
    await h.runReconnectTimer(); await settle();
    assert.equal(snapshots(h).length, 1);
    assert(snapshots(h)[0].allTabs.some(tab => tab.id === 103));
    release(); await settle();
    assert.equal(snapshots(h).length, 1, "A retired Firefox port query cannot overwrite its replacement profile sidecar");
    assert.equal(h.updates.length + h.focusedWindows.length, 0);
  }
  console.log("Firefox one-time read-only profile bootstrap, quiet idle, failures and retired-port fences: passed");
}

async function run() {
  {
    const active = {active:true,accessMode:"whitelist",selectedTabIDs:[71],allowedWebsites:[],startupWebsites:[],
      startupSessionID:"disconnect-current",blockNavigation:true,hideDistractions:true,nativeWindowVisibility:true,
      browserProcessIdentity:{pid:321,launched:800001000},hostCapabilities:["native-window-visibility-host-v1"],
      websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["messages"]}}};
    const parked = {windowID:2,title:"Fixture parked window",frame:{left:40,top:50,width:900,height:700},state:"minimized"};
    const h = createHarness(active,[
      {id:71,windowId:1,index:0,active:true,url:"https://www.instagram.com/"},
      {id:72,windowId:2,index:0,active:false,url:"https://example.org/"}
    ],{withCommandPort:true,controlReconnectTimers:true,nativeVisibility:true,
      async onVisibilitySync(rules,owner) { if (rules.active) await owner.publishPlan(rules,[],[parked]); }});
    await h.ready();
    for (let i=0;i<8;i++) await new Promise(setImmediate);
    const request = (id,url) => h.listeners.onBeforeRequest[0]({tabId:id,url,type:"main_frame"});
    assert.equal(request(72,"https://example.org/").cancel,true,"The live exact-tab rule blocks an unselected tab before loss");
    assert.equal(request(71,"https://www.instagram.com/").redirectUrl,"https://www.instagram.com/direct/inbox/",
      "The current Instagram messages policy is active before host loss");
    const ownership = JSON.stringify(h.sessionStorage.intentNativeWindowVisibilityV1.plans);
    const parkingProof = JSON.stringify(h.storage.intentNativeParkingClosureV1);
    assert(h.sessionStorage.intentNativeWindowVisibilityV1.plans[active.startupSessionID].parkingWindows.length,
      "A real native-owner accepted parking plan exists before transport loss");
    h.updates.length=0;h.focusedWindows.length=0;
    h.setHostAvailable(false);h.disconnectPort();
    assert.equal(h.activeRules().active,false,"Current-port disconnect releases browser enforcement synchronously");
    assert.equal(request(72,"https://example.org/").cancel,undefined,"A disconnected exact-tab rule cannot keep blocking requests");
    assert.equal(request(71,"https://www.instagram.com/").redirectUrl,undefined,"A disconnected Instagram rule cannot keep redirecting requests");
    await h.activate(72);
    for (let i=0;i<8;i++) await new Promise(setImmediate);
    assert.equal(h.tabs.get(72).active,true,"Ordinary tab clicks remain where the user puts them after disconnect");
    assert.equal(h.updates.some(update=>update.patch.active===true),false,"Disconnect never activates a fallback tab");
    assert.deepEqual(h.focusedWindows,[],"Disconnect does not focus an arbitrary browser window");
    assert.equal(JSON.stringify(h.sessionStorage.intentNativeWindowVisibilityV1.plans),ownership,
      "Disconnect retains accepted native window ownership for durable recovery");
    assert.equal(JSON.stringify(h.storage.intentNativeParkingClosureV1),parkingProof,
      "Disconnect cannot discard or invent closure of a parked-window proof");
    assert.equal(await h.nativeWindowOwner().revealWindows(active.startupSessionID,[parked]),false,
      "A missing host cannot acknowledge release of an owned native window");
    assert.equal(JSON.stringify(h.sessionStorage.intentNativeWindowVisibilityV1.plans),ownership,
      "Failed reveal keeps the original ownership plan rather than blindly unhiding a window");
    assert.equal(h.reconnectTimers().length,1,"Only one bounded reconnect is pending");
    await h.runReconnectTimer();
    assert.equal(h.activeRules().active,false,"Failed reconnection leaves all browser rules inactive");
    assert.equal(h.reconnectTimers()[0][1].delay,2000,"An unavailable host retains exponential reconnect backoff");
    const newer = h.setNativeRules({...active,startupSessionID:"disconnect-new",selectedTabIDs:[72]});
    h.setHostAvailable(true);await h.runReconnectTimer();
    assert.equal(h.activeRules().active,true,"A confirmed newer connection can apply the host's current intention");
    assert.deepEqual(Array.from(h.activeRules().selectedTabIDs),[72]);
    const currentPort=h.nativePorts.length-1;
    assert(currentPort>0);
    h.disconnectPort(0);await h.receiveNative({...active,selectedBrowserSessionID:h.browserSessionID()},0);
    assert.equal(h.activeRules().active,true,"An obsolete port disconnect cannot disable a newer connection");
    assert.equal(h.activeRules().startupSessionID,newer.startupSessionID,"An obsolete port message cannot restore the previous session");
    assert.deepEqual(Array.from(h.activeRules().selectedTabIDs),[72]);
  }
  {
    const h=createHarness({active:false},[{id:71,windowId:1,index:0,active:true,url:"https://www.instagram.com/"}],
      {withCommandPort:true,controlReconnectTimers:true,hostAvailable:false});
    await h.ready();
    await h.applyRules({active:true,accessMode:"whitelist",startupSessionID:"cached-before-retry",selectedTabIDs:[71],
      startupWebsites:[],websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["messages"]}}});
    assert.equal(h.activeRules().active,true);
    await h.runReconnectTimer();
    assert.equal(h.activeRules().active,false,"A failed connectNative attempt clears any retained active policy");
    assert.equal(h.nativeConnectAttempts(),2,"The controlled timer performs exactly one failed reconnect attempt");
  }
  {
    const h=createHarness({active:true,accessMode:"whitelist",startupSessionID:"disconnect-write",selectedTabIDs:[71],
      allowedWebsites:[],startupWebsites:[],websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["messages"]}}},[
      {id:71,windowId:1,index:0,active:true,url:"https://www.instagram.com/"}
    ],{withCommandPort:true,controlReconnectTimers:true,requestOnlyNativeReplies:true});
    await h.ready();await new Promise(setImmediate);
    assert.equal(h.activeRules().active,true);
    h.setHostAvailable(false);await h.heartbeat();
    assert.equal(h.activeRules().active,false,"A current-port postMessage failure releases the same stale browser policy");
    assert.equal((await h.message({type:"getGuardStatus"})).connected,false,"Write failure revokes connected readiness");
    assert.equal(h.reconnectTimers().length,1,"A write failure and any later disconnect share one reconnect attempt");
    h.disconnectPort();
    assert.equal(h.reconnectTimers().length,1,"A repeated retired-port disconnect cannot duplicate retries");
  }
  {
    let hold=false, captured, release;
    const started=new Promise(resolve=>captured=resolve), gate=new Promise(resolve=>release=resolve);
    const h=createHarness({active:true,accessMode:"whitelist",startupSessionID:"disconnect-command",selectedTabIDs:[71],
      allowedWebsites:[],startupWebsites:[]},[
      {id:71,windowId:1,index:0,active:true,url:"https://example.com/"},
      {id:72,windowId:1,index:1,active:false,url:"https://example.org/"}
    ],{withCommandPort:true,controlReconnectTimers:true,requestOnlyNativeReplies:true,
      async afterTabGet() { if(hold){hold=false;captured();await gate;} }});
    await h.ready();await new Promise(setImmediate);
    h.updates.length=0;h.focusedWindows.length=0;hold=true;
    const pending=h.command({browserSessionID:h.browserSessionID(),tabID:71,windowID:1});
    await started;h.setHostAvailable(false);h.disconnectPort();await h.activate(72);release();await pending;
    assert.equal(h.tabs.get(72).active,true,"A command from a disconnected port cannot undo the user's next tab click");
    assert.equal(h.updates.some(update=>update.patch.active===true),false,"Old-port pending activation is canceled before dispatch");
    assert.deepEqual(h.focusedWindows,[],"Old-port pending activation cannot focus a window after transport loss");
  }
  {
    const h=createHarness({active:false},[
      {id:401,windowId:44,index:0,active:true,url:'about:blank',title:'New tab'},
      {id:402,windowId:44,index:1,active:false,url:'https://example.com/t-added',title:'Example'}
    ],{withCommandPort:true});
    await h.ready();
    h.nativeMessages.length=0;
    await h.command({browserSessionID:h.browserSessionID(),tabID:402,windowID:44});
    const reply=h.nativeMessages.filter(message=>message.type==='tabsSnapshot').at(-1);
    assert(reply?.allTabs.some(tab=>tab.id===402&&tab.active),
      'An explicit idle activation must publish its actual new active tab without waiting for a second discovery request');
    assert(reply.allTabs.some(tab=>tab.id===401&&!tab.active),'The old active tab must no longer be reported as current');
    assert.equal(h.tabs.size,2,'Startup confirmation must never open or reload a replacement tab');
  }
  for (const initiallyActive of [false,true]) for (const rejectQuery of [false,true]) {
    const active={active:true,accessMode:"whitelist",startupSessionID:"ordered-native-start",
      selectedTabIDs:[8],allowedWebsites:["example.com"],startupWebsites:[],blockNavigation:true};
    let holdNext=false, started, release;
    const captured=new Promise(resolve=>started=resolve), gate=new Promise(resolve=>release=resolve);
    const h=createHarness(initiallyActive?active:{active:false},[
      {id:8,windowId:344,index:0,active:true,url:"https://example.com/"}
    ],{withCommandPort:true,requestOnlyNativeReplies:true,async afterTabQuery(){if(holdNext){holdNext=false;started();await gate;if(rejectQuery)throw new Error("query cancelled");}}});
    await h.ready();await new Promise(setImmediate);
    holdNext=true;
    const olderRules=h.setNativeRules(initiallyActive?active:{active:false});
    const older=h.receiveNative({...olderRules,tabCommand:{id:"slow-old-command",action:"snapshot",tabID:-1,windowID:-1}});
    await captured;
    const newer=h.setNativeRules(initiallyActive?{active:false}:active);
    await h.receiveNative(newer);
    assert.equal((await h.message({type:"getActiveRules"})).active,!initiallyActive,"New Start/Finish applies while an older command is pending");
    release();await older;await new Promise(setImmediate);
    assert.equal((await h.message({type:"getActiveRules"})).active,!initiallyActive,
      "An older native command completion or rejection must not reapply stale rules after Start/Finish");
    if(!initiallyActive) assert.deepEqual(h.allowedTabIDs(),[8],"Latest active exact-tab enforcement survives old inactive command completion");
  }
  {
    let holdQuery=false, queryStarted, releaseQuery, applicationStarted, releaseApplication;
    const queryCaptured=new Promise(resolve=>queryStarted=resolve), queryGate=new Promise(resolve=>releaseQuery=resolve);
    const applicationCaptured=new Promise(resolve=>applicationStarted=resolve), applicationGate=new Promise(resolve=>releaseApplication=resolve);
    const h=createHarness({active:false},[{id:8,windowId:344,index:0,active:true,url:"https://example.com/"}],{
      withCommandPort:true,requestOnlyNativeReplies:true,
      async afterTabQuery(){if(holdQuery){holdQuery=false;queryStarted();await queryGate;}},
      async onVisibilitySync(rules){if(rules.active){applicationStarted();await applicationGate;}}
    });
    await h.ready();await new Promise(setImmediate);
    holdQuery=true;
    const older=h.receiveNative({active:false,tabCommand:{id:"before-refresh",action:"snapshot",tabID:-1,windowID:-1}});
    await queryCaptured;
    h.setNativeRules({active:true,accessMode:"whitelist",startupSessionID:"newer-refresh",
      allowedWebsites:["example.com"],startupWebsites:[],selectedTabIDs:[8]});
    let refreshed=false;
    const refreshing=h.refresh().then(()=>{refreshed=true;});
    await applicationCaptured;
    releaseQuery();await older;for(let n=0;n<16;n++)await Promise.resolve();
    assert.equal(refreshed,false,"An older callback cannot settle a newer refresh while its rule application is pending");
    releaseApplication();await refreshing;
    assert.equal(refreshed,true,"The current refresh completes after its own latest rule application");
  }
  for (const replacementActive of [false,true]) {
    let hold=false, started, release;
    const captured=new Promise(resolve=>started=resolve), gate=new Promise(resolve=>release=resolve);
    const h=createHarness({active:false},[{id:8,windowId:344,index:0,active:true,url:"about:blank"}],{
      withCommandPort:true,requestOnlyNativeReplies:true,
      async afterTabUpdate(patch){if(hold && patch.url){hold=false;started();await gate;}}
    });
    await h.ready();await new Promise(setImmediate);
    hold=true;
    const earlier=h.setNativeRules({active:true,accessMode:"whitelist",startupSessionID:"old-startup",
      allowedWebsites:["example.com","example.org"],startupWebsites:["https://example.com/first","https://example.org/second"]});
    const starting=h.receiveNative(earlier);await captured;
    const replacement=h.setNativeRules(replacementActive?{...earlier,startupSessionID:"replacement-startup",startupWebsites:[]}:{active:false});
    const finishing=h.receiveNative(replacement);
    const effectCount=h.updates.length;release();await Promise.all([starting,finishing]);
    assert.equal(h.updates.filter(update=>update.patch.url).length,1,"Finish/replacement prevents remaining old-session startup URL effects");
    assert.equal(h.updates.slice(effectCount).some(update=>update.patch.active===true && !update.patch.url),false,
      "Obsolete startup completion cannot activate its first tab after Finish/replacement");
    assert.equal(h.tabs.size,1,"Obsolete startup loop cannot create the second requested tab");
  }
  {
    let release;const gate=new Promise(resolve=>release=resolve), observed=[];
    const initial={active:true,nativeWindowVisibility:true,hideDistractions:true,startupSessionID:'bootstrap-routing',
      allowedWebsites:['example.com'],startupWebsites:[],browserProcessIdentity:{pid:321,launched:800001000},
      hostCapabilities:['native-window-visibility-host-v1','firefox-window-minimize-bootstrap-host-v1']};
    const native=createHarness(initial,[{id:1,windowId:1,active:true,url:'https://example.com/'}],{
      nativeVisibility:true,withCommandPort:true,bootstrapObserver:(message,context)=>observed.push({message,context}),
      onVisibilitySync:async rules=>{if(rules.active)await gate;}});
    for(let n=0;n<8;n++)await new Promise(setImmediate);
    const incoming=native.receiveNative({...initial,active:false,minimizeBootstrapOffers:[]});
    for(let n=0;n<8;n++)await Promise.resolve();
    assert.equal(observed.at(-1).context.rules.active,false,'Finish reaches the bootstrap fence before a pending visibility operation settles');
    release();await incoming;
    assert(!require('../chrome-extension/manifest.json').background.service_worker?.includes('bootstrap'));
    assert(!fs.readFileSync(path.join(__dirname,'../chrome-extension/background.js'),'utf8').includes('new IntentFirefoxMinimizeBootstrap'),
      'Chrome has no Firefox effect executor');
  }
  // The real adapter waits for a receipt inside the serialized rules pipeline.
  // Delivering receipts after awaiting that same pipeline would deadlock setup.
  for (const [compatible, processProof] of [[true, true], [true, false], [false, true]]) {
    const receipts = [];
    const syncModes = [];
    const native = createHarness({active: true, addAsYouGo: true,
      nativeWindowVisibility: true, hideDistractions: true,
      browserProcessIdentity: processProof ? {pid: 321, launched: 800001000} : null,
      startupSessionID: "native-visibility-port", selectedTabIDs: [1],
      allowedWebsites: ["example.com"], startupWebsites: [],
      hostCapabilities: compatible ? ["native-window-visibility-host-v1"] : []},
      [{id: 1, windowId: 1, active: true, url: "https://example.com/"}], {
        nativeVisibility: true, withCommandPort: true,
        onVisibilitySync: async (rules, owner, mode) => {
          if (!rules.active) return;
          syncModes.push(mode);
          if (rules.nativeWindowVisibility) receipts.push(await owner.publishPlan(rules, [], []));
        }
      });
    for (let i = 0; i < 8; i++) await new Promise(setImmediate);
    assert.equal(receipts.includes(true), compatible, "Native visibility requires negotiated host capability and a processed receipt");
    const before = syncModes.length;
    native.intervals.find(interval => interval.delay === 3000).callback();
    for (let i = 0; i < 8; i++) await new Promise(setImmediate);
    assert.ok(syncModes.length > before);
    assert.equal(syncModes.at(-1), "initial", "Heartbeat must retry initial selection through the durable visibility ledger");
    assert.equal(native.nativeMessages.some(message => message.type === "windowVisibilityPlan"), compatible);
    assert.equal(native.nativeMessages.some(message => message.extensionCapabilities?.includes('native-window-visibility-v1')),
      compatible && processProof, 'Readiness requires both modern host and verified current process proof');
  }

  {
    const base = {active:false, hostCapabilities:['native-window-visibility-host-v1']};
    const proof = {pid:321, launched:800001000};
    const native = createHarness({...base, browserProcessIdentity:proof}, [],
      {nativeVisibility:true, withCommandPort:true});
    for (let i = 0; i < 8; i++) await new Promise(setImmediate);
    for (const available of [false, true]) {
      const response = available ? {...base, browserProcessIdentity:proof} : base;
      await native.applyRules(response);
      const before = native.nativeMessages.filter(message => message.type === 'heartbeat').length;
      await native.receiveNative(response);
      for (let i = 0; i < 8; i++) await new Promise(setImmediate);
      const beats = native.nativeMessages.filter(message => message.type === 'heartbeat');
      assert.ok(beats.length > before, 'Readiness changes publish immediately without waiting for the timer');
      assert.equal(beats.at(-1).extensionCapabilities.includes('native-window-visibility-v1'), available,
        'Omitted process proof revokes readiness and verified proof restores it');
    }
  }

  for (const outcome of ["finish", "new-click", "leave-browser", "own-activation"]) {
    let releaseActivation, activationStarted;
    let pauseActivation = false;
    const started = new Promise(resolve => { activationStarted = resolve; });
    const delayed = new Promise(resolve => { releaseActivation = resolve; });
    const race = createHarness({active: true, accessMode: 'whitelist', selectedTabIDs: [1, 2],
      allowedWebsites: [], startupWebsites: [], startupSessionID: 'activation-finish-race',
      blockTabSwitching: true, blockNavigation: true}, [
        {id: 1, windowId: 1, active: true, url: 'https://example.com/'},
        {id: 2, windowId: 2, active: false, url: 'https://example.org/'},
        {id: 3, windowId: 3, active: false, url: 'https://blocked.example/'}
      ], {emitActivationOnUpdate: true, afterTabUpdate: async patch => {
        if (pauseActivation && patch.active) { pauseActivation = false; activationStarted(); await delayed; }
      }});
    await race.ready();
    race.focusedWindows.length = 0;
    pauseActivation = true;
    const returning = race.activate(3);
    let deadline;
    await Promise.race([started, new Promise((_, reject) => {
      deadline = setTimeout(() => reject(new Error("Recovery did not reach activation")), 2000);
    })]).finally(() => clearTimeout(deadline));
    if (outcome === "finish") await race.applyRules({active: false});
    else if (outcome === "new-click") await race.activate(2);
    else if (outcome === "leave-browser") await race.focusWindow(-1);
    releaseActivation();
    await returning;
    assert.equal(race.focusedWindows.length, outcome === "own-activation" ? 1 : 0,
      "Recovery must accept its own activation but never raise a window after finish or a newer click");
  }

  for (const mode of ['whitelist', 'blacklist']) {
    const open = createHarness({active: true, guardEnabled: true, addAsYouGo: true, accessMode: mode,
      allowedWebsites: [], selectedTabIDs: [81], blockNavigation: true, blockTabSwitching: true, blockNewTabs: true,
      allowGoogleSearchTabs: true, startupSessionID: 'open-test'}, [
      {id: 81, windowId: 1, active: mode === 'whitelist', url: 'https://example.com/'},
      {id: 82, windowId: 1, active: mode === 'blacklist', url: 'https://other.example/'}
    ]);
    await open.ready();
    await open.activate(82);
    assert.equal(open.tabs.get(82).active, true, 'Add as you go permits ordinary tab switching');
    await open.update(82, {url: 'https://new.example/'});
    assert.equal(open.tabs.get(82).url, 'https://new.example/', 'Add as you go permits ordinary website navigation');
    assert.equal(open.removals.length, 0, 'Add as you go and blacklist never delete existing tabs');
    await open.create({id: 83, windowId: 1, active: true, url: 'https://fresh.example/'});
    await open.activate(83);
    assert.equal(open.tabs.get(83)?.active, true, 'A new ordinary tab is usable with Add as you go');
    if (mode === 'blacklist') {
      await open.activate(81);
      assert.equal(open.tabs.get(81).active, false, 'An explicit blacklisted tab remains inaccessible');
    }
  }

  const website = createHarness({active:true, accessMode:"whitelist", selectedTabIDs:[7],
    websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:["search"]}}}, [
      {id:7,windowId:1,active:true,url:"https://www.youtube.com/watch?v=test"}
    ]);
  await website.ready();
  assert.equal(website.listeners.onBeforeRequest[0]({tabId:7,url:"https://www.youtube.com/shorts/test"}).cancel, true, "A selected Firefox tab must not bypass its No Shorts policy");
  assert.equal(website.listeners.onBeforeRequest[0]({tabId:7,url:"https://www.youtube.com/watch?v=test"}).cancel, undefined, "Normal videos remain usable");
  // Real address-bar navigation also emits onCommitted; onUpdated alone does
  // not exercise the exact-tab direct-navigation guard.
  for (const mode of ['whitelist', 'blacklist']) {
    for (const addAsYouGo of (mode === 'whitelist' ? [true] : [false, true])) {
      const navigation = createHarness({active: true, accessMode: mode, addAsYouGo,
        selectedTabIDs: [1], allowedWebsites: [], startupWebsites: [],
        startupSessionID: `direct-navigation-${mode}-${addAsYouGo}`,
        blockNavigation: true, blockTabSwitching: true, allowGoogleSearchTabs: true}, [
        {id: 1, windowId: 1, active: mode === 'whitelist', url: 'https://example.com/'},
        {id: 2, windowId: 1, active: mode === 'blacklist', url: 'https://example.org/'}
      ]);
      await navigation.ready();
      const existingID = mode === 'whitelist' ? 1 : 2;
      await navigation.create({id: 3, windowId: 1, active: true, url: 'about:blank'});
      for (const id of [existingID, 3]) {
        await navigation.commit(id, 'https://new.example/', 'typed');
        assert.equal(navigation.tabs.get(id).url, 'https://new.example/', `${mode}: permitted tabs accept typed websites`);
        await navigation.commit(id, 'https://www.google.com/search?q=study', 'generated');
        assert.equal(navigation.tabs.get(id).url, 'https://www.google.com/search?q=study', `${mode}: permitted tabs accept address-bar searches`);
        await navigation.commit(id, 'https://result.example/', 'link');
        assert.equal(navigation.tabs.get(id).url, 'https://result.example/', `${mode}: ordinary search results can open`);
      }
      if (mode === 'blacklist') {
        await navigation.activate(1);
        assert.equal(navigation.tabs.get(1).active, false, 'Direct navigation permission must not unblock explicitly blacklisted tabs');
      }
    }
  }

  // Background loading and background-created search tabs must never change
  // which user-selected tab receives a blocked activation's recovery.
  {
    const recovery = createHarness({active: true, accessMode: 'whitelist', selectedTabIDs: [1,2],
      allowedWebsites: [], startupWebsites: [], startupSessionID: 'background-recovery',
      blockNavigation: true, blockTabSwitching: true, allowGoogleSearchTabs: true}, [
      {id: 1, windowId: 1, active: true, url: 'https://example.com/'},
      {id: 2, windowId: 1, active: false, url: 'https://example.org/'},
      {id: 3, windowId: 1, active: false, url: 'https://blocked.example/'}
    ]);
    await recovery.ready();
    await recovery.activate(1);
    await recovery.emitUpdated(2, {status: 'complete'});
    await recovery.activate(3);
    assert.equal(recovery.tabs.get(1).active, true, 'A background page load must not replace the last user-selected allowed tab');
    await recovery.create({id: 4, windowId: 1, active: false, url: 'about:blank'});
    await recovery.activate(3);
    assert.equal(recovery.tabs.get(1).active, true, 'A background search tab must not replace the last user-selected allowed tab');
  }

  // Visibility restoration emits browser events. Once stop arrives those
  // events must not be processed using the previous intention's restrictions.
  {
    let restore = async () => {};
    const finishing = createHarness({active: true, accessMode: 'whitelist', selectedTabIDs: [1],
      allowedWebsites: [], startupWebsites: [], startupSessionID: 'finishing-visibility',
      blockNavigation: true, blockTabSwitching: true}, [
      {id: 1, windowId: 1, active: true, url: 'https://example.com/'},
      {id: 2, windowId: 1, active: false, url: 'https://example.org/'}
    ], {onVisibilitySync: rules => !rules.active ? restore() : Promise.resolve()});
    await finishing.ready();
    finishing.updates.length = 0;
    restore = async () => { await finishing.activate(2); };
    await finishing.applyRules({active: false});
    assert.equal(finishing.tabs.get(2).active, true, 'Restoration events after stop must not reactivate the old selected tab');
    assert.equal(finishing.updates.filter(update => update.patch.active).length, 0, 'Session finish must not issue an activation during restoration');
    await finishing.applyRules({active: true, accessMode: 'whitelist', selectedTabIDs: [1],
      allowedWebsites: [], startupWebsites: [], startupSessionID: 'previous-session', blockTabSwitching: true});
    let enterRestore, releaseRestore;
    const restoreEntered = new Promise(resolve => { enterRestore = resolve; });
    const restoreGate = new Promise(resolve => { releaseRestore = resolve; });
    restore = async () => { enterRestore(); await restoreGate; };
    const stopping = finishing.applyRules({active: false});
    await restoreEntered;
    const starting = finishing.applyRules({active: true, accessMode: 'whitelist', selectedTabIDs: [2],
      allowedWebsites: [], startupWebsites: [], startupSessionID: 'replacement-session', blockTabSwitching: true});
    releaseRestore();
    await Promise.all([stopping, starting]);
    assert.deepEqual(finishing.allowedTabIDs(), [2], 'A delayed old restore cannot clear or reinstate policy over the newer intention');
  }

  // Old blank/result tabs must not inherit the fresh-search allowance.
  {
    const searchRules = {active: true, hideDistractions: true, accessMode: 'whitelist', selectedTabIDs: [1], allowedWebsites: [], startupWebsites: [], startupSessionID: 'fresh-search-regression', blockTabSwitching: true, blockNavigation: true, blockNewTabs: true, allowGoogleSearchTabs: true};
    const domains = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/google-search-domains.json'), 'utf8')).hosts;
    assert.deepEqual([...helpers.supportedGoogleSearchHosts].sort(), [...domains].sort(), 'Firefox exact search domains cannot drift from the verified native/Chrome fixture');
    for (const host of domains) {
      assert.equal(helpers.isGoogleSearchURL('https://www.' + host + '/search?q=study'), true, 'Verified regional search remains allowed: ' + host);
      assert.equal(helpers.isGoogleSearchURL('https://' + host + '.evil.example/search'), false, 'Attacker suffix cannot become search: ' + host);
    }
    const sessionStorage = {};
    const freshSearch = createHarness(searchRules, [
      {id: 1, windowId: 1, active: true, url: 'https://example.com/work'},
      {id: 2, windowId: 1, active: false, url: 'about:blank'},
      {id: 3, windowId: 1, active: false, url: 'https://www.google.com/search?q=old'}
    ], {sessionStorage, withCommandPort: true});
    await freshSearch.ready();
    assert.deepEqual(freshSearch.allowedTabIDs(), [1], 'Existing blank/search tabs stay outside the intention');
    await freshSearch.activate(3);
    assert.equal(freshSearch.tabs.get(1).active, true, 'An old results tab cannot be activated');
    await freshSearch.create({id: 9, windowId: 1, active: true, url: 'about:blank'});
    assert.deepEqual(freshSearch.allowedTabIDs(), [1,9], 'A tab created during the intention can search');
    await freshSearch.update(9, {url: 'https://www.google.com/search?q=focus'});
    assert.equal(freshSearch.tabs.get(9).url, 'https://www.google.com/search?q=focus');
    let searchSnapshot = await freshSearch.snapshot();
    assert.equal(searchSnapshot.allTabs.find(tab => tab.id === 9).searchSessionID, searchRules.startupSessionID, 'A live fresh search exposes the exact rules occurrence to native lifetime checks');
    for (const id of [2, 3]) assert.equal(searchSnapshot.allTabs.find(tab => tab.id === id).searchSessionID, null, 'An old unselected blank/Google tab never exposes search membership');
    freshSearch.tabs.get(9).url = 'https://blocked.example/';
    searchSnapshot = await freshSearch.snapshot();
    assert.equal(searchSnapshot.allTabs.find(tab => tab.id === 9).searchSessionID, null, 'A blocked destination observed before recovery cannot count as live allowed search work');
    freshSearch.tabs.get(9).url = 'https://www.google.com/search?q=focus';
    const blocked = await freshSearch.update(9, {url: 'https://example.org/'}); assert.equal(blocked.cancel, true);
    assert.equal(freshSearch.tabs.get(9).url, 'https://www.google.com/search?q=focus', 'Fresh search tabs cannot leave search results');
    await freshSearch.create({id: 10, windowId: 2, active: false, url: 'about:blank'});
    await freshSearch.commit(10, 'extension://intent/parked.html', 'auto_toplevel');
    assert.equal(freshSearch.tabs.get(10).url, 'extension://intent/parked.html', 'Holding page must not be rewritten as a search tab');
    await freshSearch.commit(10, 'extension://intent/parked.html#intent-12345678-abcd-1234-abcd-123456789012', 'auto_toplevel');
    assert.equal(freshSearch.tabs.get(10).url, 'extension://intent/parked.html#intent-12345678-abcd-1234-abcd-123456789012', 'Nonce-bound holding page must remain outside fresh search allowance');
    assert(!freshSearch.allowedTabIDs().includes(10), 'Holding sentinel never becomes search-authorized');
    assert.equal((await freshSearch.snapshot()).allTabs.find(tab => tab.id === 10).searchSessionID, null, 'The holding page cannot keep a native session alive');
    freshSearch.tabs.delete(1);
    assert.equal((await freshSearch.snapshot()).allTabs.find(tab => tab.id === 9).searchSessionID, searchRules.startupSessionID, 'Closing the original selected tab retains live search membership');
    await freshSearch.applyRules({...searchRules, accessMode: 'blacklist'});
    assert.equal((await freshSearch.snapshot()).allTabs.find(tab => tab.id === 9).searchSessionID, null, 'Blacklist rules cannot donate a retained search ledger to whitelist lifetime');
    await freshSearch.applyRules({...searchRules, allowGoogleSearchTabs: false});
    assert.equal((await freshSearch.snapshot()).allTabs.find(tab => tab.id === 9).searchSessionID, null, 'Disabled Tab searches removes runtime lifetime authority');
  }

  for (const searches of [false, true]) {
    const navigation = createHarness({active: true, accessMode: "whitelist", selectedTabIDs: [1], allowedWebsites: [], startupWebsites: [], blockNavigation: true, allowGoogleSearchTabs: searches}, [{id: 1, windowId: 1, active: true, url: "https://discord.com/channels/a"}]);
    await navigation.ready();
    await navigation.create({id: 2, windowId: 1, active: false, url: "about:blank"});
    await navigation.commit(2, "https://unrelated.example/", "typed");
    assert.equal(navigation.tabs.get(2).url, searches ? "about:blank" : "https://unrelated.example/", "Search-authorized new tabs reject typed destinations; unselected tabs are never mutated");

    await navigation.commit(1, "https://discord.com/channels/b", "link");
    assert.equal(navigation.tabs.get(1).url, "https://discord.com/channels/b", "Normal links remain usable");
    await navigation.commit(1, "https://unrelated.example/", "typed");
    assert.equal(navigation.tabs.get(1).url, "https://discord.com/channels/b", "Typed arbitrary destinations return to the last committed page");
    await navigation.commit(1, "https://www.google.com/search?q=study", "generated");
    assert.equal(navigation.tabs.get(1).url, searches ? "https://www.google.com/search?q=study" : "https://discord.com/channels/b", "Address-bar searches require Searches");
    if (searches) {
      await navigation.commit(1, "https://unrelated.example/result", "link");
      assert.equal(navigation.tabs.get(1).url, "https://www.google.com/search?q=study", "Search result links stay on results even in a selected tab");
    }
  }

  const commands = createHarness({ active: false }, [
    { id: 61, windowId: 6, index: 0, active: true, url: "https://example.org/" },
    { id: 62, windowId: 6, index: 1, active: false, url: "https://example.com/" }
  ], { withCommandPort: true });
  await commands.ready();
  const initialUpdates = commands.updates.length;
  for (const action of ["activate", "close", "preview"]) {
    for (const invalid of [
      { windowID: 6 },
      { windowID: 6, browserSessionID: "stale-browser-lifetime" },
      { windowID: 99, browserSessionID: commands.browserSessionID() }
    ]) {
      const id = `invalid-${action}-${invalid.windowID}-${invalid.browserSessionID || "missing"}`;
      await commands.command({ action, id, tabID: 62, ...invalid });
      assert.equal(commands.tabs.has(62), true, "A missing/stale/window-mismatched command must never close a current tab");
      assert.equal(commands.tabs.get(61).active, true, "Invalid commands must never activate a reused tab ID");
      if (action === "preview") assert.ok(commands.nativeMessages.some(message => message.preview?.requestID === id && message.preview.error), "Rejected preview replies with an explicit error instead of timing out");
    }
  }
  assert.equal(commands.updates.length, initialUpdates, "Invalid commands perform no tab mutation");
  assert.equal(commands.focusedWindows.length, 0, "Invalid commands never change window focus");
  await commands.command({ action: "activate", tabID: 62, windowID: 6, browserSessionID: commands.browserSessionID() });
  assert.equal(commands.tabs.get(62).active, true, "A current-session command activates the exact current-window target");
  await commands.command({ action: "close", tabID: 62, windowID: 6, browserSessionID: commands.browserSessionID() });
  assert.equal(commands.tabs.has(62), false, "A current-session close command still works for the exact target");
  const mixedTabs = [
    { id: 1, windowId: 1, index: 0, active: true, url: "https://example.org/" },
    { id: 2, windowId: 1, index: 1, active: false, url: "file:///tmp/guide.pdf", highlighted: true },
    { id: 3, windowId: 1, index: 2, active: false, url: "about:newtab", highlighted: true },
    { id: 4, windowId: 1, index: 3, active: false, url: "", highlighted: true },
    { id: 5, windowId: 1, index: 4, active: false, url: "https://example.org/", highlighted: true, pinned: true, discarded: true, cookieStoreId: "firefox-container-4" }
  ];
  const discovery = createHarness({ active: false }, mixedTabs, { withCommandPort: true });
  await discovery.ready();
  const metadata = await discovery.snapshot();
  assert.deepEqual(Array.from(metadata.tabs, tab => tab.id), [1, 2, 3, 4, 5], "Discovery includes local PDF, internal, blank, pinned and discarded actual tabs");
  assert.deepEqual(Array.from(metadata.tabs.filter(tab => tab.highlighted), tab => tab.id), [2, 3, 4, 5], "Native Shift-selected group reaches Intent intact");
  assert.equal(metadata.tabs[4].pinned && metadata.tabs[4].discarded, true);
  assert.equal(metadata.tabs[4].cookieStoreID, "firefox-container-4", "Snapshots retain the browser-reported container identity for same-URL tabs");
  assert.equal(metadata.tabs[0].cookieStoreID, null, "Missing container metadata is not invented");
  assert.equal(metadata.tabs[0].windowFrame.left, 20, "Window geometry identifies same-title browser windows");
  assert.equal(metadata.tabs[0].windowFocused, true, "Browser focus disambiguates overlapping windows");
  {
    const states = new Map([[1, "normal"], [2, "minimized"], [3, "maximized"], [4, "fullscreen"], [5, "hidden"]]);
    const stateTabs = [...states.keys()].map(id => ({id, windowId: id, index: 0, active: true,
      title: "State fixture", url: "https://example.test", windowState: "minimized"}));
    const stateReader = createHarness({active: false}, stateTabs, {withCommandPort: true,
      onWindowQuery: (_query, windows) => windows.map(window => ({...window, state: states.get(window.id)}))});
    await stateReader.ready();
    let stateSnapshot = await stateReader.snapshot();
    assert.deepEqual(Array.from(stateSnapshot.allTabs, tab => tab.windowState),
      ["normal", "minimized", "maximized", "fullscreen", null],
      "Actual Firefox window API states, never tab hints or inferred visibility, reach the snapshot");
    assert.deepEqual(Array.from(stateSnapshot.tabs, tab => tab.windowState), Array.from(stateSnapshot.allTabs, tab => tab.windowState),
      "Allowed and full Firefox snapshots retain identical window readback");
    states.set(2, "normal"); states.delete(3);
    stateSnapshot = await stateReader.snapshot();
    assert.equal(stateSnapshot.allTabs.find(tab => tab.windowID === 2).windowState, "normal",
      "A later actual Firefox restore replaces the earlier minimized readback");
    assert.equal(stateSnapshot.allTabs.find(tab => tab.windowID === 3).windowState, null,
      "Unavailable Firefox state stays unknown rather than preserving an old minimized/maximized value");
    assert.equal(stateReader.focusedWindows.length + stateReader.updates.length + stateReader.removals.length, 0,
      "Window-state reporting cannot change Firefox focus, tabs or visibility");
  }
  await discovery.command({action: "snapshot", id: "firefox-discovery-one", tabID: -1, windowID: -1});
  const requestedDiscovery = discovery.nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1);
  assert.deepEqual(Array.from(requestedDiscovery.snapshotRequestIDs), ["firefox-discovery-one"],
    "Firefox discovery echoes the ID whose full-tab query it performed");
  assert.deepEqual(Array.from((await discovery.snapshot()).snapshotRequestIDs), [], "An ordinary inventory cannot inherit a discovery receipt");
  for (const invalidID of [undefined, "", "x".repeat(257), 12]) {
    await discovery.command({action: "snapshot", id: invalidID, tabID: -1, windowID: -1});
    assert.deepEqual(Array.from(discovery.nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1).snapshotRequestIDs), [],
      "Malformed request IDs cannot earn a discovery receipt");
  }
  const failingDiscoveryOptions = {withCommandPort: true};
  const failingDiscovery = createHarness({active: false}, mixedTabs, failingDiscoveryOptions);
  await failingDiscovery.ready();
  failingDiscoveryOptions.failTabQuery = true;
  await failingDiscovery.command({action: "snapshot", id: "firefox-failed-discovery", tabID: -1, windowID: -1});
  assert.equal(failingDiscovery.nativeMessages.some(message => message.snapshotRequestIDs?.includes("firefox-failed-discovery")), false,
    "A failed tabs query cannot certify an empty profile");
  for (const earlierID of [null, "firefox-earlier-request"]) {
    let holdNextQuery = false, queryStarted, releaseQuery;
    const queryGate = new Promise(resolve => { releaseQuery = resolve; });
    const queryCaptured = new Promise(resolve => { queryStarted = resolve; });
    const overlapping = createHarness({active: false}, mixedTabs, {withCommandPort: true,
      async afterTabQuery() {
        if (holdNextQuery) { holdNextQuery = false; queryStarted(); await queryGate; }
      }});
    await overlapping.ready();
    await new Promise(setImmediate);
    holdNextQuery = true;
    const earlier = earlierID === null ? overlapping.snapshot()
      : overlapping.command({action: "snapshot", id: earlierID, tabID: -1, windowID: -1});
    await queryCaptured;
    overlapping.tabs.set(88, {id: 88, windowId: 1, index: 5, active: false, url: "https://new.example/"});
    await overlapping.command({action: "snapshot", id: "firefox-later-request", tabID: -1, windowID: -1});
    const later = overlapping.nativeMessages.filter(message => message.snapshotRequestIDs?.includes("firefox-later-request")).at(-1);
    assert.ok(later.allTabs.some(tab => tab.id === 88), "The later request owns the inventory queried after it arrived");
    assert.deepEqual(Array.from(later.snapshotRequestIDs), ["firefox-later-request"], "Concurrent requests never borrow each other's receipts");
    releaseQuery();
    await earlier;
    const old = overlapping.nativeMessages.filter(message => message.type === "tabsSnapshot").at(-1);
    assert.equal(old.allTabs.some(tab => tab.id === 88), false, "The earlier query preserves its own captured inventory");
    assert.deepEqual(Array.from(old.snapshotRequestIDs), earlierID === null ? [] : [earlierID],
      "A pre-request query cannot acquire a later request's freshness ID");
  }

  assert.ok(metadata.browserSessionID, "Every snapshot carries a browser-session identity");
  assert.match(metadata.browserProfileID, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, "Snapshots carry a durable UUID profile identity");
  assert.notEqual(metadata.browserProfileID, metadata.browserSessionID, "A profile is separate from its current browser lifetime");
  assert.equal(discovery.storage.intentBrowserProfileID, metadata.browserProfileID, "A published profile UUID was persisted first");
  await discovery.heartbeat();
  assert.ok(discovery.nativeMessages.filter(message => ["getRules", "setGuardEnabled", "heartbeat"].includes(message.type))
    .every(message => message.browserProfileID === metadata.browserProfileID), "Native hello and heartbeat requests identify the same durable profile");
  const secondProfile = createHarness({ active: false }, mixedTabs, { withCommandPort: true });
  const secondMetadata = await secondProfile.snapshot();
  assert.notEqual(secondMetadata.browserProfileID, metadata.browserProfileID, "Separate browser profiles cannot share saved tab descriptors");
  for (const failure of ["failProfileRead", "failProfileWrite", "dropProfileWrite"]) {
    const options = { withCommandPort: true, [failure]: true,
      storage: failure === "failProfileRead" ? {intentBrowserProfileID: metadata.browserProfileID} : {} };
    const unavailable = createHarness({ active: false }, mixedTabs, options);
    assert.equal(await unavailable.snapshot(), undefined, failure + " cannot publish an unverified profile snapshot");
    await unavailable.heartbeat();
    assert.equal(unavailable.browserProfileID(), null, failure + " does not invent a fallback profile");
    assert.ok(unavailable.nativeMessages.every(message => !Object.hasOwn(message, "browserProfileID")), failure + " does not advertise a false durable profile");
    options[failure] = false;
    const recovered = await unavailable.snapshot();
    assert.equal(recovered.browserProfileID, unavailable.storage.intentBrowserProfileID, failure + " recovers only after successful storage");
    if (failure === "failProfileRead") assert.equal(recovered.browserProfileID, metadata.browserProfileID, "A transient read error cannot rotate an existing profile");
    await unavailable.heartbeat();
    assert.equal(unavailable.nativeMessages.filter(message => message.type === "heartbeat").at(-1).browserProfileID,
      recovered.browserProfileID, "Recovered heartbeats update the host with the persisted profile");
  }
  const noCrypto = createHarness({active: false}, mixedTabs, {withCommandPort: true, crypto: {}});
  assert.equal(await noCrypto.snapshot(), undefined, "Missing secure UUID generation cannot invent a profile");
  const persistedNoCrypto = createHarness({active: false}, mixedTabs,
    {withCommandPort: true, crypto: {}, storage: {intentBrowserProfileID: metadata.browserProfileID.toUpperCase()}});
  assert.equal((await persistedNoCrypto.snapshot()).browserProfileID, metadata.browserProfileID, "An existing UUID remains usable and canonical without generation");
  for (const invalidID of ["invalid-profile", "00000000-0000-0000-0000-000000000000", 17]) {
    const invalid = createHarness({active: false}, mixedTabs, {withCommandPort: true, storage: {intentBrowserProfileID: invalidID}});
    const replaced = await invalid.snapshot();
    assert.match(replaced.browserProfileID, /^[0-9a-f-]{36}$/, "Invalid saved profile values are replaced with a persisted UUID");
    assert.equal(replaced.browserProfileID, invalid.storage.intentBrowserProfileID);
  }
  let releaseProfileWrite;
  const profileWriteGate = new Promise(resolve => { releaseProfileWrite = resolve; });
  const waitingProfile = createHarness({active: false}, mixedTabs,
    {withCommandPort: true, beforeProfileWrite: () => profileWriteGate});
  const pendingSnapshots = [waitingProfile.snapshot(), waitingProfile.snapshot(), waitingProfile.heartbeat()];
  await new Promise(setImmediate);
  assert.equal(waitingProfile.nativeMessages.length, 0, "Native startup waits for the durable profile write");
  assert.equal(waitingProfile.profileWrites.length, 1, "Concurrent initialization shares one profile UUID write");
  releaseProfileWrite();
  const [firstWaiting, secondWaiting] = await Promise.all(pendingSnapshots);
  assert.equal(firstWaiting.browserProfileID, secondWaiting.browserProfileID, "Concurrent discovery uses one committed profile UUID");
  assert.equal(waitingProfile.profileWrites.length, 1, "Discovery does not rewrite an established profile UUID");

  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1] }).active, false, "Missing identity cannot authorize a potentially reused tab ID");
  assert.equal(discovery.effectiveRules({ active: true, selectedTabIDs: [1], selectedBrowserSessionID: "previous-browser-session" }).active, false, "Old exact-ID rules cannot target tabs after restart");
  const restartedBrowser = createHarness({ active: false }, mixedTabs, { withCommandPort: true, storage: discovery.storage });
  await restartedBrowser.ready();
  assert.notEqual((await restartedBrowser.snapshot()).browserSessionID, metadata.browserSessionID, "New Firefox background lifetimes cannot reuse staged tab identities");
  assert.equal((await restartedBrowser.snapshot()).browserProfileID, metadata.browserProfileID, "Browser restart preserves durable profile identity while changing the tab lifetime");
  for (const accessMode of ["whitelist", "blacklist"]) {
    const group = createHarness({ active: true, accessMode, selectedTabIDs: [2, 3, 4, 5], allowedWebsites: [], startupWebsites: [], blockTabSwitching: true, blockNavigation: true, blockNewTabs: true }, mixedTabs);
    await group.ready();
    for (const id of [2, 3, 4, 5]) {
      await group.activate(id);
      assert.equal(group.tabs.get(id).active, accessMode === "whitelist", "Every selected group member receives the same allow/block policy, regardless of content");
      assert.equal(group.tabs.has(id), true, "Policy preserves actual selected tabs");
    }
    assert.deepEqual(Array.from(group.tabs.values(), tab => tab.url), mixedTabs.map(tab => tab.url), "Applying the group never rewrites tab URLs");
    if (accessMode === "blacklist") {
      await group.create({ id: 9, windowId: 1, index: 5, active: true, openerTabId: 2, url: "https://child.example/" });
      assert.equal(group.tabs.get(9)?.url, "https://child.example/", "A blocked tab's new child is preserved without closing or URL replacement");
      assert.equal(group.tabs.get(2)?.url, "file:///tmp/guide.pdf", "The original blocked parent is also preserved");
    }
  }

  const selectedOnly = createHarness({
    active: true, accessMode: "whitelist", allowedWebsites: ["example.org/work"],
    startupWebsites: [], selectedTabIDs: [7], blockTabSwitching: true,
    blockNavigation: true, blockNewTabs: true
  }, [
    { id: 7, windowId: 1, index: 0, active: false, url: "https://example.org/work" },
    { id: 8, windowId: 1, index: 1, active: true, url: "https://example.org/work" }
  ]);
  await selectedOnly.refresh();
  assert.equal(selectedOnly.tabs.get(7).active, true, "Starting Quick Focus selects an allowed tab");
  await selectedOnly.activate(8);
  assert.equal(selectedOnly.tabs.get(7).active, true, "Unselected same-URL tabs must not become allowed");
  assert.equal(selectedOnly.tabs.get(8).url, "https://example.org/work", "Existing unselected tabs are preserved");
  selectedOnly.tabs.get(8).windowId = 2;
  selectedOnly.tabs.get(8).active = true;
  await selectedOnly.focusWindow(2);
  assert.equal(selectedOnly.focusedWindows.at(-1), 1, "Window focus must return to a selected tab's window");
  await selectedOnly.create({ id: 9, windowId: 1, active: true, url: "https://example.org/work" });
  assert.equal(selectedOnly.tabs.get(7).active, true, "New tabs cannot bypass selected-tab scope");

  for (const url of ["https://discord.com/channels/1/2", "https://discord.com/channels/1/3", "https://another-site.example/new"]) {
    await selectedOnly.update(7, { url });
    assert.equal(selectedOnly.tabs.get(7).url, url, "Selected tab allows channel changes and cross-site navigation");
    await selectedOnly.activate(8);
    assert.equal(selectedOnly.tabs.get(7).active, true, "Navigation never grants another tab access");
  }

  const lockedRules = {
    active: true,
    startupSessionID: "firefox-startup-session",
    allowedWebsites: ["instagram.com/direct"],
    startupWebsites: [],
    blockTabSwitching: true,
    blockNavigation: true,
    blockNewTabs: true,
    allowGoogleSearchTabs: false
  };
  const startupRules = {
    ...lockedRules,
    startupWebsites: ["https://www.instagram.com/direct/inbox/"]
  };

  const startupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  assert.deepEqual(
    startupHarness.intervals.map(({ delay }) => delay),
    [3000],
    "Firefox should keep only one low-frequency native heartbeat while idle"
  );
  await startupHarness.refresh();
  assert.ok(
    startupHarness.nativeMessages.some((message) =>
      message.extensionVersion === require("../firefox-extension/manifest.json").version &&
      message.extensionCapabilities?.includes("single-startup-launch-v1")
    ),
    "Firefox should identify a startup-safe Browser Guard to the native host"
  );
  assert.equal(
    startupHarness.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Firefox should replace its startup blank with the first allowed website"
  );
  assert.equal(startupHarness.tabs.size, 1, "Firefox startup should not create an extra blank tab");
  await startupHarness.emitUpdated(1, { status: "complete" }, {
    id: 1,
    active: true,
    url: "about:blank"
  });
  assert.equal(
    startupHarness.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "A late completion event from Firefox's replaced blank tab must not interrupt Instagram startup"
  );
  assert.equal(
    startupHarness.storage.completedStartupSessionID,
    startupRules.startupSessionID,
    "Firefox should persist the completed startup session before opening its website"
  );

  const lateFirefoxWindow = createHarness({
    ...startupRules,
    startupSessionID: "firefox-late-window-session"
  }, []);
  await lateFirefoxWindow.refresh();
  await lateFirefoxWindow.create({ id: 1, active: true, url: "about:blank" });
  assert.equal(
    lateFirefoxWindow.tabs.get(1).url,
    "https://www.instagram.com/direct/inbox/",
    "Firefox should spend the one startup launch when its first tab appears late"
  );

  const restartedStartupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "about:blank" }
  ], { storage: startupHarness.storage });
  await restartedStartupHarness.refresh();
  assert.equal(
    restartedStartupHarness.tabs.get(1).url,
    "about:blank",
    "Restarting Firefox Browser Guard must not reopen a completed session website"
  );

  assert.equal(restartedStartupHarness.storage.intentBrowserProfileID, startupHarness.storage.intentBrowserProfileID,
    "Restart preserves profile identity without spending the startup launch twice");
  assert.ok(startupHarness.nativeMessages.filter(message => ["getRules", "setGuardEnabled"].includes(message.type))
    .every(message => message.browserProfileID === startupHarness.storage.intentBrowserProfileID),
    "Firefox one-shot native hello also identifies the durable browser profile");
  const migratedStartup = createHarness(startupRules, [{id: 1, active: true, url: "about:blank"}],
    {storage: {completedStartupSessionID: startupHarness.storage.completedStartupSessionID}});
  await migratedStartup.refresh();
  await migratedStartup.heartbeat();
  assert.equal(migratedStartup.tabs.get(1).url, "about:blank", "Adding a profile UUID to old storage cannot relaunch a completed website");
  assert.equal(migratedStartup.updates.filter(update => update.patch.url).length, 0,
    "Profile migration and heartbeat do not repeat any startup URL navigation");

  const existingStartupHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await existingStartupHarness.refresh();
  assert.equal(existingStartupHarness.tabs.size, 1, "Firefox should not duplicate an open startup website");
  assert.deepEqual(
    existingStartupHarness.reloads,
    [1],
    "Firefox should deliberately load an existing startup tab once instead of trusting a suspended or half-restored page"
  );
  await existingStartupHarness.refresh();
  assert.deepEqual(
    existingStartupHarness.reloads,
    [1],
    "Firefox must not reload an existing startup tab again during the same intention session"
  );

  const existingRootStartupHarness = createHarness({
    ...startupRules,
    startupSessionID: "firefox-existing-root-session",
    allowedWebsites: ["instagram.com"],
    startupWebsites: ["https://www.instagram.com/"]
  }, [
    { id: 1, active: true, url: "https://www.instagram.com/?variant=following", status: "complete" }
  ]);
  await existingRootStartupHarness.refresh();
  assert.equal(existingRootStartupHarness.tabs.size, 1, "A broad website intention should reuse its existing tab");
  assert.equal(
    existingRootStartupHarness.tabs.get(1).url,
    "https://www.instagram.com/",
    "Reused website tabs must navigate to the configured startup URL instead of showing stale content"
  );
  assert.equal(
    existingRootStartupHarness.updates.filter(({ patch }) => patch.url === "https://www.instagram.com/").length,
    1,
    "A reused website tab must load exactly once for the new intention session"
  );

  const concurrentStartupHarness = createHarness({
    ...startupRules,
    startupWebsites: [
      "https://www.instagram.com/direct/inbox/",
      "https://instagram.com/direct/inbox"
    ]
  }, [
    { id: 1, active: true, url: "https://example.com/" }
  ]);
  await concurrentStartupHarness.ready();
  assert.equal(
    Array.from(concurrentStartupHarness.tabs.values()).filter((tab) =>
      tab.url.includes("instagram.com/direct/inbox")
    ).length,
    1,
    "Equivalent Firefox startup URLs must create only one copy of the website"
  );

  const activationHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ]);
  await activationHarness.ready();
  const firefoxRuleRequestsBeforeActivation = activationHarness.nativeMessages.filter(
    (message) => message?.type === "getRules"
  ).length;
  await activationHarness.activate(2);
  assert.equal(activationHarness.tabs.get(1).active, true, "Unallowed tab activation should return to the allowed tab");
  assert.equal(
    activationHarness.nativeMessages.filter((message) => message?.type === "getRules").length,
    firefoxRuleRequestsBeforeActivation,
    "Firefox tab events should enforce cached rules without polling the native host"
  );

  const allowedActivationHarness = createHarness(lockedRules, [
    { id: 1, windowId: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, windowId: 1, active: false, url: "https://www.instagram.com/direct/t/123/" }
  ]);
  await allowedActivationHarness.ready();
  await allowedActivationHarness.activate(2);
  assert.equal(allowedActivationHarness.tabs.get(2).active, true, "Allowed tab activation should stay active");
  await allowedActivationHarness.receiveNative({
    tabCommand: { browserSessionID: allowedActivationHarness.browserSessionID(), tabID: 2, windowID: 1, action: "close" }
  });
  assert.equal(
    allowedActivationHarness.tabs.has(2),
    false,
    "A native cleanup command should close its session-created Firefox tab"
  );

  const navigationHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await navigationHarness.ready();
  await navigationHarness.activate(1);
  await navigationHarness.update(2, { url: "https://www.instagram.com/explore/" });
  assert.equal(navigationHarness.tabs.get(2).url, "https://www.instagram.com/direct/inbox/", "Unallowed navigation should be cancelled before the page changes");
  assert.equal(navigationHarness.tabs.get(1).active, true, "Blocked navigation should return to the allowed tab");

  const redirectHarness = createHarness({
    ...lockedRules,
    startupSessionID: "firefox-outlook-redirect-session",
    allowedWebsites: ["outlook.cloud.microsoft/mail/inbox/id/message"],
    startupWebsites: ["https://outlook.cloud.microsoft/mail/inbox/id/message"]
  }, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  await redirectHarness.refresh();
  await redirectHarness.activate(1);
  const firefoxStartupUpdates = () => redirectHarness.updates.filter(
    ({ patch }) => patch.url === "https://outlook.cloud.microsoft/mail/inbox/id/message"
  ).length;
  assert.equal(firefoxStartupUpdates(), 1, "Firefox should launch an Outlook startup URL once");
  const shellRedirect = await redirectHarness.update(1, {
    url: "https://outlook.cloud.microsoft/mail/"
  });
  assert.equal(shellRedirect?.cancel, undefined, "Outlook's same-host startup shell redirect must load");
  assert.equal(
    redirectHarness.tabs.get(1).url,
    "https://outlook.cloud.microsoft/mail/",
    "Outlook's shell redirect should not leave a partially loaded startup page"
  );
  await redirectHarness.emitUpdated(1, { status: "complete" });
  assert.equal(
    firefoxStartupUpdates(),
    1,
    "An Outlook redirect must never make Firefox reload the startup URL"
  );
  assert.equal(redirectHarness.tabs.size, 1, "An Outlook redirect must never create replacement tabs");
  const laterSameHostEscape = await redirectHarness.update(1, {
    url: "https://outlook.cloud.microsoft/calendar/"
  });
  assert.equal(
    laterSameHostEscape?.cancel,
    true,
    "Same-host navigation outside the configured Outlook path must be blocked after startup settles"
  );

  const crossHostRedirectHarness = createHarness({
    ...lockedRules,
    startupSessionID: "firefox-cross-host-redirect-session",
    allowedWebsites: ["instagram.com"],
    startupWebsites: ["https://www.instagram.com/"]
  }, [
    { id: 1, active: true, url: "about:blank" }
  ]);
  await crossHostRedirectHarness.refresh();
  const crossHostRedirect = await crossHostRedirectHarness.update(1, {
    url: "https://example.com/escape"
  });
  assert.equal(crossHostRedirect?.cancel, true, "Startup grace must not allow cross-site escapes");

  const strictNewTabHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await strictNewTabHarness.ready();
  await strictNewTabHarness.create({ id: 3, active: true, url: "about:newtab" });
  assert.equal(strictNewTabHarness.tabs.has(3), true, "New tabs should always be creatable");
  await strictNewTabHarness.update(3, { url: "https://www.instagram.com/direct/inbox/" });
  await strictNewTabHarness.ready();
  assert.equal(strictNewTabHarness.tabs.has(3), true, "Typing an allowed website in a new tab should work without browser-search permission");
  assert.equal(strictNewTabHarness.tabs.get(3).active, true, "The manually opened allowed website should remain active");

  const strictSearchHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await strictSearchHarness.ready();
  await strictSearchHarness.create({ id: 3, active: true, url: "about:newtab" });
  await strictSearchHarness.update(3, { url: "https://www.google.com/search?q=intent" });
  await strictSearchHarness.ready();
  assert.equal(strictSearchHarness.tabs.has(3), false, "A search submission should close when browser searches are disabled");
  assert.equal(strictSearchHarness.tabs.get(1).active, true, "Closing a blocked search should return to an allowed tab");

  const searchRules = {
    ...lockedRules,
    allowGoogleSearchTabs: true
  };
  const searchHarness = createHarness(searchRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await searchHarness.ready();
  await searchHarness.activate(1);
  await searchHarness.create({ id: 3, active: true, url: "about:newtab" });
  assert.equal(searchHarness.tabs.has(3), true, "Google-search mode should allow a new search staging tab");
  await searchHarness.update(3, { url: "https://www.google.com/search?q=github" });
  assert.equal(searchHarness.tabs.get(3).url, "https://www.google.com/search?q=github", "Google result pages should remain usable");
  await searchHarness.update(3, { url: "https://github.com/" });
  assert.equal(searchHarness.tabs.get(3).url, "https://www.google.com/search?q=github", "Clicking through from Google to an unallowed site should be cancelled before the tab leaves search");

  await searchHarness.remove(3);
  assert.equal(searchHarness.tabs.has(3), false, "Search tabs should remain closable");
  assert.equal(searchHarness.tabs.get(1).active, true, "Closing a search tab should return to an allowed tab");

  const closeAllowedHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" },
    { id: 3, active: false, url: "https://www.instagram.com/direct/t/456/" }
  ]);
  await closeAllowedHarness.ready();
  await closeAllowedHarness.activate(1);
  await closeAllowedHarness.remove(1);
  assert.equal(closeAllowedHarness.tabs.has(1), false, "Allowed tabs should be closable");
  assert.equal(closeAllowedHarness.tabs.get(3).active, true, "Closing an allowed tab should land on another allowed tab, not the next unallowed tab");

  const closeOnlyAllowedHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ]);
  await closeOnlyAllowedHarness.ready();
  await closeOnlyAllowedHarness.activate(1);
  await closeOnlyAllowedHarness.remove(1);
  assert.equal(closeOnlyAllowedHarness.tabs.has(1), false, "The final allowed tab should still be closable");
  assert.equal(
    Array.from(closeOnlyAllowedHarness.tabs.values()).some((tab) =>
      tab.active && tab.url === "https://www.instagram.com/direct/inbox/"
    ),
    false,
    "Closing the final allowed tab must not reopen a website that already started once"
  );

  const closeBrowserHarness = createHarness(startupRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await closeBrowserHarness.ready();
  await closeBrowserHarness.remove(1);
  assert.equal(closeBrowserHarness.tabs.size, 0, "Closing Firefox should not manufacture a recovery tab");

  const typedUrlHarness = createHarness(searchRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" }
  ]);
  await typedUrlHarness.ready();
  await typedUrlHarness.activate(1);
  await typedUrlHarness.create({ id: 4, active: true, url: "about:newtab" });
  await typedUrlHarness.update(4, { url: "https://youtube.com/" });
  assert.equal(typedUrlHarness.tabs.get(4).url, "about:newtab", "Typing an unallowed website should be cancelled before the search tab gets stuck");
  assert.equal(typedUrlHarness.tabs.get(1).active, true, "Blocked typed URL should return to an allowed tab");
  await typedUrlHarness.remove(4);
  assert.equal(typedUrlHarness.tabs.has(4), false, "Blocked search staging tabs should remain closable after a typed URL attempt");

  const blacklistRules = {
    ...lockedRules,
    accessMode: "blacklist",
    allowedWebsites: ["youtube.com"],
    startupWebsites: []
  };
  const blacklistHarness = createHarness(blacklistRules, [
    { id: 1, active: true, url: "https://wikipedia.org/wiki/Focus" },
    { id: 2, active: false, url: "https://youtube.com/watch?v=1" }
  ]);
  await blacklistHarness.ready();
  assert.equal(blacklistHarness.tabs.has(1), true, "Firefox blacklist mode should preserve unlisted websites");
  assert.equal(blacklistHarness.tabs.has(2), true, "Firefox blacklist mode must preserve already-open blocked websites");
  const blockedNavigation = await blacklistHarness.update(1, { url: "https://youtube.com/watch?v=2" });
  assert.equal(blockedNavigation.cancel, true, "Firefox should cancel blacklisted navigation before it commits");
  assert.equal(
    blacklistHarness.tabs.get(1).url,
    "https://wikipedia.org/wiki/Focus",
    "Firefox should retain the last permitted page after blocking navigation"
  );
  const blacklistBlankHarness = createHarness(blacklistRules, [
    { id: 1, active: true, url: "about:newtab" }
  ]);
  await blacklistBlankHarness.ready();
  const blockedFromBlank = await blacklistBlankHarness.update(1, {
    url: "https://youtube.com/watch?v=3"
  });
  await blacklistBlankHarness.ready();
  assert.equal(blockedFromBlank.cancel, true, "Firefox should cancel a blacklisted URL entered in a new tab");
  assert.equal(
    blacklistBlankHarness.tabs.get(1).url,
    "about:newtab",
    "A blacklisted site entered from a fresh Firefox tab should return to a clean tab"
  );

  const markedBlockRules = { ...blacklistRules, selectedTabIDs: [2] };
  const markedBlock = createHarness(markedBlockRules, [
    {id: 1, active: true, url: "https://youtube.com/", windowId: 1},
    {id: 2, active: false, url: "https://youtube.com/", windowId: 1},
    {id: 3, active: false, url: "https://example.org/", windowId: 1}
  ]);
  await markedBlock.ready();
  await markedBlock.activate(2);
  await markedBlock.ready();
  assert.equal(markedBlock.tabs.has(2), true, "Marked blacklist tab is retained");
  assert.equal(markedBlock.tabs.get(2).url, "https://youtube.com/", "Marked blacklist URL is retained");
  assert.equal(markedBlock.tabs.get(1).active, true, "Same-URL unmarked tab stays usable");
  await markedBlock.activate(3);
  await markedBlock.ready();
  assert.equal(markedBlock.tabs.get(3).active, true, "Unmarked tab stays usable");

  const disabledHarness = createHarness(lockedRules, [
    { id: 1, active: true, url: "https://www.instagram.com/direct/inbox/" },
    { id: 2, active: false, url: "https://www.youtube.com/" }
  ], { guardEnabled: false });
  await disabledHarness.activate(2);
  assert.equal(disabledHarness.tabs.get(2).active, true, "Disabled guard should not change active tabs by itself");
  const status = await disabledHarness.message({ type: "getGuardStatus" });
  assert.equal(status.enabled, false, "Popup should report the persisted disabled state");
  await disabledHarness.message({ type: "setGuardEnabled", enabled: true });
  assert.equal(disabledHarness.storage.guardEnabled, true, "Popup toggle should persist the enabled state");
  assert.equal(
    disabledHarness.nativeMessages.some((message) => message?.type === "setGuardEnabled" && message.enabled === true),
    true,
    "Popup toggle should notify the native host"
  );

  const learningHarness = createHarness({ ...lockedRules, active: false }, [
    { id: 9, active: true, title: "OASIS | Curtin University", url: "https://oasis.curtin.edu.au/student" }
  ]);
  await learningHarness.ready();
  assert.equal(
    learningHarness.nativeMessages.some((message) =>
      message?.type === "recordWebsiteVisit" &&
      message.url === "https://oasis.curtin.edu.au" &&
      message.title === "OASIS | Curtin University"
    ),
    true,
    "Firefox should teach Intent a local domain and readable title without sending page paths"
  );
}

(process.env.INTENT_FIREFOX_BOOTSTRAP_ONLY ? nativeProfileBootstrapRegression() : nativeProfileBootstrapRegression().then(run))
  .then(websiteRegression)
  .then(async () => {
    {
    const rapid = createHarness({active:true,accessMode:'whitelist',selectedTabIDs:[501,502],allowedWebsites:[],startupWebsites:[],startupSessionID:'rapid-clicks',blockNavigation:true,blockTabSwitching:true}, [
      {id:501,windowId:1,index:0,active:true,url:'https://example.com/'},
      {id:502,windowId:1,index:1,active:false,url:'https://example.org/'},
      {id:503,windowId:1,index:2,active:false,url:'https://blocked.example/'}
    ]);
    await rapid.ready();
    rapid.updates.length = 0;
    await Promise.all([rapid.activate(503), rapid.activate(502)]);
    assert.equal(rapid.tabs.get(502).active,true,'A delayed blocked-tab recovery cannot undo a newer allowed click');
    assert.equal(rapid.updates.filter(x=>x.patch.active).length,0,'Switching to the allowed tab needs no synthetic activation');
  }
  console.log("Firefox background behavior spec passed");
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

async function websiteRegression() {
  const engine = require("../firefox-extension/website-features.js");
  const active = {active:true,accessMode:"whitelist",selectedTabIDs:[71],allowedWebsites:[],startupWebsites:[],
    startupSessionID:"website-readiness",blockNavigation:true,
    websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["messages"]}}};
  const initial = [{id:71,windowId:1,active:true,url:"https://www.instagram.com/"},
    {id:72,windowId:1,active:false,url:"https://www.instagram.com/"}];
  const reply = m => ({websiteFeatures:true,websiteRequestID:m.websiteRequestID,
    websitePolicyKey:engine.policyKey(m.rules),startupSessionID:m.rules?.startupSessionID || null});
  const baseOptions = {withCommandPort:true};
  {
    let holdRestore=false, restoreEntered, releaseRestore;
    const entered=new Promise(resolve=>restoreEntered=resolve);
    const restoreGate=new Promise(resolve=>releaseRestore=resolve);
    const h=createHarness({active:false},initial,{...baseOptions,
      async onVisibilitySync(current){
        if(!current.active && holdRestore){restoreEntered();await restoreGate;}
      }});
    await h.ready();await h.applyRules(active);
    h.websiteMessages.length=0;h.updates.length=0;h.focusedWindows.length=0;
    holdRestore=true;
    let finished=false;
    const ending=h.applyRules({active:false}).then(()=>{finished=true;});
    await entered;
    for(let i=0;i<24;i++)await Promise.resolve();
    assert.equal(finished,false,"Fixture actually holds native visibility restoration unfinished");
    for(const tab of initial){
      const message=h.websiteMessages.filter(entry=>entry.id===tab.id).at(-1)?.message;
      assert.equal(message?.type,"rulesUpdated","Finish reaches each loaded website while tab restoration is held");
      assert.equal(message.rules.active,false,"Finish releases site DOM rules before parked-tab restoration completes");
    }
    assert.equal(h.focusedWindows.length,0,"Early DOM release does not focus a restored window");
    assert.equal(h.updates.some(update=>update.patch.active===true),false,"Early DOM release does not activate a restored tab");
    const replacement={...active,startupSessionID:"website-replacement",
      websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["stories"]}}};
    const starting=h.applyRules(replacement);
    releaseRestore();await Promise.all([ending,starting]);
    for(let i=0;i<24;i++)await Promise.resolve();
    for(const tab of initial){
      const message=h.websiteMessages.filter(entry=>entry.id===tab.id).at(-1)?.message;
      assert.equal(message.rules.startupSessionID,replacement.startupSessionID,
        "Late inactive restoration cannot overwrite a replacement intention's DOM policy");
      assert.equal(message.rules.active,true);
    }
  }
  {
    let holdQuery=false, holdRestore=false, queryEntered, releaseQuery, restoreEntered, releaseRestore;
    const entered=new Promise(resolve=>queryEntered=resolve);
    const queryGate=new Promise(resolve=>releaseQuery=resolve);
    const restoreStarted=new Promise(resolve=>restoreEntered=resolve);
    const restoreGate=new Promise(resolve=>releaseRestore=resolve);
    const h=createHarness({active:false},initial,{...baseOptions,async afterTabQuery(){
      if(holdQuery){holdQuery=false;queryEntered();await queryGate;}
    },async onVisibilitySync(current){
      if(!current.active && holdRestore){restoreEntered();await restoreGate;}
    }});
    await h.ready();await h.applyRules(active);
    holdQuery=true;holdRestore=true;
    const ending=h.applyRules({active:false});
    await Promise.all([entered,restoreStarted]);
    const replacement={...active,startupSessionID:"website-after-delayed-finish-query"};
    const starting=h.applyRules(replacement);
    assert.equal(h.activeRules().active,false,"Replacement application is still queued behind old restoration");
    const sent=h.websiteMessages.length;
    releaseQuery();for(let i=0;i<24;i++)await Promise.resolve();
    assert.equal(h.websiteMessages.length,sent,
      "An old inactive tab query cannot broadcast after a newer active revision is requested");
    releaseRestore();await Promise.all([ending,starting]);
    for(let i=0;i<24;i++)await Promise.resolve();
    for(const tab of initial){
      assert.equal(h.websiteMessages.filter(entry=>entry.id===tab.id).at(-1).message.rules.startupSessionID,
        replacement.startupSessionID);
    }
  }
  {
    let injections=0, stale=true;
    const h=createHarness({active:false},initial,{...baseOptions,onWebsiteInject(){injections++;},
      websiteReceipt(_id,m){const r=reply(m);if(stale&&m.websiteRequestID){stale=false;r.websitePolicyKey="stale";}return r;}});
    await h.ready();
    await h.applyRules(active);
    assert.ok(injections>0,"Stale/generic receipt cannot certify the current website guard");
    assert.ok(h.nativeMessages.some(m=>m.type==="websitePolicyReady"&&m.appliedWebsitePolicySessionID===active.startupSessionID));
    const msg={type:"routeWebsiteFeature",url:initial[0].url,websitePolicyKey:engine.policyKey(active)};
    h.updates.length=0;
    assert.equal((await h.routeWebsiteFeature(msg,{tab:{id:72},frameId:0})).routed,false,"Unselected tab cannot route itself");
    assert.equal((await h.routeWebsiteFeature(msg,{tab:{id:71},frameId:2})).routed,false,"Subframes cannot drive tab navigation");
    assert.equal((await h.routeWebsiteFeature({...msg,websitePolicyKey:"previous"},{tab:{id:71},frameId:0})).routed,false);
    assert.equal((await h.routeWebsiteFeature(msg,{tab:{id:71},frameId:0})).routed,true);
    assert.equal(h.tabs.get(71).url,"https://www.instagram.com/direct/inbox/");
    assert.equal(h.tabs.get(71).active,true);assert.equal(h.tabs.size,2);
    assert.deepEqual(JSON.parse(JSON.stringify(h.updates)),[{tabId:71,patch:{url:"https://www.instagram.com/direct/inbox/"}}],"Inbox routing only changes the existing tab URL");
    await h.applyRules({active:false});
    assert.equal((await h.routeWebsiteFeature(msg,{tab:{id:71},frameId:0})).routed,false,"Finished session cannot navigate later");
  }
  {
    const h=createHarness({active:false},initial,{...baseOptions,websiteReceipt(_id,m){return {...reply(m),websiteRequestID:"another-request"};}});
    await h.ready();
    await assert.rejects(h.applyRules(active),/current policy/);
    assert.equal(h.nativeMessages.some(m=>m.type==="websitePolicyReady"),false);
  }
  {
    let release;
    const h=createHarness({active:false},initial,{...baseOptions,websiteReceipt(_id,m){
      if(m.websiteRequestID && m.rules.active) return new Promise(resolve=>release=()=>resolve(reply(m)));
      return reply(m);
    }});
    await h.ready();
    const starting=h.applyRules(active);
    for(let i=0;i<120&&!release;i++) await Promise.resolve();
    assert.equal(typeof release,"function");
    assert.equal(h.nativeMessages.some(m=>m.type==="websitePolicyReady"),false,"DOM receipt actually gates readiness");
    const ending=h.applyRules({active:false});release();await starting;await ending;
    assert.equal(h.nativeMessages.some(m=>m.type==="websitePolicyReady"),false,"Late receipt after finish cannot acknowledge old session");
  }
  {
    const h=createHarness({active:false},initial,baseOptions);await h.ready();await h.applyRules(active);
    const request=(url,id=71)=>h.listeners.onBeforeRequest[0]({tabId:id,url,type:"main_frame"});
    assert.equal(request(initial[0].url).redirectUrl,"https://www.instagram.com/direct/inbox/","Initial full-document request redirects without a loaded content script");
    assert.equal(request(initial[0].url,72).cancel,true,"Unselected tab is still blocked");
    assert.equal(request("https://www.instagram.com/accounts/login/").redirectUrl,undefined,"Authentication is not redirected");
    await h.applyRules({...active,selectedTabIDs:null,accessMode:"blacklist",allowedWebsites:["instagram.com/reels"]});
    assert.equal(request("https://www.instagram.com/reels/").cancel,true,"Explicit outer blacklist wins over redirect");
    assert.equal(request(initial[0].url).redirectUrl,"https://www.instagram.com/direct/inbox/");
    await h.applyRules({active:false});assert.equal(request(initial[0].url).redirectUrl,undefined);
  }
  {
    const videoRules={...active,websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:["search"]}}};
    const source="https://www.youtube.com/results?search_query=manual",target="https://www.youtube.com/watch?v=chosen";
    const h=createHarness({active:false},[{...initial[0],url:source}],baseOptions);
    await h.ready();await h.applyRules(videoRules);
    await h.commit(71,target,"link");
    const message={type:"consumeWebsitePlaybackIntent",url:target,websitePolicyKey:engine.policyKey(videoRules)};
    const sender={frameId:0,tab:{...h.tabs.get(71)},url:target};
    assert.equal((await h.message(message,sender)).allowed,true,"Actual background commit and runtime message adapters deliver manual document playback");
    await h.applyRules({active:false});
    assert.equal((await h.message(message,sender)).allowed,false,"Finish clears document playback evidence");
  }
  for(const mode of ["whitelist","blacklist"]) {
    const scoped={...active,selectedTabIDs:null,accessMode:mode,
      allowedWebsites:[mode==="whitelist"?"instagram.com/reels":"instagram.com/direct"]};
    const url=mode==="whitelist"?"https://www.instagram.com/reels/":"https://www.instagram.com/";
    const h=createHarness({active:false},[{...initial[0],url}],baseOptions);await h.ready();await h.applyRules(scoped);
    const outcome=await h.routeWebsiteFeature({url,websitePolicyKey:engine.policyKey(scoped)},{tab:{id:71},frameId:0});
    assert.equal(outcome.routed,false,"Messages routing cannot widen outer "+mode+" URL rules");
    assert.equal(h.tabs.get(71).url,url);
  }
  // Enabled Instagram areas share one fallback contract, including the home
  // shell required by Stories-only. Routing must stay in the existing tab.
  for(const [allowedFeatures,source,destination] of [
    [["stories"],"https://www.instagram.com/reels/","https://www.instagram.com/"],
    [["reels"],"https://www.instagram.com/","https://www.instagram.com/reels/"],
    [["explore"],"https://www.instagram.com/stories/friend/","https://www.instagram.com/explore/"],
    [["messages","stories"],"https://www.instagram.com/reels/","https://www.instagram.com/"]
  ]) {
    const policy={...active,websiteFeaturePolicies:{instagram:{version:1,allowedFeatures}}};
    const h=createHarness({active:false},[{...initial[0],url:source},initial[1]],baseOptions);
    await h.ready();await h.applyRules(policy);
    assert.equal(h.listeners.onBeforeRequest[0]({tabId:71,url:source,type:"main_frame"}).redirectUrl,destination,
      "Firefox's initial request and content routing choose the same enabled area");
    h.updates.length=0;
    const outcome=await h.routeWebsiteFeature({url:source,websitePolicyKey:engine.policyKey(policy)},{tab:{id:71},frameId:0});
    assert.equal(outcome.routed,true,"An enabled Instagram area supplies its native landing shell");
    assert.equal(h.tabs.get(71).url,destination);assert.equal(h.tabs.size,2);
    assert.deepEqual(JSON.parse(JSON.stringify(h.updates)),[{tabId:71,patch:{url:destination}}],"Fallback never opens or activates a tab/window");
    assert.equal((await h.routeWebsiteFeature({url:destination,websitePolicyKey:engine.policyKey(policy)},{tab:{id:71},frameId:0})).routed,false,"Native landing does not loop");
  }
  for(const mode of ["whitelist","blacklist"]) {
    const policy={...active,selectedTabIDs:null,accessMode:mode,
      allowedWebsites:[mode==="whitelist"?"instagram.com/reels":"instagram.com"],
      websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:["stories"]}}};
    const source="https://www.instagram.com/reels/",h=createHarness({active:false},[{...initial[0],url:source}],baseOptions);
    await h.ready();await h.applyRules(policy);
    const result=await h.routeWebsiteFeature({url:source,websitePolicyKey:engine.policyKey(policy)},{tab:{id:71},frameId:0});
    assert.equal(result.routed,false,"Stories fallback cannot reopen an outer-denied home shell");
    assert.equal(h.tabs.get(71).url,source);
  }
  console.log("firefox website background: correlated readiness, cancellation, same-tab inbox and outer restrictions passed");
}
