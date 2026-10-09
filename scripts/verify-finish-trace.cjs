#!/usr/bin/env node
'use strict';

// Read-only QA evidence validation. This does not drive UI, sample the desktop,
// or prove that no transition occurred between samples.
const fs = require('node:fs');

function verifyFinishTrace(samples, diagnostic, { minimumSeconds = 20, maximumGap = 0.075, initialMaximumGap = 0.075 } = {}) {
  const fail = message => { throw new Error(message); };
  if (!(minimumSeconds >= 5) || !(maximumGap > 0) || !(initialMaximumGap > 0)) fail('Invalid observation limits');
  const start = diagnostic?.startedAt;
  const begin = diagnostic?.events?.find(event => event.event === 'begin');
  const complete = diagnostic?.events?.find(event => event.event === 'complete');
  if (!Number.isFinite(start) || !(begin?.targetPID > 0) || !(begin?.visibleWindowID > 0)) {
    fail('Missing exact finish timestamp, target PID, or native window identity');
  }
  if (!complete || !Number.isFinite(complete.elapsed) || complete.elapsed < 4.5) {
    fail('The bounded native guard did not complete');
  }
  const disruptive = diagnostic.events.find(event =>
    /cancel|spaceChanged|preserveWindow|inputCountChanged/i.test(event.event) ||
    // An attempted AXMain/AXRaise is a correction even when the sampled target
    // was already front. Dispatch success and a later settled target cannot
    // establish that it preserved focus continuously. The cancelled variant
    // was recorded after AXMain had already been dispatched in older builds.
    /^ownedRestorePreservation/.test(event.event) ||
    [event.event, event.action, event.effect, event.operation].some(value => typeof value === 'string' &&
      /AXRaise|AXMain|(?:^|[._ -])(?:activate|activationEffect|raiseWindow|setMainWindow)(?:$|[._ (:-])/i.test(value)) ||
    ['mainStatus', 'raiseStatus', 'activationStatus'].some(key => Object.hasOwn(event, key)) ||
    (event.event === 'foreground' && event.pid !== begin.targetPID) ||
    (event.event === 'frontWindow' && event.targetIsFront !== true) ||
    (event.event === 'windowVisibility' && (event.exists === false || event.onScreen === false)));
  if (disruptive) fail(`Guard recorded ${disruptive.event}; not a quiet-finish pass`);
  if (!Array.isArray(samples) || samples.length < 2) fail('Insufficient samples');
  for (let i = 0; i < samples.length; i++) {
    if (!Number.isFinite(samples[i].at) || (i && samples[i].at <= samples[i - 1].at)) {
      fail('Sample timestamps must be finite and strictly increasing');
    }
    if (samples[i].nativeWindowQuerySucceeded === false) fail('Native window observation failed');
    if (Object.hasOwn(samples[i], 'requestedIntervalSeconds') &&
        (!Number.isFinite(samples[i].requestedIntervalSeconds) || samples[i].requestedIntervalSeconds > 0.05 + 1e-9 ||
         samples[i].requestedIntervalSeconds <= 0)) {
      fail('Independent sampler must request at least 50 ms observation frequency');
    }
  }
  const before = samples.filter(sample => sample.at <= start).at(-1);
  const after = samples.filter(sample => sample.at >= start);
  if (!before || start - before.at > maximumGap || !after.length || after[0].at - start > maximumGap) {
    fail('Recording does not cover the finish boundary closely enough');
  }
  if (before.frontWindowIDs?.[0] !== begin.visibleWindowID ||
      (before.pid !== begin.targetPID && !(begin.fromControls === true && before.pid === begin.controllerPID))) {
    fail('Pre-finish working window disagrees with the native guard target');
  }
  const observedSeconds = after.at(-1).at - start;
  if (observedSeconds < Math.max(minimumSeconds, complete.elapsed)) {
    fail(`Only ${observedSeconds.toFixed(2)} seconds recorded after Finish; need ${minimumSeconds}`);
  }
  let previous = before.at;
  const hasSpaceObservation = Number.isInteger(before.spaceChangeCount) && before.spaceChangeCount >= 0;
  // The sampler independently watches a public notification. It does not
  // fabricate an exact Space ID, which the supported public API does not expose.
  if (!hasSpaceObservation && after.some(sample => Object.hasOwn(sample, 'spaceChangeCount'))) {
    fail('Space observation does not cover the finish boundary');
  }
  for (const sample of after) {
    const limit = sample.at <= start + 5 && previous >= start ? initialMaximumGap : maximumGap;
    if (sample.at - previous > limit + 1e-6) fail('Gap in post-finish recording exceeds the limit');
    previous = sample.at;
    // frontWindowIDs must come from a separate optionOnScreenOnly CG query.
    // Filtering optionAll by IsOnscreen does not establish the same ordering.
    if (sample.pid !== begin.targetPID || sample.frontWindowIDs?.[0] !== begin.visibleWindowID) {
      fail('Foreground app or exact working window changed after Finish');
    }
    if (hasSpaceObservation && sample.spaceChangeCount !== before.spaceChangeCount) {
      fail('Independent Space-change observation changed or disappeared after Finish');
    }
  }
  return { samplesAfterFinish: after.length, observedSeconds,
    targetPID: begin.targetPID, targetWindowID: begin.visibleWindowID,
    maximumPermittedGapSeconds: Math.max(maximumGap, initialMaximumGap),
    spaceChangeNotifications: hasSpaceObservation ? 'unchanged' : 'unverified',
    exactSpaceIdentity: 'unverified-public-api-unavailable',
    exactBrowserTab: 'unverified-no-independent-tab-sampler' };
}

module.exports = { verifyFinishTrace };
if (require.main === module) {
  try {
    const [tracePath, diagnosticPath] = process.argv.slice(2);
    if (!tracePath || !diagnosticPath) throw new Error('Usage: node scripts/verify-finish-trace.cjs TRACE.jsonl DIAGNOSTIC.json');
    const samples = fs.readFileSync(tracePath, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
    const result = verifyFinishTrace(samples, JSON.parse(fs.readFileSync(diagnosticPath, 'utf8')));
    console.log(`PASS: sampled quiet finish ${JSON.stringify(result)} (not sub-sample or physical-input proof)`);
  } catch (error) {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  }
}
