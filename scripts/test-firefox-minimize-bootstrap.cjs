const assert = require('node:assert/strict');
const Bootstrap = require('../firefox-extension/window-minimize-bootstrap.js');
const Visibility = require('../firefox-extension/tab-visibility.js');
const clone = value=>value===undefined?undefined:JSON.parse(JSON.stringify(value));
const processIdentity = {pid:4242,launched:100};
const rules = {active:true,nativeWindowVisibility:true,hideDistractions:true,startupSessionID:'session'};
function offer(id='effect',windowID=2) { return {effectID:id,intentionSessionID:'session',browserSessionID:'profile',
  browserProcessIdentity:processIdentity,windowID,planRevision:1,expiresAtUnixMS:10000,
  descriptor:{windowID,title:'blocked',state:'normal',frame:{left:0,top:0,width:800,height:600}}}; }
function deferred() { let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve}; }
function fixture(options={}) {
  let data=clone(options.data||{}), identity={browserSessionID:'profile',processIdentity}, currentRules=rules;
  const calls=[], messages=[], window={id:2,type:'normal',focused:false,state:'normal',tabs:[{id:20,windowId:2,url:'https://blocked.invalid'}]};
  let executor;
  const receive=(extra={},nextRules=currentRules)=>{currentRules=nextRules;executor.receive({active:nextRules.active,
    browserProcessIdentity:identity?.processIdentity,hostCapabilities:['firefox-window-minimize-bootstrap-host-v1'],...extra},
    {rules:nextRules,fingerprint:JSON.stringify(nextRules)});};
  const api={runtime:{getURL:path=>'moz-extension://intent/'+path},storage:{local:{get:async key=>({[key]:clone(data[key])}),set:async value=>{
    calls.push(['save',clone(value)]);if(options.write)await options.write(value,{receive,data});Object.assign(data,clone(value));
  }}},windows:{update:async(id,change)=>{calls.push(['update',id,change]);if(options.update)await options.update(id,change,{receive});window.state='minimized';return clone(window);},get:async()=>clone(window)}};
  const send=message=>{messages.push(clone(message));const type=message.type;
    if(options.send?.(message,{receive,calls,messages})===false)return true;
    queueMicrotask(()=>receive(type==='windowMinimizeBootstrapClaim'
      ? {minimizeBootstrapClaimReceipt:{effectID:message.minimizeBootstrapClaim.effectID,granted:true}}
      : {minimizeBootstrapResultReceipt:{effectID:message.minimizeBootstrapResult.effectID,accepted:true}}));return true;};
  executor=new Bootstrap(api,{send,identity:()=>identity,now:()=>100,timeout:options.timeout??15,
    validate:async value=>options.validate ? options.validate(value,{window,receive}) : window.type==='normal'&&!window.focused&&['normal','maximized'].includes(window.state)&&!window.tabs.some(t=>t.allowed)});
  return {executor,api,receive,calls,messages,window,data:()=>data,setIdentity:value=>identity=value,
    async drain(){for(let n=0;n<8;n++){await executor.running;await Promise.all([...executor.inFlight.values()]);await executor.outboxTask;await Promise.resolve();if(!executor.running&&!executor.outboxTask&&!executor.inFlight.size)break;}},
    updates:()=>calls.filter(x=>x[0]==='update'),results:()=>messages.filter(x=>x.type==='windowMinimizeBootstrapResult').map(x=>x.minimizeBootstrapResult.outcome)};
}
const tests=[];function test(name,fn){tests.push([name,fn]);}
test('durable intent, one-shot effect, durable settled result before send',async()=>{
 const f=fixture();f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();
 assert.equal(f.updates().length,1);assert.deepEqual(f.updates()[0][2],{state:'minimized'});assert.deepEqual(f.results(),['settled']);
 const index=f.calls.findIndex(x=>x[0]==='update');assert.equal(Object.values(f.calls[index-1][1])[0].entries[0].phase,'dispatching');
 assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].phase,'acknowledged');
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,1);
});
test('pre-minimized and newly permitted windows cannot dispatch',async()=>{
 for(const kind of ['minimized','allowed']) {const f=fixture();if(kind==='minimized')f.window.state='minimized';else f.window.tabs[0].allowed=true;
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);assert.equal(f.messages.length,0);}
});
test('allowed tab added while grant waits cancels',async()=>{
 const f=fixture({send(message,{receive}){if(message.type==='windowMinimizeBootstrapClaim'){
 f.window.tabs.push({id:21,allowed:true});queueMicrotask(()=>receive({minimizeBootstrapClaimReceipt:{effectID:'effect',granted:true}}));return false;}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);assert.deepEqual(f.results(),['notDispatched']);
});
test('lost claim grant never dispatches',async()=>{
 const f=fixture({send:m=>m.type==='windowMinimizeBootstrapClaim'?false:undefined});f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();
 assert.equal(f.updates().length,0);assert.deepEqual(f.results(),['notDispatched']);
});
test('Finish or disconnect before dispatch cancels without browser restore',async()=>{
 for(const mode of ['finish','disconnect']){const f=fixture({write(value,{receive}){if(value.intentFirefoxMinimizeBootstrapV1.entries[0]?.phase==='dispatching'){
 if(mode==='finish')receive({}, {...rules,active:false});else f.executor.disconnected();}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);
 assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].outcome,'notDispatched');}
});
test('Finish during an effect retains a settled result, never restores',async()=>{
 const gate=deferred(), entered=deferred();const f=fixture({update(){entered.resolve();return gate.promise;}});
 f.receive({minimizeBootstrapOffers:[offer()]});await entered.promise;
 assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].phase,'dispatching');
 f.receive({}, {...rules,active:false});gate.resolve();await f.drain();assert.equal(f.updates().length,1);assert.deepEqual(f.results(),['settled']);
});
test('rejected dispatched API and context death are uncertain, never replayed',async()=>{
 const first=fixture({update(){throw new Error('ambiguous rejection');}});first.receive({minimizeBootstrapOffers:[offer()]});await first.drain();assert.deepEqual(first.results(),['uncertain']);
 for(const phase of ['dispatching','claiming']){const f=fixture({data:{intentFirefoxMinimizeBootstrapV1:{version:1,entries:[{offer:offer(),phase}]}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);assert.deepEqual(f.results(),[phase==='dispatching'?'uncertain':'notDispatched']);}
});
test('result is durable before send and ACK loss retries only the result',async()=>{
 let delivered=0;const f=fixture({send(message){if(message.type==='windowMinimizeBootstrapResult'){
 assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].outcome,'settled');if(++delivered===1)return false;}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].phase,'result');
 f.receive({});await f.drain();assert.equal(f.updates().length,1);assert.equal(delivered,2);assert.equal(f.data().intentFirefoxMinimizeBootstrapV1.entries[0].phase,'acknowledged');
});
test('pre-dispatch local write failure makes no effect',async()=>{
 for(const phase of ['claiming','dispatching']){const f=fixture({write(value){if(value.intentFirefoxMinimizeBootstrapV1.entries[0]?.phase===phase)throw new Error('disk failed');}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);}
});
test('historical result timeout does not delay new active dispatch',async()=>{
 const performed=deferred();const old={offer:offer('old'),phase:'result',outcome:'uncertain'};
 const f=fixture({data:{intentFirefoxMinimizeBootstrapV1:{version:1,entries:[old]}},timeout:500,
 send:m=>m.type==='windowMinimizeBootstrapResult'&&m.minimizeBootstrapResult.effectID==='old'?false:undefined,
 update(){performed.resolve();}});
 f.receive({minimizeBootstrapOffers:[offer()]});await performed.promise;
 assert.equal(f.executor.pendingResults.has('old'),true);assert.equal(f.updates().length,1);f.executor.disconnected();await f.drain();
});
test('offers arriving during awaited work receive a following pass',async()=>{
 const gate=deferred();let once=true;const f=fixture({validate:async()=>{if(once){once=false;await gate.promise;}return true;}});
 f.receive({minimizeBootstrapOffers:[offer('first')]});await Promise.resolve();
 f.receive({minimizeBootstrapOffers:[offer('second')]});gate.resolve();await f.drain();
 assert.equal(f.messages.some(x=>x.minimizeBootstrapClaim?.effectID==='second'),true);
});
test('duplicate or malformed durable effects never grant a new action',async()=>{
 for(const entries of [[{offer:offer(),phase:'result',outcome:'wrong'}],[{offer:offer(),phase:'claiming'},{offer:offer(),phase:'claiming'}]]){
 const f=fixture({data:{intentFirefoxMinimizeBootstrapV1:{version:1,entries}}});f.receive({minimizeBootstrapOffers:[offer('new')]});await f.drain();assert.equal(f.messages.length,0);assert.equal(f.updates().length,0);}
});
test('acknowledged capacity is compacted, pending capacity retained',async()=>{
 for(const phase of ['acknowledged','result']){const entries=Array.from({length:512},(_,i)=>({offer:offer('prior-'+i),phase,outcome:'uncertain'}));
 const f=fixture({data:{intentFirefoxMinimizeBootstrapV1:{version:1,entries}},send:m=>m.type==='windowMinimizeBootstrapResult'?false:undefined});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,phase==='acknowledged'?1:0);}
});
test('browser process mismatch cannot receive grant or replay old effect',async()=>{
 const f=fixture({send(message,{receive}){if(message.type==='windowMinimizeBootstrapClaim'){
 queueMicrotask(()=>receive({browserProcessIdentity:{pid:4243,launched:200},minimizeBootstrapClaimReceipt:{effectID:'effect',granted:true}}));return false;}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,0);
});
test('validator uses frozen initial policy, not permissive Add-as-you-go runtime',async()=>{
 const f=fixture(), v=new Visibility(f.api,true,{identity:()=>({browserSessionID:'profile',processIdentity})});
 const current={...rules,addAsYouGo:true};v.desiredRules=current;v.bootstrapPolicy={rules:current,windowIDs:new Set([2]),allowed:t=>t.id!==20};
 assert.equal(await v.validateBootstrap(offer()),true);f.window.tabs.push({id:21,windowId:2,url:'https://fresh.invalid'});
 assert.equal(await v.validateBootstrap(offer()),false);v.desiredRules={...current,active:false};assert.equal(await v.validateBootstrap(offer()),false);
});
test('unrelated window activity does not cancel an issued grant',async()=>{
 const f=fixture({send(message){if(message.type==='windowMinimizeBootstrapClaim'){
 f.executor.invalidateWindow(99); f.executor.invalidateWindow(1);}}});
 f.receive({minimizeBootstrapOffers:[offer()]});await f.drain();assert.equal(f.updates().length,1);assert.deepEqual(f.results(),['settled']);
});
test('a hung target does not delay a separate target',async()=>{
 const gate=deferred(),other=deferred();const f=fixture({validate:async()=>true,update:id=>id===2?gate.promise:other.resolve()});
 f.receive({minimizeBootstrapOffers:[offer('first',2),offer('second',3)]});await other.promise;
 assert.equal(f.updates().length,2);gate.resolve();await f.drain();
});
test('new settlement is delivered promptly after an older result transport',async()=>{
 const entered=deferred();let ackOld;const old={offer:offer('old'),phase:'result',outcome:'uncertain'};
 const f=fixture({data:{intentFirefoxMinimizeBootstrapV1:{version:1,entries:[old]}},timeout:500,
 send(message,{receive}){if(message.minimizeBootstrapResult?.effectID==='old'){
 ackOld=()=>receive({minimizeBootstrapResultReceipt:{effectID:'old',accepted:true}});return false;}},update(){entered.resolve();}});
 f.receive({minimizeBootstrapOffers:[offer()]});await entered.promise;await Promise.all([...f.executor.inFlight.values()]);
 assert.equal(f.results().includes('settled'),false);ackOld();await f.drain();assert.equal(f.results().includes('settled'),true);
});
test('semantically identical reconciliation does not invalidate an awaited window read',async()=>{
 const f=fixture(),v=new Visibility(f.api,true,{identity:()=>({browserSessionID:'profile',processIdentity})});
 v.desiredRules=rules;const policy={rules,allowed:()=>false,windowIDs:new Set([2]),key:'same-policy'};v.bootstrapPolicy=policy;
 const get=f.api.windows.get;f.api.windows.get=async(...args)=>{v.bootstrapPolicy={...policy,allowed:()=>false,windowIDs:new Set([2])};return get(...args);};
 assert.equal(await v.validateBootstrap(offer()),true);
});
(async()=>{let failed=0;for(const[name,fn]of tests){try{let timer;try{await Promise.race([fn(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('test did not settle')),1000);})]);}finally{clearTimeout(timer);}console.log('PASS Firefox bootstrap: '+name);}catch(e){failed++;console.error('FAIL Firefox bootstrap: '+name+' — '+e.stack);}}process.exitCode=failed?1:0;})();
