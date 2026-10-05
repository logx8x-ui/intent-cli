#!/usr/bin/env node
// Plans and runs existing behavioral suites. This never installs, starts a
// focus session, publishes, or certifies physical/live acceptance.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync, spawnSync} = require('node:child_process');

const SUITES = Object.freeze({
  gate: ['node', 'scripts/test-change-impact.cjs'],
  session: ['npm', 'run', 'test:session-ui'],
  swift: ['npm', 'run', 'test:swift'],
  extensions: ['npm', 'run', 'test:extensions'],
  host: ['npm', 'run', 'test:native-host'],
  release: ['npm', 'run', 'test:release-readiness'],
  ai: ['npm', 'run', 'test:ai'],
  lint: ['npm', 'run', 'extension:lint'],
});
const ALL = Object.keys(SUITES);
const DESKTOP = ['session', 'extensions', 'host'];
const LIVE_CASES = Object.freeze([
  'physical-caps-and-number-toggles',
  'staged-strip-editor-and-overview-continuity',
  'actual-browser-tab-outline-not-overview-thumbnail',
  'dbt-start-exact-current-native-window-and-browser-tab',
  'finish-exact-current-native-window-and-browser-tab-delayed-tail',
]);

function ownedPath(file) {
  return /^(Sources|scripts|firefox-extension|chrome-extension|services|supabase|Assets|\.github)\//.test(file)
    || /^(Package\.(swift|resolved)|package(-lock)?\.json|AGENTS\.md|firefox-updates\.json|install\.sh)$/.test(file);
}

