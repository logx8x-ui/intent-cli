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

- Final Firefox archive: `dist/firefox/intent_browser_guard-0.2.28.zip`. Mozilla approved version 6539802 / file 5083944 on October 4. Signed package is downloaded and installed in the default Firefox profile. Active profile and fresh native heartbeat confirm 0.2.28; full-browser restart persistence and remaining live acceptance are separate outstanding checks.
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
| Final Firefox package in actual default profile | Signed permanent 0.2.28 installed; exact XPI bytes and fresh 0.2.28 native heartbeat verified |
| Final active-session live matrix | Firefox native-created selected/fresh-tab lifecycle and website rejection passed; same-window completion regression reproduced and under repair. Chrome rejection/additions remain pending. |


## Resumed live pass and coordination, October 4

- Coordinated explicitly with **Intent - Fix a Bug**. That chat owns Caps Lock input, fixed notch session controls, completion animation and delayed native focus-action cancellation. This pass owns browser signing and browser QA. Only one chat controls the desktop/install at a time; no unrelated edits were staged or installed.
- Mozilla accepted final Firefox 0.2.28 with zero validation errors/warnings and approved AMO version **6539802**, file **5083944**. Downloaded signed XPI: `dist/firefox/485649d659c2420c9778-0.2.28.xpi`, SHA-256 `5531ee3d05019a6c69deea4bb2c3a07bce4d6cca6d87c5af4f4566f2afe232ae`. Signature metadata is present. All submitted payload files match; the manifest differs only in JSON formatting. No public update-feed or release changes.
- Actual default Firefox profile remains `ykomjweq.default-release`, signed permanent **0.2.25**. The Mac locked again when opening the downloaded XPI for installation. Approval/download is **not** installed-profile acceptance.
- On installed Mac build `2f17c4f` and Chrome Browser Guard **0.2.28**, a real UI-created intention selected exactly two QA tabs, with **Tab searches + Stopwatch**, Add as you go off. Passive rules confirmed both exact IDs and policy. Pre-existing unselected tabs, including an old Google search, were parked. Five native tab-click switches and creation/use of a fresh Google search passed.
- During typed website rejection from that fresh search, the intention became inactive after about 75 seconds, and old tabs returned. The check is **inconclusive**, not a pass. App PID remained unchanged, and the other chat confirmed no UI, install, process-test or real-state activity. The journal has no timer, checklist or recovery checkpoint. The configured finish shortcut is Shift+backtick, unrelated to Cmd+L/Return.
- Source audit found that loss of all selected tab IDs can finish this quick-selection session normally. Current empty snapshots after finish are expected idle behavior and cannot establish the trigger. The QA tabs were created using the browser automation wrapper; repeat with native-created tabs and passive transition capture before attributing this interruption to Intent.
- Remaining: signed Firefox installation, matching-profile tab lifecycle/add-as-you-go/focus checks, repeat Chrome typed-navigation check, and coordinated acceptance after the other chat's combined native build. Physical key/mouse timing remains a separate unverified acceptance item.

### Later unlocked installation

- Installed the approved signed XPI through Firefox's normal file/update UI with the same extension ID and unchanged required permissions; private-window access was not enabled.
- `check-firefox-installation.py --profile .../ykomjweq.default-release` confirms a matching permanent package. Installed XPI bytes exactly match the signed download. A fresh Firefox native heartbeat reports **0.2.28**; Chrome also reports **0.2.28**.
- Explicitly handed sole desktop/install ownership to **Intent - Fix a Bug** for combined source `a463b9a`. Browser QA will resume after that install and handback. Firefox full-browser restart persistence is not yet claimed.

- Combined source `a463b9a` was subsequently installed by the other chat using system Python. Passive `dwarfdump` here independently confirms the daily executable UUID **6B436395-ECEB-3C3E-99F5-13935DC60BB4**, matching its QA build. Browser heartbeats still report 0.2.28. Native/live checks remain owned by that chat until explicit handback.

