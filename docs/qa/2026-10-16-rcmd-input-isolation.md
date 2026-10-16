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
- Desktop control reports the Mac locked. Installed-app verification and physical acceptance are pending, not inferred from the automated passes. An unlock request is outstanding.
- Final review found startup `onReady` can update presentation during a bounded repair, but it does not loosen restrictions; diagnostics remain recovering, queued activation is invalidated, and verification must complete or stop within one second. No additional source change was needed.

## Required physical and release acceptance

For each installed channel, test SBT and DBT, allowed/excluded rcmd destinations, three 60-second shortcut bursts, 20 Mission Control return cycles and a 30-minute soak. Record real callback traffic, zero ordinary timeouts/recoveries/stops/escapes, callback maximum below 5ms, and finish restoration. Check pre-Run actual tab contours and Mission Control full-window borders, screenshots, Control-Tab, Caps Lock + backtick and emergency recovery separately.

All Firefox/Chrome/Both hosted packages must pass the clean-account download → Gatekeeper → correct browser-choice onboarding → first intention → finish journey. macOS 13 and current macOS, browser profiles, reconnect/offline recovery, update/reinstall/rollback/uninstall and invite denial remain required. No `releaseReady: true` while any is pending.
