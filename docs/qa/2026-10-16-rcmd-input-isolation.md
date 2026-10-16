# rcmd input isolation and Mission Control qualification

## Report and preserved behaviour

Logan reproduced repeated attempts to activate excluded apps through rcmd followed by an intention ending with `inputTapTimeout`. The latest diagnostic reported one timeout and ten rejected activations; that is an input-protection safety stop, not evidence of a process crash. Both launch and development channels are in scope. Selected windows, browser tabs, Control-Tab, screenshots, Spaces, manual/emergency Finish, exact-current-window restoration and development-only Notes/T must remain intact.

Baseline: `0a922cae749c269773a6a004a6ab16f4dea6b75d`, checkout `/Users/loganmondi/Documents/Codex/2026-04-24-okok-im-planning-on-making-an/thavis`. Do not operate the obsolete worktree path.

## Changes under qualification

- Dedicated CoreGraphics input run loop. Routing consumes immutable value snapshots, does no AX/WindowServer/AppKit/file discovery, and never waits for the producer lock. Effects are bounded/coalesced and fenced against Finish and recovery.
- Off-callback discovery retains the observation's earliest timestamp. Stale snapshots do not authorize ordinary input. Excluded native siblings and unknown native click targets cannot borrow an allowed window's identity.
- rcmd 3.4.0 supported CLI mappings are captured before Intent's head-inserted session tap. Allowed app shortcuts use Intent's window-aware activation. Window/stage/unknown shortcuts are consumed. No rcmd configuration changes are made. Process, filter and configuration changes invalidate compatibility; transient CLI transport failure consumes shortcuts during a bounded retry.
- One timeout recovery of the same valid tap, with a one-second deadline and fresh permission/native/reported/browser coverage. User-disable, revoked permission, a second timeout or failed verification stops safely. Recovery is never counted as uninterrupted protection or as a passing stress run.
- Recovery distinguishes an unreadable browser inventory from an observed empty inventory, and rechecks currently pending browser discovery claims.
- Mission Control selection outlines remain before Run only. Full-thumbnail contours, browser-specific tab counts, partial-scan continuity and an ambiguity summary replace invisible scaled tab strips and identity guesses.
- Private content-free diagnostics retain the last 20 occurrences with callback duration, snapshot age, queue and recovery counters.

Apple documents that unresponsive event taps may be disabled and re-enabled with `CGEventTapEnable`; its documented tap locations distinguish HID, session and annotated-session ordering. Our limited retry adds explicit fresh verification rather than assuming re-enable alone establishes correct enforcement: https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:) and https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cghideventtap .

## Release promotion barrier

`scripts/qualify-release.mjs --prepare MANIFEST RECEIPT` produces pending checks, never a ready release. `--verify MANIFEST RECEIPT EVIDENCE_DIR` checks the exact source/app/package identities and hashed JSON observations. `--qualify ... OUTPUT_MANIFEST` additionally requires signed/notarized distribution and matching approved Chrome delivery. All installed, physical, clean-account, hosted and OS cases must pass; omitted, pending, stale or mismatched evidence fails closed. The site's matching server validator independently rejects an incomplete qualification. `PINNED_LAUNCH_RELEASE` remains null.

A per-check observation is JSON containing `check_id`, `kind`, `status`, `observed_at`, `candidate`, `environment` and, where required, `metrics`. Screenshots may supplement that observation. Results must be actually observed; this is an accidental-promotion barrier, not an attestation against fabricated owner-authored evidence.

## Current environment and results

