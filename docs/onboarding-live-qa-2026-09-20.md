# Intent onboarding live QA — 20 September 2026

Status: partial live acceptance. Final QA permissions worked; three limited native scenarios covered timer expiry, checklist-first completion, and saving/reusing one canvas intention while closing the guide. These are not three fully integrated passes. Physical global shortcuts, browser integration, composited blur/input behavior and the independent hidden-controls expiry notice remain unverified. The Mac locked during replay testing; QA cleanup is verified and further live work awaits unlock.

## Candidate and evidence

- Starting source commit: `a35bf11` (`Teach Intent through a resumable purpose-first onboarding`).
- Initial isolated app: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-L9Xz3YTp/Intent QA.app`. The Mac was unlocked and this QA app launched. The daily app was not replaced.
- The initial rendered welcome/purpose/permission observations below belong to the subsequent layer-fix candidate at `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-RtsJjHlA/Intent QA.app`.
- Candidate after all three window/focus changes: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-dW8GexAs/Intent QA.app`. It launched after the Rts candidate was quit; the follow-up observations below belong to this dW8 candidate. Later integrity checks failed, so its earlier successful packaging check does not establish that the current bundle remains valid.
- Evidence below comes from the main task's live CUA observations, conversation screenshots and inspection of persisted QA state. No screenshot files were created; no filesystem screenshot links are available.
- The [19 September implementation report](onboarding-qa-2026-09-19.md) contains the earlier full automated results. The final release App compilation after all three window/focus fixes passed in 28.35 seconds (`/tmp/intent-onboarding-live-final-build.log`); packaging and code-signature verification passed (`/tmp/intent-onboarding-live-final-package.log`). CoreSpec, including 100 gesture sequences, and AccountSpec executables were rerun successfully against unchanged core sources. This is not a new full-suite or live-acceptance claim.
- Subsequent durable-package candidates are identified below by `OxTBjTz0` and `4U34UP`. The comprehensive run after the guide-reopen changes passed all checks and three automated repetitions: `/tmp/intent-onboarding-approved-final-checks-2.log`, detailed log directory `intent-qa-checks-i5IYTXdT`. An earlier attempt failed because `updatePresentation` lacked `@MainActor`; that annotation was corrected before the successful run. These results predate the final permission-handoff change and do not substitute for live integrated passes.
- Final permission-handoff artifact: `/Users/loganmondi/.codex/artifacts/intent-qa/package-u676apjy/Intent QA.app`, using the same private QA data. Release IntentApp compilation passed in 54.72 seconds; CoreSpec passed, including 100 gesture sequences and the extended presentation/handoff specifications. Logs: `/tmp/intent-permission-handoff-core-build.log`, `/tmp/intent-permission-handoff-core-spec.log`, `/tmp/intent-permission-handoff-app-build.log` and `/tmp/intent-permission-handoff-package.log`. These focused results supplement the earlier comprehensive run; they are not three live integrated passes.
- After the final handoff build, `/usr/bin/python3 scripts/test-qa-packaging.py` passed both tests in 5.102 seconds. Shell syntax checks (`bash -n`) and `git diff --check` passed. At that earlier checkpoint, daily `intentions.json`, `schedules.json` and `cooldowns.json` hashes were unchanged and QA `browser-rules.json` was inactive. A fresh final daily-state and cleanup check remains due after the live runs below.

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
| Settings handoff | Open Settings created an off QA Accessibility row after the exact-QA TCC reset. Toggling it on opened a macOS Privacy & Security sheet requiring Touch ID or a password. | At that stage, effective grants and Ready were unverified. The user's existing approval was retained while waiting for OS authentication. |
| Authentication pause, now resolved | The main task displayed the exact user-action callout and sent an asynchronous Done response prompt. Live UI work paused at the macOS authentication sheet until the user completed it. | No intention or enforcement had started at that checkpoint. Post-authentication runs are recorded separately below. |

Tool-observation limit: requesting AX state directly from a hidden QA app can reopen it. Such an observation cannot by itself prove that the permission handoff failed to keep the app hidden or that it stole focus.

## Post-authentication native runs

