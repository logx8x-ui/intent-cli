# Intent onboarding implementation and verification

Status: implemented in source; final post-fix automated verification passed and the isolated app is packaged. Live acceptance is still blocked, so this is not a claim that every interaction is verified or that a new user completes setup in three minutes.

This follows the modifier/reliability work in local commit `4038263`, documented in [the previous QA report](qa-2026-09-19-report.md). That report's limited timer observations do not validate this new onboarding. AI Mode, Purpose Mode and scheduler feature testing remain excluded. No release, push, daily-app replacement, real-account change or UniHead change is part of this pass.

## Checklist and final sequence

- [x] Read the brief, project instructions, existing runtime, input router, guide, storage and permission paths.
- [x] Research primary guidance; record findings, transfer limits, final copy and a novice test script in [the rationale](onboarding-research-2026-09-19.md).
- [x] Replace the separate tutorial picker with a compact coach using real overview, marking, run and canvas actions.
- [x] Preserve purpose, timing, progress, skips, existing selections and saved identities.
- [x] Review the integrated diff and add targeted state/save regressions.
- [x] Run all-source post-fix automated regressions and package the isolated app.
- [ ] Complete actual rendered onboarding, physical-shortcut and accessibility acceptance.
- [ ] Complete three integrated live smoke passes and an uncoached novice study.

1. **Let’s begin** starts the small 3:00 clock. The first question is **“What do you want to do on your Mac right now?”** Free text stays intact, except outer whitespace in the saved name; it remains editable.
2. **Choose your setup:** contextual permission help, then the actual single-backtick overview. Choose resources for the purpose, understand Allow versus Block, locate bottom modifications, and press Return to start a real run. Opening by button does not claim shortcut mastery.
3. **Select where you are:** explicitly finish the first run to try this skill, or close the guide and keep working. Double-backtick marks the actual app window or native selected browser-tab group; repeat removes that group. Hold backtick with Return to run, B to switch mode, Tab for browser-window selection, or Esc to clear marks.
4. **Keep a useful setup:** optional normal finish-and-save writes the purpose as the name. Locate the actual saved card; reuse runs through the normal runtime. Existing saves can be kept or explicitly updated without duplicating the card. Internal/non-web tab setups explain when current tabs must be selected again.
5. **Repeat cue:** “When I sit down to use my Mac, I press [actual shortcut] and choose an intention.” Skipped skills stay distinct from demonstrated actions; Settings → Show quick guide resumes or replays.

## Implementation boundaries

| Files | Change |
|---|---|
| `Sources/IntentCore/IntentOnboarding.swift` | Codable state, original purpose, evidence-gated skills, negative countdown, exit/resume/replay, setup/core/full timing, private-content-free measurements, deleted-save recovery and late-save identity bookkeeping |
| `Sources/IntentCore/OnboardingSavePlan.swift` | Consumed keep/insert/explicit-replace policy; edited name, stable saved identity/location/folder, connected-node relocation |
| `Sources/IntentApp/IntentOnboardingCoordinator.swift` | Local persistence, continuous clock in-process, actual product event connection, separate draft versus measurements, purpose-edit return path, selection ownership |
| `Sources/IntentApp/IntentQuickGuideView.swift` | Bounded draggable coach, free-text IME-aware field, contextual permission/browser recovery, real-action guidance, accessible on-demand timer announcement, reduced-transparency fallback |
| `Sources/IntentApp/QuickSelectionView.swift` | Existing real picker/mark/run events, contextual inline hint, temporary selection snapshot and deferred restoration; no new shortcut router |
| `Sources/IntentApp/IntentDesktopApp.swift`, `GlobalHotKeyManager.swift` | Existing shortcut evidence, shared finish-and-save label, session-end selection restoration/acquisition, deferred startup behavior |
| `Sources/IntentApp/IntentAppModel.swift`, `Sources/IntentLock/FocusLock.swift` | Run evidence only after runtime startup succeeds; successful persistence before save evidence; failure rollback; explicit update authorization scoped to the candidate |
| `Sources/IntentApp/IntentGraphView.swift` | Purpose before account setup, optional guest path, replay entry, focus the real saved canvas card, click-through presenter anchor |
| `Sources/IntentCoreSpec/OnboardingSpecs.swift`, `OnboardingSavePlanSpecs.swift`, `main.swift` | Deterministic regression coverage integrated with the normal CoreSpec executable |

