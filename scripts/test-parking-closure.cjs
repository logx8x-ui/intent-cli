#!/usr/bin/env node
const assert=require('node:assert/strict');
const path=require('node:path');
const Owner=require(process.env.INTENT_CLOSURE_BASELINE?path.resolve('audit-baseline/native-window-visibility.js'):path.resolve('chrome-extension/native-window-visibility.js'));
const clone=value=>structuredClone(value),tick=()=>new Promise(resolve=>setImmediate(resolve));
const processIdentity={pid:123,launched:800000000};
const window=id=>({windowID:id,title:'Intent holder',frame:{left:0,top:20,width:900,height:700},state:'normal'});
const rules={active:true,nativeWindowVisibility:true,startupSessionID:'session-a'};
const proof=(id,session='session-a')=>({intentionSessionID:session,previousBrowserSessionID:'browser-a',previousProcessIdentity:{...processIdentity},windowIDs:[id],closed:false});
function fixture(){
 const session={},local={},messages=[],live=[{id:9}],options={dropPlan:false,closed:true},timing={now:100};let owner;
 const api={storage:{session:{get:async()=>clone(session),set:async value=>Object.assign(session,clone(value))},local:{get:async()=>clone(local),set:async value=>Object.assign(local,clone(value))}},windows:{getAll:async()=>clone(live)}};
 function make(browserSessionID='browser-a',identity=processIdentity){
  owner=new Owner(api,message=>{
   messages.push(clone(message));
   if(message.type==='windowVisibilityPlan'&&!options.dropPlan)queueMicrotask(()=>owner.receive({visibilityPlanReceipt:{revision:message.visibilityPlan.revision,accepted:true}}));
   if(message.type==='windowVisibilityClosed'&&options.closed!==null)queueMicrotask(()=>owner.receive({visibilityClosedReceipt:{requestID:message.visibilityClosedRequest.requestID,accepted:typeof options.closed==='function'?options.closed(message.visibilityClosedRequest):options.closed}}));
   return true;
  },()=>browserSessionID,{timeout:30,now:()=>timing.now});
  owner.receive({active:false,browserProcessIdentity:identity});return owner;
 }
 return {api,session,local,messages,live,options,timing,make,ledger:()=>local.intentNativeParkingClosureV1?.entries||[],closedMessages:()=>messages.filter(m=>m.type==='windowVisibilityClosed')};
}
async function run(){
 const failures=[];
 async function check(name,fn){try{await fn();console.log('PASS parking closure: '+name)}catch(e){failures.push({name,message:e.message});console.error('FAIL parking closure: '+name+' — '+e.message)}}
 await check('registration proof is durable before its transport ACK can be lost',async()=>{
  const f=fixture(),owner=f.make();f.options.dropPlan=true;
  const pending=owner.publishPlan(rules,[],[window(9)]);await tick();
  assert.deepEqual(f.ledger(),[proof(9)]);assert.equal(f.messages[0].type,'windowVisibilityPlan');assert.equal(await pending,false);
  f.live.length=0;for(const key of Object.keys(f.session))delete f.session[key];
  const next=f.make('browser-after-update');await next.retireClosedWindows({force:true});
  assert.equal(f.closedMessages().length,1);assert.equal(f.closedMessages()[0].visibilityClosedRequest.previousBrowserSessionID,'browser-a');assert.equal(f.ledger()[0].closed,true);
 });
 await check('successful browser absence retires despite an independently live native backing',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);
  await owner.retireClosedWindows({force:true});assert.equal(f.closedMessages().length,0);
  f.live.length=0;await owner.retireClosedWindows({force:true});assert.equal(f.closedMessages().length,1);assert(f.ledger()[0].closed);
  await owner.retireClosedWindows({force:true});assert.equal(f.closedMessages().length,1,'Completed closure is not continuously resubmitted');
 });
 for(const bad of ['throw','missing-id','negative-id','duplicate-id'])await check('inventory '+bad+' is not absence',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);
  f.api.windows.getAll=async()=>{if(bad==='throw')throw Error('busy');return bad==='missing-id'?[{}]:bad==='negative-id'?[{id:-1}]:[{id:1},{id:1}]};
  await owner.retireClosedWindows({force:true});assert.equal(f.closedMessages().length,0);assert.equal(f.ledger()[0].closed,false);
 });
 for(const outcome of ['reject','timeout','disconnect','wrong-receipt','process-change'])await check('closure '+outcome+' retains retry proof',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);f.live.length=0;f.options.closed=null;
  const pending=owner.retireClosedWindows({force:true});await tick();const msg=f.closedMessages().at(-1);assert(msg);
  if(outcome==='reject')owner.receive({visibilityClosedReceipt:{requestID:msg.visibilityClosedRequest.requestID,accepted:false}});
  if(outcome==='disconnect')owner.disconnected();
  if(outcome==='wrong-receipt')owner.receive({visibilityRecoveryReceipt:{requestID:msg.visibilityClosedRequest.requestID,accepted:true}});
  if(outcome==='process-change'){owner.receive({browserProcessIdentity:{pid:999,launched:800000001}});owner.receive({visibilityClosedReceipt:{requestID:msg.visibilityClosedRequest.requestID,accepted:true}})}
  await pending;assert.equal(f.ledger()[0].closed,false);
  f.options.closed=true;const retry=f.make('browser-after-reload');await retry.retireClosedWindows({force:true});assert.equal(f.ledger()[0].closed,true);
 });
 await check('different verified process drops only local proof and never sends old IDs',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);f.live.length=0;
  const next=f.make('new-browser',{pid:456,launched:800000100});await next.retireClosedWindows({force:true});assert.equal(f.closedMessages().length,0);assert.equal(f.ledger().length,0);
 });
 await check('prior accepted plan backfill requires original matching profile/process proof',async()=>{
  const f=fixture();f.session.intentNativeWindowVisibilityV1={browserSessionID:'browser-old',revision:2,plans:{'session-a':{intentionSessionID:'session-a',windows:[],parkingWindows:[window(9)],revealWindowIDs:[]}}};
  const owner=f.make('browser-new');
  assert.equal(await owner.rememberParkingOwnership('session-a',{browserSessionID:'foreign',processIdentity}),false);
  assert.equal(await owner.rememberParkingOwnership('session-a',{browserSessionID:'browser-old',processIdentity:{pid:999,launched:800000000}}),false);
  assert.equal(f.ledger().length,0);
  assert.equal(await owner.rememberParkingOwnership('session-a',{browserSessionID:'browser-old',processIdentity}),true);
  f.live.length=0;await owner.retireClosedWindows({force:true});assert.equal(f.closedMessages()[0].visibilityClosedRequest.previousBrowserSessionID,'browser-old');
 });
 await check('registration rechecks identity after local persistence and before sending',async()=>{
  const f=fixture(),owner=f.make(),set=f.api.storage.local.set;
  f.api.storage.local.set=async value=>{await set(value);owner.receive({browserProcessIdentity:{pid:999,launched:800000100}})};
  assert.equal(await owner.publishPlan(rules,[],[window(9)]),false);assert.equal(f.messages.length,0);
 });
 await check('historical closure timeout cannot delay a new active registration',async()=>{
  const f=fixture();f.local.intentNativeParkingClosureV1={version:1,entries:Array.from({length:1024},(_,i)=>proof(i+100))};f.live.length=0;f.options.closed=null;
  const owner=f.make();const closure=owner.retireClosedWindows({force:true});await tick();assert.equal(f.closedMessages().length,1);assert.equal(f.closedMessages()[0].visibilityClosedRequest.windowIDs.length,256);
  let done=false;const publish=owner.publishPlan({...rules,startupSessionID:'session-new'},[window(1)],[]).then(value=>{done=value});
  for(let i=0;i<4;i++)await tick();assert(done,'New registration must finish while historical closure still awaits receipt');
  assert.equal(owner.closedPending.size,1);owner.disconnected();await closure;await publish;
 });
 await check('rejected interleaved groups and large chunks do not starve later proof',async()=>{
  const f=fixture();f.local.intentNativeParkingClosureV1={version:1,entries:[proof(10,'A'),proof(20,'B'),proof(11,'A')]};f.live.length=0;f.options.closed=false;const owner=f.make();
  await owner.retireClosedWindows({force:true});await owner.retireClosedWindows({force:true});
  assert.deepEqual(f.closedMessages().map(m=>m.visibilityClosedRequest.intentionSessionID),['A','B']);
  const g=fixture();g.local.intentNativeParkingClosureV1={version:1,entries:Array.from({length:520},(_,i)=>proof(i+100))};g.live.length=0;g.options.closed=true;const other=g.make();
  for(let i=0;i<3;i++)await other.retireClosedWindows({force:true});
  assert.equal(new Set(g.closedMessages().flatMap(m=>m.visibilityClosedRequest.windowIDs)).size,520);
 });
 await check('an uncaptured candidate cannot poison a captured closure in the same tuple',async()=>{
  const f=fixture();f.local.intentNativeParkingClosureV1={version:1,entries:[proof(10),proof(20)]};f.live.length=0;
  f.options.closed=request=>request.windowIDs.every(id=>id===20);const owner=f.make();
  for(let i=0;i<3;i++)await owner.retireClosedWindows({force:true});
  assert.equal(f.ledger().find(p=>p.windowIDs[0]===10).closed,false);assert.equal(f.ledger().find(p=>p.windowIDs[0]===20).closed,true);
  assert.deepEqual(f.closedMessages().map(m=>m.visibilityClosedRequest.windowIDs),[[10,20],[10],[20]]);
 });
 await check('concurrent registration cannot lose proof when a closure ACK persists',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);f.live.length=0;f.options.closed=null;
  const close=owner.retireClosedWindows({force:true});await tick();const request=f.closedMessages()[0].visibilityClosedRequest;
  assert.equal(await owner.publishPlan({...rules,startupSessionID:'session-new'},[],[window(10)]),true);
  owner.receive({visibilityClosedReceipt:{requestID:request.requestID,accepted:true}});await close;
  assert(f.ledger().find(p=>p.windowIDs[0]===9).closed);assert.equal(f.ledger().find(p=>p.windowIDs[0]===10).closed,false);
 });
 await check('pending proof cap fails closed without discarding existing metadata',async()=>{
  const f=fixture();f.local.intentNativeParkingClosureV1={version:1,entries:Array.from({length:1024},(_,i)=>proof(i+100))};const owner=f.make();
  assert.equal(await owner.publishPlan({...rules,startupSessionID:'session-new'},[],[window(9)]),false);
  assert.equal(f.ledger().length,1024);assert.equal(f.messages.length,0);
 });
 await check('local proof failure prevents registration transport',async()=>{
  const f=fixture(),owner=f.make();f.api.storage.local.set=async()=>{throw Error('disk busy')};
  assert.equal(await owner.publishPlan(rules,[],[window(9)]),false);assert.equal(f.messages.length,0);assert.equal(f.ledger().length,0);
 });
 await check('post-ACK local failure reloads unclosed proof for idempotent retry',async()=>{
  const f=fixture(),owner=f.make();await owner.publishPlan(rules,[],[window(9)]);f.live.length=0;
  const set=f.api.storage.local.set;f.api.storage.local.set=async value=>{if(value.intentNativeParkingClosureV1?.entries.some(p=>p.closed))throw Error('disk busy');await set(value)};
  assert.equal(await owner.retireClosedWindows({force:true}),false);assert.equal(f.ledger()[0].closed,false);
  f.api.storage.local.set=set;const next=f.make();await next.retireClosedWindows({force:true});
  assert.equal(f.closedMessages().length,2);assert.equal(f.ledger()[0].closed,true);
 });
 assert.deepEqual(failures,[],'Parking closure protocol regressions');
}
run().catch(error=>{console.error(error);process.exitCode=1});
