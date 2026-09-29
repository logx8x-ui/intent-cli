const assert = require("node:assert/strict");
const fs = require("node:fs");
const engine = require("../chrome-extension/website-features.js");
for (const file of ["website-features.js", "site-feature-guard.js"]) {
  assert.equal(fs.readFileSync("chrome-extension/" + file, "utf8"), fs.readFileSync("firefox-extension/" + file, "utf8"), file + " browser parity");
}
const policies = {instagram: {version:1, allowedFeatures:["messages"]}, youtube: {version:1, allowedFeatures:["search"]}};
const cases = [
  ["https://www.instagram.com/direct/inbox/", true],
  ["https://www.instagram.com/direct/t/123/", true],
  ["https://www.instagram.com/accounts/login/", true],
  ["https://www.instagram.com/", false],
  ["https://www.instagram.com/reels/", false],
  ["https://www.instagram.com/stories/friend/", false],
  ["https://www.instagram.com/explore/", false],
  ["https://www.instagram.com/someone/", false],
  ["https://www.youtube.com/watch?v=abc", true],
  ["https://www.youtube.com/results?search_query=calculus", true],
  ["https://www.youtube.com/@course/videos", true],
  ["https://www.youtube.com/shorts/abc", false],
  ["https://www.youtube.com/", false],
  ["https://www.youtube.com/feed/subscriptions", false],
  ["https://www.youtube.com/resultsevil", false],
  ["https://youtube.com.evil.test/shorts/x", true]
];
for (const [url, allowed] of cases) assert.equal(engine.permits(url, policies), allowed, url);
assert.equal(engine.permits("https://www.instagram.com/%E0%A4%A", policies), false, "Malformed encoding fails closed without throwing");
assert.equal(engine.permits("https://www.youtube.com/shorts/a", {}), true, "Old intentions unchanged");
assert.equal(engine.permits("https://www.youtube.com/watch?v=a", {youtube:{version:99,allowedFeatures:[]}}), false, "Unknown policy version is not ignored");
assert.equal(engine.siteOf("https://notinstagram.com/"), null);

const rules = engine.networkRules(policies, [42]);
function verdict(url, tabID, extra = []) {
  const matching = [...rules, ...extra].filter(rule =>
    (!rule.condition.tabIds || rule.condition.tabIds.includes(tabID))
    && (!rule.condition.excludedTabIds || !rule.condition.excludedTabIds.includes(tabID))
    && new RegExp(rule.condition.regexFilter, "i").test(url)).sort((a,b) => b.priority - a.priority);
  return matching[0]?.action.type;
}
for (const [url, allowed] of cases.filter(([url]) => !url.includes("evil"))) {
  assert.equal(verdict(url, 42), allowed ? "allow" : "block", "Network route " + url);
}
const tabBlock = {priority:1000,action:{type:"block"},condition:{excludedTabIds:[42],regexFilter:"^https?://"}};
assert.equal(verdict("https://www.youtube.com/watch?v=a", 99, [tabBlock]), "block", "Feature allowance cannot override unselected-tab block");
assert.equal(new Set(rules.map(r=>r.id)).size, rules.length);
assert.ok(engine.networkRules(policies, null).every(r => r.action.type === "block"), "URL-scoped sessions can only narrow existing permissions");
assert.deepEqual(engine.networkRules(policies, []), []);
const css = engine.css("youtube", policies.youtube);
for (const selector of ["#comments", "#related", "/shorts/", "autonav"]) assert.ok(css.includes(selector), selector);
const all = {version:1,allowedFeatures:["search","feed","shorts","recommendations","comments","autoplay"]};
assert.equal(engine.css("youtube", all), "", "Checking all optional features restores the original page");
console.log("Website features: route matrix, network precedence, malformed policies, CSS and browser parity passed");
