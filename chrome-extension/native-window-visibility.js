/* Native owns whole-window visibility; acknowledgements mean durable ownership,
 * not successful AX completion. Never fall back to browser restoration on loss. */
(function(root) {
  class IntentNativeWindowVisibility {
    constructor(api, send, sessionID, options = {}) {
      this.api = api; this.send = send; this.sessionID = sessionID;
      this.key = 'intentNativeWindowVisibilityV1';
      this.closureKey = 'intentNativeParkingClosureV1'; this.closureLedger = null; this.closedPending = new Map();
      this.closureLedgerTail = Promise.resolve(); this.closureTask = null; this.closureNextAt = 0;
      this.closureCursor = 0; this.closureGroupOffsets = new Map(); this.closureSingleGroups = new Set(); this.closureSerial = 0; this.closureRerun = false;
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
    sameProcess(a, b) {
      return this.validProcess(a) && this.validProcess(b) && a.pid === b.pid && a.launched === b.launched;
    }
    validClosureProof(proof) {
      return typeof proof?.intentionSessionID === 'string' && proof.intentionSessionID.length > 0 && proof.intentionSessionID.length <= 256
        && typeof proof.previousBrowserSessionID === 'string' && proof.previousBrowserSessionID.length > 0 && proof.previousBrowserSessionID.length <= 256
        && this.validProcess(proof.previousProcessIdentity) && Array.isArray(proof.windowIDs) && proof.windowIDs.length === 1
        && Number.isSafeInteger(proof.windowIDs[0]) && proof.windowIDs[0] >= 0;
    }
    async loadClosureLedger() {
      if (!this.api.storage.local) return false;
      if (this.closureLedger) return true;
      const saved = (await this.api.storage.local.get(this.closureKey))[this.closureKey];
      if (saved != null && (saved.version !== 1 || !Array.isArray(saved.entries) || saved.entries.length > 1280
          || saved.entries.some(entry => !this.validClosureProof(entry) || typeof entry.closed !== 'boolean')
          || new Set(saved.entries.map(entry => this.closureProofKey(entry))).size !== saved.entries.length)) return false;
      this.closureLedger = saved || {version:1, entries:[]};
      return true;
    }
    async saveClosureLedger() {
      try { await this.api.storage.local.set({[this.closureKey]:this.closureLedger}); }
      catch (error) { this.closureLedger = null; throw error; }
    }
    closureProofKey(proof) {
      return JSON.stringify([proof.previousBrowserSessionID, proof.intentionSessionID,
        proof.previousProcessIdentity.pid, proof.previousProcessIdentity.launched, proof.windowIDs[0]]);
    }
    withClosureLedger(operation) {
      const run = async () => await this.loadClosureLedger() ? operation() : false;
      const result = this.closureLedgerTail.then(run, run);
      this.closureLedgerTail = result.catch(() => false);
      return result;
    }
    rememberParkingProof(plan, identity) {
      if (!plan.parkingWindows.length) return Promise.resolve(true);
      if (!identity) return Promise.resolve(false);
      return this.withClosureLedger(async () => {
        if (!this.sameProcess(this.identity()?.processIdentity, identity.processIdentity)) return false;
        // This ledger belongs to this extension profile, not every browser
        // profile sharing its PID. Host records never invent JS ownership.
        const entries = this.closureLedger.entries.filter(entry => this.sameProcess(entry.previousProcessIdentity, identity.processIdentity));
        for (const window of plan.parkingWindows) {
          const proof = {intentionSessionID:plan.intentionSessionID, previousBrowserSessionID:identity.browserSessionID,
            previousProcessIdentity:{...identity.processIdentity}, windowIDs:[window.windowID], closed:false};
          if (!entries.some(entry => this.closureProofKey(entry) === this.closureProofKey(proof))) entries.push(proof);
        }
        const pending = entries.filter(entry => !entry.closed);
        if (pending.length > 1024) return false;
        const next = [...pending, ...entries.filter(entry => entry.closed).slice(-256)];
        if (JSON.stringify(next) !== JSON.stringify(this.closureLedger.entries)) {
          this.closureLedger.entries = next; await this.saveClosureLedger();
        }
        return true;
      });
    }
    // Upgrade recovery requires the accepted plan AND the original durable
    // profile/process proof. Today's identity alone cannot create ownership.
    rememberParkingOwnership(intentionSessionID, previousIdentity) {
      return this.enqueue(async () => {
        const current = this.identity();
        if (!current || !previousIdentity || !this.sameProcess(current.processIdentity, previousIdentity.processIdentity)
            || !this.api.storage.session) return false;
        // Inspect the original profile-owned helper state before load() could
        // replace it with a fresh extension nonce after a worker/update restart.
        const saved = (await this.api.storage.session.get(this.key))[this.key];
        const prior = this.state?.browserSessionID === previousIdentity.browserSessionID ? this.state
          : saved?.browserSessionID === previousIdentity.browserSessionID ? saved : null;
        const plan = prior?.plans?.[intentionSessionID];
        if (!plan || plan.intentionSessionID !== intentionSessionID
            || JSON.stringify(this.identity()) !== JSON.stringify(current)) return false;
        return this.rememberParkingProof({...plan,parkingWindows:this.descriptors(plan.parkingWindows)}, previousIdentity);
      });
    }
    retireClosedWindows({force = false} = {}) {
      // Closure is background housekeeping: one bounded transport batch, never
      // queued ahead of new-session registration or tab visibility work.
      if (this.closureTask) { this.closureRerun ||= force; return this.closureTask; }
      if (!force && this.now() < this.closureNextAt) return Promise.resolve(false);
      this.closureNextAt = this.now() + 10000;
      this.closureTask = this.runClosurePass().catch(() => false).finally(() => {
        this.closureTask = null;
        if (this.closureRerun) { this.closureRerun = false; void this.retireClosedWindows({force:true}); }
      });
      return this.closureTask;
    }
    async runClosurePass() {
      const identity = this.identity();
      if (!identity) return false;
      const pending = await this.withClosureLedger(async () => {
        if (JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
        // Different-process IDs cannot identify today's windows. Discard only
        // local retry proof; native independently owns its old process journal.
        const entries = this.closureLedger.entries.filter(entry => this.sameProcess(entry.previousProcessIdentity, identity.processIdentity));
        if (entries.length !== this.closureLedger.entries.length) {
          this.closureLedger.entries = entries; await this.saveClosureLedger();
        }
        return entries.filter(entry => !entry.closed).map(entry => ({...entry,previousProcessIdentity:{...entry.previousProcessIdentity},windowIDs:[...entry.windowIDs]}));
      });
      if (!pending || !pending.length) return true;
      const windows = await this.api.windows.getAll({populate:false});
      if (!Array.isArray(windows) || windows.some(window => !Number.isSafeInteger(window?.id) || window.id < 0)
          || new Set(windows.map(window => window.id)).size !== windows.length
          || JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
      const live = new Set(windows.map(window => window.id));
      const absent = pending.filter(proof => !live.has(proof.windowIDs[0]));
      if (!absent.length) return true;
      // Rotate across profile-owned tuples and chunks so rejected historical
      // registrations cannot starve later captured holders.
      const groups = new Map();
      for (const proof of absent) {
        const key = JSON.stringify([proof.previousBrowserSessionID, proof.intentionSessionID]);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(proof);
      }
      for (const key of this.closureGroupOffsets.keys()) if (!groups.has(key)) this.closureGroupOffsets.delete(key);
      for (const key of this.closureSingleGroups) if (!groups.has(key)) this.closureSingleGroups.delete(key);
      const keys = [...groups.keys()].sort(), key = keys[this.closureCursor % keys.length], group = groups.get(key);
      this.closureCursor = (this.closureCursor + 1) % keys.length;
      const start = (this.closureGroupOffsets.get(key) || 0) % group.length;
      const batch = Array.from({length:Math.min(this.closureSingleGroups.has(key) ? 1 : 256,group.length)}, (_, index) => group[(start + index) % group.length]);
      this.closureGroupOffsets.set(key, (start + batch.length) % group.length);
      const first = batch[0];
      const nonce = globalThis.crypto?.randomUUID?.() || `${Date.now().toString(36)}-${++this.closureSerial}-${Math.random().toString(36).slice(2)}`;
      const requestID = `${identity.browserSessionID}-closed-${nonce}`;
      const accepted = await new Promise(resolve => {
        const timer = setTimeout(() => {this.closedPending.delete(requestID);resolve(false);},this.timeout);
        this.closedPending.set(requestID,value => {clearTimeout(timer);this.closedPending.delete(requestID);resolve(value);});
        try {
          if (!this.send({type:'windowVisibilityClosed',visibilityClosedRequest:{requestID,
            intentionSessionID:first.intentionSessionID,previousBrowserSessionID:first.previousBrowserSessionID,
            previousProcessIdentity:{...first.previousProcessIdentity},windowIDs:batch.map(proof => proof.windowIDs[0])}})) this.closedPending.get(requestID)?.(false);
        } catch (_) {this.closedPending.get(requestID)?.(false);}
      });
      if (!accepted) {
        // Candidate proof precedes registration. One uncaptured candidate must
        // not permanently poison a captured sibling in the same tuple.
        if (batch.length > 1) this.closureSingleGroups.add(key);
        return false;
      }
      if (JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
      const completed = new Set(batch.map(proof => this.closureProofKey(proof)));
      return this.withClosureLedger(async () => {
        if (JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
        for (const proof of this.closureLedger.entries) if (completed.has(this.closureProofKey(proof))) proof.closed = true;
        this.closureLedger.entries = [...this.closureLedger.entries.filter(proof => !proof.closed),
          ...this.closureLedger.entries.filter(proof => proof.closed).slice(-256)];
        await this.saveClosureLedger();
        return true;
      });
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
          windows:this.descriptors(windows), parkingWindows:this.descriptors(parkingWindows), revealWindowIDs:[]}, true);
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
    async submit(plan, captureParkingProof = false) {
      const identity = this.identity();
      if (captureParkingProof && plan.parkingWindows.length
          && (!identity || !this.api.storage.local || !await this.rememberParkingProof(plan, identity))) return false;
      // Durable before sending: native may capture a holder even if its ACK is
      // lost. Closure still requires host registration AND native capture proof.
      if (captureParkingProof && plan.parkingWindows.length && JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
      const fingerprint = JSON.stringify(plan);
      const previous = this.sent.get(plan.intentionSessionID);
      if (previous?.fingerprint === fingerprint && this.now() - previous.at < 10000) return true;
      if (!Number.isSafeInteger(this.state.revision) || this.state.revision >= Number.MAX_SAFE_INTEGER - 1) return false;
      const revision = ++this.state.revision;
      // Persist before sending, so worker suspension never reuses a revision.
      await this.save();
      if (captureParkingProof && plan.parkingWindows.length && JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
      const accepted = await new Promise(resolve => {
        const timer = setTimeout(() => { this.pending.delete(revision); resolve(false); }, this.timeout);
        this.pending.set(revision, value => { clearTimeout(timer); this.pending.delete(revision); resolve(value); });
        try {
          if (!this.send({type:'windowVisibilityPlan', visibilityPlan:{...plan, revision}})) this.pending.get(revision)?.(false);
        } catch (_) { this.pending.get(revision)?.(false); }
      });
      if (!accepted) return false;
      if (captureParkingProof && plan.parkingWindows.length && JSON.stringify(this.identity()) !== JSON.stringify(identity)) return false;
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
      const closed = message?.visibilityClosedReceipt;
      if (typeof closed?.requestID === 'string') this.closedPending.get(closed.requestID)?.(closed.accepted === true);
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
      for (const settle of [...this.closedPending.values()]) settle(false);
      this.processIdentity = null; this.nativeActive = null;
      this.sent.clear();
    }
  }
  root.IntentNativeWindowVisibility = IntentNativeWindowVisibility;
  if (typeof module !== 'undefined') module.exports = IntentNativeWindowVisibility;
})(typeof globalThis !== 'undefined' ? globalThis : this);
