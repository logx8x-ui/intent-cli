# October 9: finish restores the workspace; compact native finder

## Report and cause

Logan reported that apps/windows stayed hidden or minimized after an intention.
The GUI finish spec deliberately persisted `onUserReveal`, so restoring only
when the user manually reopened an app was expected by the previous policy.
The October 9 request supersedes that policy: restore Intent-owned changes while
keeping the current native window and browser tab in front. Do not open apps that
were closed, or unminimize windows the user had already minimized.

## Changes

- GUI finish and interrupted-session recovery request `restoreOwnedWorkspace`.
  At recovery this promotes all existing Intent-owned entries, including older
  deferred entries, to automatic restoration. Narrow failed-start cleanup keeps
  its existing ownership boundary.
- Existing process identity, exact native-window binding, browser parking closure
  receipts, newer-session guards, durable retries, and finish-focus preservation
  remain in force. A failed/unknown restoration retains its record.
- Finder observation is scoped to the exact finder window, tab, browser session
  and overview generation. Search pages stay open; a completed website page is
  committed automatically after main-frame URL validation. Commit rechecks that
  URL. Manual Add and Cancel remain available.
- Both extensions verify the new finder window's actual compact geometry and
  correct it once if the browser ignored the creation bounds. Existing windows
  are never resized. The native app validates the returned dimensions.

## Validation

The complete `npm run test:changed -- --base 956f88c` gate passed before install,
including session UI, core Swift, release build, extension suites, native host,
AI and lint. The source was stable during this run. Regression coverage includes
old deferred-entry promotion, unknown-state retention, user-visible ownership
retirement, compact geometry, URL races, search pages, 130 observation cycles
without journal growth, cancellation and original-tab ownership.

Initial tested app UUID: `3AD221A7-0B3E-37CF-9B7E-6E3B59B8B385`.
Final installed app UUID after comment/documentation cleanup and a second full
passing gate: `85ECD920-A33A-3E59-9ACE-232BA2B73E3B`.
Installed native host UUID: `6D4BBB92-20B3-3021-AC86-448D1AB83361`.
Firefox daily profile `ykomjweq.default-release` has permanent signed Browser
Guard 0.2.39, active, signedState 2. AMO version 6555628 / file 5099767 was
approved; its four changed JavaScript files match the tested source byte-for-byte.
Chrome's fresh heartbeat also reports 0.2.39 and native finder observation support.

### Installed-app results

| Check | Evidence/result |
| --- | --- |
| Manual Finish menu | Firefox intention hid Spotify, Chrome and Codex. Finish restored the current processes' owned visibility and retained Firefox in front. |
| Original geometry | Firefox window 102, Spotify 63 and Chrome 65 were visible afterward with identical pre-session bounds. |
| Timer expiry | One-minute Timer ended automatically; original windows were visible with unchanged bounds; Firefox and its test tab remained current. Repeated on final UUID 85ECD920 with the same successful result and the pre-run browser tab still current. |
| Screenshot tool | Apple's Screenshot toolbar opened during the timer session; `com.apple.screencaptureui` remained unhidden; its Close button worked. No Always Allowed change. |
| Finder size | Firefox finder window 413 was 760 x 560. Original Firefox window 102 remained 1710 x 1073 at its previous position. |
| Search versus website | Google results remained in the compact window. Visiting an Example Domain URL moved exactly that tab into the original window. |
| Automatic return | Repeat direct-URL test returned to Intent's overview with the new Example Domain tab selected and Run enabled. |
| Chrome finder | Logavix profile opened its own 760 x 560 finder, then returned with the loaded website selected. Closing the overview while a second unused finder was open cancelled that finder and preserved the two existing QA tabs. |
| Overview layout | Installed overview screenshot shows bottom captions above the modifications. Isolated rendered layout checks cover measured chrome and 800x600, 1280x800, 1710x1112. |

Local evidence: `~/.codex/artifacts/intent-20261008/oct9-*.json`,
`oct9-combined-gate.log`, `oct9-idle-final-gate.log`, `oct9-final-install.log`. These are local-only QA artifacts.

## Acceptance boundaries and pending work

- Synthetic Shift+grave did not trigger the global finish shortcut. Manual menu
  and timer results are not physical-key acceptance.
- Screenshot toolbar accessibility passed; physical Command-Shift-3/4/5/6 and
  native Mission Control click delivery remain unverified by this automation.
- A pre-minimized Calculator negative-control attempt could not establish the
  native minimized state. A subsequent CUA Raise action crashed the separate
  SkyComputerUseService (not Intent or Codex); UI input stopped for recovery.
  This check is not counted as passed. The service recovered on the next read;
  Calculator was quit afterward, returning it to its pre-QA stopped state.
  Only the QA-created browser tabs/window were closed during cleanup.
- Four old recovery records refer to PIDs now reused by background daemons.
  They were not manually edited or treated as current apps; the new session's
  own live-process records were retired on finish. Conservative unknown-identity
  retention remains in effect.
- The Instagram 32-combination policy tests and route/component fixes are
  covered separately in `2026-10-08-instagram-feature-contract.md`. Normal Home
  Stories tray acceptance remains pending: the user's Unscroll extension redirects
  Home to the Following feed, and no permission to pause it has been received.
- The first automatic finder run moved the tab successfully, but its final
  overview state was not observed. A second full run explicitly verified the
  selected tab and returned overview. Do not infer why the first view was absent.

## Layout rationale

The packing algorithm now receives the measured header and footer exclusion
areas, and each preview's full caption footprint. This follows the separation
between available space and child measurement described in [Apple's SwiftUI
layout session](https://developer.apple.com/videos/play/wwdc2022/10056/) and the
legible spacing principles in [Apple's layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout).
It preserves existing common preview scale and stable group positions rather
than changing to a smaller fixed grid. [Ordered layout research](https://www.cs.umd.edu/~ben/papers/Bederson2002Ordered.pdf)
and [overlap-removal constraints](https://bridges.monash.edu/articles/report/Fast_Node_Overlap_Removal_in_Graph_Layout_Adjustment/20365455)
support treating ordering/stability and geometric non-overlap as separate
constraints. This is a design inference from those references, not a claim that
Apple's private Mission Control algorithm is reproduced.

## Final gate accounting

The intermediate `oct9-final-gate.log` run failed its isolated notch activation
assertion while live UI actions were also in progress. It is not a pass. UI
actions were stopped, then the complete gate was rerun against the same source
fingerprint `6999ef733ad49e6995101d83bd7e62000e9d662394013bf354f54717c9dfa3f9`.
`intent-change-gate-sh9CiA/result.json` reports `automated-pass` for gate, session,
Swift, extensions, native host, release, AI and lint. No production code or
regression assertion was changed to obtain that result.
