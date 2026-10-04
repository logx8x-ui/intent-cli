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

### Matching development installation

Scoped native source was committed as `dfe0e73`, after browser commit `ff8bab1`.
With Head Chat's UI paused, the development installer completed using macOS
Python PATH; log: `/tmp/intent-native-visibility-install-20261004.log`.

- Daily app: `/Users/loganmondi/Applications/Intent.app`, PID 20331 immediately
  after installation, bundle `dev.loganmondi.intent`, `LSUIElement=true`.
- Installed app/host UUIDs match the tested UUIDs above exactly; strict deep
  signature verification passed.
- Embedded Firefox/Chrome native-visibility helper bytes match final source.
- Browser rules were inactive and the hidden-workspace journal was empty before
  and after installation. No fixture was seeded and no daily data reset.
- The installer correctly reported that default Firefox still had permanent
  Browser Guard 0.2.28 while 0.2.29 signing was pending. Its separate disposable
  QA-profile missing-extension warning is not proof of a default-profile failure.

The final Firefox/Chrome extension suites, release-readiness and Mozilla lint
were independently rerun after both commits and passed. Idle fixtures scheduled
zero snapshot timers for 1,000 inactive browser events. These are synthetic
efficiency checks, not battery-life or live foreground acceptance.

UI control was explicitly returned to Head Chat for the signed extension install
and exact-profile multi-window foreground/Space retest. That live acceptance is
still pending at this checkpoint; no remote push has occurred.

### Chrome installed checks and an evidence correction

Chrome connected as Browser Guard 0.2.29 with negotiated native-window
visibility on the installed build above. Head Chat exercised selected tabs,
Tab searches and a stopwatch: repeated tab clicks and a fresh search remained
usable, and a typed external URL was rejected. The first session had no blocked
whole-browser-window plan and therefore did not test native browser-window
restoration.

The second session (`0DFEE286-C25A-401F-B056-489C26FA7EA1`) created a real holding
window. Native ownership captured Chrome PID 36078 / CG window 13547 for browser
window 1733680409 before tabs moved. Head Chat observed the parked tab returned
to working window 9047 after Finish. The native journal later settled to `[]`;
cleanup was eventual, not instantaneous.

Trace `/tmp/intent-chrome-029-parking-finish.jsonl` has 40 samples across 20.53
seconds, all with Chrome PID 36078 and working CG 9047 first in a separate
`optionOnScreenOnly` query. However, it spans Unix timestamps
1791112581.785707–1791112602.3173571 and Finish began at 1791112600.129889. Thus
only **2.19 seconds are post-finish**, not 20 seconds. App-owned diagnostics
independently completed the five-second guard with no Space change, foreground
change or corrective raise. A longer post-finish recording remains required.

Do not interpret an `optionAll` inventory filtered by `kCGWindowIsOnscreen` as
front-to-back order: this machine returned a different order from a separate
`optionOnScreenOnly` query. The latter agreed with the native working-window
target. The earlier ordering discrepancy does not establish a guard-target bug.

This live run also exposed a genuine enforcement gap: two same-profile windows
with the same title and geometry cannot be safely mapped from browser IDs to
native CG and AX identities. The matcher correctly refused to minimize an
ambiguous window, but the intention did not report that its blocked-window
claim remained unresolved. Exact mapping must not be guessed, and this trial
is not a full restriction pass. A bounded explicit failure path is being added
separately; unique-title whole-window acceptance is still in progress.

### Unique-title Chrome window: strict no-pop failure

The subsequent unique-title case captured normal blocked CG 13527 / browser
window 1733680407 and parking CG 13585 / browser window 1733680412 with the
verified Chrome process lifetime. This exercised actual whole-window ownership,
not only parked tabs. The 120-sample trace spans 62.03 seconds, including 50.12
seconds after Finish (`startedAt` 1791113007.956737):

