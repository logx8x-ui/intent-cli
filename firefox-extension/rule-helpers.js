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
      if (["about:blank", "about:newtab"].includes(url)) {
        return {
          host: "about",
          path: url.replace("about:", "/")
        };
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
    return ["about:blank", "about:newtab"].includes(url);
  }

  function isGoogleSearchURL(url) {
    const parts = normalizedURLParts(url);
    if (!parts) {
      return false;
    }

    const googleHost = parts.host === "google.com" || /^google\.[a-z.]+$/.test(parts.host);
    return googleHost && (parts.path === "" || parts.path === "/" || parts.path === "/search");
  }

  function isAllowedURL(url, rules) {
    if (!rules.active || rules.allowedWebsites.length === 0) {
      return true;
    }

    if (rules.allowGoogleSearchTabs && (isSearchStagingURL(url) || isGoogleSearchURL(url))) {
      return true;
    }

    const parts = normalizedURLParts(url);
    if (!parts) {
      return false;
    }

    return rules.allowedWebsites.some((rawRule) => {
      const rule = normalizeRule(rawRule);
      if (!rule) {
        return false;
      }

      const slashIndex = rule.indexOf("/");
      const ruleHost = slashIndex === -1 ? rule : rule.slice(0, slashIndex);
      const rulePath = slashIndex === -1 ? "" : rule.slice(slashIndex);
      const hostMatches = parts.host === ruleHost || parts.host.endsWith(`.${ruleHost}`);

      if (!hostMatches) {
        return false;
      }

      return rulePath === "" || parts.path === rulePath || parts.path.startsWith(`${rulePath}/`);
    });
  }

  const api = {
    normalizeRule,
    normalizedURLParts,
    isSearchStagingURL,
    isGoogleSearchURL,
    isAllowedURL
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  } else {
    root.IntentBrowserRules = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
