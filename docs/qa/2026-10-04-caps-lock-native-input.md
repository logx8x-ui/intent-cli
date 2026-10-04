# Caps Lock native input boundary — 2026-10-04

## Fault and correction

`QuickMarkKeyMonitor` excluded the latched AlphaShift flag from ordinary
modifiers, but then separately queried `CGEventSource.keyState(..., key: 57)`
and treated that Caps Lock state as a physical held Run key. That snapshot does
not establish a new physical Caps press and can also describe a later event
than the callback currently being processed. The reducer's old test supplied
`capsLockHeld: false` directly, so it could not detect a wrong native decoder.

The monitor now uses `QuickMarkKeyboardNormalizer` on the delivered `CGEvent`.
It distinguishes the lock flag from the physical stateless flag, and recognizes
a rising physical flag even when its `flagsChanged` keycode is 255 instead of
57. Releasing Caps while leaving capitals enabled returns backtick to the
ordinary single/double path. Text-editor/IME exclusions and standard shortcut
modifier filtering are retained; no new HID listener, permission or polling is
introduced.

Native definitions verified against the installed macOS SDK:

- `IOKit.framework/Headers/hidsystem/IOLLEvent.h:241` defines
  `NX_ALPHASHIFTMASK` as `0x00010000` (latched capitals).
- The same header at lines 249 and 260 defines
  `NX_ALPHASHIFT_STATELESS_MASK` as `0x01000000` and
  `NX_DEVICE_ALPHASHIFT_STATELESS_MASK` as `0x00000080`.
- Apple's [IOHIDEventService.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventService.cpp)
  assigns the stateless masks to `kHIDUsage_KeyboardCapsLock`.
- Apple's [IOHIKeyboardMapper.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOHIKeyboardMapper.cpp)
  handles the stateless modifier separately and computes modifier flags from
  key-down state (`calcModBit` / `IsModifierDown`).

## Automated evidence

`bash scripts/test-quick-mark-input.sh` passes. This independently compiles the
production normalizer and reducer, creates real `CGEvent` fixtures, and never
posts input to the desktop. The identical fixtures also run from
`IntentCoreSpec`.

Covered: capitals latched on/off; single action exactly once; double-backtick
mark without a stray single; physical Caps in either press order; stateless
bits independently and together; keycodes 57/255; repeated notifications and
key auto-repeat; release then ordinary hide/show; Shift/Command/Control/Option
and finish/save pass-through; Spotlight detection; continuing text cancels a
pending single.

A separate mutation experiment substituting the latch flag for the physical
mask fails with `Native caps latch is neither a shortcut modifier nor a
physically held Run key`. This establishes that the new native-input fixture
detects the lock-state/physical-state confusion, rather than assuming the
correct `capsLockHeld` boolean as the old reducer-only test did.

## Idle-work reduction

Removed the monitor's repeating 25 ms timer (nominally 40 callbacks per second
even with no input). `QuickMarkGesture.pendingSingleDeadline` now drives a
single `QuickMarkExpiryTimer` only after a completed backtick press. It is
cancelled by a double press, continued typing, a chord or context/session reset;
the idle monitor has no expiry timer. This is a source-level wakeup reduction,
not a measured battery-life claim.

The independent harness also compiles the actual app timer helper and verifies
no idle timer, no timer while the prefix is held, exactly one scheduled deadline,
unchanged-deadline reuse, early firing/rechecking uptime, cancellation of an
already-enqueued callback, a single firing exactly once, late-event/expiry race
recovery, and returning to no timer after reset. It uses an injected timer
registrar and deterministic clock, never the desktop event loop.

## Not established by these tests

These are native-event fixtures, not physical hardware or event-tap-delivery
acceptance. A keyboard remapper or device may not preserve the physical flags;
that cannot be inferred from a fixture. The monitor deliberately never falls
back to treating the capitals latch as a held key. No installed app, browser,
Caps Lock state or foreground window was changed by this task's test harness.

Required live matrix once desktop ownership is available:

1. Physically enable Caps Lock and release it. Single backtick hides/shows the
   timer, checklist and unmodified-session UI, with no unexpected Run.
2. Double backtick retains its normal action while capitals remain enabled.
3. Press physical Caps plus backtick in each order, with the latch initially
   on and off; Run fires once and release does not hide/show the new session.
4. Type in an Intent name/text field and marked IME composition; normal input
   remains untouched. Test the built-in keyboard and any configured remapper.

The broader CoreSpec/release/app-install results belong to the parent task's
final gate after concurrent source edits settle.
