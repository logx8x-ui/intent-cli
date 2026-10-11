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

  // Static https://www.google.com/supported_domains snapshot, 2026-10-12.
  // Do not accept arbitrary google.* suffixes owned by another site.
  const supportedGoogleSearchHosts = new Set((
    "google.com google.ad google.ae google.com.af google.com.ag google.al google.am google.co.ao " +
    "google.com.ar google.as google.at google.com.au google.az google.ba google.com.bd google.be " +
    "google.bf google.bg google.com.bh google.bi google.bj google.com.bn google.com.bo google.com.br " +
    "google.bs google.bt google.co.bw google.by google.com.bz google.ca google.cd google.cf " +
    "google.cg google.ch google.ci google.co.ck google.cl google.cm google.cn google.com.co " +
    "google.co.cr google.com.cu google.cv google.com.cy google.cz google.de google.dj google.dk " +
    "google.dm google.com.do google.dz google.com.ec google.ee google.com.eg google.es google.com.et " +
    "google.fi google.com.fj google.fm google.fr google.ga google.ge google.gg google.com.gh " +
    "google.com.gi google.gl google.gm google.gr google.com.gt google.gy google.com.hk google.hn " +
    "google.hr google.ht google.hu google.co.id google.ie google.co.il google.im google.co.in " +
    "google.iq google.is google.it google.je google.com.jm google.jo google.co.jp google.co.ke " +
    "google.com.kh google.ki google.kg google.co.kr google.com.kw google.kz google.la google.com.lb " +
    "google.li google.lk google.co.ls google.lt google.lu google.lv google.com.ly google.co.ma " +
    "google.md google.me google.mg google.mk google.ml google.com.mm google.mn google.com.mt " +
    "google.mu google.mv google.mw google.com.mx google.com.my google.co.mz google.com.na google.com.ng " +
    "google.com.ni google.ne google.nl google.no google.com.np google.nr google.nu google.co.nz " +
    "google.com.om google.com.pa google.com.pe google.com.pg google.com.ph google.com.pk google.pl google.pn " +
    "google.com.pr google.ps google.pt google.com.py google.com.qa google.ro google.ru google.rw " +
    "google.com.sa google.com.sb google.sc google.se google.com.sg google.sh google.si google.sk " +
    "google.com.sl google.sn google.so google.sm google.sr google.st google.com.sv google.td " +
    "google.tg google.co.th google.com.tj google.tl google.tm google.tn google.to google.com.tr " +
    "google.tt google.com.tw google.co.tz google.com.ua google.co.ug google.co.uk google.com.uy google.co.uz " +
    "google.com.vc google.co.ve google.co.vi google.com.vn google.vu google.ws google.rs google.co.za " +
    "google.co.zm google.co.zw google.cat"
  ).trim().split(/\s+/));

  function isGoogleSearchURL(url) {
    if (!/^https?:\/\//i.test(String(url || ""))) return false;
    const parts = normalizedURLParts(url);
    if (!parts) return false;
    const googleHost = supportedGoogleSearchHosts.has(parts.host);
    return googleHost && (parts.path === "" || parts.path === "/" || parts.path === "/search");
  }

  function isAllowedURL(url, rules) {
    if (!rules.active) return true;
    const isBlacklist = rules.accessMode === "blacklist";
    if (rules.addAsYouGo && !isBlacklist) return true;
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

  const api = { normalizeRule, normalizedURLParts, isSearchStagingURL, isGoogleSearchURL, isAllowedURL,
    supportedGoogleSearchHosts: Object.freeze([...supportedGoogleSearchHosts]) };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.IntentBrowserRules = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
