# Intent overview layout — 21 September 2026

Status: scoped layout implementation, full release CoreSpec, app release packaging/signature and live overview/sidebar checks passed in the isolated QA build. Wider application acceptance remains separate.

## Report and scope

The user reports that double-backtick now appears fixed in the Chrome QA Notes tab. Their new screenshot shows a sparse overview: small window thumbnails, repeated small utilities occupying large grid slots, clipped or abbreviated labels, and too much unused space. They want sizing and arrangement closer to Apple Mission Control.

The isolated QA boundary remains in force: no daily-app replacement, release, push, account change or personal-profile extension installation. No enforcing intention is needed for this visual check.

## Changes

- Replaced equal grid cells with compact rows fitted to actual window shapes, maximizing a shared scale while preserving relative size and aspect ratio.
- Uses native source positions to prefer familiar left/right and upper/lower arrangements; keeps deterministic identity-to-frame mapping.
- Reserves actual label space, including a minimum 110-point footprint for narrow windows. Preview placement now accounts for its caption separately.
- Bounds the hosting view, full-screen content and footer to the display. Keeps the centered Intent title, time, wallpaper, green/red outline and bottom modifiers.
- Adds recognizable app icons, readable labels and compact browser-tab controls. Captures, selection semantics and browser enforcement are unchanged.

No heuristic removes windows by title or size, because that would hide genuine small windows, dialogs or duplicate browser windows.

## Checks

Focused layout checks cover 1–50 mixed windows, landscape/portrait/negative-origin displays, a narrowed browser-sidebar area, reserved labels, collisions, aspect ratios, shared scale, deterministic results and spatial ordering. The screenshot-shaped 21-window fixture increases scale from approximately 0.1703 to 0.2492 (about 46% wider/taller); this is a deterministic fixture measurement, not a measured gain for every live desktop.

`swift run -c release IntentCoreSpec` passed with exit code 0 after a 516.85-second release compilation (`/tmp/intent-overview-layout-core.log`). The run passed 100 quick-gesture sequences, onboarding presentation specifications and the complete new FieldOfViewLayout specifications, then reported IntentCoreSpec passed. The expanded standalone layout suite also passed; an optimized 100-layout benchmark averaged 1.89 ms for a 21-window source-aware layout on this Mac.

`scripts/build-qa.sh --data-root /private/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-dW8GexAs` passed with exit code 0 after 222.81 seconds of release app compilation (`/tmp/intent-overview-layout-build.log`). Artifact: `/Users/loganmondi/.codex/artifacts/intent-qa/package-buBsUPCq/Intent QA.app`. `codesign --verify --deep --strict` passed. No browser code changed, so no new extension regression run is claimed.

The old QA app was quit and absence of any QA process verified before launch. Only the QA Screen Recording and Accessibility entries were refreshed through supported System Settings controls, using the exact new artifact. After the Screen Recording restart, sole PID 21890 matched the new path. The gesture diagnostic reported Accessibility trusted, gesture ready and Carbon fallback absent after Accessibility refresh without another restart.

Live AX and screenshots verified:

- The full overview shows 23 app/window entries with larger, compactly arranged previews, native proportions, app-icon labels, centered title, clock, green border and visible bottom controls.
- Opening the Chrome QA browser tile repacks the left area without overlapping the right tab panel or footer.
- The existing explicit browser-window chooser was required because multiple native Chrome windows have ambiguous matching details. Choosing the connected QA window displayed all seven tabs.
- The separate Tasks tab could be selected and deselected in the picker; Run enabled and then disabled accordingly. This is picker selection evidence, not physical double-backtick proof on that tab.
- Closing the tab panel restored the full arrangement. The new overview is left open for user review with empty selection and no active intention.

Final read-only checkpoint: all three daily intention/schedule/cooldown hashes match the baseline, QA browser rules are inactive, the QA saved collection still contains one intention, Chrome QA heartbeat age is 1.4 seconds and PID 21890 reports the gesture listener ready. No push, release, daily-app replacement or personal-profile modification occurred. The browser fixtures remain available for ongoing QA; fixture cleanup and three fully integrated acceptance passes are not claimed.

No physical gesture or three-pass integrated acceptance is inferred from these layout tests. Real multiple-monitor, display-scaling and reduced-effects acceptance remains untested; their geometry is covered only by deterministic layout checks.

## Chrome connection boundary

Read-only inspection confirmed Profile 7 (Intent QA) uses Browser Guard 0.2.12 with a private QA native host and data root. The personal Default profile uses the daily host and its heartbeat reports 0.2.11 without the current group/session capabilities. The six QA fixture tabs all have valid selectable IDs; there is no Notes-site-only rule. The user was asked which profile contained the tabs that failed. No other-profile success is claimed, and no personal extension was modified.