The coach uses the registered interactive-panel class, so it is not treated as restricted content. It hides while the real picker is visible. Its invisible hosting anchor does not intercept canvas clicks. Explicit canvas navigation leaves edit mode so the saved card can run. Existing timer/checklist locks and Safety Stop remain in charge: a guide step cannot override them. Closing the guide cleans up only its temporary selection; an explicitly started real session keeps running.

## Issues caught during implementation review

- Editing a purpose after the run could save the old title. The save policy now applies the latest answer only for a new save or an explicitly requested update.
- Replaying could ambiguously replace an existing setup. The guide now shows the actual saved name and offers keep versus explicit update, preserving stable card identity and position.
- Closing the guide during asynchronous finish-and-save could lose its saved ID and duplicate the card on replay. Successful storage now retains that identity after exit/completion without manufacturing mastery or active time.
- Resuming during an active tutorial session could restore pre-tutorial marks too early. Resuming cancels deferred restoration. Beginning during a preexisting real session acquires tutorial selection ownership only after that session ends.
- A full-sized, empty guide anchor could obstruct the actual canvas. Both SwiftUI hit testing and the AppKit anchor now pass through to the canvas.
- Long purposes are truncated only for constrained display labels; the original full text remains in the draft and saved name. Purpose-edit return navigation survives guide exit and process relaunch.

## QA ledger

| Scenario / precondition | Expected and actual result | Verification / status |
|---|---|---|
| Fresh state and first Begin | Unstarted welcome; Begin asks purpose before prerequisites | Core state assertions passed; actual first-launch render blocked |
| Empty, long, Unicode purpose; edit and persistence | Reject blank only; retain exact text and progress; save latest name | Core/save-plan assertions passed; physical IME composition unverified |
| Clock at 179/180/181/241 seconds | 0:01 / 0:00 / -0:01 / -1:01; no auto-advance | Controlled-time assertions passed |
| Back, repeated begin, exit, resume, crash/relaunch and rollback | Same attempt includes time away; active measurements exclude absence; no increasing timer after rollback | Controlled-time and Codable assertions passed |
| Open/run through button versus actual shortcut | Navigation/button alone never demonstrates the shortcut | Core evidence assertions passed; actual hooks reviewed; physical delivery blocked |
| Real overview, native group mark, Allow/Block, bottom modifications | Actual identities/rules and existing router used | Existing core/browser/host regressions passed; integrated desktop acceptance blocked |
| Save retry/replay, edited name, explicit update | One stable saved card; no implicit overwrite; latest purpose on authorized write | Consumed save-plan and identity assertions passed; actual canvas click/reuse unverified |
| Guide exits before save completes | Retain successful saved identity without adding learned skill or elapsed interaction time | New late-save regression passed; asynchronous UI reproduction unverified |
| Missing/deleted saved entry | Remove stale saved evidence only; retain unrelated progress; allow a genuine new save | Core assertions passed |
| Missing permissions/bridge | Explain actual prerequisite, settings/connect action, real status recheck, skip honestly | Source review; missing grant previously observed in the prior QA build, new guide UI blocked |
| Existing user, active session and staged selections | No forced replay, no silent stop or destruction of prior marks | Coordinator/controller review; integrated exit/resume/restore still needs live acceptance |
| Keyboard, focus, VoiceOver, small/multiple displays, contrast and motion | Bounded scrollable panel, native controls, marked-text protection, no per-tick announcements, solid material fallback | Implemented and compiled; physical/visual matrix not tested |
| Timer/checklist locks and emergency release | Normal end cannot bypass locks; tutorial exit never stops a real run | Existing deterministic checks passed; no new enforcement session started without verified QA escape |
| Analytics privacy | Measurement type has no purpose text, URL, title, saved ID or raw key stream | Serialization assertions passed; user draft persists locally in a separate key |

