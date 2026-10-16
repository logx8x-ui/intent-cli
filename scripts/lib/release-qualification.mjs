// Shared with the private site's server validator. No credentials or user content.
export const QUALIFICATION_SCHEMA = 1;
export const REQUIRED_RELEASE_CHECKS = Object.freeze({
  'automated.regressions': 'automated',
  'installed.launch.sbt': 'installed', 'installed.launch.dbt': 'installed',
  'installed.test.sbt': 'installed', 'installed.test.dbt': 'installed',
  'physical.launch.rcmd-mission-control': 'physical',
  'physical.test.rcmd-mission-control': 'physical',
  'physical.dbt-outlines': 'physical', 'physical.shortcuts': 'physical',
  'installed.presets-modifications': 'installed', 'installed.resource-lifetime': 'installed',
  'installed.finish-restoration': 'installed', 'installed.browser-profiles-tabs': 'installed',
  'installed.instagram-youtube': 'installed', 'installed.recovery': 'installed',
  'hosted.firefox': 'hosted', 'hosted.chrome': 'hosted', 'hosted.both': 'hosted',
  'clean-account.firefox': 'clean-account', 'clean-account.chrome': 'clean-account', 'clean-account.both': 'clean-account',
  'compatibility.macos13': 'installed', 'compatibility.current-macos': 'installed',
  'data.update-reinstall-rollback-uninstall': 'installed', 'privacy.invites-and-public-root': 'hosted',
});
const record = v => !!v && typeof v === 'object' && !Array.isArray(v);
const digest = v => typeof v === 'string' && /^[a-f0-9]{64}$/.test(v) && !/^(.)\1+$/.test(v);
const date = v => typeof v === 'string' && Number.isFinite(Date.parse(v));
const browsers = ['firefox', 'chrome', 'both'];
const uuid = v => typeof v === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v);
export function qualificationIdentity(release) {
  return { version: release.version, build: release.build, source_commit: release.source_commit,
    source_fingerprint: release.source_fingerprint, app_binary_sha256: release.app_binary_sha256,
    firefox_extension_version: release.firefox_extension_version, chrome_extension_version: release.chrome_extension_version,
    packages: Object.fromEntries(browsers.map(browser => [browser, release.installers?.[browser]?.sha256])) };
}
export function qualificationCandidateMatches(actual, expected) {
  return record(actual) && record(expected)
    && Object.keys(expected).filter(key => key !== 'packages').every(key => actual[key] === expected[key])
    && browsers.every(browser => digest(expected.packages?.[browser])
      && actual.packages?.[browser] === expected.packages[browser]);
}
export function validateQualification(release, qualification = release?.qualification) {
  const fail = reason => ({ ok: false, reason });
  if (!record(release) || release.source_dirty !== false || !/^[a-f0-9]{40}$/.test(release.source_commit ?? '')
      || !digest(release.source_fingerprint) || !digest(release.app_binary_sha256)) return fail('candidate-identity');
  if (!record(qualification) || qualification.schema !== QUALIFICATION_SCHEMA || !record(qualification.candidate)
      || !date(qualification.completed_at) || !Array.isArray(qualification.blockers) || qualification.blockers.length
      || !record(qualification.checks)) return fail('qualification-incomplete');
  const expected = qualificationIdentity(release), actual = qualification.candidate;
  for (const key of Object.keys(expected).filter(key => key !== 'packages')) {
    if (actual[key] !== expected[key]) return fail('qualification-stale');
  }
  for (const browser of browsers) {
    if (!digest(expected.packages[browser]) || actual.packages?.[browser] !== expected.packages[browser]) return fail('qualification-artifacts');
  }
  for (const [id, kind] of Object.entries(REQUIRED_RELEASE_CHECKS)) {
    const check = qualification.checks[id];
    if (!record(check) || check.status !== 'passed' || check.kind !== kind || !date(check.observed_at)
        || !qualificationCandidateMatches(check.candidate, expected)
        || Date.parse(check.observed_at) > Date.parse(qualification.completed_at)
        || !Array.isArray(check.evidence) || !check.evidence.length
        || !check.evidence.every(e => record(e) && typeof e.path === 'string' && /^[a-zA-Z0-9_./-]+$/.test(e.path)
          && !e.path.startsWith('/') && !e.path.split('/').includes('..') && digest(e.sha256))) return fail(`check:${id}`);
    if (kind !== 'automated') {
      const env = check.environment;
      if (!record(env) || typeof env.macos !== 'string' || !/^\d+\.\d+(?:\.\d+)?$/.test(env.macos)
          || env.architecture !== 'arm64' || !uuid(env.app_uuid)
          || !record(env.browsers) || typeof env.browsers.firefox !== 'string' || !env.browsers.firefox
          || typeof env.browsers.chrome !== 'string' || !env.browsers.chrome) return fail(`environment:${id}`);
      if (id === 'compatibility.macos13' && !env.macos.startsWith('13.')) return fail('oldest-os-unverified');
    }
    if (id.endsWith('rcmd-mission-control')) {
      const m = check.metrics;
      if (!record(m) || !['bursts','seconds_per_burst','mission_control_cycles','soak_seconds'].every(key => Number.isFinite(m[key]))
          || m.bursts !== 3 || m.seconds_per_burst < 60 || m.mission_control_cycles < 20 || m.soak_seconds < 1800
          || m.input_tap_timeouts !== 0 || m.recoveries !== 0 || m.safety_stops !== 0 || m.excluded_app_escapes !== 0
          || !Number.isSafeInteger(m.callback_count) || m.callback_count < 1000
          || !Number.isFinite(m.max_callback_microseconds) || m.max_callback_microseconds < 0
          || m.max_callback_microseconds >= 5000) return fail(`stress:${id}`);
    }
  }
  return { ok: true };
}
