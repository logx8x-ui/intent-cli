# Focus blur implementation and acceptance

## Scope

Requested: blur disallowed windows in native Mission Control and disallowed browser tabs during an intention.

Implemented a visual-only native panel layer in `FocusBlurController.swift`, tied to the existing enforcement session lifecycle. Panels ignore mouse input, do not activate, use behind-window AppKit visual effects, and expire after 350ms without refreshed geometry. Leisure does not start this layer. Session cleanup removes it. Browser geometry comes from the existing bounded tab scanner, with a separate visual cache that excludes ambiguous allowed/forbidden duplicate sidebar titles. The focused browser window is the current browser coverage boundary; other background browser windows are not yet covered.

Mission Control discovery is restricted to Dock's `mc` accessibility subtree. Known window titles are matched against normal window owners and the current permission policy. Mixed/unknown ownership stays clear. Browser-window decisions inspect the visible active tab against the guard's allowed subset. Spaces thumbnails, unknown titles, and inaccessible elements are skipped. This does not guarantee every forbidden tile can be mapped.

No browser extension package or permissions were changed. No new input interception was added. Counts-only scanner diagnostics live in `~/.intent/native-tab-click-diagnostics.json` and `~/.intent/focus-blur-diagnostics.json`; no page contents, titles, URLs, screenshots, or raw mouse positions are recorded there.

## Verification

- Final `swift run IntentCoreSpec` passed. Added checks for unknown/ambiguous tile exclusion, coordinate conversion across displays, and invalid geometry rejection.
- `npm run test:extensions` passed Firefox and Chrome rule/background tests and reconnect/idle assertions.
- Production CLI/app/native-host builds passed through `scripts/install-dev.sh`.
- Development app installed at `~/Applications/Intent.app`; strict deep signature verification passed. Existing saved data retained.
- A temporary Chrome window containing example.com and example.org was created. Cmd+G selection started a temporary session with exactly one Chrome tab allowed. The first session finished through File → Finish Intention, showed Save, and was discarded.
- The first browser screenshot did not establish visible blur. Added diagnostics showed `not-frontmost-browser` despite CUA controlling the Chrome window. This distinguishes background UI automation from a real foreground-browser test.
- Native Mission Control inspection through CUA again timed out. No successful native Mission Control screenshot or blur alignment was established.

- Final diagnostic session was ended through File → Finish Intention and discarded. The two-tab QA window was closed; original Chrome windows remain. Browser rules were confirmed inactive afterward.

## Remaining acceptance

Physical foreground-browser and Mission Control tests are required. Neither rendered browser blur nor native Mission Control blur is acceptance-passed. Also unverified: Firefox/Sidebery blur, multiple screens, tab dragging/scrolling, moving windows, fullscreen transitions, reduced transparency, and rendered cleanup after Safety Stop. Background browser windows and unresolvable native tiles remain implementation gaps, not merely test gaps.

Do not publish this as a completed all-windows/all-tabs feature. The initial pass left source changes local. The follow-up is development source; physical visual acceptance and complete coverage remain separate outstanding checks.

References used for API discovery: [Apple NSVisualEffectView](https://developer.apple.com/documentation/AppKit/NSVisualEffectView), [Apple stationary windows](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary), and [Hammerspoon's Mission Control subtree discovery](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua). No third-party implementation was copied.

## Follow-up: recognisable blur and tab mapping

Logan physically confirmed the initial window masks appeared, but reported that they looked too black and tab blur was not satisfactory. The latest physical-use diagnostics showed seven native tab regions and seven mapped blur regions. This confirms region discovery on that run, not correct appearance or placement.

Changes in this follow-up:

- Replaced forced dark HUD material with a translucent light behind-window material. A thin red outline communicates restriction; larger window masks also show a small “Not allowed” label. Tab masks omit the label. Both remain mouse-transparent.
- Prioritised the focused browser window before spending the bounded scanner budget on background windows, with a main-window fallback when the focused-window attribute is unavailable.
- Discover native tabs inside grouped containers. If only part of the browser tab list is exposed, visual mapping falls back to exact tab titles and Chrome's known memory-usage suffix. Mixed allowed/forbidden duplicate titles are never visually masked by this fallback. Positional click veto still requires a complete native list.
- Inset native tab masks slightly to keep adjacent masks distinct.
- Recognise Chrome AX window titles containing a profile suffix, such as “First page - Google Chrome – Work”. Previously those titles failed matching when multiple browser windows existed.

Final core tests passed, including partial native-tab label mapping, ambiguous-title exclusion, and Chrome profile suffix regression cases. Browser extension regression tests passed. The updated appearance and grouped/partial strip handling still need physical visual acceptance; the earlier user confirmation applies to the previous window mask only. No claim that every hidden/background tab is covered is made.

Final follow-up development installation completed successfully. Strict deep signature verification passed; installed and production app UUIDs both equal `7801389F-06EB-33D4-854F-9CB75ACA2DCB`. CUA opened the updated app and its normal controls were available. No test restriction session was left active in this follow-up. The new frosted appearance is installed but has not been physically visually accepted. This remains a development source change, not a signed public release or complete all-background-window coverage claim.
