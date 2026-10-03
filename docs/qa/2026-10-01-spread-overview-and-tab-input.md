# Spread overview and browser input — October 1, 2026

## Changes

- Removed the automatic expanded app sheet, including its Done/Escape panel and four-window preview limit.
- Every window has a direct overview preview. Multiwindow groups use a shared preview scale, staggered partial overlap and larger allocated footprints; hovering changes only front-to-back order.
- Window captions have their own bounded, clear rectangles below previews. Long titles truncate at the end, have no backdrop, and cannot collide with neighbouring previews. Recent intentions remain a layout obstacle.
- Hidden-tab sessions leave tab/sidebar row clicks to Browser Guard. Native masks are restricted to the actual receiving window; a changed active title cannot inherit a stale full-window mask. Tab searches permits a fresh tab/window shortcut even from a blocked browser window.
- Both extensions now permit direct typed/search navigation under Add as you go and ordinary blacklist policy while retaining explicit bans.
- Background page loads and background-created search tabs no longer replace the user's recovery tab.
- Stopping enforcement precedes tab restoration. Rule applications are serialized and revision-guarded so a delayed old restore cannot overwrite a newer intention.
- Browser Guard source and bundled native-host version advanced to 0.2.25.

## Verification completed

- IntentCoreSpec, PurposeMatcherSpec and IntentAccountSpec passed.
- Layout assertions cover all window IDs, equal scale, caption/preview collisions, staggered exposure, nine-window groups and stable geometry on tab-count changes; existing field-of-view coverage includes 1–50 windows.
- Repeated shortcut sequences (100), native input policy regressions, and app persistence suite (33 assertions) passed.
- Firefox/Chrome rules and background suites passed, including reproductions of all three browser defects above before their fixes.
- Browser idle work, popup, tab visibility/restoration, suspended worker, website features, native-host behavior/performance/profile routing/snapshot freshness all passed. Native host peak RSS: 8.3 MiB.
- QA packaging, Chrome/Firefox profile isolation and development/public channel tests passed. Release readiness passed. Firefox lint: zero errors/warnings/notices. Both 0.2.25 extension archives built.
- Release app built and installed with matching executable UUID BF77B9C7-1F75-3BDB-A078-1401D6E0E88B; strict/deep codesign passed.
- Chrome's loaded heartbeat reports 0.2.25. Firefox remains permanently installed at 0.2.24.

## Required live acceptance

The Mac was locked on both computer-use attempts. An unlock request is pending. Do not label this tester-ready or physically verified.

After unlock:
1. Upload the prepared 0.2.25 Firefox archive to Mozilla, obtain/install its signed XPI, and confirm the default profile connects as 0.2.25 after restart. Signing credentials are unavailable to the CLI; use the authenticated developer portal. No Firefox signing checks may be disabled.
2. Inspect the actual overview on the MacBook: Notes/Firefox multiwindow spread, exposed previews, readable captions, hover layering, no app sheet, no missing windows, history drag/reflow, browser tab picker.
3. Rapidly click selected tabs and fresh Tab searches tabs across Firefox/Sidebery and Chrome windows; verify old search tabs stay unavailable and fresh searches cannot open websites.
4. Verify Add as you go starts only selected resources then allows new tabs, windows, apps and typed navigation; explicit bans remain blocked.
5. Exercise Timer/Checklist/Stopwatch collapse, hide/restore, drag and modifier shortcuts; optional naming, saved-slot order/delete/replay; finish by shortcut, timer and checklist while another app stays foreground.

The beta-installer test was invoked without its required prepared-kit argument and therefore did not run; it is not included in the passing checks. No public app release/update feed was changed. Unrelated working files and saved user data were preserved.

## October 3 continuation

- Confirmed the installed development app at `~/Applications/Intent.app` still has UUID `BF77B9C7-1F75-3BDB-A078-1401D6E0E88B`, matching this change. The active Firefox profile's permanent package and heartbeat remain 0.2.24; Chrome's heartbeat is 0.2.25.
- Re-ran `npm test`: Swift specs, both browser rules/background suites, tab visibility and restoration, native-host behavior/performance/snapshot/profile checks, AI service tests, release readiness, and Firefox lint all passed. Lint reported zero errors, warnings, or notices.
- `swift build -c release --product IntentApp` passed. `scripts/test-qa-persistence.sh` passed 39 isolated-model assertions; this does not establish live UI acceptance.
- Closed the earlier installer coverage gap: prepared an isolated kit using the current installer and signed installed app, then ran `scripts/test-beta-installer.py` with that kit. Fresh install, update/data preservation, reinstall, and system-install migration checks passed without changing the user's installation or data.
- Mozilla's authenticated Firefox portal was reached for uploading 0.2.25. The native file chooser accepted the package path but did not accept automation confirmation; native targeting, direct input, and reconnect attempts did not complete the upload. Chrome's alternate portal required a separate sign-in. A minimal user action request is pending to confirm the already-entered package in Firefox.
- No new application code or public release changed in this continuation. All live acceptance items above remain pending until the signed Firefox update is installed and the actual flows are exercised. Do not describe the app as bug-free or tester-ready from these automated results.

