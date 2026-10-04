/* Firefox-only one-shot startup assistance. Native retains all restore authority. */
(function(root) {
  class IntentFirefoxMinimizeBootstrap {
    constructor(api, options) {
      this.api = api; this.options = options; this.key = 'intentFirefoxMinimizeBootstrapV1';
      this.timeout = options.timeout ?? 500; this.now = options.now ?? Date.now;
      this.epoch = 0; this.fingerprint = null; this.rules = null; this.connected = false;
      this.offers = []; this.pendingClaims = new Map(); this.pendingResults = new Map();
      this.ledger = null; this.running = null; this.rerun = false;
      this.writes = Promise.resolve(); this.outboxTask = null; this.resultCursor = 0;
      this.workRevision = 0; this.offerFingerprint = null; this.windowEpochs = new Map();
      this.inFlight = new Map(); this.attempted = new Map(); this.resultRevision = 0; this.freshResults = new Set();
    }
    sameProcess(a,b) { return Number.isInteger(a?.pid) && a.pid > 0 && Number.isFinite(a.launched)
      && a.launched > 0 && a.pid === b?.pid && a.launched === b.launched; }
    validOffer(value) {
      return ['effectID','intentionSessionID','browserSessionID'].every(key => typeof value?.[key] === 'string'
        && value[key].length > 0 && value[key].length <= 256)
        && this.sameProcess(value.browserProcessIdentity,value.browserProcessIdentity)
        && Number.isSafeInteger(value.windowID) && value.windowID >= 0
        && Number.isSafeInteger(value.planRevision) && value.planRevision >= 0
        && Number.isFinite(value.expiresAtUnixMS) && value.descriptor?.windowID === value.windowID
        && ['normal','maximized'].includes(value.descriptor?.state);
    }
    invalidate() { ++this.epoch; }
    invalidateWindow(id) { if (Number.isSafeInteger(id) && id>=0) this.windowEpochs.set(id,(this.windowEpochs.get(id)||0)+1); }
    receive(message, context) {
      if (context) {
        if (this.fingerprint !== context.fingerprint) { this.invalidate(); ++this.workRevision; }
        this.fingerprint = context.fingerprint; this.rules = context.rules;
        const connected = Boolean(message?.hostCapabilities?.includes('firefox-window-minimize-bootstrap-host-v1'));
        if (connected !== this.connected) ++this.workRevision;
        this.connected = connected;
        if (!this.connected) this.invalidate();
      }
      const claim = message?.minimizeBootstrapClaimReceipt;
      if (typeof claim?.effectID === 'string') this.settle(this.pendingClaims,claim.effectID,claim.granted===true,message);
      const result = message?.minimizeBootstrapResultReceipt;
      if (typeof result?.effectID === 'string') this.settle(this.pendingResults,result.effectID,result.accepted===true,message);
      if (Array.isArray(message?.minimizeBootstrapOffers)) {
        const offers = message.minimizeBootstrapOffers.filter(x=>this.validOffer(x)).slice(0,256);
        const fingerprint = JSON.stringify(offers);
        if (fingerprint !== this.offerFingerprint) { this.offerFingerprint=fingerprint; ++this.workRevision; }
        this.offers=offers;
      }
      void this.pump();
    }
    settle(pending,id,value,message) {
      const request = pending.get(id);
      if (request && this.sameProcess(message?.browserProcessIdentity,request.processIdentity)
          && this.sameProcess(this.options.identity()?.processIdentity,request.processIdentity)) request.settle(value);
    }
    disconnected() {
      this.connected = false; this.invalidate();
      for (const request of this.pendingClaims.values()) request.settle(false);
      for (const request of this.pendingResults.values()) request.settle(false);
    }
    eligible(offer, epoch) {
      const identity = this.options.identity();
      return this.connected && epoch.rules === this.epoch && epoch.window === (this.windowEpochs.get(offer.windowID)||0) && this.rules?.active && this.rules.nativeWindowVisibility
        && this.rules.startupSessionID === offer.intentionSessionID && this.now() < offer.expiresAtUnixMS
        && identity?.browserSessionID === offer.browserSessionID
        && this.sameProcess(identity.processIdentity,offer.browserProcessIdentity);
    }
    async load() {
      if (this.ledger) return;
      if (!this.api.storage?.local) throw new Error('Durable bootstrap storage unavailable');
      await this.writes.catch(()=>{});
      const saved = (await this.api.storage.local.get(this.key))[this.key];
      if (saved && (saved.version !== 1 || !Array.isArray(saved.entries) || saved.entries.length > 512
          || new Set(saved.entries.map(x=>x?.offer?.effectID)).size !== saved.entries.length
          || saved.entries.some(x=>!this.validOffer(x.offer) || !['claiming','dispatching','result','acknowledged'].includes(x.phase)
            || (['result','acknowledged'].includes(x.phase) && !['settled','notDispatched','uncertain'].includes(x.outcome)))))
        throw new Error('Invalid bootstrap ledger');
      this.ledger = saved || {version:1,entries:[]};
      // A prior context cannot still invoke our JavaScript call. An already
      // issued API operation may survive it, so dispatching is never replayed.
      let changed = false;
      for (const item of this.ledger.entries) {
        if (item.phase === 'claiming' || item.phase === 'dispatching') {
          item.outcome = item.phase === 'claiming' ? 'notDispatched' : 'uncertain';
          item.phase = 'result'; changed = true;
        }
      }
      if (changed) await this.save();
    }
    save() {
      if (!this.ledger) return Promise.reject(new Error('Bootstrap ledger unavailable'));
      const snapshot = JSON.parse(JSON.stringify(this.ledger));
      const write = this.writes.catch(()=>{}).then(()=>this.api.storage.local.set({[this.key]:snapshot}));
      this.writes = write;
      return write.catch(error=>{this.ledger = null;throw error;});
    }
    request(type, property, payload, pending) {
      return new Promise(resolve=>{
        const timer = setTimeout(()=>settle(false),this.timeout);
        const settle = value=>{clearTimeout(timer);pending.delete(payload.effectID);resolve(value);};
        pending.set(payload.effectID,{settle,processIdentity:{...payload.previousProcessIdentity}});
        try { if (!this.options.send({type,[property]:payload})) settle(false); }
        catch (_) { settle(false); }
      });
    }
    proof(offer) { return {effectID:offer.effectID,intentionSessionID:offer.intentionSessionID,
      previousBrowserSessionID:offer.browserSessionID,previousProcessIdentity:{...offer.browserProcessIdentity}}; }
    async result(item,outcome) {
      item.phase = 'result'; item.outcome = outcome; await this.save();
      ++this.resultRevision; this.freshResults.add(item.offer.effectID);
      void this.flushResults();
    }
    async deliver(item) {
      const identity = this.options.identity();
      if (!this.connected || !this.sameProcess(identity?.processIdentity,item.offer.browserProcessIdentity)) return;
      const accepted = await this.request('windowMinimizeBootstrapResult','minimizeBootstrapResult',
        {...this.proof(item.offer),outcome:item.outcome},this.pendingResults);
      if (accepted && this.sameProcess(this.options.identity()?.processIdentity,item.offer.browserProcessIdentity)) {
        // The effect result may settle while another effect persists its intent.
        // Save snapshots through one short write queue; transport never owns it.
        if (!this.ledger) return;
        const current = this.ledger.entries.find(x=>x.offer.effectID===item.offer.effectID);
        if (current?.phase !== 'result' || current.outcome !== item.outcome) return;
        current.phase = 'acknowledged'; await this.save();
      }
    }
    flushResults() {
      if (this.outboxTask || !this.ledger || !this.connected) return this.outboxTask;
      const results = this.ledger.entries.filter(x=>x.phase==='result');
      if (!results.length) return;
      const revision = this.resultRevision;
      const item = results.find(x=>this.freshResults.has(x.offer.effectID)) || results[this.resultCursor++ % results.length];
      this.freshResults.delete(item.offer.effectID);
      this.outboxTask = this.deliver(item).catch(()=>{}).finally(()=>{
        this.outboxTask=null;
        // New settlements get one prompt delivery after the bounded older call;
        // rejected historical receipts alone never cause a busy retry loop.
        if (revision !== this.resultRevision || this.freshResults.size) void this.flushResults();
      });
      return this.outboxTask;
    }
    async run(offer) {
      const epoch = {rules:this.epoch,window:this.windowEpochs.get(offer.windowID)||0};
      if (!this.eligible(offer,epoch) || !await this.options.validate(offer) || !this.eligible(offer,epoch)) return;
      const item = {offer,phase:'claiming'};
      // Expired, acknowledged offers can never grant another action. The host
      // retains the effect tombstone; unresolved local results are never evicted.
      this.ledger.entries = this.ledger.entries.filter(x=>x.phase!=='acknowledged' || this.offers.some(o=>o.effectID===x.offer.effectID));
      if (this.ledger.entries.length >= 512) return;
      this.ledger.entries.push(item); await this.save();
      if (!this.eligible(offer,epoch)) return this.result(item,'notDispatched');
      const granted = await this.request('windowMinimizeBootstrapClaim','minimizeBootstrapClaim',this.proof(offer),this.pendingClaims);
      if (!granted || !this.eligible(offer,epoch)) return this.result(item,'notDispatched');
      item.phase = 'dispatching'; await this.save();
      if (!await this.options.validate(offer) || !this.eligible(offer,epoch)) return this.result(item,'notDispatched');
      // No await between the final generation fence and this sole effect call.
      // focused:false itself changes foreground order; deliberately omit it.
      let outcome = 'uncertain';
      try {
        await this.api.windows.update(offer.windowID,{state:'minimized'});
        outcome = 'settled'; // Native AX, not a browser receipt, verifies hiding.
      } catch (_) { /* Rejecting an API promise is not proof that no effect ran. */ }
      await this.result(item,outcome);
    }
    pump() {
      if (this.running) return this.running;
      const revision = this.workRevision;
      this.running = (async()=>{
        if (!this.ledger && this.inFlight.size) return;
        await this.load();
        void this.flushResults();
        for (const offer of this.offers) {
          if (this.inFlight.size >= 4) break;
          if (this.inFlight.has(offer.effectID) || this.attempted.get(offer.effectID)===this.workRevision
              || this.ledger.entries.some(x=>x.offer.effectID===offer.effectID)) continue;
          this.attempted.set(offer.effectID,this.workRevision);
          const task = this.run(offer).catch(()=>{}).finally(()=>{
            this.inFlight.delete(offer.effectID);
            if (this.offers.some(x=>!this.inFlight.has(x.effectID) && this.attempted.get(x.effectID)!==this.workRevision))
              void this.pump();
          });
          this.inFlight.set(offer.effectID,task);
        }
      })().catch(()=>{}).finally(()=>{
        this.running = null;
        // Only changed offers/rules schedule another pass; receipts alone must
        // not create a rejection/timeout busy loop.
        if (this.workRevision !== revision) queueMicrotask(()=>this.pump());
      });
      return this.running;
    }
  }
  root.IntentFirefoxMinimizeBootstrap = IntentFirefoxMinimizeBootstrap;
  if (typeof module !== 'undefined') module.exports = IntentFirefoxMinimizeBootstrap;
})(typeof globalThis !== 'undefined' ? globalThis : this);
