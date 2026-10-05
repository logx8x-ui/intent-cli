#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {SUITES, LIVE_CASES, planChanges, changedPaths, sourceFingerprint, executePlan} = require('./change-impact.cjs');

for (const file of ['Sources/IntentApp/QuickSelectionView.swift', 'Sources/IntentLock/WorkspaceWindow.swift', 'Sources/IntentCore/UnknownNewOwner.swift', 'Sources/IntentNativeHost/main.swift']) {
  const plan = planChanges([file]);
  for (const suite of ['session', 'extensions', 'host', 'swift']) assert.ok(plan.suites.includes(suite), `${file}: ${suite}`);
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
assert.deepEqual(calls, plan.suites, 'Suites run once and serially in the declared order');
assert.ok(passed.liveAcceptance.every(item => item.status === 'pending'), 'Automation must never promote a live or physical case to passed');
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