### Native-created Firefox acceptance and reproduced restoration defect

- After desktop handback, repeated Firefox on installed `a463b9a` with permanent signed Browser Guard **0.2.28** using native-created QA tabs, avoiding automation-owned ephemeral tabs.
- Selected two exact QA tab IDs with Tab searches and Stopwatch enabled, Add as you go disabled. Old unselected search/blank tabs were parked. Repeated Sidebery clicks between selected tabs and a fresh Google search remained usable without ending the session.
- Typed website navigation and an actual search-result click from the fresh search were rejected; the Google search remained available. Moving a selected tab to another window, closing that window, closing the fresh search and restoring it via the browser's undo-close command all retained a valid active intention.
- A synthetic Shift+backtick attempt did not finish the session. This is inconclusive for physical hardware delivery; native File > Finish Intention completed it.
- A PID-only foreground check initially stayed on Firefox, but a stricter passive CG-window observer exposed a real failure. The working window **12687** was on screen before finish, then older Firefox windows **11783/11787** appeared and window12687 became off-screen while still existing. No CUA inspection ran during the observation interval.
- Reproduced twice with only QA tab15 selected. During the second active session, native `hidden-workspace.json` owned only non-Firefox apps (Chrome, Spotify, RemNote, Codex), narrowing the older Firefox-window restoration to the extension/browser path. The native guard recorded `windowUnavailable` roughly0.55–0.61seconds after finish because its existence check used an on-screen-only inventory.
- Local passive traces: `/tmp/intent-firefox-window-finish.jsonl` and `/tmp/intent-firefox-ownership-finish.jsonl`. These prove off-screen displacement, not whether the working window was minimized, covered or moved between Spaces.
- Broader QA paused at this reproduced failure. **Intent - Fix a Bug** owns the exact-window guard fix and passive diagnostic instrumentation; this chat retains browser review and desktop ownership until coordinated install. Fix acceptance is not yet claimed.
- Desktop crash review found a repeated ChatGPT EXC_BREAKPOINT/SIGTRAP signature in the browser/V8 main-thread path; cause remains unproven. Reduced UI/output volume is a precaution, not a verified crash fix. No desktop-app restart or profile mutation was performed.
- Read-only browser follow-up exercised the real visibility class and runtime allowed-tab callback across48 isolated finish schedules around async boundaries. No working-window minimization occurred. This rules out the suspected queued dynamic-callback race in those schedules, but cannot model Firefox/macOS window-restoration side effects. No browser change was made on speculation.

### First installed lifetime candidate: failed live acceptance

- Installed UUID **0DA4C920-7D41-340F-BD92-0E9A5D20FF4C** matched the tested native candidate. Same exact tab15/window12687 reproduction still failed.
- App-owned diagnostics now show target exists, initially `AXMinimized=false`, then off-screen at0.665seconds; repeated AX timeouts precede `spaceChanged` at0.923seconds. No user or CUA input occurred during passive sampling. The candidate's unconditional Space-change cancellation therefore stops recovery during a restoration-induced desktop change.
- This is a failed acceptance result; shared with the native owner for correction. Source/browser packages are not declared release-ready. Trace: `/tmp/intent-firefox-candidate-finish.jsonl`.

### Browser-only restoration isolation

- Ran a temporary blacklist session selecting every tab in the two older Firefox windows, leaving the QA working window allowed. Verified native `hidden-workspace.json` was exactly `[]` while active.
- Finishing still restored11783/11787, moved12687 off-screen and emitted `spaceChanged` at0.597seconds. This proves Firefox restoration is sufficient to cause the desktop displacement without native app hide/unhide operations. `/tmp/intent-firefox-browser-only-finish.jsonl` records the passive CG-window transition.
- Found an observer limitation: repeated `NSWorkspace.frontmostApplication` calls in a standalone process using `Thread.sleep` may retain cached activation state. Prior PID-only samples are not authoritative. The helper now runs its run loop between samples; direct CG-window inventory transitions and app-owned diagnostic events remain the evidence for this defect.
- No permanent blacklist or saved intention was created. Rules inactive after the test. Native owner is evaluating bounded exact-window recovery before any product-policy change.


