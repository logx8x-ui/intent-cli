# Compact notch HUD and completion laser — 5 October 2026

## Acceptance brief

Logan rejected the previous large HUD. The replacement should use literal
menu-bar-sized timing text, a tiny dark-grey/black notch surround with smooth
angular wings attached to the screen top, and a shallow intention-name lip.
Completion should be a thinner animated laser in the exact intention-mode
green/red, not a broad glowing border. Continue prior browser/input work without
claiming those outstanding cases are fixed by a visual change.

## Owners and implementation

- `SessionNotchLayout`: uses the actual camera gap as a distinct `notchFrame`.
  For a 200×32-point camera, the collapsed footprint drops from 424×60 to
  300×46 points: 24-point indicator wing, 76-point clock wing, 14-point name lip.
  No-notch displays get a 228×24-point cap below the menu bar without a fake
  empty camera region. Expanded checklist rows are 34 points, capped at 204.
- `SessionChromeStyle`: shared resolved dark-mode green/red for the 5-point
  indicator and laser; 13-point system timing text and 10-point title text.
  Redundant FOCUS/BLOCK labels and stacked clock labels are removed.
- `SessionNotchView` and `OverlayWindowController`: screen-top header remains
  mouse-transparent. Only a separate below-notch checklist panel takes clicks.
  Hardware controls do not create a second ticking `TimelineView`; no-notch
  controls own the single clock. Hide/end dismiss both panels.
- `SessionCompletionLight`: correct physical-notch origins despite asymmetric
  wings; 1-point coloured cores, short 76-point tails, 8-point tips, restrained
  glow and a small same-colour meeting pulse. Finite 1.05-second Core Animation,
  no recurring animation timer. Reduce Motion keeps only a static 1-point fade.

## Verification record

Source base: `0a119687d0f5763d811d5be2650d40e36e621d2c` on
`codex/name-first-intentions`, with the scoped changes above.

- First gate: core, native input and isolation passed; release type-check caught
  an overly complex quadratic path expression. The expression was split into
  explicitly typed coefficients without changing the curve.
- Extension harness: Firefox, Chrome, installation, idle-work, popup,
  tab/native-window visibility and website-feature regressions passed.
- A second render gate caught `100:00:00` needing 66.222 points. The clock's
  content allowance is now 67 rather than 66 points, preserving both the
  13-point font and the 300-point outer width.
- Final `npm run test:session-ui`: PASS, unchanged source throughout. Core
  behaviour, physical/latched-Caps decoder fixtures, 100 repeated gesture
  sequences, isolated data guards, release build, 46 model assertions and
  85 notch/laser/panel assertions all passed. These are not posted physical keys.
  Evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-mCcsVuqN`.
  Source fingerprint:
  `c0ad53fa36f20eb30fc59ec3907b026e93bdf21bd9746526712209b63139cdd8`.
  Built/QA app UUID: `40135A04-A09A-37EF-9B64-F29B5A916665`.
- Actual render inspection: hardware collapsed whole/header/controls and
  expanded controls preserve their alignment; no clipped clock or task text.
  Long mixed-language names truncate inside the lip. No-notch collapsed and
  expanded controls render without a camera gap. Sampled actual CA layers show
  slim red/green travelling strokes and a small meeting pulse, not a white flash.
  These are isolated bitmap observations, not live animation/Space acceptance.
  Renders: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-T9rSkNQn`.
- `npm run test:native-host`: PASS, including ownership/protocol, performance
  (10.2 MiB peak RSS), snapshot freshness and exact-profile routing.
- Read-only second review found no split-panel lifecycle/interactive-region
  regression: ordering out removes the input region; header never registers one.
- Installation identity and live acceptance follow below. The checks above do
  not establish that the user's installed copy has been updated yet.

## First installation and real-panel correction

Development installation at `/Users/loganmondi/Applications/Intent.app` matched
app UUID `40135A04-A09A-37EF-9B64-F29B5A916665`; embedded/built native host UUID
`227B15F6-69AB-34ED-A8D9-753E8B7A61B0`; deep strict code-signature verification
passed and `LSUIElement=true`. The installer launched PID 68463. No browser was
restarted. Permanent Firefox remained 0.2.28 underneath temporary 0.2.29.

