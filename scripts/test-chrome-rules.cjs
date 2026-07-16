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
assert.equal(rules.isAllowedURL("https://www.google.com/search?q=intent", instagram), true);
assert.equal(rules.isAllowedURL("https://youtube.com/", instagram), false);
assert.equal(rules.isAllowedURL("https://anything.example/", { ...instagram, active: false }), true);

console.log("Chrome rule helper spec passed");
