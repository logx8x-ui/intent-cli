/* Profile-owned native website finder. Never mutates an existing browser window. */
class IntentNativeFinder {
  constructor(api, options) {
    this.api = api; this.options = options; this.queue = Promise.resolve(); this.cancelled = new Set();
  }
  validID(value) { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value); }
  valid(command) {
    const owned = Number.isSafeInteger(command?.finderWindowID) && command.finderWindowID >= 0 && command.finderWindowID !== command.windowID
      && Number.isSafeInteger(command?.finderTabID) && command.finderTabID >= 0 && command.finderTabID !== command.anchorTabID;
    const noOwned = command?.finderWindowID == null && command?.finderTabID == null;
    return (command?.action === "open" ? noOwned : command?.action === "commit" ? owned : owned || noOwned) && command && this.validID(command.id) && this.validID(command.finderID)
      && ["open", "commit", "cancel"].includes(command.action)
      && command.browserSessionID === this.options.session()
      && Number.isSafeInteger(command.windowID) && command.windowID >= 0
      && Number.isSafeInteger(command.anchorTabID) && command.anchorTabID >= 0
      && Number.isFinite(command.expiresAtUnixMS) && command.expiresAtUnixMS > Date.now()
      && command.expiresAtUnixMS <= Date.now() + 15000;
  }
  eligible(command) { return this.valid(command) && !this.options.active() && this.options.enabled(); }
  handle(command) {
    if (!this.valid(command)) return Promise.resolve();
    if (command.action === "cancel") this.cancelled.add(command.finderID);
    this.queue = this.queue.then(() => this.perform(command), () => this.perform(command));
    return this.queue;
  }
  send(command, extra) {
    const result = { requestID: command.id, finderID: command.finderID, action: command.action,
      browserSessionID: command.browserSessionID, originalWindowID: command.windowID,
      anchorTabID: command.anchorTabID, ...extra };
    this.options.send({ type: "nativeFinderResult", finder: result }); return result;
  }
  sameOwner(record, command) {
    return record.session === command.browserSessionID && record.originalWindowID === command.windowID && record.anchorTabID === command.anchorTabID;
  }
  safeURL(value) {
    if (typeof value !== "string" || value.length > 8192 || /[\s\\]/.test(value)) return false;
    try { const url = new URL(value); return ["http:", "https:"].includes(url.protocol) && url.hostname && !url.username && !url.password; }
    catch (_) { return false; }
  }
  async perform(command) {
    const reject = error => this.send(command, { error });
    if (!this.api.storage?.session) return reject("Update Browser Guard before opening a website finder.");
    let journal;
    const save = () => this.api.storage.session.set({ intentNativeFinders: journal });
    try { journal = (await this.api.storage.session.get("intentNativeFinders")).intentNativeFinders || {}; }
    catch (_) { return reject("Browser Guard could not safely record this finder. Nothing was changed."); }
    const key = command.browserSessionID + ":" + command.finderID;
    let record = journal[key];
    if (record && (command.finderWindowID != null || command.finderTabID != null)
      && (record.windowID !== command.finderWindowID || record.tabID !== command.finderTabID))
      return reject("The finder tab identity changed. No tab was moved or closed.");
    if (record && !this.sameOwner(record, command)) return reject("The finder no longer belongs to this browser window.");
    const fingerprint = JSON.stringify(command);
    const previous = record?.requests?.[command.id];
    if (previous) {
      if (previous.fingerprint !== fingerprint) return reject("The finder request changed. No action was repeated.");
      if (previous.receipt) { this.options.send({ type: "nativeFinderResult", finder: previous.receipt }); return; }
      return reject("The browser may already have handled this request. Check its windows; Intent will not repeat it.");
    }
    if (command.action !== "cancel" && (!this.eligible(command) || this.cancelled.has(command.finderID)))
      return reject("The finder was cancelled, disconnected, or an intention started.");
    if (command.action === "open" && record) return reject("This finder already exists. No second window was opened.");
    if (!record) {
      if (command.action === "commit") return reject("This finder is no longer available.");
      if (Object.keys(journal).length >= 512) return reject("Too many finder records. Restart the browser before opening another finder.");
      record = journal[key] = { session: command.browserSessionID, originalWindowID: command.windowID,
        anchorTabID: command.anchorTabID, state: "opening", requests: {} };
    }
    if (Object.keys(record.requests).length >= 128) return reject("Close this finder and open it again.");
    record.requests[command.id] = { fingerprint };
    try { await save(); }
    catch (_) { return reject("Browser Guard could not safely record this request. Nothing was changed."); }
    const finish = async extra => {
      const receipt = { requestID: command.id, finderID: command.finderID, action: command.action,
        browserSessionID: command.browserSessionID, originalWindowID: command.windowID, anchorTabID: command.anchorTabID, ...extra };
      record.requests[command.id].receipt = receipt;
      await save().catch(() => {}); // Durable pre-claim still prevents replay if acknowledgement persistence fails.
      this.options.send({ type: "nativeFinderResult", finder: receipt }); this.options.snapshot?.();
    };
    try {
      if (command.action === "cancel") {
        if (["cancelled", "committed"].includes(record.state)) return finish({});
        record.state = "cancelled"; await save();
        // Only the original new tab is owned. Never remove a window, a moved
        // tab, or any extra tabs the user placed into the finder window.
        if (Number.isSafeInteger(record.tabID) && Number.isSafeInteger(record.windowID)) {
          const tab = await this.api.tabs.get(record.tabID).catch(() => null);
          if (tab?.windowId === record.windowID && command.browserSessionID === this.options.session()) {
            await this.api.tabs.remove(record.tabID);
          }
        }
        return finish({});
      }
      const anchor = await this.api.tabs.get(command.anchorTabID);
      const original = await this.api.windows.get(command.windowID);
      if (anchor.windowId !== command.windowID || original.type !== "normal")
        return finish({ error: "The original normal browser window changed or closed." });
      if (this.options.firefox && anchor.cookieStoreId && !["firefox-default", "firefox-private"].includes(anchor.cookieStoreId))
        return finish({ error: "Open this website in its Firefox container first, then select that tab in Intent." });
      if (command.action === "open") {
        const frame = command.frame;
        if (!frame || ![frame.left, frame.top, frame.width, frame.height].every(Number.isFinite)
          || frame.width < 480 || frame.width > 1600 || frame.height < 360 || frame.height > 1200)
          return finish({ error: "The finder size is unavailable. Open Intent on this display again." });
        if (!this.eligible(command) || this.cancelled.has(command.finderID)) return finish({ error: "The finder was cancelled before opening." });
        const created = await this.api.windows.create({ type: "normal", state: "normal", focused: true,
          incognito: Boolean(original.incognito), left: Math.round(frame.left), top: Math.round(frame.top),
          width: Math.round(frame.width), height: Math.round(frame.height) });
        const tabs = created?.tabs || (Number.isSafeInteger(created?.id) ? await this.api.tabs.query({ windowId: created.id }) : []);
        if (!Number.isSafeInteger(created?.id) || tabs.length !== 1 || !Number.isSafeInteger(tabs[0]?.id))
          return finish({ error: "The browser opened a window but did not confirm its ownership. Keep it open and check your windows." });
        record.windowID = created.id; record.tabID = tabs[0].id; record.state = "open";
        await save();
        if (this.cancelled.has(command.finderID)) {
          const tab = await this.api.tabs.get(record.tabID).catch(() => null);
          if (tab?.windowId === record.windowID) await this.api.tabs.remove(record.tabID);
          record.state = "cancelled";
          return finish({ error: "Website finder cancelled." });
        }
        if (!this.eligible(command)) return finish({ error: "The browser changed while opening. Cancel the finder to return to Intent." });
        return finish({ windowID: record.windowID, tabID: record.tabID,
          frame: { left: created.left, top: created.top, width: created.width, height: created.height } });
      }
      if (record.state !== "open") return finish({ error: "This finder has already finished. No tab was moved." });
      const tab = await this.api.tabs.get(record.tabID);
      const source = await this.api.windows.get(record.windowID);
      if (tab.windowId !== record.windowID || source.type !== "normal" || source.incognito !== original.incognito)
        return finish({ error: "The finder tab moved or its privacy context changed. No tab was moved." });
      if (!tab.active) return finish({ error: "Select the original finder tab, then choose Add to intention." });
      if (!this.safeURL(tab.url)) return finish({ error: "Open a website first, then choose Add to intention." });
      const before = await this.api.tabs.query({ windowId: command.windowID });
      const active = before.find(item => item.active);
      const highlightedIDs = before.filter(item => item.highlighted).map(item => item.id);
      if (!active || !highlightedIDs.includes(active.id) || typeof this.api.tabs.highlight !== "function")
        return finish({ error: "The browser cannot safely preserve the original tab selection." });
      if (!this.eligible(command) || this.cancelled.has(command.finderID)) return finish({ error: "The finder was cancelled before adding." });
      // A persisted commit claim precedes the move. A restart cannot replay it.
      record.state = "committing"; await save();
      if (!this.eligible(command) || this.cancelled.has(command.finderID)) { record.state = "open"; return finish({ error: "The finder was cancelled before adding." }); }
      const fresh = await this.api.tabs.get(record.tabID);
      if (fresh.windowId !== record.windowID || !fresh.active || !this.safeURL(fresh.url)) { record.state = "open"; return finish({ error: "The finder tab changed. Check it before adding." }); }
      if (!this.eligible(command) || this.cancelled.has(command.finderID)) { record.state = "open"; return finish({ error: "The finder was cancelled before adding." }); }
      await this.api.tabs.move(record.tabID, { windowId: command.windowID, index: -1 });
      record.state = "committed"; await save();
      const after = await this.api.tabs.query({ windowId: command.windowID });
      const nowActive = after.find(item => item.active);
      const nowHighlighted = after.filter(item => item.highlighted).map(item => item.id);
      const expected = new Set([...highlightedIDs, record.tabID]);
      const originalGroup = nowHighlighted.length === highlightedIDs.length && highlightedIDs.every(id => nowHighlighted.includes(id));
      const movedOnly = nowHighlighted.length === 1 && nowHighlighted[0] === record.tabID;
      const originalWithMoved = nowHighlighted.length === expected.size && nowHighlighted.every(id => expected.has(id));
      if (this.eligible(command) && !this.cancelled.has(command.finderID)
          && nowActive && [active.id, record.tabID].includes(nowActive.id) && (originalGroup || movedOnly || originalWithMoved)
          && highlightedIDs.every(id => after.some(item => item.id === id))) {
        const ordered = [active.id, ...highlightedIDs.filter(id => id !== active.id)];
        await this.api.tabs.highlight({ windowId: command.windowID, tabs: ordered.map(id => after.find(item => item.id === id).index) });
      }
      const moved = await this.api.tabs.get(record.tabID);
      if (moved.windowId !== command.windowID) return finish({ error: "The website was moved again. Check its tab list before selecting it." });
      return finish({ windowID: command.windowID, tabID: moved.id, tab: {
        id: moved.id, windowID: moved.windowId, index: moved.index, title: (moved.title || moved.url).slice(0, 2048),
        url: moved.url, active: Boolean(moved.active), highlighted: Boolean(moved.highlighted),
        pinned: Boolean(moved.pinned), discarded: Boolean(moved.discarded)
      } });
    } catch (_) {
      return finish({ error: "The browser could not confirm this finder action. Check its windows; Intent will not repeat an uncertain action." });
    }
  }
}
if (typeof module !== "undefined") module.exports = IntentNativeFinder;
