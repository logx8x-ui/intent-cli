const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const Finder = require('../chrome-extension/native-finder.js');
assert.equal(fs.readFileSync('chrome-extension/native-finder.js','utf8'), fs.readFileSync('firefox-extension/native-finder.js','utf8'));
function harness(options={}) {
  let session='profile-a', active=false, enabled=true, nextWindow=10, nextTab=20;
  const storage=options.storage||{}, calls=[], receipts=[];
  const windows=new Map([[4,{id:4,type:'normal',incognito:!!options.private,left:10,top:10,width:1200,height:800}]]);
  const tabs=new Map([[7,{id:7,windowId:4,index:0,active:true,highlighted:true,url:'https://original.test',cookieStoreId:options.container}],
    [8,{id:8,windowId:4,index:1,active:false,highlighted:true,url:'https://second.test'}]]);
  const api={webNavigation:{async getFrame({tabId}){await options.duringFrame?.();return {url:options.frameURL || tabs.get(tabId)?.url,parentFrameId:-1,errorOccurred:!!options.frameError}}},storage:{session:{async get(){if(options.readFails)throw Error();return structuredClone(storage)},async set(v){if(options.writeFails)throw Error();Object.assign(storage,structuredClone(v));await options.afterSave?.();}}},
    windows:{async get(id){if(!windows.has(id))throw Error('closed');return structuredClone(windows.get(id))},
      async create(props){calls.push(['create',structuredClone(props)]);await options.duringCreate?.();const id=nextWindow++,tabID=nextTab++;const tab={id:tabID,windowId:id,index:0,active:true,highlighted:true,url:'chrome://newtab/'};const win={...props,...(options.ignoredBounds?{width:1700,height:1100}:{}),id,tabs:[tab]};windows.set(id,win);tabs.set(tabID,tab);return structuredClone(win)},
      async remove(){throw Error('Never delete a window')},async update(id,props){assert.notEqual(id,4,'Never resize original window');calls.push(['resize',id,props]);Object.assign(windows.get(id),props);return structuredClone(windows.get(id))}},
    tabs:{async get(id){if(!tabs.has(id))throw Error('closed');return structuredClone(tabs.get(id))},
      async query(q){return [...tabs.values()].filter(t=>t.windowId===q.windowId).map(t=>structuredClone(t))},
      async move(id,props){calls.push(['move',id,props]);await options.duringMove?.();const t=tabs.get(id);t.windowId=props.windowId;t.index=2;return structuredClone(t)},
      async remove(id){calls.push(['remove',id]);tabs.delete(id)},
      async highlight(p){calls.push(['highlight',p]);const list=[...tabs.values()].filter(t=>t.windowId===p.windowId);for(const t of list){t.highlighted=p.tabs.includes(t.index);t.active=t.index===p.tabs[0]}}}};
  const finder=new Finder(api,{session:()=>session,active:()=>active,enabled:()=>enabled,firefox:!!options.firefox,send:m=>receipts.push(m.finder)});
  return {finder,api,storage,calls,receipts,tabs,windows,setActive:v=>active=v,setEnabled:v=>enabled=v,setSession:v=>session=v};
}
function command(action='open', extra={}) {return {id:crypto.randomUUID(),finderID:crypto.randomUUID(),action,browserSessionID:'profile-a',windowID:4,anchorTabID:7,frame:{left:200,top:100,width:720,height:520},expiresAtUnixMS:Date.now()+8000,...extra}}
const next=(open,action)=>command(action,{finderID:open.finderID,...(action==='commit'?{finderWindowID:10,finderTabID:20}:{})});
async function opened(options={}){const h=harness(options),open=command();await h.finder.handle(open);return {...h,open,owned:h.receipts.at(-1).tabID,ownedWindow:h.receipts.at(-1).windowID}}
(async()=>{
 for(const firefox of [true,false]) {
  const h=await opened({firefox});assert.equal(h.calls.length,1);const props=h.calls[0][1];assert.equal(props.type,'normal');assert.equal(props.url,undefined,'Native New Tab retains chosen search engine');assert.equal(props.focused,true);assert.equal(props.width,720);
  const before=structuredClone(h.windows.get(4));h.tabs.get(h.owned).url='https://visited.test/account';h.tabs.get(h.owned).title='Visited';
  const commit=next(h.open,'commit');await Promise.all([h.finder.handle(commit),h.finder.handle(commit)]);
  assert.equal(h.calls.filter(c=>c[0]==='move').length,1,'Duplicate commit moves exactly once');assert.equal(h.receipts.at(-1).tab.id,h.owned);assert.equal(h.tabs.get(h.owned).windowId,4);assert.equal(h.tabs.get(7).active,true);assert.deepEqual([...h.tabs.values()].filter(t=>t.windowId===4&&t.highlighted).map(t=>t.id),[7,8],'Native original multi-selection restored');assert.deepEqual(h.windows.get(4),before,'Original bounds/privacy untouched');
  await h.finder.handle(next(h.open,'cancel'));assert(h.tabs.has(h.owned),'Late cancel never closes the committed tab');
 }
 const duplicate=await opened();await duplicate.finder.handle(duplicate.open);assert.equal(duplicate.calls.filter(c=>c[0]==='create').length,1);assert.equal(duplicate.receipts.at(-1).tabID,duplicate.owned);
 const restart=harness({storage:duplicate.storage});await restart.finder.handle(duplicate.open);assert.equal(restart.calls.length,0,'Worker restart returns immutable receipt without recreating');
 for(const options of [{readFails:true},{writeFails:true},{firefox:true,container:'firefox-container-1'}]) {const h=harness(options);await h.finder.handle(command());assert.equal(h.calls.length,0)}
 for(const mode of ['active','disabled','moved','popup']) {const h=harness();if(mode==='active')h.setActive(true);if(mode==='disabled')h.setEnabled(false);if(mode==='moved')h.tabs.get(7).windowId=5;if(mode==='popup')h.windows.get(4).type='popup';await h.finder.handle(command());assert.equal(h.calls.length,0)}
 const privateFinder=await opened({private:true});assert.equal(privateFinder.calls[0][1].incognito,true,'Original privacy preserved');
 const cancel=await opened();cancel.tabs.set(90,{id:90,windowId:cancel.ownedWindow,index:1,url:'https://user-added.test'});await cancel.finder.handle(next(cancel.open,'cancel'));assert(!cancel.tabs.has(cancel.owned));assert(cancel.tabs.has(90),'Never close extra user tabs');
 const moved=await opened();moved.tabs.get(moved.owned).windowId=4;await moved.finder.handle(next(moved.open,'cancel'));assert(moved.tabs.has(moved.owned),'User-moved finder tab loses deletion ownership');
 const late=harness(),o=command();await late.finder.handle(next(o,'cancel'));await late.finder.handle(o);assert.equal(late.calls.length,0,'Cancel before open prevents a delayed window');
 let race;const r=command();race=harness({afterSave:async()=>race.setActive(true)});await race.finder.handle(r);assert.equal(race.calls.length,0,'Intention starting before create prevents effects');
 let cancelRace;const cr=command();cancelRace=harness({duringCreate:async()=>{void cancelRace.finder.handle(next(cr,'cancel'))}});await cancelRace.finder.handle(cr);await cancelRace.finder.queue;assert.equal(cancelRace.calls.filter(c=>c[0]==='create').length,1);assert.equal(cancelRace.calls.filter(c=>c[0]==='remove').length,1,'Racing cancellation cleans only owned new tab');
 const blank=await opened();await blank.finder.handle(next(blank.open,'commit'));assert.equal(blank.calls.filter(c=>c[0]==='move').length,0,'New Tab is never automatically chosen');blank.tabs.get(blank.owned).url='https://chosen.test';await blank.finder.handle(next(blank.open,'commit'));assert.equal(blank.calls.filter(c=>c[0]==='move').length,1,'Corrected explicit Add may succeed once');
 const changed=await opened();changed.tabs.get(changed.owned).url='https://chosen.test';changed.tabs.get(changed.owned).windowId=99;await changed.finder.handle(next(changed.open,'commit'));assert.equal(changed.calls.filter(c=>c[0]==='move').length,0);
 const foreign=await opened();await foreign.finder.handle(next(foreign.open,'commit'));const bad=next(foreign.open,'cancel');bad.windowID=99;await foreign.finder.handle(bad);assert(foreign.tabs.has(foreign.owned),'Changed original-window ownership cannot cancel');
 const originalClosed=await opened();originalClosed.tabs.get(originalClosed.owned).url='https://chosen.test';originalClosed.windows.delete(4);await originalClosed.finder.handle(next(originalClosed.open,'commit'));assert.equal(originalClosed.calls.filter(c=>c[0]==='move').length,0,'Closed destination never redirects to another window');
 const wrongOwned=await opened();wrongOwned.tabs.get(wrongOwned.owned).url='https://chosen.test';await wrongOwned.finder.handle({...next(wrongOwned.open,'commit'),finderTabID:21});assert.equal(wrongOwned.calls.filter(c=>c[0]==='move').length,0,'Receipt target must be the original owned tab');
 const sessionChanged=await opened();sessionChanged.tabs.get(sessionChanged.owned).url='https://chosen.test';sessionChanged.setSession('profile-b');await sessionChanged.finder.handle(next(sessionChanged.open,'commit'));assert.equal(sessionChanged.calls.filter(c=>c[0]==='move').length,0,'Profile session change never moves a tab');
 const immutable=await opened();await immutable.finder.handle({...immutable.open,frame:{...immutable.open.frame,width:730}});assert.equal(immutable.calls.filter(c=>c[0]==='create').length,1);assert.match(immutable.receipts.at(-1).error,/request changed/);
 let disconnectCommit, saved=0;const dcOptions={afterSave:async()=>{if(++saved===5)disconnectCommit.setEnabled(false)}};disconnectCommit=await opened(dcOptions);disconnectCommit.tabs.get(disconnectCommit.owned).url='https://chosen.test';await disconnectCommit.finder.handle(next(disconnectCommit.open,'commit'));assert.equal(disconnectCommit.calls.filter(c=>c[0]==='move').length,0,'Disconnect after the commit claim prevents the move');
 let moveCancellation;moveCancellation=await opened({duringMove:async()=>{void moveCancellation.finder.handle(next(moveCancellation.open,'cancel'))}});moveCancellation.tabs.get(moveCancellation.owned).url='https://chosen.test';await moveCancellation.finder.handle(next(moveCancellation.open,'commit'));await moveCancellation.finder.queue;assert.equal(moveCancellation.tabs.get(moveCancellation.owned).windowId,4);assert.equal(moveCancellation.calls.filter(c=>c[0]==='remove').length,0,'Cancellation during in-flight move never deletes the moved tab');assert.equal(moveCancellation.calls.filter(c=>c[0]==='highlight').length,0,'Cancellation during in-flight move prevents subsequent selection restoration');
 for (const transition of ['active','disabled']) {
  let pending;pending=await opened({duringMove:async()=>transition==='active'?pending.setActive(true):pending.setEnabled(false)});pending.tabs.get(pending.owned).url='https://chosen.test';await pending.finder.handle(next(pending.open,'commit'));
  assert.equal(pending.calls.filter(c=>c[0]==='move').length,1,'An already-issued move remains a single owned effect');
  assert.equal(pending.calls.filter(c=>c[0]==='highlight').length,0,'A '+transition+' transition during the move prevents later selection effects');
 }
 let userGroup;userGroup=await opened({duringMove:async()=>{userGroup.tabs.get(7).highlighted=true;userGroup.tabs.get(8).highlighted=false;userGroup.tabs.get(userGroup.owned).highlighted=false}});userGroup.tabs.get(userGroup.owned).url='https://chosen.test';await userGroup.finder.handle(next(userGroup.open,'commit'));assert.equal(userGroup.calls.filter(c=>c[0]==='highlight').length,0,'A changed native multi-selection is not overwritten');
 const uncertain=command();const store={intentNativeFinders:{['profile-a:'+uncertain.finderID]:{session:'profile-a',originalWindowID:4,anchorTabID:7,state:'opening',requests:{[uncertain.id]:{fingerprint:JSON.stringify(uncertain)}}}}};const u=harness({storage:store});await u.finder.handle(uncertain);assert.equal(u.calls.length,0);assert.match(u.receipts.at(-1).error,/may already/);
 for(const firefox of [true,false]) {
  const h=await opened({firefox});const tab=h.tabs.get(h.owned);tab.status='complete';tab.url='https://example.com/ready';
  const observe=()=>({...next(h.open,'observe'),finderWindowID:h.ownedWindow,finderTabID:h.owned});
  await h.finder.handle(observe());assert.equal(h.receipts.at(-1).readyURL,tab.url);
  const record=Object.values(h.storage.intentNativeFinders)[0];const requests=Object.keys(record.requests).length;
  for(let i=0;i<130;i++)await h.finder.handle(observe());
  assert.equal(Object.keys(Object.values(h.storage.intentNativeFinders)[0].requests).length,requests,'Read-only observations do not fill mutation journal');
  for(const url of ['about:blank','https://www.google.com/search?q=test','https://google.co.kr/search?q=test','https://www.bing.com/search?q=test','https://duckduckgo.com/?q=test','https://search.yahoo.com/search?p=test','https://search.brave.com/search?q=test','https://www.ecosia.org/search?q=test']) {
   tab.url=url;await h.finder.handle(observe());assert.equal(h.receipts.at(-1).readyURL,undefined,'Search stays open: '+url);
  }
  for(const url of ['https://docs.google.com/document/example','https://google.com.example.org/']) {
   tab.url=url;await h.finder.handle(observe());assert.equal(h.receipts.at(-1).readyURL,url,'Real website not confused with search host');
  }
  tab.url='https://example.com/ready';tab.pendingUrl='https://example.org/';await h.finder.handle(observe());assert.equal(h.receipts.at(-1).readyURL,undefined);delete tab.pendingUrl;
  tab.status='loading';await h.finder.handle(observe());assert.equal(h.receipts.at(-1).readyURL,undefined);tab.status='complete';
  await h.finder.handle({...next(h.open,'commit'),expectedURL:'https://example.com/old'});assert.equal(h.calls.filter(c=>c[0]==='move').length,0,'URL race cannot capture different page');
  await h.finder.handle({...next(h.open,'commit'),expectedURL:tab.url});assert.equal(h.calls.filter(c=>c[0]==='move').length,1);
 }
 const compact=await opened({ignoredBounds:true});assert.equal(compact.windows.get(compact.ownedWindow).width,720);assert.equal(compact.calls.filter(c=>c[0]==='resize').length,1);
 const frameMismatch=await opened({frameURL:'https://example.org/other'});frameMismatch.tabs.get(frameMismatch.owned).url='https://example.com/';frameMismatch.tabs.get(frameMismatch.owned).status='complete';await frameMismatch.finder.handle({...next(frameMismatch.open,'observe'),finderWindowID:frameMismatch.ownedWindow,finderTabID:frameMismatch.owned});assert.equal(frameMismatch.receipts.at(-1).readyURL,undefined,'Committed top frame must agree with tab URL');
 console.log('Native finder: real normal windows, exact profile ownership, privacy, group preservation, cancellation races and restart/idempotency checks passed');
})().catch(e=>{console.error(e);process.exitCode=1});
