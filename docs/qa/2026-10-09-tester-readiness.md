# Intent tester readiness: October 9–11, 2026

Target: a small private tester cohort within two days, gated by evidence rather
than a promise of zero bugs. Freeze new features and visual redesigns. Work one
reproducible defect at a time: reproduce, fix the owner, regression, install,
repeat the failed flow and adjacent working flow, record source/build identity.

October 10 update: the newer source/build and three Chrome 0.2.43 direct-URL
T-to-Run checks are recorded in `2026-10-10-browser-start-and-outlines.md`.
Use `2026-10-10-stabilization-plan.md` for the current ordered gate. The older
versions and acceptance rows below remain historical evidence; quiet finish is
still a blocker and the candidate is not yet tester-ready.

## Release gate

Do not call the build tester-ready with a known crash, data-loss defect, stuck
restriction, failed owned-window restoration, wrong-profile launch, duplicate
startup loop, or broken core selection/start/finish path. Classify each case as
PASS, FAIL, NOT EXERCISED, or AUTOMATION LIMIT. A source test never becomes a
physical-input or live-profile pass. Preserve user tabs, data and preferences.

## Schedule

1. October 9–10: stabilize existing core flows and fix reproducible blockers.
   Serial desktop ownership; no overlapping build/UI workers. Preserve the
   already-verified T and saved-replay behavior.
2. October 10: onboarding/permission and installation audit, missing extension,
   reconnect, stale profile, cancellation and repeated-session checks. Prepare
   tester instructions and a rollback path. No tester needs a source build.
3. By October 11: rerun on the exact packaged candidate, verify matching signed
   Firefox and Chrome distribution route, and freeze one version/checksum.
   Start with 3–5 users; do not distribute an older GitHub release as this build.

## Acceptance queue (in priority order)

| Area | Required cases | Current evidence |
| --- | --- | --- |
| Core browser flow | Firefox/Chrome: select existing tabs, T add/search/cancel, run, Control-Tab, close selected tab | T/Run native UI PASS on 0.2.41; remaining cases queued |
| Saved replay | Missing tab, original window closed, missing app, modifications, no duplicate launches | Native UI PASS: Chrome missing tab; Firefox closed original window; Calculator absent; Stopwatch restored |
| Input | Escape, plain backtick, DBT outlines, held Caps+backtick, latched Caps, successive number toggles | Deterministic coverage passed; physical current-build acceptance pending |
| Completion | Manual, timer, checklist; exact current tab/window retained; owned visibility restored; prehidden untouched; delayed callbacks | FAIL: Firefox and Chrome sibling windows rise during native restoration; latest measured Chrome repeat below |
| Rules | Both access modes; persistent bans; Add as you go on/off; Tab searches old/new tabs | Automated coverage exists; candidate live matrix queued |
| Social controls | Instagram each feature and combinations, Stories-only home without feed; YouTube each option | DOM/route matrix exists; final authenticated profile checks queued |
| Layout | Multiple app windows, labels clear of modifiers, compact finder, URL flight, Reduce Motion | Compact finder verified; flight smoothness pending |
| First run | Clean install, permission denied/granted, browser absent/disconnected, restart/reconnect, uninstall/rollback | Candidate audit queued |
| Distribution | Exact binary/source, signatures, installer, extension versions, update path, checksum, instructions | Source pushed; no current public macOS binary release |

## Evidence and execution log

Baseline primary checkout: codex/name-first-intentions at 5ded6d2; installed
Intent UUID E719BECD-3B1F-3CC6-8A1C-2BB2A30C8896; browser guards 0.2.41.
Previous full eight-suite gate m1CVLd passed. See
2026-10-09-t-transfer-and-saved-replay.md for exact installed acceptance.
Intent - Fix a Bug is idle and last agreed to leave shared checkout/build/UI alone.

No changes to the waitlist, AI product direction, or unrelated user work.

### October 9: sustained-session pass

- Reproduced twice: Firefox-only whitelist with two identical Chrome New tab
  windows stopped after three seconds with `windowIdentityUnavailable`.
  Chrome was wholly blocked and hidden, but per-window matching still required
  unique title/geometry. Confirmed application hiding now satisfies these
  claims only when the whole browser is prohibited. Allowed browser windows
  retain individual enforcement. A fresh visible observation rearms failure.
- Five-suite change gate UAdF7n passed at source fingerprint
  babd0ed307805be1e951fd052b4bf6aade24e79405097dceb31328ae43e505e6.
  Installed UUID E5C563BC-26FB-3AF3-9643-A553BE5C0191.
- Native UI: Firefox whitelist + Tab searches + Stopwatch stayed active for
  over four minutes. Control-Tab and a direct sidebar click changed allowed
  tabs. A fresh Google search worked; direct navigation from that search tab
  to an unapproved website was rejected. Rules remained active throughout.
