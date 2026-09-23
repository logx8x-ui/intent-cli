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
  const api = {
    storage:{session:{get:async key=>structuredClone(data),set:async value=>Object.assign(data,structuredClone(value))}},
    sessions:{
      setTabValue:async(id,key,value)=>{tabs.find(t=>t.id===id).owned=value},
      getTabValue:async id=>tabs.find(t=>t.id===id)?.owned,
      removeTabValue:async id=>{delete tabs.find(t=>t.id===id).owned},
      setWindowValue:async(id,key,value)=>{windows.find(w=>w.id===id).owned=value},
      getWindowValue:async id=>windows.find(w=>w.id===id)?.owned,
      removeWindowValue:async id=>{delete windows.find(w=>w.id===id).owned}
    },
    runtime:{getURL:path=>'extension://intent/'+path},
    windows:{
      getAll:async()=>structuredClone(windows),
      get:async id=>{const w=windows.find(x=>x.id===id);if(!w)throw Error();return structuredClone(w)},
      update:async(id,value)=>{const w=windows.find(x=>x.id===id);if(!w)throw Error();Object.assign(w,value);return w},
      create:async value=>{const id=serial++;const w={id,type:'normal',...value};windows.push(w);tabs.push({id:serial++,windowId:id,index:0,url:value.url});return w}
    },
    tabs:{
      query:async q=>structuredClone(tabs.filter(t=>q.windowId==null||q.windowId===t.windowId)),
      get:async id=>{const t=tabs.find(t=>t.id===id);if(!t)throw Error();return structuredClone(t)},
      update:async(id,value)=>{const t=tabs.find(t=>t.id===id);if(value.active)tabs.filter(x=>x.windowId===t.windowId).forEach(x=>x.active=false);Object.assign(t,value)},
      hide:async id=>{tabs.find(t=>t.id===id).hidden=true},
      show:async id=>{tabs.find(t=>t.id===id).hidden=false},
      move:async(id,value)=>{assert(windows.some(w=>w.id===value.windowId));Object.assign(tabs.find(t=>t.id===id),value)},
      remove:async id=>{removed.push(id);tabs.splice(tabs.findIndex(t=>t.id===id),1)}
    }
  };
  return {api,tabs,windows,removed};
}
(async()=>{
  const active={active:true,hideDistractions:true,startupSessionID:'one',selectedTabIDs:[1]};
  for(const firefox of [true,false]) {
    const f=fixture(), v=new Visibility(f.api,firefox);
    f.tabs[3].pinned=true;
    if(firefox) f.tabs[2].hidden=true; // Already hidden by another extension.
    else f.tabs[2].groupId=9; // Do not destroy a user's group to hide a tab.
    await v.sync(active,t=>t.id===1);
    assert.equal(f.tabs[0].windowId,1);
    assert.equal(f.windows[1].state,'minimized');
    assert.equal(f.tabs[3].windowId,1);
    if(firefox) assert.equal(f.tabs[1].hidden,true);
    else assert.notEqual(f.tabs[1].windowId,1);
    await new Visibility(f.api,firefox).sync({active:false},()=>true); // Suspended worker recovery.
    assert.equal(f.tabs[1].windowId,1);
    assert.equal(f.tabs[1].index,1);
    assert(!f.tabs[1].hidden);
    if(firefox) assert.equal(f.tabs[2].hidden,true);
    assert.equal(f.windows[1].state,'minimized'); // Preserve preexisting minimization.
    assert(!f.removed.some(id=>id<=5));
  }
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,()=>false); assert.equal(f.windows[0].state,'minimized');
    assert.equal(f.tabs.length,5); // Whole blocked windows are never emptied.
    await v.sync({active:false},()=>true); assert.equal(f.windows[0].state,'normal');}
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,t=>t.id===1); const parking=f.tabs[1].windowId;
    f.windows.splice(f.windows.findIndex(w=>w.id===1),1);
    await v.sync({active:false},()=>true);
    assert.equal(f.windows.find(w=>w.id===parking).state,'normal');
    assert.equal(f.tabs.length,6);assert.equal(f.removed.length,0);}
  {const f=fixture(),v=new Visibility(f.api,true);
    await Promise.all([v.sync(active,t=>t.id===1),v.sync({active:false},()=>true)]);
    assert(!f.tabs.some(t=>t.hidden));}
  {const f=fixture(),v=new Visibility(f.api,false);
    await v.sync(active,t=>t.id===1);
    await v.sync({...active,hideDistractions:false},()=>true);
    assert.equal(f.tabs.filter(t=>t.windowId===1).length,4);}
  {const f=fixture(),v=new Visibility(f.api,true);
    f.api.storage.session.set=async()=>{throw Error('disk full')};
    await v.sync(active,t=>t.id===1); await v.sync(active,t=>t.id===1);
    assert(!f.tabs.some(t=>t.hidden));}
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
    assert(!f.tabs[1].hidden); assert(f.tabs[3].hidden);}
  {const f=fixture(),v=new Visibility(f.api,false);
    let queries=0;const query=f.api.tabs.query;
    f.api.tabs.query=async q=>{queries++;return query(q)};
    await v.sync({active:false},()=>true);
    const baseline=queries;
    for(let i=0;i<100;i++)await v.sync({active:false},()=>true);
    assert.equal(queries,baseline, 'Idle heartbeats must not rescan the browser');}
  console.log('Tab visibility: restore, suspended worker, mode reversal, owned state, last window, missing destination and serialization passed');
})().catch(e=>{console.error(e);process.exit(1)});
