#!/usr/bin/env node

const assert = require("node:assert/strict");
const rules = require("../firefox-extension/rule-helpers.js");

const instagramRules = {
  active: true,
  allowedWebsites: ["instagram.com/direct"],
  allowGoogleSearchTabs: true
};

assert.equal(
  rules.isAllowedURL("https://www.instagram.com/direct/inbox/", instagramRules),
  true,
  "Instagram DMs should stay allowed"
);
assert.equal(
  rules.isAllowedURL("https://www.instagram.com/explore/", instagramRules),
  false,
  "Other Instagram pages should stay blocked"
);
assert.equal(
  rules.isAllowedURL("about:newtab", instagramRules),
  true,
  "Search-enabled sessions should allow staging tabs"
);
assert.equal(
  rules.isAllowedURL("https://www.google.com/search?q=lol", instagramRules),
  true,
  "Google results pages should stay allowed when search tabs are enabled"
);
assert.equal(
  rules.isAllowedURL("https://leagueoflegends.com/", instagramRules),
  false,
  "Clicking through from Google should stay blocked"
);

const strictGithubRules = {
  active: true,
  allowedWebsites: ["github.com"],
  allowGoogleSearchTabs: false
};
assert.equal(
  rules.isAllowedURL("about:newtab", strictGithubRules),
  false,
  "New tabs should be blocked when Google-search tabs are not enabled"
);
assert.equal(
  rules.isAllowedURL("https://www.google.com/search?q=github", strictGithubRules),
  false,
  "Google search tabs should be blocked when the Google-search exception is off"
);
assert.equal(
  rules.isAllowedURL("https://gist.github.com/", strictGithubRules),
  true,
  "Subdomains of allowed domains should stay allowed"
);

const idleRules = {
  active: false,
  allowedWebsites: ["instagram.com/direct"],
  allowGoogleSearchTabs: false
};
assert.equal(
  rules.isAllowedURL("https://example.com/", idleRules),
  true,
  "Idle browser rules should not interfere with normal browsing"
);

console.log("Firefox rule helper spec passed");
