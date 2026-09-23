# Hide distractions and movable lists — 23 September 2026

## Changes

- Recent intentions and Saved lists have separate drag handles and remembered, screen-relative positions. The workspace uses the free regions on all sides of the list; previews retain their shared proportional scale and animate into place. Movement respects Reduce Motion. Right-click the handle to reset position. This is Intent's layout, not control of Apple's private Mission Control implementation.
- Settings offers **Hide (preview)** and **Blur**. Hide is the experimental default requested by Logan; switching to Blur takes effect on the next session.
- Native hiding owns only the app/window visibility it changed. Already-hidden apps and already-minimized windows remain untouched. Exact process launch identities and window IDs scope the local recovery journal. Finish/Safety Stop restores owned visibility; startup recovers interrupted ownership. Windows that cannot be safely identified retain blur enforcement.
- Firefox 0.2.16 uses tabHide with session ownership markers, which follow a tab across browser restarts. Preexisting hidden tabs stay hidden. Pinned/capturing tabs remain protected by existing enforcement instead of being unpinned or interrupting calls.
- Chrome 0.2.16 parks blocked, unpinned, ungrouped tabs in a minimized holding window, preserving their live contents and original position. Entirely blocked windows are minimized rather than emptied. Finish restores surviving original windows. If the original window was closed, or Chrome restarted, the holding window is revealed; no guessed/recycled IDs are used to move unrelated tabs. Pinned/grouped/split tabs and private windows use existing blocking fallback.
- Hide mode never quits a newly launched blocked app or closes session resources on finish. Newly created blocked tabs are preserved too.
- The development installer now updates the embedded native helper and both extension-source folders, preventing an old helper inside the app from overriding the newly built helper at startup.
- Release-readiness validation accepts the current immutable, version-matched Firefox release assets as well as the older release layout.

## Automated verification

- Swift core, purpose matching and account suites: passed. New geometry tests cover off-screen dragging, central placement and preview exclusion; rule persistence retains the Hide preference.
- Firefox/Chrome rules/background, popup status and reconnect/idle-performance suites: passed.
- New shared tab-visibility tests: ownership, pre-hidden/pre-minimized resources, mode reversal, multiple blocked tabs, all-blocked windows, original-window removal, concurrent start/stop serialization, worker recovery, browser-restart recovery and storage failure.
- AI service: 14 tests passed.
- Download catalog and kits, QA packaging, development/public update-channel packaging: passed.
- Firefox lint: zero errors, warnings or notices.
- Native-host protocol, fresh snapshots in both browsers and performance checks passed (peak RSS 8.0 MiB); fresh-install reset/update preservation and QA-profile isolation checks also passed.

## Release gates still requiring actual evidence

Do not confuse these source/build checks with certifying every Mac/browser configuration.

- Install signed Firefox 0.2.16 and verify tab hiding/restoration in Logan's normal profile. CLI signing credentials are absent; the developer hub is signed out in Chrome, and its Firefox session could not be checked after the Mac locked. The source ZIP is not a permanently installable signed XPI.
- Verify Chrome 0.2.16 is actually running after the local helper/source update, then test a complete live tab session.
- Physical single/double-key timing, trackpad Spaces/Mission Control, multiple displays, fullscreen and actual sleep/reboot remain a hardware acceptance matrix.
- Real email verification/delivery, a second account's data isolation, and the public update/install path require separate release/environment acceptance. Unit tests do not establish those external outcomes.
- Passcode entry/reset is user-owned credential interaction; automated QA does not create a real user passcode.

## Product judgment

Hiding is worth testing because the workspace becomes quieter. Keep it optional until testers confirm they understand that their work has only been put aside. Recovery must remain obvious and non-destructive; Chrome's extra holding window and protected-tab exceptions mean this should stay a preview setting for now.

References: [Firefox tab hiding](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/hide), [Firefox persistent tab identity](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/sessions/getTabValue), [Chrome Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs).

## Final installed evidence

The final release builds and data-preserving development installation passed.
Deep/strict code-signature verification passed. The installed app's Mach-O UUID
matches the source build: `EE40000A-745C-37EA-A903-105AC6E96EC8`; the embedded
native helper matches `F2D918A6-8B0C-3A49-8EE5-CF48F8867648`. The development
updater opt-out remains enabled. Both packaged visibility modules exactly match
source. Chrome's actual heartbeat reports 0.2.16 and the hide capability; Firefox's
actual normal-profile heartbeat remains 0.2.14.

macOS locked before the new installed UI could be exercised. The user has been
asked to unlock it. No new live drag/hide/restore/quit/Spaces acceptance is claimed.
Final browser rules are inactive and there are no pending hidden native resources.
No QA intentions or history entries were created during this pass.

The naming prompt now makes room for the movable history panel too; the recovery
button lives inside that panel rather than overlapping it as a separate floating
card. The source, automated verification and installed artifacts are ready for
review, but this is not a completed ten-tester release gate or a zero-bug claim.
