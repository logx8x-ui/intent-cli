# Option 2: silver session capsule

Requested: compact black glass, silver-white name and timing, fine silver border
and a subtle star; shared by Intent and Test Intent. Preserve timer, stopwatch,
checklist expansion, backtick hide/restore, nonactivation, and completion light.

Implemented in shared session presentation, with no channel conditional:
264 x 28 points, six points below the camera/menu exclusion; same capsule on
external displays. Long names truncate in the middle. Checklist expands beneath
the same header. Its one live clock belongs to the nonactivating controls panel;
no duplicate hardware-notch clock or old wing-shaped input region remains.

The actual hosting test caught AppKit rounding a half-point X coordinate beneath
an odd-width camera. Geometry now uses a whole-point origin; an added regression
checks stable placement within half a point of the camera centre.

Automated gate passed five affected suites (gate/session/Swift/extensions/host):
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-sRfASq/result.json`.
Source fingerprint bd6a9d3fe06777384f88a461a1f52bafe64cd1a8e1341c2d6c83b7c6b5e34e84.
Real-panel presentation passed 237 assertions, including repeated replacement,
collapse/expansion, offset/external displays, timing widths and nonactivation.
Actual render artifacts:
`/Users/loganmondi/.codex/artifacts/intent-silver-capsule-20261014/capsule.png`
and `checklist.png`. These are production-content renders, not live acceptance.

Work is isolated from Head Chat's active onboarding/installer changes. Both local
channel builds use the same presentation source. Installation and release
qualification must be coordinated with the active owner before replacing apps;
the older notarized package does not contain this design.
