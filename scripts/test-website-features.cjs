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
  ["https://www.youtube.com/", true],
  ["https://www.youtube.com/?app=desktop", true],
  ["https://www.youtube.com/#search", true],
  ["https://www.youtube.com/feed/subscriptions", false],
  ["https://www.youtube.com/unknown", false],
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
assert.equal(verdict("https://www.youtube.com/", 99, [tabBlock]), "block", "Search shell cannot override an unselected-tab block");
assert.equal(verdict("https://www.youtube.com/", 42, [{priority:1,action:{type:"block"},condition:{regexFilter:"^https://www\\.youtube\\.com/"}}]),
  "block", "Search shell remains unavailable when an outer URL policy blocks YouTube");
assert.equal(new Set(rules.map(r=>r.id)).size, rules.length);
assert.ok(engine.networkRules(policies, null).every(r => r.action.type === "block"), "URL-scoped sessions can only narrow existing permissions");
assert.deepEqual(engine.networkRules(policies, []), []);
const css = engine.css("youtube", policies.youtube);
for (const selector of ["#comments", "#related", "/shorts/", "autonav"]) assert.ok(css.includes(selector), selector);
assert.ok(css.includes('ytd-browse[page-subtype="home"]'), "Search-only shell still hides the Home feed");
assert.ok(!/(?:ytd-masthead|ytd-searchbox|html|body)\s*[,\{]/.test(css), "Feed hiding must not hide the native search/header shell");
for (const allowedFeatures of [[],["search"],["feed"],["search","feed"],["comments"]]) {
  const p={youtube:{version:1,allowedFeatures}};
  assert.equal(engine.permits("https://www.youtube.com/",p),allowedFeatures.includes("search")||allowedFeatures.includes("feed"),
    "Root shell is available exactly when Search or Feed is enabled");
  assert.equal(engine.permits("https://www.youtube.com/feed/subscriptions",p),allowedFeatures.includes("feed"),
    "Allowing root Search never enables Feed routes");
}
// Independent product contract: every one of the 32 Instagram combinations,
// including none selected, is checked against explicit feature expectations.
// These expectations do not call the engine to compute their answer.
const instagramFeatures=["messages","feed","reels","stories","explore"];
const instagramRoutes=[
  ["/",f=>f.feed||f.stories], ["/?source=home",f=>f.feed||f.stories], ["/#stories",f=>f.feed||f.stories],
  ["/direct/inbox/",f=>f.messages], ["/direct/t/123/",f=>f.messages],
  ["/reels/",f=>f.reels], ["/reel/example/",f=>f.reels],
  ["/stories/friend/123/",f=>f.stories],
  ["/explore/",f=>f.explore], ["/explore/search/",f=>f.explore], ["/someone/",f=>f.explore],
  ["/someone/tagged/",f=>f.explore], ["/someone/reels/",f=>f.explore&&f.reels],
  ["/s/reels/",f=>f.explore&&f.reels], ["/storiesx/reels/",f=>f.explore&&f.reels],
  ["/stories/reels/123/",f=>f.stories], ["/direct/t/reels/",f=>f.messages], ["/p/example/",f=>f.feed||f.explore],
  ["/accounts/login/",()=>true], ["/challenge/",()=>true]
];
for(let mask=0;mask<32;mask++) {
  const flags=Object.fromEntries(instagramFeatures.map((feature,i)=>[feature,Boolean(mask&(1<<i))]));
  const instagram={version:1,allowedFeatures:instagramFeatures.filter(feature=>flags[feature])}, policy={instagram};
  const valid=mask!==0;
  const expectedLanding=!valid?null:"https://www.instagram.com"+(flags.feed||flags.stories?"/":flags.messages?"/direct/inbox/":flags.reels?"/reels/":"/explore/");
  assert.equal(engine.valid("instagram",instagram),valid,`Instagram ${mask}: empty selection stays invalid`);
  assert.deepEqual(engine.instagramSurfaces(instagram),{home:flags.feed||flags.stories,...flags},`Instagram ${mask}: independent content surfaces`);
  assert.equal(engine.landingDestination("instagram",policy),expectedLanding,`Instagram ${mask}: enabled landing`);
  if(expectedLanding) assert.equal(engine.preferredDestination(expectedLanding,policy),null,`Instagram ${mask}: no landing redirect loop`);
  const routed=engine.networkRules(policy,[42],{sources:["instagram.com"],excludedSources:[]});
  for(const [path,expect] of instagramRoutes) {
    const url="https://www.instagram.com"+path, allowed=valid&&expect(flags);
    assert.equal(engine.permits(url,policy),allowed,`Instagram ${mask}: explicit route ${path}`);
    assert.equal(engine.preferredDestination(url,policy),allowed?null:expectedLanding,`Instagram ${mask}: denied route landing ${path}`);
    const winner=routed.filter(rule=>new RegExp(rule.condition.regexFilter,"i").test(url)).sort((a,b)=>b.priority-a.priority)[0];
    assert.equal(winner?.action.type||"allow",allowed?"allow":valid?"redirect":"block",`Instagram ${mask}: DNR route ${path}`);
    if(winner?.action.type==="redirect") assert.equal(winner.action.redirect.url,expectedLanding);
  }
}
// Scoped redirects for profile Reels must retain raw outer URL boundaries.
for(const source of ["instagram.com/someone","instagram.com/someone/reels","instagram.com/someone%2freels"]) {
  const p={instagram:{version:1,allowedFeatures:["explore"]}};
  const generated=engine.networkRules(p,[42],{sources:[source],excludedSources:[]});
  const winner=url=>generated.filter(rule=>new RegExp(rule.condition.regexFilter,"i").test(url)).sort((a,b)=>b.priority-a.priority)[0];
  assert.equal(winner("https://"+source+(source.endsWith("someone")?"/reels/":"/")).action.type,"redirect","Only the allowed profile source can redirect");
  assert.equal(winner("https://www.instagram.com/another/reels/").action.type,"block","Unrelated profile is not captured by a scoped redirect");
}
assert.equal(engine.landingDestination("instagram",{}),null,"No policy means no new navigation behavior for old intentions");
assert.equal(engine.preferredDestination("https://unrelated.example/",{instagram:{version:1,allowedFeatures:["stories"]}}),null);

const all = {version:1,allowedFeatures:["search","feed","shorts","recommendations","comments","autoplay"]};
assert.equal(engine.css("youtube", all), "", "Checking all optional features restores the original page");
const matrix = {
  instagram: {features:["messages","feed","reels","stories","explore"], paths:["/","/direct","/direct?x=1","/direct/#hash","/direct/t/123/","/directevil/","/reel/id","/reels","/stories/user/","/explore/","/someone/","/someone/reels/","/s/reels/","/storiesx/reels/","/stories/reels/123/","/direct/t/reels/","/%73omeone/%72eels/","/someone%2freels/","/p/post/","/p","/accounts/login","/accounts/login?next=x","/accounts/password/reset","/accounts/other","/challenge","/two_factor/","/%64irect/t/1","/%72eels/","/direct%2ft/1","/DIRECT/T/1","/%","/%0","/%zz"]},
  youtube: {features:["search","feed","shorts","recommendations","comments","autoplay"], paths:["/","/?app=desktop","/#search","/watch?v=test","/embed/id","/live/id","/results?search_query=a","/resultsevil","/@course/videos","/@","/@/videos","/channel/1","/user/name","/playlist?list=x","/shorts?x=1","/shorts/id","/feed/subscriptions","/feed","/account","/oops","/unknown","/%73horts/id","/%77atch?v=x","/watch?bad=%zz"]}
};
for(const [site,{features,paths}] of Object.entries(matrix)) {
  for(let mask=0; mask < 2**features.length;mask++) {
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
