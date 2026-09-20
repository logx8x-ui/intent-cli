# Intent onboarding live QA — 20 September 2026

Status: partial live acceptance. The `gZRuKyGJ` candidate completed three native onboarding/save/reuse cycles with clean saved layouts, followed by three bounded Chrome scenarios in an isolated, unsigned-in profile. Chrome tab-ID policy, tab retention and same-tab navigation were observed in two scenarios; the all-tabs-blocked scenario does not establish physical input blocking. Physical single-backtick picker entry, Esc closure and double-backtick Chrome tab outlining are user-confirmed. The later `ksf8n4nv` Settings fix passed release/package/signature checks and app-directed live settings/reopen/guide-preservation checks. Its effective macOS permission gate cleared on the sole correct process, and a saved native smoke run then verified Settings during an active timer and early checklist completion. The physical Chrome marking check also exposed a modifier bar left behind after unmarking the final tab. The focused source fix passed existing Core regressions, release packaging and signature checks. Its new 35yHyFJm candidate has effective permissions and passed an overview modifier-editor check; the exact physical last-tab unmark regression is still pending. Browser fixtures remain installed pending cleanup, with no active QA intention. These observations do not constitute three fully integrated acceptance passes.

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
- Resumed live testing used the existing `package-u676apjy` artifact, relaunched as PID `96754`, with the canonical checkout at `1e1a88c` before the new fixes below. Those native cycles predate the new source fixes and retain only that candidate's evidence scope.
- The full combined regression script completed with exit code 0: `/tmp/intent-finish-final-regressions.log` (session `68710`, checks directory identifier `PTehG0tO`). All three automated repetitions and the release/package checks passed. This included the Swift layout fixes and Chrome highlighted-group restoration. The subsequent Chrome discovery-generation fix passed fresh Chrome, Firefox and idle-work tests, syntax checks, negative controls and Chrome packaging; unchanged Swift was not rebuilt again. No live browser acceptance is implied.
- Rebuilt Swift artifact: `/Users/loganmondi/.codex/artifacts/intent-qa/package-gZRuKyGJ/Intent QA.app`. Its build and signature verification passed. The mixed-process attempt, subsequent correctly attributed camera check, historical effective-permission failure and later recovered final-candidate runs are separated below.
- Settings-command candidate: `/Users/loganmondi/.codex/artifacts/intent-qa/package-ksf8n4nv/Intent QA.app`. Release build and packaging returned exit code 0 in 269.18 seconds, with deep/strict signature verification included; log `/tmp/intent-settings-command-build.log`. The exact artifact was verified as the sole QA process, PID `77673`. Its limited live Settings checks and separate permission handoff are recorded below; `gZRuKyGJ` browser/native evidence is not automatically transferred to this new binary.

## Initial verified observations

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

## Previous locked-Mac handoff

Before the resumed work below, cleanup checks confirmed unchanged daily intention/schedule/cooldown hashes; inactive QA browser rules; absent QA Chrome/Firefox native-host manifests; no QA Firefox profile registration; the original Firefox default `Profiles/ykomjweq.default-release`; and no QA Chrome profile names. Final `u676` deep/strict signature verification and `git diff --check` passed. Exact QA process `70706` received TERM while the Mac was locked; a subsequent check found no Intent QA, QA Firefox or daily Intent process. No post-stop UI observation was claimed. The one saved QA card, private data and durable artifact were retained; the daily app was not replaced or relaunched, and nothing was released, pushed or deployed.

These were completed checks at the previous handoff, not final cleanup evidence for the subsequently resumed testing.

## Resumed native functional cycles after unlock

The user completed the unlock, and final `u676` was relaunched alone as PID `96754`. Three consecutive cycles used purposes `QA replay1`, `QA replay2` and `QA replay3`. Each followed the real guide and canvas flow:

1. Edit the guide purpose, open the picker, choose Block Calculator, and configure a one-minute Timer plus one checklist task, `Finish QA step`.
2. Run at `01:00` and complete the task through its checkbox.
3. Choose **Try the quicker way**, skip the quick-selection skill, explicitly **Update** the existing saved setup, and **Show on canvas**.
4. Double-click the saved card to start its actual reuse; observe the guide acknowledge reuse and truthfully retain the skipped-skill explanation.
5. Choose **Let me do my thing**; the guide closes while controls show `00:59` and task progress `0/1`. Check the task to end the reused run.

All three cycles completed these functional steps. Saved ID `BE41729E-191E-48F2-917E-D03A50EE6C0A` remained unchanged, with one entry whose name was updated for each cycle. Before the first explicit Update, the persisted entry still had `Read my notes`, confirming that merely editing the new guide purpose had not silently renamed the existing save.

Visual defects were also observed: timer/checklist controls sometimes appeared offscreen or overlapped the saved card. Consequently these cycles are **not three flawless full-scope passes**. Quick-selection local draft-origin and onboarding bounds-framing fixes now have source/regression coverage; the rebuilt candidate's narrower camera observation is recorded below.

