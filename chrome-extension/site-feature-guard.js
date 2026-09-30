/* No page text or message contents leave this script. */
(() => {
  "use strict";
  if (globalThis.intentWebsiteFeatureGuardInstalled) return;
  globalThis.intentWebsiteFeatureGuardInstalled = true;
  const api = typeof browser !== "undefined" ? browser : chrome;
  const engine = IntentWebsiteFeatures;
  const site = engine.siteOf(location.href);
  if (!site) return;
  let rules = {active:false}, observer = null, timer = null, scheduled = false;
  let style = null, notice = null, lastGesture = 0;
  function policy() { return rules.active ? rules.websiteFeaturePolicies?.[site] : null; }
  function render() {
    scheduled = false;
    const p = policy();
    // Search chips have no Shorts URL, so identify their dedicated tab label.
    // Mark only these controls; removing the policy restores the page.
    for (const chip of document.querySelectorAll('[role="tab"],yt-chip-cloud-chip-renderer,yt-chip-cloud-chip-view-model,[data-intent-feature-hidden]')) {
      const hide = site === "youtube" && p && !p.allowedFeatures?.includes("shorts") && chip.textContent.trim().toLowerCase() === "shorts";
      if (hide) chip.setAttribute("data-intent-feature-hidden", "shorts");
      else chip.removeAttribute("data-intent-feature-hidden");
    }
    if (!p) {
      style?.remove(); style = null; notice?.remove(); notice = null;
      document.documentElement?.removeAttribute("data-intent-site-blocked");
      observer?.disconnect(); observer = null;
      if (timer) clearInterval(timer); timer = null;
      return;
    }
    if (!document.documentElement) return;
    if (!style?.isConnected) {
      style = document.createElement("style"); style.id = "intent-site-feature-style";
      document.documentElement.appendChild(style);
    }
    const blocked = !engine.permits(location.href, rules.websiteFeaturePolicies);
    const css = engine.css(site, p) + '\nhtml[data-intent-site-blocked] body{visibility:hidden!important} #intent-site-feature-notice{visibility:visible!important;position:fixed;inset:0;z-index:2147483647;display:grid;place-content:center;background:#16221c;color:white;font:17px system-ui;padding:40px;text-align:center}';
    if (style.textContent !== css) style.textContent = css;
    if (blocked) {
      for (const media of document.querySelectorAll("video,audio")) media.pause();
      if (!document.documentElement.hasAttribute("data-intent-site-blocked")) document.documentElement.setAttribute("data-intent-site-blocked", "true");
      if (!notice?.isConnected) {
        notice = document.createElement("div"); notice.id = "intent-site-feature-notice";
        notice.setAttribute("role", "alert");
        const title = document.createElement("h2"); title.textContent = "Not part of this intention";
        const text = document.createElement("p"); text.textContent = "This area is not allowed by your website settings. You can return to an allowed page or finish your intention in Intent.";
        const link = document.createElement("a");
        link.href = site === "instagram" && p.allowedFeatures?.includes("messages") ? "https://www.instagram.com/direct/inbox/" : site === "youtube" && p.allowedFeatures?.includes("search") ? "https://www.youtube.com/results?search_query=" : "#";
        link.textContent = "Return to an allowed area"; link.style.color = "#80e0aa";
        if (link.getAttribute("href") === "#") link.removeAttribute("href");
        notice.append(title, text, link); document.documentElement.appendChild(notice);
      }
    } else {
      document.documentElement.removeAttribute("data-intent-site-blocked");
      notice?.remove(); notice = null;
    }
    if (!observer) {
      observer = new MutationObserver(schedule);
      observer.observe(document.documentElement, {childList:true, subtree:true});
      timer = setInterval(schedule, 500);
    }
  }
  function schedule() { if (!scheduled) { scheduled = true; requestAnimationFrame(render); } }
  function update(next) { rules = next || {active:false}; render(); }
  api.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "rulesUpdated") { update(message.rules); respond({websiteFeatures: true}); }
    return false;
  });
  try {
    if (typeof browser !== "undefined") api.runtime.sendMessage({type:"getActiveRules"}).then(update).catch(() => {});
    else api.runtime.sendMessage({type:"getActiveRules"}, response => { if (!api.runtime.lastError) update(response); });
  } catch (_) {}
  document.addEventListener("click", event => {
    if (!policy()) return;
    const link = event.target?.closest?.("a[href]");
    if (link && !engine.permits(link.href, rules.websiteFeaturePolicies)) { event.preventDefault(); event.stopImmediatePropagation(); }
  }, true);
  document.addEventListener("auxclick", event => {
    if (!policy()) return;
    const link = event.target?.closest?.("a[href]");
    if (link && !engine.permits(link.href, rules.websiteFeaturePolicies)) { event.preventDefault(); event.stopImmediatePropagation(); }
  }, true);
  for (const name of ["pointerdown", "keydown"]) document.addEventListener(name, event => { if (event.isTrusted) lastGesture = Date.now(); }, true);
  document.addEventListener("play", event => {
    const p = policy();
    if (p && (!engine.permits(location.href, rules.websiteFeaturePolicies)
        || (site === "youtube" && !p.allowedFeatures?.includes("autoplay") && Date.now() - lastGesture > 1400))) {
      event.target?.pause?.();
    }
  }, true);
  for (const name of ["popstate","hashchange","pageshow","yt-navigate-finish"]) addEventListener(name, schedule);
})();
