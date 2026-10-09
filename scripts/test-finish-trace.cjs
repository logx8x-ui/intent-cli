'use strict';
const assert = require('node:assert/strict');
const { verifyFinishTrace } = require('./verify-finish-trace.cjs');
const diagnostic = { startedAt: 100, events: [
  { event: 'begin', targetPID: 42, visibleWindowID: 123 },
  { event: 'foreground', pid: 42, elapsed: 0.02 },
  { event: 'complete', elapsed: 5.01 }
] };
const trace = Array.from({ length: 441 }, (_, i) => 99 + i * 0.05)
  .map(at => ({ at, pid: 42, frontWindowIDs: [123, 456] }));
assert.equal(verifyFinishTrace(trace, diagnostic).observedSeconds, 21);
assert.throws(() => verifyFinishTrace(trace.filter(sample => sample.at <= 102), diagnostic), /Only 2.00 seconds/);
assert.throws(() => verifyFinishTrace(trace.map(sample => ({ ...sample, at: sample.at - 30 })), diagnostic), /boundary/);
assert.throws(() => verifyFinishTrace(trace.filter(sample => sample.at < 104 || sample.at > 109), diagnostic), /Gap/);
assert.throws(() => verifyFinishTrace(trace.map((sample, i) => i === 29 ? { ...sample, pid: 99 } : sample), diagnostic), /Foreground/);
assert.throws(() => verifyFinishTrace(trace.map((sample, i) => i === 29 ? { ...sample, frontWindowIDs: [456, 123] } : sample), diagnostic), /Foreground/);
assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events,
  { event: 'frontWindow', pid: 42, windowID: 456, targetIsFront: false }] }), /not a quiet/);
assert.equal(verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events,
  { event: 'frontWindow', pid: 42, windowID: 123, targetIsFront: true }] }).observedSeconds, 21);
assert.throws(() => verifyFinishTrace(trace.map(sample => ({ at: sample.at, pid: sample.pid, windows: [{ id: 123, onScreen: true }] })), diagnostic), /Pre-finish/);
assert.throws(() => verifyFinishTrace(trace.map(sample => sample.at <= 100 ? { ...sample, pid: 99 } : sample), diagnostic), /Pre-finish/);
assert.throws(() => verifyFinishTrace(trace.filter(sample => sample.at < 101 || sample.at > 101.3), diagnostic), /Gap/);
assert.throws(() => verifyFinishTrace([...trace].reverse(), diagnostic), /increasing/);
assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: diagnostic.events.slice(0, 2) }), /did not complete/);
for (const event of ['spaceChanged', 'preserveWindow', 'cancel']) {
  assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events, { event }] }), /not a quiet/);
}
assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events,
  { event: 'ownedRestorePreservation', targetWasFront: false, targetWasFrontBeforeRaise: true }] }), /not a quiet/);
assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events,
  { event: 'ownedRestorePreservation', targetWasFront: true, targetWasFrontBeforeRaise: true }] }), /not a quiet/);
for (const event of [
  { event: 'ownedRestorePreservationCancelled', targetWasFront: true, mainStatus: 0 },
  { event: 'AXRaise', targetWasFront: true },
  { event: 'AXMain', targetWasFront: true },
  { event: 'activate', targetWasFront: true },
  { event: 'effect', action: 'application.activate(options: [])', targetWasFront: true },
  { event: 'effect', operation: 'AXUIElementPerformAction(kAXRaiseAction)', targetWasFront: true },
  { event: 'effect', raiseStatus: -25204 },
  { event: 'effect', activationStatus: 0 }
]) {
  assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [...diagnostic.events, event] }), /not a quiet/);
}
assert.throws(() => verifyFinishTrace(trace.filter((_, i) => i < 180 || i % 2 === 0), diagnostic), /Gap/);
assert.throws(() => verifyFinishTrace(trace.map((sample, i) => i === 90 ? { ...sample, nativeWindowQuerySucceeded: false } : sample), diagnostic), /observation failed/);
assert.equal(verifyFinishTrace(trace.map(sample => ({ ...sample, requestedIntervalSeconds: 0.050000000000000003 })), diagnostic).observedSeconds, 21);
assert.throws(() => verifyFinishTrace(trace.map(sample => ({ ...sample, requestedIntervalSeconds: 0.0501 })), diagnostic), /50 ms/);
assert.throws(() => verifyFinishTrace(trace.map(sample => ({ ...sample, requestedIntervalSeconds: 0.1 })), diagnostic), /50 ms/);
const spaceTrace = trace.map(sample => ({ ...sample, spaceChangeCount: 3 }));
assert.equal(verifyFinishTrace(spaceTrace, diagnostic).spaceChangeNotifications, 'unchanged');
assert.equal(verifyFinishTrace(trace, diagnostic).spaceChangeNotifications, 'unverified');
assert.equal(verifyFinishTrace(spaceTrace, diagnostic).exactSpaceIdentity, 'unverified-public-api-unavailable');
assert.equal(verifyFinishTrace(spaceTrace, diagnostic).exactBrowserTab, 'unverified-no-independent-tab-sampler');
assert.throws(() => verifyFinishTrace(spaceTrace.map((sample, i) => i >= 90 ? { ...sample, spaceChangeCount: 4 } : sample), diagnostic), /Space-change/);
assert.throws(() => verifyFinishTrace(spaceTrace.map((sample, i) => i >= 90 ? { ...sample, spaceChangeCount: undefined } : sample), diagnostic), /Space-change/);
assert.throws(() => verifyFinishTrace(spaceTrace.map(sample => sample.at <= 100 ? { ...sample, spaceChangeCount: undefined } : sample), diagnostic), /Space observation/);
assert.throws(() => verifyFinishTrace(trace, { ...diagnostic, events: [{ event: 'begin', targetPID: 42 }, diagnostic.events.at(-1)] }), /identity/);
console.log('PASS: finish trace accounting rejects short tails, stale/unordered evidence, sampling gaps, focus/Space changes and every attempted correction; exact tab/Space identity remain unverified');
