# App stacks and website controls — 2026-09-29

## Implementation

- Stable, source-position-aware app clusters, staggered same-app windows, most-tabs-first browser stacks, explicit promotion and expanded window selection. Layout work runs off the main thread; Reduce Motion is respected.
- Individual window permissions survive save/replay conservatively: missing exact targets require review, never whole-app permission. Unavailable synthetic window placeholders cannot masquerade as native window IDs.
- Inline Instagram and YouTube feature policies, shared across a site's selected tabs within an intention. New intentions default to Instagram messages and YouTube normal videos/search; legacy saved intentions retain their settings.
- Chrome network rules and Firefox request vetoes enforce route restrictions; page guards remove disabled surfaces and cover SPA changes. Policies are acknowledged before the native focus lock begins.
- Browser snapshots, commands, selected-tab IDs and policy receipts are partitioned by browser session/profile. Same-numbered tabs in different profiles cannot share permissions accidentally.

## Verified

- Swift core, purpose matcher and account specs pass.
- Chrome/Firefox extension behavior, idle work, popup, tab visibility and website-feature route/precedence/parity tests pass.
- Native-host tests, snapshot refresh, performance and multi-profile routing/receipt tests pass.
- Firefox extension lint: zero errors, notices or warnings.
- Release app/native-host builds and development installation succeeded. Code signature verification succeeded.
- Final source and installed app UUID match: `4931B77E-7E24-37A9-8BF9-80F746F0546D`.
- Live overview displayed natural separate app stacks. Live Notes selection moved from 0/2 to 1/2 to 2/2 independently, with expansion and promotion.
- Live Firefox 0.2.21 tab discovery worked; selecting the test YouTube tab did not select other tabs. Website configuration chip appeared.

## Live findings corrected

- Initial empty-state layout had remained cached, displaying the grid fallback. Replaced lifecycle callbacks with an input-keyed asynchronous task; natural stacks were then verified visually.
- Removed rear-window captions that overlapped the front caption.
- Website defaults did not automatically expand in the installed UI. Replaced their lifecycle callbacks with an input-keyed task and rebuilt/installed. This final correction has not yet been rechecked live.

## Still outstanding

- The Mac locked during UI QA. No test intention was started. Final site-checkbox rendering, live route/SPA blocking, finish/save restoration, physical shortcut/swipe behavior and animation frame pacing remain unverified. Automated tests do not establish zero-frame leakage or zero lag.
- Chrome Browser Guard 0.2.21 was connected. Firefox 0.2.21 was loaded temporarily through about:debugging for QA; its permanent default-profile copy is still 0.2.20. A Mozilla-signed 0.2.21 XPI is required for durable deployment. Signing credentials were not configured; security requirements were not bypassed.
- Existing third-party Firefox distraction extensions were left unchanged; visual blocking must be attributed carefully during follow-up QA.
- Disposable native Firefox YouTube and about:debugging tabs, and a Chrome extension-inspection tab, may remain open because lock prevented UI cleanup. No saved QA intention was created.
- Build tools emit an XCTest-path discovery warning with Command Line Tools, but executable Swift specs and release builds complete successfully. Installation used system Python via `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` to avoid the unrelated Homebrew Python 3.14 pyexpat failure.

No published app or extension release was created. Another Intent chat has a separate worktree and may later replace the installed development build; verify UUID before continuing QA.

## September 30 follow-up — retirement and unlocked QA

- Integrated session-additions commit `75c5895` before changing the primary checkout, preserving stopwatch, Spotlight and flexible sessions.
- Deleted `IntentHomeView`; removed the legacy launcher hotkey registration and callback. Cmd+G is rejected as a finish shortcut and old saved Cmd+G finish bindings migrate to the default. Menu/reopen now routes to the workspace or running controls. Settings, account/onboarding and finish/save dialogs use a compact utility host; plain sessions retain accessible finish controls.
- Unsaved workspace sessions again offer save on successful completion, without automatically saving QA intentions or changing saved-intention behavior.
- Installed release app and source UUID match: `41469815-2DC5-3B88-9EB3-D2FE9B0FDF18`. Code signature verification passed.
- Live checks: old home absent; synthetic Cmd+G from Firefox left Intent closed; settings General showed only the finish recorder and explicitly stated Cmd+G is unused. Closing settings worked.
- Live Firefox 0.2.22: selected only the disposable calculus tab; website controls expanded with Search enabled and Home/Shorts/recommendations/comments/autoplay disabled. Shorts toggle updated the summary. Disabled Home and direct Shorts navigation stayed on search; a normal video opened. The extension acknowledged the actual active native session before restrictions started.
- Live Chrome 0.2.22 from this exact source directory: independent one-tab selection; disabled Home click stayed on search; a normal video opened. Stopwatch session finished through the File menu and showed the save prompt. Declined saving; injected policy style disappeared. Reloaded Browser Guard after the last content-script edit and ran another session: Shorts chips carried the owned marker and computed `display: none`; finish again showed save, then restored all owned markers/styles. QA video tabs were closed.
- Swift executable specs and the full extension behavior suite passed after the final edits. These observations supersede the earlier locked-Mac blockers for site-checkbox rendering, the tested YouTube routes and finish/save restoration.
- Remaining acceptance limits: physical shortcut/swipe/event-tap behavior, animation frame pacing and zero-frame tab leakage are not established by synthetic UI actions. Instagram authenticated SPA behavior was not live-tested; its allow/block route matrix passed in both engines. The last Shorts-chip polish was live-verified in Chrome, not Firefox.
- Durable Firefox deployment is still blocked: default-profile permanent extension is 0.2.20 versus source 0.2.22; the connected 0.2.22 copy is temporary. A matching Mozilla-signed package and restart readback are required. No signature enforcement was bypassed and no published release was created.
