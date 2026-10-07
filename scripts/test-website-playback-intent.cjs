const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const engine=require('../chrome-extension/website-features.js');
assert.equal(fs.readFileSync('chrome-extension/website-playback-intent.js','utf8'),fs.readFileSync('firefox-extension/website-playback-intent.js','utf8'));
function harness() {
  let current={active:true,startupSessionID:'playback',websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:['search','shorts']}},allowedWebsites:['youtube.com']}, time=0, onPause=()=>{};
  const tabs=new Map([[1,{id:1,url:'https://www.youtube.com/results?search_query=manual'}]]);
  const context={IntentWebsiteFeatures:engine};
  vm.runInNewContext(fs.readFileSync('chrome-extension/website-playback-intent.js','utf8'),context);
  const owner=new context.IntentWebsitePlayback({api:{tabs:{get:async id=>tabs.get(id)}},getRules:()=>current,
    isAllowedTab:tab=>tab.id!==99&&engine.siteOf(tab.url)==='youtube',now:()=>time,pause:async()=>{time+=50;onPause();}});
  const key=()=>engine.policyKey(current);
  return {owner,tabs,key,get rules(){return current;},replace(next){current=next;},advance(ms){time+=ms;},onPause(fn){onPause=fn;},
    sender(id,url,documentId='new'){return {frameId:0,tab:{...tabs.get(id)},url,documentId};},
    remember(targetURL,disposition='same-tab'){return owner.remember({url:tabs.get(1).url,targetURL,disposition,websitePolicyKey:key()},this.sender(1,tabs.get(1).url,'old'));},
    consume(id,url){return owner.consume({url,websitePolicyKey:key()},this.sender(id,url));}};
}
(async()=>{
  const target='https://www.youtube.com/watch?v=chosen';
  {
    const h=harness();assert.equal((await h.remember(target)).remembered,true);h.tabs.get(1).url=target;
    assert.equal((await h.consume(1,target)).allowed,true,'Manual same-tab full-document link survives guard replacement');
    assert.equal((await h.consume(1,target)).allowed,false,'Handoff is one-use');
  }
  {
    const h=harness();h.tabs.set(2,{id:2,openerTabId:1,url:target});h.owner.created(h.tabs.get(2));
    await h.remember(target,'new-tab');
    assert.equal((await h.consume(2,target)).allowed,false,'A preexisting sibling cannot spend a newer click');
    h.tabs.set(3,{id:3,openerTabId:1,url:target});h.owner.created(h.tabs.get(3));
    assert.equal((await h.consume(3,target)).allowed,true,'New tab consumes only its actual opener\'s exact target');
    h.tabs.set(4,{id:4,openerTabId:1,url:target});h.owner.created(h.tabs.get(4));
    assert.equal((await h.consume(4,target)).allowed,false,'No replay in a second new tab');
  }
  {
    const h=harness();h.tabs.get(1).url=target;
    h.onPause(()=>h.owner.committed({frameId:0,tabId:1,url:target,transitionType:'typed',documentId:'new'}));
    assert.equal((await h.consume(1,target)).allowed,true,'Document-start waits for a browser-proved address-bar commit');
  }
  for(const type of ['link','auto_bookmark','reload']) {
    const h=harness();h.tabs.get(1).url=target;h.owner.committed({frameId:0,tabId:1,url:target,transitionType:type,documentId:'new'});
    assert.equal((await h.consume(1,target)).allowed,true,'Manual '+type+' document plays');
  }
  for(const details of [{transitionType:'auto_toplevel'},{transitionType:'link',transitionQualifiers:['client_redirect']}]) {
    const h=harness();h.tabs.get(1).url=target;h.owner.committed({frameId:0,tabId:1,url:target,...details});
    assert.equal((await h.consume(1,target)).allowed,false,'Automatic navigation cannot mint a manual playback grant');
  }
  {
    const h=harness();await h.remember(target);h.advance(10001);h.tabs.get(1).url=target;
    assert.equal((await h.consume(1,target)).allowed,false,'Expired clicks do not authorize delayed autoplay');
  }
  {
    const h=harness();await h.remember(target);h.tabs.get(1).url=target;h.replace({...h.rules,startupSessionID:'replacement'});
    assert.equal((await h.consume(1,target)).allowed,false,'A replacement occurrence cannot use an old click');
  }
  {
    const h=harness();h.tabs.get(1).url=target;h.owner.committed({frameId:0,tabId:1,url:target,transitionType:'typed',documentId:'old'});
    assert.equal((await h.consume(1,target)).allowed,false,'Previous-document commit does not authorize the new document');
    h.owner.beforeNavigate({frameId:0,tabId:1});assert.equal(h.owner.commits.size,0);
  }
  {
    const h=harness();h.tabs.set(99,{id:99,url:target});h.owner.committed({frameId:0,tabId:99,url:target,transitionType:'link'});
    assert.equal((await h.consume(99,target)).allowed,false,'Playback intent does not expand outer tab access');
    h.replace({...h.rules,websiteFeaturePolicies:{youtube:{version:1,allowedFeatures:['search']}}});
    assert.equal((await h.remember('https://www.youtube.com/shorts/blocked')).remembered,false,'Shorts route restrictions win over a manual link');
  }
  console.log('Website playback intents: manual documents/new tabs, browser commit race, one-use scope, expiry, replacement and outer restrictions passed');
})().catch(e=>{console.error(e);process.exit(1);});
