/* Native owns whole-window visibility; acknowledgements mean durable ownership,
 * not successful AX completion. Never fall back to browser restoration on loss. */
(function(root) {
  class IntentNativeWindowVisibility {
    constructor(api, send, sessionID, options = {}) {
      this.api = api; this.send = send; this.sessionID = sessionID;
      this.key = 'intentNativeWindowVisibilityV1';
      this.timeout = options.timeout ?? 2000;
      this.now = options.now ?? Date.now;
      this.tail = Promise.resolve(); this.pending = new Map(); this.sent = new Map();
      this.state = null; this.processIdentity = null; this.nativeActive = null; this.restartPending = new Map(); this.recoveryPending = new Map();
    }
    enqueue(operation) {
      const result = this.tail.then(operation, operation).catch(() => false);
      this.tail = result; return result;
    }
    async load() {
      const id = this.sessionID();
      if (!id || !this.api.storage.session) return false;
      if (!this.state || this.state.browserSessionID !== id) {
        const saved = (await this.api.storage.session.get(this.key))[this.key];
        this.state = saved?.browserSessionID === id ? saved : {browserSessionID: id, revision: 0, plans: {}};
      }
      return true;
    }
    save() { return this.api.storage.session.set({[this.key]: this.state}); }
    descriptors(windows) {
      if (!Array.isArray(windows) || windows.length > 256) throw new Error('Invalid visibility inventory');
      const seen = new Set();
      return windows.map(w => {
        if (!Number.isInteger(w?.windowID) || w.windowID < 0 || seen.has(w.windowID)
            || typeof w.title !== 'string' || w.title.length > 4096
            || !w.frame || !['left','top','width','height'].every(k => Number.isFinite(w.frame[k]))
            || w.frame.width <= 0 || w.frame.height <= 0
            || !['normal','minimized','maximized','fullscreen'].includes(w.state)) {
          throw new Error('Invalid visibility window');
        }
        seen.add(w.windowID);
        return {windowID:w.windowID, title:w.title,
          frame:{left:w.frame.left,top:w.frame.top,width:w.frame.width,height:w.frame.height}, state:w.state};
      }).sort((a,b) => a.windowID - b.windowID);
    }
    validProcess(value) {
      return Number.isInteger(value?.pid) && value.pid > 0
        && Number.isFinite(value.launched) && value.launched > 0;
    }
    identity() {
      const browserSessionID = this.sessionID();
      return browserSessionID && this.processIdentity
        ? {browserSessionID, processIdentity:{...this.processIdentity}} : null;
    }
    recoverPriorWindows(request) {
      return this.enqueue(async () => {
        const current = this.identity();
        const ids = request?.windowIDs;
        if (!current || !this.validProcess(request?.previousProcessIdentity)
            || current.processIdentity.pid !== request.previousProcessIdentity.pid
            || current.processIdentity.launched !== request.previousProcessIdentity.launched
            || typeof request.intentionSessionID !== 'string' || !request.intentionSessionID
            || typeof request.previousBrowserSessionID !== 'string' || !request.previousBrowserSessionID
            || !Array.isArray(ids) || !ids.length || ids.length > 256
            || ids.some(id => !Number.isSafeInteger(id) || id < 0) || new Set(ids).size !== ids.length
            || !await this.load()) return false;
        const generation = JSON.stringify(current);
        if (!Number.isSafeInteger(this.state.revision) || this.state.revision >= Number.MAX_SAFE_INTEGER - 1) return false;
        const requestID = `${current.browserSessionID}-recovery-${++this.state.revision}`;
        await this.save();
        const accepted = await new Promise(resolve => {
          const timer = setTimeout(() => {this.recoveryPending.delete(requestID);resolve(false);},this.timeout);
          this.recoveryPending.set(requestID,value => {clearTimeout(timer);this.recoveryPending.delete(requestID);resolve(value);});
          try {
            if (!this.send({type:'windowVisibilityRecovery',visibilityRecoveryRequest:{requestID,
              intentionSessionID:request.intentionSessionID, previousBrowserSessionID:request.previousBrowserSessionID,
              previousProcessIdentity:{...request.previousProcessIdentity},windowIDs:[...ids]}})) this.recoveryPending.get(requestID)?.(false);
          } catch (_) {this.recoveryPending.get(requestID)?.(false);}
        });
        return accepted && JSON.stringify(this.identity()) === generation;
      });
    }
    authorizeRestartRecovery(request) {
      return this.enqueue(async () => {
        const current = this.identity();
        if (this.nativeActive !== false || !current || !this.validProcess(request?.previousProcessIdentity)
            || typeof request.intentionSessionID !== 'string' || !request.intentionSessionID
            || typeof request.previousBrowserSessionID !== 'string' || !request.previousBrowserSessionID
            || (current.processIdentity.pid === request.previousProcessIdentity.pid
              && current.processIdentity.launched === request.previousProcessIdentity.launched)
            || !await this.load()) return false;
        const generation = JSON.stringify(current);
        if (!Number.isSafeInteger(this.state.revision) || this.state.revision >= Number.MAX_SAFE_INTEGER - 1) return false;
        const requestID = `${current.browserSessionID}-restart-${++this.state.revision}`;
        await this.save();
        const accepted = await new Promise(resolve => {
          const timer = setTimeout(() => {this.restartPending.delete(requestID); resolve(false);}, this.timeout);
          this.restartPending.set(requestID, value => {clearTimeout(timer);this.restartPending.delete(requestID);resolve(value);});
          try {
            if (!this.send({type:'windowVisibilityRestartRecovery', visibilityRestartRequest:{requestID,
              intentionSessionID:request.intentionSessionID,
              previousBrowserSessionID:request.previousBrowserSessionID,
              previousProcessIdentity:{...request.previousProcessIdentity}}})) this.restartPending.get(requestID)?.(false);
          } catch (_) {this.restartPending.get(requestID)?.(false);}
        });
        return accepted && this.nativeActive === false && JSON.stringify(this.identity()) === generation;
      });
    }
    publishPlan(rules, windows, parkingWindows = []) {
      return this.enqueue(async () => {
        if (!rules?.active || !rules.nativeWindowVisibility || !rules.startupSessionID || !await this.load()) return false;
        return this.submit({intentionSessionID:rules.startupSessionID,
          windows:this.descriptors(windows), parkingWindows:this.descriptors(parkingWindows), revealWindowIDs:[]});
      });
    }
    revealWindows(sessionID, windows) {
      return this.enqueue(async () => {
        if (!await this.load()) return false;
        const prior = this.state.plans[sessionID];
        if (!prior) return false;
        const requested = this.descriptors(windows).map(w => w.windowID);
        if (!requested.every(id => prior.parkingWindows.some(w => w.windowID === id))) return false;
        // Use accepted identity metadata, not a newly observed title/frame from
        // an inactive browser. The host independently checks prior registration.
        return this.submit({...prior, revealWindowIDs:[...new Set([...(prior.revealWindowIDs || []), ...requested])].sort((a,b) => a-b)});
      });
    }
    async submit(plan) {
      const fingerprint = JSON.stringify(plan);
      const previous = this.sent.get(plan.intentionSessionID);
      if (previous?.fingerprint === fingerprint && this.now() - previous.at < 10000) return true;
      if (!Number.isSafeInteger(this.state.revision) || this.state.revision >= Number.MAX_SAFE_INTEGER - 1) return false;
      const revision = ++this.state.revision;
      // Persist before sending, so worker suspension never reuses a revision.
      await this.save();
      const accepted = await new Promise(resolve => {
        const timer = setTimeout(() => { this.pending.delete(revision); resolve(false); }, this.timeout);
        this.pending.set(revision, value => { clearTimeout(timer); this.pending.delete(revision); resolve(value); });
        try {
          if (!this.send({type:'windowVisibilityPlan', visibilityPlan:{...plan, revision}})) this.pending.get(revision)?.(false);
        } catch (_) { this.pending.get(revision)?.(false); }
      });
      if (!accepted) return false;
      this.state.plans[plan.intentionSessionID] = plan;
      await this.save();
      this.sent.set(plan.intentionSessionID, {fingerprint, at:this.now()});
      return true;
    }
    receive(message) {
      if (typeof message?.active === 'boolean') this.nativeActive = message.active;
      // Full host responses omit optional identity when verification is unavailable.
      // That omission revokes cached proof; receipt-only messages are partial.
      if (typeof message?.active === 'boolean' || (message && Object.prototype.hasOwnProperty.call(message, 'browserProcessIdentity'))) {
        this.processIdentity = this.validProcess(message.browserProcessIdentity) ? {...message.browserProcessIdentity} : null;
      }
      const recovery = message?.visibilityRecoveryReceipt;
      if (typeof recovery?.requestID === 'string') this.recoveryPending.get(recovery.requestID)?.(recovery.accepted === true);
      const restart = message?.visibilityRestartReceipt;
      if (typeof restart?.requestID === 'string') this.restartPending.get(restart.requestID)?.(restart.accepted === true);
      const receipt = message?.visibilityPlanReceipt;
      if (Number.isSafeInteger(receipt?.revision)) this.pending.get(receipt.revision)?.(receipt.accepted === true);
    }
    disconnected() {
      for (const settle of [...this.pending.values()]) settle(false);
      for (const settle of [...this.restartPending.values()]) settle(false);
      for (const settle of [...this.recoveryPending.values()]) settle(false);
      this.processIdentity = null; this.nativeActive = null;
      this.sent.clear();
    }
  }
  root.IntentNativeWindowVisibility = IntentNativeWindowVisibility;
  if (typeof module !== 'undefined') module.exports = IntentNativeWindowVisibility;
})(typeof globalThis !== 'undefined' ? globalThis : this);
