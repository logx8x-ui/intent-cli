# Notch controls and quiet completion — 2026-10-04

## Requested contract

- Latched Caps Lock does not change backtick hide/show. Physically held Caps +
  backtick retains Run, and double-backtick retains marking.
- Timer is fixed around the current display's actual camera exclusion: green
  whitelist/red blacklist left, effective timer/end-time right, existing named
  or generated intention text below. No drag, resize, or saved-position restore.
- Checklist uses the same header with progress and an anchored scrollable tray.
  External displays fall back to a fixed top-centre cap below the menu bar.
- Every end preserves current work. A finite, nonactivating, click-through light
  trace travels from both notch sides around the display edges and meets/fades.
- Future changes run a common regression gate and distinguish source, installed
  binary, rendered UI, real keyboard, browser profile and foreground evidence.

## Root causes and owning fixes

1. The native input adapter interpreted latched Caps state as a held Run key.
   `QuickMarkKeyboardNormalizer` now decodes Apple's physical/stateless flags;
   see `2026-10-04-caps-lock-native-input.md` for native fixtures and limitations.
2. The old panel persisted its dragged rectangle and offered expansion for a
   timer. `SessionNotchLayout` and `SessionNotchView` replace that UI; only a
   checklist exposes expansion. Display changes recompute the anchor without
   changing the user's hide/show state.
3. Queued native app/tab-switcher and AX-recovery actions survived stop requests.
   `DeferredSessionActionGate` fences each bounded effect. Stop invalidates them
   immediately; old onReady/teardown callbacks cannot affect a replacement run.
4. Legacy GUI resource closure could terminate the foreground work, and safety
   or continuing-work-period transitions could present a new chooser. GUI finish
   preserves resources; interrupted work remains recoverable explicitly. A work
   period continues silently permitting the current work app while choosing.
5. A delayed modifier-popover dismissal could reactivate a previous application.
   Only a still-visible, active, pre-session editor may now return focus.
6. Backtick expiry polled every 25 ms while idle. It now creates a one-shot timer
   only for an actual pending single press; native scheduler regressions exercise
   cancellation, stale callbacks and early/delayed firing.

## Presentation safeguards

- Session HUD cannot become key/main; timer-only content is mouse-transparent.
- Completion is a separate nonactivating panel, never a normal window. It ignores
  mouse input and contains no app/window activation or Space movement calls.
- Core Animation owns the finite 1.05-second effect; no display link or recurring
  animation timer. Reduce Motion uses a subtle edge fade instead of travelling.
- New sessions, lock/sleep and explicit hiding cancel pending feedback. The
  occurrence ID prevents replay. A failed startup does not celebrate completion.
- Geometry tests cover secondary-display offsets, no-notch fallback, long lists,
  partial camera metadata and mixed duration/end-time deadlines. The HUD displays
  the deadline which will actually end the session, not a later unused end time.

## Verification record

Passed on the combined source, with no source changes during the gate:

- `npm run test:session-ui`: native event decoding and real one-shot scheduler,
  full `IntentCoreSpec`, release app build, isolated model checks (42 assertions),
  real panel/content checks (20 assertions), packaging/signature and whitespace.
- `npm run test:extensions`: Firefox/Chrome rules, background behaviour, idle
  work, popup status, tab visibility/restoration and website-feature parity.
- `npm run test:native-host`: bridge protocol, performance, snapshot freshness,
  notification, profile isolation and command routing; peak test RSS 8.1 MiB.
- Inspected rendered whitelist timer and blacklist checklist PNGs; name, mode,
  countdown/progress and checklist text visible. This is offscreen rendering.

Evidence directory:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-ugJLuJ4g`.
Isolated rendered content:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-Vo8ItaCI`.
Packaged QA executable UUID: `6B436395-ECEB-3C3E-99F5-13935DC60BB4`.
Daily installed executable was separately checked and is still the older UUID
`1BFD7BE8-0613-3EC7-BA9C-7A9863A95FD3` at
`/Users/loganmondi/Applications/Intent.app/Contents/MacOS/IntentApp`.
No daily app install/relaunch or browser profile mutation was performed here.

Use `npm run test:session-ui` and retain its provenance/log directory. It creates
isolated QA storage and renders the production SwiftUI content inside AppKit.
See `docs/session-ui-regression-contract.md` for owners and the full live matrix.

At implementation time, the other Intent chat owned browser signing/live QA.
The Mac then locked before this task's installation or physical acceptance.
Neither source tests nor offscreen preview renders establish installed notch
alignment, actual Caps Lock event delivery, Space behaviour or final foreground
stability. Those remain explicit live checks, not inferred passes.
