# Intent onboarding live QA — 20 September 2026

Status: partial live observations; the final permission-handoff candidate compiled, passed CoreSpec and automatically displayed its welcome on a fresh launch. Purpose entry and Return reached the permission gate. The QA app is running, awaiting the user's macOS Touch ID/password authentication to enable its new Accessibility entry. No intention or restrictions have been started during this pass. This document does not claim effective permission grants or a complete onboarding, accessibility, browser or safety pass.

## Candidate and evidence

- Starting source commit: `a35bf11` (`Teach Intent through a resumable purpose-first onboarding`).
- Initial isolated app: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-L9Xz3YTp/Intent QA.app`. The Mac was unlocked and this QA app launched. The daily app was not replaced.
- The initial rendered welcome/purpose/permission observations below belong to the subsequent layer-fix candidate at `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-RtsJjHlA/Intent QA.app`.
- Candidate after all three window/focus changes: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-dW8GexAs/Intent QA.app`. It launched after the Rts candidate was quit; the follow-up observations below belong to this dW8 candidate. Later integrity checks failed, so its earlier successful packaging check does not establish that the current bundle remains valid.
- Evidence below comes from the main task's live CUA observations, conversation screenshots and inspection of persisted QA state. No screenshot files were created; no filesystem screenshot links are available.
- The [19 September implementation report](onboarding-qa-2026-09-19.md) contains the earlier full automated results. The final release App compilation after all three window/focus fixes passed in 28.35 seconds (`/tmp/intent-onboarding-live-final-build.log`); packaging and code-signature verification passed (`/tmp/intent-onboarding-live-final-package.log`). CoreSpec, including 100 gesture sequences, and AccountSpec executables were rerun successfully against unchanged core sources. This is not a new full-suite or live-acceptance claim.
- Subsequent durable-package candidates are identified below by `OxTBjTz0` and `4U34UP`. The comprehensive run after the guide-reopen changes passed all checks and three automated repetitions: `/tmp/intent-onboarding-approved-final-checks-2.log`, detailed log directory `intent-qa-checks-i5IYTXdT`. An earlier attempt failed because `updatePresentation` lacked `@MainActor`; that annotation was corrected before the successful run. These results predate the final permission-handoff change and do not substitute for live integrated passes.
- Final permission-handoff artifact: `/Users/loganmondi/.codex/artifacts/intent-qa/package-u676apjy/Intent QA.app`, using the same private QA data. Release IntentApp compilation passed in 54.72 seconds; CoreSpec passed, including 100 gesture sequences and the extended presentation/handoff specifications. Logs: `/tmp/intent-permission-handoff-core-build.log`, `/tmp/intent-permission-handoff-core-spec.log`, `/tmp/intent-permission-handoff-app-build.log` and `/tmp/intent-permission-handoff-package.log`. These focused results supplement the earlier comprehensive run; they are not three live integrated passes.
- After the final handoff build, `/usr/bin/python3 scripts/test-qa-packaging.py` passed both tests in 5.102 seconds. Shell syntax checks (`bash -n`) and `git diff --check` passed. Daily `intentions.json`, `schedules.json` and `cooldowns.json` hashes were unchanged; QA `browser-rules.json` was inactive. The QA app remains running for the pending authentication handoff, so this is not a final process-cleanup claim.

## Verified observations