- macOS 26.2 (25C56), Apple silicon.
- Firefox 158.0, Chrome 155.0.8059.82.
- rcmd 3.4.0: live read-only probe confirmed PID 72696, tap 628175011, session location, filtering enabled. Process/tap identity is session-specific and must be refreshed at installation/acceptance.
- Health/recovery diagnostics and bounded history tests passed in isolation.
- Site: 26 tests plus actual local Worker/R2 upload/read/range/auth tests passed; production framework build passed.
- Site source is retained at local commit `2cd5e81`; hosting push returned `protocol error: bad line length 134`. No new deployment was claimed.
- Chrome Web Store publicly reports 0.2.14 on October 16; required Browser Guard is 0.2.46. Store approval remains a distribution blocker.
- Full frozen change-impact gate passed all eight suites at 2026-10-16T10:07:06Z: session UI, Swift, both browser extensions, native host, release readiness, AI, extension lint and gate self-tests. Source fingerprint: `eeacc3db6b609aa4217a29900b91436eaa2c8145a98906a0114ac827078f03bb`. Evidence: `/Users/loganmondi/.codex/artifacts/intent-input-isolation-20261016/automated-gate`; the gate explicitly reports `releaseReady: false`.
- Browser Guard 0.2.46 Mozilla-signed XPI from candidate `202610160002` was reverified against unchanged extension source; SHA-256 `5fe3ad9af1d122f6c74b5458f17fd811b531a48d7de17918a9d9beed5e6c7606`.
- The Mac was initially locked; after unlock, installed verification exposed the separate startup crash below. Physical acceptance remains pending, not inferred from automated passes.
- Final review found startup `onReady` can update presentation during a bounded repair, but it does not loosen restrictions; diagnostics remain recovering, queued activation is invalidated, and verification must complete or stop within one second. No additional source change was needed.

## Installed failure found after unlock

At 20:18 KST, the installed development executable `D624D19E-FD90-3441-B02F-92627C4D1CDA` crashed when Run was clicked for a selected ChatGPT window. The macOS report `IntentApp-2026-10-16-201924.ips` identifies an `EXC_BREAKPOINT` / main-queue assertion in `TSMCurrentAsciiCapableKeyboardLayoutInputSourceRefCreate`, reached through `RcmdCompatibilityMonitor.keyboardKeyCodes()` from the FocusLock worker. This is a real process crash, distinct from the original safety-stop report. The prior automated pass did not cover that platform call.

Candidate `0.9.7 / 202610160003` is rejected despite successful notarization after unlock. Its output directory contains `REJECTED-NOT-FOR-DISTRIBUTION.txt`; distribution remains disabled.

The repair captures Carbon keyboard layout on main into an immutable cache. Worker discovery copies that cache; the event callback reads only an atomic revision. Input-source changes revoke old mapping generations before refresh. `scripts/test-rcmd-platform.sh` exercises real worker-first preparation, real background `readCurrent()` with rcmd present, 1,000 cached reads and generation invalidation while pumping the main run loop. This platform regression is now included in the session gate. Both narrow runs confirmed `rcmd present=true, compatible=true`. The final full eight-suite gate passed at 2026-10-16T11:35:17Z with source fingerprint `44e376146ca17d53bdb064f2feec6dcd666bb6db210195a81b11d438420af147`; evidence is `/Users/loganmondi/.codex/artifacts/intent-input-isolation-20261016/automated-gate-carbon-fixed`.

An adjacent SDK/API audit found no other confirmed main-thread-only call in the new input/worker path. This does not substitute for installed stress acceptance.

The corrected installed Test Intent executable `B8CB238F-ECC2-39E0-B034-717BA4D4AACC` successfully started a ChatGPT-only session. Clicking the selected window blurred the optional naming field. Native visibility reported zero unresolved windows, and the process remained running with zero tap timeouts/recoveries. The callback count was also zero, so these observations do not establish physical-input or Mission Control stress acceptance. A user physical test is pending.

## Remaining acceptance

For each installed channel, test SBT and DBT, allowed/excluded rcmd destinations, three 60-second shortcut bursts, 20 Mission Control return cycles and a 30-minute soak. Record real callback traffic, zero ordinary timeouts/recoveries/stops/escapes, callback maximum below 5ms, and finish restoration. Check pre-Run actual tab contours and Mission Control full-window borders, screenshots, Control-Tab, Caps Lock + backtick and emergency recovery separately.

All Firefox/Chrome/Both hosted packages must pass the clean-account download → Gatekeeper → correct browser-choice onboarding → first intention → finish journey. macOS 13 and current macOS, browser profiles, reconnect/offline recovery, update/reinstall/rollback/uninstall and invite denial remain required. No `releaseReady: true` while any is pending.