- `/tmp/intent-chrome-029-full-finish.jsonl`
- `/tmp/intent-chrome-029-full-diagnostics.json`

Chrome PID 36078 remained foreground, but restored CG 13527 displaced working
CG 9047 at approximately +0.436 seconds. Working CG 9047 returned by +1.500
seconds. Native diagnostics recorded eleven deferred AX probes before a
corrective raise at +1.107 seconds. Thus native AX deminiaturization itself can
raise a Chrome window: this is **not a no-pop pass**. The new read-only trace
verifier rejects this recording; a completed five-second guard does not erase
an earlier visible failure.

A follow-up candidate queues preservation of the already-bound, still-onscreen
working AX window immediately after each owned native restore, before waiting
for minimized/focused-state reads. It does not alter global macOS preferences,
use private window IDs, restore a minimized work target, or chase a Space.
Diagnostics distinguish this causal dispatch from a later corrective raise.
This remains an experimental timing improvement until the matching installed
build passes denser sampling and live observation; no claim of invisible
restoration follows from its source tests.

### Follow-up candidate regression gate

The candidate also adds explicit failure for continuously unresolved accepted
normal-window claims, exact bound-window verification across title/frame changes,
and generation/process/claim fences before delivering that failure. It does not
guess duplicate window identity or change parking acknowledgements. Failure
suppresses the success animation and preserves its specific error message.
Installed error presentation still needs checking: the existing hidden SwiftUI
alert host has no explicit activation, but source review alone does not establish
whether the notice is visible without bringing Intent forward.

Focus preservation now checks public WindowServer input counters before each
effect as well as NSEvent monitors. This covers input whose main-queue callback
is delayed by AX IPC. It rechecks native visibility and foreground between AX
effects, records whether the target was already in front, and uses both bounded
uptime and wall-time fences so sleep/wake cannot replay an old transaction.

- `intent-session-checks-6JEdzKbJ` passed component checks but was correctly
  rejected by the source-stability check after the final input-counter edit.
- `intent-session-checks-lMljRzsJ` passed the complete gate. A subsequent two-line
  sleep/wake fence required another complete run before installation.