| Check | Actual observation | Limits |
|---|---|---|
| Effective permissions | After the user's authentication and Screen Recording Quit & Reopen, Accessibility and Screen Recording worked for the final `u676` candidate. | This verifies the tested candidate after the handoff; it does not establish retained grants across a future differently signed build. |
| Single QA process | macOS restart left two QA processes: the older `OxTBjTz0` package and final `u676`. Both exact processes were stopped, then only final `u676` was relaunched as PID `70706`. | Process identity was controlled for these runs; the final process was stopped during cleanup below. |
| Emergency-release pilot | Safety Stop was invoked from the menu while idle and during the pilot. An app-directed Control + Option + Command + Escape released the pilot; the safety alert appeared and QA browser rules became inactive. | This proves the exercised app-directed release path, not delivery of a physical global chord from another app. The pilot is not counted as a completed integrated pass. |
| Pilot timer entry | The pilot initially used the default 25 minutes because CUA typing had not focused the field; the pilot was stopped. | No code defect was established from this targeting error. |
| One-minute configuration | A later setValue plus Raise interaction set the value to one minute, which persisted after closing and reopening the modifier popover. | A verified value is required before running; the earlier unfocused typing attempt is not treated as successful input. |
| Native smoke 1: Timer | One-minute Timer with Block Calculator started at `01:00`. Normal Finish was refused with 23 seconds remaining. Automatic expiry was observed, the guide reported “Your first setup ran,” and the dashboard became inactive. | A limited native timer run passed these assertions. Physical shortcut mastery, browser selection and pixel-level blur/input enforcement are not established by it. |
| Native smoke 2: Timer + Checklist | The one-time Timer + Checklist explanation appeared. With Timer set to one minute and two tasks, normal Finish was refused with “Check off your tasks.” The first checkbox produced `1/2` at `00:38`; checking the last task closed the controls and returned to an inactive dashboard before the timer deadline. | Checklist-first completion and normal-finish refusal were observed. This is a second limited native run, not the third fully integrated pass. |
| Overview previews | The picker screenshot showed actual app previews at differing scaled sizes, with some icon fallbacks for native apps without windows. | The individual-window captures available through CUA cannot prove the final composited blur or input blocking on the desktop. |

These first two limited native runs and the emergency pilot are supplemented by the save/reuse scenario below. No browser integration pass is claimed; fixture preparation and targeting limits are recorded separately.

## Save, reuse and replay

| Check | Actual observation | Limits |
|---|---|---|
| Save through the guide | After skipping the quick-selection skill, the first overview timer setup was saved through the guide's Save to canvas path. QA `intentions.json` contained exactly one saved `Read my notes` intention, ID `BE41729E-191E-48F2-917E-D03A50EE6C0A`, with Block Calculator and a one-minute Timer. Show on canvas displayed its actual card. | The observed save produced one card. Retry, edited-name update and stable-ID replacement still require separate live checks. |
| Native smoke 3: saved reuse | Double-clicking the canvas card started a real reuse. The final guide showed “You ran your saved intention again” and explained that skipped skills are not marked learned. | This verifies the saved native setup's reuse; the skipped quick-selection skill was not demonstrated. |
| Close guide during a run | **Let me do my thing** closed the guide while the saved intention continued, with `00:48` visible. | Intentional guide closure did not silently stop this run. Preservation of pre-existing staged marks remains untested. |
| Hide controls and expiry | After hiding controls with their arrow and hiding the dashboard, the saved run expired and the dashboard was later inactive. | The independent expiry notice was missed; hidden-controls/background notice delivery is not proven. |
| Explicit replay | Settings → Show quick guide returned to welcome. **Let's begin** reopened a purpose field containing `Read my notes`. The next screenshot attempt was blocked because the Mac locked. | Replay entry and retained purpose were observed; the full replay flow and timing were not completed. |
| Native shortcut attempt | An app-directed double-backtick attempt targeting Calculator did not invoke quick marking. | App-directed CUA input can miss the native global path; this attempt is inconclusive, not an established product bug or physical-shortcut pass. |

