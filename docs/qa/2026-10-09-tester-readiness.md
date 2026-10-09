# Intent tester readiness: October 9–11, 2026

Target: a small private tester cohort within two days, gated by evidence rather
than a promise of zero bugs. Freeze new features and visual redesigns. Work one
reproducible defect at a time: reproduce, fix the owner, regression, install,
repeat the failed flow and adjacent working flow, record source/build identity.

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
| Completion | Manual, timer, checklist; exact current tab/window retained; owned visibility restored; prehidden untouched; delayed callbacks | Earlier installed evidence exists; candidate repeat queued |
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
