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
