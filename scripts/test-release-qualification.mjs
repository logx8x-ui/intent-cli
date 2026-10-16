import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { REQUIRED_RELEASE_CHECKS, qualificationIdentity, validateQualification } from './lib/release-qualification.mjs';
const fixture = () => {
 const r={source_dirty:false,version:'1.0.0',build:'202610160001',source_commit:'ab'.repeat(20),source_fingerprint:'bc'.repeat(32),app_binary_sha256:'cd'.repeat(32),firefox_extension_version:'1.0.0',chrome_extension_version:'1.0.0',installers:Object.fromEntries(['firefox','chrome','both'].map(b=>[b,{sha256:'de'.repeat(32)}]))};
 r.qualification={schema:1,candidate:qualificationIdentity(r),completed_at:'2026-10-16T00:00:00Z',blockers:[],checks:Object.fromEntries(Object.entries(REQUIRED_RELEASE_CHECKS).map(([id,kind])=>[id,{kind,status:'passed',candidate:qualificationIdentity(r),observed_at:'2026-10-15T00:00:00Z',evidence:[{path:'synthetic.json',sha256:'ef'.repeat(32)}],environment:{macos:'13.7',architecture:'arm64',app_uuid:'01234567-0123-4567-8901-012345678901',browsers:{firefox:'144.0',chrome:'141.0'}},metrics:{bursts:3,seconds_per_burst:60,mission_control_cycles:20,soak_seconds:1800,input_tap_timeouts:0,recoveries:0,safety_stops:0,excluded_app_escapes:0,callback_count:5000,max_callback_microseconds:120}}]))};return r;
};
test('only complete evidence for the exact candidate qualifies',()=>{
 assert.equal(validateQualification(fixture()).ok,true);
 for(const id of Object.keys(REQUIRED_RELEASE_CHECKS)){
  const r=fixture();r.qualification.checks[id].status='pending';assert.equal(validateQualification(r).ok,false,id);
 }
 for(const key of ['source_fingerprint','app_binary_sha256','source_commit','build']){
  const r=fixture();r[key]='changed';assert.equal(validateQualification(r).ok,false,key);
 }
 const r=fixture();r.qualification.checks['physical.launch.rcmd-mission-control'].metrics.input_tap_timeouts=1;assert.equal(validateQualification(r).ok,false);
});
test('qualification rejects missing duration, stale individual check and malformed UUID',()=>{
 for(const field of ['seconds_per_burst','mission_control_cycles','soak_seconds']){
  for(const value of [undefined,NaN,'60']){
   const r=fixture();r.qualification.checks['physical.launch.rcmd-mission-control'].metrics[field]=value;
   assert.equal(validateQualification(r).ok,false,field);
  }
 }
 const stale=fixture();stale.qualification.checks['installed.launch.dbt'].candidate.app_binary_sha256='ab'.repeat(32);
 assert.equal(validateQualification(stale).ok,false);
 const missing=fixture();delete missing.qualification.checks['installed.launch.sbt'].candidate;
 assert.equal(validateQualification(missing).ok,false);
 const invalid=fixture();invalid.qualification.checks['installed.launch.dbt'].environment.app_uuid='-'.repeat(36);
 assert.equal(validateQualification(invalid).ok,false);
});
test('CLI checks hashed JSON records and strict distribution booleans before promotion',()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'intent-qualification-spec-'));
 const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
 try{
  const r=fixture();
  for(const browser of ['firefox','chrome','both']){
   const asset=`Intent-${browser}.pkg`,bytes=Buffer.from(`unit-fixture-${browser}`);
   fs.writeFileSync(path.join(root,asset),bytes);
   r.installers[browser]={asset,size_bytes:bytes.length,sha256:hash(bytes)};
  }
  r.qualification.candidate=qualificationIdentity(r);
  const records=path.join(root,'records');fs.mkdirSync(records);
  for(const [id,check] of Object.entries(r.qualification.checks)){
   check.candidate=qualificationIdentity(r);
   const record={check_id:id,kind:check.kind,status:check.status,observed_at:check.observed_at,
    candidate:check.candidate,environment:check.environment,metrics:check.metrics};
   const bytes=Buffer.from(JSON.stringify(record));fs.writeFileSync(path.join(records,`${id}.json`),bytes);
   check.evidence=[{path:`${id}.json`,sha256:hash(bytes)}];
  }
  const manifest=path.join(root,'manifest.json'),receipt=path.join(root,'qualification.json');
  const write=()=>{fs.writeFileSync(manifest,JSON.stringify(r));fs.writeFileSync(receipt,JSON.stringify(r.qualification));};
  const run=(mode='--verify')=>spawnSync(process.execPath,['scripts/qualify-release.mjs',mode,manifest,receipt,records,path.join(root,'qualified.json')],{encoding:'utf8'});
  write();assert.equal(run().status,0);
  const id='installed.launch.dbt',file=path.join(records,`${id}.json`),original=fs.readFileSync(file);
  const stale=JSON.parse(original);stale.candidate.app_binary_sha256='ab'.repeat(32);
  const altered=Buffer.from(JSON.stringify(stale));fs.writeFileSync(file,altered);
  r.qualification.checks[id].evidence[0].sha256=hash(altered);write();
  const failed=run();assert.notEqual(failed.status,0);assert.match(failed.stderr,/does not match check or candidate/);
  fs.writeFileSync(file,original);r.qualification.checks[id].evidence[0].sha256=hash(original);
  Object.assign(r,{notarized:'false',firefox_extension_signed:true,chrome_web_store_approved:true,
   chrome_web_store_version:r.chrome_extension_version,channel:'launch',website_adder_enabled:false,
   automatic_update_checks_enabled:false});write();
  const truthy=run('--qualify');assert.notEqual(truthy.status,0);assert.match(truthy.stderr,/Distribution or output gate incomplete/);
  assert.equal(fs.existsSync(path.join(root,'qualified.json')),false);
 }finally{fs.rmSync(root,{recursive:true,force:true});}
});
