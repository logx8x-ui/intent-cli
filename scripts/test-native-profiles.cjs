const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const {spawnSync} = require("node:child_process");
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "intent-profile-spec-"));
const browser = "com.google.Chrome";
const now = Date.now()/1000 - 978307200;
const hash = value => crypto.createHash("sha256").update(value).digest("hex");
const id = (session, tab) => parseInt(hash(session + ":" + tab).slice(0,12),16);
function invoke(session, messages) {
  const input = Buffer.concat(messages.map(message => {
    const body = Buffer.from(JSON.stringify({...message, browserSessionID:session, browserBundleIdentifier:browser}));
    const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
    return Buffer.concat([header,body]);
  }));
  const run = spawnSync(path.resolve(".build/release/IntentNativeHost"), {input, env:{...process.env,INTENT_NATIVE_HOST_DIRECTORY:directory}});
  assert.equal(run.status,0,run.stderr.toString());
  const replies=[]; let offset=0;
  while(offset<run.stdout.length) {
    const count=run.stdout.readUInt32LE(offset); offset+=4;
    replies.push(JSON.parse(run.stdout.subarray(offset,offset+count))); offset+=count;
  }
  return replies;
}
try {
  fs.writeFileSync(path.join(directory,"browser-rules.json"), JSON.stringify({
    active:true,accessMode:"whitelist",allowedWebsites:[],allowedWebsitesByBrowser:{[browser]:["youtube.com"]},
    selectedTabIDsByBrowser:{[browser]:[id("a",7)]},
    selectedBrowserSessionIDsByBrowser:{[browser]:"profiles:a|b"},
    startupSessionID:"test-session",updatedAt:now,blockTabSwitching:true,blockNavigation:true,blockNewTabs:false,
    websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:["search"]}}
  }));
  const snapshot = {type:"tabsSnapshot",tabs:[{id:7,windowID:2,index:0,title:"Test",url:"https://www.youtube.com/watch?v=test",active:true}]};
  const a = invoke("a",[snapshot,{type:"getRules"}]).at(-1);
  const b = invoke("b",[snapshot,{type:"getRules"}]).at(-1);
  assert.deepEqual(a.selectedTabIDs,[7]);
  assert.deepEqual(b.selectedTabIDs,[], "Other profile's tab 7 must not inherit permission");
  assert.equal(a.selectedBrowserSessionID,"a");
  assert.equal(b.selectedBrowserSessionID,"b");
  assert.deepEqual(a.websiteFeaturePolicies.youtube.allowedFeatures,["search"]);
  const commandFile = path.join(directory,"browser-tab-command-com-google-Chrome.profile-"+hash("a").slice(0,24)+".json");
  fs.writeFileSync(commandFile,JSON.stringify({id:"command-a",tabID:7,windowID:2,action:"activate",browserSessionID:"a",createdAt:now}));
  assert.ok(!invoke("b",[{type:"getRules"}]).some(r=>r.tabCommand?.id==="command-a"));
  assert.ok(fs.existsSync(commandFile));
  assert.ok(invoke("a",[{type:"getRules"}]).some(r=>r.tabCommand?.id==="command-a"));
  invoke("a",[{type:"websitePolicyReady",appliedWebsitePolicySessionID:"test-session"}]);
  const receipt = path.join(directory,"website-policy-ack-com.google.Chrome.profile-"+hash("a").slice(0,24)+".json");
  assert.equal(JSON.parse(fs.readFileSync(receipt)).startupSessionID,"test-session");
  console.log("Native profiles: partitioned snapshots, exact-tab policy translation, command routing and receipts passed");
} finally { fs.rmSync(directory,{recursive:true,force:true}); }