There are now three limited native scenarios, plus a separately identified safety pilot. They do not satisfy three fully integrated selection/run/stop/save/replay passes with the outstanding browser and native global-key coverage.

## Isolated browser attempts and cleanup

| Browser | Actual work and cleanup | Remaining limit |
|---|---|---|
| Firefox | A profile was created at the QA path and the original `default-release` default was restored immediately. QA Firefox launched as PID `78073`, but CUA resolved the personal Firefox process `1032` even when rebound using the exact application path `/Applications/Firefox.app`; the app selector has no process-ID option. No extension was installed. The exact QA process was stopped, its profile entry removed using **Don't Delete Files**, the original default confirmed, and only the QA about:profiles tab closed. | Correct QA-process UI targeting was unavailable; tab selection and enforcement were not tested. Profile data was retained. |
| Firefox native-host fixture | `prepare-qa-firefox.py` was run, followed by `--cleanup`. Cleanup verified removal of the QA native-host registration and copied fixture while retaining profile data. | Fixture preparation/cleanup is verified; it is not a connected extension or browser runtime pass. |
| Chrome | The latest Add profile attempt again produced blank AX output and no available screenshot; Cmd+W closed it. The final names-only profile inventory contained no QA profile. | No Chrome extension installation or browser integration pass is claimed. |

## Issues found and changes awaiting verification

The missing coach was traced in source to ordering between peer `.floating` windows. It was not caused by a dashboard at `statusBar + 1`. Raising the coach allowed the explicit Settings path to render; automatic welcome was subsequently observed on a controlled fresh launch of `package-u676apjy`.

The main task also corrected the initial panel-show guard while the real picker is visible and prevented `focusOverlay` from taking key focus away from welcome/purpose entry. All three changes compiled and were packaged. Automatic welcome, purpose focus and UI typing/Return were observed on `package-u676apjy`; physical keyboard focus and picker/coach coexistence are still not fully verified.

The later bundle inspection established a packaging-integrity problem. Temporary-file age cleanup is a possible explanation for the missing contents and changed directory timestamps; it is an inference, not a confirmed cause. The packaging change now places app artifacts outside the temporary directory, and both packaging tests passed. The dW8 failure remains historical evidence; it is not the current permission diagnosis.

Guide presentation now has an explicit request that raises a retained coach without restarting its clock, clearing evidence or recreating the selection scope. The presentation policy defers focus while the real picker is visible and restores the coach without taking keyboard focus on ordinary picker closure. Source review and automated policy tests found no new actionable lifecycle regression; only the explicit reopening/Continue later behavior above has been observed live.

## Current verification boundary

The password-sheet, stale QA authorization and temporary-package blockers have been superseded for the current candidate. Effective QA permissions and the app-directed emergency-release path were exercised before the bounded native runs. The older duplicate QA process was removed from the test before those runs.

The remaining boundary is evidence coverage: physical native global-key delivery, actual isolated browser connection/tab behavior, full composited blur/input behavior, save retries/updates, the independent hidden-controls expiry notice, three fully integrated live passes and the broader accessibility matrix remain outstanding. Basic one-card save, real canvas reuse and guide closure while running were observed. The Mac is now locked; an unlock request was sent, and further live work waits for access.

Final read-only cleanup checks confirmed unchanged hashes for daily `intentions.json`, `schedules.json` and `cooldowns.json`; inactive QA browser rules; absent QA Chrome/Firefox native-host manifests; no QA Firefox profile registration; the original Firefox default `Profiles/ykomjweq.default-release`; and an empty QA Chrome profile-name list. Deep/strict signature verification of final `u676` and `git diff --check` passed. The exact QA process `70706` received TERM while the Mac was locked; a subsequent process check found no Intent QA, QA Firefox or daily Intent process. No UI observation is claimed after stopping QA.

The private QA data and durable artifact remain available for resumption, including the one saved QA card. The daily app was neither replaced nor relaunched; there was no release, push or deployment. The daily app remains closed while the Mac is locked.

## Remaining live matrix

