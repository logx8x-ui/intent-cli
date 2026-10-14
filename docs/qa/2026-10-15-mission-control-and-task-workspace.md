# Mission Control safety stop and Test Intent task workspace

## Observed failure, not an inferred app crash

The most recent recorded occurrence was a native-window safety stop before readiness (`nativeWindowEnforcementFailure`, about 3.46 seconds). ChatGPT/Codex's selected native window 121 was available; named sibling 151 was listed by WindowServer but absent from the application's AXWindows, AXMainWindow and AXFocusedWindow roots. The independent read-only inventory on 15 October showed 151 positively offscreen and 121 onscreen. No matching Intent app crash report was found. This explains this occurrence, but does not establish that every reported post-Mission-Control termination has this same cause.

The runtime now distinguishes positively observed offscreen windows from missing/unavailable inventory. Exact PID/birth/window identities stay tracked after startup. Reappearance or failed observation requires verified hiding within the existing bounded interval; whole-app exclusions and click/foreground rules remain enforced. Space changes queue an immediate coalesced check. Add as you go's startup-only restrictions retire when its ongoing policy permits that exact window.

## Task workspace

Only the explicitly compiled development channel exposes Tasks. The launch channel has no entry point and its default task store refuses access. The workspace uses the overview's desktop background, General inbox, movable list cards, task completion, drag/reorder, saved-intention mentions and Undo. Clicking a task prepares its name and linked configuration for review; it does not silently start a session.

Three-finger horizontal recognition is local to the overview, accepts exactly three stable indirect contacts, rejects vertical gestures and triggers once per contact sequence. It does not change macOS trackpad settings. Actual trackpad delivery and conflicts with OS-reserved gestures remain a physical acceptance item. Tasks and Choose apps buttons provide visible access in either direction.

Task documents are separate from saved intentions, written atomically with private permissions, backed up, and protected against stale writers/newer unsupported formats. General cannot be removed; removing a folder moves its tasks to General. Task typing has local keyboard ownership so normal letters, digits and backticks do not run overview actions. A pending saved Run cannot switch to Tasks and later start behind it.

## Verification

- Final `npm run test:changed`: all eight mapped suites passed (gate accounting, session, Swift, Firefox/Chrome extension behavior, native host, release/channel contracts, AI, extension lint).
- Source fingerprint: `571acf3323668c13ee1370c7121594a8ea8785e414e93e388523567c31689dd8`; source stayed unchanged throughout. Base commit: `f5a9042bfa8212d77ebd47960c86d294806afcf7` plus the scoped changes recorded with this note.
- Receipt: `dist/qa-20261015-mission-control-task-workspace/change-gate/result.json`. The receipt correctly reports `releaseReady: false`; none of its physical checks are promoted by automated results.
- Release-channel compilation and isolated production-controller/UI checks passed: **1,691 assertions**. Existing Swift 6 actor-isolation migration warnings remain outside this change.
- Separate development-channel compilation passed; executable UUID `B6ED4B16-7858-345E-B73D-634D11888C07` (ARM64). Its isolated app/controller checks passed: **1,694 assertions**, including task-to-draft name, saved Timer/Checklist preservation, missing preset recovery and closed-controller fences.
- Rendered workspace images at 800×600 and 1280×800 visually inspected after correcting lower card clipping. This is offscreen rendering, not installed UI acceptance.
- Independent review found and repaired Add as you go's deferred-target retirement and unsaved task draft/folder-removal paths before the final gate. Two final read-only reviews found no additional concrete defects.
- The desktop locked during hosted-package verification. Installed app replacement, DBT/SBT→Apple Mission Control→click allowed window, trackpad, and visible drag/mention interactions have not passed in this run.

## Regression and release boundary

Source changes require the mapped behavioral suites, including channel/release checks. Source fingerprints include untracked Swift files and reject changes during a gate. Machine receipts explicitly keep releaseReady false and reset physical evidence to pending; automated success cannot certify desktop behavior. Compiler workers default to 1 to limit laptop pressure.

The local checkout has the stronger CI workflow, but the remote source branch still has the older workflow: prior OAuth publication could not write `.github/workflows`. A fresh attempt through the GitHub connector on 15 October also returned HTTP 403, `Resource not accessible by integration`. Local gate success must not be described as branch protection or active remote CI enforcement. Do not merge or enable downloads based only on these tests.

Implementation is committed locally as `3c9b1a2aed9df8ba775d0acc0ff8febb1dff5f7e`. The same 35 changed source/script/note files are published on `codex/selected-resource-lifetime` as `ec3a535571eb68429feeca7d4aae6e69d683405d`, preserving its existing workflow and unrelated history. No release, main-branch update, installed-app replacement or private catalog promotion was performed. Test Intent's prepared isolated QA bundle is `/Users/loganmondi/.codex/artifacts/intent-qa/package-sS4EKV6b/Intent QA.app`; it is not the daily Test Intent installation.

The private upload UI confirmed all three build 202610140002 installers were checksum-verified and stored privately. Hosted HEAD/range/full-download verification was started but its completion was not observed before screen lock. These are older packages, not the new fix; the release catalog remains unpinned. The separate Firefox finish-focus regression, matching Chrome store approval, fresh-account installation and supported-OS evidence remain release blockers. Do not publish these artifacts as a qualified release.

Next installed acceptance: normally quit the idle daily channel, use the development installer, verify its channel/UUID/native bridge, then run the SBT and DBT Mission Control click journeys separately. Verify native three-finger input, list/task dragging, mention selection, draft departure/reopen and named overview preparation. The installer intentionally refuses to replace either running engine; the screen lock is not a reason to bypass that guard. Preserve the independent timer-finish trace as a separate failing case until it passes without corrective window activation.