## Hidden-controls expiry notice

A separate reuse of `QA replay3` ran with its one-minute Timer and checklist left unchecked. The controls were manually hidden, and QA was left until expiry. CUA AX output and a screenshot captured the actual notice reading **Time’s up** and **QA replay3** after the deadline; it disappeared after its eight-second display interval.

This establishes visible notice delivery in that exercised hidden-controls case, unlike the earlier missed notice. A later manual-dismiss attempt could not find its target after the delay, so manual dismissal is not proven. Focus preservation and the full composited desktop appearance are still not established by the available captures.

No new browser UI attempt occurred during this resumed turn. The requested physical-backtick check remains unanswered.

## Rebuilt candidate and attribution boundary

An initial attempt to check the new layout was rejected as new-candidate evidence: CUA reopened the old `u676` app while `gZRuKyGJ` was also running. Both processes were found and stopped. One interim explicit update left the saved entry named `QA final layout` with the same recorded saved ID; that mixed-process operation is not used to accept the rebuilt candidate.

After a fresh CUA reset, the main task bound only `gZRuKyGJ` as PID `21784`. An actual **Show on canvas** screenshot displayed the existing `QA final layout` card with its Timer and checklist fully inside the view and separated. This verifies camera framing for that existing saved card. It does not validate a newly created draft, an enforcement cycle, composited blur, or every display/zoom combination.

The rebuilt candidate's effective Accessibility and Screen Recording remained false. The exact artifact was selected through Add for both permissions, existing grants were toggled off/on, and Quit & Reopen was performed; both Settings switches were on, but the guide still showed the permission gate. No effective new-candidate grant or enforcement pass is claimed. The final observed running QA process was `gZRuKyGJ` alone, PID `25660`; it was subsequently quit as recorded in final cleanup below.

At that checkpoint, the guide purpose was `QA rebuilt layout`; the saved entry remained `QA final layout`. These distinct names are recorded deliberately, without treating the mixed-process update as new-candidate acceptance. The three original native functional cycles and the captured notice on `u676` remain valid within their earlier scope.

## Issues found and verification history

The missing coach was traced in source to ordering between peer `.floating` windows. It was not caused by a dashboard at `statusBar + 1`. Raising the coach allowed the explicit Settings path to render; automatic welcome was subsequently observed on a controlled fresh launch of `package-u676apjy`.

The main task also corrected the initial panel-show guard while the real picker is visible and prevented `focusOverlay` from taking key focus away from welcome/purpose entry. All three changes compiled and were packaged. Automatic welcome, purpose focus and UI typing/Return were observed on `package-u676apjy`; physical keyboard focus and picker/coach coexistence are still not fully verified.

The later bundle inspection established a packaging-integrity problem. Temporary-file age cleanup is a possible explanation for the missing contents and changed directory timestamps; it is an inference, not a confirmed cause. The packaging change now places app artifacts outside the temporary directory, and both packaging tests passed. The dW8 failure remains historical evidence; it is not the current permission diagnosis.

Guide presentation now has an explicit request that raises a retained coach without restarting its clock, clearing evidence or recreating the selection scope. The presentation policy defers focus while the real picker is visible and restores the coach without taking keyboard focus on ordinary picker closure. Source review and automated policy tests found no new actionable lifecycle regression; only the explicit reopening/Continue later behavior above has been observed live.

The resumed cycles exposed the control-placement defects described above. Local quick-selection draft origins and bounds-based onboarding camera framing were corrected and covered by regressions; the first properly isolated rebuilt-app screenshot confirmed only the existing-card camera result. The later final-candidate cycles below additionally verify clean layouts for three newly constructed drafts. Separately, a Chrome regression reproduced preview activation collapsing the browser's native highlighted tab group on the old code. Both Chrome corrections have targeted mock tests and negative controls. The full combined script passed, but mock/source evidence does not constitute actual Chrome acceptance or prove that a browser has loaded the corrected extension.

## Historical verification boundary before permission recovery

Effective QA permissions and the app-directed emergency-release path were exercised for `u676` before its bounded native runs. That success does not transfer automatically to rebuilt `gZRuKyGJ`, whose effective permissions currently remain false despite visible on switches. Earlier duplicate processes were removed before the original native cycles; the later mixed-candidate layout attempt was separately rejected and the camera screenshot was taken only after resetting the binding.

The three native functional cycles, explicit stable-ID updates, real canvas reuse and one visible hidden-controls notice remain evidence for `u676`. On rebuilt `gZRuKyGJ`, only the correctly attributed existing-card camera framing is live-verified. Its effective macOS permissions block further restriction testing. Physical native global-key delivery, isolated browser connection/tab behavior, full composited blur/input behavior, new-draft layout and broader display cases, save retries, manual notice dismissal, focus preservation and the broader accessibility matrix remain outstanding.

The comprehensive suite has passed and the rebuilt Swift artifact has passed build/signature verification. No new browser UI attempt, effective `gZRuKyGJ` permission grant or physical-global-key pass is claimed.

