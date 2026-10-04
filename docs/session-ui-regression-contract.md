# Session UI regression contract

This is the change map for backtick gestures, session controls and completion.
The goal is repeatable evidence, not a promise that passing tests eliminates all
desktop bugs. Keep fixes local to their owner; do not patch each visible symptom
with another delayed activation or an independent copy of session state.

## Before editing

1. Confirm the checkout/branch, current installed executable and uncommitted work.
   A passing stale worktree is not evidence about the user's running app.
2. Write down the reported input sequence, expected state and foreground app.
   Include Caps Lock **latched on** separately from Caps Lock **physically held**.
3. Find the shared owner below. Add a regression that fails on the old behaviour
   when the defect is deterministic; fix the owner, not just one caller.

| Behaviour | Owning code / deterministic evidence |
| --- | --- |
| Input decoding and delivery | `QuickMarkKeyMonitor.swift`, `GlobalHotKeyManager.swift`; core gesture specs do not prove event-tap delivery |
| Backtick sequences and cancellation | `QuickMarkGesture.swift`, `OverviewSearchGesture.swift`; `QuickGestureRegressionSpecs.swift` and `IntentCoreSpec` |
| Timer deadlines, controls visibility | `SessionRuntimePolicy.swift`, `SessionTimerFormatter.swift`; `SessionRuntimeSpecs.swift` |
| Named/generated intention text | `SessionNaming.swift`; `IntentCoreSpec` and isolated app-model persistence checks |
| Session completion and deferred work | `IntentAppModel.swift`, `IntentLock`; occurrence/lifecycle regressions and isolated presenter checks |
| Runtime window-enforcement failure notice | `SessionFailureNoticePolicy.swift`, `SessionFailureNotice.swift`; typed-error presenter order, security/resume policy and actual nonactivating panel checks |
| Notch sizing, view and nonactivating windows | `OverlayWindowController.swift` and notch layout/presentation helpers; core layout specs and `--qa-notch-checks` |
| Browser activation after completion | Firefox/Chrome background recovery; separate browser harnesses and matching-profile live QA |

## Invariants

- A latched Caps Lock state does not turn an otherwise plain backtick into a
  different modifier chord. Physical Caps Lock + backtick Run remains distinct.
- One input gesture produces at most one action. A consumed down event owns its
  corresponding up event even if modifiers change before release. Repeats do
  not toggle repeatedly. Session/context changes cancel pending gestures.
- Timer/checklist refreshes preserve the user's hidden state for the same
  occurrence. A new occurrence starts with fresh presentation state.
- The timer is notch-anchored, not draggable or user-resizable. Display changes
  recompute geometry; legacy saved panel frames do not override the anchor.
- Checklist interaction stays usable without displacing the anchor. No-notch
  displays, long names and combined modifiers need explicit coverage.
- The same completion path handles normal timer, end-time, checklist and manual
  finish. It cancels old focus work before clearing session ownership. Failures
  and explicit safety-stop reporting remain distinct from successful completion.
- Completion feedback cannot become key/main, activate Intent, switch Spaces,
  raise a browser or accept clicks. Delayed work from an ended/replaced occurrence
  cannot act on a new one. Locked/sleeping sessions never replay old celebration
  on unlock. Respect Reduce Motion.
- A runtime browser-window enforcement failure stops the session and shows a
  finite, nonactivating, mouse-transparent notice independent of timer visibility.
  Keep details for deliberate reopening. Sleep/lock cancels transient feedback;
  wake can rearm only an exact still-running occurrence, never a consumed failure.

## Automated gate

From the intended checkout, run:

```sh
npm run test:session-ui
```

This first runs native CGEvent decoder fixtures without posting input, then
builds the actual `IntentCoreSpec` and runs a renamed `IntentQASpec` copy with a
private marked `INTENT_QA_ROOT`. An environment probe first asserts that default
store lookups resolve to that root, never the daily `.intent` directory. Do not
run the bare CoreSpec binary: lifecycle tests can call real recovery owners.
The gate then builds the release app, packages
a separate signed QA bundle, and runs opt-in app-model and notch presentation
checks in a new marked QA data directory. It does **not** install, launch the daily
app, register a native browser host, activate restrictions or publish anything.
It prints retained logs/previews, records source and binary identity, fails on the
first failed step, and rejects results if relevant source changed during the run.
Use `INTENT_QA_BUILD_PATH` for a separate SwiftPM build directory when needed.

Do not bypass a failing gate with source-text matching tests or a build-only pass.
Run `npm run test:extensions` and `npm run test:native-host` as well when modifying
browser rules, protocol, startup, completion or delayed browser focus behaviour.
The broader `scripts/test-qa-regressions.sh` remains available for a cross-system
pass; none of these commands certifies live desktop acceptance.

## Installed/live acceptance

Coordinate desktop ownership with any other active QA task before installation
or input. Follow `AGENTS.md` for install authority. Record source commit plus dirty
state, built/installed Mach-O UUID, installed bundle path/ID, permissions, OS,
display geometry, and actual browser profile + extension version if involved.

| Test | Required observation |
| --- | --- |
| Physical backtick, Caps Lock off and latched on | Timer, checklist and combined HUD hide and restore once; no stray character, run or overview |
| Physical held Caps Lock Run and double-backtick | Existing Run/mark semantics remain intact; key release and repeats cannot leave a pending gesture |
| Timer, checklist, combined; both access modes | Correct green/red dot, explicit/generated name and timing/progress; no drag/resize affordance |
| Notch, external display, resolution/Space/full-screen change | Anchor stays within the correct display, text avoids notch and menu-bar geometry; no unexpected Space jump |
| Manual finish, duration expiry, absolute end, final checklist item | Same foreground PID/window before and after; no browser, utility or save screen rises |
| Finish immediately after a pending picker/recovery/show animation | No late focus steal or old HUD resurrection; a new session is unaffected |
| Completion colour, duration, Reduce Motion, lock/sleep | Two bounded edge traces meet/fade; mouse/typing still reaches foreground app; no replay on unlock |

Check foreground identity again after delayed callbacks have had time to finish,
not only on the first frame. Start with disposable test data and safe targets;
never close the user's tabs, reset preferences or erase saved intentions to pass.
End with restrictions inactive and no test session left running.

For browser finish traces, capture a separate `optionOnScreenOnly` native-window
query rather than treating an all-window inventory as z-order. Save the matching
`restoration-focus-diagnostics.json` before another session overwrites it. Check
at least 20 seconds **after its `startedAt`**, not merely 20 seconds total:

```sh
node scripts/verify-finish-trace.cjs TRACE.jsonl DIAGNOSTIC.json
```

The verifier rejects short tails, gaps, reordered/stale samples, foreground
changes, Space changes and corrective raises. A sampled pass is not proof of
sub-sample animation, physical key delivery or an untested display/profile.

## Handoff

Report source tests, release build, isolated rendering, installation, live
acceptance, commit and push as separate facts. Mark every untested physical or
profile-dependent item explicitly. Capture a compact QA note with reproduction,
cause, owner, regression and evidence so a future change can rerun the same case.