- Final same-source `npm run test:session-ui` passed at
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-CxIDqGTU`.
  Tested app UUID: `EA77703F-F19A-3A2F-8724-0A9C9D0D9B28`.
- Full `npm run test:native-host` passed (10.1 MiB peak stress RSS). Tested host
  UUID: `2116F34D-AA5B-3F10-A858-47F2023A569A`. The later fence changes only the
  native focus guard, not the host or core protocol.
- Firefox/Chrome extension suites, release-readiness fixtures and Mozilla lint
  passed again with unchanged browser source; lint has zero errors/warnings.

The trace verifier itself is now included in the session gate. It rejects a wrong
pre-finish target, short post-finish coverage, gaps over 0.2 seconds in the first
five post-finish seconds, later gaps over 0.75 seconds, and recorded/sampled
displacement. Pure fixtures do not prove actual AX ordering or invisible visual
restoration. The matching installed candidate retest is still pending here.

Candidate source was committed as `e383c88` and installed under an explicit
install-only desktop lease. `scripts/install-dev.sh` completed using the macOS
Python PATH. Log: `/tmp/intent-owned-restoration-install-20261004.log`.
`/Users/loganmondi/Applications/Intent.app` relaunched as PID 62505 with bundle
`dev.loganmondi.intent` and `LSUIElement=true`. Installed app and host UUIDs match
the tested UUIDs above exactly; deep strict signature verification passed.
Rules were inactive and the native journal empty before and after installation.
Chrome still advertised Browser Guard 0.2.29 and native visibility readiness.
Firefox's permanent 0.2.28/signing-pending warning remained unchanged. The
install lease was returned to Head Chat for the dense exact-case retest; root
performed no UI driving or fixture seeding.

### Installed immediate-preservation candidate: still fails strict acceptance

Head Chat repeated the exact Chrome case in occurrence
`7C68758F-67B6-440C-BB1E-BA5CAC8E678E` on installed `e383c88`: working CG 9047,
normal owned CG 13527 and parking CG 13633. Evidence:

- `/tmp/intent-chrome-029-immediate-finish.jsonl`
- `/tmp/intent-chrome-029-immediate-diagnostics.json`

The trace includes 225 post-finish samples and 32.24 seconds after Finish.
Foreground PID stayed 36078, but the old window became first at +0.5194 seconds
and working CG 9047 returned at +1.1143 seconds: roughly 0.6 seconds of
displacement remains. The old window's bounds grew from 92 x 158 at +0.437 to
1710 x 1073 at +0.777, identifying the Dock deminiaturization animation as the
visible operation. Immediate AX preservation was overtaken by that asynchronous
animation. The guard reported its target already front before every immediate
dispatch and no later corrective raise; those diagnostics alone would have
missed the displacement.

The trace also has a 0.228-second gap in the first five seconds, exceeding the
verifier's 0.2-second requirement. The verifier rejects the recording; widening
that tolerance would not remove the independently recorded window switch.
This is an improvement over the earlier one-second displacement, **not a fixed
no-pop finish**. No further timing patch is accepted on this evidence.

Parked user tabs returned. Parking ownership was still present after several
minutes, then retired to `[]` on a subsequent passive read without journal
mutation. Record eventual cleanup, not immediate cleanup. Supported non-minimize
hiding/restoration alternatives and the actual duplicate-claim failure notice
remain under investigation; leaving ordinary windows minimized after Finish
would change restoration semantics and must not be introduced silently.

### Duplicate claim failure: stop verified, notice deferred

Head Chat repeated the duplicate-title/geometry case on installed `e383c88` in
occurrence `7FDF305B-10E1-4121-A423-DA49E26964EC`, with the passive observer
started before Run. Rules became inactive. The foreground changed from Intent
to Chrome at 9.725 seconds in the 40-second trace and remained Chrome without
any subsequent CUA call. Evidence:
`/tmp/intent-chrome-029-duplicate-stop.jsonl`.

The specific failure sheet was observed only after a later Intent accessibility
query reopened/activated the app. Thus the safety stop is effective, but the
existing alert on the hidden utility host is not a verified immediate visible
notice. Do not describe this as an unattended-notice pass or infer that the
alert itself stole focus. A nonactivating failure notice needs separate review;
successful completion must still show no utility screen.

### Supported API boundary and pending product choice

Mozilla's public window update implementation handles `focused: true` but still
lists `focused: false` as unimplemented, and its public window schema has no
per-window hidden/order-out operation. Its native Cocoa implementation describes
deminiaturization as asynchronous; the did-deminiaturize callback finalizes that
transition and sends activation events. Similarly, the public AX notification
reports that the window is already no longer minimized, not a pre-visibility
barrier. These APIs cannot be treated as prevention of the recorded animation.

Primary references:

- [Firefox window update implementation](https://searchfox.org/firefox-main/source/browser/components/extensions/parent/ext-windows.js#510)
- [Firefox native Cocoa window implementation](https://github.com/mozilla-firefox/firefox/blob/main/widget/cocoa/nsCocoaWindow.mm)
- [Firefox public windows schema](https://github.com/mozilla-firefox/firefox/blob/main/browser/components/extensions/schemas/windows.json)

Source review also found that native recovery starts before the normal app rules
clear, but an already-in-flight renewal can clear rules while that recovery is
running. Browser tab restoration and native window restoration do not share a
tabs-ready acknowledgement. This overlap is a contributor hypothesis, not proof
of the measured animation, and merely reordering it cannot establish no-pop.

Logan was asked whether a quiet finish should leave ordinary windows minimized
until he chooses them. No answer had arrived at this checkpoint. No deferred
restoration semantics, global macOS preferences, private window APIs or further
timing workaround were introduced while that product choice remained pending.