## Verification and measured timings

The reproducible automated command is:

```sh
env PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin scripts/test-qa-regressions.sh
```

It builds Core/Account specifications and release App/CLI/native host; repeats core/account/browser/native-host/freshness/release-readiness checks three times; then runs host performance, extension lint/packages, download catalog/kits, isolated-browser fixture preparation/cleanup, QA isolation and fresh-install preservation. These three repetitions are **automated regressions, not live end-to-end smoke passes**.

Initial onboarding baseline: debug CoreSpec build passed in 13.40 seconds; CoreSpec passed. Initial release App build passed in 49.30 seconds. The first all-source onboarding suite passed, with release App compilation in 47.39 seconds; aggregate log `/tmp/intent-onboarding-final-checks.log`, detailed logs `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-checks-fUCqVTl2`. That run predates the late-save and active-session scope fixes.

**Final post-fix suite: exit code 0; all checks passed**, including all three automated repetitions. Aggregate log: `/tmp/intent-onboarding-final-checks-2.log`; detailed logs: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-checks-Om6LCZPp`. Optimized App compilation took 46.06 seconds. Native-host performance test passed with peak RSS 8.0 MiB. Firefox extension lint reported zero errors, notices or warnings. The installed Command Line Tools emit a nonfatal `xcrun` PlatformPath/XCTest lookup diagnostic; compilation and all executables/checks completed successfully. `git diff --check` passed after the integrated review.

Each full automated batch includes 100 controlled gesture sequences per pass (300 total), and 1,000 inactive events per browser per pass (3,000 per browser). Browser idle/reconnection simulation observed eight reconnect attempts over 120 simulated seconds and 20 heartbeats/minute. This measures fixtures, not actual people's behavior.

Onboarding timing instrumentation records full Begin-to-observation time, active core time, required setup time, time to first runtime success, step visits/abandonments, demonstrated/skipped skills, save and reuse evidence. Exit/resume includes time away in full elapsed time, not active core/setup time. In-process time uses ContinuousClock; after process death the civil timestamp plus persisted high-water mark prevents a reset but cannot reconstruct an unknown system-clock change exactly. No timer pauses for permission setup.

**Actual human first-run time, human core tutorial time, and novice study results: not measured.** No three-minute completion claim is validated. The [uncoached test script](onboarding-research-2026-09-19.md#short-uncoached-first-user-test) is ready; it is not a completed study.

## Live evidence and safe handoff

The new onboarding build was packaged separately with `scripts/build-qa.sh --skip-build` and passed deep/strict ad-hoc signature verification. Opening it through CUA returned: **“The Mac is locked and automatic unlock could not unlock it. Ask the user to unlock the Mac manually before continuing.”** No screenshot or recording of the new onboarding was obtained; no visual acceptance is claimed. Previous screenshots of timer controls/expiry belong only to the previous QA report.

Final isolated artifact: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-L9Xz3YTp/Intent QA.app`; packaging log `/tmp/intent-onboarding-qa-package.log`. A final attempt to open this post-fix bundle returned the same lock-screen block. The earlier pre-race-fix package at `intent-qa-YHOhw3D8` is superseded and is not the acceptance build. These are local temporary artifacts, not published downloads.

The QA bundle has a separate identifier, private temporary data directory, disabled updater/account/recording startup, and no production browser registration. The daily app was not replaced or installed. Daily `intentions.json`, `schedules.json` and `cooldowns.json` matched the saved pre-QA SHA-256 values; daily browser rules were inactive and no QA process was running after the blocked opening attempt. Unrelated `.superpowers/`, `weppy-project-sync/` and UniHead remain outside this change.

Remaining physical work: unlock the Mac, grant the separate QA app Accessibility and Screen Recording if still absent, connect isolated Chrome/Firefox QA fixtures, verify emergency escape before restrictions, then run three integrated selection/run/stop/save/replay passes. Inspect outlines/blur while moving windows and Spaces; verify IME, keyboard-only use, VoiceOver, reduced display effects and multiple displays. Do not count source review or fixture assertions as completion of these checks.
