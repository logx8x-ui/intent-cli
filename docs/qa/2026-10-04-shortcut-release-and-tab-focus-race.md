# October 4: shortcut release and delayed tab recovery

## Verified fixes

- Mission Control's prefix key could remain held if backtick was released with Command/Shift/Option down. The release now clears the hold, consumes the matching key-up, and does not close the overview. Subsequent plain numbers select saved slots; Escape closes without clearing the draft. New regression failed before the change and passes after it.
- Firefox and Chrome tab recovery checked session/activation state before `tabs.update`, but could still raise a browser window after that asynchronous call completed even if the intention had ended or the user clicked another allowed tab. Recheck immediately before window focus. Recognize the recovery's own activation event rather than treating it as an unrelated click.
- Both browser harnesses now emit an optional realistic activation event during a tab update and hold its completion. Three scenarios cover finish during IPC, a newer allowed click, and normal recovery's own activation. Original source fails the finish regression; an intermediate revision failed the own-activation case; final source passes all three in both browsers. A bounded watchdog prevents a missing activation from silently ending a test.

## Verification

- IntentCoreSpec regression failed before the prefix fix and passed afterwards.
- Full Swift suite passed: IntentCoreSpec, PurposeMatcherSpec, IntentAccountSpec.
- Extension suite passed: Firefox/Chrome rules and background, install/profile fixtures, idle reconnect work, popup state, tab restoration/serialization, website feature policy.
- Native-host suite passed: protocol, performance (8.1 MiB peak RSS), snapshot/rule delivery, profile isolation and command routing.
- Mozilla lint: zero errors, warnings and notices. Release-readiness consistency test passed; this does not establish release acceptance.
- Release development build installed with `scripts/install-dev.sh`; deep strict signature verification passed. Installed IntentApp UUID: `1BFD7BE8-0613-3EC7-BA9C-7A9863A95FD3`.
- Chrome's existing idle-update mechanism loaded final Browser Guard 0.2.28, confirmed by heartbeat. Its extension settings UI was blocked by browser automation policy; no workaround was attempted.
- Live Mission Control opened, its Chrome tab picker resolved the existing QA window, and selected-tab/Tab searches/Stopwatch setup worked. The Mac locked before Run completed; active-session acceptance is NOT claimed for this revision.
- Final passive state: browser rules inactive. No test session remains running.

## Remaining acceptance / package handoff

- Final Firefox archive: `dist/firefox/intent_browser_guard-0.2.28.zip`. Default Firefox still runs permanent signed 0.2.25. Submit/sign/install 0.2.28 through the authenticated Mozilla portal and verify after restart once the Mac is unlocked.
- Intermediate 0.2.26 was uploaded for unlisted signing as AMO version 6538562, before the own-activation regression correction. Do NOT install/distribute that intermediate package. It was not added to any public release or update feed.
- Resume actual Firefox/Chrome active-session tab lifecycle checks and completion-focus checks on final matching packages.
- Physical double-backtick, Caps Lock chord order, held-number input and physical mouse event interception remain unverified. Synthetic UI actions and pure state-machine tests are not physical acceptance.
- User's real tabs, saved intentions and unrelated `.superpowers/` and `weppy-project-sync/` files were preserved. Website, public releases and update feeds were not changed.

## Bounded independent follow-up review

- Reviewed event-tap generation cancellation, Caps Lock physical-vs-latched handling, repeat suppression, queued marking and run cancellation; no additional independently reproduced shortcut defect in this pass. Physical event delivery is still outstanding.
- Reviewed close/move notifications, exact tab browser-session identity, reconnect ownership, delayed recovery and search-ledger/visibility restoration. Found one additional race: a window-focus loss does not necessarily activate a tab, so an in-flight recovery could still raise the browser after switching to another app.
- Added the `leave-browser` regression to both browser harnesses; both failed against b9f6f96. A window-focus revision now invalidates pending recovery before activation and before raising a window. All four cases (finish, newer tab click, leave browser, own activation) pass in both browsers.
- Corrected final source/package version is 0.2.28; 0.2.27 is superseded. Firefox 0.2.28 still requires signing/install after unlock. No attempt was made to operate the locked desktop or bypass the blocked Chrome settings page.

| Acceptance | Current evidence |
| --- | --- |
| Modified-backtick release | Failing-before/passing-after Core regression; installed build |
| Tab recovery after finish, newer click, focus loss | Failing-before/passing-after Firefox and Chrome regressions |
| Normal recovery with browser-generated activation | Passing Firefox and Chrome regressions |
| Browser lifecycle/rule/visibility regressions | Extension suite passed |
| Native bridge delivery, profile isolation, performance | Native-host suite passed |
| Physical double-backtick/Caps Lock and click timing | Unverified; unlocked hardware check required |
| Final Firefox package in actual default profile | Pending signing/install; still 0.2.25 |
| Final active-session live matrix | Incomplete; Mac locked before Run |
