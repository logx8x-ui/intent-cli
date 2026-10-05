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
4. List adjacent **working** behaviours before changing the owner. On October 5,
   2026 Logan physically confirmed Caps Lock + backtick Run and number toggles
   on `f969241`. Preserve those fixtures and recheck those flows for input or
   selection changes. User confirmation is evidence for that build, not a pass
   automatically inherited by a subsequent build.
5. Run `npm run qa:plan` (or `npm run qa:plan -- --base <pre-change-commit>` for
   committed changes). Inspect the mapped consumers, not only the edited file.
   New runtime paths deliberately receive broad coverage until a reviewed,
   behaviour-tested narrower mapping is justified.

| Behaviour | Owning code / deterministic evidence |
| --- | --- |
| Input decoding and delivery | `QuickMarkKeyMonitor.swift`, `GlobalHotKeyManager.swift`; core gesture specs do not prove event-tap delivery |
| Backtick sequences and cancellation | `QuickMarkGesture.swift`, `OverviewSearchGesture.swift`; `QuickGestureRegressionSpecs.swift` and `IntentCoreSpec` |
| Timer deadlines, controls visibility | `SessionRuntimePolicy.swift`, `SessionTimerFormatter.swift`; `SessionRuntimeSpecs.swift` |
| Named/generated intention text | `SessionNaming.swift`; `IntentCoreSpec` and isolated app-model persistence checks |
| Session completion and deferred work | `IntentAppModel.swift`, `IntentLock`; occurrence/lifecycle regressions and isolated presenter checks |
| Runtime window-enforcement failure notice | `SessionFailureNoticePolicy.swift`, `SessionFailureNotice.swift`; typed-error presenter order, security/resume policy and actual nonactivating panel checks |
| Notch sizing, view and nonactivating windows | `OverlayWindowController.swift` and notch layout/presentation helpers; core layout specs and `--qa-notch-checks` |
| Compact HUD palette and completion laser | `SessionChromeStyle.swift`, `SessionCompletionLight.swift`; `SessionCompletionLaserChecks.swift` samples the actual finite animation layers |
| Browser activation after completion | Firefox/Chrome background recovery; separate browser harnesses and matching-profile live QA |
| Actual staged browser outline | `WorkspaceWindow.swift`, browser session/tab identity and active-tab snapshot; actual browser surface acceptance distinct from overview selection state |

## Invariants

- A latched Caps Lock state does not turn an otherwise plain backtick into a
  different modifier chord. Physical Caps Lock + backtick Run remains distinct.
- The overview and staged-selection routes both accept physical Caps Run in
  either key order when physical-held state is supplied. Backtick-first also
  accepts the documented Caps-specific latch-transition event when optional
  stateless bits are absent; sticky Caps alone never means Run. Native routing
  fixtures must include that compatibility path and the overview callback,
  optional empty names, editor transitions and consumed releases, not only the
  standalone gesture reducer. Never hold inout gesture access across UI callbacks.
- Explicit non-browser selection dismisses the tab picker, cancels its pending
  resolution/reload/preview work, and preserves already-selected browser tabs.
- Leaving overview with a retained target restores its staged modifier strip.
  Editing a staged modifier preserves the selected visible window's outline;
  unrelated foreground applications do not inherit that exception. Partial
  tab selections highlight their exactly identified native-window preview,
  without implying all tabs are allowed or guessing ambiguous window identity.
- Overview preview highlight and the actual staged browser-tab/window outline
  are separate outputs. Test both: mark a real Firefox tab with DBT, move between
  marked/unmarked tabs and sibling browser windows, edit a modifier, enter/leave
  overview, and check the actual foreground browser outline. A green thumbnail,
  selected model ID or icon screenshot does not pass that case. Repeat in Chrome
  whenever shared selection, snapshot, outline or identity code changes.
- Tab icons use browser-provided addresses only, bounded memory caches, and
  stable browser-session/tab/site identity. Missing or failing updates retain a
  known good same-site icon; navigation/restart and late replies cannot reuse an
  unrelated icon. No third-party favicon-discovery service is introduced.
- New timers remember the last explicitly entered valid duration. Opening a
  saved timer must not change that preference or the saved timer's own meaning.
- One input gesture produces at most one action. A consumed down event owns its
  corresponding up event even if modifiers change before release. Repeats do
  not toggle repeatedly. Session/context changes cancel pending gestures.
- Timer/checklist refreshes preserve the user's hidden state for the same
  occurrence. A new occurrence starts with fresh presentation state.
- The timer is notch-anchored, not draggable or user-resizable. Display changes
  recompute geometry; legacy saved panel frames do not override the anchor.
- Checklist interaction stays usable without displacing the anchor. No-notch
  displays, long names and combined modifiers need explicit coverage.
- The physical camera gap, not the asymmetric outer HUD frame, owns the anchor
  and laser origins. Timing uses 13-point menu-bar typography; the hardware name
  lip is 14 points. Checklist input lives in a separate below-notch panel:
  the entire screen-top header must pass clicks through to the menu bar.
- Replace hosted content only through `SessionNotchPanel.setHostedContent`:
  disable automatic window-size negotiation and apply the authoritative frame
  after assigning/layout of the controller. Exercise real controller replacement
  across expand/collapse, not only NSHostingView bitmap renders. Cropped-away
  content must not expose invisible Accessibility controls in the other panel.
- Whitelist/blacklist dots and completion use one resolved dark-mode accent.
  The completion core is 1 point with bounded 180-point tails, never a white flash
  or a persistent whole-screen animation timer. Inspect real header/control
  crops as well as the combined preview whenever their geometry changes.
- The same completion path handles normal timer, end-time, checklist and manual
  finish. It cancels old focus work before clearing session ownership. Failures
  and explicit safety-stop reporting remain distinct from successful completion.