## Historical cleanup of the earlier resumed turn

The guide was closed with **Continue later**, then QA was quit through its native Quit control. A subsequent process check found no Intent QA, daily Intent or QA Firefox processes. Final checks confirmed unchanged hashes for all three daily intention/schedule/cooldown files, inactive QA browser rules, and exactly one saved QA entry retaining ID `BE41729E-191E-48F2-917E-D03A50EE6C0A` with name `QA final layout`.

No QA native-host manifests remained; the QA Firefox profile was not registered, the original `ykomjweq.default-release` default was retained, and no QA Chrome profile was present. The new Chrome packaging command passed, and `gZRuKyGJ` again passed deep/strict signature verification. Private QA data and artifacts remain for resumption. The daily app was not replaced; it is currently closed. No release, push or deployment is claimed by this report.

## Later permission recovery and physical-key handoff

After the user asked what to do next, the unchanged `gZRuKyGJ` artifact was opened again. Read-only inspection confirmed valid signatures and matching QA plists, but different designated cdhash requirements between old `u676` and `gZRuKyGJ`. The guide polls the actual macOS APIs every two seconds; no stored permission override was introduced. A stale old-code permission entry was the working diagnosis, not a finding from direct TCC database access.

Through System Settings, only the **Intent QA** entries were selected and removed, then the exact `package-gZRuKyGJ/Intent QA.app` was added back. Actual selected-row state was verified before removal; other apps and daily Intent were untouched. The guide first changed to **Accessibility Ready**. After the same supported replacement for Screen Recording and **Quit & Reopen**, it changed from the permission gate to **Press ` once** with **Open the picker instead**, confirming both effective grants in the running candidate. No password prompt was required in this recovery.

Exactly one QA process was observed, PID `79524`, at the intended `gZRuKyGJ` path. At this permission-recovery checkpoint, no new restriction session had started, browser rules were inactive and daily data hashes remained unchanged. Calculator was raised for the user to physically press backtick once and Esc. The subsequent user confirmation and final-candidate runs are recorded below; this recovery superseded the earlier effective-permission blocker and stopped-app state.

## Final-candidate native cycles — 20 September 2026

The same unchanged `package-gZRuKyGJ` candidate, PID `79524`, was used after the permission recovery. No application source changes, rebuild, extension installation or publication occurred during these observations.

The user reported **“yes it did open. and i was able to close it”** after the physical single-backtick picker and Esc check. This confirms those two physical actions only; it does not establish double-backtick, held-backtick chords or physical emergency-stop delivery. Before the new restriction runs, the menu **Safety Stop** was invoked while idle, its actual all-restrictions-released alert appeared, and the alert was dismissed.

Three consecutive native cycles used purposes `Final native check 1`, `Final native check 2` and `Final native check 3`:

1. Enter the purpose in the guide, use the button to open the picker, choose Block Calculator, and configure a one-minute Timer plus the single checklist task `Finish QA step`.
2. Start the actual run at `01:00`, then check the task to end it before the timer deadline.
3. Choose **Try the quicker way**, skip the quick-mark skill, explicitly **Update** the existing saved setup, and choose **Show on canvas**.
4. Observe the actual saved card above distinct Timer and checklist nodes, with clean connections and all nodes inside the viewport; this layout was captured in each of the three cycles.
5. Run the saved setup again. Cycles 1 and 2 used an actual canvas double-click. In cycle 3, a coordinate click returned `windowNotFoundAtPosition`; refreshed accessibility output exposed **Run my saved intention**, and that real button successfully started reuse. The guide acknowledged actual reuse.
6. Choose **Let me do my thing** to close the guide while its timer remains active, then check the task to end the reused run. The last observed dashboard was idle.

These observations verify the corrected local draft geometry across repeated newly constructed setups, full-group canvas framing, checklist-first completion, explicit update UI, actual native reuse and guide closure during an active run on the final candidate. The separate read-only integrity checkpoint below verifies persisted identity, geometry and daily-state preservation. Skipping quick marking did not demonstrate that skill, and the button-driven picker entry in these cycles is distinct from the user's separate physical-key check.

At this native-cycle checkpoint, a further Chrome **Add profile** attempt again produced blank accessibility output and no available image. The user was asked to create an unsigned-in `Intent QA` profile. No extension was loaded and QA native-host registrations were absent at that checkpoint; the later successful Chrome setup and bounded browser runs are recorded below.

## Post-cycle integrity checkpoint — not final cleanup

Read-only checks after `Final native check 3` confirmed:

- Exactly one saved QA intention, named `Final native check 3`, retaining ID `BE41729E-191E-48F2-917E-D03A50EE6C0A`.
- Block mode, a one-minute Timer and one checklist task, `Finish QA step`, were persisted.
- The saved card anchor was `(340, 0)`, Timer position `(580, 260)` and Checklist position `(100, 260)`: the intended local offsets `(+240, +260)` and `(-240, +260)` were preserved.
- All three daily intention/schedule/cooldown hashes were unchanged, and QA browser rules were inactive.
- Only QA PID `79524` was running at the exact final artifact path; deep/strict signature verification returned exit code 0.

The last observed native dashboard was idle. This is an integrity checkpoint while the test app remains available for continued QA; it does not claim final process shutdown or completion of the browser-profile handoff.

## Skip both skills, keep the saved setup and replay

A subsequent non-enforcing flow used the same final `gZRuKyGJ` candidate:

1. Settings → **Show quick guide** opened welcome; **Begin** reopened purpose entry, which was changed to `Replay without saving`.
2. **Choose** advanced, **Back** returned with the purpose preserved, and **Choose** advanced again.
3. **Skip this skill** skipped overview, and the next **Skip this skill** skipped quick marking.
4. The save page identified the existing `Final native check 3` setup. **Continue without another save** reached **Start with what you came to do**, with the truthful explanation that skipped skills are not learned and no false first-run success claim.
5. A screenshot showed `2:26` and the calm **Take your time** message. **Replay the guide** returned to welcome; **Begin** visibly reset the countdown to `3:00` while retaining `Replay without saving` in the purpose field.

No intention was run and no save was requested in this sequence. This verifies skipping both skills, Back/purpose preservation, continuing without an additional save when a saved setup already exists, and explicit replay with a fresh countdown. It does not cover the fresh-user **No thanks** variant or quitting and relaunching between every step.

The real countdown was then observed on the same purpose-entry step: screenshots showed `3:00` at Begin, `0:41`, actual `0:00`, and `-0:08`. The purpose remained `Replay without saving`, the calm **Take your time** message remained visible, and accessibility output showed no stage change. There was no automatic advance or reset. This captures zero followed by negative time on the final candidate; the exact individual `0:01` and `-0:01` frames were not captured.

## Historical verification boundary before Chrome integration

Effective permissions and three bounded native cycles are now observed on the unchanged final `gZRuKyGJ` candidate. All three saved layouts were clean and in bounds, and each saved setup was actually reused. Physical single-backtick picker entry and Esc closure are user-confirmed. The earlier `u676` timer-expiry, hidden-controls notice and other historical observations retain only their stated candidate and scenario scope.

These are three native cycles, not three fully integrated acceptance passes. Live Chrome/Firefox extension behavior, other physical global chords, native quick marking, complete desktop blur/input blocking, physical IME entry, broader display/accessibility conditions, manual notice dismissal and focus preservation remain outstanding. The post-cycle checkpoint confirmed one stable saved ID, correct modifier geometry, unchanged daily hashes, inactive QA browser rules and a valid final signature. The native runs ended at an idle QA dashboard; the subsequent guide replay and countdown observation started no active intention. QA was subsequently quit and cleanup verified below. The daily app was not replaced.

## Historical cleanup after native cycles and countdown

**Continue later** closed the guide, the actual idle dashboard was observed, and **Quit Intent QA** stopped the app. Read-only final checks found no QA or daily Intent processes, inactive QA browser rules, and unchanged hashes for all three daily intention/schedule/cooldown files. The saved QA collection still contained exactly one `Final native check 3`, with the same stable ID; skipping/replaying had not duplicated or renamed it.

Both QA native-host registrations were absent. No QA Chrome profile had been created and no QA Firefox profile was registered; Firefox retained its original `Profiles/ykomjweq.default-release` default. Chrome's profile setup remained blank to automation, and the user handoff to create an unsigned-in `Intent QA` profile was pending at that checkpoint. No QA extension was installed. Private test artifacts and saved QA evidence were retained; daily Intent remains closed and its bundle/data unchanged. Only this ledger was edited in this continuation; no new application source changes, rebuild, push, release or deployment occurred.

## Isolated Chrome connection and bounded browser scenarios

The user completed profile creation. Chrome's own version/profile UI verified the unsigned-in `Intent QA` profile as `Profile 7`. QA Browser Guard `0.2.12` was loaded from its isolated source fixture and connected through its own QA native host; the heartbeat advertised all six required capabilities. A local test server at `127.0.0.1:18765` supplied controlled fixtures. The six-tab window contained page A1, a duplicate A2, page B, a PDF, Chrome Settings and New Tab.

The picker required its explicit browser-window chooser because native window mapping was ambiguous alongside the personal Chrome profile. The six-tab QA window was chosen explicitly. This is an exercised recovery path, not evidence that ambiguous windows were automatically matched.

| Scenario | Actual observation | Limits |
|---|---|---|
| Block PDF, Settings and New Tab | The screenshot showed those three tabs selected green in the picker. A two-minute Block session published rules for exactly their three tab IDs. Selecting each returned to allowed A1, and all six tabs remained in Chrome. A1's counter reached 1; navigating to channel 2 retained that counter. App-directed Safety Stop displayed its release alert and ended the run. | This covers the selected-ID block policy, retention of tabs and allowed-tab state in the exercised fixture. It does not prove physical global shortcut delivery or full composited blur. |
| Allow only A1 | Reopening the picker acquired a fresh snapshot with all six original IDs and the same browser-session nonce. A two-minute Allow session selected only A1. Selecting duplicate A2 returned to A1. A1's counter reached 2; channel 1 retained 2. Following A1's link to `localhost` page B worked and the destination button worked. Active rules and snapshot showed A1's same selected ID with its changed URL; all six tabs and the nonce were retained. The timer ended automatically and rules became inactive. | This covers duplicate-tab identity and navigation to another site through the allowed tab without pinning its old URL. The expiry notice was not visually captured in this run. |
| Select all / clear all / block all | X selected all six tabs, X again cleared all, and X again selected all six. Return started a one-minute Block session at actual `01:00`; rules contained exactly all six IDs. Safety Stop later displayed its release alert and ended the session. | This verifies the picker selection shortcut, exact rule selection and session start/stop. Physical whole-window input blocking remains inconclusive, as detailed below. |

During the all-tabs-blocked run, CUA accessibility and coordinate clicks on **Add one** incremented an existing page's counter. Read-only native input diagnostics later reported `scanState=not-frontmost-browser`, `mouseDownEvents=0` and `blockedClicks=0`. These attempts therefore did not demonstrate delivery through the native physical-input guard. No physical pass/fail or product fix is concluded from this observation. Source inspection explains the boundary: the content guard defers selected-tab-ID policy, DNR covers new navigation rather than an existing page button, and whole-window existing-content input protection depends on the native event tap.

A captured `254×39` surface had empty accessibility content. Source inspection indicates it was likely a tab-blur overlay owned by Intent QA, rather than the `336×140` running-controls panel. That attribution is an inference; the surface is not used to claim timer-control rendering or visual blur acceptance.

No implementation changes were made to obtain these Chrome observations. There was no new Firefox test. These are three bounded Chrome scenarios: two exercised the connected bridge's policy and tab behavior, while the third established group selection and execution only. They do not complete the outstanding fully integrated acceptance matrix.

## Newly reproduced Settings command defect

Cmd+, reproduced a real additional UI defect: SwiftUI's retained empty Settings scene opened instead of Intent's actual settings. The source fix replaces the default app Settings command, routes an explicit presentation request through `IntentAppModel`, and opens the existing canvas Settings popover in `IntentGraphView`. It defers the guide while preserving its progress and does not stop an active intention.

Independent read-only review found no confirmed regression in the current single retained canvas lifecycle. The subsequent release build and packaging passed with exit code 0, including deep/strict signature verification, in 269.18 seconds (`/tmp/intent-settings-command-build.log`). The new artifact is `package-ksf8n4nv/Intent QA.app`; exact path and sole QA PID `77673` were verified.

Live app-directed checks on `ksf8n4nv` then established:

- Cmd+, opened the actual Settings controls, confirmed through accessibility output and a screenshot.
- Cancelling the popover and pressing Cmd+, again reopened the real controls.
- Dismissing Settings, hiding the dashboard and reopening the app did **not** reopen Settings unexpectedly.
- Cmd+, → **Show quick guide** retained purpose `Replay without saving`; Cmd+, while the guide was open returned to Settings, and **Show quick guide** again retained the same purpose.

These are actual UI checks using app-directed input, not new physical-global-shortcut evidence. This focused release/package and live verification is subsequent to the earlier combined three-repetition automated run; no new full-suite repetition is claimed.

## Historical Settings-candidate authentication handoff and checkpoint

At this checkpoint, the new `ksf8n4nv` binary showed the real permission gate, so effective grants were not yet claimed for it. Earlier grants to another ad-hoc binary are not assumed to transfer. Supported replacement of only the QA Accessibility entry was initiated in System Settings: the selected **Intent QA** row was verified through accessibility state before Remove, and macOS displayed a Touch ID/password authentication sheet. User authentication was pending. No completed removal or replacement was claimed at that point; other applications' permission entries were not changed.

There was no active QA intention. A read-only checkpoint confirmed unchanged hashes for all three daily intention/schedule/cooldown files, inactive QA browser rules and one saved QA intention. The exact new artifact remained the sole verified QA process, PID `77673`. These are checkpoint results during the authentication handoff, not final cleanup.

Separately, while the app was stopped, the Chrome QA extension was disabled and re-enabled through its UI. The QA host observed disabled/enabled state, then recovered a heartbeat aged 0.8 seconds at version `0.2.12`. A seventh popup tab was added to the QA fixture; the six original tabs remained unchanged. This verifies the exercised reconnect path without claiming another restriction run. No new Firefox coverage was added.

## Settings-candidate permission recovery and process attribution

Authentication subsequently completed. The old QA Accessibility entry was absent; the exact `package-ksf8n4nv/Intent QA.app` was added, its switch was on, and the guide visibly reported **Accessibility Ready**. The selected QA Screen Recording row was then replaced through the supported remove/add controls using the exact same artifact, followed by **Quit & Reopen**.

macOS unexpectedly reopened the older `gZRuKyGJ` artifact as PID `88747`. Binding the exact `ksf8n4nv` app also launched PID `88794`. No enforcing run occurred during this two-candidate ambiguity, and that interval is not used as permission or restriction acceptance for the new candidate. Both apps were quit through their own UI, and a process check confirmed no QA processes before the exact `ksf8n4nv` app was relaunched alone as PID `89622`.

On this sole verified process, Cmd+, opened the actual Settings UI; **Show quick guide** preserved `Replay without saving` and the permission gate cleared to **Press ` once**. This verifies recovery of the running candidate's effective gate after supported QA-only permission changes, rather than assuming an old grant transferred. No enforcement run is claimed by this recovery; final smoke testing and cleanup follow separately.

