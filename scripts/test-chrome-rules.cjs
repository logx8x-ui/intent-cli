#!/usr/bin/env node

const assert = require("node:assert/strict");
const rules = require("../chrome-extension/rule-helpers.js");

const instagram = {
  active: true,
  allowedWebsites: ["instagram.com/direct"],
  allowGoogleSearchTabs: true
};

assert.equal(rules.isAllowedURL("https://instagram.com/direct/inbox/", instagram), true);
assert.equal(rules.isAllowedURL("https://instagram.com/explore/", instagram), false);
assert.equal(rules.isAllowedURL("chrome://newtab/", instagram), true);
assert.equal(rules.isAllowedURL("chrome://new-tab-page/", instagram), true);
assert.equal(rules.isAllowedURL("chrome-search://local-ntp/local-ntp.html", instagram), true);
assert.equal(rules.isAllowedURL("https://www.google.com/search?q=intent", instagram), true);
assert.equal(rules.isAllowedURL("https://youtube.com/", instagram), false);
assert.equal(rules.isAllowedURL("https://anything.example/", { ...instagram, active: false }), true);

const blacklist = {
  active: true,
  accessMode: "blacklist",
  allowedWebsites: ["youtube.com", "instagram.com/reels"],
  allowGoogleSearchTabs: false
};
assert.equal(rules.isAllowedURL("https://youtube.com/watch?v=1", blacklist), false);
assert.equal(rules.isAllowedURL("https://instagram.com/reels/123", blacklist), false);
assert.equal(rules.isAllowedURL("https://wikipedia.org/wiki/Focus", blacklist), true);
assert.equal(rules.isAllowedURL("chrome://newtab/", blacklist), true);
assert.equal(rules.isAllowedURL("https://example.com/", { ...blacklist, allowedWebsites: [] }), true);

console.log("Chrome rule helper spec passed");
