(function attachIntentBrowserRules(root) {
  function normalizeRule(value) {
    return String(value || "")
      .trim()
      .replace(/^https?:\/\//i, "")
      .replace(/^www\./i, "")
      .replace(/\/+$/g, "")
      .toLowerCase();
  }

  function normalizedURLParts(url) {
    try {
      if (isSearchStagingURL(url)) {
        return { host: "about", path: "/newtab" };
      }

      const parsed = new URL(url);
      if (!["http:", "https:"].includes(parsed.protocol)) {
        return null;
      }

      return {
        host: parsed.hostname.replace(/^www\./i, "").toLowerCase(),
        path: parsed.pathname.replace(/\/+$/g, "").toLowerCase()
      };
    } catch (_) {
      return null;
    }
  }

  function isSearchStagingURL(url) {
    const value = String(url || "").toLowerCase();
    return (
      value === "about:blank" ||
      value === "about:newtab" ||
      /^chrome:\/\/(?:newtab|new-tab-page)(?:\/|$)/.test(value) ||
      /^chrome-search:\/\//.test(value)
    );
  }

  function isGoogleSearchURL(url) {
    const parts = normalizedURLParts(url);
    if (!parts) return false;
    const googleHost = parts.host === "google.com" || /^google\.[a-z.]+$/.test(parts.host);
    return googleHost && (parts.path === "" || parts.path === "/" || parts.path === "/search");
  }

  function isAllowedURL(url, rules) {
    if (!rules.active) return true;
    const isBlacklist = rules.accessMode === "blacklist";
    if (isSearchStagingURL(url)) return isBlacklist || rules.allowGoogleSearchTabs;
    if (rules.allowGoogleSearchTabs && (isSearchStagingURL(url) || isGoogleSearchURL(url))) return true;
    if (!rules.allowedWebsites.length) return isBlacklist;

    const parts = normalizedURLParts(url);
    if (!parts) return isBlacklist;
    const matchesConfiguredWebsite = rules.allowedWebsites.some((rawRule) => {
      const rule = normalizeRule(rawRule);
      if (!rule) return false;
      const slashIndex = rule.indexOf("/");
      const ruleHost = slashIndex === -1 ? rule : rule.slice(0, slashIndex);
      const rulePath = slashIndex === -1 ? "" : rule.slice(slashIndex);
      const hostMatches = parts.host === ruleHost || parts.host.endsWith(`.${ruleHost}`);
      return hostMatches && (rulePath === "" || parts.path === rulePath || parts.path.startsWith(`${rulePath}/`));
    });
    return isBlacklist ? !matchesConfiguredWebsite : matchesConfiguredWebsite;
  }

  const api = { normalizeRule, normalizedURLParts, isSearchStagingURL, isGoogleSearchURL, isAllowedURL };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.IntentBrowserRules = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