### Native AX restoration comparison and coordinated bridge

- Ran the same browser-only isolation with only the two known, extension-minimized Firefox windows temporarily recorded in the native restoration ledger, bound to their exact PID and process launch date. The production `FocusVisibilityController.restore()` path restored via AX before clearing browser rules.
- In `/tmp/intent-firefox-ax-comparison-finish.jsonl`, working window12687 remained first and on screen throughout the passive observation. App diagnostics completed the five-second guard without a Space change. This proves the tested restoration ordering preserves the working window; it does not yet prove the new protocol end to end.
- Read-only Firefox extension inspection subsequently confirmed all three browser windows (3,9,303) were maximized, with none minimized. One native ledger entry survived an AX timeout despite successful restoration; the native owner cleaned only that known fixture after the browser readback. Root-created inspector and debugging tab were closed.
- Implementing Browser Guard0.2.29 and a negotiated native ownership protocol: native owns whole user-window hide/restore; the extension retains tab order/parking. New parking windows require a durable native identity receipt before user tabs move into them. Missing receipts never fall back to browser restoration during the active browser lifetime.
- Both background pipelines now process native receipts before awaiting serialized rule application, avoiding a circular wait. Add-as-you-go heartbeat retries the original durable inventory until setup succeeds, while newly opened tabs remain allowed.
- Full extension suite and Mozilla lint passed after this integration (zero lint errors/warnings/notices). New tests cover receipt timeout/rejection/disconnect, worker restart, unknown parking identity, exclusive ownership, migration, orphan reveal retries and initial inventory retries. The new package has not yet been signed or installed.
- Independent review identified and corrected a full-Firefox-restart orphan recovery gap. Persistent Firefox markers now preserve native browser/process/session and original parking identities. A same-process extension reload uses only native recovery; a confirmed full browser restart can recover its own marked orphan windows only with explicit host authorization, inactive rules and unchanged generation after the reply.
- The new restart regression resets session storage and browser window/tab IDs while preserving Firefox's session markers. Disabling the new recovery path makes that regression fail with the orphan window still minimized; the implementation passes. Additional cases cover denied/retried recovery, missing helper plans, new-intention/process-change cancellation, missing process proof before tab movement and temporarily unavailable source windows.
- Final extension suite and release-readiness consistency checks passed. These establish automated behavior only; signing, matching installed components and the original live finish reproduction remain pending.

### Recovery and readiness follow-up before signing

- Chrome now writes a durable local shadow of the parking ledger before moving tabs. A verified same-process extension update can restore source positions; a full browser restart uses strict random UUID holder URLs and native authorization rather than applying recycled numeric IDs. Delayed session-window loading retains recovery proof for later heartbeats.
- The previous Chrome source fails the new extension-update negative control by restoring a window through the browser API; the corrected source passes. Tests also cover source closure, restart ID remapping, denied/mismatched proof, unavailable persistent storage, a new intention during recovery and missing native identity through finish.
- Browser readiness is advertised only after the modern host supplies verified current process proof. A full response that omits the optional proof revokes cached readiness, and readiness changes send a heartbeat immediately. Native-required policy remains required even while proof is unavailable, preventing a legacy restoration fallback.
- Signed 0.2.29 and matching installed native bridge acceptance are still pending. No public release or update feed has changed.

### Installed 0.2.29 Chrome bridge acceptance