| Check | Actual observation | Limits |
|---|---|---|
| Launch and initial coach visibility | Initial dashboard screenshot showed no coach. | Initial automatic presentation did not pass. |
| Explicit guide opening | Settings → Show quick guide displayed the welcome screen after the coach was raised. | This proves the explicit path rendered, not that a clean first launch now works. |
| Begin and initial countdown | Clicking Begin displayed `3:00`. | The initial observation did not cover the zero crossing or total tutorial duration. |
| Empty purpose | The continue action was disabled with empty input. | Follow-up whitespace and long-input observations are recorded separately below. |
| Unicode purpose submission | CUA setValue submitted the exact raw string `  친구에게 답장하기 — café 🐈  `. The guide displayed the purpose and required-permission stage at `2:46`. | Programmatic setValue does not exercise physical typing or IME composition. |
| Purpose persistence | Persisted QA state retained that exact raw purpose, including leading/trailing spaces and Unicode. | No save, saved-name normalization or edit-return recovery has been tested live; the later launch observation is recorded below. |
| Missing-permission path | The guide exposed its permission gate. Adding QA Accessibility reached the macOS password/authentication sheet. | Permission grant and status refresh are not confirmed. |
| Local timing and evidence state | At a later persisted-state observation, full elapsed time was 198.75 seconds: 184.62 seconds of setup and 14.13 seconds of core interaction; step was `overview`, purpose remained exact, and evidence/mastery were empty. | This includes automation and permission waiting. It is not a human completion time or visual observation of the countdown crossing zero. |

## Follow-up observations on the dW8 candidate

| Check | Actual observation | Limits |
|---|---|---|
| Permission approval | The user approved both QA permission requests and macOS authentication completed. | User approval is not proof that macOS retained an effective grant. Neither permission is marked passed here. |
| Launch and retained state | After the Rts candidate quit, the dW8 candidate launched and the guide retained its purpose. | This checks retained state across these launches, not a complete fresh-launch or edit-return matrix. |
| Negative countdown | The rendered guide visibly showed `-699:48` and later `-702:31`. | Negative time is visually confirmed. The actual `0:01 → 0:00 → -0:01` transition was not captured; these values are not human tutorial completion times. |
| Whitespace-only input | Blank spaces disabled **Choose my setup**. | Physical typing and IME composition remain unverified. |
| Long Unicode input | The string `책 읽기 — café 🐈 ` repeated 24 times retained its full wording. The contextual header stayed within two lines and used an ellipsis. | A bounded header does not demonstrate small-display or VoiceOver acceptance. |
| Return submission | CUA Return advanced the entered purpose to the permission overview. | This is synthetic keyboard delivery; marked-text/physical IME behavior is not established. |
| Accessibility Add | The exact dW8 app was selected twice; the file chooser accepted Open, but no QA row remained in Accessibility. | Effective Accessibility permission and the guide's refreshed granted state were not verified. |
| Bundle integrity | Inspection found missing Sparkle Resources/helper `Info.plist` content and an empty `Intent_IntentApp.bundle`; both deep and non-deep code-signature verification rejected the bundle. | The earlier package passed verification around 02:03; inspected directories had changed at 03:35:01. The reason for the later loss is not proven. |
| Stop | QA stopped cleanly with no enforcement session started. | Full final cleanup, daily-state hashes and restoration still require their own checks. |

## Durable packaging and guide-reopen observations

| Check | Actual observation | Limits |
|---|---|---|
| Durable packaging | Both packaging tests passed after moving app artifacts outside the temporary directory. | This addresses artifact placement/integrity; it does not repair a previously stored macOS code requirement. |
| Permission rows for `OxTBjTz0` | At approximately 13:51, the exact package had visible Accessibility and Screen Recording rows switched on; Quit & Reopen was performed. | Visible on switches do not prove effective permission for a subsequently rebuilt binary. |
| Explicit guide reopening on `4U34UP` | After the guide-reopen fix, Settings → Show quick guide displayed the actual coach, retained the long purpose and showed `-719:33`. | Explicit reopening is observed; clean first-launch and physical focus acceptance remain separate. |
| Continue later and resume | Continue later closed the guide; Settings → Show quick guide opened it again with state preserved. | Replay, edit-return after process death and a complete skip sequence remain untested. |
| Shortcut and lock copy | Settings showed the configured Finish shortcut, Shift + backtick, and the explanation that an unfinished checklist can keep an intention running. | Correct copy does not establish physical shortcut or lock enforcement behavior. |
| Effective permission diagnosis | The guide still did not show Ready. A scoped `tccd` log reported a code-requirement hash mismatch between the old QA authorization and rebuilt binary, despite on switches in Settings. Adding the existing entry and toggling QA off/on did not refresh that requirement. | No effective grant or permission-dependent acceptance is claimed. QA Accessibility was left off at this stage; other apps' permissions were untouched. |
| Settings interaction | The high-level coach can overlap Settings. Some coordinate-based clicks were unsuccessful. | Overlap was observed, but tool targeting can also explain click errors; no single cause is assigned to all failures. |
| Isolated Chrome attempt | Add profile produced empty accessibility output and no available screenshot. Cmd+W closed that attempt and returned to the original tab; a names-only Local State check found no QA profile. | No QA Chrome profile, extension or native-host registration was installed by this attempt. Browser integration remains untested. |
| QA-only permission reset | `4U34UP` was stopped cleanly using Quit. Official `tccutil reset Accessibility dev.loganmondi.intent.qa` and `tccutil reset ScreenCapture dev.loganmondi.intent.qa` both succeeded. No Intent process or restrictions remained. | Only this test bundle's grants were reset; no TCC database edits or production permission changes were made. The new candidate still requires fresh grants and an actual Ready check. |

