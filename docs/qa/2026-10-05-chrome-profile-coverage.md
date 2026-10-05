# Chrome profile window coverage — October 5, 2026

## Confirmed baseline

Source `64748a2`, installed Browser Guard 0.2.32. Chrome PID 36078 has one reporting profile (Default / Logavix) and another profile without Intent Browser Guard. The selected QA window is native CG 9047. Existing native windows CG 10941 and CG 6782 belong outside the reporting inventory.

The preceding live Add as you go run `ACEA911B-AB48-420C-896A-29E9B9FBC796` allowed only two tabs in the reporting profile. The two other existing Chrome windows remained available and acquired no native hiding entry. Thus selected/new-tab success inside the reporting profile did not establish complete initial window hiding.

The read-only probe `/tmp/intent-chrome-coverage-probe.py` and `/tmp/intent-chrome-coverage-before.json` bind all three windows uniquely through process, normalized title and geometry. Each is exposed as `AXWindow` / `AXStandardWindow`, initially unminimized. No page fields or credentials were used.

Chrome also has six off-screen auxiliary CG surfaces with ordinary layer, alpha, sharing and storage values. Their titles and sizes cannot establish whether they are browser windows. They must not become hiding targets merely because their CG metadata resembles an ordinary window.

## Acceptance boundary

- Selected-tab whitelist startup obtains fresh, request-correlated, process-attested profile inventories before changing restrictions.
- Every selected browser window must map uniquely to its native window. A missing or ambiguous proof prevents startup without hiding anything.
- Existing unreported windows positively exposed as AX standard windows enter a frozen native hiding cohort. Saving ownership precedes minimization; successful AX readback is required.
- Windows the user already minimized remain unowned and are not restored by Intent.
- Add as you go permits later windows after the initial cohort is confirmed. Restrictive sessions continue protecting newly observed unreported standard windows.
- An exact later profile claim transfers the existing ownership entry; it must not create a second entry or restore the window during transfer.
- Whole-browser and always-allowed Chrome selections remain exempt; blacklist behavior is unchanged.
- Finish and cancelled/replaced starts invalidate pending work. Existing three-second enforcement failures still stop safely.

This boundary covers AX-observable unreported windows. An unreported ordinary window absent from AX on another desktop cannot reliably be distinguished from Chrome auxiliary CG surfaces, so universal coverage of those windows is not claimed. Authoritative profile-reported windows retain the existing native enforcement contract, including unresolved AX failures.

## Verification record

Integrated the independently reviewed 18-file candidate from source `64748a2`. Patch SHA-256: `6744a8968db69667e00b8bfecce8cb0bf5be1b8ea5d6ab2736be996bf9185482`. All integrated files were compared byte-for-byte with the frozen candidate; the sole initial difference was the native version bump. Both browser manifests and bundled host version are 0.2.33.

The candidate uses the existing snapshot command with bounded request receipts and host-attested process/readiness evidence. Native ownership uses the existing durable journal; a later profile claim transfers that entry. Full AX inventories run on serial workers with bounded deadlines, and main-thread completion rechecks the occurrence before touching caches or windows. Delayed native and transferred ownership cannot restore under a newer active occurrence.

Isolated evidence in `/Users/loganmondi/.codex/artifacts/intent-chrome-coverage-candidate-20261005`:

- Exact baseline fails the new Chrome discovery receipt assertion and the host process-attestation assertion; candidate passes both.
- Full extension gate, CoreSpec, host discovery/profile isolation and performance pass. Host performance peak RSS 10.7 MiB.
- Release app compiled with two jobs. Signed QA bundle passed 76 isolated app-model assertions, including pending-start cancellation, Finish, reopen and replacement.
- Shared native effect tests cover save-before-effect, failed persistence/readback, pre-minimized windows, in-place ownership transfer and the different-occurrence restore fence.
- Independent review found no remaining blocker within the documented coverage boundary.

Actual-checkout build/install identity and live outcomes follow below when verified. Isolated results do not establish installed-profile or physical-input acceptance.

## Initial installed 0.2.33 result and discovered regression

Actual checkout passed the source-stable session gate (`/tmp/intent-033-session-ui.log`), complete native-host gate (`/tmp/intent-033-native-host.log`, peak RSS 10.4 MiB), readiness and extension lint (zero errors/notices/warnings). Both packages built. Development install completed with app UUID `E2810E16-C438-37BE-9C75-76FE6F5EC5E8`, embedded host UUID `0FBEF648-2E1F-35D2-9B9D-22A70286C73F`, matching release artifacts and strict deep code-signature verification. Both fresh browser heartbeats reported 0.2.33. Firefox remains a temporary development extension above signed 0.2.28, not permanent/restart acceptance.

Session `53C5C1B0-AD60-402B-A1E0-C5D2259B2582` selected two disposable Chrome tabs, with all modifications off. Native CG 10941 and 6782 were minimized and each had exactly one `nativeCoverage` journal entry; selected CG 9047 stayed unminimized. Ordinary clicks switched the two allowed tabs successfully.