- Menu Finish deactivated rules and cleared this run's app/window ownership.
  An older Notes entry remained; it was not created by this test. The finishing
  Firefox tab was unchanged at final observation. **NOT a clean focus pass:**
  restoration diagnostics observed two other Firefox windows temporarily in
  front before returning to the target after approximately two seconds.
- Synthetic Shift+backtick did not finish the session. This remains an
  automation limitation/physical acceptance item; menu Finish was used.
- Chrome selected-tab startup separately failed preflight. Native diagnostics
  narrowed it to two standard windows with candidate counts [0, 1]. Chrome's
  grouped-tab AX title contained `– Part of group …`, absent from WindowServer
  and Browser Guard titles. Chrome-only decoration normalization now resolves
  that window; duplicate candidates still fail. No delay-based workaround kept.
- Final five-suite gate o9ZtlB passed at fingerprint
  f50446f165ca657ef8a91c8c39920dc317883c66a7f13b35010e21c2393c1522.
  Installed UUID C7D48A8E-2F4B-3EC7-954D-90472CF716FD. Both guards stay at 0.2.41;
  no extension source changed. The exact previously failing grouped Chrome tab
  then started with Stopwatch and stayed active. Native coverage minimized the
  other profile's window (769); the selected window was 510. Finish released
  rules and all current-run ownership. The original tab remained selected.
- **Open release blocker:** Chrome completion independently reproduced the
  foreground issue: window 769 briefly came forward at 0.366 seconds; target
  510 returned at 1.007 seconds. Firefox showed the same class of issue above.
  Restoring visibility is working; preserving foreground throughout is not yet
  accepted. Do not report the app tester-ready or final focus checks passed.
- Local diagnostics now distinguish startup stage and enforcement category
  without recording titles, URLs, content, or credentials. The pending first
  cohort checklist is `2026-10-09-private-tester-checklist.md`.

### Distribution audit

The latest stable GitHub release is v0.8.1 (July 22) with Browser Guard 0.2.5
assets and no release-manifest.json required by the current release installer.
It must not be advertised as the current candidate. This Mac has zero valid
code-signing identities. The existing beta workflow packages an ad-hoc signed,
non-notarized build; its Sparkle archive signature is not Apple notarization.
The September tester instructions contain obsolete shortcuts and extension
versions and must be replaced before inviting users. No new binary was released
during this pass.

### October 9 evening: reject a failed focus correction

- Tested changing the existing restoration owner to use visible WindowServer
  order instead of waiting for AXFocusedWindow/AXMinimized replies. It retained
  input, Space, target-lifetime and new-session cancellation. The candidate
  passed five isolated suites (Z88vdo, fingerprint
  8e9f726bb099c8ee674df4671ce8274e1f666c917017de9735ee5588593d665a), and installed
  as UUID 41A05AD1-0D5C-3DC2-8213-0A923E3387A5.
- **Rejected on installed acceptance.** With a selected Chrome test tab, other
  browser windows minimized by Intent, and normal File > Finish Intention:
  independent 50 ms onscreen samples saw target 510 at +0.054 s, sibling 769 at
  +0.343 s, and target 510 again at +1.005 s. The recording covers 29.457 seconds
  after finish. Native diagnostics separately confirm the displacement and
  repeated AX cannotComplete replies during it. The strict finish verifier
  rejects this run. Faster/different corrective raises did not fix quiet finish.
- Candidate source reverted to 13fd6b9; do not ship this experiment as a fix.
  A successful test gate does not override the failed live check. The restoration
  effect itself needs a solution; another independent delayed raise is not one.
- This run cleared active browser rules and all current-run hidden ownership.
  The pre-existing Notes PID 632 entry remained. No saved data or user tabs were
  removed; the one disposable QA website tab was closed after verification.
- A separate startup case failed at the activation-confirmation stage after
  installing/reconnecting the helper. The selected tab was active in Chrome but
  its retained inventory still said windowFocused=false. Refreshing the selection
  and retrying started successfully. Cause is **not established**; retain this as
  a startup/preview/reconnection race to reproduce rather than declaring it fixed.
- Tomorrow's download/onboarding work remains the next milestone. It can be
  developed while these failures are investigated, but release readiness still
  requires the exact packaged build to pass start and quiet-finish checks.

Rollback completed through the normal development installer. Installed and source
release UUIDs both equal 42E56D4C-1B1D-3DC6-86A8-98330CE9A3AE; strict/deep signature
verification passed. Source files match 13fd6b9 exactly. This is a rebuilt baseline,
not a corrected quiet-finish candidate. No browser source or extension version was
changed in this experiment.
