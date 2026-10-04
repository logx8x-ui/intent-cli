import CoreGraphics
import IOKit.hidsystem
import IntentCore

/// Construct native events but never post them: these fixtures exercise exactly
/// the decoder used by the event tap, without typing into Logan's desktop.
func runQuickMarkKeyboardInputSpecs() throws {
    func event(_ code: CGKeyCode, _ type: CGEventType, _ flags: CGEventFlags, repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }
    func send(_ code: CGKeyCode, _ type: CGEventType, _ flags: CGEventFlags, at time: Double,
              normalizer: inout QuickMarkKeyboardNormalizer, gesture: inout QuickMarkGesture) -> QuickMarkGesture.Result? {
        guard let input = normalizer.normalize(type: type, event: event(code, type, flags)) else { return nil }
        return gesture.key(input, now: time)
    }

    for capsLatched in [false, true] {
        let latch: CGEventFlags = capsLatched ? .maskAlphaShift : []
        var normalizer = QuickMarkKeyboardNormalizer()
        var gesture = QuickMarkGesture()
        let down = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, latch))!
        try expect(!down.modified && !down.capsLockHeld, "Native caps latch is neither a shortcut modifier nor a physically held Run key")
        try expect(gesture.key(down, now: 0).action == nil, "Caps-on backtick must not dispatch Run instead of hide/show")
        try expect(gesture.pendingSingleDeadline == nil, "Holding backtick schedules no expiry wakeup")
        _ = send(50, .keyUp, latch, at: 0.05, normalizer: &normalizer, gesture: &gesture)
        try expect(gesture.pendingSingleDeadline == 0.05 + QuickMarkGesture.doublePressInterval, "Releasing backtick exposes exactly one monotonic single deadline")
        try expect(gesture.expire(now: 0.34) == .single, "Timer, checklist and other session UI receive the same single action with capitals on or off")
        try expect(gesture.pendingSingleDeadline == nil, "After a single fires there is no idle expiry wakeup")
        try expect(gesture.expire(now: 1) == nil, "A native caps-on single emits exactly once")

        _ = send(50, .keyDown, latch, at: 2, normalizer: &normalizer, gesture: &gesture)
        _ = send(50, .keyUp, latch, at: 2.05, normalizer: &normalizer, gesture: &gesture)
        try expect(send(50, .keyDown, latch, at: 2.1, normalizer: &normalizer, gesture: &gesture)?.action == .mark,
            "Native caps-on double backtick retains marking, without a spurious Run")
        try expect(gesture.pendingSingleDeadline == nil, "A double backtick cancels the pending single timer immediately")
        _ = send(50, .keyUp, latch, at: 2.15, normalizer: &normalizer, gesture: &gesture)
        try expect(gesture.expire(now: 3) == nil, "A native caps-on double does not also hide/show UI")

        for modifier: CGEventFlags in [.maskCommand, .maskShift, .maskControl, .maskAlternate, [.maskCommand, .maskShift]] {
            gesture.reset()
            let input = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, latch.union(modifier)))!
            try expect(input.modified, "Native modifier decoding preserves finish/save and ordinary keyboard shortcuts")
            try expect(!gesture.key(input, now: 0).consume, "Latched Caps cannot intercept a modified backtick intended for Carbon or the foreground app")
        }
        let spotlight = normalizer.normalize(type: .keyDown, event: event(49, .keyDown, latch.union(.maskCommand)))!
        try expect(spotlight.opensSpotlight, "Caps Lock does not block native Spotlight detection")

        gesture.reset()
        _ = send(50, .keyDown, latch, at: 0, normalizer: &normalizer, gesture: &gesture)
        _ = send(50, .keyUp, latch, at: 0.05, normalizer: &normalizer, gesture: &gesture)
        let typed = send(0, .keyDown, latch, at: 0.1, normalizer: &normalizer, gesture: &gesture)
        try expect(typed?.consume == false && gesture.expire(now: 1) == nil, "Native caps-on continuing text cancels a pending single without consuming the letter")
    }

    let physicalMasks = [NX_ALPHASHIFT_STATELESS_MASK, NX_DEVICE_ALPHASHIFT_STATELESS_MASK,
                         NX_ALPHASHIFT_STATELESS_MASK | NX_DEVICE_ALPHASHIFT_STATELESS_MASK]
    for rawMask in physicalMasks {
        for capsLatched in [false, true] {
            let latch: CGEventFlags = capsLatched ? .maskAlphaShift : []
            let held = latch.union(CGEventFlags(rawValue: UInt64(rawMask)))
            for flagsCode: CGKeyCode in [57, 255] {
                for capsFirst in [true, false] {
                    var normalizer = QuickMarkKeyboardNormalizer()
                    var gesture = QuickMarkGesture()
                    if capsFirst {
                        _ = send(flagsCode, .flagsChanged, held, at: 0, normalizer: &normalizer, gesture: &gesture)
                    } else {
                        _ = send(50, .keyDown, latch, at: 0, normalizer: &normalizer, gesture: &gesture)
                    }
                    let action = capsFirst
                        ? send(50, .keyDown, held, at: 0.1, normalizer: &normalizer, gesture: &gesture)?.action
                        : send(flagsCode, .flagsChanged, held, at: 0.1, normalizer: &normalizer, gesture: &gesture)?.action
                    try expect(action == .run, "Physical Caps plus backtick works in either order, independent of latch state and native Caps event code")
                    try expect(send(flagsCode, .flagsChanged, held, at: 0.12, normalizer: &normalizer, gesture: &gesture) == nil,
                        "Duplicate native flagsChanged events cannot retrigger Run")
                    let repeated = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, held, repeatKey: true))!
                    try expect(gesture.key(repeated, now: 0.15).action == nil, "Native backtick auto-repeat cannot repeat Run")
                    _ = send(flagsCode, .flagsChanged, .maskAlphaShift, at: 0.2, normalizer: &normalizer, gesture: &gesture)
                    _ = send(50, .keyUp, .maskAlphaShift, at: 0.25, normalizer: &normalizer, gesture: &gesture)
                    try expect(gesture.expire(now: 1) == nil, "Releasing the physical Run chord cannot hide/show the session UI")
                    _ = send(50, .keyDown, .maskAlphaShift, at: 2, normalizer: &normalizer, gesture: &gesture)
                    _ = send(50, .keyUp, .maskAlphaShift, at: 2.05, normalizer: &normalizer, gesture: &gesture)
                    try expect(gesture.expire(now: 2.34) == .single, "After Run releases, capitals may stay enabled and the next backtick still hides/shows normally")
                }
            }
        }
    }

    var normalizer = QuickMarkKeyboardNormalizer()
    var gesture = QuickMarkGesture()
    _ = send(50, .keyDown, [], at: 0, normalizer: &normalizer, gesture: &gesture)
    try expect(send(57, .flagsChanged, .maskAlphaShift, at: 0.05, normalizer: &normalizer, gesture: &gesture) == nil,
        "A latch-only flagsChanged event is not evidence of a physical Caps press")
    _ = send(50, .keyUp, .maskAlphaShift, at: 0.1, normalizer: &normalizer, gesture: &gesture)
    try expect(gesture.expire(now: 1) == .single, "Latch-only notifications never steal a pending single")
    print("Native keyboard normalization regressions passed (latched and physical Caps, both key orders, keycodes 57/255)")
}
