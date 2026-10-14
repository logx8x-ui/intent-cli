#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync, spawnSync} = require('node:child_process');
const {SUITES, LIVE_CASES, planChanges, changedPaths, sourceFingerprint, executePlan} = require('./change-impact.cjs');

for (const file of [
  'Sources/IntentApp/QuickSelectionView.swift', 'Sources/IntentLock/WorkspaceWindow.swift',
  'Sources/IntentLock/FocusVisibilityController.swift', 'Sources/IntentLock/NativeVisibilityCoveragePolicy.swift',
  'Sources/IntentCoreSpec/NativeVisibilityCoverageSpecs.swift',
  'Sources/IntentCore/TaskWorkspace.swift', 'Sources/IntentCore/TaskWorkspaceStore.swift',
  'Sources/IntentApp/TaskWorkspaceView.swift', 'Sources/IntentApp/TaskWorkspaceInput.swift',
  'Sources/IntentCore/OverviewPageSwipe.swift', 'Sources/IntentApp/OverviewPageHostingView.swift',
  'Sources/IntentCore/IntentBuildPolicy.swift', 'Sources/IntentCore/UnknownNewOwner.swift',
  'Sources/IntentNativeHost/main.swift',
]) {
  const plan = planChanges([file]);
  for (const suite of ['session', 'extensions', 'host', 'swift', 'release']) assert.ok(plan.suites.includes(suite), `${file}: ${suite}`);
  assert.deepEqual(plan.liveAcceptance.map(item => item.id), LIVE_CASES);
}
for (const file of ['firefox-extension/background.js', 'chrome-extension/content.js']) {
  const plan = planChanges([file]);
  for (const suite of ['session', 'extensions', 'host', 'release', 'lint']) assert.ok(plan.suites.includes(suite));
}
assert.deepEqual(planChanges(['docs/qa/new-note.md']).suites, ['gate']);
assert.deepEqual(planChanges(['services/intent-ai/src/index.ts']).suites, ['gate', 'ai']);
assert.deepEqual(planChanges(['new-runtime.conf']).suites, Object.keys(SUITES));
assert.deepEqual(planChanges(['scripts/change-impact.cjs']).suites, Object.keys(SUITES));
assert.equal(planChanges(['Sources/IntentApp/A.swift', 'Sources/IntentApp/A.swift']).files.length, 1);
assert.deepEqual(planChanges(['Sources/IntentApp/B.swift', 'Sources/IntentApp/A.swift']).files,
  ['Sources/IntentApp/A.swift', 'Sources/IntentApp/B.swift']);

const plan = planChanges(['firefox-extension/background.js']);
let calls = [];
const passed = executePlan(plan, {fingerprint: () => 'same', run: id => { calls.push(id); return 0; }});
assert.equal(passed.status, 'automated-pass');
assert.equal(passed.releaseReady, false, 'Passing every automated suite cannot qualify a tester download');
assert.deepEqual(calls, plan.suites, 'Suites run once and serially in the declared order');
assert.ok(passed.liveAcceptance.every(item => item.status === 'pending'), 'Automation must never promote a live or physical case to passed');
const reused = {...plan, liveAcceptance: plan.liveAcceptance.map(item => ({...item, status: 'passed'}))};
const reusedResult = executePlan(reused, {fingerprint: () => 'same', run: () => 0});
assert.ok(reusedResult.liveAcceptance.every(item => item.status === 'pending'),
  'A stale plan cannot import desktop acceptance from a different installed build');
assert.equal(reused.liveAcceptance[0].status, 'passed', 'Resetting acceptance does not mutate a caller-owned receipt');
calls = [];
const failed = executePlan(plan, {fingerprint: () => 'same', run: id => { calls.push(id); return 7; }});
assert.equal(failed.status, 'failed');
assert.deepEqual(calls, ['gate'], 'Failure stops subsequent suites');
assert.equal(failed.suites[0].exitCode, 7);
let revision = 'before';
calls = [];
const drifted = executePlan(plan, {fingerprint: () => revision, run: id => { calls.push(id); revision = 'after'; return 0; }});
assert.equal(drifted.status, 'source-changed');
assert.deepEqual(calls, ['gate'], 'Source drift invalidates a passing subprocess immediately');