## October 3 signed update and live continuation

- Installed Mozilla-approved permanent Browser Guard 0.2.25 in `ykomjweq.default-release`; `signedState: 2`, active, not temporary. Restarted Firefox normally and confirmed the 0.2.25 connection survived. Installed `background.js` and `tab-visibility.js` match the checkout byte for byte. Firefox also applied its pending vendor update to version 157 during restart.
- Inspected the installed overview: three Firefox windows use equal preview scale and staggered overlap; Notes windows select directly without the old expanded sheet; captions have no backdrop; Finder stays in the always-allowed area and is absent from the grid.
- In a dedicated Firefox test window, selected two Example Domain tabs with Tab searches and Stopwatch. Ten alternating Sidebery clicks reached the correct selected tab; six more alternated between a selected tab and a fresh Google search. A search opened before the intention was unavailable, a fresh search was usable, and navigating that fresh search to `example.net` was rejected. Stopwatch collapsed to a bar and expanded again.
- Reproduced delayed completion focus loss with multiple Firefox windows: the selected QA search initially remained visible, then another Firefox window surfaced. Added content-free restoration diagnostics and found AX error `-25204` (`cannotComplete`) about 0.15 seconds after completion. The guard had treated this temporary failure as a closed/minimized target.
- Restoration now identifies the actual visible WindowServer window with an unambiguous AX frame/title match, handles finishing from Intent's own controls, and retries temporary AX failures within the existing five-second transaction. It never activates an app after a failed exact-window raise. Real input, unrelated activation, closed/minimized/off-screen windows and hidden/terminated apps still stop preservation.
- Repeated the same menu-finish case on installed UUID `A92EDFB1-8A99-3670-B3F4-63D8AD45EE82`: Firefox's AX responses were unavailable for roughly 1.6 seconds; preservation retried, raised the original window and completed. The same QA search remained visible after the transaction ended. Repeated with a one-minute Timer plus Stopwatch; expiry cleared rules and controls, restored hidden resources, and left that same Firefox page visible. No completion/save screen appeared.
- `IntentCoreSpec` passed after the change, including target-selection/cancellation checks. Release builds and development installation passed; source/installed executable UUIDs match and strict/deep signature validation passed.
- Native CUA clicks do not exercise the physical event-tap path (`mouseDownEvents` stayed zero), and an app-targeted backtick injection did not toggle the controls. These are automation limitations, not passing physical-input acceptance. Actual trackpad fluidity, hardware backtick/Caps Lock, fullscreen Spaces and screen-edge dragging remain distinct acceptance items.
- Remaining live checks continue below; no public GitHub release or update feed has been changed.

### Rule delivery and additions follow-up

- Reproduced a native-helper race in an isolated process: an incoming heartbeat could consume a changed rules-file signature before the directory watcher, leaving the browser without the stop update. The old binary failed the new regression. The helper now publishes effective changes discovered by heartbeat/snapshot handling, with unchanged updates still deduplicated.
- Firefox/Chrome start and stop races, exactly-once delivery, timestamp-only renewals, unchanged silence, baseline native-host tests and 50,000-heartbeat performance checks passed (8.1 MiB peak RSS). Installed matching helper bytes and verified both browser connections restarted on the new helper.
- Live Firefox Add as you go started with only the selected search tab. Existing unselected tabs stayed put aside; a new tab, typed navigation to a different domain, a new window and opening Calculator were permitted. Checklist collapse/expand preserved the task and ticking it cleared active rules and the hidden-resource ledger.
- This exposed another focus case: two Example Domain windows had identical titles/frames. The unique-match guard safely refused to guess, but restoration then promoted a different Firefox window. Window identity resolution is being refined before that completion case can pass.

### October 3: duplicate windows and a crash caught during QA

