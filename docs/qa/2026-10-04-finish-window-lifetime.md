# Finish-time window identity — 2026-10-04

## Reproduction and distinction from the earlier native-only pass

The installed `a463b9a` build preserved Finder during timer/checklist completion,
but that did not cover restoring multiple windows of the foreground browser.
Head Chat reproduced this additional case twice with signed Firefox 0.2.28:

1. Create the QA window in Firefox itself; select only its tab in Intent.
2. Start a stopwatch intention, leaving the other Firefox windows restricted.
3. Finish through Intent's File menu, then use only passive foreground/CG samples.

The working window (CG ID 12687) became offscreen while existing windows 11783
and 11787 returned. The working
window was still present in the all-window inventory. On the first reproduction,
the guard resolved that exact visible window, then logged four deferred AX
probes and cancelled with `windowUnavailable` about 547 ms after finish.
The native visibility journal contained no Firefox ownership; the extension
owned the older Firefox windows' minimization. Stage Manager was disabled.

Evidence retained locally:

- `/tmp/intent-firefox-window-finish.jsonl`
- `/tmp/intent-firefox-ownership-finish.jsonl`

## Definite native defect and candidate boundary

`RestorationFocusGuard` used `WorkspaceWindow.list()` as a lifetime check, even
though that method defaults to onscreen presentation candidates. Offscreen is
not the same as destroyed. The new `WorkspaceWindow.exists` probe requests the
all-window inventory and matches both CG window ID and owner PID. Missing means
closed; unavailable inventory means defer within the existing five-second limit.

The guard retains the originally resolved AX window; it does not guess another
window, reopen a browser, unhide an app or deminiaturize a target. Actual user
input, unrelated activation and a new session cancel the transaction. Old
timer, activation and input callbacks cannot act as a newer transaction.
Bounded diagnostics record target existence/visibility, readable minimized state
and Space notifications without titles or URLs.