- Installed combined source `dfe0e73` (browser `ff8bab1`) with app UUID `C923ED94-A0A6-3931-ABCE-1A2FE294C725`, native-host UUID `218A3634-FAA8-384C-A58E-FA0374D10264`; strict signing and matching embedded browser source verified. Chrome's idle update loaded0.2.29 and advertised the negotiated native capability. Firefox0.2.29 submitted as unlisted AMO version6540210/file5084352; awaiting signature at this point.
- Native-created Chrome tabs: selected two exact tabs; Tab searches and Stopwatch on. Repeated allowed-tab clicks, a fresh Google search, typed external-navigation rejection and reuse of the search tab all passed without ending the intention.
- A real parking claim was captured before movement (browser window1733680409 / native CG13547 / PID36078 with launch proof). On completion, the old search tab returned. A40sample trace retained working CG9047; only2.187seconds were after Finish, so this is not a20second post-finish pass. The separate guard completed at5seconds. The empty-holder journal entry subsequently cleared.
- Found a real ambiguous-window limitation: an unselected window and the selected window both titled Example Domain with identical bounds could not be uniquely matched; the unselected whole window remained visible. The matcher correctly refused guessing, but the restriction was not fully enforced. Native follow-up is required.
- Renamed the disposable blocked window by navigating it to a distinctive QA search. Native successfully owned and minimized CG13527 (browser window1733680407) and captured parking CG13585 (browser window1733680412). No fixture seeding was used.
- **Failed strict quiet completion in Chrome:** the120sample trace spans50.123seconds after Finish. Correct on-screen-only front ordering changes from working CG9047 to restored CG13527 at+0.436seconds, then back to9047 at+1.500seconds. Native diagnostics show AX probe deferrals and `preserveWindow` at+1.107seconds. PID remains36078. Native AX unminimization still causes a transient foreground displacement in this case. Do not mark quiet completion fixed or release-ready.
- Evidence: `/tmp/intent-chrome-029-full-finish.jsonl` and `/tmp/intent-chrome-029-full-diagnostics.json`. The earlier observer queried all CG windows; filtering that list by isOnScreen did not give the same z-order as a dedicated on-screen query. Current observer records both lifetime inventory and a separate on-screen front-window list.

### Follow-up after the failed Chrome completion

- The empty native parking journal subsequently cleared; no fixture cleanup was used.
- Prepared a passive CG observer that samples at 20 Hz for the first ten seconds after the app's exact finish timestamp, then at 2 Hz. This is needed because the earlier 2 Hz observer cannot exclude short flashes. The new trace verifier rejects short post-finish tails, stale or unordered observations, large gaps, exact-window changes and reactive corrections.
- Read-only audit found a separate pre-0.2.29 Chrome upgrade gap: an older bare `parked.html` holder can lose its session-only ledger during an extension update, and 0.2.29 correctly declines unknown native ownership but leaves the legacy holder minimized. This is a migration gap, not a failure of new nonce-backed ownership; a safe migration remains unresolved. Do not treat browser API unminimize as a quiet recovery solution.
- Firefox0.2.29 remains awaiting Mozilla review/signature. Approval, actual-profile installation and live acceptance have not been inferred from successful lint/upload.
- The same audit found a pin-preservation coverage gap: Chromium154 cross-window insertion uses `ADD_NONE`, whereas the current fixture retains the original pinned flag. Intent records that flag but does not explicitly reapply it after movement. This needs a targeted regression and installed check; it has not been represented as a passed case.


### Immediate native restoration candidate and safety-stop acceptance

