/* One-shot, inactive website creation. Shared by Firefox and Chrome. */
class IntentTabCreation {
  constructor(api, options) {
    this.api = api; this.options = options; this.cancelled = new Map(); this.queue = Promise.resolve();
  }
  handle(command) {
    for (const [id, expiry] of this.cancelled) if (expiry <= Date.now()) this.cancelled.delete(id);
    if (command?.action === "cancelCreate") {
      if (this.validID(command.id) && command.browserSessionID === this.options.session()) this.cancelled.set(command.id, Date.now() + 15000);
      return Promise.resolve();
    }
    if (command?.action !== "create") return Promise.resolve();
    this.queue = this.queue.then(() => this.create(command), () => this.create(command));
    return this.queue;
  }
  validID(id) { return typeof id === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id); }
  safeURL(value) {
    try {
      if (typeof value !== "string" || value.length > 8192 || /[\s\\]/.test(value)) return null;
      const url = new URL(value);
      return ["http:", "https:"].includes(url.protocol) && url.hostname && !url.username && !url.password ? url.href : null;
    } catch (_) { return null; }
  }
  receipt(command, extra) {
    const receipt = { requestID: command.id, browserSessionID: command.browserSessionID,
      anchorTabID: command.tabID, windowID: command.windowID, url: command.url, ...extra };
    this.options.send({ type: "tabCreateResult", creation: receipt });
    return receipt;
  }
  eligible(command) {
    return !this.cancelled.has(command.id) && this.options.session() === command.browserSessionID
      && !this.options.active() && this.options.enabled() && Number.isFinite(command.expiresAtUnixMS)
      && command.expiresAtUnixMS > Date.now() && command.expiresAtUnixMS <= Date.now() + 15000;
  }
  async create(command) {
    if (!this.validID(command.id) || !Number.isSafeInteger(command.tabID) || command.tabID < 0
        || !Number.isSafeInteger(command.windowID) || command.windowID < 0
        || !this.safeURL(command.url) || typeof command.browserSessionID !== "string"
        || !this.api.storage.session) return;
    const reject = text => this.receipt(command, { error: text });
    if (!this.eligible(command)) return reject("The website request expired, was cancelled, or an intention started. Reopen the picker.");
    const storage = this.api.storage.session;
    const key = "intentWebsiteCreation";
    let journal;
    try { journal = (await storage.get(key))[key] || {}; }
    catch (_) { return reject("Browser Guard could not safely record this request. No tab was created."); }
    const scope = command.browserSessionID + ":" + command.id;
    const fingerprint = JSON.stringify([command.browserSessionID, command.tabID, command.windowID, command.url]);
    const previous = journal[scope];
    if (previous) {
      if (previous.fingerprint !== fingerprint) return reject("This website request no longer matches its original window.");
      if (previous.receipt) { this.options.send({ type: "tabCreateResult", creation: previous.receipt }); return; }
      return reject("This request may already have created a tab. Check the browser tab list before trying again.");
    }
    let anchor, window;
    try { anchor = await this.api.tabs.get(command.tabID); window = await this.api.windows.get(command.windowID); }
    catch (_) { return reject("The selected browser window or tab closed. Reopen the picker."); }
    if (anchor.windowId !== command.windowID || !["normal", "popup"].includes(window.type))
      return reject("The selected tab moved to another window. Reopen its picker.");
    if (this.options.firefox && anchor.cookieStoreId && anchor.cookieStoreId !== "firefox-default" && anchor.cookieStoreId !== "firefox-private")
      return reject("Adding websites to a Firefox container is not supported yet. Open that website in its container, then select the tab.");
    // A persisted claim precedes the effect. A service-worker restart after this
    // point reports uncertainty; it never retries tabs.create.
    journal = Object.fromEntries(Object.entries(journal).filter(([, row]) => Date.now() - row.at < 60000).slice(-63));
    journal[scope] = { fingerprint, at: Date.now() };
    try { await storage.set({ [key]: journal }); }
    catch (_) { return reject("Browser Guard could not safely record this request. No tab was created."); }
    try {
      anchor = await this.api.tabs.get(command.tabID);
      if (!this.eligible(command) || anchor.windowId !== command.windowID) return reject("The browser selection changed. No tab was created.");
      const properties = { url: this.safeURL(command.url), windowId: command.windowID, active: false, openerTabId: command.tabID };
      if (this.options.firefox) properties.discarded = true;
      const tab = await this.api.tabs.create(properties);
      if (!Number.isSafeInteger(tab?.id) || tab.windowId !== command.windowID || tab.active)
        return reject("The browser did not confirm a background tab. Check its tab list before trying again.");
      const receipt = { requestID: command.id, browserSessionID: command.browserSessionID,
        anchorTabID: command.tabID, windowID: command.windowID, url: command.url,
        tab: { id: tab.id, windowID: tab.windowId, index: tab.index ?? 0, title: tab.title || command.url,
          url: tab.url || tab.pendingUrl || command.url, active: false, pinned: Boolean(tab.pinned),
          discarded: Boolean(tab.discarded), highlighted: false,
          windowFrame: {left: window.left, top: window.top, width: window.width, height: window.height},
          windowFocused: Boolean(window.focused) } };
      journal[scope].receipt = receipt;
      // Even if receipt persistence fails, the persisted pre-claim still blocks
      // replay. Return the known tab, but never delete it or refocus its window.
      await storage.set({ [key]: journal }).catch(() => {});
      this.options.send({ type: "tabCreateResult", creation: receipt });
      this.options.snapshot?.();
    } catch (_) { reject("The browser could not confirm the new tab. Check its tab list before trying again."); }
  }
}
if (typeof module !== "undefined") module.exports = IntentTabCreation;
