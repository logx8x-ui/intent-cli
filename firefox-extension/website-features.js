/* Shared site policy engine. Keep Chrome/Firefox copies byte-identical. */
(function(root) {
  "use strict";
  const features = {
    instagram: ["messages", "feed", "reels", "stories", "explore"],
    youtube: ["search", "feed", "shorts", "recommendations", "comments", "autoplay"]
  };
  function siteOf(raw) {
    try {
      const h = new URL(raw).hostname.toLowerCase();
      if (h === "instagram.com" || h.endsWith(".instagram.com")) return "instagram";
      if (h === "youtube.com" || h.endsWith(".youtube.com") || h === "youtu.be") return "youtube";
    } catch (_) {}
    return null;
  }
  function valid(site, policy) {
    return policy?.version === 1 && Array.isArray(policy.allowedFeatures)
      && policy.allowedFeatures.every(f => features[site]?.includes(f))
      && (site !== "instagram" || policy.allowedFeatures.length > 0);
  }
  function permits(raw, policies) {
    const site = siteOf(raw), p = policies?.[site];
    if (!p) return true; // Backward compatibility is intentional.
    if (!valid(site, p)) return false;
    const u = new URL(raw);
    let path;
    try { path = decodeURIComponent(u.pathname).toLowerCase(); } catch (_) { return false; }
    const has = f => p.allowedFeatures.includes(f);
    if (site === "instagram") {
      if (/^\/(accounts\/(login|logout|onetap|password|edit)|challenge|two_factor)(\/|$)/.test(path)) return true;
      if (/^\/direct(\/|$)/.test(path)) return has("messages");
      if (/^\/reels?(\/|$)/.test(path)) return has("reels");
      if (/^\/stories(\/|$)/.test(path)) return has("stories");
      if (path === "/") return has("feed");
      if (/^\/p\//.test(path)) return has("feed") || has("explore");
      return has("explore");
    }
    if (u.hostname === "youtu.be") return true;
    if (/^\/(signin|logout|account|oops)(\/|$)/.test(path)) return true;
    if (/^\/shorts(\/|$)/.test(path)) return has("shorts");
    if (/^\/(watch|embed|live)(\/|$)/.test(path)) return true;
    if (path === "/") return has("feed");
    if (/^\/(results|@[^/]+|channel|user|playlist)(\/|$)/.test(path)) return has("search");
    if (/^\/feed\//.test(path)) return has("feed");
    return false;
  }
  function css(site, policy) {
    if (!valid(site, policy)) return "";
    const has = f => policy.allowedFeatures.includes(f), hidden = [];
    if (site === "youtube") {
      if (!has("shorts")) hidden.push('ytd-reel-shelf-renderer', 'ytd-rich-shelf-renderer[is-shorts]', 'ytm-shorts-lockup-view-model', 'a[href^="/shorts/"]', 'ytd-guide-entry-renderer:has(a[href^="/shorts"])');
      if (!has("recommendations")) hidden.push('#related', '.ytp-endscreen-content', '.ytp-ce-element', 'ytd-watch-next-secondary-results-renderer');
      if (!has("comments")) hidden.push('ytd-comments', '#comments', 'ytm-comment-section-renderer');
      if (!has("autoplay")) hidden.push('.ytp-autonav-toggle-button-container', 'ytd-compact-autoplay-renderer');
      if (!has("feed")) hidden.push('ytd-browse[page-subtype="home"]', 'a[title="Home"]');
    } else {
      if (!has("reels")) hidden.push('a[href^="/reel/"]', 'a[href^="/reels/"]');
      if (!has("stories")) hidden.push('a[href^="/stories/"]');
      if (!has("explore")) hidden.push('a[href^="/explore/"]');
      if (!has("feed")) hidden.push('nav a[href="/"]');
    }
    return hidden.length ? hidden.join(",") + "{display:none!important;pointer-events:none!important}" : "";
  }
  function networkRules(policies, tabIds) {
    let id = 24000;
    const rules = [];
    for (const [site, p] of Object.entries(policies || {})) {
      const host = site === "instagram" ? "([^/]+\\.)?instagram\\.com" : "([^/]+\\.)?youtube\\.com";
      if (!features[site]) continue;
      const scope = Array.isArray(tabIds) ? {tabIds} : {};
      if (Array.isArray(tabIds) && !tabIds.length) continue;
      if (!Array.isArray(tabIds)) {
        // In URL-based/blacklist sessions these rules may only subtract access:
        // an allow rule here would override a stricter existing URL whitelist.
        const denied = !valid(site, p) ? [""] : site === "instagram"
          ? [...(!p.allowedFeatures.includes("messages") ? ["direct(/|[?#]|$)"] : []),
             ...(!p.allowedFeatures.includes("feed") ? ["([?#]|$)"] : []),
             ...(!p.allowedFeatures.includes("reels") ? ["reels?(/|[?#]|$)"] : []),
             ...(!p.allowedFeatures.includes("stories") ? ["stories(/|[?#]|$)"] : []),
             ...(!p.allowedFeatures.includes("explore") ? ["explore(/|[?#]|$)"] : [])]
          : [...(!p.allowedFeatures.includes("shorts") ? ["shorts(/|[?#]|$)"] : []),
             ...(!p.allowedFeatures.includes("feed") ? ["([?#]|$)", "feed/"] : []),
             ...(!p.allowedFeatures.includes("search") ? ["(results|@[^/]+|channel|user|playlist)(/|[?#]|$)"] : [])];
        for (const path of denied) rules.push({id: id++, priority: 800, action: {type: "block"},
          condition: {regexFilter: "^https?://" + host + "/(" + path + ")", resourceTypes: ["main_frame"]}});
        continue;
      }
      // Deny this site's documents, then allow only known enabled destinations.
      rules.push({id: id++, priority: 800, action: {type: "block"}, condition: {regexFilter: "^https?://" + host + "/", resourceTypes: ["main_frame"], ...scope}});
      if (!valid(site, p)) continue;
      const allow = site === "instagram"
        ? ["accounts/(login|logout|onetap|password|edit)(/|$)", "challenge(/|$)", "two_factor(/|$)",
           ...(p.allowedFeatures.includes("messages") ? ["direct(/|$)"] : []),
           ...(p.allowedFeatures.includes("reels") ? ["reels?(/|$)"] : []),
           ...(p.allowedFeatures.includes("stories") ? ["stories(/|$)"] : []),
           ...(p.allowedFeatures.includes("feed") ? ["([?#]|$)", "p/"] : []),
           ...(p.allowedFeatures.includes("explore") ? ["[^/?#]+(/|[?#]|$)"] : [])]
        : ["(watch|embed|live|signin|logout|account|oops)(/|[?#]|$)",
           ...(p.allowedFeatures.includes("search") ? ["(results|@[^/]+|channel|user|playlist)(/|[?#]|$)"] : []),
           ...(p.allowedFeatures.includes("feed") ? ["([?#]|$)", "feed/"] : []),
           ...(p.allowedFeatures.includes("shorts") ? ["shorts(/|$)"] : [])];
      for (const path of allow) rules.push({id: id++, priority: 801, action: {type: "allow"}, condition: {regexFilter: "^https?://" + host + "/(" + path + ")", resourceTypes: ["main_frame"], ...scope}});
      // Broad profile access must not reopen expressly disabled Instagram areas.
      if (site === "instagram") for (const [f, path] of [["messages","direct"],["reels","reels?"],["stories","stories"]]) {
        if (!p.allowedFeatures.includes(f)) rules.push({id: id++, priority: 802, action: {type:"block"}, condition: {regexFilter: "^https?://" + host + "/" + path + "(/|$)", resourceTypes:["main_frame"], ...scope}});
      }
    }
    return rules;
  }
  const api = {siteOf, valid, permits, css, networkRules};
  root.IntentWebsiteFeatures = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