Opening a fresh Chrome window with Command-N exposed a regression: new native CG 15672 and the previously hidden CG 6782 both had the title New Tab and identical geometry. Both current AX standard elements therefore matched the same two CG IDs, making the complete coverage inventory unresolved. The safety deadline ended the intention with the specific other-Chrome-window visibility failure. This is **not** a passing new-window or restrictive-session acceptance result.

Cleanup returned the original pinned tab, restored the two owned unreported windows exactly once each, and left inactive rules with an empty journal. The newly created QA tab 1733680442/window 1733680441 was then closed through Chrome's normal tab control. All original tabs/windows were preserved. Evidence: `/tmp/intent-033-restrictive-session.jsonl`, `/tmp/intent-033-restrictive-active-ax.json`, `/tmp/intent-033-restrictive-new-window-ax.json`.

The follow-up fix must use continuously revalidated positive AX identity, not title/focus guesses. A full profile snapshot can exclude an existing window only when that native window was positively observed before the request and its identity remains live afterward. Both the coverage planner and normal-window enforcement must consume the same exact mapping. Cold indistinguishable windows and incomplete enumeration remain unresolved.

## Separate Add as you go acceptance on 0.2.33

Session `29A7AB4B-741C-46FA-912C-0A2715B31EBA` used the same two selected Chrome tabs with Add as you go enabled before starting. CG 10941 and 6782 were verified minimized and owned; selected CG 9047 stayed visible. A fresh Command-N window CG 15716 remained usable and loaded the new QA website. The original allowed tabs remained accessible through Chrome's native Window menu and ordinary tab clicks.

The sampled active interval exceeded 167 seconds. Normal menu Finish left inactive rules and an empty journal; each of CG 10941 and 6782 recorded exactly one restoration effect. The new test window was closed afterward, leaving all three original Chrome windows unminimized and intact. Evidence: `/tmp/intent-033-additions-session.jsonl`, `/tmp/intent-033-additions-active-ax.json`, `/tmp/intent-033-additions-new-window-ax.json`, `/tmp/intent-033-additions-finished-ax.json`, `/tmp/intent-033-cleaned-ax.json`.

This verifies the flexible-session path separately; it does not erase the restrictive duplicate-window failure above or establish physical-key/strict quiet-finish acceptance.

## Duplicate-window follow-up, development 0.2.34

Integrated the independently reviewed 13-file incremental patch with SHA-256 `0c796201677a164d4ec11f6fcdb489a680a9ba8510fb09f921485d7c33009b8b`. Every original and final file hash was checked against the frozen candidate, with the independently managed host version normalized only for comparison. Both browser manifests and the bundled host are now 0.2.34.

Previously proven native window identities survive title changes only while the same live AX object, process lifetime and CG identity remain verified. Full browser discovery is bracketed by native observations; new profile-window bindings require continuity on both sides. The normal hiding path consumes this same mapping. Closed or replaced windows cannot inherit a previous window's proof.

Incomplete or transiently empty Chrome enumerations receive bounded retries. A per-profile sidecar preserves the exact correlated reply against ordinary snapshot overwrites. Both consumers reject newer positive metadata contradictions after the native scan and request a fresh reply within the original deadline. They do not treat ordinary empty snapshots as proof of a window's absence.

The unchanged original 0.2.33 implementations fail the new completeness regressions; the full extension suite passes against the final candidate. Native compilation, isolated lifecycle checks and installed acceptance are recorded below after execution. New Chrome bindings without the required AX witness and cold indistinguishable windows remain unresolved. No universal cross-desktop or quiet-finish claim follows from this change.

The first actual-checkout gate passed CoreSpec but the app compiler rejected two local helper functions lacking explicit main-actor isolation. Added `@MainActor` to `isCurrent` and `fail` in the startup task, independently reviewed. The worker AX closures do not call these helpers; enumeration remains off-main. The failed build was not installed. The full source-stable gate is rerun after this correction.

## Final 0.2.34 automated checks and installed identity

The rerun of `npm run test:session-ui` passed after the two actor annotations. This includes CoreSpec coverage fixtures, keyboard/native-gesture checks, layouts for 1–50 windows, the release app build, isolated app-model and notch checks, whitespace validation and the unchanged-source fingerprint. Independent review confirmed the integrated source matches the frozen candidate apart from those annotations and the version bumps.

The release native host, protocol, window-visibility, refresh, correlated complete-snapshot and profile-isolation checks passed. The first native-host performance check exceeded its existing coalescing budget during UI activity (five writes where at most four were allowed). It was not relaxed: the isolated rerun passed, with peak RSS 10.5 MiB. The final candidate's complete extension suite, readiness checks and Firefox lint passed; lint reported zero errors, notices and warnings. Both 0.2.34 extension archives were built.

