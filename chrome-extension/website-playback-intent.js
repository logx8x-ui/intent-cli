/* One-use navigation evidence for manual YouTube playback across documents. */
(function(root) {
  "use strict";
  class WebsitePlaybackIntent {
    constructor({api,getRules,isAllowedTab,now=Date.now,pause=ms=>new Promise(resolve=>setTimeout(resolve,ms))}) {
      Object.assign(this,{api,getRules,isAllowedTab,now,pause});
      this.links=new Map();this.commits=new Map();this.createdTabs=new Map();this.sequence=0;
    }
    prune() {
      for(const map of [this.links,this.commits,this.createdTabs]) {
        for(const [id,value] of map) if(value.expires<=this.now()) map.delete(id);
        while(map.size>128) map.delete(map.keys().next().value);
      }
    }
    eligible(url,tab,current) {
      return current.active && current.websiteFeaturePolicies?.youtube
        && root.IntentWebsiteFeatures.videoID(url)
        && root.IntentWebsiteFeatures.permits(url,current.websiteFeaturePolicies)
        && this.isAllowedTab({...tab,url});
    }
    async remember(message,sender) {
      const current=this.getRules(), engine=root.IntentWebsiteFeatures;
      if(sender?.frameId!==0 || !Number.isInteger(sender?.tab?.id) || !current.active
          || message.websitePolicyKey!==engine.policyKey(current)
          || !["same-tab","new-tab"].includes(message.disposition)) return {remembered:false};
      const sequence=++this.sequence;
      const tab=await this.api.tabs.get(sender.tab.id).catch(()=>null);
      if(this.getRules()!==current || !tab || tab.url!==message.url
          || engine.siteOf(message.url)!=="youtube" || !this.isAllowedTab(tab)
          || !engine.permits(message.url,current.websiteFeaturePolicies)
          || !this.eligible(message.targetURL,tab,current)) return {remembered:false};
      this.prune();
      this.links.set(tab.id,{sourceURL:message.url,targetURL:message.targetURL,videoID:engine.videoID(message.targetURL),
        disposition:message.disposition,key:engine.policyKey(current),sequence,expires:this.now()+10000});
      return {remembered:true};
    }
    created(tab) {
      this.prune();
      this.createdTabs.set(tab.id,{openerTabId:tab.openerTabId,sequence:++this.sequence,expires:this.now()+10000});
    }
    beforeNavigate(details) {if(details.frameId===0) this.commits.delete(details.tabId);}
    committed(details) {
      if(details.frameId!==0 || details.tabId<0) return;
      this.commits.delete(details.tabId);
      const current=this.getRules(),engine=root.IntentWebsiteFeatures;
      if(!this.eligible(details.url,{id:details.tabId},current)) return;
      this.prune();
      const qualifiers=details.transitionQualifiers||[];
      const manual=qualifiers.includes("from_address_bar")
        || (!qualifiers.includes("client_redirect") && ["link","typed","generated","keyword","keyword_generated","auto_bookmark","reload"].includes(details.transitionType));
      if(manual) this.commits.set(details.tabId,{url:details.url,videoID:engine.videoID(details.url),
        documentId:details.documentId,key:engine.policyKey(current),expires:this.now()+10000});
    }
    async consume(message,sender) {
      const current=this.getRules(),engine=root.IntentWebsiteFeatures,key=engine.policyKey(current);
      if(sender?.frameId!==0 || !Number.isInteger(sender?.tab?.id) || message.websitePolicyKey!==key
          || sender.url!==message.url || !this.eligible(message.url,sender.tab,current)) return {allowed:false};
      // document_start can ask before onCommitted arrives. Wait briefly without
      // blocking rule application, then recheck the real tab and policy.
      for(let attempt=0;attempt<21;attempt++) {
        if(this.getRules()!==current) return {allowed:false};
        this.prune();
        const tab=await this.api.tabs.get(sender.tab.id).catch(()=>null);
        if(this.getRules()!==current || !tab || (tab.pendingUrl||tab.url)!==message.url || !this.eligible(message.url,tab,current)) return {allowed:false};
        const commit=this.commits.get(tab.id);
        if(commit?.url===message.url && commit.key===key
            && (!commit.documentId || !sender.documentId || commit.documentId===sender.documentId)) {
          this.commits.delete(tab.id);
          this.links.delete(tab.id);
          return {allowed:true,videoID:commit.videoID,websitePolicyKey:key};
        }
        const sourceID=tab.openerTabId, own=this.links.get(tab.id), opener=this.links.get(sourceID);
        const created=this.createdTabs.get(tab.id);
        const link=own?.disposition==="same-tab" ? own : opener?.disposition==="new-tab" && created?.openerTabId===sourceID && created.sequence>opener.sequence ? opener : null;
        // A full document must differ from the source. SPA playback is handled
        // locally; a new tab must have the browser-provided opener identity.
        if(link && link.targetURL===message.url && link.sourceURL!==message.url && link.key===key
            && (link===own || !sender.tab.url || sender.tab.id!==sourceID)) {
          this.links.delete(link===own?tab.id:sourceID);
          return {allowed:true,videoID:link.videoID,websitePolicyKey:key};
        }
        if(attempt<20) await this.pause(50);
      }
      return {allowed:false};
    }
    forget(tabId) {this.links.delete(tabId);this.commits.delete(tabId);this.createdTabs.delete(tabId);}
    clear() {this.links.clear();this.commits.clear();this.createdTabs.clear();}
  }
  root.IntentWebsitePlayback=WebsitePlaybackIntent;
  if(typeof module!=="undefined") module.exports=WebsitePlaybackIntent;
})(globalThis);
