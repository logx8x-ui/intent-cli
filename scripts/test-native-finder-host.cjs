const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const host = process.env.INTENT_NATIVE_HOST_PATH || path.resolve('.build/release/IntentNativeHost');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-native-finder-protocol-'));
const browser = 'com.google.Chrome', session = 'finder-profile';
const envelope = { browserBundleIdentifier: browser, browserSessionID: session,
  extensionCapabilities: ['native-website-finder-v1'], extensionVersion: '0.2.35' };
function frame(value) { const data = Buffer.from(JSON.stringify(value)), header = Buffer.alloc(4); header.writeUInt32LE(data.length); return Buffer.concat([header, data]); }
function call(messages) {
  const result = spawnSync(host, { input: Buffer.concat(messages.map(message => frame({ ...envelope, ...message }))),
    env: { ...process.env, INTENT_NATIVE_HOST_DIRECTORY: root } });
  assert.equal(result.status, 0, result.stderr.toString());
  let offset = 0; const messagesOut = [];
  while (offset < result.stdout.length) { const count = result.stdout.readUInt32LE(offset); offset += 4; messagesOut.push(JSON.parse(result.stdout.subarray(offset, offset + count))); offset += count; }
  return messagesOut;
}
function prepare(action = 'open') {
  const request = { id: crypto.randomUUID(), finderID: crypto.randomUUID(), action, browserSessionID: session,
    anchorTabID: 7, windowID: 4, frame: {left:100, top:100, width:720, height:520}, expiresAtUnixMS: Date.now()+8000,
    ...(action === 'commit' ? {finderWindowID:10, finderTabID:20} : {}) };
  const channel = 'browser-finder-com-google-Chrome-' + crypto.createHash('sha256').update(session).digest('hex').slice(0,24) + '.json';
  fs.writeFileSync(path.join(root, channel), JSON.stringify([request]));
  const receipt = { requestID:request.id, finderID:request.finderID, action, browserSessionID:session, originalWindowID:4, anchorTabID:7,
    ...(action === 'open' ? {windowID:10, tabID:20, frame:request.frame} : action === 'commit' ? {windowID:4, tabID:20,
      tab:{id:20, windowID:4, index:2, title:'Selected', url:'https://example.test', active:false}} : {}) };
  return {request, receipt, resultPath:path.join(root, 'browser-finder-result-'+request.id+'.json')};
}
try {
  for (const action of ['open','commit','cancel']) {
    const item=prepare(action);const replies=call([{type:'getRules'},{type:'nativeFinderResult',finder:item.receipt}]);
    assert(replies.some(reply=>reply.finderCommand?.id===item.request.id),'The exact profile host delivers '+action);
    assert.deepEqual(JSON.parse(fs.readFileSync(item.resultPath)),item.receipt,'Matching '+action+' receipt persists');
  }
  for (const patch of [{browserSessionID:'other'}, {originalWindowID:5}, {anchorTabID:8}, {finderID:crypto.randomUUID()}, {action:'cancel'}, {tabID:21,tab:{id:21,windowID:4,index:2,title:'Other',url:'https://example.test',active:false}}]) {
    const item=prepare('commit');call([{type:'getRules'},{type:'nativeFinderResult',finder:{...item.receipt,...patch}}]);
    assert(!fs.existsSync(item.resultPath),'Wrong ownership cannot acknowledge a finder effect');
  }
  let item=prepare();call([{type:'nativeFinderResult',finder:item.receipt}]);
  assert(!fs.existsSync(item.resultPath),'Unissued receipt cannot create an accepted finder');
  fs.writeFileSync(path.join(root,'browser-rules.json'),JSON.stringify({active:true,allowedWebsites:[],blockTabSwitching:true,
    unrestrictedBrowserBundleIdentifiers:[browser],blockNavigation:true,blockNewTabs:false,allowGoogleSearchTabs:false,
    updatedAt:Date.now()/1000-978307200}));
  for(const action of ['open','commit']) {item=prepare(action);const replies=call([{type:'getRules'}]);assert(replies.every(r=>!r.finderCommand),'Globally active intention prevents '+action+' even for unrestricted browser');}
  item=prepare('cancel');const replies=call([{type:'getRules'}]);assert(replies.some(r=>r.finderCommand?.action==='cancel'),'Owned cancellation remains available during active rules');
  console.log('Native finder host: profile partition, immutable ownership receipts, active-session rejection and safe cancellation passed');
} finally { fs.rmSync(root,{recursive:true,force:true}); }
