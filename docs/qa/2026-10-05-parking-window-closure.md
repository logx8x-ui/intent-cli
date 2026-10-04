# Browser-confirmed parking-window closure — October 5, 2026

## Reproduction

The installed Browser Guard 0.2.30 pinned-tab checks returned every disposable
tab to its source and closed the empty extension holding window. Native recovery
nevertheless retained ownership because macOS still reported the holding
window's CG identity. A missing on-screen window is not sufficient evidence that
its lifetime ended.

Chrome browser window1733680428 / native15128 remained in the recovery journal
at 01:56 KST, with Chrome's original PID36078 still running. Firefox's corresponding
window852 / native15183 was initially retained too, but naturally retired before
that check. Rules were inactive. No journal entry was manually removed.

Firefox's ordinary Window menu and filtered, fresh session-recovery data confirmed
that its holding page belonged to closed windows, not a live browser window.
The raw unfiltered CG inventory could still retain the backing identity. The old
diagnostic helper's twenty-window output limit must not be used as closure proof.

## Acceptance boundary

The fix must let this extension profile report a successful full browser inventory
confirming that its own captured holding window closed. It must preserve the exact
browser process lifetime, profile, intention occurrence, browser window ID and
native capture identity. It must never infer closure from failed reads, off-screen
state or another profile that happens to share the same browser process.

Closure must retire only that parking record without revealing or touching an
ordinary user window. Lost replies and worker reloads need durable retry evidence;
cleanup retries must not block new tab selection or intention startup.

Pre-upgrade closed holders without profile-owned durable proof remain a compatibility
limit. The existing process-lifetime recovery still applies to them. Browser tests,
native protocol tests, installed-profile checks and physical shortcut acceptance
must be reported separately.

This work does not resolve the separate Firefox cross-desktop startup failure or
the macOS deminiaturization focus displacement. No public release, update feed or
waitlist deployment is included.

## Implemented and isolated verification

Browser Guard 0.2.31 adds a distinct closure receipt, exact process/profile/occurrence
validation and monotonic closed-parking IDs. Browser-owned proof is durable before
registration transport. Cleanup runs independently of new tab operations, with
bounded retries and fair singleton fallback after rejected batches. Native
retirement avoids AX work; final parking reveal dispatch shares the closure
record lock, acquired without waiting on the app thread.

The frozen candidate passed the full extension suite, including 21 targeted
closure-helper cases, 10 holder-cleanup failure regressions and the existing
pinned-tab suite. Full IntentCoreSpec and native-host visibility gates also passed
with Swift builds limited to two jobs. Baseline helper/cleanup/native regressions
failed before the fix. Firefox and Chrome implementation pairs are byte-identical.

Candidate and logs: `/Users/loganmondi/.codex/artifacts/intent-parking-closure-candidate-20261005/`.
Combined patch SHA-256: `ef1a9f9cc103bda3d19474f467e1b3d70463e29dc3436a8482d1e4c72f1dd99f`.
The patch was applied to `cf7ab1e`, followed by matching extension/host version bumps.

Positive native-host protocol tests use the isolated simulated-identity fixture;
they do not establish live AppKit, browser profile, physical-input or foreground
acceptance. An OS reveal already dispatched before closure acceptance may still
complete asynchronously afterward.

## Actual-checkout gates

- `npm run test:session-ui`: passed, same source throughout; evidence directory
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-LxCY9BTD`.
  Includes isolated core behaviour, keyboard handling, app model, notch presentation
  and the app release build. The Command Line Tools emitted an XCTest-platform
  lookup warning; it did not fail these executable regression gates.
- `npm run test:native-host`: passed against the release helper, including closure
  protocol, performance, snapshot freshness, rule notifications and profile routing.
  Log: `/tmp/intent-031-native-host.log`.
- Mozilla extension validator: zero errors, warnings and notices.
- Release-readiness gate: passed with matching Browser Guard 0.2.31 versions.
- Applied files match the tested candidate byte-for-byte, apart from the intentional
  native-host version bump. Both browser manifests were bumped together.

Builds used a temporary Swift wrapper adding `--jobs 2` and system Python first
in PATH. No global toolchain or Python settings were changed.

## Installed-profile acceptance

Installed with `scripts/install-dev.sh`, preserving daily data. Source and installed
app UUIDs match: `CD4A3AE2-833D-3A20-84B5-FCD531C3C0C2`. Source and embedded host UUIDs
match: `EC6EC376-4113-3307-84B2-11F66B96D745`. Deep strict code-sign verification passed.
Chrome reported a fresh 0.2.31 heartbeat. Firefox loaded the 0.2.31 ZIP through its
normal temporary-addon picker and reported the matching heartbeat. Firefox's
permanent signed version remains 0.2.28, so browser-restart/update acceptance is
still outstanding.

- Firefox session `A573831C-230E-4F6B-AF1D-8529EB2BF29C`: blacklist only the existing
  disposable pinned search tab; all modifications off. Browser holder890/native15268
  was durably captured. The two allowed Example Domain tabs switched through the
  native Sidebery UI. Menu Finish returned the original three-tab count and kept
  the last Example Domain tab selected. The host persisted `closedParkingWindowIDs:
  [890]`, and native ownership of15268 disappeared.
- Chrome session `89FA9030-BFDC-40F2-BDDF-E37CAF137E49`: blacklist only the disposable
  pinned search tab in the Logavix QA window. Browser holder1733680431/native15288
  was captured. Both allowed tabs switched through the native tab strip. Menu Finish
  returned the pinned tab with `Pinned` visible in its accessibility label and kept
  the other search tab selected. The host persisted closure of1733680431, and its
  native journal entry disappeared.
- Final rules are inactive and `hidden-workspace.json` is empty. The older 0.2.30
  Chrome15128 entry also naturally retired by the second test; its old record has
  no closure receipt, so do not attribute that legacy cleanup to the new protocol.

Tests used unnamed disposable drafts. During preparation, automated AX name-field
interaction did not establish text focus, and subsequent synthetic number input
loaded a saved draft. No session started; its prepared Messages icon was removed,
selections/name/timer were cleared, and fresh drafts were verified before running.
Do not count that automation route as successful text-entry or shortcut acceptance.
No saved intention was edited or deleted.

These scoped UI checks do not establish physical double-backtick/Caps Lock input,
human-perceived smoothness, every modification combination or strict quiet finish.
The latter still has its separately recorded macOS window-restoration failure.
