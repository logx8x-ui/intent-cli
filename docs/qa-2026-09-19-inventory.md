# Intent QA inventory — 19 September 2026

This is the initial, source-backed inventory for the implementation/QA pass requested in `Pasted text.txt`. It is a test plan, not a passing test report. Inspection started at `9622d11` with existing uncommitted feature changes; those changes and unrelated `.superpowers/` / `weppy-project-sync/` content must be preserved. No application launch, installation, account operation, restriction session, build, or test execution was performed to produce this inventory.

## Scope and evidence labels

- Exclude AI Mode, Purpose Mode, and scheduler feature testing/redesign. Shared types may compile or receive regression checks without implying those features were verified.
- “Existing automated coverage” means executable assertions were found in source, **not** that they passed during this pass.
- “Not tested” means actual acceptance is outstanding. A source assertion or mocked browser is not live browser verification.
- A supported Browser Guard integration is currently Chrome or Firefox: separate extension directories and registrations exist for those two. The broader `BrowserApplication.bundleIdentifiers` classification also recognizes Safari, Brave, Edge and Arc; that does not establish equivalent Guard support.
- The latest attachment contains no new defect screenshot; reproduce the described PDF/blank-tab issue without claiming an unavailable screenshot was inspected.

## Architecture relevant to this pass

| Area | Source and implications |
|---|---|
| App and lifecycle | `IntentDesktopApp.swift`: menu bar/accessory app, Carbon shortcuts plus QuickMark gesture routing, startup registration, onboarding and updater |
| Workspace | `IntentAppModel.swift`, `IntentGraphView.swift`, `GraphEditors.swift`: intentions, graph, pending startup, session/checklist state and saving |
| Storage | `IntentionStore.swift`, `IntentAccountWorkspace.swift`: JSON intentions with last-good recovery, per-account/guest workspace paths, browser rules/heartbeat |
| Selection | `QuickSelectionView.swift`, `QuickSelection.swift`, `BrowserTabBridge.swift`: app/window/exact browser-tab identity, overview, marked selection, tab previews |
| Input | `GlobalHotKeyManager.swift`, `QuickMarkGesture.swift`, `QuickMarkKeyMonitor.swift`: remappable dashboard/finish bindings, single/double/held backtick routing |
| Enforcement | `FocusSessionSpec.swift`, `FocusLock.swift`, `NativeBrowserTabClickGuard.swift`, `FocusBlurController.swift`: native input/window restrictions and masks; separate `AllowedAppSwitcher` / `AllowedBrowserTabSwitcher` |
| Browser bridge | Chrome/Firefox `background.js`, Chrome `content-guard.js`, `IntentNativeHost/main.swift`: native messaging, runtime policy, snapshot and command IPC |
| Presentation | `OverlayWindowController.swift`, `WorkspaceWindow.swift`, `WorkspaceTabOutline.swift`: running controls, desktop previews, window/tab outlines |
| Permissions/setup | `AccessibilityAuthorizationGate.swift`, `IntentQuickGuideView.swift`, `IntentBrowserSetup.swift`, `IntentFreshInstallation.swift` |

## Coverage matrix

Use isolated fixtures for every destructive or persistent action. Expected results here are acceptance targets, not observations.