## Final Settings-build native smoke

The following observations used only the verified `ksf8n4nv` process, PID `89622`:

- Cmd+, still opened the actual Settings controls, and the guide retained its purpose. After closing the guide, File → **Safety Stop** while idle displayed the all-restrictions-released alert.
- Double-clicking the saved `Final native check 3` card started its real one-minute run, with `01:00` and task progress `0/1` visible.
- Cmd+, during the run opened the real Settings popover. The dashboard still showed `Final native check 3` at `00:56`, with **End** disabled because the run was locked.
- Cancelling Settings left the timer running at `00:48`. Hiding the dashboard exposed the running controls at `00:43`.
- Clicking the `Finish QA step` checkbox closed the controls before the timer deadline. QA browser rules were inactive, and reopening the exact app showed an idle dashboard.

This verifies that Settings presentation preserved the active run and that checklist-first completion worked on the latest build. It does not establish physical blocked-input behavior or composited blur. No new saved entry or save/update operation is claimed for this smoke run.

A fresh read-only checkpoint after this smoke confirmed that all three daily `~/.intent` intention/schedule/cooldown hashes still matched the original baseline, QA `browser-rules.json` had `active: false`, and the QA saved collection still contained exactly one intention.

The Chrome QA **A Notes** tab was then raised for a selection-only physical double-backtick quick-mark check, with no active intention. At that handoff, the `ksf8n4nv` QA app and isolated Chrome fixture were left ready; the user response and resulting defect are recorded below. The integrity checkpoint was complete; fixture cleanup was not.

