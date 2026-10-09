# T website transfer and saved replay — October 9

## Request and reproduction

T must use the compact real browser, select the visited website, and produce a
working intention. Transfer should animate into the tab menu without flashing
the original browser window. Saved intentions must prepare missing apps and
websites and retain their saved modifications.

Baseline: `9337c64`, daily installed Intent at
`/Users/loganmondi/Applications/Intent.app`, Chrome Logavix profile, Guard 0.2.40.
Live T created `https://example.com/?intent-qa-t-oct9` in a compact Chrome window,
then showed Example Domain selected in Intent. Run failed with “Could not confirm
Chrome’s current windows.” A read-only native inventory showed two Chrome
profiles with New tab windows at the same bounds. T correctly preserved the old
active tab, but startup attempted coverage before activating the selected site.

Preserve DBT's exact current window/tab at Run, all finish restoration rules,
profile isolation, blacklist non-launch behavior, user multi-selection, native
finder cancellation ownership, and existing modifier shortcuts. Do not close
user tabs or erase saved intentions for QA.

## Changes

- Overview Run activates an exactly selected Chrome tab and awaits its fresh
  same-session active/focused confirmation before native coverage. DBT skips
  this entirely. Stale sessions and unselected IDs cannot become a target.
- Finder transfer raises the existing overview before moving its owned tab;
  the original browser stays behind it. A URL chip flies to the measured tab
  menu, with a stationary Reduce Motion alternative. Selection waits for the
  real commit and refreshed snapshot. Failures return to the finder controls.
- Missing saved websites use a verified saved profile's focused/live window
  when the old window has closed or the browser restarted. Fresh single-owner
  legacy migration uses the same rule. Conflicting/unknown profiles are still
  rejected rather than selecting the wrong account.
- Saved native apps with no remaining windows prepare their default workspace,
  including apps whose processes are still running.

## Validation

The first full gate passed at `intent-change-gate-NDdLhV` and development app
UUID `E719BECD-3B1F-3CC6-8A1C-2BB2A30C8896` was installed. The live repeat caught
a second failure: native Chrome now displayed Example Domain, but its retained
idle snapshot still reported New tab active. Explicit activation did not publish
an inventory; idle activation events intentionally avoid discovery. Both browser
adapters now publish the actual post-activation inventory. A new regression fails
on the old Chrome implementation and passes on the fixed Chrome and Firefox
implementations. Browser Guard is bumped to 0.2.41, including the native host's
bundled version. The earlier gate does not certify this later change.

Final full gate `intent-change-gate-m1CVLd` passed all eight suites, source
fingerprint `e290194102cd313b88e715909530a0e68feb6a00b6c6389ad20e1ca3439f0d28`.
Matching development app and native host installed through `install-dev.sh`.
Daily Chrome heartbeat reports 0.2.41.

Installed Chrome acceptance: T created `https://example.net/?intent-qa-t-041`,
selected the exact tab, and Run succeeded with Stopwatch enabled. The actual
Chrome content and address bar showed that URL during the session. Finish via
Intent's File menu left the same page in front. Saved this as the disposable
QA Oct9 T replay 041 intention, closed its tab, and clicked its saved slot:
Intent recreated the exact URL in the same Chrome profile, automatically ran,
and restored Stopwatch. No manual re-selection was requested. Finished via the
menu again with the same page retained. These are native UI automation results,
not physical shortcut acceptance.

## Official Firefox update and installed acceptance

Mozilla version 6558052 / file 5102190 was approved after zero validation
errors or warnings. Downloaded the official signed 0.2.41 package and checked
its signature metadata, manifest, and byte-identical background.js against source.
SHA-256: `43c2f96511b31272e286ad26b2b29f657ec40d40d075e881fd00e1e0aca83f39`.
Installed it in daily `ykomjweq.default-release`; extensions.json confirms
0.2.41, active true, signedState 2. The native heartbeat also reports 0.2.41.
Permissions are unchanged from the installed 0.2.40 package.

Native UI acceptance passed:
- The compact real Firefox window measured 760 by 560 points and retained the
  existing profile, bookmarks and browser suggestions.
- T navigation to `https://example.org/?intent-qa-firefox-transfer-041`
  automatically selected the exact transferred tab. Run succeeded with Stopwatch.
  The actual Firefox address bar and page confirmed the URL during the session.
- Finish via File > Finish Intention retained that page without a completion UI.
- Saved the QA intention, then closed its entire original two-tab QA window.
  Other daily Firefox windows remained open. Clicking saved slot 6 recreated the
  exact required URL in the same profile, ran automatically, and restored Stopwatch.
  No manual tab or app reselection was requested. Finish retained the same page.
- Closed-app replay also passed: Calculator was confirmed not running, prepared
  and saved with Stopwatch, quit, and reopened automatically by its saved slot.
  The prior Calculator calculation was retained. Calculator was quit after testing
  to return it to its original non-running state.

One initial Firefox attempt typed into the original window because native
computer automation retained its previous window binding. This was not counted
as a T pass. Selecting the compact finder via Firefox's Window menu corrected
that automation targeting; the actual flow above then passed.

The disposable Chrome, Firefox and Calculator bookmarks were removed through the
UI; recent run history remains recoverable. Owned Chrome example test tabs and
Firefox QA tabs/window were closed. User tabs, documents and saved intentions
were preserved. No new Intent, Firefox or Chrome crash was observed during these
checks. Private browsing content is omitted from this report.

The URL flight animation is implemented, but the brief moving chip was not
captured by the desktop screenshot cadence; visual smoothness remains unverified.
Physical shortcuts remain unverified. Stopwatch was tested live in these replay
flows; Timer/Checklist persistence is covered by automated regression checks,
not claimed as an exhaustive live test of every modification combination.

Implementation is published at `codex/overview-finder-fixes`, commit
`3c8930a103e3d79324d657c54c66a08b7737f44d`. This is a scoped source push and matching
local development installation, not a new public macOS binary release.