- Reproduced a real Intent crash while editing a checklist in Mission Control. `IntentApp-2026-10-03-181431.ips` identifies `intent.spotlight-selection` calling system-wide `AXFocusedUIElement`; serialization entered Intent's own SwiftUI field editor on the worker queue.
- Removed that system-wide Spotlight probe. The watcher now queries only verified, on-screen Apple Spotlight processes, rejects system-wide/own-process AX elements before reads, and retains the AXSystemDialog fallback. Repeated eight checklist edits and dismissal survived; actual Apple Spotlight opened via the overview button and status changed `native-search-ready` → `closed` on dismissal.
- Improved finish-window identity when Firefox windows have identical titles/geometry: hit-test the exposed WindowServer window through public AX, validate ownership/frame/title and unchanged stacking, then fall back only to a unique match. No guessed window activation.
- Installed UUID `E3920F73-F160-318D-908E-4E81E8B0D1B7` matches release source; deep/strict signature verification and IntentCoreSpec passed.
- Live checklist completion with multiple Example Domain windows now resolved `visibleHit`, survived transient Firefox AX timeouts, and completed its five-second transaction. The exact QA URL `example.com/?intent-qa=duplicate-front` remained foreground afterwards. No save/completion screen appeared and browser rules became inactive.
- These are native UI automation checks; physical keyboard timing/trackpad fluidity are not inferred from them.

### October 3: duplicate-title browser picker

- Reproduced the empty "Waiting for tabs" picker with three Firefox windows sharing Example Domain titles and geometry. Firefox window focus commands alone did not activate the macOS app, so native/extension focus confirmation never agreed.
- The resolver now activates only the existing PID owning the requested native window behind the floating overview. It probes matching-title candidates first and retains both native and extension identity checks. Resolver-specific IDs prevent cancelled lookups from restoring focus over replacements; returning to Intent respects a move to an unrelated app.
- Installed release UUID `11411AAD-55ED-3E44-ADC7-BB5F907F3E8A`, deep/strict signature verified. All three duplicate-window tab pickers loaded independently: five tabs for the original QA window, one tab for each later QA window. No expansion sheet was added.

### October 3: Chrome session checks

- Matching Chrome profile/Browser Guard 0.2.25: two selected tabs plus Tab searches/Stopwatch. Eight native tab-strip switches reached the correct selected pages, then six switches alternated with a fresh Google search. The pre-existing Google search was parked. Attempted navigation from the fresh search to example.net was rejected; the search tab remained available at its original Google URL.
- Add as you go off/on were exercised separately. With it on and Tab searches off, only the selected search tab remained initially; a new example.net tab, navigation to example.org and a new example.com window worked.
- Chrome's AX window title includes the browser/profile suffix, unlike WindowServer's page title. The finish guard now uses the already-tested browser-title normalization while retaining PID/frame and hit-test/uniqueness checks.
- On installed/source UUID `DC43C081-303D-3255-8772-817F18931AF2`, menu completion resolved `visibleHit`, restored resources, completed the guard and kept the exact new Chrome QA URL in front. Active rules were false afterwards. No finish/save screen appeared.
- Opening Settings while active showed session policy controls disabled, so the tested session cannot enable Add as you go midway through its run. The Settings window was opened deliberately for automation's menu access; no settings were changed.

### Final review and acceptance boundary, October 3

- Hardened duplicate-window lookup against a page changing title during loading: matching-title candidates are tried first, followed by the remaining active windows. Existing minimized/off-screen preview owners are located without launching a new process. Before activation, the resolver rechecks its request identity, selected preview, panel visibility and current foreground, so a late snapshot cannot take focus after cancellation or an unrelated app switch.
- Prevented outline/blur background workers from querying Intent's own accessibility window through `WorkspaceWindow.focused`; its own window uses WindowServer ordering. This extends the boundary established by the reproduced Spotlight crash fix.
- Final installed executable and release source both have UUID `04AA6EC2-7ECA-3C34-A77C-67AF7CCDB01E`; deep/strict codesign passed. Swift suites passed, and IntentCoreSpec passed again after the final native guard changes. No new Intent crash report appeared during subsequent live QA.
- Final-build duplicate-title pickers worked in Chrome and Firefox. A simultaneous blacklist session hid the two explicitly selected QA tabs: both were absent from permitted snapshots but present in full snapshots, confirming they were retained rather than deleted. New example.org navigation worked in each browser. Normal finish cleared active rules and completed its focus guard.
- Browser Guard 0.2.25 is permanently signed and active in the real default Firefox profile. The matching Chrome connection is the Logavix/Default profile. The separate Chrome Intent profile used for Instagram does not currently have Browser Guard; its enforcement is not claimed as tested.
- Physical input acceptance remains outstanding: real double-backtick selection, rapid trackpad tab clicks, Caps Lock/backtick, held-number sequences, screen-edge HUD dragging and fullscreen/Spaces. Native app-targeted automation does not traverse the global event hook. Logan was asked for a short real-input check after the automated live cases; this is not a zero-bug/tester-ready declaration.
- No website changes, JEV integration, public GitHub release, or update-feed mutation were made. Saved user data was preserved.
