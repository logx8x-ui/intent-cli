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
  function videoID(raw) {
    try {
      const u = new URL(raw);
      if (siteOf(raw) !== "youtube") return null;
      if (u.pathname === "/watch") return u.searchParams.get("v");
      if (u.hostname === "youtu.be") return u.pathname.split("/")[1] || null;
      return /^\/(?:embed|live|shorts)\/([^/]+)/.exec(u.pathname)?.[1] || null;
    } catch (_) { return null; }
  }
  function valid(site, policy) {
    return policy?.version === 1 && Array.isArray(policy.allowedFeatures)
      && policy.allowedFeatures.every(f => features[site]?.includes(f))
      && (site !== "instagram" || policy.allowedFeatures.length > 0);
  }
  // A route decision tree is shared by DOM checks and Chrome's subtractive
  // network rules. Each node owns an exact path and the default for descendants.
  const routeCache = new WeakMap();
  function routeTree(site, p) {
    const signature = site + ":" + p.allowedFeatures.join(",");
    const cached = routeCache.get(p);
    if (cached?.signature === signature) return cached.tree;
    const has = f => p.allowedFeatures.includes(f);
    const fallback = site === "instagram" && has("explore");
    const node = allowed => ({exact:allowed, fallback:allowed, children:new Map()});
    const root = node(fallback);
    const at = path => {
      let current = root;
      for (const c of path) {
        if (!current.children.has(c)) current.children.set(c, node(current.fallback));
        current = current.children.get(c);
      }
      return current;
    };
    const route = (path, allowed) => {
      const current = at(path); current.exact = allowed;
      current.children.set("/", node(allowed));
    };
    const prefix = (path, allowed) => Object.assign(at(path), node(allowed));
    // YouTube's root also contains its native search/header shell. Search may
    // use that shell while CSS independently removes the disabled Home feed.
    // Descendant feed routes retain their separate Feed-only policy.
    root.exact = has("feed") || (site === "youtube" ? has("search") : has("stories"));
    if (site === "instagram") {
      for (const auth of ["login","logout","onetap","password","edit"]) route("accounts/" + auth, true);
      for (const auth of ["challenge","two_factor"]) route(auth, true);
      route("direct", has("messages"));
      for (const path of ["reel","reels"]) route(path, has("reels"));
      route("stories", has("stories"));
      prefix("p/", has("feed") || has("explore"));
    } else {
      for (const path of ["watch","embed","live","signin","logout","account","oops"]) route(path, true);
      route("shorts", has("shorts"));
      for (const path of ["results","channel","user","playlist"]) route(path, has("search"));
      prefix("feed/", has("feed"));
      const channel = at("@"); channel.fallback = has("search"); channel.exact = false;
      channel.children.set("/", node(false));
    }
    routeCache.set(p, {signature,tree:root});
    return root;
  }
  const instagramReservedRoots = new Set(["accounts","challenge","two_factor","direct","reel","reels","stories","p","explore"]);
  function instagramProfileReels(path) {
    const parts = path.replace(/^\//, "").split("/");
    return Boolean(parts[0]) && !instagramReservedRoots.has(parts[0]) && parts[1] === "reels";
  }
  function permits(raw, policies) {
    const site = siteOf(raw), p = policies?.[site];
    if (!p) return true; // Old saved intentions retain their existing behavior.
    if (!valid(site, p)) return false;
    const u = new URL(raw);
    let path;
    try { path = decodeURIComponent(u.pathname).toLowerCase(); } catch (_) { return false; }
    if (u.hostname === "youtu.be") return true;
    if (site === "instagram" && instagramProfileReels(path)) {
      return p.allowedFeatures.includes("explore") && p.allowedFeatures.includes("reels");
    }
    let current = routeTree(site, p);
    for (const c of path.slice(1)) {
      if (!current.children.has(c)) return current.fallback;
      current = current.children.get(c);
    }
    return current.exact;
  }
  function policyKey(rules) {
    return JSON.stringify([Boolean(rules?.active), rules?.startupSessionID || null,
      Object.entries(rules?.websiteFeaturePolicies || {}).sort(([a],[b]) => a.localeCompare(b))
        .map(([site,p]) => [site,p?.version,Array.isArray(p?.allowedFeatures) ? [...p.allowedFeatures].sort() : null])]);
  }
  // Feature routes and the surfaces inside a shared route are separate. Stories
  // needs Instagram's home shell without granting the post feed inside it.
  function instagramSurfaces(policy) {
    const enabled = valid("instagram", policy);
    const has = feature => enabled && policy.allowedFeatures.includes(feature);
    return {home:has("feed") || has("stories"), messages:has("messages"),
      feed:has("feed"), reels:has("reels"), stories:has("stories"), explore:has("explore")};
  }
  function landingDestination(site, policies) {
    if (site !== "instagram" || !valid(site, policies?.[site])) return null;
    const surface = instagramSurfaces(policies.instagram);
    const path = surface.home ? "/" : surface.messages ? "/direct/inbox/"
      : surface.reels ? "/reels/" : surface.explore ? "/explore/" : null;
    return path ? "https://www.instagram.com" + path : null;
  }
  function preferredDestination(raw, policies) {
    return siteOf(raw) === "instagram" && !permits(raw, policies)
      ? landingDestination("instagram", policies) : null;
  }
  function css(site, policy) {
    if (!valid(site, policy)) return "";
    const has = f => policy.allowedFeatures.includes(f), hidden = [];
    if (site === "youtube") {
      if (!has("shorts")) hidden.push('[data-intent-feature-hidden="shorts"]', 'ytd-reel-shelf-renderer', 'ytd-rich-shelf-renderer[is-shorts]', 'ytm-shorts-lockup-view-model', 'a[href^="/shorts/"]', 'ytd-guide-entry-renderer:has(a[href^="/shorts"])');
      if (!has("recommendations")) hidden.push('#related', '.ytp-endscreen-content', '.ytp-ce-element', 'ytd-watch-next-secondary-results-renderer');
      if (!has("comments")) hidden.push('ytd-comments', '#comments', 'ytm-comment-section-renderer');
      if (!has("autoplay")) hidden.push('.ytp-autonav-toggle-button-container', 'ytd-compact-autoplay-renderer');
      if (!has("feed")) hidden.push('ytd-browse[page-subtype="home"]', 'a[title="Home"]');
    } else {
      if (!has("messages")) hidden.push('a[href^="/direct"]');
      if (!has("reels")) hidden.push('a[href^="/reel/"]', 'a[href^="/reels/"]');
      if (!has("stories")) hidden.push('a[href^="/stories/"]');
      if (!has("explore")) hidden.push('a[href^="/explore/"]');
      if (!has("feed") && !has("stories")) hidden.push('nav a[href="/"]', '[role="navigation"] a[href="/"]');
      hidden.push('[data-intent-feature-hidden="navigation"]', '[data-intent-feature-hidden="feed"]');
    }
    return hidden.length ? hidden.join(",") + "{display:none!important;pointer-events:none!important}" : "";
  }
  const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  function encoded(c) {
    const codes = [...new Set([c, c.toUpperCase()].map(x => x.charCodeAt(0).toString(16).padStart(2,"0")))];
    return "(?:" + escapeRegex(c) + "|%" + codes.join("|%") + ")";
  }
  function otherEncoded(chars) {
    const codes = new Set(chars.flatMap(c => [c,c.toUpperCase()].map(x => x.charCodeAt(0).toString(16).padStart(2,"0"))));
    const hex = "0123456789abcdef";
    const branches = [];
    for (const first of hex) {
      const seconds = [...hex].filter(second => !codes.has(first + second)).join("");
      if (seconds) branches.push(first + "[" + seconds + "]");
    }
    return "%(?:" + branches.join("|") + ")";
  }
  let profileReelsPatterns;
  function deniedProfileReels(policy, rawScope = "") {
    if (!valid("instagram", policy) || !policy.allowedFeatures.includes("explore") || policy.allowedFeatures.includes("reels")) return [];
    const suffix = [..."reels"].map(encoded).join("") + "(?:" + encoded("/") + "|[?#]|$)";
    if (rawScope) {
      let path;
      try { path = decodeURIComponent(rawScope).toLowerCase(); } catch (_) { return []; }
      const parts = path.replace(/^\//, "").split("/");
      if (!parts[0] || instagramReservedRoots.has(parts[0])) return [];
      const raw = escapeRegex(rawScope.replace(/^\//, ""));
      if (parts.length === 1) return [raw + encoded("/") + suffix];
      return instagramProfileReels(path) ? [raw + "(?:[/?#]|$)"] : [];
    }
    if (profileReelsPatterns) return profileReelsPatterns;
    // A profile segment must not swallow reserved paths such as /stories/reels/
    // (a story by a user named reels). Generate RE2-safe exclusions without
    // lookahead or an allow rule that could override a stricter outer ban.
    const root = {end:false, children:new Map()}, result = [];
    for (const name of instagramReservedRoots) {
      let node = root;
      for (const char of name) {
        if (!node.children.has(char)) node.children.set(char, {end:false,children:new Map()});
        node = node.children.get(char);
      }
      node.end = true;
    }
    const any = "(?:[^%/?#]|" + otherEncoded(["/"]) + ")";
    function visit(node, prefix) {
      if (prefix && !node.end) result.push(prefix + encoded("/") + suffix);
      const chars = [...node.children.keys(), "/"];
      const excluded = chars.map(char => char.replace(/[\\\]\^-]/g, "\\$&")).join("");
      result.push(prefix + "(?:[^%?#" + excluded + "]|" + otherEncoded(chars) + ")" + any + "*" + encoded("/") + suffix);
      for (const [char, child] of node.children) visit(child, prefix + encoded(char));
    }
    visit(root, "");
    profileReelsPatterns = result;
    return result;
  }
  function deniedPaths(tree) {
    const result = [];
    function visit(node, prefix) {
      if (!node.children.size && node.exact === node.fallback) {
        if (!node.exact) result.push(prefix);
        return;
      }
      if (!node.exact) result.push(prefix + "(?:[?#]|$)");
      const chars = [...node.children.keys()];
      if (!node.fallback) {
        const excluded = chars.map(c => c.replace(/[\\\]\^-]/g, "\\$&")).join("");
        result.push(prefix + "(?:[^%?#" + excluded + "]|" + otherEncoded(chars) + ")");
      }
      for (const [c, child] of node.children) visit(child, prefix + encoded(c));
    }
    visit(tree, "");
    // Invalid percent escapes never become a route allowance.
    result.push("[^?#]*%(?:[^0-9a-f]|[0-9a-f](?:[^0-9a-f]|$)|$)");
    return result;
  }
  // Intersect a denied feature route with an outer allowed URL prefix. The
  // outer policy matches raw path bytes; only the route-tree lookup decodes.
  function scopedDeniedPaths(tree, rawPath) {
    if (!rawPath) return deniedPaths(tree);
    let decoded;
    try { decoded = decodeURIComponent(rawPath).toLowerCase(); } catch (_) { return []; }
    let current = tree;
    for (const c of decoded.replace(/^\//, "")) {
      current = current.children.get(c) || {exact:current.fallback,fallback:current.fallback,children:new Map()};
    }
    const prefix = escapeRegex(rawPath.replace(/^\//, ""));
    const result = current.exact ? [] : [prefix + "(?:[?#]|$)"];
    const child = current.children.get("/") || {exact:current.fallback,fallback:current.fallback,children:new Map()};
    result.push(...deniedPaths(child).map(path => prefix + "/" + path));
    return result;
  }
  function instagramScope(raw) {
    const value = String(raw || "").trim().replace(/^https?:\/\//i, "").replace(/^www\./i, "").replace(/\/+$/, "").toLowerCase();
    const slash = value.indexOf("/"), host = slash < 0 ? value : value.slice(0, slash);
    if (!host || !(host === "instagram.com" || host.endsWith(".instagram.com") || "instagram.com".endsWith("." + host))) return null;
    return {host:host.endsWith(".instagram.com") ? host : "instagram.com",path:slash < 0 ? "" : value.slice(slash)};
  }
  function networkRules(policies, tabIds, instagramRouting = null) {
    let id = 24000;
    const rules = [];
    if (Array.isArray(tabIds) && !tabIds.length) return rules;
    for (const [site,p] of Object.entries(policies || {})) {
      if (!features[site]) continue;
      const host = site === "instagram" ? "([^/]+\\.)?instagram\\.com" : "([^/]+\\.)?youtube\\.com";
      const scope = Array.isArray(tabIds) ? {tabIds} : {};
      // Only subtract access. An allow rule would reopen a stricter outer URL
      // whitelist or explicit blacklist. Encoded ASCII follows the DOM parser.
      const denied = valid(site,p) ? deniedPaths(routeTree(site,p)) : [""];
      if (site === "instagram") denied.push(...deniedProfileReels(p));
      for (const path of denied) {
        rules.push({id:id++, priority:800, action:{type:"block"}, condition:{
          regexFilter:"^https?://" + host + "(?::[0-9]+)?/" + path,
          resourceTypes:["main_frame"], ...scope
        }});
      }
    }
    const instagram = policies?.instagram, destination = landingDestination("instagram", policies);
    if (instagramRouting && destination) {
      const scope = Array.isArray(tabIds) ? {tabIds} : {};
      const sources = [...new Set(instagramRouting.sources || [])].map(instagramScope).filter(Boolean);
      for (const source of sources) {
        const denied = [...scopedDeniedPaths(routeTree("instagram", instagram), source.path), ...deniedProfileReels(instagram, source.path)];
        for (const path of denied) {
          rules.push({id:id++,priority:801,action:{type:"redirect",redirect:{url:destination}},condition:{
            regexFilter:"^https?://([^/]+\\.)?" + escapeRegex(source.host) + "(?::[0-9]+)?/" + path,
            resourceTypes:["main_frame"],...scope}});
        }
      }
      for (const source of [...new Set(instagramRouting.excludedSources || [])].map(instagramScope).filter(Boolean)) {
        rules.push({id:id++,priority:802,action:{type:"block"},condition:{
          regexFilter:"^https?://([^/]+\\.)?" + escapeRegex(source.host) + "(?::[0-9]+)?" +
            (source.path ? escapeRegex(source.path) + "(?:[/?#]|$)" : "/"),resourceTypes:["main_frame"],...scope}});
      }
    }
    if (id > 24997) throw new Error("Website features exceeded the session regex budget after exact-tab/search rules");
    return rules;
  }
  const api = {siteOf, videoID, valid, permits, css, networkRules, policyKey, preferredDestination, landingDestination, instagramSurfaces};
  root.IntentWebsiteFeatures = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