| Priority | Scenario | Status / required evidence |
|---|---|---|
| 1 | Final build, signature and regressions after panel/focus changes | Durable packaging tests and the earlier comprehensive run passed all three automated repetitions; final handoff CoreSpec/release build passed and `package-u676apjy` was packaged. |
| 1 | Fresh first launch, guide layering and welcome/purpose keyboard focus | Automatic welcome, purpose-field focus and CUA typing/Return observed on `package-u676apjy`; physical keyboard and varied display/focus conditions remain pending. |
| 1 | Blank/whitespace, long input, physical Unicode/IME entry | Empty/whitespace rejection, long Unicode retention, bounded header and CUA Return observed; physical typing/IME still pending. |
| 1 | Edit purpose from a later step, Back, close/resume and quit/relaunch | Purpose/negative timer persisted across candidate launches; Continue later and explicit Settings reopening preserved state on `4U34UP`. Edit-return, Back and complete replay/relaunch combinations remain pending. |
| 1 | Real `0:01 → 0:00 → -0:01` countdown | Negative values visibly confirmed; the actual zero crossing remains uncaptured. |
| 1 | Skip both skills, decline saving, finish and explicit replay | Quick-selection skill skip and truthful skipped-skill copy observed; explicit replay reached welcome and retained purpose. Skip-both/no-save and complete replay flows remain pending. |
| 1 | Grant QA permissions and observe the guide's real refresh | Effective final-candidate Accessibility and Screen Recording worked after user authentication and Screen Recording Quit & Reopen. |
| 1 | Emergency release and bounded fallback before restriction testing | Menu path exercised; app-directed emergency chord released the pilot with safety alert and inactive rules. Physical global delivery remains unverified. |
| 2 | First actual intention run through the overview and native global shortcut | Three limited native scenarios exercised start, finish-lock refusal, timer/checklist completion and saved reuse. Native global-shortcut delivery and mastery remain pending. |
| 2 | Timer and checklist completion | One-minute Timer expired normally; one-minute Timer + two-task Checklist ended on the final checkbox before its deadline. These limited native assertions passed. |
| 2 | Composited blur, input blocking and overview previews | Actual preview images/scaled sizes observed; complete desktop composition and blocked-input behavior cannot be concluded from individual-window captures. |
| 2 | Actual native quick-mark shortcut, staged targets and successful run | App-directed Calculator double-backtick did not invoke marking and is inconclusive; physical global delivery, target identity and successful marked run remain pending. |
| 2 | Isolated Chrome and Firefox fixture connections | Firefox QA profile/preparation attempted and safely cleaned up, but CUA targeted personal Firefox; no QA extension installed. Chrome profile UI remained unavailable; browser integration remains untested. |
| 2 | Optional save, canvas click/reuse, edited name and explicit stable-ID update | One `Read my notes` card persisted with the recorded ID and double-clicked reuse worked. Retry, edited-name update and explicit stable-ID replacement remain pending. |
| 2 | Guide closure/resume during a real session and preservation of earlier marks | Guide closure left the saved run active at `00:48`; pre-existing staged-mark preservation remains pending. |
| 2 | Independent expiry notice with hidden controls | Saved run ended with controls/dashboard hidden, but the notice was missed; visibility/delivery assertion remains unproven. |
| 2 | Three integrated live selection/run/stop/save/replay passes | Still pending. Emergency pilot is not a pass; the three limited native scenarios do not satisfy all integrated criteria. |
| 2 | Keyboard-only access, VoiceOver, reduced effects, small/multiple displays | Pending; no accessibility acceptance claimed. |
| 3 | Uncoached first-user study and independent shortcut recall | Not run; see the [research test script](onboarding-research-2026-09-19.md#short-uncoached-first-user-test). |
| Final | Cleanup, QA rules/processes/hosts, daily state hashes and daily app restoration | Daily hashes unchanged, QA rules inactive, QA hosts/profile entries absent, original Firefox default retained and final signature valid. QA/QA Firefox processes stopped; daily Intent also closed. Artifact/data retained; daily app reopening remains blocked by the locked Mac. |

AI Mode, Purpose Mode, scheduler, publication, daily-app replacement and unrelated projects remain outside this pass.