## Final permission-handoff candidate

| Check | Actual observation | Limits |
|---|---|---|
| Fresh-state preparation | With QA stopped, only QA onboarding preferences were backed up to `onboarding-before-fresh-launch.plist` within the private QA data root, then reset through `defaults`. Daily data was untouched. | This creates a controlled fresh onboarding state; it is not a new macOS account or a novice study. |
| Automatic welcome | Fresh launch of `package-u676apjy` automatically displayed the welcome coach. | This resolves the previously unobserved automatic path for this candidate; broader display/accessibility conditions remain untested. |
| Entry focus and typing | Clicking **Let's begin** focused the purpose field. CUA `typeText('Read my notes')` followed by Return advanced to the overview permission gate. | This is actual UI entry through automation, not physical keyboard/IME acceptance or a native global-shortcut test. |
| Settings handoff | Open Settings created an off QA Accessibility row after the exact-QA TCC reset. Toggling it on opened a macOS Privacy & Security sheet requiring Touch ID or a password. | The effective grant and the guide's Ready state remain unverified. The user's existing approval is retained; OS authentication must be completed by the user. |
| Current pause | The main task displayed the exact user-action callout and sent an asynchronous Done response prompt. Live UI work is waiting at the macOS authentication sheet. | No intention or enforcement has started, and no additional UI action is being treated as authorized authentication. |

Tool-observation limit: requesting AX state directly from a hidden QA app can reopen it. Such an observation cannot by itself prove that the permission handoff failed to keep the app hidden or that it stole focus.

## Issues found and changes awaiting verification

The missing coach was traced in source to ordering between peer `.floating` windows. It was not caused by a dashboard at `statusBar + 1`. Raising the coach allowed the explicit Settings path to render; automatic welcome was subsequently observed on a controlled fresh launch of `package-u676apjy`.

The main task also corrected the initial panel-show guard while the real picker is visible and prevented `focusOverlay` from taking key focus away from welcome/purpose entry. All three changes compiled and were packaged. Automatic welcome, purpose focus and UI typing/Return were observed on `package-u676apjy`; physical keyboard focus and picker/coach coexistence are still not fully verified.

The later bundle inspection established a packaging-integrity problem. Temporary-file age cleanup is a possible explanation for the missing contents and changed directory timestamps; it is an inference, not a confirmed cause. The packaging change now places app artifacts outside the temporary directory, and both packaging tests passed. The dW8 failure remains historical evidence; it is not the current permission diagnosis.

Guide presentation now has an explicit request that raises a retained coach without restarting its clock, clearing evidence or recreating the selection scope. The presentation policy defers focus while the real picker is visible and restores the coach without taking keyboard focus on ordinary picker closure. Source review and automated policy tests found no new actionable lifecycle regression; only the explicit reopening/Continue later behavior above has been observed live.

## Current blocker

