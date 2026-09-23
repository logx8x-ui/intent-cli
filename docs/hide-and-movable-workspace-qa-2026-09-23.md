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

- Firefox 0.2.16 is now approved and signed by Mozilla (version 6508703, file 5052855). Its signed XPI is downloaded locally. Installation is waiting for Logan to approve the new recently-closed-tabs and hide/show-tab permissions; normal-profile Firefox hide/restore remains unverified. The public update feed has not been advanced from 0.2.14.
- Chrome 0.2.16 normal-profile tab parking/restoration passed the live check below. Other profiles and browser-restart recovery still require live acceptance.
- Physical single/double-key timing, trackpad Spaces/Mission Control, multiple displays, fullscreen and actual sleep/reboot remain a hardware acceptance matrix.
- Real email verification/delivery, a second account's data isolation, and the public update/install path require separate release/environment acceptance. Unit tests do not establish those external outcomes.
- Passcode entry/reset is user-owned credential interaction; automated QA does not create a real user passcode.

## Product judgment

Hiding is worth testing because the workspace becomes quieter. Keep it optional until testers confirm they understand that their work has only been put aside. Recovery must remain obvious and non-destructive; Chrome's extra holding window and protected-tab exceptions mean this should stay a preview setting for now.

References: [Firefox tab hiding](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/hide), [Firefox persistent tab identity](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/sessions/getTabValue), [Chrome Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs).

## Installed follow-up — 24 September 2026

- Fixed a live drag failure in both list panels: use global gesture coordinates and persist the final translation instead of a stale rendered frame. Both Recent and Saved panels moved successfully; window previews rearranged around them, and saved relative coordinates changed. Recent position survived a reinstall. Saved reset-position action also passed.
- Added header clearance for the named intention to avoid overlapping the first preview.
- Native visibility work now runs on the main thread. A bounded recovery retry re-reads asynchronous macOS visibility state; a generation guard prevents old retries from touching a newer session.
- Live native sessions hid six disallowed apps while preserving the selected Reminders app and the always-allowed apps. Normal finish and Safety Stop restored all six and cleared the recovery journal. Cmd-Q during an active test also released all owned visibility; the app was subsequently available again. Actual OS shutdown/reboot remains untested.
- Chrome normal-profile heartbeat reports 0.2.16. With a disposable Example Domain tab selected, five original tabs moved into a holding window. After finish, the seven original tab IDs survived, the holding page was gone, and native Chrome UI showed the original tab order in the original window. Grouped test tabs exercised the documented fallback. Inactive Browser Guard intentionally clears its tab snapshot, so the final UI and live browser inventory were used instead of interpreting that cleared snapshot as tab loss.
- Swift core, purpose and account suites passed again, including 100 repeated gesture sequences and layout checks for 1–50 windows. Release build and development install passed; strict/deep code-signature verification passed. Installed app UUID: `C6FFCC09-4B40-3933-A9DC-B7E61EFD44AB`.
- No active restrictions or hidden native recovery entries remain. Disposable Chrome example tabs were closed. QA session records are backed up and removed separately from user intentions.

This is verified local development progress, not a public app release or a completed ten-tester gate. Firefox permission/install acceptance, physical gestures/multiple displays/sleep/reboot, email delivery/account isolation and public update acceptance remain explicit gates above.