- Combined source `e383c88` installed with app UUID `EA77703F-F19A-3A2F-8724-0A9C9D0D9B28` and native-host UUID `2116F34D-AA5B-3F10-A858-47F2023A569A`; source-stable session gate `CxIDqGTU`, strict signing and browser checks passed.
- **Quiet completion still fails:** session `7C68758F-67B6-440C-BB1E-BA5CAC8E678E` selected the two native-created Chrome QA tabs with Tab searches and Stopwatch enabled. Native ownership correctly hid old CG13527 and captured parking CG13633. Finishing changes visible front-window order from CG9047 to CG13527 at +0.5194 seconds, then back at +1.1143 seconds.
- Passive bounds establish a Dock deminimization animation: the restored window grows from 92x158 near the Dock to 1710x1073. Immediate native raises reported the target already in front before the later animation; their internal success does not establish quiet visible behavior. No CUA observations ran during the post-finish interval.
- Evidence: `/tmp/intent-chrome-029-immediate-finish.jsonl` and `/tmp/intent-chrome-029-immediate-diagnostics.json`; 32.24 seconds after finish. A separate 0.228-second early sample gap also fails the strict coverage threshold. The observed wrong-window interval is a definitive failure regardless of that gap. No further speculative timing patch was accepted.
- Duplicate-title/identical-bounds Chrome windows now stop the intention safely instead of silently leaving a blocked whole window allowed. Rules became inactive and user tabs returned. A 40-second passive trace for session `7FDF305B-10E1-4121-A423-DA49E26964EC` stayed on Chrome after the launch transition, but its failure sheet appeared only when Intent was deliberately reopened later. Automatic notice visibility therefore failed and is being repaired separately. Trace: `/tmp/intent-chrome-029-duplicate-stop.jsonl`.
- All test intentions are inactive. Temporary parking entries subsequently retired without manual deletion. The disposable old Chrome window was returned to its distinctive QA search title after the ambiguity test.
- Firefox permanent signed 0.2.28 remains installed. Temporary 0.2.29 installation has not completed: its QA window CG12687 is off-screen and native automation sees changed toolbar URLs but stale rendered content. Supported Raise/window-selection attempts did not bring it forward; user handoff requested. Do not count this as Firefox 0.2.29 installed acceptance.


### Installed nonactivating safety warning: passed scoped live check

- Installed combined source `cd10a8c`, app UUID `17A2B80B-781F-3EE0-8936-C71C2D0474D2`, host UUID `9EC07046-FD34-3AB4-A9A3-4154256B2D1E`. Gate `n0uZcacy`, browser/native-host suites, release-readiness consistency, Mozilla lint and strict signing passed. The permanent Firefox package was unchanged.
- Repeated the real duplicate-title Chrome case with only the two QA tabs selected and all modifications off. After Run, no CUA app inspection occurred during the 45-second passive recording.
- The actual on-screen notice `Intent — Intention stopped` appeared at +14.419 seconds in the recording (layer26, 440x148, x635/y47), then disappeared at +26.799 seconds. Chrome PID36078 and the working CG9047 remained in front throughout the post-launch interval. The notice therefore appeared automatically and expired after roughly12seconds without activating Intent.
- `verify-finish-trace.cjs` passed with223 samples spanning30.7407seconds after the exact finish timestamp. There was no Space change, target replacement or late reactive correction. This is scoped safety-stop acceptance, not acceptance of normal whole-window restoration or proof of physical shortcut timing.
- Evidence: `/tmp/intent-chrome-029-visible-stop.jsonl`, `/tmp/intent-visible-stop-restoration-focus-diagnostics.json`, `/tmp/intent-visible-stop-window-visibility-diagnostics.json`. Detailed error sheet was inspected only after recording, dismissed, and the QA interrupted-session prompt dismissed. Rules remain inactive.
- Created one fresh Firefox QA window CG13770 through the normal New Window shortcut. Its about:debugging page renders correctly; old CG12687 remains off-screen. The supported Load Temporary Add-on action did not open a file picker through an accessibility click, screenshot-grounded click or focused Return while Firefox remained background. Requested the minimal user handoff: bring Firefox forward and click that button. No temporary update, signature bypass, Firefox restart, profile deletion or permanent add-on removal occurred.
- Chrome pin-preservation candidate is isolated under `/tmp/intent-pin-candidate/`; patch `/tmp/intent-pin-candidate.patch`. All12 targeted cases fail against original source and pass against the candidate, along with the existing visibility suite. It is not applied, installed, packaged or accepted in this checkpoint. Legacy pre-0.2.29 Chrome orphan migration is also unresolved.
- Normal fully blocked Chrome-window restoration still fails the strict quiet-finish requirement documented above. Matching Firefox0.2.29 installed-profile testing and physical-input acceptance remain outstanding. No release-ready or zero-bug claim is supported.