| ID | Scenario / preconditions | Expected result and essential variants | Initial evidence / status |
|---|---|---|---|
| R01 | Chrome/Firefox tab types | Web, PDF, new/blank, internal, loading, discarded, pinned/grouped and duplicate-URL rows all select by distinct identity; titles/favicons optional | Existing bridge/selection/extension tests; new cases required; **Not tested** |
| R02 | Tab identity transitions | Reload/navigation preserve selection; moves refresh window association; closed targets disappear explicitly without substitutes | Exact IDs covered in core/background tests; live close/move/reorder **Not tested** |
| R03 | Tab Shift-click | Both range directions, extend/shrink, independent additive selection, scrolled/filter lists, removed anchors; no crossing browser/window lists | New regression coverage required; **Not tested** |
| R04 | Native selected tab group | Browser highlighted group reaches double-backtick marking and allow/block execution in full; unsupported reading shown explicitly | Native metadata needs inspection; **Not tested** |
| R05 | App-tile Shift-click | Existing always-allowed preset toggle still works independently of tab range gesture | Core preset assertions exist; actual app-tile gesture **Not tested** |
| R06 | Actual timer expiry | Duration/end time each produce one dismissible, nonactivating central notice with intention name on one current display | Existing time calculations only; runtime notice **Not tested** |
| R07 | Timer transitions | Cancel/replace/early completion produce no stale notice; background, sleep/wake, clock/time-zone changes follow documented elapsed/absolute semantics | Deterministic clock and runtime integration tests required; **Not tested** |
| R08 | Running controls eligibility | Timer/end time/checklist show relevant controls; no eligible modifier opens no generic run overlay | UI lifecycle coverage required; **Not tested** |
| R09 | Running controls persistence | Hide/collapse survives ticks/checklist updates; drag/topmost/position/compact restore work; stop cleans up | Prior docs describe QA but not evidence for this build; **Not tested** |
| R10 | Single/double backtick priority | Selection surface first; confirmed double marks; single collapses expanded run controls; otherwise existing overview action; no premature single action | Existing deterministic gesture tests; new routing tests and live input required; **Not tested** |
| R11 | Gesture edge cases | Near threshold, repeats, held keys, rapid sequences, pending gestures during start/stop, text/IME/layouts, remapped bindings | Existing repeat/modified-key assertions; remaining coverage **Not tested** |
| P01 | Modification shortcuts | Backtick+1…4 opens visible numbered slot settings directly; exact current user order; repeated keydown does not retoggle | Current uncommitted core gesture assertions; UI **Not tested** |
| P02 | Modification reorder | Click/hold drag swaps positions, numbers follow order, restart preserves order; no unwanted activation during drag | UI and persistence **Not tested** |
| P03 | Modifier combinations | Duration XOR absolute end-time clearly indicated; checklist alone and timer alone prevent normal finish; mixed session ends when checklist completes OR timer expires | Core/model assertions partly present; integration **Not tested** |
| P04 | First-use combined explanation | Checklist+timer explanation appears once, readable/dismissible; unrelated settings not reset | Preferences/UI **Not tested** |
| P05 | Marked-workspace modification strip | Double-backtick mode shows bottom strip; settings don't lose already marked windows/tabs | Current UI implementation exists; **Not tested** |
| P06 | Blacklist gesture/cleanup | Backtick+B toggles; selected tabs/windows are blocked/blurred but never closed or deleted, including finish/cancel/safety stop | Core and new background assertions present; actual tab/window counts **Not tested** |
| P07 | Allowed app/tab switchers | Correct center on active display, simple glass material, keyboard reverse/cancel, correct target activated, no clipping | Native UI implementation; visual/integration **Not tested** |
| P08 | Overview relative scale | Small windows remain proportionally smaller; aspect ratios preserved, cards fit without overlaps, windowless apps remain identifiable | Core layout assertions for counts 1/2/4/9/16/30/50 and ratio; rendered **Not tested** |
| W01 | Intention CRUD/save | Create, name/edit/icon/resource changes, save, reopen, delete isolated fixture; blank/invalid input and cancellation preserve valid data | Core Codable/store/recovery coverage; graph UI **Not tested** |
| W02 | Graph canvas | Pan/zoom/fit/drag nodes and links, remove resource/restriction, undo, persisted layout after restart | Graph migration/core assertions; live canvas **Not tested** |
| W03 | Start/stop/save lifecycle | Existing saved and unsaved intentions, normal finish vs finish-and-save, replacement warning, repeated starts and cancellation | Model source + core policy coverage; integrated **Not tested** |
| W04 | Apps/windows selection | Multiple windows same app, no-window apps, select all/clear, whitelist/blacklist distinctions, stale/disappearing windows | Core exact-window specs; preview capture and actual bounds **Not tested** |
| W05 | Browsers/tab menu | Vertical displayed order, select-all/X, hover preview, missing preview labels, multiple windows, duplicates, empty/long/large lists | Bridge/core/background assertions; live mouse/hit testing **Not tested** |
| W06 | Marks and native overview | Tab-only green outline vs whole-browser outline, persistent marks, Backtick+Escape clear, native Mission Control mapping | Core metadata/AX policy tests; physical/native rendering **Not tested** |
| W07 | Always allowed and startup | Presets and manual selections obey context; startup URLs/apps launch once; reconnect does not relaunch | Core/background startup assertions; isolated launch/reconnect **Not tested** |
| W08 | Other current modifiers | Browser searches and cooldown valid/invalid inputs, combined modifiers, cooldown persistence/expiry | Existing core tests; UI **Not tested** |
| W09 | Legacy graph options | Currently exposed countdown/typed phrase/reason/time-budget/Don't-start-up nodes remain compatible in existing saved intentions | Source `GraphEditors.swift` / core legacy decoding; no redesign assumed; **Not tested** |
| W10 | Leisure and Zero Drift | Leisure performs no unwanted enforcement; bounded Zero Drift setup/cancel/expiry/emergency release; restart never reactivates restrictions | Core policy/persistence assertions; isolated live safety prerequisites required; **Not tested** |
| W11 | Menu bar and settings | Open/close/dashboard/finish states, shortcut change/conflict/reset, visual preference persistence | Source/readiness assertions; actual menu/input **Not tested** |
| W12 | Onboarding | Fresh guest name/resources/shortcuts/permission guidance/first-run finish-save, back/cancel/reopen draft | Draft and fresh-install tests exist; actual flow **Not tested** |
| W13 | Permission loss/recovery | Accessibility/Screen Recording denied/revoked/granted and capture failure communicate clearly; no trapped input | Authorization policy source/core tests; clean-profile permission cases **Not tested** |
| W14 | Bridge health/recovery | Guard off/old/missing/restart/reconnect, slow/empty/stale snapshots; no modal dead-end, no wrong tab substituted | QuickMarkRecovery, idle-work, host snapshot tests exist; live profiles **Not tested** |
| W15 | Data/restart | Atomic save, corrupt primary/backup recovery, absent data, update preserves workspace; reset only requested marker | Core stores and isolated fresh-install spec exist; app relaunch **Not tested** |
| W16 | Guest/account boundaries | Offline guest, validation and cached workspace resolution; cancel sign-in; no real credentials/accounts touched | IntentAccountSpec fixture coverage; hosted sign-in/email delivery **Blocked** without test account |
| W17 | Recording Mode | Local activity start/stop/clear, retention and permissions; no unexpected capture when disabled | Core activity record/retention assertions; use synthetic profile only; **Not tested** |
| W18 | App update/distribution | Version comparison, malformed/incomplete package rejection, update UI/disabled state; no install or publication | AppReleaseVersion + installer/download/readiness tests; network/install action **Not tested** |
| V01 | Restriction rendering | Allowed app stays clear; blocked app/tab gets intended blur; move/resize/app-switch/Space/fullscreen leaves no stale mask | Core click/foreground tests are not rendered proof; **Not tested** |
| V02 | Visual/accessibility combinations | Light/dark, Reduce Motion/Transparency/contrast, long text, small display, mixed scale/multiple displays, stacking and keyboard access | Screenshots/actual environment required; **Not tested** |
| S01 | Safety escape | Control+Option+Command+Escape releases all restrictions; menu safety stop works even when normal finish locked | Both global key and FocusLock event tap paths found; live confirmation required before enforcement; **Not tested** |
| S02 | Integration repetitions | Three consecutive clean/repeated-use smoke passes; record exact count of extra open/select/run/collapse/stop stress cycles and intermittent failures | No cycles executed by this inventory task; **Not tested** |

