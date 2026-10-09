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
not physical shortcut acceptance. Firefox 0.2.41 signing/install/live acceptance
remains in progress.
Firefox's signed 0.2.40 was installed from its approved Mozilla file 5100875 in
the daily `ykomjweq.default-release` profile; extension metadata confirms enabled
0.2.40. This is installation evidence, not T/Run or Instagram feature acceptance.

Private profile information,
user page titles, and browsing content are not included in this note.

Mozilla upload for 0.2.41 completed and validated with zero errors/warnings.
The next submission step is not yet confirmed. Stopped desktop automation when
Firefox switched from the update page to another user window during input;
requested a quiet window to finish signing/install and daily-profile acceptance.
No signed 0.2.41 artifact or Firefox acceptance is claimed. QA saved slot and
owned example.com/example.org/example.net tabs remain for continuation/cleanup.
Physical shortcuts and visual animation smoothness still need acceptance.