- DBT start preserves the exact native window and, for browsers, active tab at
  Run invocation. Do not replace that target with the first marked app/window,
  reopen an already present website, or rely on PID alone. Completion captures
  the current native window/tab at finish, independently of the start target.
  A sibling Firefox window is a failure even though its PID and bundle match.
  Automatically restoring other minimized windows must not move focus or Spaces;
  unsafe restoration is deferred until deliberate user reveal, including across
  retries/restarts. Never hide a jump with a later corrective activation.
- Completion feedback cannot become key/main, activate Intent, switch Spaces,
  raise a browser or accept clicks. Delayed work from an ended/replaced occurrence
  cannot act on a new one. Locked/sleeping sessions never replay old celebration
  on unlock. Respect Reduce Motion.
- A runtime browser-window enforcement failure stops the session and shows a
  finite, nonactivating, mouse-transparent notice independent of timer visibility.
  Keep details for deliberate reopening. Sleep/lock cancels transient feedback;
  wake can rearm only an exact still-running occurrence, never a consumed failure.

## Automated gate

For every runtime change, from the intended checkout run:

```sh
npm run qa:plan
npm run test:changed
# Include committed edits when continuing/reviewing an existing change:
npm run test:changed -- --base <pre-change-commit>
```

`scripts/change-impact.cjs` maps the diff (including staged changes, deletions,
rename sides and owned untracked source) to existing suites. Swift app/core/lock
changes conservatively run the isolated session gate, Swift specs, both browser
suites and native-host tests. Browser edits also check app consumers, release
compatibility and lint. Tooling/dependency or unknown runtime changes select all
safe suites; documentation-only changes run the gate's own accounting tests.
Tests verify mapping, real Git discovery, fail-fast execution, content identity
and the boundary that automated passes leave all live cases **pending**.

The runner executes serially, records source fingerprint/commit/changed files
and separate suite logs in a private temporary evidence directory, and rejects
source drift after each suite. QA notes are excluded from the source fingerprint;
staging identical content does not invalidate it. No installation, active session,
release, extension signing or publication occurs. Do not run another SwiftPM gate
against the shared build directory in parallel. The existing GitHub workflow
runs the gate for pull requests and `main`/`codex/**` pushes; beta publication is
still main-only and depends on it. CI is automated evidence, not desktop approval;
branch-protection settings are a separate repository administration concern.

For a narrower iteration on session behaviour, run:

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
browser rules, protocol, startup, completion or delayed browser focus behaviour;
the change-impact gate selects them automatically for these coupled areas.
The broader `scripts/test-qa-regressions.sh` remains available for a cross-system
pass and now routes lifecycle specs through private QA roots. `test:swift` uses
the same renamed, environment-probed spec isolation; never invoke its bare build
outputs directly. None of these commands certifies live desktop acceptance.

## Installed/live acceptance

Coordinate desktop ownership with any other active QA task before installation
or input. Follow `AGENTS.md` for install authority. Record source commit plus dirty
state, built/installed Mach-O UUID, installed bundle path/ID, permissions, OS,
display geometry, and actual browser profile + extension version if involved.

| Test | Required observation |
| --- | --- |
| Physical backtick, Caps Lock off and latched on | Timer, checklist and combined HUD hide and restore once; no stray character, run or overview |
| Physical held Caps Lock Run and double-backtick | Existing Run/mark semantics remain intact; key release and repeats cannot leave a pending gesture |
| Backtick-number toggles, Caps off and latched on | Each press toggles exactly once in overview and staged mode; editing/escape does not lose target or modifier state |
| Real DBT browser outline | Mark a Firefox tab on the actual browser surface, not the overview thumbnail; correct green/red outline persists through modifier editing and overview escape/reentry, while unmarked tabs/sibling windows do not inherit it; repeat Chrome for shared changes |
| DBT Run with two browser windows and several marked targets | Record native window ID, browser profile/session/window/tab IDs at invocation; the same exact window and tab remain foreground throughout startup, with no duplicate website open |
| Timer, checklist, combined; both access modes | Correct green/red dot, explicit/generated name and timing/progress; no drag/resize affordance |
| Notch, external display, resolution/Space/full-screen change | Anchor stays within the correct display, text avoids notch and menu-bar geometry; no unexpected Space jump |
| Manual finish, duration expiry, absolute end, final checklist item | Same foreground PID/window before and after; no browser, utility or save screen rises |
| Finish immediately after a pending picker/recovery/show animation | No late focus steal or old HUD resurrection; a new session is unaffected |
| Completion colour, duration, Reduce Motion, lock/sleep | Two bounded edge traces meet/fade; mouse/typing still reaches foreground app; no replay on unlock |

Check foreground identity again after delayed callbacks have had time to finish,
not only on the first frame. Start with disposable test data and safe targets;
never close the user's tabs, reset preferences or erase saved intentions to pass.
End with restrictions inactive and no test session left running.

Use at least two native windows of the same browser for start/finish checks and
finish from a different window than the start when permitted. Record the actual
current profile, extension ID/version/install type, fresh host connection and
browser-session/window/tab IDs; a temporary extension does not prove the permanent
package is current. Native window identity must be measured independently of
browser IDs. Do not substitute title/PID equality or extension approval for this
acceptance. Repeat through delayed callbacks, with an unrelated minimized sibling
window present. Check normal finish plus every changed expiry/completion route.

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
Include a compact table separating: user-confirmed baseline, deterministic
regression, release build/installed UUID, actual rendered surface, physical input,
exact-profile start/finish and delayed-window trace. Use `passed`, `failed` or
`not exercised` per row; no blanket "all tested" if any affected row is missing.
