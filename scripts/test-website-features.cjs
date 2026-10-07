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
  return matching[0]?.action.type || "allow";
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
const matrix = {
  instagram: {features:["messages","feed","reels","stories","explore"], paths:["/","/direct","/direct?x=1","/direct/#hash","/direct/t/123/","/directevil/","/reel/id","/reels","/stories/user/","/explore/","/someone/","/p/post/","/p","/accounts/login","/accounts/login?next=x","/accounts/password/reset","/accounts/other","/challenge","/two_factor/","/%64irect/t/1","/%72eels/","/direct%2ft/1","/DIRECT/T/1","/%","/%0","/%zz"]},
  youtube: {features:["search","feed","shorts","recommendations","comments","autoplay"], paths:["/","/watch?v=test","/embed/id","/live/id","/results?search_query=a","/resultsevil","/@course/videos","/@","/@/videos","/channel/1","/user/name","/playlist?list=x","/shorts?x=1","/shorts/id","/feed/subscriptions","/feed","/account","/oops","/unknown","/%73horts/id","/%77atch?v=x","/watch?bad=%zz"]}
};
for(const [site,{features,paths}] of Object.entries(matrix)) {
  for(let mask=site === "instagram" ? 1 : 0; mask < 2**features.length;mask++) {
    const policies={[site]:{version:1,allowedFeatures:features.filter((_,i)=>mask&(1<<i))}};
    for(const scope of [null,[42]]) {
      const generated=engine.networkRules(policies,scope).map(r=>({...r,regex:new RegExp(r.condition.regexFilter,"i")}));
      assert.ok(generated.every(r=>r.action.type==="block"),"Website features never grant outer permissions");
      assert.ok(generated.length<1000,"Stay within Chrome's regex rule budget");
      for(const path of paths) {
        for(const host of ["www."+site+".com",site+".com:443"]) {
          const url="https://"+host+path;
          const blocked=generated.some(r=>r.regex.test(url));
          assert.equal(!blocked,engine.permits(url,policies),`${site} ${mask} ${scope} ${url}`);
          // Every site-level verdict intersects, never expands, the outer policy.
          for(const outerAllowed of [false,true]) {
            const outer=[{priority:outerAllowed?2:1,action:{type:outerAllowed?"allow":"block"},regex:/^https?:/}];
            const winner=[...generated,...outer].filter(r=>r.regex.test(url)).sort((a,b)=>b.priority-a.priority)[0];
            assert.equal(winner.action.type!=="block",outerAllowed && engine.permits(url,policies),"Combined outer URL + feature permissions");
          }
        }
      }
    }
  }
}
console.log("Website features: route matrix, network precedence, malformed policies, CSS and browser parity passed");

// Session regex rules share one 1000-rule budget, including exact-tab/search
// restrictions. Exercise combined policies, not just each site separately.
let largestCombined=0;
const igFeatures=matrix.instagram.features, ytFeatures=matrix.youtube.features;
for(let im=1;im<2**igFeatures.length;im++) for(let ym=0;ym<2**ytFeatures.length;ym++) {
  const both={instagram:{version:1,allowedFeatures:igFeatures.filter((_,i)=>im&(1<<i))},youtube:{version:1,allowedFeatures:ytFeatures.filter((_,i)=>ym&(1<<i))}};
  const generated=engine.networkRules(both,[42],{sources:["instagram.com"],excludedSources:[]});
  largestCombined=Math.max(largestCombined,generated.length);
  assert.ok(generated.length+3<=1000,"Combined feature + exact-tab/search regex budget");
  assert.ok(generated.every(r=>r.id>=24000&&r.id<25000),"Feature IDs stay in the fully cleaned namespace");
}
console.log("Largest combined feature rule set: "+largestCombined+" (plus 3 exact-tab/search rules; Chrome session regex limit 1000)");