Calendar-linked events are part of the excluded scheduler surface. Account storage/preferences and local recording remain in scope, with real account and personal recording actions prohibited by this pass's working rules.

## Baseline and final-check commands

Run commands from the canonical checkout and retain exit code/log paths. These are recommendations, **not a command execution record**. Use an isolated Swift scratch path if another agent is compiling; avoid concurrent builds against the same `.build` directory.

```sh
git diff --check
swift build --product IntentCoreSpec
.build/debug/IntentCoreSpec
swift build --product IntentAccountSpec
.build/debug/IntentAccountSpec
npm run test:extensions
npm run test:native-host
npm run test:release-readiness
npm run extension:lint
swift build -c release --product IntentApp
swiftc -parse-as-library Sources/IntentApp/IntentFreshInstallation.swift scripts/test-fresh-install.swift -o /tmp/intent-fresh-install-spec
/tmp/intent-fresh-install-spec
python3 scripts/test-download-kits.py
node scripts/test-download-page.mjs
```

The existing aggregate `npm test` also runs hosted AI tests and `PurposeMatcherSpec`; do not use it as an unqualified in-scope QA command. `IntentCoreSpec` is monolithic and includes excluded-feature pure assertions as well as shared logic; document that boundary or add a scoped runner without weakening existing assertions. It does not run the excluded modes in the app. `test:native-host` assumes `.build/release/IntentNativeHost`; two host scripts honor `INTENT_NATIVE_HOST_PATH`, while snapshot-refresh currently hardcodes that path. A scratch-path build therefore requires an explicit runner adjustment, not an assumption that all tests use it.