The prior password-sheet and temporary-package blockers have been superseded. Settings subsequently showed both rows on, but rebuilt QA did not become Ready and the scoped `tccd` log confirmed a stored code-requirement mismatch. After quitting QA, the main task successfully reset Accessibility and ScreenCapture for the exact QA bundle ID with official `tccutil` commands. That removes the stale test authorization; it does not grant permission to the next candidate.

The permission-handoff change now passes the focused CoreSpec and release build checks, and `package-u676apjy` is packaged and launched. Its new Accessibility row is present, but turning it on requires the user's macOS Touch ID/password authentication. That sheet is the current blocker, and further UI work waits for the user. Fresh effective Accessibility and Screen Recording grants, the guide's Ready state and emergency release must be verified before enforcement. No enforcement has been started.

## Remaining live matrix

| Priority | Scenario | Status / required evidence |
|---|---|---|
| 1 | Final build, signature and regressions after panel/focus changes | Durable packaging tests and the earlier comprehensive run passed all three automated repetitions; final handoff CoreSpec/release build passed and `package-u676apjy` was packaged. |
| 1 | Fresh first launch, guide layering and welcome/purpose keyboard focus | Automatic welcome, purpose-field focus and CUA typing/Return observed on `package-u676apjy`; physical keyboard and varied display/focus conditions remain pending. |
| 1 | Blank/whitespace, long input, physical Unicode/IME entry | Empty/whitespace rejection, long Unicode retention, bounded header and CUA Return observed; physical typing/IME still pending. |
| 1 | Edit purpose from a later step, Back, close/resume and quit/relaunch | Purpose/negative timer persisted across candidate launches; Continue later and explicit Settings reopening preserved state on `4U34UP`. Edit-return, Back and complete replay/relaunch combinations remain pending. |
| 1 | Real `0:01 → 0:00 → -0:01` countdown | Negative values visibly confirmed; the actual zero crossing remains uncaptured. |
| 1 | Skip both skills, decline saving, finish and explicit replay | Pending; no fabricated demonstrated actions or saved card. |
| 1 | Grant QA permissions and observe the guide's real refresh | Exact-QA grants reset; new final candidate's Accessibility row exists. macOS Touch ID/password sheet is awaiting the user; effective grants and Ready remain pending. |
| 1 | Emergency release and bounded fallback before restriction testing | Pending; do not count source/automated checks as physical escape verification. |
| 2 | First actual intention run through the overview and native global shortcut | Not started. After permissions/escape are verified, observe selection, runtime success and normal stop; a button or synthetic app-targeted key alone does not establish native global-shortcut mastery. |
| 2 | Actual native quick-mark shortcut, staged targets and successful run | Pending; verify actual target identity and successful runtime start. Failed starts or recognised keys alone do not establish mastery. |
| 2 | Isolated Chrome and Firefox fixture connections | Chrome profile attempt closed without creating a QA profile; no QA extensions/hosts installed. QA disables production Connect/register, so isolated fixtures are still required. |
| 2 | Optional save, canvas click/reuse, edited name and explicit stable-ID update | Pending; verify one saved card, no implicit overwrite and no duplicate after retry. |
| 2 | Guide closure/resume during a real session and preservation of earlier marks | Pending; closure must not silently end the session or destroy pre-existing selection. |
| 2 | Three integrated live selection/run/stop/save/replay passes | Not started; automated repetitions are not substitutes. |
| 2 | Keyboard-only access, VoiceOver, reduced effects, small/multiple displays | Pending; no accessibility acceptance claimed. |
| 3 | Uncoached first-user study and independent shortcut recall | Not run; see the [research test script](onboarding-research-2026-09-19.md#short-uncoached-first-user-test). |
| Final | Cleanup, QA rules/processes/hosts, daily state hashes and daily app restoration | Daily intention/schedule/cooldown hashes unchanged and QA browser rules inactive. `package-u676apjy` is running for authentication; remaining cleanup/restoration is pending, not a completed final cleanup. |

AI Mode, Purpose Mode, scheduler, publication, daily-app replacement and unrelated projects remain outside this pass.
