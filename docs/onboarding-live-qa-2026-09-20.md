# Intent onboarding live QA — 20 September 2026

Status: partial live observations; permission approval and remaining acceptance checks are pending. No intention or restrictions have been started during this pass. This document does not claim a complete onboarding, accessibility, browser or safety pass.

## Candidate and evidence

- Starting source commit: `a35bf11` (`Teach Intent through a resumable purpose-first onboarding`).
- Initial isolated app: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-L9Xz3YTp/Intent QA.app`. The Mac was unlocked and this QA app launched. The daily app was not replaced.
- The rendered welcome/purpose/permission observations below belong to the subsequent layer-fix candidate at `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-RtsJjHlA/Intent QA.app`.
- Final candidate after all three window/focus changes: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-dW8GexAs/Intent QA.app`. It has been packaged but **not launched**; earlier screenshots do not validate its live behavior.
- Evidence below comes from the main task's live CUA observations, conversation screenshots and inspection of persisted QA state. No screenshot files were created; no filesystem screenshot links are available.
- The [19 September implementation report](onboarding-qa-2026-09-19.md) contains the earlier full automated results. The final release App compilation after all three window/focus fixes passed in 28.35 seconds (`/tmp/intent-onboarding-live-final-build.log`); packaging and code-signature verification passed (`/tmp/intent-onboarding-live-final-package.log`). CoreSpec, including 100 gesture sequences, and AccountSpec executables were rerun successfully against unchanged core sources. This is not a new full-suite or live-acceptance claim.

## Verified observations

| Check | Actual observation | Limits |
|---|---|---|
| Launch and initial coach visibility | Initial dashboard screenshot showed no coach. | Initial automatic presentation did not pass. |
| Explicit guide opening | Settings → Show quick guide displayed the welcome screen after the coach was raised. | This proves the explicit path rendered, not that a clean first launch now works. |
| Begin and initial countdown | Clicking Begin displayed `3:00`. | Negative countdown, continuity and total tutorial duration have not been observed. |
| Empty purpose | The continue action was disabled with empty input. | Whitespace-only input and keyboard submission still need separate checks. |
| Unicode purpose submission | CUA setValue submitted the exact raw string `  친구에게 답장하기 — café 🐈  `. The guide displayed the purpose and required-permission stage at `2:46`. | Programmatic setValue does not exercise physical typing or IME composition. |
| Purpose persistence | Persisted QA state retained that exact raw purpose, including leading/trailing spaces and Unicode. | No save, saved-name normalization, edit-return or relaunch recovery has been tested live. |
| Missing-permission path | The guide exposed its permission gate. Adding QA Accessibility reached the macOS password/authentication sheet. | Permission grant and status refresh are not confirmed. |
| Local timing and evidence state | At a later persisted-state observation, full elapsed time was 198.75 seconds: 184.62 seconds of setup and 14.13 seconds of core interaction; step was `overview`, purpose remained exact, and evidence/mastery were empty. | This includes automation and permission waiting. It is not a human completion time or visual observation of the countdown crossing zero. |

## Issues found and changes awaiting verification

The missing coach was traced in source to ordering between peer `.floating` windows. It was not caused by a dashboard at `statusBar + 1`. Raising the coach allowed the explicit Settings path to render; the fresh-launch behavior must be tested again after packaging the final changes.

The main task also corrected the initial panel-show guard while the real picker is visible and prevented `focusOverlay` from taking key focus away from welcome/purpose entry. All three changes compile and are packaged in the final candidate. Their live behavior is unverified because that candidate has not been launched.

## Current blocker

The main task asked the user to approve the separate QA app's Accessibility and Screen Recording permissions. A fresh read still showed the macOS authentication sheet with Password focused; the grant and the user's response remain pending. No password was entered by automation and no enforcement was started. Remaining checks that do not need these permissions may proceed when the sheet can be dismissed safely; permission-dependent acceptance remains blocked.

## Remaining live matrix

| Priority | Scenario | Status / required evidence |
|---|---|---|
| 1 | Final build, signature and targeted regressions after panel/focus changes | App compilation, packaging/signature verification and unchanged CoreSpec/AccountSpec executable reruns passed as recorded above; final-candidate launch is pending. |
| 1 | Fresh first launch, guide layering and welcome/purpose keyboard focus | Pending; screenshot alone must show the correct automatic guide, then type and submit using the keyboard. |
| 1 | Blank/whitespace, long input, physical Unicode/IME entry | Empty-input disabled and setValue Unicode checks only; the rest is pending. |
| 1 | Edit purpose from a later step, Back, close/resume and quit/relaunch | Pending; preserve exact answer, return destination, attempt and elapsed time. |
| 1 | Real `0:01 → 0:00 → -0:01` countdown | Pending; no automatic advancement, pause, reset or punitive visual change. |
| 1 | Skip both skills, decline saving, finish and explicit replay | Pending; no fabricated demonstrated actions or saved card. |
| 1 | Grant QA permissions and observe the guide's real refresh | Blocked by macOS authentication/user grant; no pass recorded. |
| 1 | Emergency release and bounded fallback before restriction testing | Pending; do not count source/automated checks as physical escape verification. |
| 2 | Actual overview shortcut, selection and successful run | Pending; opening by button alone does not establish shortcut mastery. |
| 2 | Actual quick-mark shortcut, staged targets and successful run | Pending; failed starts or recognised keys alone do not establish mastery. |
| 2 | Isolated Chrome and Firefox fixture connections | Pending; QA disables the production Connect/register handoff, so use isolated profiles and fixture scripts. |
| 2 | Optional save, canvas click/reuse, edited name and explicit stable-ID update | Pending; verify one saved card, no implicit overwrite and no duplicate after retry. |
| 2 | Guide closure/resume during a real session and preservation of earlier marks | Pending; closure must not silently end the session or destroy pre-existing selection. |
| 2 | Three integrated live selection/run/stop/save/replay passes | Not started; automated repetitions are not substitutes. |
| 2 | Keyboard-only access, VoiceOver, reduced effects, small/multiple displays | Pending; no accessibility acceptance claimed. |
| 3 | Uncoached first-user study and independent shortcut recall | Not run; see the [research test script](onboarding-research-2026-09-19.md#short-uncoached-first-user-test). |
| Final | Cleanup, QA rules/processes/hosts, daily state hashes and daily app restoration | Pending final verification after live work; no final cleanup claim yet. |

AI Mode, Purpose Mode, scheduler, publication, daily-app replacement and unrelated projects remain outside this pass.
