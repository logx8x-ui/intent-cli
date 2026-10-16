# Mission Control window continuity and Test Intent notes — 16 October

## Report and evidence

User reproduced a DBT session stopping on return from Apple Mission Control. The
new Test Intent receipt at 10:37 KST records `inventoryUnavailable`, one known
Chrome window, one AX standard window, zero metadata candidates, no minimized
AX windows, and `window-continuity` failure. The engine deliberately stopped; this
receipt is not a process-crash report. Original receipts are retained locally in
`dist/qa-20261016-mission-control-notes` (not source-controlled).

The prior fix handled minimized restore geometry but still required both title
and frame agreement for an existing non-minimized AX binding. Both are mutable
presentation properties sampled from different APIs. The shared observer now
retains a previously proven equal AX object only when a unique current title OR
frame match agrees with its exact native/process lifetime and there is no
contradictory complete match. Cold, replacement, ambiguous and process-reused
windows remain subject to strict matching. Hiding verification and safety stops
remain active. Diagnostic comparisons now retain geometry and title-match
booleans, not page titles, to identify any remaining mismatch precisely.

This addresses a concrete continuity defect; the historical receipt lacks the
actual mismatched property, so it does not prove this was the only trigger.
Both SBT and DBT use this same coverage owner. Both physical return paths need
verification against the new installed binary before calling the reported bug
closed.

## Test-only workspace

- Exactly two contacts; a third contact cancels page navigation.
- Gesture progress drives both pages continuously, with a spring settle/cancel
  on release and Reduce Motion support. Existing requested leftward mapping is
  preserved; no global macOS gesture preferences change.
- Page views remain mounted during navigation to preserve list/editor state.
- Notepad dragging uses the desktop coordinate space instead of a moving local
  coordinate space; crossing other notes no longer changes stacking on hover.
- Four corner handles resize with the opposite corner anchored, minimum size,
  canvas bounds, and one atomic position/size persistence on release.
- Existing task files without dimensions decode with the original default size;
  tasks, links and saved intentions are preserved.

## Acceptance

Pending final evidence: automated gate, source-matching installs, rendered
notes drag/resize/persistence, physical two-finger direction and feel, and SBT
plus DBT → Apple Mission Control → click allowed window. No tester-release
acceptance is implied by source tests.

## Intermediate verification

- `GRIvV4`: all six automated suites passed. Superseded by the draft-departure
  preservation change, so not final-source evidence.
- `rQT2LO`: all six automated suites passed with departure saving. Superseded by
  the one-line mouse-button cancellation guard for the trackpad recognizer.
- First run `f2Nm8L` stopped after successful release compilation because the
  temporary log volume ran out of space. Only generated QA executables and Intel
  build cache were removed; user data and retained evidence logs were kept.
- Root `/Applications/Intent.app` was verified as 0.9.4 build 202610150002, so the
  earlier installer approval did eventually complete. That package predates this
  turn's continuity change and is not evidence for the new fix.