// Exercise the sourced worker policy in the real Bash used by macOS, without
// compiling or starting any app. Invalid values fail before Swift is invoked.
const workerScript = path.join(__dirname, 'build-jobs.sh');
function workerPolicy(value) {
  const env = {...process.env};
  if (value === undefined) delete env.INTENT_BUILD_JOBS;
  else env.INTENT_BUILD_JOBS = value;
  return spawnSync('/bin/bash', ['-ec', 'source "$1"; printf "%s" "$INTENT_BUILD_JOBS"', 'worker-test', workerScript],
    {env, encoding: 'utf8'});
}
assert.equal(workerPolicy(undefined).stdout, '1', 'Builds use one worker unless explicitly overridden');
for (const value of ['1', '2', '8']) {
  const result = workerPolicy(value);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, value);
}
for (const value of ['0', '9', '-1', '2.5', 'two', '1 --jobs 20', ' 2']) {
  const result = workerPolicy(value);
  assert.equal(result.status, 64, `Invalid build concurrency ${value} must fail closed`);
  assert.equal(result.stdout, '');
}

// Check the package's real native-host entry command with a fake swift binary,
// so a quoting error cannot drop the worker limit or extension host product.
const workerFixture = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-worker-spec-'));
try {
  const fakeSwift = path.join(workerFixture, 'swift');
  fs.writeFileSync(fakeSwift, '#!/bin/sh\nprintf "%s\\n" "$@"\n', {mode: 0o755});
  const nativeCommand = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'))
    .scripts['test:native-host'].split(' && node ')[0];
  const native = spawnSync('/bin/bash', ['-ec', nativeCommand], {
    cwd: path.resolve(__dirname, '..'), encoding: 'utf8',
    env: {...process.env, PATH: `${workerFixture}:${process.env.PATH}`, INTENT_BUILD_JOBS: '1'},
  });
  assert.equal(native.status, 0, native.stderr);
  assert.deepEqual(native.stdout.trim().split('\n'),
    ['build', '--jobs', '1', '-c', 'release', '--product', 'IntentNativeHost']);
} finally { fs.rmSync(workerFixture, {recursive: true, force: true}); }

// Exercise real Git index/worktree discovery, not source-text assertions.
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-impact-spec-'));
const git = (...args) => execFileSync('git', args, {cwd: fixture, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).trim();
const write = (file, value) => { fs.mkdirSync(path.dirname(path.join(fixture, file)), {recursive: true}); fs.writeFileSync(path.join(fixture, file), value); };
try {
  git('init', '-q'); git('config', 'user.email', 'qa@example.invalid'); git('config', 'user.name', 'Intent QA');
  write('Sources/IntentApp/Old.swift', 'baseline'); write('docs/qa/note.md', 'baseline');
  git('add', '.'); git('commit', '-qm', 'fixture');
  const base = git('rev-parse', 'HEAD');
  const original = sourceFingerprint(fixture);
  write('docs/qa/note.md', 'evidence may be recorded without invalidating source');
  write('unrelated-private-work/local.txt', 'never include unrelated untracked directories');
  assert.equal(sourceFingerprint(fixture), original);
  assert.ok(!changedPaths(fixture).includes('unrelated-private-work/local.txt'));
  write('Sources/IntentApp/New.swift', 'new source');
  assert.notEqual(sourceFingerprint(fixture), original, 'Untracked source is fingerprinted');
  assert.ok(changedPaths(fixture).includes('Sources/IntentApp/New.swift'));
  const unstaged = sourceFingerprint(fixture);
  git('add', 'Sources/IntentApp/New.swift');
  assert.equal(sourceFingerprint(fixture), unstaged, 'Staging alone does not invalidate content identity');
  fs.chmodSync(path.join(fixture, 'Sources/IntentApp/New.swift'), 0o755);
  assert.notEqual(sourceFingerprint(fixture), unstaged, 'Runtime file permission changes invalidate evidence');
  fs.chmodSync(path.join(fixture, 'Sources/IntentApp/New.swift'), 0o644);
  git('mv', 'Sources/IntentApp/Old.swift', 'Sources/IntentApp/Renamed.swift');
  const changed = changedPaths(fixture);
  assert.ok(changed.includes('Sources/IntentApp/Old.swift') && changed.includes('Sources/IntentApp/Renamed.swift'), 'Both rename sides are mapped');
  git('commit', '-qam', 'rename');
  assert.ok(changedPaths(fixture, base).includes('Sources/IntentApp/Renamed.swift'), 'Base detects committed as well as pending edits');
  const beforeDelete = sourceFingerprint(fixture);
  fs.unlinkSync(path.join(fixture, 'Sources/IntentApp/New.swift'));
  assert.notEqual(sourceFingerprint(fixture), beforeDelete, 'Deleted tracked source invalidates evidence');
  assert.throws(() => changedPaths(fixture, 'missing-ref'), 'Bad comparison base fails closed');
} finally {
  fs.rmSync(fixture, {recursive: true, force: true});
}
console.log('Change-impact mapping, source identity, failure propagation and live-acceptance boundaries passed.');
