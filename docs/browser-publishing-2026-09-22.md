# Browser Guard publishing and outline pass — 22 September 2026

## Firefox

- Submitted unlisted update 0.2.14 to existing Mozilla add-on `intent-firefox@loganmondi.dev`, version record 6504002.
- Mozilla validation: zero errors and warnings; version status Approved.
- Signed XPI file 5048156 downloaded, signature entries and source version checked.
- Published immutable tester asset at https://github.com/logx8x-ui/intent-cli/releases/tag/browser-guard-0.2.14 and verified public download SHA-256.
- Updated firefox-updates.json to 0.2.14 with immutable asset URL and hash.
- Installed signed XPI in normal Firefox profile. Permanent package now matches source; native heartbeat reports 0.2.14. Browser restart not performed during user's ongoing work.
- This is signed self-distribution for testers, not a searchable Firefox marketplace listing.

## Chrome

- Web Store submission ZIP built: dist/chrome/intent-browser-guard-chrome-web-store-0.2.14.zip.
- Google verification completed by Logan. Uploaded and verified draft 0.2.14, then submitted for review with automatic publication enabled. Dashboard confirmed: Your extension was submitted for review.
- Existing public store item ffgfjfpkddgimambgmahlodjjojmjnbc remains on 0.2.5 until review completes; 0.2.14 is submitted, not yet live.

## App changes

- Modifier row maximum width reduced from 880 to 680 points, with 36-point controls, 8-point gaps and adjusted drag destinations. Staged panel height reduced to 46 points.
- Tab outline AX window matching permits unique geometry matches despite stale window titles. Ambiguous geometry still requires title matching.
- AX traversal checks element equality rather than treating hash collisions as identical elements.
- Exact tab-order matching skips unnecessary label reads, preserving the bounded scan budget for selected-tab geometry.
- Release build and IntentCoreSpec passed. Extension suites passed; lint reported zero errors/warnings/notices.
- Installed updated development app at ~/Applications/Intent.app; codesign verification passed. Saved data retained.
- Native CUA could not complete shortcut/visual acceptance after the menu-bar app hid its window. Physical first-mark behavior remains unverified; do not describe it as fully accepted.
