#!/usr/bin/env node
'use strict';

// Read-only QA evidence validation. This does not drive UI, sample the desktop,
// or prove that no transition occurred between samples.
const fs = require('node:fs');

function verifyFinishTrace(samples, diagnostic, { minimumSeconds = 20, maximumGap = 0.75, initialMaximumGap = 0.2 } = {}) {
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
    (event.event === 'ownedRestorePreservation' &&
      (event.targetWasFront !== true || event.targetWasFrontBeforeRaise !== true)) ||
    (event.event === 'foreground' && event.pid !== begin.targetPID) ||
    (event.event === 'frontWindow' && event.targetIsFront !== true) ||
    (event.event === 'windowVisibility' && (event.exists === false || event.onScreen === false)));
  if (disruptive) fail(`Guard recorded ${disruptive.event}; not a quiet-finish pass`);
  if (!Array.isArray(samples) || samples.length < 2) fail('Insufficient samples');
  for (let i = 0; i < samples.length; i++) {
    if (!Number.isFinite(samples[i].at) || (i && samples[i].at <= samples[i - 1].at)) {
      fail('Sample timestamps must be finite and strictly increasing');
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
  for (const sample of after) {
    const limit = sample.at <= start + 5 && previous >= start ? initialMaximumGap : maximumGap;
    if (sample.at - previous > limit + 1e-6) fail('Gap in post-finish recording exceeds the limit');
    previous = sample.at;
    // frontWindowIDs must come from a separate optionOnScreenOnly CG query.
    // Filtering optionAll by IsOnscreen does not establish the same ordering.
    if (sample.pid !== begin.targetPID || sample.frontWindowIDs?.[0] !== begin.visibleWindowID) {
      fail('Foreground app or exact working window changed after Finish');
    }
  }
  return { samplesAfterFinish: after.length, observedSeconds,
    targetPID: begin.targetPID, targetWindowID: begin.visibleWindowID };
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
