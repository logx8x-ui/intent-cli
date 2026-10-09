# Intent stabilization and private tester gate

The goal is a dependable existing app for a first cohort of three to five
people. Stop adding features until the known core failures are closed. Work on
one reproducible defect at a time; parallel agents may inspect independent
owners, but one person owns the shared build, installation and desktop.

## Why green checks missed the failures

The T startup fixture checked that the requested tab became active. Production
also required its window to become focused. Chrome can report the first before
the second, and the later idle focus event did not publish another inventory.
A concurrent hover preview could also restore the old tab after Run. Neither
race was represented in that fixture. Source tests cannot establish the result
of an installed browser operation, a physical shortcut or a macOS animation.

## Repeatable defect loop

1. Record the exact app UUID, source fingerprint, browser profile, extension
   version, permissions and active rules. Reproduce using disposable resources.
2. Capture the owning state transition, then add a failing behavioral regression.
   Fix that owner; do not hide its error, loosen identity checks or add an
   independent delayed activation to disguise a failed effect.
3. Freeze edits and run the impacted checks and session regression gate.
4. Install the candidate and matching browser components. Repeat the original
   installed failure three times, then its nearest working/cancellation cases.
5. Record PASS, FAIL, NOT EXERCISED or AUTOMATION LIMIT. A failure remains in
   the queue; a mocked or synthetic pass is never relabeled as physical evidence.

## Queue, in order

| Priority | Defect or acceptance group | Acceptance |
| --- | --- | --- |
| 1 | T website transfer and Chrome Run | Direct URL, search result, immediate Run, hovered preview, cancellation and reconnect work in the intended profile; no reload/reselection request, duplicate tab or crash. |
| 2 | Actual DBT tab outlines | Chrome and Firefox ordinary/pinned/grouped/multiple selected tabs, duplicate titles, sibling windows, resizing and modifiers show the correct actual tab contour. Unselected or closed tabs never acquire a stale mark. |
| 3 | Quiet completion | Every Intent-owned hidden/minimized window returns, prehidden/preminimized windows remain unchanged, and the exact finish app/window/tab/Space stays in front throughout at least 20 seconds of independent sampling. Manual, timer, end-time and checklist completion all obey the same rule. |
| 4 | Saved intentions and navigation | Missing apps/tabs/windows open once with original modifications; already-open resources are reused; native clicks and Control-Tab remain smooth; no wrong-profile launch or manual reselection. |
| 5 | Modifications and workspace | Add as you go opens only initial selections then admits later additions while bans win; Tab searches distinguishes fresh tabs; six positions/reordering, stopwatch/timer/checklist controls, screenshots, blank/clicked/swiped Spaces, labels and multiwindow layout work. |
| 6 | Instagram and YouTube | Allowed features work and disabled ones stay unavailable, including Stories-only home with no feed, messages-only and risky feature combinations, in both daily browser profiles. |
| 7 | Lifecycle and installation | Reconnect, disabled/missing extension, denied/granted permissions, lock/sleep/wake, interruption/restart, emergency release and rollback preserve data and leave no stuck rules. |

## Final candidate verification

Current evidence as of October 10 (see
`2026-10-10-browser-start-and-outlines.md` for exact identities):

| Check | Status | Evidence boundary |
| --- | --- | --- |
| Frozen source and installed development build | PASS | Eight serial suites; installed UUID 97FDE7AE-16FF-39EE-A65D-0DB8218EA16C; independent source-fingerprint match. |
| Chrome 0.2.43 direct URL → T transfer → Run | PASS | Three real installed runs in Logavix/Default; exact selected tab active in the focused target window; no startup alert. |
| Chrome compact T close/reopen | PASS with automation limitation | Cmd-W and reopening exercised twice; one stale native binding required refreshing before the intended action. |
| Final Firefox matching component | NOT EXERCISED / AUTOMATION LIMIT | Daily signed Guard is still 0.2.42; 0.2.43 upload/install remains incomplete. |
| Actual tab discovery and geometry | Earlier read-only PASS | Production 0.2.42 probe resolved Chrome tabs and painted Firefox Sidebery rows; final physical gesture and rendered border remain unverified. |
| Quiet finish | FAIL | Native restoration can raise a sibling window; final settled visibility is not continuous foreground preservation. |
| Remaining core matrices and soak runs | NOT EXERCISED on final candidate | Search transfer, live preview race/reconnect, saved replay, modifications, Spaces and social controls retain separate rows. |

After the core FAIL rows are cleared, run 20 disposable start/finish cycles
split across both browsers and both selection methods. Alternate access modes,
completion routes, immediate finish/restart and reconnect. Then run a 60–90
minute study-like session in each browser. Stop and return to the defect loop
on a crash, foreground jump, stale overlay, duplicate resource or stuck rule.

Use exhaustive deterministic modifier/route matrices where practical and live
single-option, risky pairwise and all-enabled cases. Do not claim that a finite
manual run exercised every possible combination, machine or browser state.

Download/onboarding work can proceed tomorrow, but distribution waits for the
candidate gate. Verify a clean install and a data-preserving update; record
binary hashes, source, app UUID, extension versions, signatures and supported
macOS versions. Supply a permanent Mozilla-signed Firefox extension and a
persistent Chrome installation route. Replace obsolete tester instructions.
The old public v0.8.1 release is not the current candidate. Apple notarization
and the current binary release are separate unfinished distribution work.

The foreground restoration failure documented in the October 9 readiness note
is still a release blocker until a changed restoration effect passes the strict
live trace. Do not call this build tester-ready while that failure is open.

For that next defect, first isolate a single native deminimize from browser tab
parking, rules and focus guards. If the OS operation itself raises the sibling,
change the visibility-restoration approach rather than masking it with a later
raise, an off-screen move or a delayed activation. Use an independent 50 ms trace
for at least 20 seconds, checking window/tab/Space and original minimized states.
Freeze and install that fix before advancing to the next acceptance group.
