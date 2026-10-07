const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function harness(browserName, url, hasRoot = true, transport = null, readyState = "complete") {
  const nodes = [], documentListeners = new Map(), pageListeners = new Map(), observers = [];
  const frames = new Map(), timeouts = new Map(), intervals = new Map(), messages = [];
  let id = 0, listener, initialReply, paused = 0, played = 0;
  const location = {href:url};
  class Element {
    constructor(tag) { this.tagName=tag; this.attrs={}; this.children=[]; this.parentNode=null; this.textContent=''; this.style={}; nodes.push(this); }
    get isConnected() { return this === document.documentElement || Boolean(this.parentNode?.isConnected); }
    appendChild(child) { child.remove(); child.parentNode=this; this.children.push(child); return child; }
    append(...items) { items.forEach(item=>this.appendChild(item)); }
    remove() { if(this.parentNode) this.parentNode.children=this.parentNode.children.filter(x=>x!==this); this.parentNode=null; }
    setAttribute(k,v) { this.attrs[k]=v; }
    getAttribute(k) { return this.attrs[k] ?? null; }
    hasAttribute(k) { return k in this.attrs; }
    removeAttribute(k) { delete this.attrs[k]; }
    pause() { paused++; this.paused = true; }
    play() {
      played++; this.paused = false;
      for (const fn of documentListeners.get('play') || []) fn({type:'play',target:this,isTrusted:true});
      return Promise.resolve();
    }
    closest(selector) {
      if(selector==='a[href]') return this.tagName==='a' ? this : this.parentNode?.closest(selector);
      if(selector.includes('navigation')) return this.navigation ? this : null;
      if(selector.includes('contenteditable')) return ['input','textarea','select'].includes(this.tagName) || this.isContentEditable || this.editable ? this : this.parentNode?.closest(selector);
      if(selector.includes('ytp-play-button') && this.playButton) return this;
      if(selector.includes('video') && (this.player || selector.includes('html5-video-player') && this.playerContainer)) return this;
      return this.parentNode?.closest(selector) || null;
    }
    querySelector() { return this.icon ? this : null; }
  }
  const document = {
    documentElement:null,body:null,readyState,
    createElement: tag=>new Element(tag),
    addEventListener(name,fn) { (documentListeners.get(name) || documentListeners.set(name,[]).get(name)).push(fn); },
    querySelectorAll(selector) {
      return nodes.filter(n=>n.isConnected && (
        selector==='[data-intent-feature-hidden]' ? n.hasAttribute('data-intent-feature-hidden') :
        selector==='video,audio' ? ['video','audio'].includes(n.tagName) :
        selector.startsWith('[role="tab"]') ? n.getAttribute('role')==='tab' || n.getAttribute('data-intent-feature-hidden')==='shorts' :
        selector.startsWith('a[href]') ? n.tagName==='a' || n.getAttribute('data-intent-feature-hidden')==='navigation' : false));
    }
  };
  function mount() {
    document.documentElement=new Element('html'); document.body=new Element('body'); document.documentElement.appendChild(document.body);
    for(const o of observers) if(o.active) o.fn();
  }
  if(hasRoot) mount();
  const runtime = {
    onMessage:{addListener(fn){listener=fn;}},
    sendMessage(message,callback) {
      messages.push(message);
      if(message.type==='getActiveRules') {
        if(browserName==='firefox') return new Promise(resolve=>initialReply=resolve);
        initialReply=callback; return;
      }
      const response = transport ? transport(message) : {routed:true};
      if(browserName==='firefox') return Promise.resolve(response);
      Promise.resolve(response).then(value=>callback?.(value));
    }
  };
  const context = {
    [browserName==='firefox'?'browser':'chrome']:{runtime}, document, location, URL,
    setTimeout(fn){ const key=++id; timeouts.set(key,fn); return key; }, clearTimeout(key){timeouts.delete(key);},
    setInterval(fn){ const key=++id; intervals.set(key,fn); return key; }, clearInterval(key){intervals.delete(key);},
    requestAnimationFrame(fn){const key=++id;frames.set(key,fn);return key;},cancelAnimationFrame(key){frames.delete(key);},
    MutationObserver:class { constructor(fn){this.fn=fn;this.active=false;observers.push(this);} observe(){this.active=true;} disconnect(){this.active=false;} },
    addEventListener(name,fn){(pageListeners.get(name)||pageListeners.set(name,[]).get(name)).push(fn);}
  };
  vm.runInNewContext(fs.readFileSync(browserName+'-extension/website-features.js','utf8'),context);
  vm.runInNewContext(fs.readFileSync(browserName+'-extension/site-feature-guard.js','utf8'),context);
  return {
    nodes,document,messages,frames,timeouts,intervals,engine:context.IntentWebsiteFeatures,
    get paused(){return paused;}, get played(){return played;}, mount,
    add(tag,props={}) {const n=Object.assign(new Element(tag),props);document.documentElement.appendChild(n);return n;},
    update(rules, request='request') { const replies=[]; listener({type:'rulesUpdated',rules,websiteRequestID:request},{},r=>replies.push(r));return replies; },
    async initial(rules) {initialReply(rules);await Promise.resolve();await Promise.resolve();},
    frame(){const batch=[...frames.values()];frames.clear();batch.forEach(fn=>fn());},
    expire(){const batch=[...timeouts.values()];timeouts.clear();batch.forEach(fn=>fn());},
    interval(){for(const fn of intervals.values())fn();this.frame();},
    route(url,event='popstate'){location.href=url;for(const fn of pageListeners.get(event)||[])fn();this.frame();},
    event(name,target,props={}) { const e={type:name,target,isTrusted:true,preventDefault(){this.prevented=true;},stopImmediatePropagation(){this.stopped=true;},...props};for(const fn of documentListeners.get(name)||[])fn(e);return e; }
  };
}
const ig={active:true,startupSessionID:'ig-session',websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:['messages']}}};
const yt={active:true,startupSessionID:'yt-session',websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:['search']}}};
async function flush() {for(let i=0;i<8;i++) await Promise.resolve();}
(async()=>{
for(const browser of ['firefox','chrome']) {
  for (const firstPolicy of ['initial','update']) {
    for (const allowed of [false,true]) {
      let resolveHandoff;
      const h=harness(browser,'https://www.youtube.com/watch?v=fresh',true,message=>
        message.type==='consumeWebsitePlaybackIntent' ? new Promise(resolve=>resolveHandoff=resolve) : {},'loading');
      const media=h.add('video',{player:true});await media.play();
      assert.equal(h.paused,0,'Unresolved rules have not guessed an active restriction');
      h.document.readyState='complete';
      if(firstPolicy==='initial') await h.initial(yt); else h.update(yt);
      assert.equal(h.paused,1,'First active policy catches a fresh document play that occurred before rules arrived');
      assert.equal(media.paused,true);
      resolveHandoff({allowed,videoID:'fresh',websitePolicyKey:h.engine.policyKey(yt)});await flush();
      assert.equal(h.played,allowed?2:1,'Only the exact approved manual handoff can resume the early media');
      if(firstPolicy==='update') {
        await h.initial({active:false});
        assert.ok(h.nodes.some(n=>n.id==='intent-site-feature-style'&&n.isConnected),'Late initial reply cannot replace the newer active policy');
      }
    }
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=existing',true,null,'loading');
    await h.initial({active:false});const media=h.add('video',{player:true});await media.play();h.update(yt);
    assert.equal(h.paused,0,'A page that already saw inactive rules keeps current playback when the intention starts');
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=cancelled-before-root',false,null,'loading');
    h.update(yt);h.update({active:false});h.mount();const media=h.add('video',{player:true});await media.play();h.update(yt);
    assert.equal(h.paused,0,'A cancelled first-policy gate cannot reappear when a later intention starts');
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=loaded',true,null,'complete');
    const media=h.add('video',{player:true});await media.play();await h.initial(yt);
    assert.equal(h.paused,0,'Injection into an already-loaded page preserves current playback at intention start');
  }

  {
    const h=harness(browser,'https://www.instagram.com/',false), replies=h.update(ig);
    assert.equal(replies.length,0,'No root means no success receipt');
    h.mount();h.frame();
    assert.equal(replies.length,1);assert.equal(replies[0].websiteFeatures,true);
    assert.equal(replies[0].websiteRequestID,'request');assert.equal(replies[0].websitePolicyKey,h.engine.policyKey(ig));
    assert.equal(replies[0].startupSessionID,'ig-session');
    assert.ok(h.nodes.some(n=>n.id==='intent-site-feature-style'&&n.isConnected));
    assert.equal(h.document.documentElement.getAttribute('data-intent-site-blocked'),'true');
    assert.equal(h.messages.filter(m=>m.type==='routeWebsiteFeature').length,1,'Messages-only asks background for same-tab inbox');
    h.interval();assert.equal(h.messages.filter(m=>m.type==='routeWebsiteFeature').length,1,'No redirect loop');
    h.route('https://www.instagram.com/direct/inbox/');
    assert.equal(h.document.documentElement.hasAttribute('data-intent-site-blocked'),false);
    assert.equal(h.nodes.some(n=>n.id==='intent-site-feature-notice'&&n.isConnected),false);
  }
  {
    const h=harness(browser,'https://www.instagram.com/',false), pending=h.update(ig);
    const ended=h.update({active:false});assert.equal(pending[0].websiteFeatures,false);assert.equal(ended[0].websiteFeatures,true);
    await h.initial(ig);h.mount();h.frame();
    assert.equal(h.nodes.some(n=>n.id==='intent-site-feature-style'),false,'Late initial response cannot resurrect ended policy');
    assert.equal(h.messages.some(m=>m.type==='routeWebsiteFeature'),false);
    assert.equal(h.intervals.size,0);assert.equal(h.timeouts.size,0);
  }
  {
    const h=harness(browser,'https://www.instagram.com/',false), a=h.update(ig,'a');
    const replacement={...ig,startupSessionID:'replacement',websiteFeaturePolicies:{instagram:{version:1,allowedFeatures:['feed']}}};
    const b=h.update(replacement,'b');h.mount();h.frame();
    assert.equal(a[0].websiteFeatures,false);assert.equal(b[0].websiteFeatures,true);
    assert.equal(b[0].startupSessionID,'replacement');assert.equal(h.messages.some(m=>m.type==='routeWebsiteFeature'),false);
    assert.equal(h.document.documentElement.hasAttribute('data-intent-site-blocked'),false);
  }
  {
    const h=harness(browser,'https://www.instagram.com/',false), replies=h.update(ig);h.expire();
    assert.equal(replies[0].websiteFeatures,false,'Timeout is failure, never a synthetic readiness success');
    h.mount();h.frame();assert.equal(replies.length,1,'Expired request cannot acknowledge later');
    assert.equal(h.update(ig,'retry')[0].websiteFeatures,true);
  }
  {
    const h=harness(browser,'https://www.instagram.com/direct/inbox/');
    const profile=h.add('a',{href:'https://www.instagram.com/someone/',navigation:true});
    const thread=h.add('a',{href:'https://www.instagram.com/direct/t/123/',navigation:true});
    h.update(ig);assert.equal(profile.getAttribute('data-intent-feature-hidden'),'navigation');assert.equal(thread.hasAttribute('data-intent-feature-hidden'),false);
    for(const name of ['click','auxclick']) {const e=h.event(name,profile);assert.equal(e.prevented,true);assert.equal(e.stopped,true);}
    assert.equal(h.event('click',thread).prevented,undefined);
    h.route('https://www.instagram.com/reels/');assert.equal(h.messages.at(-1).type,'routeWebsiteFeature');
    h.route('https://www.instagram.com/accounts/login/');assert.equal(h.document.documentElement.hasAttribute('data-intent-site-blocked'),false);
    h.update({active:false});assert.equal(profile.hasAttribute('data-intent-feature-hidden'),false);assert.equal(h.intervals.size,0);
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=old');h.update(yt);
    const media=h.add('video',{player:true});
    h.event('pointerdown',media);h.interval();h.interval();h.interval();h.interval();h.event('play',media);
    assert.equal(h.paused,0,'Deliberate play survives slow loading, with no elapsed-time cutoff');
    h.route('https://www.youtube.com/watch?v=automatic','yt-navigate-finish');h.event('play',media);
    assert.equal(h.paused,1,'Automatic next video is not authorized by previous player input');
    h.event('pointerdown',h.add('div'));h.event('play',media);assert.equal(h.paused,2,'Unrelated clicks cannot authorize autoplay');
    h.route('https://www.youtube.com/watch?v=old','yt-navigate-finish');h.event('play',media);assert.equal(h.paused,3,'Automatic return to a previously played video is not a permanent permission');
    h.event('keydown',media,{key:' '});h.event('play',media);assert.equal(h.paused,3,'Explicit player keyboard playback works');
    const link=h.add('a',{href:'https://www.youtube.com/watch?v=chosen'});h.event('click',link);
    h.route(link.href,'yt-navigate-finish');h.interval();h.interval();h.interval();h.interval();h.event('play',media);
    assert.equal(h.paused,3,'A clicked video is authorized across delayed SPA navigation');
    h.update({...yt,websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:['search','autoplay']}}});
    h.route('https://www.youtube.com/watch?v=auto-enabled');h.event('play',media);assert.equal(h.paused,3);
    h.route('https://www.youtube.com/shorts/blocked');const before=h.paused;h.event('play',media);assert.equal(h.paused,before+1,'Autoplay setting never overrides route restrictions');
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=page-key');h.update(yt);
    const media=h.add('video',{player:true});
    h.event('keydown',h.document.body,{key:'k'});h.event('play',media);
    assert.equal(h.paused,0,'YouTube K works when the document body owns focus');
    h.route('https://www.youtube.com/watch?v=page-space');
    h.event('keydown',h.document.documentElement,{key:' '});h.event('play',media);
    assert.equal(h.paused,0,'YouTube Space works with page focus');
    for(const [target,props] of [
      [h.add('input'),{key:'k'}], [h.add('textarea'),{key:' '}],
      [h.add('div',{isContentEditable:true}),{key:'k'}], [h.add('div'),{key:'k'}],
      [h.document.body,{key:'k',ctrlKey:true}], [h.document.body,{key:'k',metaKey:true}],
      [h.document.body,{key:' ',repeat:true}], [h.document.body,{key:' ',shiftKey:true}], [h.document.body,{key:'Enter'}],
      [h.document.body,{key:'k',isTrusted:false}]
    ]) {
      h.route('https://www.youtube.com/watch?v=ungranted-'+h.paused);
      const before=h.paused;h.event('keydown',target,props);h.event('play',media);
      assert.equal(h.paused,before+1,'Editing, modified/repeat shortcuts and unrelated targets cannot authorize playback');
    }
    for(const props of [{button:2},{button:1},{button:0,isPrimary:false}]) {
      h.route('https://www.youtube.com/watch?v=pointer-ungranted-'+h.paused);
      const before=h.paused;h.event('pointerdown',media,props);h.event('play',media);
      assert.equal(h.paused,before+1,'Context/middle/nonprimary pointer actions do not mean Play');
    }
    h.route('https://www.youtube.com/watch?v=button-enter');
    h.event('keydown',h.add('button',{playButton:true}),{key:'Enter'});h.event('play',media);
    const before=h.paused;h.event('play',media);assert.equal(h.paused,before,'Enter on the actual play control is deliberate');
  }
  {
    const allowedShorts={...yt,websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:['search','shorts']}}};
    const h=harness(browser,'https://www.youtube.com/shorts/chosen');h.update(allowedShorts);
    const media=h.add('video',{player:true});h.event('pointerdown',media);h.event('play',media);
    assert.equal(h.paused,0,'An allowed Shorts route has a video identity and supports deliberate play with autoplay off');
    h.route('https://www.youtube.com/shorts/automatic');h.event('play',media);assert.equal(h.paused,1);
    h.event('keydown',h.document.body,{key:'k'});h.event('play',media);assert.equal(h.paused,1);
    h.update(yt);const before=h.paused;h.event('keydown',h.document.body,{key:'k'});h.event('play',media);
    assert.equal(h.paused,before+1,'Manual playback never bypasses the separate Shorts route restriction');
  }
  {
    let remembered=null;
    const transport=message=>{
      if(message.type==='rememberWebsitePlaybackIntent') {remembered=message;return {remembered:true};}
      if(message.type==='consumeWebsitePlaybackIntent' && remembered && message.url===remembered.targetURL) {
        const reply={allowed:true,videoID:'chosen-document',websitePolicyKey:remembered.websitePolicyKey};remembered=null;return reply;
      }
      return {allowed:false};
    };
    const source=harness(browser,'https://www.youtube.com/results?search_query=test',true,transport);source.update(yt);
    const link=source.add('a',{href:'https://www.youtube.com/watch?v=chosen-document'});source.event('click',link);
    assert.equal(remembered.disposition,'same-tab');assert.equal(remembered.url,'https://www.youtube.com/results?search_query=test');
    assert.equal(remembered.websitePolicyKey,source.engine.policyKey(yt));
    // A separate JS context represents the full document replacement.
    const dest=harness(browser,link.href,true,transport);dest.update(yt);
    const media=dest.add('video',{player:true});dest.event('play',media);assert.equal(dest.paused,1);
    await flush();assert.equal(dest.played,1,'A validated handoff resumes only media paused awaiting this manual navigation');
    assert.equal(dest.paused,1,'Resumed explicit playback is not immediately paused again');
    dest.route('https://www.youtube.com/watch?v=automatic-next');dest.event('play',media);await flush();
    assert.equal(dest.paused,2);assert.equal(dest.played,1,'Consumed navigation intent cannot authorize automatic next');
  }
  {
    const source=harness(browser,'https://www.youtube.com/watch?v=source');source.update(yt);
    const link=source.add('a',{href:'https://www.youtube.com/watch?v=new-child'});
    const first=()=>source.messages.filter(m=>m.type==='rememberWebsitePlaybackIntent');
    for(const [event,props] of [['auxclick',{button:1}],['click',{metaKey:true}],['click',{ctrlKey:true}],['click',{shiftKey:true}]]) {
      source.event(event,link,props);assert.equal(first().at(-1).disposition,'new-tab');
    }
    link.target='_blank';source.event('click',link);assert.equal(first().at(-1).disposition,'new-tab');link.target='';
    const count=first().length;
    source.event('auxclick',link,{button:2});source.event('click',link,{isTrusted:false});source.event('click',link,{altKey:true});
    link.setAttribute('download','');source.event('click',link);link.removeAttribute('download');
    const blocked=source.add('a',{href:'https://www.youtube.com/shorts/disallowed'});source.event('click',blocked);
    assert.equal(first().length,count,'Right-click, synthetic/download gestures and blocked routes create no handoff');
    source.route(link.href);const media=source.add('video',{player:true});source.event('play',media);
    assert.equal(source.paused,1,'A new-tab click cannot grant matching automatic playback in the source document');
    const child=harness(browser,link.href,true,message=>message.type==='consumeWebsitePlaybackIntent'
      ? {allowed:true,videoID:'new-child',websitePolicyKey:source.engine.policyKey(yt)} : {allowed:false});
    child.update(yt);const childMedia=child.add('video',{player:true});child.event('play',childMedia);await flush();
    assert.equal(child.played,1,'The intended child document can receive the background-validated one-shot grant');
  }
  {
    const replies=[];
    const h=harness(browser,'https://www.youtube.com/watch?v=before',true,message=>message.type==='consumeWebsitePlaybackIntent'
      ? new Promise(resolve=>replies.push({message,resolve})) : {});h.update(yt);
    const media=h.add('video',{player:true});h.event('play',media);
    h.route('https://www.youtube.com/watch?v=after');h.event('play',media);
    replies[0].resolve({allowed:true,videoID:'before',websitePolicyKey:h.engine.policyKey(yt)});await flush();
    assert.equal(h.played,0,'A stale document/route handoff cannot start a later player');
    h.route('https://www.youtube.com/watch?v=before');h.event('play',media);await flush();
    assert.equal(h.played,0,'Returning to the old URL does not revive a consumed stale response');
    h.update({active:false});replies.at(-1).resolve({allowed:true,videoID:'before',websitePolicyKey:h.engine.policyKey(yt)});await flush();
    assert.equal(h.played,0,'Ending the intention fences an outstanding playback handoff');
  }
  {
    for(const mutate of ['input','removed','wrong-video','wrong-policy','blocked-route']) {
      let reply;
      const h=harness(browser,'https://www.youtube.com/watch?v=manual',true,message=>message.type==='consumeWebsitePlaybackIntent'
        ? new Promise(resolve=>reply=resolve) : {});h.update(yt);
      const media=h.add('video',{player:true});h.event('play',media);
      if(mutate==='input') h.event('pointerdown',h.add('div'));
      if(mutate==='removed') media.remove();
      if(mutate==='blocked-route') h.route('https://www.youtube.com/shorts/manual');
      reply({allowed:true,videoID:mutate==='wrong-video'?'other':'manual',websitePolicyKey:mutate==='wrong-policy'?'stale':h.engine.policyKey(yt)});
      await flush();assert.equal(h.played,0,mutate+': late handoff must not resume this player');
    }
  }
  {
    const h=harness(browser,'https://www.youtube.com/watch?v=already-playing');
    const media=h.add('video',{player:true,paused:false});h.update(yt);
    assert.equal(h.paused,0,'Starting an intention does not stop an already-playing allowed video merely for lacking historic input');
    h.route('https://www.youtube.com/watch?v=next');h.event('play',media);assert.equal(h.paused,1);
  }
  {
    const h=harness(browser,'https://www.youtube.com/results?search_query=test');
    const chip=h.add('button',{textContent:'Shorts'});chip.setAttribute('role','tab');h.update(yt);
    assert.equal(chip.getAttribute('data-intent-feature-hidden'),'shorts');
    h.update({active:false});assert.equal(chip.hasAttribute('data-intent-feature-hidden'),false);
  }
}
console.log('Website guard: real content scripts, DOM-ready receipts, cancellation, SPA routing, surfaces and deliberate playback passed (Chrome + Firefox)');
})().catch(e=>{console.error(e);process.exit(1);});
