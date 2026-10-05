#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn, spawnSync} = require('node:child_process');
const host = process.env.INTENT_NATIVE_HOST_PATH || path.resolve(__dirname, '../.build/release/IntentNativeHost');
const browser = 'com.google.Chrome', profile = 'coverage-profile';
const proof = {pid: process.pid, launched: 1};
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-qa-coverage-snapshot-'));
fs.chmodSync(directory, 0o700);
fs.writeFileSync(path.join(directory, '.intent-qa-root'), 'Intent isolated QA data v1\n', {mode:0o600});
const qaHost = path.join(directory, 'IntentQASpec');
fs.copyFileSync(host, qaHost); fs.chmodSync(qaHost, 0o700);
assert.equal(spawnSync('/usr/bin/codesign', ['--force','--sign','-',qaHost]).status,0);
function frame(message) {
  const body = Buffer.from(JSON.stringify({browserBundleIdentifier:browser,browserSessionID:profile,...message}));
  const header = Buffer.alloc(4); header.writeUInt32LE(body.length); return Buffer.concat([header,body]);
}
async function until(predicate, message) {
  const deadline = Date.now()+4000;
  while (Date.now()<deadline) {
    if (predicate()) return;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  throw new Error(message);
}
const child = spawn(qaHost, {env:{...process.env,INTENT_QA_ROOT:directory,
  INTENT_NATIVE_HOST_DIRECTORY:directory,INTENT_QA_BROWSER_PROCESS_IDENTITY:JSON.stringify(proof)}});
let output=Buffer.alloc(0); const replies=[];
child.stdout.on('data', chunk=>{
  output=Buffer.concat([output,chunk]);
  while(output.length>=4 && output.length>=4+output.readUInt32LE(0)) {
    const size=output.readUInt32LE(0); replies.push(JSON.parse(output.subarray(4,4+size))); output=output.subarray(4+size);
  }
});
child.stderr.resume();
const file=path.join(directory,'browser-tabs-com-google-Chrome.json');
const coverageFile=path.join(directory,'browser-tabs-com-google-Chrome.coverage-profile-'+crypto.createHash('sha256').update(profile).digest('hex').slice(0,24)+'.json');
const readCoverage=()=>{try{return JSON.parse(fs.readFileSync(coverageFile));}catch{return null;}};
const read=()=>{try{return JSON.parse(fs.readFileSync(file));}catch{return null;}};
const tabs=[{id:1,windowID:7,index:0,title:'Example',url:'https://example.test',active:true,
  windowFrame:{left:20,top:40,width:900,height:700}}];
async function request(id) {
  fs.writeFileSync(path.join(directory,'browser-tab-command-com-google-Chrome.json'), JSON.stringify({id,tabID:-1,windowID:-1,action:'snapshot',createdAt:Date.now()/1000-978307200}));
  await until(()=>replies.some(reply=>reply.tabCommand?.id===id),'Host did not issue discovery command '+id);
}
async function snapshot(extra={}) {
  const before=read()?.updatedAt;
  child.stdin.write(frame({type:'tabsSnapshot',tabs,allTabs:tabs,completeWindowInventory:true,...extra}));
  await until(()=>read()?.updatedAt!==before,'Snapshot was not persisted');
  return read();
}
(async()=>{
  try {
    child.stdin.write(frame({type:'getRules',extensionCapabilities:['native-window-visibility-v1']}));
    await until(()=>replies.length,'Host did not connect');
    let value=await snapshot({snapshotRequestIDs:['never-issued']});
    assert.deepEqual(value.browserProcessIdentity,proof,'Process identity is host-attested, not supplied by the snapshot');
    assert.equal(value.snapshotRequestIDs,undefined,'Unissued request ID cannot establish discovery freshness');
    await request('coverage-one');
    value=await snapshot({snapshotRequestIDs:['coverage-one','never-issued']});
    assert.deepEqual(value.snapshotRequestIDs,['coverage-one']);
    assert.equal(value.completeWindowInventory,true);
    assert.equal(value.guardEnabled,true);
    assert.ok(value.guardCapabilities.includes('native-window-visibility-v1'));
    assert.deepEqual(value.allTabs,tabs);
    await until(()=>readCoverage()?.snapshotRequestIDs?.includes('coverage-one'),'Correlated sidecar was not persisted');
    const retained = readCoverage();
    assert.deepEqual(retained.snapshotRequestIDs,['coverage-one']);
    value = await snapshot({snapshotRequestIDs:[],completeWindowInventory:false,tabs:[],allTabs:[]});
    assert.equal(value.completeWindowInventory,undefined,'Ordinary idle snapshot is never stamped complete');
    assert.deepEqual(readCoverage(),retained,'Ordinary overwrite cannot erase the correlated discovery reply');
    await request('coverage-two');
    value=await snapshot({snapshotRequestIDs:['coverage-two'],allTabs:undefined});
    assert.equal(value.snapshotRequestIDs,undefined,'Filtered tabs alone are not a full-window inventory');
    for (const completeWindowInventory of [undefined, false]) {
      const id = 'coverage-incomplete-' + String(completeWindowInventory);
      await request(id);
      value = await snapshot({snapshotRequestIDs:[id],completeWindowInventory});
      assert.equal(value.snapshotRequestIDs,undefined,'Uncertified windows enumeration earns no discovery receipt');
      assert.equal(value.completeWindowInventory,undefined);
    }
    await request('coverage-three');
    value=await snapshot({snapshotRequestIDs:['coverage-three'],browserSessionID:'foreign-profile'});
    assert.equal(value.snapshotRequestIDs,undefined,'Another profile cannot borrow this host request');
    assert.equal(value.browserProcessIdentity,undefined,'Another profile cannot borrow host process attestation');
    await request('coverage-disabled');
    child.stdin.write(frame({type:'setGuardEnabled',enabled:false}));
    value=await snapshot({snapshotRequestIDs:['coverage-disabled']});
    assert.deepEqual(value.snapshotRequestIDs,['coverage-disabled']);
    assert.equal(value.guardEnabled,false,'Disabled guard remains explicit and cannot become coverage-ready');
    console.log('Chrome coverage snapshots: correlated full discovery, host identity, profile isolation and readiness passed');
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const ended = new Promise(resolve=>child.once('exit',resolve));
      child.stdin.end(); child.kill(); await ended;
    }
    fs.rmSync(directory,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