A disposable two-minute Calculator blacklist + two-task checklist showed the
smaller red-dot timer correctly, but collapsing the real checklist exposed an
AppKit hosting issue absent from the NSHostingView bitmap checks. The actual
209×38 camera uses a 309-point wide header. After content-controller replacement,
CG reported header Y=-38 rather than 0 and collapsed controls Y=24 rather than38:
each panel had shifted upward by its own height. CUA then could not capture the
off-screen header (ScreenCaptureKit invalid parameter). This run is **not** a
live acceptance pass. The session expired and its hidden-workspace journal
returned to empty. No browser tabs were changed by this test.

`SessionNotchPanel.setHostedContent` now disables hosting size negotiation,
assigns/ lays out the new content controller, then applies the authoritative
anchored frame last. A real NSPanel/NSHostingController replacement-cycle
regression exercises both slices, notch/fallback, four expanded/collapsed states,
and immediate/deferred frame and content bounds. Cropped-away content is hidden
from Accessibility so the header does not advertise off-panel buttons.

Important causality limit: never-ordered standalone old-order probes did not
reproduce the live shift. AppKit documents that content-controller assignment can
resize a window, but this is hardened placement, not proof that assignment alone
caused the observed displacement. CUA activation/AX handling may also affect this
case. Retest actual visible geometry before and after interaction; do not turn an
isolated regression pass into a live acceptance claim.

## Final installed verification

- Final same-source gate: PASS at
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-FnTrR3bt`.
  Real notch/laser/panel assertions increased to 149. A fractional-coordinate
  fixture initially failed exact equality because AppKit rounds window origins;
  the fixture now uses integer auxiliary-area edges like the hardware. Exact
  frame/bounds assertions were retained, not loosened.
- Matching development app reinstalled and relaunched at the same stable path.
  Installed/QA UUID: `8D9DB5F9-2194-3B0A-9A71-27E32E5BEA10`; PID 88331;
  deep strict signature verification passed. Native host unchanged from the
  first installation. Installer log:
  `/tmp/intent-compact-notch-install-final-20261005.log`.
- Live disposable Calculator-only blacklist, named `QA compact verified`,
  combined a three-minute timer and two checklist tasks. The actual hardware
  notch is 209×38 points. Header CG frame stayed `(727,0,309,38)`;
  expanded controls `(727,38,309,94)` → collapsed `(751,38,209,14)` → expanded
  `(727,38,309,94)`. The name-strip coordinate clicks succeeded and neither
  panel shifted upward. This is actual ordered-window evidence after the fix.
- Actual first/final checkbox coordinate clicks completed both tasks. Journal
  occurrence `8F895E49-0103-4A0A-AEAF-BA17A487E53B` records completed tasks
  `[0,1]` and 33.59 seconds remaining: the last checkbox, not timer expiry,
  ended the session. Both HUD panels disappeared.
- Passive 40-second native-window trace:
  `/tmp/intent-compact-final-checklist-panels-20261005.jsonl`. Completion panel
  appeared in 19 samples spanning 0.980 seconds (consistent with its 1.05-second
  lifetime), then disappeared. No HUD/laser reappeared over the final 32.33
  seconds. Final hidden-workspace journal is empty; no active test remains.
- CUA app-targeted actions activate Intent while testing, so this run does not
  establish physical nonactivation/foreground acceptance. It verifies actual
  geometry, pointer hit targets, completion cause and panel lifetime. The laser's
  visual stroke/colour checks remain the isolated actual-layer renders above;
  no high-frame-rate live visual recording was captured. Whitelist appearance,
  no-notch layout and Reduce Motion passed isolated checks, not fresh live runs.
- Backtick hide/show with physical Caps Lock, external/fullscreen display changes
  and lock/wake still need physical acceptance. Browser startup/window restore
  limitations below remain separate and were not bypassed for these UI tests.

## Prior limitations remain separate

Ordinary whole-window deminiaturization can still briefly raise an old Chrome
window. Changing restoration to leave windows minimized needs Logan's decision;
this visual patch does not silently change that contract. Firefox 0.2.29 exact
profile QA is coordinated in Head Chat, with a startup safety-stop under
investigation. Physical keys, fullscreen/external displays and lock/wake are
not established by isolated bitmap or synthetic decoder tests.