Firefox's `windows.update({focused:false})` must not be assumed to prevent
restoration from changing the visible window: Mozilla's implementation handles
`focused:true` but still lists false as unimplemented. See [Mozilla's source](https://searchfox.org/firefox-main/source/browser/components/extensions/parent/ext-windows.js#510).
The initial displacement is separate from the native guard's early cancellation.

## Regression evidence

The CoreSpec calls the same production probe with an injected CG inventory. It
asserts exact query flags (not `contains(optionAll)`, since optionAll is zero),
visible/offscreen identity, another same-process window coming forward, reused
IDs with different PIDs, true removal and unavailable inventory. It does not
claim to synthesize AX timing, a physical key or a Space transition.

Passed after the final source edits:

- `npm run test:session-ui`: CG inventory fixtures, native keyboard fixtures,
  isolated CoreSpec, release app, app-model and real notch-panel checks. Source
  fingerprint remained stable. Evidence:
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-cIuamm1S`.
- `npm run test:extensions`, unchanged browser source.
- `npm run test:native-host`, including profile routing and performance (8.1 MiB
  peak RSS). One overlapping attempt hit SwiftPM's shared build database lock;
  the sequential rerun passed. Do not run two SwiftPM builds on this build path.
- Development install completed using macOS Python PATH. Installed app and
  tested QA app both have UUID `0DA4C920-7D41-340F-BD92-0E9A5D20FF4C`; strict
  deep signature verification passed. Log:
  `/tmp/intent-finish-window-install-oct4.log`.

### Candidate installed retest: failed, not accepted

The exact Firefox case still changed the working desktop on UUID
`0DA4C920-7D41-340F-BD92-0E9A5D20FF4C`. Target 12687 began visible with
`AXMinimized=false`; after AX timeouts it remained alive but became offscreen at
665 ms. `activeSpaceDidChange` arrived at 923 ms and cancelled preservation.
No user/CUA input occurred in the post-finish observation period. This confirms
an involuntary Space transition, not window closure. Evidence:
`/tmp/intent-firefox-candidate-finish.jsonl`.

The lifetime defect is real, but correcting it alone does **not** satisfy the
user's finish-focus contract. Both non-Firefox native unhide and Firefox's
window restoration were in flight; do not attribute the Space change to one
without isolating ownership. An empty-native-ledger variant is the next check.

### Browser-only isolation: confirmed restore-induced Space switch

Head Chat ran a blacklist variant selecting all tabs in the two older Firefox
windows and leaving QA window 12687 usable. The native hidden-workspace ledger
was verified empty (`[]`). Finish still revealed the older windows, displaced
12687 offscreen and emitted `spaceChanged` at about 597 ms. Therefore Firefox
window restoration alone is sufficient to cause this failure, without native
application unhide or native-window deminiaturization.

Evidence: `/tmp/intent-firefox-browser-only-finish.jsonl`. CG window arrays were
fresh, but the first helper read `NSWorkspace.frontmostApplication` repeatedly
without pumping its run loop and could cache its PID. Do not use that helper's
app-PID samples as proof of foreground retention. The CG and app-owned
restoration diagnostics establish the window/Space failure independently.

No browser implementation race was found in 48 isolated async schedules using
the real visibility class and runtime allowed-tab predicate. This does not prove
all browser behavior correct; it narrows the observed failure to restoration.

### Product boundary, not an accepted complete fix

There is no verified public interprocess deminiaturize-without-Space-activation
operation available to this implementation. A Space notification has no cause;
absence of NSEvent callbacks cannot prove a Space transition was not a deliberate
system gesture. Blindly raising the old window across Spaces can fight the user.

The native lifetime correction and bounded diagnostics are valid and tested, but
the full finish-focus issue remains open. Do not silently leave windows minimized
or change global macOS Space preferences. A second bounded candidate continues
the existing exact-window transaction through a Space notification, while adding
gesture event types to its input cancellation. It must be compared live before
claiming recovery; system-gesture delivery is a separate physical acceptance
item. Returning to the correct window after a jump is not proof that the visible
Space jump itself has been prevented. A public AX-only restore comparison may
still be needed before deciding whether browser ownership needs to change.

### Native-first production-path comparison

The same browser-only session was run against the installed first candidate.
Both older windows had been normal before the session, were minimized by Browser
Guard, and the native ledger was empty. With that ownership confirmed, the empty
ledger was backed up and a disposable fixture added only IDs 11783 and 11787,
bound to the current Firefox PID, bundle and exact process launch date. The
working window 12687 was not included. Finish still went through the normal UI.

This invoked `FocusVisibilityController`'s real native `AXMinimized=false` path
before the normal rules clear. Target 12687 remained first/onscreen in every
passive CG sample, with no `spaceChanged` diagnostic. The guard completed at five
seconds and recorded an exact-window preservation around 1.51 seconds. Trace:
`/tmp/intent-firefox-ax-comparison-finish.jsonl`.

This is a promising native-first intervention, **not** yet a pure AX-versus-browser
A/B or a complete pass: pending native retries can overlap browser restoration,
and the native setter's return code is not a final minimized-state readback. The
ledger retained 11787 pending at the first post-test check. Head Chat then used
the installed extension's normal Firefox debugging console to read
`browser.windows.getAll`: all three windows (browser IDs 3, 9 and 303) were
`maximized`, none minimized. This confirms restoration in this trial; the
remaining 11787 native entry was a stale timeout receipt. Rules were inactive,
the journal contained only that fixture entry, and only that entry was cleared,
returning the native journal to its backed-up empty state. No user-minimized
windows were adopted or cleared.

### Second candidate build, not yet installed

The bounded Space-notification candidate and stale input-callback identity fence
passed the full source-stable session gate at
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-GTqeu9QD`.
Built UUID: `E6B01B9D-6963-3929-8720-4A01EF95D1B1`. The daily app is still the
first candidate while the native-first comparison is investigated. An earlier
release link hit an Apple linker assertion; a plain sequential build retry and
the complete gate passed without compiler flags or source workarounds.

The second candidate will **not** ship: returning across Spaces can fight a user
gesture and does not prevent the initial visible jump. Its Space callback was
reverted to cancellation after the native-first comparison succeeded. The
lifetime correction and old-callback identity fences remain. Implementation now
uses exclusive native whole-window ownership with Browser Guard 0.2.29; see
`docs/browser-window-visibility-contract.md`. That bridge requires its own full
build, protocol/regression checks, matching component installation and live
acceptance before it can be called a fix.

### Exclusive native ownership implementation

Browser Guard 0.2.29 and the matching native host now negotiate the contract
above. The browser retains tab parking/order; whole-window visibility belongs to
the native journal. Before moving tabs into a holding window, the browser waits
for a durable native identity capture, not merely a saved plan. Browser API IDs
are never interpreted as CG window IDs. New claims require the verified browser
parent PID and launch lifetime, unique title plus geometry, and the exact rule
occurrence. Replays, older occurrences, process restarts and extension-only
reloads have separately bounded recovery paths.

The first combined source-stable session gate passed at
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-yH5Dq9JO`.
It includes the real CoreSpec, native input fixtures, release app, isolated
app-model persistence and notch panels. Review then found one additional native
recovery edge case: missing AppKit process metadata must retain ownership until
positive lifetime evidence is available. The final gate must be rerun after
that correction. The corrected lifetime version then passed the complete
source-stable gate at
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-xpsrR3uW`
and the full native-host suite (10.0 MiB peak RSS in the synthetic stress test).

Further integration review identified two release-blocking boundaries before
installation: required native mode could silently downgrade when process proof
was temporarily unavailable, and the active half-second loop re-decoded every
historical visibility plan. Required mode and negotiated readiness are now
separate, and discovery has a current-occurrence cache plus exact journal-key
recovery reads. The cache's first new regression run
(`intent-session-checks-8t8nLL4p`) failed its forced-refresh read-count assertion.
An isolated diagnostic confirmed the production refresh returned the right plan
and made exactly two current-file reads; the fixture looked up a nonstandardized
URL key. Test accounting now uses standardized URLs. The atomic-replacement
fixture also normalizes its initial mtime to a whole second so equal-time/size
invalidation is tested without Foundation timestamp-roundtrip noise. These final
corrections then passed their final green gate:

- `npm run test:session-ui`, same-source pass:
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-yAvrkZ5j`.
  App-model, real isolated notch panels, native input and all CoreSpec fixtures
  passed. Tested app UUID: `C923ED94-A0A6-3931-ABCE-1A2FE294C725`.
- `npm run test:native-host`: all ordinary protocol, visibility/capture,
  negotiation/readiness, restart/reload recovery, profile routing and snapshot
  checks passed. Stress peak RSS was 10.1 MiB. Tested host UUID:
  `218A3634-FAA8-384C-A58E-FA0374D10264`.
- The host's positive protocol fixtures use an explicitly simulated process
  identity in a renamed, isolated QA executable. Production-host tests prove
  rejection without real proof; neither is live browser/AppKit acceptance.
- Head Chat reports final browser commit `ff8bab1`, full Firefox/Chrome extension
  suites, release-readiness and Mozilla lint passing (zero lint errors, warnings
  or notices). Its rebuilt unsigned 0.2.29 archive SHA-256 is
  `2d6da9abe3b0e2d1a8c6c8957ff6b00b37e4ea4bd2774a8098d29f4d1e3374c6`.

At this checkpoint no bridge version has replaced the daily candidate or passed
matching-profile live acceptance. Daily rules are inactive and the native
hidden-workspace journal is empty. Signing, matching installation and the
multi-window foreground/Space retest remain separate steps.