## Physical Chrome quick mark and leftover modifier bar

The user physically confirmed that double-pressing backtick outlined the Chrome tab. This establishes the exercised native shortcut and visible tab outline on the tested `ksf8n4nv` candidate, independently of earlier inconclusive app-directed key attempts. No marked intention was run during this check.

The same check exposed a real UI defect: after the final selected tab was unhighlighted, the bottom modifier bar remained visible. The leftover bar was confirmed through accessibility output and a screenshot. The controller retained a draft even with no selected targets, and the former presentation path did not require nonempty targets before showing the staged bar.

The focused fix changes only `QuickSelectionView.swift`:

- Staged-bar visibility now requires actual selected targets or an explicitly open modifier editor, outside the overview and any active run.
- Opening a modifier first establishes its editor before showing the bar, so configuring a modifier before selecting targets still works.
- Closing an editor rechecks empty selection, and unmarking the final target hides the bar while retaining draft settings.
- Shared outline refresh stops its worker when the selection is empty or the overview is open, and closing the overview clears its editor state.

Peer source review found no blocker. The Core regression command returned exit code 0: release CoreSpec built in 270.71 seconds, Quick gesture regressions passed 100 sequences, Onboarding presentation specifications passed, and IntentCoreSpec passed (`/tmp/intent-staged-modifiers-core.log`). These existing checks include target/group clearing; no new tests that merely mirror the visibility implementation were added.