Development installation completed with app UUID `8A39ED2A-6735-38AA-9282-53AC9D753723` and embedded host UUID `D766C4FB-369D-3784-95F0-DFAEA0D36DB8`, matching the release artifacts. Strict deep code-signature verification passed. Both browser connections reported 0.2.34 during acceptance. No public release, update feed, store submission or waitlist deployment was performed.

The Mac restarted between the Chrome and Firefox checks. Earlier `/tmp/intent-034-*.log` files are no longer available after that restart; their results were observed before it, and are recorded here rather than represented as surviving artifacts. The frozen candidate and its review evidence remain in the private artifact directory above. The restart cause was not established by this work.

## Installed Chrome restrictive-session acceptance

Session `F44C700C-61E2-4793-BA27-0250FD8D807B` selected the two QA tabs in native window CG 9047. Existing unreported windows CG 10941 and 6782 were minimized with native coverage ownership, while the selected window remained visible. Ordinary clicks switched the selected tabs.

Command-N created native CG 15812, browser window 1733680453, tab 1733680454. Its New Tab title and geometry were identical to the existing hidden CG 6782, reproducing the ambiguity that stopped 0.2.33. In 0.2.34 both windows remained minimized, the new reported window acquired normal profile ownership, and the intention remained active. The sampled active interval was 140.1 seconds; selected-tab clicks continued to work before and after the new window appeared.

Normal menu Finish left inactive rules and an empty hiding journal. Original windows and the new QA window were restored. Only the new QA tab was then closed through Chrome's normal controls, and the original tabs, including the pinned tab, were preserved. This passes the reproduced duplicate-window regression; it does not certify physically pressed shortcuts or an unchanged foreground window during restoration.

## Installed Chrome Add as you go acceptance

Session `5E6BDB0C-8498-4479-A063-6F0E123D4107` used the same two selected tabs with Add as you go enabled before Run. Initial CG 10941 and 6782 were minimized, and selected CG 9047 remained visible. A new Command-N window CG 15853, tab 1733680460, remained visible and loaded a fresh QA website. The selected tabs stayed usable through native window selection and ordinary tab clicks.

The sampled active interval was 164.8 seconds. Normal menu Finish left inactive rules and an empty journal, with one restoration effect each for the two initially hidden windows. Cleanup of the fresh QA tab was interrupted; after the Mac restart it was no longer present in the connected Chrome profile, so no unrelated tab was closed to compensate. That profile then contained a single New Tab. Existing recovery prompts and other-profile windows were left untouched.

## Firefox regression smoke after restart

The temporary extension had not survived the restart. Browser Guard 0.2.34 was reloaded through Firefox's normal temporary-extension UI into daily profile `ykomjweq.default-release`, and its fresh heartbeat was verified. The underlying signed version remains 0.2.28; permanent installation and acceptance after a Firefox restart remain outstanding.

Session `50FCDE12-33FD-4EA6-9780-F41CFDDBE8FE` selected two existing QA tabs with Tab searches and Stopwatch enabled, and Add as you go off. Ordinary tab clicks switched between both selected pages. A native Command-T search tab loaded Google results, and attempting to navigate it directly to an external QA website left it on those search results. Switching between a selected tab and the fresh search tab also worked. The sampled active interval was 227.5 seconds.

Normal menu Finish returned inactive rules and an empty journal. The one fresh search tab was closed afterward; pre-existing Firefox pages and windows were preserved. A ScreenCaptureKit `-3811` observation failure immediately after Finish recovered on the next read without restarting Intent or Firefox. This tool error is not evidence of an app crash.

Durable evidence is under `/Users/loganmondi/.codex/artifacts/intent-034-verification-20261005`: `firefox-session.jsonl`, `firefox-finished.json`, and `firefox-finish-visibility.json`. The read-only watcher samples rules, ownership and visibility; it does not synthesize input.

## Final cleanup and remaining limits

- Final read-only verification confirmed inactive rules and zero hidden-workspace entries. Intent's overview was dismissed after cleanup. Installed app and host UUIDs still match the identities above.
- Firefox's current heartbeat was fresh at handoff. Chrome's last 0.2.34 heartbeat was about 80 minutes old by the final checkpoint, so its earlier passing live tests are not represented as a currently connected Chrome profile.
- Strict quiet-finish acceptance remains unresolved: earlier native traces showed automatic deminimization briefly raising another Chrome window. This patch does not change the user's restoration policy, and menu Finish is not proof of physical-hotkey or foreground-stability acceptance.
- Coverage remains limited to the positively observed windows described above; cold indistinguishable identities and unreported windows absent from AX on another desktop are not claimed covered.
- The coordinated “Intent - Fix a Bug” chat prepared separate shortcut, modification-toggle, timer-preference, tab-menu and completion-animation fixes in isolation. They are not included in this checkpoint. Actual-checkout and UI ownership will transfer only after this scoped commit is pushed.
