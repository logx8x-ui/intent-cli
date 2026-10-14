const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
function plan(script, args = []) {
  const result = spawnSync('bash', [path.join(root, 'scripts', script), ...args, '--print-plan'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
const development = plan('install-dev.sh');
const launch = plan('install-launch-local.sh');
assert.equal(development.channel, 'development');
assert.equal(development.app_name, 'Test Intent');
assert.equal(development.bundle_identifier, 'dev.loganmondi.intent.test');
assert.equal(development.data_directory_name, '.intent-test');
assert.equal(development.auth_scheme, 'intent-test');
assert.equal(development.cli_name, 'test-intent');
assert.equal(launch.channel, 'launch');
assert.equal(launch.app_name, 'Intent');
assert.equal(launch.bundle_identifier, 'dev.loganmondi.intent');
assert.equal(launch.data_directory_name, '.intent');
assert.equal(launch.auth_scheme, 'intent');
assert.equal(launch.cli_name, 'intent');
for (const field of ['bundle_identifier', 'binary_directory', 'app_bundle', 'build_path', 'auth_scheme', 'cli_name']) {
  assert.notEqual(development[field], launch[field], `Channels cannot overwrite one another's ${field}`);
}
assert.equal(path.basename(development.app_bundle), 'Test Intent.app');
assert.equal(path.basename(launch.app_bundle), 'Intent.app');
const invalid = spawnSync('bash', [path.join(root, 'scripts/install-dev.sh'), '--unknown-channel', '--print-plan'], { encoding: 'utf8' });
assert.equal(invalid.status, 64);
assert.equal(invalid.stdout, '');
// Execute the installer's actual build argument construction with macOS's
// Bash 3 and nounset. A dry plan does not catch an empty launch flag array.
const installer = fs.readFileSync(path.join(root, 'scripts', 'install-dev.sh'), 'utf8');
const buildCommand = installer.split('\n').find(line => /^  swift build /.test(line));
assert.ok(buildCommand);
for (const flags of ['', '-Xswiftc -D -Xswiftc INTENT_DEVELOPMENT']) {
  const result = spawnSync('/bin/bash', ['-uc', `INTENT_BUILD_JOBS=1; SWIFT_FLAGS=(${flags}); BUILD='/tmp/intent fixture'; product=IntentApp; swift() { printf '%s\\n' "$@"; }; ${buildCommand}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const expected = ['build', '-c', 'release', '--jobs', '1', '--scratch-path', '/tmp/intent fixture'];
  if (flags) expected.push('-Xswiftc', '-D', '-Xswiftc', 'INTENT_DEVELOPMENT');
  expected.push('--product', 'IntentApp');
  assert.deepEqual(result.stdout.trimEnd().split('\n'), expected);
}
console.log('Local installer plans keep app, identity, data, build, auth and CLI destinations separate.');