The QA app build and package command returned exit code 0 (`/tmp/intent-staged-modifiers-build.log`): release IntentApp compilation took 224.60 seconds, and the package passed deep/strict signature verification. The new artifact is `/Users/loganmondi/.codex/artifacts/intent-qa/package-35yHyFJm/Intent QA.app`. There were no extension changes, so no additional extension test reruns are claimed. No push, release or daily-app replacement occurred.

## Modifier-bar candidate permissions and bounded UI check

Only the QA Screen Recording entry was replaced through supported remove/add controls using the exact `35yHyFJm` artifact. **Later** was chosen instead of macOS reopening an older app; QA was quit, no QA process remained, and the exact artifact was launched again. The QA Accessibility entry was also replaced using the exact path. No user authentication prompt was required for these replacements. The sole verified QA process was PID `26599` at the `35yHyFJm` path.

File → **Quick Focus** opened the actual picker, confirming the effective permission gate passed for this candidate. With zero targets selected, clicking **Timer** enabled its editor and visibly showed Duration `25`, **Duration** and **Set end time**. **Done** closed the popover. Closing the picker returned to the dashboard without a stray bar; the dashboard was then hidden.

This is a bounded overview/editor check. It does **not** reproduce or accept the reported staged-draft sequence of physically marking and then unmarking the final tab. Chrome QA **A Notes** was raised, but two CUA backtick presses produced no UI change and are inconclusive for native physical input. A user check is pending: physically mark, wait one second, then unmark the tab and observe whether the bar disappears. No intention was started during these checks. A fresh read-only checkpoint confirmed all three daily hashes unchanged, QA rules inactive, one saved QA intention and a Chrome QA heartbeat aged 1.7 seconds. The QA app, profile, host and fixture are retained for the pending physical regression check; cleanup is not complete.