## Isolation gaps and safe development runner

The current app is **not safely isolated by copying the bundle or choosing a guest workspace**:

1. Numerous stores resolve `FileManager.homeDirectoryForCurrentUser/.intent`; `switchProfile` redirects only intentions/schedules.
2. Startup calls `IntentFreshInstallation.prepare`, `IntentBrowserSetup.register`, data hardening and Launch-at-Login handling. Browser setup writes the real Chrome/Firefox native-host registrations and may `pkill` every IntentNativeHost owned by the user.
3. `IntentRuntime.start` starts account/update services and schedule bookkeeping. `model.load` clears browser runtime rules through emergency recovery. A second instance can therefore affect the daily-use app even without starting a test intention.
4. Preferences use `UserDefaults.standard`, account tokens have a fixed Keychain service, and browser rules/snapshots/commands share filenames.
5. Native host tests already support `INTENT_NATIVE_HOST_DIRECTORY` with temporary folders; the full app does not yet honor the equivalent override. A fake `HOME` alone is insufficient evidence of isolation.

Recommended runner: opt-in QA environment with one validated data root used by **every** runtime store; a distinct temporary app bundle ID/preferences suite; skip account/calendar/recording/updater/login registration and production native-host registration; use a fixture workspace and separate Chrome/Firefox profiles. Native bridge wrapper and app must agree on the QA IPC root. A browser profile alone does not isolate a globally registered native host. Confirm all paths remain inside the QA root before launch. Use one central path/configuration abstraction rather than scattered alternate literals. Keep production behavior unchanged when the flag is absent.

Before restriction tests, prove emergency escape in that isolated app and verify no production session is running. Use explicitly finite session limits and an independent watchdog targeted to the **exact test PID**, never `pkill Intent*`. Stop the session in `defer`/cleanup, confirm isolated rules are inactive and masks/event taps are gone, then remove only the test-owned artifacts. Existing `stopForSafety` skips resource closure; unhealthy event taps also fail open. A bounded watchdog is still required because a UI timer or a manual-finish shortcut is not an independent recovery mechanism.

Existing `scripts/install-dev.sh` writes the daily app, `.intent/bin` and LaunchAgent and is inappropriate for this attachment's isolation requirement. No publish/push/release/install action is authorized by this QA plan itself.

## Highest-risk boundaries to examine first

- Browser enumeration currently must preserve all real tab IDs independently of URL-scheme/content-script access; content restriction limitations must be explicit for privileged pages.
- NativeHost `HostTab` originally contains ID/window/index/title/URL/active only; native highlighted-group metadata needs end-to-end propagation, not a UI-only range fix.
- NativeHost response advertises a hardcoded bundled extension version (`0.2.9` at inventory time); compare with current manifests/capability use before describing negotiation as verified.
- Ordinary timer termination, checklist completion and emergency release share model/lock cleanup. Put expiry identity/deduplication at the runtime transition, not inside a SwiftUI countdown view.
- Source currently has separate global and local gesture consumers; a routing regression can produce double actions or leak held backtick keys. Test owner/context transitions, not only the pure recognizer.
- Blacklist cleanup, native click blocking and extension policy must all preserve original tabs/windows, including when a blocked browser has no permitted tab available.
- Centering/scaling mathematical tests do not establish visible bounds for hosted SwiftUI panels; inspect rendered screenshots on the actual display.

