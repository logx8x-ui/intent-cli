const assert = require('node:assert/strict');
const Visibility = require('../chrome-extension/tab-visibility.js');
const fs = require('node:fs');
assert.equal(fs.readFileSync('chrome-extension/tab-visibility.js','utf8'), fs.readFileSync('firefox-extension/tab-visibility.js','utf8'));
function fixture() {
  let serial = 50;
  const data = {};
  const windows = [{id:1,type:'normal',state:'normal'}, {id:2,type:'normal',state:'minimized'}];
  const tabs = [1,2,3,4].map((id,index) => ({id,windowId:1,index,active:id===1,url:'https://example.com/'+id,groupId:-1}));
  tabs.push({id:5,windowId:2,index:0,url:'https://hidden.example',active:true});
  const removed = [];
  const groupData = new Map([[9, {id:9, windowId:1, title:'Study',color:'blue',collapsed:true}]]);
  const api = {
    storage:{session:{get:async key=>structuredClone(data),set:async value=>Object.assign(data,structuredClone(value))}},
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
      create:async value=>{const id=serial++;const w={id,type:'normal',...value};windows.push(w);tabs.push({id:serial++,windowId:id,index:0,url:value.url});return w}
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
  return {api,tabs,windows,removed,groupData};
}
(async()=>{
  const active={active:true,hideDistractions:true,startupSessionID:'one',selectedTabIDs:[1]};
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
  console.log('Tab visibility: restore, suspended worker, mode reversal, owned state, last window, missing destination and serialization passed');
})().catch(e=>{console.error(e);process.exit(1)});
