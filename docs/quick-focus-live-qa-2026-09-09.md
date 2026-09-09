# Quick Focus development QA — September 9, 2026

Feature baseline: `2ed98ac`. This follow-up adds a File-menu Quick Focus command
with Cmd+G and a menu-bar context-menu entry. The Carbon global registration
remains in place; the menu command also handles app-directed keyboard events.

## Verified on the installed development app

- `scripts/install-dev.sh` completed and relaunched
  `/Users/loganmondi/Applications/Intent.app`; deep, strict code-signature
  verification passed. Existing intentions and schedules were preserved.
- Cmd+G directed to Intent opens the full-screen picker. All 14 running regular
  apps fit on the screen; Chrome tabs appear above the app grid.
- Notes and one Chrome test tab render green outlines. Selecting a tab includes
  its browser. Clicking Chrome selects its nine eligible web tabs; clicking it
  again clears them. Internal extension-management pages cannot be selected.
- Escape cancels without starting a session. Reopening starts with no selection.
- A second Cmd+G started Quick Focus with Notes and one example.com test tab.
  The emitted browser rules contained only that Chrome tab ID.
- Clicking the unselected example.org test tab returned to example.com.
- Closing the selected test tab ended the session safely and presented
  “Save this session as an intention?” with two apps and one website.
  “No, forget it” dismissed the prompt. The remaining test tab was closed;
  browser rules were verified inactive with no selected-tab map afterward.
- The active-session safeguard prevented a second picker/session from starting.
- Chrome's existing unpacked guard was reloaded from this checkout and reported
  version 0.2.6 with the quick-selection capability.

## Automated verification

- `swift run IntentCoreSpec`: passed.
- `npm run test:extensions`: Firefox, Chrome, and idle-work tests passed.
- Release builds of Intent, IntentApp, and IntentNativeHost: passed through the
  development installer. The Command Line Tools XCTest-path warning was
  nonfatal; the explicit executable spec above passed.
- `git diff --check`: passed.

## Not verified / remaining limitations

- Physical global Cmd+G from another app and physical foreground-app blocking
  were not verified. App-directed automation did not trigger Carbon shortcuts;
  the newly added in-app command route was exercised successfully.
- Intent does not have Screen Recording permission here. The icon-based picker
  was visually verified, not live window previews. No privacy permissions were
  changed.
- The installed Firefox guard remains 0.2.5. Multiple native temporary-add-on
  loader attempts using both the manifest and packaged 0.2.6 ZIP returned to
  “Temporary Extensions (0)” without loading the update. AMO signing credentials
  were unavailable. Firefox is explicitly refused by Quick Focus instead of
  starting a session with an incompatible guard. Firefox live selected-tab
  enforcement remains unverified; its automated tests passed.
- Save-prompt presentation and discard were tested live; persistent Save and
  subsequent restart of that saved intention were not tested live.
- This is a local development installation and source update, not a signed,
  notarized public app release or a signed Firefox release.