## Current verification boundary and fixture state

The three native `gZRuKyGJ` cycles, clean new-draft layouts, save/reuse, skip/replay and countdown observations remain valid within their recorded scope. Isolated Chrome is now connected, with bounded live evidence for exact tab-ID selection, protected/internal-tab blocking, duplicate-tab identity, same-tab navigation and retained tabs. Physical single-backtick picker entry, Esc closure and the tested double-backtick Chrome tab outline are user-confirmed. Other physical chords, broader quick-mark target coverage and a successful marked intention run remain outstanding.

Full composited blur and physical input blocking, Firefox integration, broader display/accessibility conditions, physical IME entry, manual notice dismissal and focus preservation remain unverified. The all-tabs-blocked CUA result is explicitly inconclusive for physical input. Three fully integrated passes remain incomplete. The later ksf8n4nv Settings build, effective-gate recovery and focused live checks passed on sole PID 89622. Its saved native smoke also verified Settings during an active run, disabled manual End and early checklist completion. No browser-policy, composited-blur or physical-input-blocking pass is claimed for that new binary. The user-confirmed Chrome marking subsequently exposed a leftover staged modifier bar; its focused source fix passed Core/build/package/signature checks and a bounded overview editor test on sole 35yHyFJm PID 26599, but exact physical final-unmark acceptance remains pending.

At this checkpoint, Chrome `Profile 7` still contains the QA extension and seven fixture tabs, its QA native host exists, and the local server on port `18765` remains available. The latest 35yHyFJm QA app is running alone as PID 26599 with no active intention, ready for the exact physical mark/unmark check. Fixture cleanup remains pending; earlier absent-host/profile and stopped-process checks are historical, not the current fixture state. No release, push, deployment or daily-app replacement is claimed.

## Remaining live matrix

