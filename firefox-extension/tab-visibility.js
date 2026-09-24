/* Reversible, serialized visibility ownership. No user tab is closed or reloaded. */
(function(root) {
  class IntentTabVisibility {
    constructor(api, firefox = false) {
      this.api = api; this.firefox = firefox; this.tail = Promise.resolve();
      this.key = 'intentHiddenWorkspaceV1'; this.state = null; this.recoveredOnce = false;
    }
    sync(rules, allowed) {
      const operation = () => this.reconcile(rules, allowed);
      this.tail = this.tail.then(operation, operation).catch(() => {});
      return this.tail;
    }
    async load() {
      if (this.state) return;
      // Session storage survives a suspended Chrome service worker, but cannot
      // apply recycled tab IDs to an unrelated browser lifetime after restart.
      const store = this.api.storage.session;
      this.state = store ? (await store.get(this.key))[this.key] : null;
      this.state ||= { hidden: [], moved: [], minimized: [], parking: [] };
      this.state.recovered ||= [];
    }
    async save() {
      if (!this.api.storage.session) {
        if (this.firefox && this.api.sessions) return; // Persistent Firefox session markers own recovery.
        throw new Error('Safe visibility storage unavailable');
      }
      try { await this.api.storage.session.set({ [this.key]: this.state }); }
      catch (error) { this.state = null; throw error; }
    }
    async reconcile(rules, allowed) {
      await this.load();
      if (!rules.active || !rules.hideDistractions) {
        if (this.recoveredOnce && !this.state.hidden.length && !this.state.moved.length && !this.state.minimized.length && !this.state.parking.length) return;
        await this.restore(); this.recoveredOnce = true; return;
      }
      this.recoveredOnce = false;
      if (!this.api.storage.session && !(this.firefox && this.api.sessions)) return;
      const policy = JSON.stringify([rules.startupSessionID, rules.accessMode, rules.selectedTabIDs, rules.allowedWebsites]);
      if (this.state.policy && this.state.policy !== policy) await this.restore();
      this.state.policy = policy;
      const tabs = await this.api.tabs.query({});
      const windows = await this.api.windows.getAll({populate: false});
      const parked = new Set(this.state.parking);
      const moved = new Set(this.state.moved.map(x => x.id));
      const byWindow = new Map();
      for (const tab of tabs) {
        if (parked.has(tab.windowId) || moved.has(tab.id)) continue;
        if (!byWindow.has(tab.windowId)) byWindow.set(tab.windowId, []);
        byWindow.get(tab.windowId).push(tab);
      }
      for (const id of this.state.parking) {
        await this.api.windows.update(id, {state: 'minimized'}).catch(() => {});
      }
      for (const [windowId, group] of byWindow) {
        const window = windows.find(w => w.id === windowId);
        if (!window || window.type !== 'normal' || window.incognito) continue;
        const blocked = group.filter(t => !allowed(t));
        if (!blocked.length) continue;
        const permitted = group.filter(allowed);
        if (!permitted.length) {
          if (window.state !== 'minimized') {
            if (!this.state.minimized.some(x => x.id === windowId)) {
              this.state.minimized.push({id: windowId, state: window.state || 'normal'});
              await this.save();
            }
            if (this.firefox && this.api.sessions?.setWindowValue) await this.api.sessions.setWindowValue(windowId, this.key, {state: window.state || 'normal'});
            await this.api.windows.update(windowId, {state: 'minimized'});
          }
          continue;
        }
        if (blocked.some(t => t.active)) await this.api.tabs.update(permitted[0].id, {active: true});
        if (this.firefox && this.api.tabs.hide) {
          for (const tab of blocked) {
            // Firefox forbids hiding pinned/capturing tabs. Existing enforcement
            // remains the fallback; never unpin or interrupt a call to hide it.
            if (tab.hidden || tab.pinned || tab.sharingState?.screen || tab.sharingState?.camera || tab.sharingState?.microphone) continue;
            if (!this.state.hidden.includes(tab.id)) { this.state.hidden.push(tab.id); await this.save(); }
            if (!this.api.sessions?.setTabValue) continue;
            await this.api.sessions.setTabValue(tab.id, this.key, true);
            await this.api.tabs.hide(tab.id).catch(() => {});
          }
        } else if (!this.firefox) {
          const candidates = blocked.filter(t => !t.pinned && (t.groupId == null || t.groupId < 0) && (t.splitViewId == null || t.splitViewId < 0));
          if (!candidates.length) continue;
          let parking = this.state.parking.find(id => windows.some(w => w.id === id));
          if (parking == null) {
            const made = await this.api.windows.create({url: this.api.runtime.getURL('parked.html'), focused: false, state: 'minimized'});
            parking = made.id; this.state.parking.push(parking); await this.save();
          }
          for (const tab of candidates.sort((a,b) => a.index - b.index)) {
            if (!this.state.moved.some(x => x.id === tab.id)) {
              this.state.moved.push({id: tab.id, windowId, index: tab.index, parking});
              await this.save(); // Write intent before the move, including crash recovery.
            }
            await this.api.tabs.move(tab.id, {windowId: parking, index: -1}).catch(() => {});
          }
          await this.api.windows.update(parking, {state: 'minimized'}).catch(() => {});
        }
      }
    }
    async restore() {
      // Firefox session values follow the real tab/window across browser restarts.
      if (this.firefox && this.api.sessions) {
        for (const tab of await this.api.tabs.query({})) {
          if (!await this.api.sessions.getTabValue(tab.id, this.key).catch(() => false)) continue;
          try {
            if (tab.hidden) await this.api.tabs.show(tab.id);
            await this.api.sessions.removeTabValue(tab.id, this.key);
          } catch (_) { /* Keep the ownership marker for a later retry. */ }
        }
        for (const window of await this.api.windows.getAll({populate: false})) {
          const owned = await this.api.sessions.getWindowValue(window.id, this.key).catch(() => null);
          if (!owned) continue;
          try {
            if (window.state === 'minimized') await this.api.windows.update(window.id, {state: owned.state, focused: false});
            await this.api.sessions.removeWindowValue(window.id, this.key);
          } catch (_) { /* Keep the ownership marker for a later retry. */ }
        }
      }
      // Browser restart discards session-scoped IDs. Recognize only our holding
      // page and reveal its window, never guess identities from a user's URLs.
      if (!this.firefox) {
        for (const tab of await this.api.tabs.query({})) {
          if (tab.url !== this.api.runtime.getURL('parked.html') || this.state.parking.includes(tab.windowId) || this.state.recovered.includes(tab.windowId)) continue;
          try {
            await this.api.windows.update(tab.windowId, {state: 'normal', focused: false});
            this.state.recovered.push(tab.windowId); await this.save();
          } catch (_) { /* Retry next heartbeat if the browser is busy. */ }
        }
      }
      for (const id of [...this.state.hidden]) {
        const tab = await this.api.tabs.get(id).catch(() => null);
        if (tab?.hidden) { try { await this.api.tabs.show(id); } catch (_) { continue; } }
        this.state.hidden = this.state.hidden.filter(x => x !== id); await this.save();
      }
      for (const item of [...this.state.moved].sort((a,b) => a.windowId - b.windowId || a.index - b.index)) {
        const tab = await this.api.tabs.get(item.id).catch(() => null);
        if (tab && tab.windowId === item.parking) {
          try { await this.api.tabs.move(item.id, {windowId: item.windowId, index: item.index}); }
          catch (_) {
            // The user may have closed the original window. Keep their live
            // tab intact and make the holding window visible for recovery.
            await this.api.windows.update(item.parking, {state: 'normal', focused: false}).catch(() => {});
            if (await this.api.windows.get(item.windowId).catch(() => null)) continue;
            // Original window is gone: relinquish ownership of the recovered tabs.
            this.state.recovered.push(item.parking);
          }
        }
        this.state.moved = this.state.moved.filter(x => x.id !== item.id); await this.save();
      }
      for (const item of [...this.state.minimized]) {
        const window = await this.api.windows.get(item.id).catch(() => null);
        if (window?.state === 'minimized') {
          try { await this.api.windows.update(item.id, {state: item.state, focused: false}); } catch (_) { continue; }
        }
        this.state.minimized = this.state.minimized.filter(x => x.id !== item.id); await this.save();
      }
      for (const id of [...this.state.parking]) {
        const tabs = await this.api.tabs.query({windowId: id}).catch(() => []);
        // Close only our own empty holding page, never a user's tab/window.
        if (tabs.length === 1 && tabs[0].url === this.api.runtime.getURL('parked.html')) await this.api.tabs.remove(tabs[0].id).catch(() => {});
        else if (tabs.length) await this.api.windows.update(id, {state: 'normal', focused: false}).catch(() => {});
        if (!this.state.moved.some(x => x.parking === id)) this.state.parking = this.state.parking.filter(x => x !== id);
        await this.save();
      }
    }
  }
  root.IntentTabVisibility = IntentTabVisibility;
  if (typeof module !== 'undefined') module.exports = IntentTabVisibility;
})(globalThis);
