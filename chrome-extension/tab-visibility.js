/* Reversible, serialized visibility ownership. No user tab is closed or reloaded. */
(function(root) {
  class IntentTabVisibility {
    constructor(api, firefox = false, nativeOwner = null) {
      this.api = api; this.firefox = firefox; this.tail = Promise.resolve();
      this.nativeOwner = nativeOwner;
      this.desiredRules = null; this.bootstrapPolicy = null; this.lastNativeClaims = [];
      this.key = 'intentHiddenWorkspaceV1'; this.state = null; this.recoveredOnce = false;
      this.shadowKey = 'intentNativeVisibilityLedgerV1';
    }
    sync(rules, allowed) {
      this.desiredRules = rules;
      const operation = () => this.reconcile(rules, allowed);
      this.tail = this.tail.then(operation, operation).catch(() => {});
      return this.tail;
    }
    syncInitial(rules, initiallyAllowed, subsequentlyAllowed) {
      this.desiredRules = rules;
      const operation = async () => {
        await this.load();
        if (this.state.initialSession === rules.startupSessionID) {
          return this.reconcile(rules, subsequentlyAllowed);
        }
        // A native ownership receipt can take several heartbeats. Freeze the
        // original inventory so retrying setup does not hide a user's later opens.
        if (this.state.initialPending?.sessionID !== rules.startupSessionID) {
          this.state.initialPending = {sessionID: rules.startupSessionID,
            tabIDs: (await this.api.tabs.query({})).map(tab => tab.id)};
          await this.save();
        }
        const initialIDs = new Set(this.state.initialPending.tabIDs);
        if (await this.reconcile(rules, tab => !initialIDs.has(tab.id) || initiallyAllowed(tab)) === false) return;
        if (rules.nativeWindowVisibility) {
          const verified = new Set(this.nativeOwner?.verifiedWindowIDs?.(rules.startupSessionID) || []);
          if (this.lastNativeClaims.some(id=>!verified.has(id))) return;
        }
        this.state.initialSession = rules.startupSessionID;
        this.state.initialPending = null;
        await this.save();
      };
      this.tail = this.tail.then(operation, operation).catch(() => {});
      return this.tail;
    }
    async load() {
      if (this.state) { await this.recoverChromeHolders(); return; }
      // Session storage survives a suspended Chrome service worker, but cannot
      // apply recycled tab IDs to an unrelated browser lifetime after restart.
      const store = this.api.storage.session;
      this.state = store ? (await store.get(this.key))[this.key] : null;
      if (!this.state && !this.firefox && this.api.storage.local) {
        const saved = (await this.api.storage.local.get(this.shadowKey))[this.shadowKey];
        if (saved?.version === 1 && saved.state?.nativeParkingProofs?.length) {
          const identity = this.verifiedNativeIdentity();
          if (!identity) throw new Error('Waiting for verified native recovery identity');
          if (this.sameProcess(identity.processIdentity, saved.identity?.processIdentity)) {
            // Extension updates may clear session storage without restarting the
            // browser. Numeric IDs remain valid only in this verified process.
            this.state = saved.state;
          } else {
            // Across a process restart, use only our durable random holder token.
            // Never apply old numeric tab/window IDs to a new browser lifetime.
            this.state = {hidden: [], moved: [], minimized: [], parking: [], nativeReveals: [],
              nativeParkingProofs: [], nativeBrowserIdentity: saved.identity};
            for (const proof of saved.state.nativeParkingProofs) {
              if (!this.validParkingProof(proof)) continue;
              this.state.nativeSessionID ||= proof.intentionSessionID;
              this.state.nativeParkingProofs.push({...proof, windowID: null});
            }
          }
        }
      }
      this.state ||= { hidden: [], moved: [], minimized: [], parking: [] };
      this.state.recovered ||= [];
      this.state.groups ||= [];
      this.state.orders ||= [];
      this.state.nativeReveals ||= [];
      this.state.nativeParkingProofs ||= [];
      await this.recoverChromeHolders();
    }
    async recoverChromeHolders() {
      if (this.firefox || !this.state?.nativeParkingProofs?.some(proof => proof.windowID == null)) return;
      const tabs = await this.api.tabs.query({});
      for (const proof of this.state.nativeParkingProofs) {
        if (proof.windowID != null || !this.validParkingProof(proof)) continue;
        const holders = tabs.filter(tab => this.parkingNonce(tab.url) === proof.nonce);
        // Session windows can restore after extension startup. Keep the proof
        // for a later heartbeat; duplicated tokens are ambiguous, not authority.
        if (holders.length !== 1) continue;
        proof.windowID = holders[0].windowId;
        if (!this.state.parking.includes(proof.windowID)) this.state.parking.push(proof.windowID);
        if (!this.state.nativeReveals.some(item => item.windowID === proof.windowID))
          this.state.nativeReveals.push({windowID: proof.windowID, sessionID: proof.intentionSessionID});
      }
    }
    async save() {
      if (!this.api.storage.session) {
        if (this.firefox && this.api.sessions) return; // Persistent Firefox session markers own recovery.
        throw new Error('Safe visibility storage unavailable');
      }
      try {
        if (!this.firefox && this.api.storage.local) {
          this.state.nativeParkingProofs = this.state.nativeParkingProofs.filter(proof =>
            proof.windowID == null || this.state.parking.includes(proof.windowID) || this.state.nativeReveals.some(item => item.windowID === proof.windowID)
              || this.state.moved.some(item => item.parking === proof.windowID));
          if (this.state.nativeParkingProofs.length && this.state.nativeBrowserIdentity) {
            // Durable before every tab move. A session-store reset must not lose
            // either the return order or the proof that a holder belongs to us.
            await this.api.storage.local.set({[this.shadowKey]: {version: 1,
              identity: this.state.nativeBrowserIdentity, state: this.state}});
          } else await this.api.storage.local.remove(this.shadowKey);
        }
        await this.api.storage.session.set({ [this.key]: this.state });
      }
      catch (error) { this.state = null; throw error; }
    }
    async reconcile(rules, allowed) {
      await this.load();
      if (!rules.active || !rules.hideDistractions) {
        this.bootstrapPolicy = null; this.lastNativeClaims = [];
        // The native closure ledger outlives our tab state and extension reloads.
        void Promise.resolve(this.nativeOwner?.retireClosedWindows?.()).catch(() => {});
        if (this.recoveredOnce && !this.state.hidden.length && !this.state.moved.length && !this.state.minimized.length && !this.state.parking.length && !this.state.groups.length && !this.state.orders.length && !this.state.nativeReveals.length) return;
        await this.restore(); this.state.initialSession = null; this.state.initialPending = null; await this.save(); this.recoveredOnce = true; return;
      }
      this.recoveredOnce = false;
      if (!this.api.storage.session && !(this.firefox && this.api.sessions)) return;
      if (rules.nativeWindowVisibility && (typeof rules.startupSessionID !== 'string' || !rules.startupSessionID)) return false;
      // A negotiated native owner remains exclusive through transport outages.
      // Restore older JS ownership before adopting it; never discard recovery
      // metadata merely because a newer host is available.
      if (rules.nativeWindowVisibility && this.state.nativeSessionID !== rules.startupSessionID) {
        await this.restore();
        if (await this.hasLegacyWindowOwnership()) return false;
        if (this.state.hidden.length || this.state.moved.length || this.state.parking.length || this.state.groups.length || this.state.orders.length) return false;
        if (this.state.nativeReveals.length) return false;
        this.state.nativeSessionID = rules.startupSessionID;
        await this.save();
      } else if (!rules.nativeWindowVisibility && this.state.nativeSessionID && this.state.nativeSessionID !== rules.startupSessionID) {
        // A later session may use an older host. Finish the prior native
        // workspace before giving newly created parking windows legacy ownership.
        await this.restore();
        if (this.state.nativeReveals.length || this.state.moved.length || this.state.parking.length) return false;
        this.state.nativeSessionID = null;
        await this.save();
      }
      const native = Boolean(this.state.nativeSessionID && this.state.nativeSessionID === rules.startupSessionID);
      const policy = JSON.stringify([rules.startupSessionID, rules.accessMode, rules.selectedTabIDs, rules.allowedWebsites]);
      if (this.state.policy && this.state.policy !== policy) await this.restore();
      this.state.policy = policy;
      const tabs = await this.api.tabs.query({});
      const windows = await this.api.windows.getAll({populate: false});
      const parked = new Set(this.state.parking);
      const moved = new Set(this.state.moved.filter(x => tabs.some(t => t.id === x.id && t.windowId === x.parking)).map(x => x.id));
      const byWindow = new Map();
      for (const tab of tabs) {
        if (parked.has(tab.windowId) || moved.has(tab.id)) continue;
        if (!byWindow.has(tab.windowId)) byWindow.set(tab.windowId, []);
        byWindow.get(tab.windowId).push(tab);
      }
      const nativeWindows = native ? [...byWindow].flatMap(([id, group]) => {
        const window = windows.find(w => w.id === id);
        return window?.type === 'normal' && !group.some(allowed) ? [this.windowDescriptor(window, group)] : [];
      }) : [];
      this.lastNativeClaims = nativeWindows.map(window=>window.windowID);
      // Keep the exact initial Add-as-you-go classifier until native confirms
      // the initial hiding. This validator never waits for our serialized tail.
      this.bootstrapPolicy = native ? {rules,allowed,windowIDs:new Set(this.lastNativeClaims),
        key:JSON.stringify([rules,this.state.initialSession===rules.startupSessionID?'runtime':'initial',this.state.initialPending?.tabIDs||null])} : null;
      // Acceptance records parking identities before a user's tab can enter
      // them. A failed/ambiguous receipt must never switch to browser ownership.
      if (native && !await this.publishNativePlan(rules, nativeWindows)) return false;
      const nativeIdentity = native ? this.verifiedNativeIdentity() : null;
      if (native && !nativeIdentity) return false;
      if (native && !this.firefox && !this.api.storage.local) return false;
      if (native) { this.state.nativeBrowserIdentity = nativeIdentity; await this.save(); }
      await this.repairParkingPins(tabs);
      for (const id of this.state.parking) {
        await this.api.windows.update(id, {state: 'minimized'}).catch(() => {});
      }
      for (const [windowId, group] of byWindow) {
        const window = windows.find(w => w.id === windowId);
        if (!window || window.type !== 'normal') continue;
        const blocked = group.filter(t => !allowed(t));
        if (!blocked.length) continue;
        const permitted = group.filter(allowed);
        if (!permitted.length) {
          if (native) continue;
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
        // Move distractions out of the working window in both browsers.
        // tabs.hide is still visible in third-party sidebars such as Sidebery.
        // Preserve hidden tabs owned by other extensions, plus split pairs whose
        // other member is allowed (moving one can also move its allowed partner).
        let candidates = blocked.filter(t => !t.hidden && (t.splitViewId == null || t.splitViewId < 0 ||
          group.filter(other => other.splitViewId === t.splitViewId).every(other => !allowed(other))));
        if (!candidates.length) continue;
        let parking = this.state.parking.find(id => windows.some(w => w.id === id && Boolean(w.incognito) === Boolean(window.incognito)));
        if (parking == null) {
          const nonce = native && !this.firefox ? this.newParkingNonce() : null;
          const made = await this.api.windows.create({url: this.api.runtime.getURL('parked.html') + (nonce ? '#intent-' + nonce : ''), focused: false, state: 'minimized', incognito: Boolean(window.incognito)});
          parking = made.id; this.state.parking.push(parking);
          if (nonce) this.state.nativeParkingProofs.push({nonce, windowID: parking, intentionSessionID: rules.startupSessionID,
            previousBrowserSessionID: nativeIdentity.browserSessionID, previousProcessIdentity: {...nativeIdentity.processIdentity},
            windowIDs: [parking]});
          await this.save();
          if (native && !await this.publishNativePlan(rules, nativeWindows)) return false;
        }
        let sourceToken = null;
        if (this.firefox && this.api.sessions) {
          sourceToken = await this.api.sessions.getWindowValue(windowId, this.key + 'Source').catch(() => null);
          sourceToken ||= globalThis.crypto?.randomUUID?.() || `${Date.now()}-${windowId}-${Math.random()}`;
          await this.api.sessions.setWindowValue(windowId, this.key + 'Source', sourceToken);
        }
        // Group metadata is recorded before a cross-window move dissolves it.
        for (const tab of candidates) {
          if (tab.groupId == null || tab.groupId < 0 || this.state.groups.some(g => g.id === tab.groupId)) continue;
          if (!this.api.tabGroups?.get || !this.api.tabs.group) continue;
          const metadata = await this.api.tabGroups.get(tab.groupId).catch(() => null);
          if (metadata) {
            this.state.groups.push({id: tab.groupId, windowId, title: metadata.title, color: metadata.color, collapsed: metadata.collapsed,
              tabIDs: group.filter(t => t.groupId === tab.groupId).map(t => t.id)});
            await this.save();
          }
        }
        // Never dissolve a group unless its restore metadata is safely recorded.
        candidates = candidates.filter(t => t.groupId == null || t.groupId < 0 || this.state.groups.some(g => g.id === t.groupId));
        if (candidates.length && !this.state.orders.some(entry => entry.windowId === windowId)) {
          this.state.orders.push({windowId, tabIDs: group.slice().sort((a,b) => a.index - b.index).map(t => t.id)});
          await this.save();
        }
        const processed = new Set();
        for (const tab of candidates.sort((a,b) => a.index - b.index)) {
          if (native && !this.sameNativeIdentity(nativeIdentity, this.verifiedNativeIdentity())) return false;
          if (processed.has(tab.id)) continue;
          // Move a fully blocked split pair together to retain its relationship.
          const batch = tab.splitViewId != null && tab.splitViewId >= 0
            ? candidates.filter(t => t.splitViewId === tab.splitViewId) : [tab];
          for (const member of batch) {
            processed.add(member.id);
            if (!this.state.moved.some(x => x.id === member.id)) {
              const entry = {id: member.id, windowId, index: member.index, parking, pinned: Boolean(member.pinned), parkingPinPending: true, splitViewId: member.splitViewId, sourceToken,
                ...(native ? {nativeSessionID: this.state.nativeSessionID,
                  nativeBrowserSessionID: nativeIdentity.browserSessionID,
                  nativeBrowserProcessIdentity: {...nativeIdentity.processIdentity}, nativeParkingWindowID: parking} : {})};
              this.state.moved.push(entry);
              await this.save(); // Durable ownership before changing any user's tab.
              if (this.firefox && this.api.sessions) await this.api.sessions.setTabValue(member.id, this.key, {...entry, kind: 'moved'});
            }
          }
          const pinnedCount = tab.pinned ? (await this.api.tabs.query({windowId: parking})).filter(t => t.pinned).length : -1;
          await this.api.tabs.move(batch.length === 1 ? tab.id : batch.map(t => t.id), {windowId: parking, index: pinnedCount}).catch(() => {});
          for (const member of batch) {
            const owned = this.state.moved.find(item => item.id === member.id);
            if (owned) await this.repairParkingPin(owned, parking);
          }
        }
        await this.api.windows.update(parking, {state: 'minimized'}).catch(() => {});
      }
      return true;
    }
    async repairPin(item, windowId, restoreIndex = false) {
      // Chrome cross-window moves insert an unpinned tab. Keep the original
      // pin in durable ownership until both the update and readback succeed.
      if (typeof item.pinned !== 'boolean') return true;
      try {
        let tab = await this.api.tabs.get(item.id);
        if (tab.windowId !== windowId) return false;
        if (Boolean(tab.pinned) !== item.pinned) {
          await this.api.tabs.update(item.id, {pinned: item.pinned});
          tab = await this.api.tabs.get(item.id);
        }
        if (tab.windowId !== windowId || Boolean(tab.pinned) !== item.pinned) return false;
        if (restoreIndex && item.pinned) {
          // Pinning appends at the pinned boundary. Firefox marker-only recovery
          // has no saved order array, so restore the original pinned slot here.
          const tabs = await this.api.tabs.query({windowId});
          // A user may move or repin the tab while the query is in flight.
          tab = await this.api.tabs.get(item.id);
          if (tab.windowId !== windowId) return false;
          if (Boolean(tab.pinned) !== item.pinned) {
            // The desired pin was already verified before this query. A later
            // change is external, not a failed update to keep overwriting.
            item.pinned = Boolean(tab.pinned);
            return true;
          }
          const index = Math.min(Math.max(0, item.index), tabs.filter(candidate => candidate.pinned).length - 1);
          if (tab.index !== index) {
            // Omit windowId: an index correction must never become a
            // cross-window move if the user moves the tab concurrently.
            await this.api.tabs.move(item.id, {index});
            tab = await this.api.tabs.get(item.id);
          }
          if (tab.windowId !== windowId || !tab.pinned || tab.index !== index) return false;
        }
        return true;
      } catch (_) { return false; }
    }
    async persistMovedEntry(item) {
      await this.save();
      if (this.firefox && this.api.sessions)
        await this.api.sessions.setTabValue(item.id, this.key, {...item, kind: 'moved'});
    }
    async repairParkingPin(item, windowId) {
      if (item.parkingPinPending === false) return true;
      if (!await this.repairPin(item, windowId)) return false;
      item.parkingPinPending = false;
      await this.persistMovedEntry(item);
      return true;
    }
    async repairParkingPins(snapshot = null) {
      // Retry only our unfinished mutation. Once verified, later user pin
      // changes belong to the user and are captured before our return move.
      if (!this.state.moved.some(item => item.parkingPinPending !== false)) return;
      const tabs = new Map((snapshot || await this.api.tabs.query({})).map(tab => [tab.id, tab]));
      for (const item of this.state.moved) {
        const tab = tabs.get(item.id);
        if (tab?.windowId === item.parking) await this.repairParkingPin(item, item.parking);
      }
    }
    async readOwnedTab(id) {
      try { return {confirmed: true, tab: await this.api.tabs.get(id)}; }
      catch (_) {
        // A failed read is not proof that a tab closed. Release ownership only
        // after a successful inventory confirms absence; otherwise retry later.
        try {
          if (!(await this.api.tabs.query({})).some(tab => tab.id === id))
            return {confirmed: true, tab: null};
        } catch (_) { /* Keep ownership while the browser cannot answer. */ }
        return {confirmed: false, tab: null};
      }
    }
    async validateBootstrap(offer) {
      const policy = this.bootstrapPolicy;
      if (!this.firefox || !policy || JSON.stringify(this.desiredRules) !== JSON.stringify(policy.rules)
          || !policy.rules.active || !policy.rules.nativeWindowVisibility
          || policy.rules.startupSessionID !== offer.intentionSessionID || !policy.windowIDs.has(offer.windowID)) return false;
      const identity = this.verifiedNativeIdentity();
      if (identity?.browserSessionID !== offer.browserSessionID
          || !this.sameProcess(identity?.processIdentity,offer.browserProcessIdentity)) return false;
      const window = await this.api.windows.get(offer.windowID,{populate:true}).catch(()=>null);
      return this.bootstrapPolicy?.key === policy.key && this.bootstrapPolicy?.windowIDs.has(offer.windowID)
        && JSON.stringify(this.desiredRules) === JSON.stringify(policy.rules)
        && this.sameNativeIdentity(identity,this.verifiedNativeIdentity())
        && window?.id === offer.windowID && window.type === 'normal' && window.focused === false
        && ['normal','maximized'].includes(window.state) && Array.isArray(window.tabs) && window.tabs.length > 0
        && window.tabs.every(tab=>Number.isSafeInteger(tab.id) && tab.windowId===offer.windowID
          && typeof tab.url==='string' && !this.holdingPage(tab.url) && !policy.allowed(tab));
    }
    windowDescriptor(window, tabs) {
      return {windowID: window.id, title: tabs.find(tab => tab.active)?.title || '',
        frame: {left: window.left, top: window.top, width: window.width, height: window.height}, state: window.state || 'normal'};
    }
    verifiedNativeIdentity() {
      const identity = this.nativeOwner?.identity?.();
      return typeof identity?.browserSessionID === 'string' && identity.browserSessionID.length > 0
        && Number.isInteger(identity.processIdentity?.pid) && identity.processIdentity.pid > 0
        && Number.isFinite(identity.processIdentity?.launched) && identity.processIdentity.launched > 0 ? identity : null;
    }
    sameNativeIdentity(a, b) {
      return Boolean(a && b && a.browserSessionID === b.browserSessionID
        && a.processIdentity.pid === b.processIdentity.pid && a.processIdentity.launched === b.processIdentity.launched);
    }
    sameProcess(a, b) {
      return Boolean(a && b && Number.isInteger(a.pid) && a.pid > 0 && Number.isFinite(a.launched) && a.launched > 0
        && a.pid === b.pid && a.launched === b.launched);
    }
    newParkingNonce() {
      return globalThis.crypto?.randomUUID?.() || 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
        const n = Math.floor(Math.random() * 16); return (c === 'x' ? n : (n & 3) | 8).toString(16);
      });
    }
    parkingNonce(url) {
      const prefix = this.api.runtime.getURL('parked.html') + '#intent-';
      const nonce = typeof url === 'string' && url.startsWith(prefix) ? url.slice(prefix.length) : '';
      return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(nonce) ? nonce : null;
    }
    holdingPage(url) { return url === this.api.runtime.getURL('parked.html') || this.parkingNonce(url) !== null; }
    validParkingProof(proof) {
      return typeof proof?.nonce === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(proof.nonce)
        && typeof proof.intentionSessionID === 'string' && proof.intentionSessionID.length > 0
        && typeof proof.previousBrowserSessionID === 'string' && proof.previousBrowserSessionID.length > 0
        && this.sameProcess(proof.previousProcessIdentity, proof.previousProcessIdentity)
        && Array.isArray(proof.windowIDs) && proof.windowIDs.length === 1 && Number.isInteger(proof.windowIDs[0]) && proof.windowIDs[0] >= 0;
    }
    async describeWindows(ids) {
      const windows = await this.api.windows.getAll({populate: false});
      const tabs = await this.api.tabs.query({});
      return windows.filter(window => ids.includes(window.id)).map(window =>
        this.windowDescriptor(window, tabs.filter(tab => tab.windowId === window.id)));
    }
    async publishNativePlan(rules, windows) {
      const parking = await this.describeWindows(this.state.parking);
      return await this.nativeOwner?.publishPlan?.(rules, windows, parking) === true;
    }
    async hasLegacyWindowOwnership() {
      if (this.state.minimized.length) return true;
      if (this.firefox && this.api.sessions) {
        for (const window of await this.api.windows.getAll({populate: false})) {
          if (await this.api.sessions.getWindowValue(window.id, this.key).catch(() => null)) return true;
        }
      }
      return false;
    }
    async revealWindow(id, sessionID = this.state.nativeSessionID) {
      if (!sessionID) {
        await this.api.windows.update(id, {state: 'normal', focused: false});
        return;
      }
      if (!this.state.nativeReveals.some(item => item.windowID === id)) {
        this.state.nativeReveals.push({windowID: id, sessionID});
        await this.save();
      }
    }
    async retryNativeReveals() {
      for (const sessionID of new Set(this.state.nativeReveals.map(item => item.sessionID))) {
        const pending = this.state.nativeReveals.filter(item => item.sessionID === sessionID);
        const windows = await this.describeWindows(pending.map(item => item.windowID));
        const existing = new Set(windows.map(window => window.windowID));
        // Closed windows need no reveal. Every existing one keeps its receipt
        // until native ownership has durably accepted restoration responsibility.
        const accepted = !windows.length || await Promise.resolve().then(() => this.nativeOwner?.revealWindows?.(sessionID, windows)).catch(() => false) === true;
        const released = new Set(pending.filter(item => accepted || !existing.has(item.windowID)).map(item => item.windowID));
        if (!accepted) {
          for (const window of windows) {
            if (await this.recoverPriorParkingWindow(sessionID, window.windowID)) released.add(window.windowID);
          }
        }
        // Firefox markers are the restart proof. Keep them until either native
        // accepts ownership or generation-verified startup recovery succeeds.
        const sourceIDs = new Set((await this.api.windows.getAll({populate: false})).map(window => window.id));
        const relinquished = [];
        for (const item of this.state.moved.filter(item => released.has(item.parking) && !sourceIDs.has(item.windowId))) {
          const observed = await this.readOwnedTab(item.id);
          if (!observed.confirmed) continue;
          const tab = observed.tab;
          if (tab?.windowId === item.parking && !await this.repairParkingPin(item, item.parking)) continue;
          relinquished.push(item);
          if (this.firefox && this.api.sessions) await this.api.sessions.removeTabValue(item.id, this.key).catch(() => {});
        }
        this.state.moved = this.state.moved.filter(item => !relinquished.includes(item));
        this.state.parking = this.state.parking.filter(id => !released.has(id) || this.state.moved.some(item => item.parking === id));
        this.state.nativeReveals = this.state.nativeReveals.filter(item => item.sessionID !== sessionID || !released.has(item.windowID));
        await this.save();
      }
    }
    async parkingOwnershipProof(sessionID, windowID, orphanOnly = false) {
      if (!this.firefox) {
        if (!this.api.storage.local) return null;
        const saved = (await this.api.storage.local.get(this.shadowKey))[this.shadowKey];
        const tabs = await this.api.tabs.query({windowId: windowID});
        const proof = saved?.state?.nativeParkingProofs?.find(item => this.validParkingProof(item)
          && item.intentionSessionID === sessionID && tabs.some(tab => this.parkingNonce(tab.url) === item.nonce));
        return proof ? {intentionSessionID: proof.intentionSessionID, previousBrowserSessionID: proof.previousBrowserSessionID,
          previousProcessIdentity: {...proof.previousProcessIdentity}, windowIDs: [...proof.windowIDs]} : null;
      }
      if (!this.api.sessions) return null;
      const windows = await this.api.windows.getAll({populate: false});
      if (!windows.some(window => window.id === windowID)) return null;
      for (const tab of await this.api.tabs.query({windowId: windowID})) {
        const owned = await this.api.sessions.getTabValue(tab.id, this.key).catch(() => null);
        const previous = owned?.nativeBrowserProcessIdentity;
        if (owned?.kind !== 'moved' || owned.nativeSessionID !== sessionID || !owned.sourceToken
            || typeof owned.nativeBrowserSessionID !== 'string' || !owned.nativeBrowserSessionID
            || !Number.isInteger(owned.nativeParkingWindowID) || owned.nativeParkingWindowID < 0
            || !Number.isInteger(previous?.pid) || previous.pid <= 0 || !Number.isFinite(previous?.launched) || previous.launched <= 0) continue;
        // A surviving original window must use ordinary tab restoration. Never
        // guess at its old numeric ID after Firefox has recycled session IDs.
        let sourceExists = false;
        for (const window of windows) {
          if (await this.api.sessions.getWindowValue(window.id, this.key + 'Source').catch(() => null) === owned.sourceToken) {
            sourceExists = true; break;
          }
        }
        if (!orphanOnly || !sourceExists) return {intentionSessionID: sessionID, previousBrowserSessionID: owned.nativeBrowserSessionID,
          previousProcessIdentity: {...previous}, windowIDs: [owned.nativeParkingWindowID]};
      }
      return null;
    }
    async recoverPriorParkingWindow(sessionID, windowID) {
      const identity = this.verifiedNativeIdentity();
      let proof = await this.parkingOwnershipProof(sessionID, windowID);
      if (!identity || !proof) return false;
      if (identity.processIdentity.pid === proof.previousProcessIdentity.pid
          && identity.processIdentity.launched === proof.previousProcessIdentity.launched) {
        const accepted = await Promise.resolve().then(() => this.nativeOwner?.recoverPriorWindows?.(proof)).catch(() => false);
        return accepted === true && this.sameNativeIdentity(identity, this.verifiedNativeIdentity());
      }
      if (this.desiredRules?.active !== false) return false;
      proof = await this.parkingOwnershipProof(sessionID, windowID, true);
      if (!proof) return false;
      const {windowIDs: _windowIDs, ...authorization} = proof;
      const accepted = await Promise.resolve().then(() => this.nativeOwner?.authorizeRestartRecovery?.(authorization)).catch(() => false);
      if (accepted !== true || this.desiredRules?.active !== false || !this.sameNativeIdentity(identity, this.verifiedNativeIdentity())) return false;
      const confirmed = await this.parkingOwnershipProof(sessionID, windowID, true);
      if (JSON.stringify(confirmed) !== JSON.stringify(proof) || this.desiredRules?.active !== false
          || !this.sameNativeIdentity(identity, this.verifiedNativeIdentity())) return false;
      // This is exclusively a verified full-process restart recovery, after the
      // old process died. Ordinary finish/reload never reaches browser restore.
      try { await this.api.windows.update(windowID, {state: 'normal', focused: false}); return true; }
      catch (_) { return false; }
    }
    async restore() {
      // Backfill a previous accepted plan only with the original durable
      // profile/process proof; current identity alone cannot create ownership.
      if (this.state.nativeSessionID && this.state.nativeBrowserIdentity)
        await this.nativeOwner?.rememberParkingOwnership?.(this.state.nativeSessionID, this.state.nativeBrowserIdentity);
      // Firefox session values follow the real tab/window across browser restarts.
      if (this.firefox && this.api.sessions) {
        const sourceWindows = new Map();
        for (const window of await this.api.windows.getAll({populate: false})) {
          const token = await this.api.sessions.getWindowValue(window.id, this.key + 'Source').catch(() => null);
          if (token) sourceWindows.set(token, window.id);
        }
        const markerTabs = await this.api.tabs.query({});
        for (const tab of markerTabs) {
          const owned = await this.api.sessions.getTabValue(tab.id, this.key).catch(() => false);
          if (!owned) continue;
          if (owned.kind === 'moved') {
            if (!this.state.moved.some(item => item.id === tab.id)) {
              const sourceID = sourceWindows.get(owned.sourceToken) ?? -1;
              // A failed pin update may leave a marker on a tab already returned
              // to source. In the same verified process, also respect a user's
              // move elsewhere: its current window is not our recorded holder.
              const identity = this.verifiedNativeIdentity();
              const isHolder = markerTabs.some(other => other.windowId === tab.windowId && this.holdingPage(other.url));
              if (owned.nativeSessionID && !identity && tab.windowId !== sourceID && !isHolder)
                throw new Error('Waiting for verified native recovery identity');
              const sameProcess = this.sameProcess(owned.nativeBrowserProcessIdentity, identity?.processIdentity);
              const movedElsewhere = sameProcess && !isHolder && tab.windowId !== owned.parking && tab.windowId !== sourceID;
              const parking = tab.windowId === sourceID || movedElsewhere ? null : tab.windowId;
              this.state.moved.push({...owned, id: tab.id, windowId: sourceID, parking});
              if (owned.nativeSessionID) this.state.nativeSessionID ||= owned.nativeSessionID;
              if (parking != null && !this.state.parking.includes(parking)) this.state.parking.push(parking);
              await this.save();
            }
            continue;
          }
          // Recover tabs hidden by older Intent versions without touching
          // hidden state owned by Sidebery or another extension.
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
      {
        for (const tab of await this.api.tabs.query({})) {
          if (!this.holdingPage(tab.url) || this.state.parking.includes(tab.windowId) || this.state.recovered.includes(tab.windowId)) continue;
          // With a native owner, an unregistered holder is not permission to
          // resurrect a browser window. Native or durable marker proof is required.
          if (this.nativeOwner) continue;
          try {
            await this.revealWindow(tab.windowId);
            this.state.recovered.push(tab.windowId); await this.save();
          } catch (_) { /* Retry next heartbeat if the browser is busy. */ }
        }
      }
      for (const id of [...this.state.hidden]) {
        const tab = await this.api.tabs.get(id).catch(() => null);
        if (tab?.hidden) { try { await this.api.tabs.show(id); } catch (_) { continue; } }
        this.state.hidden = this.state.hidden.filter(x => x !== id); await this.save();
      }
      await this.repairParkingPins();
      const restoredIDs = new Set();
      for (const item of [...this.state.moved].sort((a,b) => a.windowId - b.windowId || a.index - b.index)) {
        if (restoredIDs.has(item.id)) continue;
        const batch = item.splitViewId != null && item.splitViewId >= 0
          ? this.state.moved.filter(other => other.windowId === item.windowId && other.parking === item.parking && other.splitViewId === item.splitViewId).sort((a,b) => a.index - b.index) : [item];
        const observed = await this.readOwnedTab(item.id);
        if (!observed.confirmed) continue;
        const tab = observed.tab;
        if (tab && tab.windowId === item.parking) {
          try {
            for (const member of batch) {
              const current = await this.api.tabs.get(member.id);
              if (current.windowId !== member.parking) throw new Error('Tab moved before return');
              if (member.parkingPinPending === false) member.pinned = Boolean(current.pinned);
              // This durable phase distinguishes our failed return from a tab
              // the user moved back themselves while Add as you go was active.
              member.returnPinPending = true;
              await this.persistMovedEntry(member);
            }
            await this.api.tabs.move(batch.length === 1 ? item.id : batch.map(member => member.id), {windowId: item.windowId, index: item.index});
            // Firefox may silently refuse a move; retain ownership until it is verified.
            const returned = await this.api.tabs.get(item.id);
            if (returned.windowId !== item.windowId) continue;
          }
          catch (_) {
            // The user may have closed the original window. Keep their live
            // tab intact and make the holding window visible for recovery.
            await this.revealWindow(item.parking, item.nativeSessionID || this.state.nativeSessionID).catch(() => {});
            if (await this.api.windows.get(item.windowId).catch(() => null)) continue;
            // Original window is gone: relinquish ownership of the recovered tabs.
            this.state.recovered.push(item.parking);
            if (item.nativeSessionID || this.state.nativeSessionID) continue;
          }
        }
        for (const member of batch) {
          const observed = await this.readOwnedTab(member.id);
          if (!observed.confirmed) continue;
          const current = observed.tab;
          if (current?.windowId === member.windowId && member.returnPinPending) {
            // Only an Intent-owned return may repair a tab already in source.
            if (!await this.repairPin(member, member.windowId, true)) continue;
          } else if (current?.windowId === member.parking && !await this.repairParkingPin(member, member.parking)) continue;
          restoredIDs.add(member.id);
          if (this.firefox && this.api.sessions && tab) await this.api.sessions.removeTabValue(member.id, this.key).catch(() => {});
          this.state.moved = this.state.moved.filter(x => x.id !== member.id);
        }
        await this.save();
      }
      // Sidebars can reorder newly attached tabs while individual restores run.
      // Normalize after cross-window moves settle, keeping newly created tabs.
      for (const order of [...this.state.orders]) {
        if (this.state.moved.some(item => item.windowId === order.windowId)) continue;
        try {
          // onAttached handlers in sidebar extensions run after tabs.move resolves.
          // Require two quiet observations before relinquishing the saved order;
          // an immediate readback alone can pass before Sidebery changes it again.
          let stable = 0;
          for (let attempt = 0; attempt < 4 && stable < 2; attempt++) {
            let current = await this.api.tabs.query({windowId: order.windowId});
            const existing = new Map(current.map(tab => [tab.id, tab]));
            const originals = order.tabIDs.filter(id => existing.has(id));
            const added = current.filter(tab => !order.tabIDs.includes(tab.id)).map(tab => tab.id);
            const desired = [...originals, ...added];
            const expected = [true, false].flatMap(pinned => desired.filter(id => Boolean(existing.get(id)?.pinned) === pinned));
            if (current.map(tab => tab.id).join(',') !== expected.join(',')) {
              stable = 0;
              // Recheck each tab after the awaited snapshot, then reorder only
              // within its current window. An explicit target window could pull
              // a user's concurrent move back here and clear its pin in Chrome.
              for (const [index, id] of expected.entries()) {
                let live = await this.api.tabs.get(id);
                const pinned = Boolean(existing.get(id)?.pinned);
                if (live.windowId !== order.windowId || Boolean(live.pinned) !== pinned) break;
                if (live.index !== index) {
                  await this.api.tabs.move(id, {index});
                  live = await this.api.tabs.get(id);
                  if (live.windowId !== order.windowId || Boolean(live.pinned) !== pinned) break;
                }
              }
            }
            await new Promise(resolve => setTimeout(resolve, 250));
            current = await this.api.tabs.query({windowId: order.windowId});
            stable = current.map(tab => tab.id).join(',') === expected.join(',') ? stable + 1 : 0;
          }
          if (stable < 2) continue; // Keep ownership for a later safe retry.
          this.state.orders = this.state.orders.filter(entry => entry !== order); await this.save();
        } catch (_) {
          if (!await this.api.windows.get(order.windowId).catch(() => null)) {
            this.state.orders = this.state.orders.filter(entry => entry !== order); await this.save();
          }
        }
      }
      for (const group of [...this.state.groups]) {
        if (this.state.moved.some(item => group.tabIDs.includes(item.id))) continue;
        const members = (await this.api.tabs.query({windowId: group.windowId}).catch(() => []))
          .filter(t => group.tabIDs.includes(t.id) && !t.pinned && (t.groupId == null || t.groupId < 0 || t.groupId === group.id));
        try {
          if (members.length && this.api.tabs.group) {
            const current = await this.api.tabGroups.get(group.id).catch(() => null);
            const id = await this.api.tabs.group({tabIds: members.map(t => t.id),
              ...(current?.windowId === group.windowId ? {groupId: group.id} : {createProperties: {windowId: group.windowId}})});
            await this.api.tabGroups.update(id, {title: group.title || '', color: group.color, collapsed: Boolean(group.collapsed)});
          }
          this.state.groups = this.state.groups.filter(g => g.id !== group.id); await this.save();
        } catch (_) { /* Keep metadata for the next restore attempt. */ }
      }
      for (const item of [...this.state.minimized]) {
        const window = await this.api.windows.get(item.id).catch(() => null);
        if (window?.state === 'minimized') {
          try { await this.api.windows.update(item.id, {state: item.state, focused: false}); } catch (_) { continue; }
        }
        this.state.minimized = this.state.minimized.filter(x => x.id !== item.id); await this.save();
      }
      let closedParking = false;
      for (const id of [...this.state.parking]) {
        try {
          const windows = await this.api.windows.getAll({populate:false});
          if (!Array.isArray(windows) || windows.some(window => !Number.isSafeInteger(window?.id) || window.id < 0)
              || new Set(windows.map(window => window.id)).size !== windows.length) continue;
          if (windows.some(window => window.id === id)) {
            const tabs = await this.api.tabs.query({windowId: id});
            // Close only our own empty holding page. A failed read/removal or a
            // window still present afterward keeps retry ownership intact.
            if (tabs.length === 1 && this.holdingPage(tabs[0].url)) {
              await this.api.tabs.remove(tabs[0].id);
              const remaining = await this.api.windows.getAll({populate:false});
              if (!Array.isArray(remaining) || remaining.some(window => !Number.isSafeInteger(window?.id) || window.id < 0)
                  || new Set(remaining.map(window => window.id)).size !== remaining.length
                  || remaining.some(window => window.id === id)) continue;
              closedParking = true;
            } else if (tabs.length) {
              await this.revealWindow(id);
            } else continue;
          } else closedParking = true;
          if (!this.state.moved.some(x => x.parking === id)) this.state.parking = this.state.parking.filter(x => x !== id);
          await this.save();
        } catch (_) { /* Absence must be confirmed, never inferred from an error. */ }
      }
      await this.retryNativeReveals();
      // Accepted parking proof was durable before tabs entered the holder, so
      // this receipt can retry independently after tab state has been cleared.
      void Promise.resolve(this.nativeOwner?.retireClosedWindows?.({force:closedParking})).catch(() => {});
    }
  }
  root.IntentTabVisibility = IntentTabVisibility;
  if (typeof module !== 'undefined') module.exports = IntentTabVisibility;
})(globalThis);