| Priority | Scenario | Status / required evidence |
|---|---|---|
| 1 | Final build, signature and regressions after panel/focus changes | Earlier combined suite passed three repetitions and gZRuKyGJ build/signature checks passed. Chrome corrections have targeted mock/negative-control coverage plus the bounded live scenarios below. The later ksf8n4nv Settings-command release/package/signature checks passed, followed by Settings reopen/dismiss/dashboard-reopen, guide-purpose retention and Settings-during-active-run checks. The newer staged modifier-bar fix passed existing CoreSpec, including 100 quick-gesture sequences and onboarding presentation specs; its QA release build/package/deep-strict signature checks passed (224.60s App build). The overview modifier editor passed a bounded UI check; exact physical final-unmark verification remains pending. No new complete three-repetition suite is claimed. |
| 1 | Fresh first launch, guide layering and welcome/purpose keyboard focus | Automatic welcome, purpose-field focus and CUA typing/Return observed on `package-u676apjy`; physical keyboard and varied display/focus conditions remain pending. |
| 1 | Blank/whitespace, long input, physical Unicode/IME entry | Empty/whitespace rejection, long Unicode retention, bounded header and CUA Return observed; physical typing/IME still pending. |
| 1 | Edit purpose from a later step, Back, close/resume and quit/relaunch | Purpose edits and explicit saved updates worked in the native cycles. The later final-candidate flow verified Back/purpose preservation and explicit replay to a visible 3:00 with the purpose retained; prior close/resume persistence was observed. Broader quit/relaunch combinations remain pending. |
| 1 | Real `0:01 → 0:00 → -0:01` countdown | Final gZRu screenshots show 3:00, 0:41, actual 0:00 and -0:08 on the same purpose-entry step, with calm copy and no advance/reset. Zero followed by negative time is observed; the exact 0:01 and -0:01 frames were not captured. |
| 1 | Skip both skills, decline saving, finish and explicit replay | Final gZRu skipped both skills, truthfully left them unlearned, continued without another save of the existing setup, and replayed to 3:00 with purpose retained. Fresh-user No thanks remains untested; this flow started no intention and requested no save. |
| 1 | Grant QA permissions and observe the guide's real refresh | Recovered for gZRuKyGJ before its native/Chrome runs. Supported QA-only entry replacement also cleared the gate for ksf8n4nv, confirmed after removing a mixed-candidate launch and relaunching it alone as PID 89622. No enforcing run occurred during process ambiguity. The later 35yHyFJm candidate also passed its effective gate after QA-only entry replacement, with File → Quick Focus opening the actual picker on sole PID 26599. |
| 1 | Emergency release and bounded fallback before restriction testing | Earlier app-directed emergency chord released the pilot. The final native-cycle idle menu check and later Chrome Safety Stop paths displayed release alerts and ended the exercised runs. Physical emergency-chord delivery remains unverified. |
| 2 | First actual intention run through the overview and native global shortcut | Three final-candidate native cycles used the real picker button, started at `01:00`, completed and reused saved setups. Separately, the user confirmed physical single-backtick picker entry, Esc closure and double-backtick Chrome tab outlining. Other chords and a successful marked-run workflow remain pending. |
| 2 | Timer and checklist completion | Earlier `u676` timer expiry and two-task checklist completion passed. Three final `gZRuKyGJ` one-minute Timer + one-task Checklist cycles, plus their reuses, ended through the checkbox before the deadline. The latest ksf8n4nv saved smoke did the same after Settings was opened during the active run. |
| 2 | Composited blur, input blocking and overview previews | Actual preview images/scaled sizes observed. All-tabs-blocked CUA clicks changed a page counter, but diagnostics recorded zero native mouse events and a non-frontmost browser; physical input protection is inconclusive. The tiny likely tab-overlay capture does not prove visual blur acceptance. |
| 2 | Actual native quick-mark shortcut, staged targets and successful run | Physical double-backtick Chrome marking and its outline are user-confirmed on ksf8n4nv. Unmarking the final tab left a reproduced modifier bar; the focused visibility/lifecycle fix passed build/package/signature checks and the overview editor check, but exact staged last-unmark verification still awaits the user's physical input. A successful marked run and broader target coverage remain pending. |
| 2 | Isolated Chrome and Firefox fixture connections | Unsigned-in Chrome Profile 7 connected QA Browser Guard 0.2.12 through its own host, with all six capabilities. Exact-ID block/allow, internal tabs, duplicate identity, retained tabs and same-tab navigation were exercised. Disabling/re-enabling the QA extension while the app was stopped recovered its 0.2.12 heartbeat at 0.8 seconds old; the original six tabs survived a seventh popup tab. No new Firefox test; fixture cleanup is pending. |
| 2 | Optional save, canvas click/reuse, edited name and explicit stable-ID update | Earlier `u676` stable-ID/count checks passed. Three final `gZRuKyGJ` cycles explicitly updated the saved setup, showed clean newly constructed layouts and actually reused it: twice by canvas double-click, once by the real Run my saved intention button. The post-cycle checkpoint confirmed one stable saved ID and correct persisted geometry; save retries remain separate. |
| 2 | Guide closure/resume during a real session and preservation of earlier marks | In all three final-candidate reuses, Let me do my thing closed the guide while the timer continued; checking the task then ended the run. Pre-existing staged-mark preservation remains pending. |
| 2 | Independent expiry notice with hidden controls | Resumed `QA replay3` expiry produced the actual visible notice and eight-second dismissal. Manual dismissal, focus preservation and full desktop composition remain unproven. |
| 2 | Three integrated live selection/run/stop/save/replay passes | Three native onboarding/save/reuse cycles and three bounded Chrome scenarios are recorded separately. Two Chrome scenarios exercised connected policy/tab behavior; the third covers group selection/execution, with physical blocking inconclusive. These are not three fully integrated passes; Firefox, quick marking and physical-input acceptance remain incomplete. Focused Settings acceptance, effective-gate recovery and a saved native smoke passed on ksf8n4nv, including Settings during an active timer and early checklist finish. Physical Chrome marking succeeded, but its final-unmark bar cleanup exposed a reproduced bug whose fix is built and partially UI-checked on 35yHyFJm; the exact physical final-unmark case remains unverified. |
| 2 | Keyboard-only access, VoiceOver, reduced effects, small/multiple displays | Pending; no accessibility acceptance claimed. |
| 3 | Uncoached first-user study and independent shortcut recall | Not run; see the [research test script](onboarding-research-2026-09-19.md#short-uncoached-first-user-test). |
| Final | Cleanup, QA rules/processes/hosts, daily state hashes and daily app restoration | The pre-recovery checkpoint confirmed unchanged daily hashes, inactive QA rules and one saved QA intention. After supported permission recovery and removal of mixed-candidate processes, sole QA PID 89622 matches ksf8n4nv. Chrome Profile 7 extension/host, seven fixture tabs and server 18765 remain present; the saved native smoke ended at an idle dashboard. Fresh post-smoke checks confirm all three daily hashes match baseline, QA rules are inactive and one QA intention remains. Following the physical quick-mark report, 35yHyFJm is the sole QA process (26599), with no intention started during its checks. Fresh post-build checks confirm unchanged daily hashes, inactive rules, one saved QA intention and Chrome QA heartbeat age 1.7s. Exact physical final-unmark verification is pending; app/profile/host/fixture are retained and cleanup is not complete. |

AI Mode, Purpose Mode, scheduler, publication, daily-app replacement and unrelated projects remain outside this pass.
