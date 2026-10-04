const assert = require('node:assert/strict');
const Visibility = require('../chrome-extension/tab-visibility.js');
const fs = require('node:fs');
const nativeIdentity={browserSessionID:'browser-one',processIdentity:{pid:123,launched:100}};
assert.equal(fs.readFileSync('chrome-extension/tab-visibility.js','utf8'), fs.readFileSync('firefox-extension/tab-visibility.js','utf8'));
function fixture() {
  let serial = 50;
  const data = {};
  const localData = {};
  const windows = [{id:1,type:'normal',state:'normal'}, {id:2,type:'normal',state:'minimized'}]
    .map(window=>({...window,left:20,top:40,width:900,height:700}));
  const tabs = [1,2,3,4].map((id,index) => ({id,windowId:1,index,active:id===1,url:'https://example.com/'+id,groupId:-1}));
  tabs.push({id:5,windowId:2,index:0,url:'https://hidden.example',active:true});
  const removed = [];
  const groupData = new Map([[9, {id:9, windowId:1, title:'Study',color:'blue',collapsed:true}]]);
  const api = {
    storage:{session:{get:async key=>structuredClone(data),set:async value=>Object.assign(data,structuredClone(value))},
      local:{get:async()=>structuredClone(localData),set:async value=>Object.assign(localData,structuredClone(value)),remove:async key=>{delete localData[key]}}},
    sessions:{
      setTabValue:async(id,key,value)=>{(tabs.find(t=>t.id===id).owned ||= {})[key]=structuredClone(value)},
      getTabValue:async(id,key)=>tabs.find(t=>t.id===id)?.owned?.[key],
      removeTabValue:async(id,key)=>{delete tabs.find(t=>t.id===id).owned[key]},
      setWindowValue:async(id,key,value)=>{(windows.find(w=>w.id===id).owned ||= {})[key]=structuredClone(value)},
      getWindowValue:async(id,key)=>windows.find(w=>w.id===id)?.owned?.[key],
      removeWindowValue:async(id,key)=>{delete windows.find(w=>w.id===id).owned[key]}
    },
    runtime:{getURL:path=>'extension://intent/'+path},
    windows:{
      getAll:async()=>structuredClone(windows),
      get:async id=>{const w=windows.find(x=>x.id===id);if(!w)throw Error();return structuredClone(w)},
      update:async(id,value)=>{const w=windows.find(x=>x.id===id);if(!w)throw Error();Object.assign(w,value);return w},
      create:async value=>{const id=serial++;const w={id,type:'normal',left:20,top:40,width:900,height:700,...value};windows.push(w);tabs.push({id:serial++,windowId:id,index:0,url:value.url,active:true,title:'Intent'});return w}
    },
    tabGroups:{get:async id=>{if(!groupData.has(id))throw Error('missing');return structuredClone(groupData.get(id))},
      update:async(id,value)=>Object.assign(groupData.get(id),value)},
    tabs:{
      group:async value=>{const id=value.groupId ?? serial++; const windowId=value.createProperties?.windowId ?? groupData.get(id).windowId;
        groupData.set(id,{id,windowId});for(const tab of tabs)if(value.tabIds.includes(tab.id))tab.groupId=id;return id},
      query:async q=>structuredClone(tabs.filter(t=>q.windowId==null||q.windowId===t.windowId).sort((a,b)=>a.windowId-b.windowId||a.index-b.index)),
      get:async id=>{const t=tabs.find(t=>t.id===id);if(!t)throw Error();return structuredClone(t)},
      update:async(id,value)=>{const t=tabs.find(t=>t.id===id);if(value.active)tabs.filter(x=>x.windowId===t.windowId).forEach(x=>x.active=false);Object.assign(t,value)},
      hide:async id=>{tabs.find(t=>t.id===id).hidden=true},
      show:async id=>{tabs.find(t=>t.id===id).hidden=false},
      move:async(ids,value)=>{
        assert(windows.some(w=>w.id===value.windowId));
        const moving=(Array.isArray(ids)?ids:[ids]).map(id=>tabs.find(t=>t.id===id));
        const remaining=tabs.filter(t=>t.windowId===value.windowId&&!moving.includes(t)).sort((a,b)=>a.index-b.index);
        const index=value.index<0?remaining.length:Math.min(value.index,remaining.length);
        assert(!(moving[0].pinned && remaining.slice(0,index).some(t=>!t.pinned)), 'Pinned tabs cannot be moved after normal tabs');
        for(const tab of moving){if(tab.windowId!==value.windowId)tab.groupId=-1;tab.windowId=value.windowId}
        remaining.splice(index,0,...moving);remaining.forEach((t,i)=>t.index=i);
        return moving;
      },
      remove:async id=>{removed.push(id);tabs.splice(tabs.findIndex(t=>t.id===id),1)}
    }
  };
  return {api,tabs,windows,removed,groupData,localData,
    clearSession:()=>{for(const key of Object.keys(data))delete data[key]}};
}
(async()=>{
  const active={active:true,hideDistractions:true,startupSessionID:'one',selectedTabIDs:[1]};
  {
    const f=fixture(), v=new Visibility(f.api,true);
    const open={...active,addAsYouGo:true};
    await v.syncInitial(open,t=>t.id===1,()=>true);
    assert.notEqual(f.tabs.find(t=>t.id===2).windowId,1,'Add as you go initially parks unselected existing tabs');
    f.tabs.push({id:88,windowId:1,index:1,url:'https://new.example',active:true});
    await new Visibility(f.api,true).syncInitial(open,t=>t.id===1,()=>true);
    assert.equal(f.tabs.find(t=>t.id===88).windowId,1,'A suspended worker cannot re-hide a new permitted tab');
    await v.sync({active:false},()=>true);
    assert.equal(f.tabs.find(t=>t.id===2).windowId,1,'Initial distractions return when Add as you go finishes');
    assert.equal(f.removed.includes(2),false,'User tabs are never deleted');
  }
  {
    const f=fixture(); delete f.api.storage.session;
    const v=new Visibility(f.api,true);
    await v.sync(active,t=>t.id===1);
    assert.notEqual(f.tabs[1].windowId,1,'Firefox parks tabs out of native and third-party sidebars');
    await new Visibility(f.api,true).sync({active:false},()=>true);
    assert.equal(f.tabs[1].windowId,1,'Firefox markers restore after a worker restart without session storage');
  }

  {
    const f=fixture(), v=new Visibility(f.api,true);
    const move=f.api.tabs.move;
    f.api.tabs.move=async(ids,value)=>{
      const id=Array.isArray(ids)?ids[0]:ids;
      const attaching=f.tabs.find(t=>t.id===id).windowId!==value.windowId;
      const result=await move(ids,value);
      if(attaching && value.windowId===1) await move(ids,{...value,index:0});
      return result;
    };
    await v.sync(active,t=>t.id===1);
    await v.sync({active:false},()=>true);
    assert.deepEqual((await f.api.tabs.query({windowId:1})).map(t=>t.id),[1,2,3,4], 'Normalize original order after sidebar attachment reorders');
  }
  for (const firefox of [true, false]) {
    const f=fixture(), v=new Visibility(f.api,firefox);
    const move=f.api.tabs.move;
    let delayed;
    f.api.tabs.move=async(ids,value)=>{
      const id=Array.isArray(ids)?ids[0]:ids;
      const attaching=f.tabs.find(t=>t.id===id).windowId!==value.windowId;
      const result=await move(ids,value);
      if(attaching && value.windowId===1 && id===4) {
        delayed=new Promise(resolve=>setTimeout(async()=>{
          await move(3,{windowId:1,index:0}); resolve();
        },75));
      }
      return result;
    };
    await v.sync(active,t=>t.id===1);
    f.tabs.push({id:80,windowId:1,index:1,url:'https://example.com/fresh'});
    await v.sync({active:false},()=>true);
    await delayed;
    assert.deepEqual((await f.api.tabs.query({windowId:1})).map(t=>t.id),[1,2,3,4,80],
      'Delayed sidebar reorder must settle before saved order is discarded; fresh tabs survive');
    assert.equal(v.state.orders.length,0);
  }
  for (const firefox of [true, false]) {
    const f=fixture(), v=new Visibility(f.api,firefox);
    f.windows.push({id:3,type:'normal',state:'normal',incognito:true});
    f.tabs.push({id:6,windowId:3,index:0,active:true,url:'https://private.example/allowed'},
      {id:7,windowId:3,index:1,active:false,url:'https://private.example/blocked'});
    await v.sync(active,t=>t.id===1||t.id===6);
    const privateParking=f.windows.find(w=>w.id===f.tabs.find(t=>t.id===7).windowId);
    assert(privateParking.incognito, 'Private tabs remain in a private holding window');
    assert.notEqual(privateParking.id,f.tabs.find(t=>t.id===2).windowId, 'Never mix normal and private tabs');
    await v.sync({active:false},()=>true);
    assert.equal(f.tabs.find(t=>t.id===7).windowId,3);
    assert(!f.removed.includes(7));
  }
  for(const firefox of [true,false]) {
    const f=fixture(), v=new Visibility(f.api,firefox);
    f.tabs[3].pinned=true;
    f.tabs[3].index=0;f.tabs[0].index=1;f.tabs[1].index=2;f.tabs[2].index=3;
    if(firefox) f.tabs[2].hidden=true; // Already hidden by another extension.
    else f.tabs[2].groupId=9; // Do not destroy a user's group to hide a tab.
    await v.sync(active,t=>t.id===1);
    assert.equal(f.tabs[0].windowId,1);
    assert.equal(f.windows[1].state,'minimized');
    assert.notEqual(f.tabs[3].windowId,1,'Pinned distractions must also be put aside');
    assert.notEqual(f.tabs[1].windowId,1);
    await new Visibility(f.api,firefox).sync({active:false},()=>true); // Suspended worker recovery.
    assert.equal(f.tabs[1].windowId,1);
    assert.equal(f.tabs[1].index,2);
    assert(!f.tabs[1].hidden);
    if(firefox) assert.equal(f.tabs[2].hidden,true);
    else {
      const group=f.groupData.get(f.tabs[2].groupId);
      assert.equal(group.title,'Study');assert.equal(group.color,'blue');assert.equal(group.collapsed,true);
    }
    assert.equal(f.tabs[3].pinned,true);assert.equal(f.tabs[3].windowId,1);
    assert.equal(f.windows[1].state,'minimized'); // Preserve preexisting minimization.
    assert(!f.removed.some(id=>id<=5));
  }
  for (const firefox of [true, false]) {const f=fixture(),v=new Visibility(f.api,firefox);
    await v.sync(active,()=>false); assert.equal(f.windows[0].state,'minimized');
    assert.equal(f.tabs.length,5); // Whole blocked windows are never emptied.
    await v.sync({active:false},()=>true); assert.equal(f.windows[0].state,'normal');
    assert.equal(f.windows[0].focused,false,'Restoring a browser window must not steal focus');}
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,t=>t.id===1); const parking=f.tabs[1].windowId;
    f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===parking).state,'normal');
    assert.equal(f.tabs.length,6);assert.equal(f.removed.length,0);}
  {const f=fixture(),v=new Visibility(f.api,true);
    await Promise.all([v.sync(active,t=>t.id===1),v.sync({active:false},()=>true)]);
    assert(!f.tabs.some(t=>t.hidden));assert.equal(f.tabs.filter(t=>t.windowId===1).length,4);}
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,t=>t.id===1);
    await v.sync({...active,hideDistractions:false},()=>true);
    assert.equal(f.tabs.filter(t=>t.windowId===1).length,4);}
  {const f=fixture(),v=new Visibility(f.api,true);
    f.api.storage.session.set=async()=>{throw Error('disk full')};
    await v.sync(active,t=>t.id===1); await v.sync(active,t=>t.id===1);
    assert(!f.tabs.some(t=>t.hidden));assert.equal(f.tabs.filter(t=>t.windowId===1).length,4);}
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,t=>t.id===1);
    // A browser restart clears session storage, but not the parked live tabs.
    f.api.storage.session.get=async()=>({});
    await new Visibility(f.api,false).sync({active:false},()=>true);
    assert(f.windows.filter(w=>w.id>=50).every(w=>w.state==='normal'));
    assert(!f.removed.some(id=>id<=5));}
  {const f=fixture(),v=new Visibility(f.api,true);
    f.tabs[3].hidden=true;
    await v.sync(active,t=>t.id===1);
    f.tabs[1].id=200; // Restored tabs have new IDs, but retain session values.
    f.api.storage.session.get=async()=>({});
    await new Visibility(f.api,true).sync({active:false},()=>true);
    assert.equal(f.tabs[1].windowId,1); assert(f.tabs[3].hidden);}
  {const f=fixture(),v=new Visibility(f.api,false);
    let queries=0;const query=f.api.tabs.query;
    f.api.tabs.query=async q=>{queries++;return query(q)};
    await v.sync({active:false},()=>true);
    const baseline=queries;
    for(let i=0;i<100;i++)await v.sync({active:false},()=>true);
    assert.equal(queries,baseline, 'Idle heartbeats must not rescan the browser');}
  {const f=fixture(),v=new Visibility(f.api,true);
    // Migration from older tabHide packages only restores owned hidden tabs.
    f.tabs[1].hidden=true; await f.api.sessions.setTabValue(2,'intentHiddenWorkspaceV1',true);
    f.tabs[2].hidden=true;
    await v.sync({active:false},()=>true);
    assert.equal(f.tabs[1].hidden,false); assert.equal(f.tabs[2].hidden,true);}
  {const f=fixture(),v=new Visibility(f.api,false);
    f.tabs[1].groupId=9; f.tabs[2].groupId=9;
    await v.sync(active,t=>t.id===1 || t.id===3);
    assert.notEqual(f.tabs[1].windowId,1);assert.equal(f.tabs[2].windowId,1);
    await v.sync({active:false},()=>true);
    assert.equal(f.tabs[1].groupId,f.tabs[2].groupId,'Partial groups restore together');}
  for (const firefox of [true, false]) {const f=fixture(),v=new Visibility(f.api,firefox);
    const move=f.api.tabs.move; let fail=true;
    f.api.tabs.move=async (ids,value)=>{if(fail)return;return move(ids,value)};
    await v.sync(active,t=>t.id===1);assert.equal(f.tabs[1].windowId,1);
    fail=false; await v.sync(active,t=>t.id===1);
    assert.notEqual(f.tabs[1].windowId,1,'A silently refused move must retry');
    fail=true;await v.sync({active:false},()=>true);
    assert(v.state.moved.length>0,'A silently refused restore retains ownership');
    fail=false;await v.sync({active:false},()=>true);
    assert.equal(f.tabs[1].windowId,1);assert.equal(v.state.moved.length,0);}
  for (const firefox of [true, false]) {const f=fixture(),v=new Visibility(f.api,firefox);
    f.tabs[1].splitViewId=7;f.tabs[2].splitViewId=7;
    const move=f.api.tabs.move;const batches=[];
    f.api.tabs.move=async(ids,value)=>{batches.push(ids);return move(ids,value)};
    await v.sync(active,t=>t.id===1); await v.sync({active:false},()=>true);
    assert.equal(batches.filter(ids=>Array.isArray(ids)&&ids.includes(2)&&ids.includes(3)).length,2);
    assert.equal(f.tabs[1].windowId,1); assert.equal(f.tabs[1].splitViewId,7);}
  {const f=fixture(),v=new Visibility(f.api,false);
    f.tabs[1].groupId=9; f.api.tabGroups.get=async()=>{throw Error('busy')};
    await v.sync(active,t=>t.id===1);
    assert.equal(f.tabs[1].windowId,1,'Do not destroy a group if recovery metadata is unavailable');}
  for (const firefox of [true, false]) {
    const f=fixture(), calls=[], plans=[], reveals=[];
    f.windows[1].state='normal';
    for (const window of f.windows) Object.assign(window,{left:20,top:40,width:900,height:700});
    for (const tab of f.tabs) tab.title='QA '+tab.id;
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{calls.push({id,...patch});return update(id,patch)};
    const owner={identity:()=>structuredClone(nativeIdentity),publishPlan:async(rules,windows,parking)=>{plans.push(structuredClone({rules,windows,parking}));return true},
      revealWindows:async(session,windows)=>{reveals.push({session,windows});return true}};
    const v=new Visibility(f.api,firefox,owner), native={...active,nativeWindowVisibility:true};
    await v.sync(native,t=>t.id===1);
    assert.deepEqual(plans.at(-1).windows.map(w=>w.windowID),[2],'Native owner receives fully blocked user windows');
    assert.deepEqual(plans.at(-1).windows[0],{windowID:2,title:'QA 5',frame:{left:20,top:40,width:900,height:700},state:'normal'});
    assert.equal(calls.some(x=>x.id===2),false,'Exclusive native ownership never uses browser window state changes');
    assert.equal(v.state.minimized.length,0,'Native windows are not also owned by the JS ledger');
    assert.equal(await f.api.sessions.getWindowValue(2,v.key),undefined,'Firefox has no competing legacy restoration marker');
    assert(plans.at(-1).parking.length>0,'Parking ownership is reported separately');
    await v.sync({active:false},()=>true);
    assert.equal(calls.some(x=>x.id===2),false,'Session completion leaves whole-window restoration to native ownership');
    assert.equal(reveals.length,0,'An empty holding page is closed without revealing a window');
  }
  {
    const f=fixture(), plans=[]; let available=false;
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async(_rules,windows)=>{plans.push(windows);if(!available)throw Error('Disconnected');return true}});
    const native={...active,nativeWindowVisibility:true};
    await v.sync(native,t=>t.id===1);
    assert.equal(v.state.nativeSessionID,'one','Native ownership mode persists before transport can fail');
    assert.equal(v.state.minimized.length,0,'Failed native transport must not fall back to JS minimization');
    available=true;
    await v.sync(native,t=>t.id===1);
    assert(plans.length>=2,'The next heartbeat republishes a failed native plan');
    assert.equal(plans.at(-1)[0].state,'minimized','Preexisting minimized state is preserved for native ownership decisions');
  }
  {
    const f=fixture(); let acceptParking=false; const receipts=[];
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async(_rules,_windows,parking)=>{
      receipts.push(parking.map(w=>w.windowID)); return !parking.length || acceptParking;
    }});
    const native={...active,nativeWindowVisibility:true};
    await v.sync(native,t=>t.id===1);
    assert(v.state.parking.length>0,'An empty holding window may be prepared before registration');
    assert.equal(f.tabs.find(t=>t.id===2).windowId,1,'No user tab enters parking before its native registration receipt');
    assert.equal(v.state.moved.length,0,'Rejected registration creates no fictitious moved ownership');
    acceptParking=true;
    await v.sync(native,t=>t.id===1);
    assert.notEqual(f.tabs.find(t=>t.id===2).windowId,1,'Accepted parking registration allows reversible tab movement');
    assert(receipts.filter(ids=>ids.length).length>=2);
  }
  {
    const f=fixture(), plans=[]; f.windows[1].state='normal';
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async(_rules,windows)=>{plans.push(windows.map(w=>w.windowID));return true}});
    const open={...active,nativeWindowVisibility:true,addAsYouGo:true};
    await v.syncInitial(open,t=>t.id===1,()=>true);
    assert.deepEqual(plans.at(-1),[2],'Add as you go publishes initial whole-window restrictions');
    await v.syncInitial(open,t=>t.id===1,()=>true);
    assert.deepEqual(plans.at(-1),[],'Later allowed windows are not repeatedly minimized by the initial restriction');
  }
  {
    const f=fixture(); let accepted=false;
    const owner={identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>accepted};
    let v=new Visibility(f.api,true,owner);
    const open={...active,nativeWindowVisibility:true,addAsYouGo:true};
    await v.syncInitial(open,t=>t.id===1,()=>true);
    assert.notEqual(v.state.initialSession,'one','Rejected receipt leaves initial visibility pending');
    f.tabs.push({id:88,windowId:1,index:8,url:'https://example.com/new',active:false});
    accepted=true;
    v=new Visibility(f.api,true,owner);
    await v.syncInitial(open,t=>t.id===1,()=>true);
    assert.equal(f.tabs.find(t=>t.id===88).windowId,1,'Retried initial setup preserves new Add-as-you-go tabs after worker suspension');
    assert.notEqual(f.tabs.find(t=>t.id===2).windowId,1,'The same retry still parks original distractions');
    assert.equal(v.state.initialSession,'one');
  }
  {
    const f=fixture(); f.windows[1].state='normal'; let plans=0, failRestore=true;
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>{plans++;return true}});
    await v.sync(active,t=>t.id===1);
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{if(id===2&&patch.state==='normal'&&failRestore)throw Error('Busy');return update(id,patch)};
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    assert.equal(plans,0,'Native ownership waits until existing legacy minimized ownership restores');
    assert(await f.api.sessions.getWindowValue(2,v.key),'Failed migration retains Firefox ownership');
    failRestore=false;
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    assert(plans>=1);
    assert.equal(await f.api.sessions.getWindowValue(2,v.key),undefined,'Successful legacy restoration clears its marker before native adoption');
  }
  for (const firefox of [true,false]) {
    const f=fixture(), changes=[], reveals=[]; let accepted=false;
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    const owner={identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true,revealWindows:async(session,windows)=>{reveals.push({session,windows});return accepted}};
    let v=new Visibility(f.api,firefox,owner);
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    const parking=f.tabs.find(t=>t.id===2).windowId;
    f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
    await v.sync({active:false},()=>true);
    assert.equal(changes.some(x=>x.id===parking&&x.state==='normal'),false,'Native parking reveal never silently falls back to browser deminimization');
    assert(v.state.nativeReveals.some(x=>x.windowID===parking),'Rejected reveal remains durable for retry');
    accepted=true;
    v=new Visibility(f.api,firefox,owner);
    await v.sync({active:false},()=>true);
    assert.equal(v.state.nativeReveals.length,0,'A resumed worker clears a reveal only after native acceptance');
    assert(reveals.every(x=>x.session==='one'),'Inactive reveal retains the owning intention session');
    assert(reveals.some(x=>x.windows.some(w=>w.windowID===parking)));
    assert.equal(changes.some(x=>x.id===parking&&x.state==='normal'),false);
  }
  {
    const f=fixture(), v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true,revealWindows:async()=>true});
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    await v.sync({active:false},()=>true);
    await v.sync({...active,startupSessionID:'legacy-next'},t=>t.id===1);
    assert.equal(v.state.nativeSessionID,null,'A distinct older-host session does not inherit native parking ownership');
    const parking=f.tabs.find(t=>t.id===2).windowId;
    f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===parking).state,'normal','Later legacy orphan parking retains its existing restoration route');
  }
  {
    const f=fixture(); f.windows[1].state='normal';
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true});
    await v.sync({...active,startupSessionID:null,nativeWindowVisibility:true},()=>false);
    assert(f.windows.every(w=>w.state==='normal'),'Malformed native session identity never falls back to JS window minimization');
  }
  for(const firefox of [true,false]) for(const planAccepted of [true,false]) {
    const f=fixture(), changes=[]; f.windows[1].state='normal';
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    const v=new Visibility(f.api,firefox,{identity:()=>null,publishPlan:async()=>planAccepted});
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    assert.equal(f.tabs.find(t=>t.id===2).windowId,1,'Native parking waits for verified host process identity before moving tabs');
    await v.sync({active:false},()=>true);
    assert.deepEqual(changes,[],'Missing native identity never allows browser whole-window minimize or finish restoration');
  }
  async function chromeParked({sourceClosed=false,restart=false}={}) {
    const f=fixture();
    const v=new Visibility(f.api,false,{identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true});
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    const originalParking=f.tabs.find(t=>t.id===2).windowId;
    const holder=f.tabs.find(t=>t.windowId===originalParking&&t.url.startsWith('extension://'));
    assert.match(holder.url,/#intent-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      'Native Chrome parking has a strict durable UUID marker');
    assert(f.localData[v.shadowKey]?.state.moved.length,'The full Chrome return ledger survives an extension update');
    if(sourceClosed) {
      f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
      for(let i=f.tabs.length-1;i>=0;i--)if(f.tabs[i].windowId===1)f.tabs.splice(i,1);
    }
    if(restart) {
      for(const window of f.windows)window.id+=1000;
      for(const tab of f.tabs){tab.id+=10000;tab.windowId+=1000;}
      // Recycled IDs are unrelated user content and must never be destinations.
      f.windows.push({id:1,type:'normal',state:'normal',left:20,top:40,width:900,height:700});
      f.tabs.push({id:2,windowId:1,index:0,active:true,url:'https://unrelated.example/reused-id'});
    }
    f.clearSession();
    return {...f,originalParking,parking:originalParking+(restart?1000:0)};
  }
  {
    const f=await chromeParked(), changes=[];
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    const v=new Visibility(f.api,false,{identity:()=>({browserSessionID:'extension-updated',processIdentity:{...nativeIdentity.processIdentity}}),
      revealWindows:async()=>false,recoverPriorWindows:async()=>true});
    await v.sync({active:false},()=>true);
    assert.deepEqual((await f.api.tabs.query({windowId:1})).map(t=>t.id),[1,2,3,4],
      'Chrome extension update restores original source and order from durable same-process ledger');
    assert.equal(changes.some(change=>change.state==='normal'),false,'Updating Chrome extension cannot bypass native window ownership');
    assert.equal(f.localData[v.shadowKey],undefined,'Completed Chrome recovery removes the durable ledger');
    assert(f.removed.every(id=>![1,2,3,4,5].includes(id)),'Only the empty Intent holder is removed');
  }
  {
    const f=await chromeParked({sourceClosed:true}), recovered=[], changes=[];
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    let verified=false;
    const owner={identity:()=>verified?{browserSessionID:'extension-updated',processIdentity:{...nativeIdentity.processIdentity}}:null,
      revealWindows:async()=>false,recoverPriorWindows:async proof=>{recovered.push(proof);return true}};
    const v=new Visibility(f.api,false,owner);
    await v.sync({active:false},()=>true);
    assert.deepEqual(changes,[],'Chrome waits safely for verified host identity after session storage is cleared');
    assert(f.localData[v.shadowKey],'Missing identity cannot erase durable ownership');
    verified=true;
    await v.sync({active:false},()=>true);
    assert.deepEqual(recovered[0].windowIDs,[f.originalParking],'Same-process Chrome orphan uses native recovery of original registered window');
    assert.equal(changes.some(change=>change.state==='normal'),false);
    assert.equal(v.state.nativeReveals.length,0);
    assert.deepEqual(f.tabs.filter(t=>[2,3,4].includes(t.id)).map(t=>t.windowId),[f.parking,f.parking,f.parking]);
  }
  {
    const f=await chromeParked({sourceClosed:true,restart:true}), proofs=[], changes=[], moves=[];
    const update=f.api.windows.update, move=f.api.tabs.move;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    f.api.tabs.move=async(ids,patch)=>{moves.push({ids,...patch});return move(ids,patch)};
    let accepted=false;
    const v=new Visibility(f.api,false,{identity:()=>({browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}}),
      revealWindows:async()=>false,authorizeRestartRecovery:async proof=>{proofs.push(proof);return accepted}});
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'minimized','Restart rejection retains the owned Chrome holder for retry');
    assert(f.localData[v.shadowKey],'Rejected restart keeps the durable nonce and native proof');
    accepted=true;
    await v.sync({active:false},()=>true);
    assert.deepEqual(changes,[{id:f.parking,state:'normal',focused:false}],'Only the nonce-owned Chrome holder receives authorized restart reveal');
    assert.deepEqual(moves,[],'A full Chrome restart never reuses stale numeric source/tab identities');
    assert.equal(v.state.nativeReveals.length,0);
    assert.equal(f.localData[v.shadowKey],undefined);
    assert(proofs.every(proof=>proof.previousBrowserSessionID==='browser-one'&&proof.previousProcessIdentity.pid===123));
    assert.equal(f.tabs.find(t=>t.id===2).url,'https://unrelated.example/reused-id');
    assert.equal(f.tabs.filter(t=>[10002,10003,10004].includes(t.id)).length,3,'All original user tabs survive full restart recovery');
  }
  {
    const f=await chromeParked({sourceClosed:true,restart:true}), changes=[];
    const holder=f.tabs.find(t=>t.windowId===f.parking&&t.url.startsWith('extension://'));
    holder.url='extension://intent/parked.html#intent-00000000-0000-4000-8000-000000000000';
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    const v=new Visibility(f.api,false,{identity:()=>({browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}}),
      revealWindows:async()=>true,authorizeRestartRecovery:async()=>true});
    await v.sync({active:false},()=>true);
    assert.deepEqual(changes,[],'A different holder nonce cannot authorize recovery, even if its numeric ID looks familiar');
    assert.equal(f.tabs.filter(t=>[10002,10003,10004].includes(t.id)).length,3);
    assert(f.localData[v.shadowKey],'Unresolved proof survives partial browser session restoration');
  }
  {
    const f=await chromeParked({sourceClosed:true,restart:true});
    const holder=f.tabs.find(t=>t.windowId===f.parking&&t.url.startsWith('extension://'));
    const url=holder.url; holder.url='about:blank';
    const v=new Visibility(f.api,false,{identity:()=>({browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}}),
      revealWindows:async()=>false,authorizeRestartRecovery:async()=>true});
    await v.sync({active:false},()=>true);
    assert(f.localData[v.shadowKey],'A holder that has not loaded yet retains durable recovery proof');
    holder.url=url;
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'normal','A later browser-restored holder is recovered on the next heartbeat');
    assert.equal(f.localData[v.shadowKey],undefined);
  }
  {
    const f=await chromeParked({sourceClosed:true,restart:true}); let entered,release;
    const started=new Promise(resolve=>{entered=resolve}),gate=new Promise(resolve=>{release=resolve});
    const v=new Visibility(f.api,false,{identity:()=>({browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}}),
      publishPlan:async()=>true,revealWindows:async()=>false,authorizeRestartRecovery:async()=>{entered();await gate;return true}});
    const restoring=v.sync({active:false},()=>true); await started;
    const newer=v.sync({...active,nativeWindowVisibility:true,startupSessionID:'newer'},()=>true);
    release();await restoring;await newer;
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'minimized','A new intention fences delayed Chrome restart reveal');
    assert(f.localData[v.shadowKey],'Interrupted Chrome recovery keeps its durable proof');
  }
  for(const unavailable of ['missing','write-failed']) {
    const f=fixture(), owner={identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true};
    if(unavailable==='missing')delete f.api.storage.local;
    else f.api.storage.local.set=async()=>{throw Error('Disk unavailable')};
    const v=new Visibility(f.api,false,owner);
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    assert.equal(f.tabs.find(t=>t.id===2).windowId,1,unavailable+' durable Chrome storage stops before user tabs enter parking');
  }
  async function restartedOrphan() {
    const f=fixture();
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true});
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    const parking=f.tabs.find(t=>t.id===2).windowId;
    const owned=await f.api.sessions.getTabValue(2,v.key);
    assert.equal(owned.nativeBrowserSessionID,nativeIdentity.browserSessionID);
    assert.deepEqual(owned.nativeBrowserProcessIdentity,nativeIdentity.processIdentity,'Firefox marker contains durable native process-generation proof');
    assert.equal(owned.nativeParkingWindowID,parking,'The original registered parking ID survives browser ID changes');
    f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
    for(let i=f.tabs.length-1;i>=0;i--)if(f.tabs[i].windowId===1)f.tabs.splice(i,1);
    // Firefox session values follow their real window/tab after a full restart,
    // whereas storage.session and numeric IDs belong to the old lifetime.
    for(const window of f.windows)window.id+=1000;
    for(const tab of f.tabs){tab.id+=10000;tab.windowId+=1000;}
    const fresh={};
    f.api.storage.session={get:async()=>structuredClone(fresh),set:async data=>Object.assign(fresh,structuredClone(data))};
    return {...f,parking:parking+1000};
  }
  {
    const f=await restartedOrphan(), authorizations=[]; let accepted=false;
    const identity={browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}};
    const owner={identity:()=>structuredClone(identity),publishPlan:async()=>true,revealWindows:async()=>false,
      authorizeRestartRecovery:async proof=>{authorizations.push(proof);return accepted}};
    const v=new Visibility(f.api,true,owner);
    await v.sync({active:false},()=>true);
    assert(v.state.nativeReveals.length>0,'Denied restart authorization retains a durable retry');
    assert(await f.api.sessions.getTabValue(10002,v.key),'Firefox marker survives until recovery accepts ownership');
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'minimized');
    accepted=true;
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'normal','Verified full restart reveals only the owned orphan holding window');
    assert.equal(v.state.nativeReveals.length,0,'Restart recovery does not leave permanent pending reveals');
    assert.equal(await f.api.sessions.getTabValue(10002,v.key),undefined,'Successful recovery clears stale ownership markers');
    assert(authorizations.every(proof=>JSON.stringify(proof)===JSON.stringify({intentionSessionID:'one',previousBrowserSessionID:'browser-one',previousProcessIdentity:nativeIdentity.processIdentity})));
    await v.sync({...active,startupSessionID:'after-restart',nativeWindowVisibility:true},()=>true);
    assert.equal(v.state.nativeSessionID,'after-restart','Recovered orphans do not block the next intention');
  }
  {
    const f=await restartedOrphan(); let calls=0;
    const v=new Visibility(f.api,true,{identity:()=>({browserSessionID:'extension-reloaded',processIdentity:{...nativeIdentity.processIdentity}}),
      revealWindows:async()=>false,authorizeRestartRecovery:async()=>{calls++;return true}});
    await v.sync({active:false},()=>true);
    assert.equal(calls,0,'A same-process worker/extension reload never takes the full-restart fallback');
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'minimized');
    assert(await f.api.sessions.getTabValue(10002,v.key),'Same-generation denial retains its ownership proof');
  }
  for(const browserSessionID of ['extension-reloaded','browser-one']) {
    const f=await restartedOrphan(), recovered=[], changes=[];
    const update=f.api.windows.update;
    f.api.windows.update=async(id,patch)=>{changes.push({id,...patch});return update(id,patch)};
    const v=new Visibility(f.api,true,{identity:()=>({browserSessionID,processIdentity:{...nativeIdentity.processIdentity}}),
      revealWindows:async()=>false,recoverPriorWindows:async proof=>{recovered.push(proof);return true},
      authorizeRestartRecovery:async()=>{throw Error('Same-process reload is never restart authorization')}});
    await v.sync({active:false},()=>true);
    assert.equal(v.state.nativeReveals.length,0,'Durable native prior-window recovery clears an extension-reload orphan');
    assert.deepEqual(recovered[0].windowIDs,[f.parking-1000],'Prior-window recovery uses the original registered browser window ID');
    assert.equal(changes.some(change=>change.state==='normal'),false,'Same-process recovery remains exclusively native');
    assert.equal(await f.api.sessions.getTabValue(10002,v.key),undefined);
  }
  {
    const f=fixture(), owner={identity:()=>structuredClone(nativeIdentity),publishPlan:async()=>true,revealWindows:async()=>true};
    const v=new Visibility(f.api,true,owner);
    await v.sync({...active,nativeWindowVisibility:true},t=>t.id===1);
    const move=f.api.tabs.move; let fail=true;
    f.api.tabs.move=async(ids,value)=>{if(value.windowId===1&&fail)throw Error('Source temporarily busy');return move(ids,value)};
    await v.sync({active:false},()=>true);
    assert(v.state.moved.length>0,'Revealing parking cannot discard return-to-source ownership while that source still exists');
    assert(await f.api.sessions.getTabValue(2,v.key));
    fail=false;
    await v.sync({active:false},()=>true);
    assert.equal(f.tabs.find(t=>t.id===2).windowId,1,'The next restore retries the original window');
  }
  for(const interrupt of ['new-intention','changed-process']) {
    const f=await restartedOrphan(); let release,entered;
    const started=new Promise(resolve=>{entered=resolve});
    const gate=new Promise(resolve=>{release=resolve});
    let identity={browserSessionID:'browser-two',processIdentity:{pid:456,launched:200}};
    const v=new Visibility(f.api,true,{identity:()=>structuredClone(identity),publishPlan:async()=>true,revealWindows:async()=>false,
      authorizeRestartRecovery:async()=>{entered();await gate;return true}});
    const restoring=v.sync({active:false},()=>true);
    await started;
    let next;
    if(interrupt==='new-intention')next=v.sync({...active,startupSessionID:'newer',nativeWindowVisibility:true},()=>true);
    else identity={browserSessionID:'browser-three',processIdentity:{pid:789,launched:300}};
    release(); await restoring; if(next)await next;
    assert.equal(f.windows.find(w=>w.id===f.parking).state,'minimized',interrupt+' fences a delayed restart authorization');
    assert(v.state.nativeReveals.length>0);
    assert(await f.api.sessions.getTabValue(10002,v.key),'Interrupted recovery must retain Firefox ownership');
  }
  console.log('Tab visibility: restore, suspended worker, mode reversal, owned state, last window, missing destination, serialization and exclusive native ownership passed');
})().catch(e=>{console.error(e);process.exit(1)});
