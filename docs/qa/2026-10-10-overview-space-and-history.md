# Larger overview previews and higher recent-intentions placement

## Request and cause

Logan asked for substantially larger Mission Control previews and for the
recent-intentions log to reach the upper-left/right corners while staying clear
of saved intentions. The old preview search began at a hard 0.42 source scale,
even when an empty screen could accommodate a larger window. The log was
positioned inside the preview canvas, below the entire measured header.

This change is limited to layout. It does not alter browser rules, keyboard
gestures, saved intentions, completion, or the waitlist.

## Change

- `AppStackLayout` packs preview/caption footprints into deterministic free
  rectangles and searches a bounded common scale up to native source size.
  Sibling windows keep a common scale and a larger combined app footprint.
  Hover changes only layering; previews and titles keep their safe boundaries.
- `OverviewHeader` provides the same real header to production and isolated QA.
  It measures the actual name field, visible saved strip, clock and guide.
- `OverviewRecentPanelLayout` gives the log screen-space drag bounds above the
  footer. It avoids those measured controls, clamps complete frames at the
  screen edges, and preserves normalized saved coordinates. A compact screen
  shortens the scrolling log only if its normal size cannot fit safely.
- The root overview hosts the log separately from the clipped canvas and
  translates its settled frame into a preview obstacle. Preview layout changes
  on release, rather than repeatedly rearranging windows during a drag.

## Acceptance and adjacent behavior

Required: upper-left/right movement, persisted position after reopening,
larger sparse and multiwindow previews, equally scaled sibling windows, exposed
titles, no saved/header/footer overlap, and the history panel hidden while a
browser tab drawer is focused. Keep saved-slot reorder/run and selection/input
ownership unchanged.

Source base: `f1a7beb83342ec10439843b85c5ccb61b9361c9b`, primary checkout
`codex/name-first-intentions`. Unrelated `.superpowers/` and
`weppy-project-sync/` remain untouched.

| Evidence | Status |
| --- | --- |
| Required changed-source gate and release build | PASS; five serial suites in `intent-change-gate-2u8aCf` |
| Production header/footer and history geometry | PASS; isolated app model/presentation checks with real measured controls |
| Installed development build identity | PASS; UUID `867AA81B-391F-35CA-8F86-E66C3BDF8AF4`, `dev.loganmondi.intent` |
| Rendered installed layout and drag/reopen | PASS through supported mouse/AX automation on the built-in display; physical human gestures remain separate |
| Physical backtick/Caps/number gestures | Not exercised by this layout request |
| Overall tester readiness | Still blocked by the separate quiet-completion failure and pending browser/profile matrices |

Do not reinterpret a layout pass as closure of the outstanding browser outline,
Firefox package, or continuous foreground-restoration acceptance items in
`2026-10-10-stabilization-plan.md`.

## Verification details

- Frozen primary source fingerprint:
  `e372e717567dcf3dd1411b831b5404d4e2fd56c8a6e699f41162d83c6de9b81c`.
  Gate evidence:
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-2u8aCf`.
  The first gate stopped at a Swift type-inference error in the new sparse-layout
  fixture. Explicit fixture types repaired it; the entire gate was rerun.
- Core behavior passed the new sparse, 6/18/36/50 mixed-size, obstacle and
  translated-monitor cases. Two 18-window layouts took 20 ms in that run.
  The release build passed, followed by 1,460 isolated app persistence/layout
  assertions and 232 notch presentation assertions. These counts are not live
  browser or physical-input acceptance.
- Installed using authorized `scripts/install-dev.sh` with the system toolchain
  and two Swift build jobs. Stable bundle:
  `/Users/loganmondi/Applications/Intent.app`, PID `55173` at verification.
  Rules were inactive before and after. Successful previews/selection show the
  existing Accessibility and Screen Recording grants were usable; no permission
  settings were changed.
- Actual full overview rendered at 1710×1112 points (3420×2224 capture pixels).
  The saved name/slots and every visible caption stayed clear of the footer.
  The existing three Firefox windows and two Word windows retained exposed,
  equal-size previews for equal-size source windows. Dense layouts are still
  limited by the actual total group footprints, not a fixed source-size cap.
- Supported mouse drags moved the history header from upper-left to upper-right,
  then toward the protected centre (placed below saved controls), then back to
  upper-left. Escape closed the overview; reopening preserved its new position.
  Opening the daily Chrome drawer hid the log, and closing the drawer brought it
  back. No intention was run and no tabs, saved entries or apps were deleted.
- Observation boundary: directly asking the native automation binding to observe
  Intent after closing can reopen it via the existing macOS reopen handler.
  Observing Chrome instead and independently querying on-screen native windows
  confirmed both Escape and the Close button left no Intent window on screen.
  This explains that observation path; it does not certify every prior
  Settings-host closure or physical shortcut case.
- Final Firefox setup still reports permanent Guard 0.2.42 rather than embedded
  0.2.43. That pre-existing matching-profile limitation is unchanged by layout.

## Publication

The seven-file scoped change is primary commit
`8abd1d754e2ecf85072d863963c04b9fa41d73ee` and public commit
`974eba0c3e3d3c4fd4f50facef224b27c9277a72` on
`codex/overview-finder-fixes`. The publication checkout passed all five serial
changed-source suites against `eef49bf8909ce52a0bc5afe1056eea7a396dc1d5`:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-oyVswz`,
fingerprint `547420ad51bd5b398f7c0611c970584fe6fc694a529fca058041d8fa8225b68b`.
The normal branch push succeeded and its remote ref matched the public commit.
This is a source-branch publication, not a new signed binary release or a claim
that the remaining tester gate passed.
