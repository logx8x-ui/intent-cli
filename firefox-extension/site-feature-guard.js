/* No page text or message contents leave this script. */
(() => {
  "use strict";
  if (globalThis.intentWebsiteFeatureGuardInstalled === 2) return;
  globalThis.intentWebsiteFeatureGuardInstalled = 2;
  const api = typeof browser !== "undefined" ? browser : chrome;
  const engine = IntentWebsiteFeatures;
  const site = engine.siteOf(location.href);
  if (!site) return;
  const startedDuringDocumentLoad = document.readyState === "loading";
  let rules = {active:false}, generation = 0, receivedUpdate = false, receivedPolicy = false;
  let initialPlaybackGate = false;
  let observer = null, timer = null, frame = null, style = null, notice = null;
  let routeAttempt = null, permittedVideo = null, pendingVideo = null, observedVideo = null, observedRoute = null;
  let handoffAttempt = null, handoffPending = null, guardedPlay = null, interactionVersion = 0;
  const waiting = new Set();
  const policy = () => rules.active ? rules.websiteFeaturePolicies?.[site] : null;
  function send(message) {
    if (typeof browser !== "undefined") return api.runtime.sendMessage(message);
    return new Promise((resolve, reject) => api.runtime.sendMessage(message, response => {
      if (api.runtime.lastError) reject(new Error(api.runtime.lastError.message)); else resolve(response);
    }));
  }
  const videoID = (raw = location.href) => engine.videoID(raw);
  function observeVideo() {
    const id = videoID();
    let route = null;
    try { route = new URL(location.href).pathname.split("/")[1]; } catch (_) {}
    if (id !== observedVideo || route !== observedRoute) {
      observedVideo = id; observedRoute = route; permittedVideo = null;
      handoffAttempt = null; handoffPending = null; guardedPlay = null;
      if (pendingVideo && pendingVideo.id !== id && pendingVideo.sourceID !== id) pendingVideo = null;
    }
    return id;
  }
  function playbackHandoff(id) {
    const p = policy();
    if (site !== "youtube" || !id || !p || p.allowedFeatures?.includes("autoplay")
        || !engine.permits(location.href, rules.websiteFeaturePolicies)) return;
    const key = engine.policyKey(rules), attempt = generation + ":" + observedRoute + ":" + id;
    if (handoffAttempt === attempt) return;
    handoffAttempt = attempt;
    const pending = {generation,id,key,attempt}; handoffPending = pending;
    // Background owns tab/opener and navigation identity; this document never
    // grants itself permission merely because a matching URL is open elsewhere.
    send({type:"consumeWebsitePlaybackIntent", url:location.href, websitePolicyKey:key}).then(result => {
      if (handoffPending !== pending) return;
      handoffPending = null;
      if (!result?.allowed || result.videoID !== id || result.websitePolicyKey !== key
          || generation !== pending.generation || videoID() !== id || engine.policyKey(rules) !== key
          || !policy() || !engine.permits(location.href, rules.websiteFeaturePolicies)) return;
      permittedVideo = id;
      const held = guardedPlay; guardedPlay = null;
      // Resume only the exact media that this guard paused while awaiting this
      // handoff. A later gesture, route, policy or replacement player cancels it.
      if (held?.pending === pending && held.interaction === interactionVersion
          && held.target?.isConnected && held.target.paused === true) {
        try { Promise.resolve(held.target.play?.()).catch(() => {}); } catch (_) {}
      }
    }).catch(() => { if (handoffPending === pending) handoffPending = null; });
  }
  function receipt(waiter, ready) {
    clearTimeout(waiter.timeout); waiting.delete(waiter);
    waiter.respond({websiteFeatures:ready, websiteRequestID:waiter.id,
      websitePolicyKey:waiter.key, startupSessionID:rules.startupSessionID || null});
  }
  function finishReceipts(ready) {
    for (const waiter of [...waiting]) receipt(waiter, ready && waiter.generation === generation);
  }
  function schedule() {
    if (frame === null) frame = requestAnimationFrame(() => { frame = null; render(); });
  }
  function ensureObservation() {
    if (!observer) {
      observer = new MutationObserver(schedule);
      // Observe the Document: document_start may precede the HTML element.
      observer.observe(document, {childList:true, subtree:true});
      timer = setInterval(schedule, 500);
    }
  }
  function markInstagramSurface(name, elements, hidden) {
    const targets = new Set(hidden ? elements : []);
    for (const previous of document.querySelectorAll('[data-intent-feature-hidden="' + name + '"]')) {
      if (!targets.has(previous)) previous.removeAttribute("data-intent-feature-hidden");
    }
    for (const element of targets) element.setAttribute("data-intent-feature-hidden", name);
  }
  // Observed native Home uses MAIN > ... > UL > LI > DIV[role=button]
  // for Stories, without an href. Restrict the English label fallback to that
  // structural context; never classify an arbitrary image or profile avatar.
  function instagramControlFeature(target) {
    const story = target?.closest?.('[role="button"][aria-label^="Story by "]');
    if (story?.closest("main") && story.closest("ul")) return "stories";
    const button = target?.closest?.('[role="button"],button');
    if (button?.querySelector?.('svg[aria-label="Messages"]')) return "messages";
    return null;
  }
  function instagramSurfaces(p) {
    const surfaces = engine.instagramSurfaces(p);
    const home = new URL(location.href).pathname === "/";
    // Observed Home posts are MAIN/ARTICLE descendants with a canonical post
    // permalink. ARTICLE alone is not a post: a tray/dialog can use it too.
    // Keep this Home-only so inbox and story viewers never inherit feed hiding.
    const posts = home ? [...document.querySelectorAll("main article")].filter(article =>
      [...article.querySelectorAll("a[href]")].some(link => {
        try {
          const url = new URL(link.href, location.href);
          return link.closest("article") === article && engine.siteOf(url.href) === "instagram" && /^\/(?:p|reel)\//.test(url.pathname);
        } catch (_) { return false; }
      })) : [];
    markInstagramSurface("feed", posts, !surfaces.feed);
    const buttons = [...document.querySelectorAll('[role="button"],button')];
    markInstagramSurface("stories", home ? buttons.filter(button =>
      instagramControlFeature(button) === "stories").map(button => button.closest("li") || button) : [], !surfaces.stories);
    markInstagramSurface("messages", buttons.filter(button =>
      instagramControlFeature(button) === "messages"), !surfaces.messages);
  }
  function render() {
    const p = policy();
    if (site === "youtube") observeVideo();
    if (!p) {
      initialPlaybackGate = false;
      style?.remove(); style = null; notice?.remove(); notice = null;
      for (const item of document.querySelectorAll("[data-intent-feature-hidden]")) item.removeAttribute("data-intent-feature-hidden");
      document.documentElement?.removeAttribute("data-intent-site-blocked");
      observer?.disconnect(); observer = null;
      if (timer !== null) clearInterval(timer); timer = null;
      if (frame !== null) cancelAnimationFrame(frame); frame = null;
      finishReceipts(true); return true;
    }
    ensureObservation();
    if (!document.documentElement) return false;
    if (!style?.isConnected) {
      style = document.createElement("style"); style.id = "intent-site-feature-style";
      document.documentElement.appendChild(style);
    }
    const blocked = !engine.permits(location.href, rules.websiteFeaturePolicies);
    const css = engine.css(site, p) + '\nhtml[data-intent-site-blocked] body{visibility:hidden!important} #intent-site-feature-notice{visibility:visible!important;position:fixed;inset:0;z-index:2147483647;display:grid;place-content:center;background:#16221c;color:white;font:17px system-ui;padding:40px;text-align:center}';
    if (style.textContent !== css) style.textContent = css;
    for (const chip of document.querySelectorAll('[role="tab"],yt-chip-cloud-chip-renderer,yt-chip-cloud-chip-view-model,[data-intent-feature-hidden="shorts"]')) {
      const hide = site === "youtube" && !p.allowedFeatures?.includes("shorts") && chip.textContent.trim().toLowerCase() === "shorts";
      if (hide) chip.setAttribute("data-intent-feature-hidden", "shorts");
      else chip.removeAttribute("data-intent-feature-hidden");
    }
    if (site === "instagram") instagramSurfaces(p);
    if (site === "instagram") for (const link of document.querySelectorAll('a[href],[data-intent-feature-hidden="navigation"]')) {
      const navigation = link.closest?.('nav,[role="navigation"],aside') || link.getAttribute("aria-label") || link.querySelector?.("svg,img");
      const hide = navigation && engine.siteOf(link.href) === site && !engine.permits(link.href, rules.websiteFeaturePolicies);
      if (hide) link.setAttribute("data-intent-feature-hidden", "navigation");
      else link.removeAttribute("data-intent-feature-hidden");
    }
    if (blocked) {
      for (const media of document.querySelectorAll("video,audio")) media.pause();
      document.documentElement.setAttribute("data-intent-site-blocked", "true");
      if (!notice?.isConnected) {
        notice = document.createElement("div"); notice.id = "intent-site-feature-notice"; notice.setAttribute("role", "alert");
        const title = document.createElement("h2"); title.textContent = "Not part of this intention";
        const text = document.createElement("p"); text.textContent = "This area is not allowed by your website settings.";
        notice.append(title, text); document.documentElement.appendChild(notice);
      }
    } else {
      document.documentElement.removeAttribute("data-intent-site-blocked");
      notice?.remove(); notice = null; routeAttempt = null;
    }
    if (!blocked && site === "youtube") playbackHandoff(videoID());
    if (initialPlaybackGate) {
      initialPlaybackGate = false;
      // A fresh document can start playing before its first rules response. That
      // play event predates our policy, so apply the same handoff gate once here.
      // Already-loaded pages and pages that observed inactive rules keep playback
      // when an intention starts; only a new document enters this recovery path.
      if (!blocked) for (const media of document.querySelectorAll("video,audio")) {
        if (media.paused === false && !media.ended) enforcePlay(media);
      }
    }
    finishReceipts(true);
    const destination = engine.preferredDestination(location.href, rules.websiteFeaturePolicies);
    const attempt = generation + ":" + location.href;
    if (destination && routeAttempt !== attempt) {
      routeAttempt = attempt;
      // Background validates the current tab, policy and outer URL restrictions.
      // It updates this tab's URL only: no activation, new tab or window.
      send({type:"routeWebsiteFeature", url:location.href, websitePolicyKey:engine.policyKey(rules)})
        .then(result => { if (result?.retry && routeAttempt === attempt) routeAttempt = null; }).catch(() => {});
    }
    return true;
  }
  function update(next) {
    if (!receivedPolicy) {
      receivedPolicy = true;
      initialPlaybackGate = startedDuringDocumentLoad && site === "youtube" && next?.active
        && Boolean(next.websiteFeaturePolicies?.youtube)
        && !next.websiteFeaturePolicies.youtube.allowedFeatures?.includes("autoplay");
    }
    const key = engine.policyKey(next);
    if (key !== engine.policyKey(rules)) {
      finishReceipts(false); generation++; routeAttempt = null;
      pendingVideo = null; permittedVideo = null;
      handoffAttempt = null; handoffPending = null; guardedPlay = null;
    }
    rules = next || {active:false};
    return render();
  }
  api.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type !== "rulesUpdated") return false;
    receivedUpdate = true;
    update(message.rules);
    const waiter = {respond,id:message.websiteRequestID,key:engine.policyKey(rules),generation};
    waiting.add(waiter);
    waiter.timeout = setTimeout(() => { if (waiting.has(waiter)) receipt(waiter, false); }, 3000);
    render();
    return true;
  });
  try { send({type:"getActiveRules"}).then(next => { if (!receivedUpdate) update(next); }).catch(() => {}); } catch (_) {}
  for (const name of ["click","auxclick"]) document.addEventListener(name, event => {
    if (!policy()) return;
    if (event.isTrusted) interactionVersion++;
    const feature = site === "instagram" ? instagramControlFeature(event.target) : null;
    if (feature && !policy().allowedFeatures?.includes(feature)) {
      event.preventDefault(); event.stopImmediatePropagation(); return;
    }
    const link = event.target?.closest?.("a[href]");
    if (link && !engine.permits(link.href, rules.websiteFeaturePolicies)) {
      event.preventDefault(); event.stopImmediatePropagation(); return;
    }
    const activation = name === "click" ? (event.button == null || event.button === 0) : event.button === 1;
    if (!event.isTrusted || site !== "youtube" || !link || !activation || event.altKey || policy().allowedFeatures?.includes("autoplay")
        || link.hasAttribute?.("download")) return;
    const id = videoID(link.href);
    if (!id) return;
    const newTab = name === "auxclick" || event.ctrlKey || event.metaKey || event.shiftKey || link.target === "_blank";
    if (!newTab) pendingVideo = {id,sourceID:videoID()};
    send({type:"rememberWebsitePlaybackIntent", url:location.href, targetURL:link.href,
      disposition:newTab ? "new-tab" : "same-tab", websitePolicyKey:engine.policyKey(rules)}).catch(() => {});
  }, true);
  function deliberatePlay(event) {
    if (!event.isTrusted) return;
    interactionVersion++;
    if (site !== "youtube" || !policy() || event.altKey || event.ctrlKey || event.metaKey || event.repeat
        || !engine.permits(location.href, rules.websiteFeaturePolicies)) return;
    const target = event.target;
    if (target?.closest?.('input,textarea,select,[contenteditable=""],[contenteditable="true"],[role="textbox"]')
        || target?.isContentEditable) return;
    const pointerControl = target?.closest?.('video,.ytp-play-button,.ytp-large-play-button,.html5-video-container,.ytp-cued-thumbnail-overlay');
    const player = target?.closest?.('video,.ytp-play-button,.ytp-large-play-button,.html5-video-player');
    const pageFocus = target === document.body || target === document.documentElement || target === document;
    const keyboardPlay = event.type === "keydown" && (!(event.shiftKey && event.key === " ") && [" ","k","K"].includes(event.key) && (player || pageFocus)
      || event.key === "Enter" && target?.closest?.('.ytp-play-button,.ytp-large-play-button'));
    if (event.type === "pointerdown" && (event.button == null || event.button === 0) && event.isPrimary !== false && pointerControl || keyboardPlay) {
      permittedVideo = observeVideo(); guardedPlay = null;
    }
  }
  document.addEventListener("pointerdown", deliberatePlay, true);
  document.addEventListener("keydown", deliberatePlay, true);
  function enforcePlay(target) {
    const p = policy();
    if (!p) return;
    const allowedRoute = engine.permits(location.href, rules.websiteFeaturePolicies);
    const id = observeVideo();
    if (allowedRoute && id && pendingVideo?.id === id) { permittedVideo = id; pendingVideo = null; }
    const shouldPause = !allowedRoute || site === "youtube" && !p.allowedFeatures?.includes("autoplay") && (!id || permittedVideo !== id);
    if (shouldPause) {
      if (allowedRoute && handoffPending?.id === id) guardedPlay = {target,pending:handoffPending,interaction:interactionVersion};
      target?.pause?.();
    }
  }
  document.addEventListener("play", event => enforcePlay(event.target), true);
  for (const name of ["DOMContentLoaded","popstate","hashchange","pageshow","yt-navigate-finish"]) addEventListener(name, schedule);
})();