## QA ledger format and smoke passes

Record each result separately from this initial matrix:

`Scenario ID | Build/OS/browser/profile/display | Preconditions | Reproduction/expected | Actual | Automated/simulated/live | Pass/fail/blocked/not-tested | Log/screenshot/test reference`

Minimum three integrated passes after final code changes:

1. Clean QA start → permissions/guest workspace → overview → mixed tab range → timer → collapse → actual expiry notice → inactive rules/clean desktop.
2. Repeated use → double-mark native tab group → reorder modifications → checklist+timer → complete tasks early → no stale expiry → save/reopen fixture.
3. Fresh QA launch → blacklist same selected group → switch/move/resize → prove no tab/window deletion → safety release → repeated start/stop → inactive rules and no overlays.

Do not record one browser/profile/display as proof for all others. Record actual repetitions and retain any intermittent failure as open until reproduced, fixed and retested. Unsupported hardware, missing permission, missing test account or missing isolated browser bridge must remain explicitly blocked/not tested.

## Isolation tooling added after the inventory

`IntentEnvironment` now centralizes default data roots. The QA bundle is explicitly `dev.loganmondi.intent.qa`; it requires `INTENT_QA_ROOT` pointing to a private `intent-qa-*` directory directly under a system temporary root, with the expected marker. Invalid QA settings stop startup rather than using daily data. The daily bundle cannot opt into this workspace accidentally. Explicit temporary-home fixtures retain their existing behavior.

Core path-only changes touch shared scheduler/AI-history/Purpose-history storage to prevent production data access; their features remain excluded. QA account clients/Keychain, recording, calendar requests/mutations, updater, native-host registration and launch integrations are disabled. These guard changes are not evidence that live hosted accounts or calendar services were tested.

`scripts/build-qa.sh` builds/packages only. `--skip-build` packages existing release products. It creates a separately named/signed app under a new QA root with a Launch Services environment entry, and never opens or replaces the installed app. Browser components are prepared separately:

```sh
bash -n scripts/build-qa.sh
swiftc -parse-as-library Sources/IntentCore/IntentEnvironment.swift scripts/test-qa-isolation.swift -o /tmp/IntentQASpec
/tmp/IntentQASpec
/usr/bin/python3 scripts/test-qa-chrome.py
# After build-qa.sh prints its dedicated QA data path:
/usr/bin/python3 scripts/prepare-qa-chrome.py "$QA_ROOT" --host-binary .build/release/IntentNativeHost
# After quitting QA Chrome and the exact QA helper process:
/usr/bin/python3 scripts/prepare-qa-chrome.py "$QA_ROOT" --cleanup
```

Chrome prep copies the extension and native host into the QA root; only the copied extension uses `dev.loganmondi.intent.qa`. It exclusively creates a new QA-only native-host JSON, refuses an existing file, and records its exact path in a receipt. It never changes `intent_native_host.json`. The wrapper passes the QA IPC directory to the native host. Load the copied extension only in a clean QA Chrome profile; normal Chrome profiles must remain untouched. Cleanup checks receipt and wrapper ownership before removing that registration and copied fixture; it deliberately retains the profile/data for inspection until test-owned cleanup.

Tooling verification executed by the inventory/isolation worker: `bash -n scripts/build-qa.sh` and `git diff --check` passed; `/usr/bin/python3 scripts/test-qa-chrome.py` passed two tests covering isolated copies, exclusive registration, the production-file sentinel, cleanup, invalid roots and changed-registration refusal. All its registrations were inside disposable temporary fixtures; no live browser registration was created. Swift validation compilation and actual QA app/browser launch are delegated to the main QA pass and are not claimed here.

The beta installer fixture test additionally requires a prepared installer-kit directory argument: `python3 scripts/test-beta-installer.py /path/to/test-kit`. Do not run it without that fixture or substitute the daily installation.
