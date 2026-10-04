#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Owner = require('../firefox-extension/native-window-visibility.js');
assert.equal(fs.readFileSync(path.join(__dirname,'../firefox-extension/native-window-visibility.js'),'utf8'),
  fs.readFileSync(path.join(__dirname,'../chrome-extension/native-window-visibility.js'),'utf8'));
const tick = () => new Promise(resolve => setImmediate(resolve));
const clone = value => JSON.parse(JSON.stringify(value));
const window = id => ({windowID:id,title:'QA window '+id,frame:{left:0,top:30,width:1000,height:700},state:'normal'});
const rules = {active:true,nativeWindowVisibility:true,startupSessionID:'intention-a'};
async function run() {
  let storage = {}, localStorage = {}, messages = [], sendWorks = true, time = 100;
  const initialProcess = {pid:100,launched:800000000};
  const api = {storage:{session:{get:async () => clone(storage),set:async data => {storage = clone({...storage,...data});}},local:{get:async()=>clone(localStorage),set:async data=>{localStorage=clone({...localStorage,...data});}}}};
  let owner = new Owner(api, message => {messages.push(message); return sendWorks;}, ()=>'browser-a',{timeout:25,now:()=>time});
  owner.receive({browserProcessIdentity:initialProcess});
  let promise = owner.publishPlan(rules,[window(1)],[window(9)]);
  await tick();
  assert.equal(messages.length,1);
  assert.equal(storage.intentNativeWindowVisibilityV1.revision,1,'persist counter before sending');
  assert.equal(storage.intentNativeWindowVisibilityV1.plans['intention-a'],undefined,'not owned before durable ACK');
  owner.receive({visibilityPlanReceipt:{revision:1,accepted:true}});
  assert.equal(await promise,true);
  assert.equal(storage.intentNativeWindowVisibilityV1.plans['intention-a'].parkingWindows[0].windowID,9);
  assert.equal(await owner.publishPlan(rules,[window(1)],[window(9)]),true);
  assert.equal(messages.length,1,'same accepted plan throttled');
  owner.disconnected();
  owner.receive({browserProcessIdentity:initialProcess});
  promise = owner.publishPlan(rules,[window(1)],[window(9)]); await tick();
  assert.equal(messages.at(-1).visibilityPlan.revision,2,'reconnect resends even inside throttle period');
  owner.receive({visibilityPlanReceipt:{revision:2,accepted:true}}); assert.equal(await promise,true);

  // A new worker in the same browser lifetime cannot replay old revisions.
  owner = new Owner(api, message => {messages.push(message); return sendWorks;}, ()=>'browser-a',{timeout:25,now:()=>time});
  owner.receive({browserProcessIdentity:initialProcess});
  promise = owner.publishPlan(rules,[window(1)],[window(9)]); await tick();
  assert.equal(messages.at(-1).visibilityPlan.revision,3);
  owner.receive({visibilityPlanReceipt:{revision:3,accepted:false}}); assert.equal(await promise,false);
  sendWorks = false;
  assert.equal(await owner.publishPlan(rules,[window(1)],[window(9)]),false);
  sendWorks = true;
  promise = owner.publishPlan(rules,[window(1)],[window(9)]); await tick();
  const timedOutRevision = messages.at(-1).visibilityPlan.revision;
  assert.equal(await promise,false,'transport timeout does not transfer JS ownership');
  owner.receive({visibilityPlanReceipt:{revision:timedOutRevision,accepted:true}});
  promise = owner.publishPlan(rules,[window(1)],[window(9)]); await tick();
  const retryRevision = messages.at(-1).visibilityPlan.revision;
  assert.ok(retryRevision > timedOutRevision);
  owner.receive({visibilityPlanReceipt:{revision:timedOutRevision,accepted:true}});
  owner.receive({visibilityPlanReceipt:{revision:retryRevision,accepted:true}});
  assert.equal(await promise,true);

  const beforeUnknown = messages.length;
  assert.equal(await owner.revealWindows('intention-a',[window(99)]),false);
  assert.equal(messages.length,beforeUnknown,'unknown parking ID cannot be revealed');
  assert.equal(await owner.revealWindows('unknown-session',[window(9)]),false);
  promise = owner.revealWindows('intention-a',[{...window(9),title:'Changed after tabs moved',frame:{left:80,top:60,width:900,height:600}}]);
  await tick();
  const reveal = messages.at(-1).visibilityPlan;
  assert.deepEqual(reveal.revealWindowIDs,[9]);
  assert.deepEqual(reveal.parkingWindows,[window(9)],'inactive recovery must reuse accepted identity');
  owner.receive({visibilityPlanReceipt:{revision:reveal.revision,accepted:true}});
  assert.equal(await promise,true);
  time += 10001;
  promise = owner.revealWindows('intention-a',[window(9)]); await tick();
  owner.disconnected(); assert.equal(await promise,false,'disconnect settles pending operation for retry');
  assert.equal(await owner.publishPlan({...rules,nativeWindowVisibility:false},[],[]),false);
  assert.equal(await owner.publishPlan(rules,[{...window(1),frame:{left:0,top:0,width:NaN,height:700}}],[]),false);
  assert.equal(await owner.publishPlan(rules,[window(1),window(1)],[]),false);

  // A browser restart gets a new identity rather than reusing another lifetime's receipts.
  owner = new Owner(api, message => {messages.push(message);return true;}, ()=>'browser-b',{timeout:25});
  assert.equal(await owner.revealWindows('intention-a',[window(9)]),false);
  promise = owner.publishPlan(rules,[],[]);await tick();
  assert.equal(messages.at(-1).visibilityPlan.revision,1);
  owner.receive({visibilityPlanReceipt:{revision:1,accepted:true}});assert.equal(await promise,true);

  const previousProcessIdentity = {pid:100,launched:800000000};
  const currentProcessIdentity = {pid:200,launched:800001000};
  const restartRequest = {intentionSessionID:'intention-a',previousBrowserSessionID:'browser-a',previousProcessIdentity};
  assert.equal(await owner.authorizeRestartRecovery(restartRequest),false,'unknown host generation cannot recover');
  owner.receive({active:false,browserProcessIdentity:previousProcessIdentity});
  assert.equal(await owner.authorizeRestartRecovery(restartRequest),false,'extension reload is not browser restart');
  owner.receive({active:true,browserProcessIdentity:currentProcessIdentity});
  assert.equal(await owner.authorizeRestartRecovery(restartRequest),false,'active intention cannot use startup recovery');
  for (const outcome of ['accepted','rejected','new-session','new-process','disconnect','timeout']) {
    owner.receive({active:false,browserProcessIdentity:currentProcessIdentity});
    promise = owner.authorizeRestartRecovery(restartRequest); await tick();
    const message = messages.at(-1);
    assert.equal(message.type,'windowVisibilityRestartRecovery');
    assert.deepEqual(message.visibilityRestartRequest.previousProcessIdentity,previousProcessIdentity);
    if (outcome === 'new-session') owner.receive({active:true});
    if (outcome === 'new-process') owner.receive({browserProcessIdentity:{pid:300,launched:800002000}});
    if (outcome === 'disconnect') owner.disconnected();
    if (outcome !== 'timeout') owner.receive({visibilityRestartReceipt:{requestID:message.visibilityRestartRequest.requestID,accepted:outcome !== 'rejected'}});
    assert.equal(await promise,outcome === 'accepted',`restart recovery ${outcome}`);
  }

  const priorRequest = {...restartRequest,windowIDs:[9]};
  owner.receive({active:false,browserProcessIdentity:currentProcessIdentity});
  assert.equal(await owner.recoverPriorWindows(priorRequest),false,'native prior-session recovery never crosses browser processes');
  owner.receive({active:false,browserProcessIdentity:previousProcessIdentity});
  assert.equal(await owner.recoverPriorWindows({...priorRequest,windowIDs:[9,9]}),false,'duplicate identities rejected');
  for (const outcome of ['accepted','rejected','different-active-intention','new-process','disconnect','timeout']) {
    owner.receive({active:false,browserProcessIdentity:previousProcessIdentity});
    promise = owner.recoverPriorWindows(priorRequest); await tick();
    const message = messages.at(-1);
    assert.equal(message.type,'windowVisibilityRecovery');
    assert.deepEqual(message.visibilityRecoveryRequest.windowIDs,[9]);
    if (outcome === 'different-active-intention') owner.receive({active:true,startupSessionID:'new-intention',browserProcessIdentity:previousProcessIdentity});
    if (outcome === 'new-process') owner.receive({browserProcessIdentity:currentProcessIdentity});
    if (outcome === 'disconnect') owner.disconnected();
    if (outcome !== 'timeout') owner.receive({visibilityRecoveryReceipt:{requestID:message.visibilityRecoveryRequest.requestID,accepted:outcome !== 'rejected'}});
    assert.equal(await promise,['accepted','different-active-intention'].includes(outcome),`native prior-session recovery ${outcome}`);
  }
  owner.receive({active:false,browserProcessIdentity:previousProcessIdentity});
  assert.ok(owner.identity());
  owner.receive({active:false});
  assert.equal(owner.identity(), null, 'Omitted optional proof in a full response revokes prior readiness');
  assert.equal(await owner.recoverPriorWindows(priorRequest), false, 'Revoked proof cannot authorize recovery');
  owner.receive({active:false,browserProcessIdentity:previousProcessIdentity});
  owner.receive({visibilityRecoveryReceipt:{requestID:'unknown',accepted:true}});
  assert.ok(owner.identity(), 'Partial receipt does not invent a loss of process proof');
  console.log('Native-window visibility transport: ownership, retries, reconnect, worker restart, and recovery identity passed.');
}
run().catch(error => {console.error(error);process.exitCode=1;});