function planChanges(files) {
  const selected = new Set(['gate']);
  const reasons = {};
  let desktop = false;
  const add = (file, suites) => {
    reasons[file] = suites;
    for (const suite of suites) selected.add(suite);
    if (suites.some(suite => DESKTOP.includes(suite))) desktop = true;
  };
  for (const file of [...new Set(files)].sort()) {
    if (/^(docs\/|README(?:\.|$))/.test(file) || /\.(md|txt)$/.test(file) && !ownedPath(file)) continue;
    if (/^services\/intent-ai\//.test(file)) { add(file, ['ai']); continue; }
    if (/^(firefox|chrome)-extension\//.test(file)) {
      // Both browsers and the app share rules/protocol. Testing only the edited
      // browser misses recovery/focus regressions in the other consumer.
      add(file, [...DESKTOP, 'release', 'lint']); continue;
    }
    if (/^Sources\//.test(file)) {
      // App/core/lock changes are coupled to browser startup and recovery. A
      // deliberately broad boundary is safer than a filename keyword guess.
      add(file, [...DESKTOP, 'swift']); continue;
    }
    if (/^(Package\.|package(?:-lock)?\.json|scripts\/|\.github\/|AGENTS\.md)/.test(file)) {
      add(file, ALL); continue;
    }
    if (/^(Assets\/|firefox-updates\.json|install\.sh)/.test(file)) {
      add(file, [...DESKTOP, 'release']); continue;
    }
    // Unclassified tracked code/configuration fails closed to all safe suites.
    add(file, ALL);
  }
  return {
    files: [...new Set(files)].sort(),
    suites: ALL.filter(suite => selected.has(suite)),
    reasons,
    liveAcceptance: desktop ? LIVE_CASES.map(id => ({id, status: 'pending'})) : [],
  };
}

function git(root, args) {
  return execFileSync('git', args, {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
}
function splitPaths(value) { return value.split('\0').filter(Boolean); }
function trackedPaths(root) { return splitPaths(git(root, ['ls-files', '-z', '--cached'])); }
function untrackedInputs(root) {
  return splitPaths(git(root, ['ls-files', '-z', '--others', '--exclude-standard'])).filter(ownedPath);
}
function changedPaths(root, base, all = false) {
  // A resolved commit hash, not arbitrary options or shell text, reaches diff.
  const resolved = base && git(root, ['rev-parse', '--verify', '--end-of-options', `${base}^{commit}`]).trim();
  return [...new Set([
    ...(all ? trackedPaths(root) : splitPaths(git(root, ['diff', '--name-only', '-z', '--no-renames', resolved || 'HEAD', '--']))),
    ...untrackedInputs(root),
  ])].sort();
}
function sourceFingerprint(root) {
  const hash = crypto.createHash('sha256');
  // Content, including deletions and untracked source, not index ordering. QA
  // notes/artifacts are intentionally excluded so recording evidence is safe.
  const files = [...new Set([...trackedPaths(root), ...untrackedInputs(root)])]
    .filter(file => ownedPath(file) || !/^(docs\/|README(?:\.|$))|\.(md|txt)$/.test(file)).sort();
  for (const file of files) {
    const full = path.join(root, file);
    hash.update(`${file}\0`);
    if (!fs.existsSync(full)) { hash.update('missing\0'); continue; }
    const stat = fs.lstatSync(full);
    hash.update(`mode:${stat.mode & 0o777}\0`);
    if (stat.isSymbolicLink()) hash.update(`link:${fs.readlinkSync(full)}\0`);
    else if (stat.isFile()) { hash.update(fs.readFileSync(full)); hash.update('\0'); }
    else throw new Error(`Gate input is not a file: ${file}`);
  }
  return hash.digest('hex');
}

function executePlan(plan, {fingerprint, run, now = () => new Date().toISOString()}) {
  const before = fingerprint();
  const result = {
    schemaVersion: 1, startedAt: now(), sourceFingerprint: before,
    status: 'running', suites: [], liveAcceptance: plan.liveAcceptance,
  };
  for (const id of plan.suites) {
    const exitCode = run(id, SUITES[id]);
    result.suites.push({id, exitCode, status: exitCode === 0 ? 'passed' : 'failed'});
    if (exitCode !== 0) { result.status = 'failed'; break; }
    if (fingerprint() !== before) { result.status = 'source-changed'; break; }
  }
  if (result.status === 'running') {
    result.status = fingerprint() === before ? 'automated-pass' : 'source-changed';
  }
  result.finishedAt = now();
  return result;
}

function main(argv) {
  let base, run = false, all = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--base' && argv[i + 1]) base = argv[++i];
    else if (argv[i] === '--run') run = true;
    else if (argv[i] === '--all') all = true;
    else throw new Error('Usage: node scripts/change-impact.cjs [--base COMMIT] [--all] [--run]');
  }
  const root = path.resolve(__dirname, '..');
  const plan = planChanges(changedPaths(root, base, all));
  if (!run) { console.log(JSON.stringify(plan, null, 2)); return; }
  const evidence = fs.mkdtempSync(path.join(os.tmpdir(), 'intent-change-gate-'));
  fs.chmodSync(evidence, 0o700);
  console.log(`Change-impact evidence: ${evidence}`);
  const provenance = {
    checkout: root, commit: git(root, ['rev-parse', 'HEAD']).trim(),
    base: base || null, plan,
  };
  fs.writeFileSync(path.join(evidence, 'plan.json'), JSON.stringify(provenance, null, 2));
  const result = executePlan(plan, {
    fingerprint: () => sourceFingerprint(root),
    run(id, command) {
      const log = fs.openSync(path.join(evidence, `${id}.log`), 'w');
      console.log(`Running ${id}: ${command.join(' ')}`);
      try {
        const child = spawnSync(command[0], command.slice(1), {
          cwd: root, stdio: ['ignore', log, log], timeout: 45 * 60 * 1000,
        });
        if (child.error) fs.writeSync(log, `${child.error.message}\n`);
        return child.status ?? 1;
      } finally { fs.closeSync(log); }
    },
  });
  result.commit = provenance.commit;
  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify(result, null, 2));
  const failedSuite = result.suites.find(suite => suite.status === 'failed');
  if (failedSuite) {
    const tail = fs.readFileSync(path.join(evidence, `${failedSuite.id}.log`), 'utf8').split('\n').slice(-80).join('\n');
    console.error(tail);
  }
  console.log(`${result.status}; evidence: ${evidence}`);
  // CI keeps stdout even when its temporary workspace is gone. Keep the source
  // receipt visible there without copying private profiles or browser content.
  console.log(JSON.stringify(result, null, 2));
  console.log('Installed UUID/profile, actual rendered outlines, physical input and exact window/tab focus remain separate acceptance checks.');
  if (result.status !== 'automated-pass') process.exitCode = 1;
}

module.exports = {SUITES, LIVE_CASES, ownedPath, planChanges, changedPaths, sourceFingerprint, executePlan};
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
