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

## Final source and installed evidence

- Code commit: `02bc479`; source-only publication `9da6496` on
  `codex/selected-resource-lifetime`.
- Exact source fingerprint:
  `89ca4a43387206b078774f03dc752376c6cb08e4f319c2f4ae0c9ef0486646f4`.
- Final gate `LMT1Sw`: source, session, Swift, extension, native host and release
  suites all exit 0. Receipt retained in `dist/qa-20261016-mission-control-notes`.
- Both local apps installed; deep/strict signatures verified. Test binary UUID
  `1F13E787-A4B3-36D5-8843-A22672A71A0F`; launch binary UUID
  `406B6AD9-0173-341C-B706-85C4ADCC14F7`. Stable home Applications paths and
  respective development/launch channels verified.
- Installed Test Intent: created a disposable empty list, dragged its header
  upward by 615 screen pixels, then resized bottom-right, top-left, top-right
  and bottom-left. Saved dimensions progressed 330x420 -> 400x470 -> 420x490 ->
  440x510 -> 460x530 points. No page navigation occurred during pointer drags.
- Entered a task draft and clicked Choose apps without submitting; returning
  to Tasks showed exactly one saved task and retained the resized card. Removed
  the disposable task and list through UI and confirmed no QA list remained.
  Existing user lists/tasks were preserved. Test Intent was then quit normally.
- Built signed ARM64 launch 0.9.5 / 202610160001. Firefox, Chrome, Both packages
  and DMG notarized/stapled; `verify-release.sh` passed. Artifacts retained under
  `dist/private-candidate-202610160001`. This is package integrity evidence,
  not release acceptance.
- System-wide update is at the macOS protected installer authorization prompt.
  Computer Use explicitly denied SecurityAgent; user action requested. Do not
  report `/Applications/Intent.app` updated until version/build verification.
- Still pending: physical two-finger left/right feel and three-finger rejection;
  physical SBT and DBT -> Apple Mission Control -> return to allowed Chrome
  window in both installed channels. Automated coverage does not close these.
- Downloads remain disabled. Chrome store approval, complete hosted installer
  journey, and runtime physical acceptance remain separate release blockers.
