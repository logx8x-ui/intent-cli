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

    try runCapsLockCompatibilityRoutingSpecs()
    try runOverviewKeyboardRoutingSpecs()
    print("Native keyboard normalization and routing regressions passed (overview/staged selection, Caps-specific latch transitions, stateless Caps in both key orders, keycodes 57/255)")
}

/// A Caps-specific flagsChanged event is an input edge, not merely the capitals
/// latch carried by an unrelated key. Session event delivery need not include
/// the optional HID stateless bits (Apple QA1519). The original fixture encoded
/// only stateless events and incorrectly required this documented path to drop.
private func runCapsLockCompatibilityRoutingSpecs() throws {
    func event(_ code: CGKeyCode, _ type: CGEventType, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
        event.type = type; event.flags = flags
        return event
    }
    for startingLatch in [CGEventFlags(), .maskAlphaShift] {
        let toggledLatch: CGEventFlags = startingLatch.isEmpty ? .maskAlphaShift : []
        var normalizer = QuickMarkKeyboardNormalizer()
        _ = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, startingLatch))
        let caps = normalizer.normalize(type: .flagsChanged, event: event(57, .flagsChanged, toggledLatch))
        try expect(caps?.code == 57 && caps?.down == true && caps?.capsLockHeld == false,
            "A compatibility Caps transition is a single press edge, never a fabricated physical hold")
        try expect(normalizer.normalize(type: .flagsChanged, event: event(57, .flagsChanged, toggledLatch)) == nil,
            "Duplicate latch-only Caps flags are ignored at the native decoder")
        let laterBacktick = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, toggledLatch))!
        try expect(!laterBacktick.capsLockHeld,
            "A latch transition before backtick cannot leak a sticky physical-Caps state")

        normalizer = QuickMarkKeyboardNormalizer()
        _ = normalizer.normalize(type: .keyDown, event: event(50, .keyDown, startingLatch))
        try expect(normalizer.normalize(type: .flagsChanged,
            event: event(56, .flagsChanged, toggledLatch.union(.maskShift))) == nil,
            "A changed capitals latch carried by an unrelated modifier key is not a Caps press")
        try expect(normalizer.normalize(type: .flagsChanged, event: event(57, .flagsChanged, toggledLatch)) == nil,
            "An unchanged Caps notification after a flags snapshot is not another press")

        for mask in [NX_ALPHASHIFT_STATELESS_MASK, NX_DEVICE_ALPHASHIFT_STATELESS_MASK] {
            normalizer = QuickMarkKeyboardNormalizer()
            let held = startingLatch.union(CGEventFlags(rawValue: UInt64(mask)))
            _ = normalizer.normalize(type: .flagsChanged, event: event(57, .flagsChanged, held))
            try expect(normalizer.normalize(type: .flagsChanged, event: event(57, .flagsChanged, toggledLatch)) == nil,
                "A known stateless Caps release cannot masquerade as a compatibility press when its latch changes")
        }
    }
    for overviewVisible in [false, true] {
        for capsLatched in [false, true] {
            let before: CGEventFlags = capsLatched ? .maskAlphaShift : []
            let after: CGEventFlags = capsLatched ? [] : .maskAlphaShift
            var normalizer = QuickMarkKeyboardNormalizer()
            var overview = OverviewSearchGesture(), global = QuickMarkGesture()
            var overviewActions: [OverviewSearchGesture.Action] = []
            var globalActions: [QuickMarkGesture.Action] = []
            @discardableResult
            func deliver(_ code: CGKeyCode, _ type: CGEventType, _ flags: CGEventFlags, time: Double) -> Bool {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
                event.type = type; event.flags = flags
                guard let input = normalizer.normalize(type: type, event: event) else { return false }
                let route = QuickMarkKeyboardRouting.route(input, intentOwnsInput: overviewVisible,
                    editingText: false, overviewHandler: { input in
                        let result = overview.key(code: input.code, down: input.down, modified: input.modified,
                            repeated: input.repeatKey, editing: false, capsLockHeld: input.capsLockHeld)
                        if let action = result.action { overviewActions.append(action) }
                        return result.consume
                    }, gesture: global)
                switch route {
                case .overview: global.reset(); return true
                case .text: global.reset(); return false
                case .gesture:
                    let result = global.key(input, now: time)
                    if let action = result.action { globalActions.append(action) }
                    return result.consume
                }
            }
            deliver(50, .keyDown, before, time: 0)
            try expect(deliver(57, .flagsChanged, after, time: 0.05),
                "A documented Caps key transition completes an owned backtick even without stateless HID bits")
            try expect(overviewVisible ? overviewActions == [.run] && globalActions.isEmpty
                : globalActions == [.run] && overviewActions.isEmpty,
                "Caps turning either on or off routes exactly one Run to the prefix owner")
            deliver(57, .flagsChanged, after, time: 0.06)
            deliver(50, .keyUp, after, time: 0.1)
            try expect(overviewVisible ? overviewActions == [.run] : globalActions == [.run],
                "A duplicate Caps notification and chord release cannot issue another action")
            try expect(global.expire(now: 1) == nil, "Caps compatibility Run leaves no delayed single")
            deliver(50, .keyDown, after, time: 2)
            deliver(50, .keyUp, after, time: 2.1)
            try expect(overviewVisible ? overviewActions == [.run, .close] : global.expire(now: 3) == .single,
                "The capitals state left by compatibility Run does not turn a later plain backtick into Run")
        }
    }
}

/// Exercise the production routing boundary, not just the global reducer. The
/// old monitor sent Caps to a reset global reducer after overview owned prefix.
private func runOverviewKeyboardRoutingSpecs() throws {
    typealias Delivery = (consume: Bool, overview: OverviewSearchGesture.Action?, global: QuickMarkGesture.Action?)
    func send(_ code: CGKeyCode, _ type: CGEventType, _ flags: CGEventFlags, at time: Double,
              overviewVisible: Bool = true, editing: Bool = false, repeatKey: Bool = false,
              normalizer: inout QuickMarkKeyboardNormalizer, overview: inout OverviewSearchGesture,
              global: inout QuickMarkGesture) -> Delivery? {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
        event.type = type; event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        guard let input = normalizer.normalize(type: type, event: event) else { return nil }
        var overviewAction: OverviewSearchGesture.Action?
        let result = QuickMarkKeyboardRouting.route(input, intentOwnsInput: overviewVisible,
            editingText: editing, overviewHandler: { input in
                let result = overview.key(code: input.code, down: input.down, modified: input.modified,
                    repeated: input.repeatKey, editing: editing, capsLockHeld: input.capsLockHeld)
                overviewAction = result.action
                return result.consume
            }, gesture: global)
        switch result {
        case .overview: global.reset(); return (true, overviewAction, nil)
        case .text: global.reset(); return (false, nil, nil)
        case .gesture:
            let result = global.key(input, now: time)
            return (result.consume, nil, result.action)
        }
    }

    var reentrantGesture = QuickMarkGesture()
    _ = reentrantGesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    var reentrantNormalizer = QuickMarkKeyboardNormalizer()
    let reentrantEvent = CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true)!
    let reentrantInput = reentrantNormalizer.normalize(type: .keyDown, event: reentrantEvent)!
    let reentrantRoute = QuickMarkKeyboardRouting.route(reentrantInput, intentOwnsInput: true,
        editingText: false, overviewHandler: { _ in
            // The real controller can run a modal prompt or close overview,
            // synchronously calling cancelPending on this very same owner.
            reentrantGesture.reset()
            return true
        }, gesture: reentrantGesture)
    if case .overview = reentrantRoute {
        try expect(!reentrantGesture.isHoldingPrefix,
            "Overview callbacks may cancel live gesture state without exclusivity traps or stale state writeback")
    } else { try expect(false, "A reentrant overview callback retains event ownership") }

    for capsLatched in [false, true] {
        let latch: CGEventFlags = capsLatched ? .maskAlphaShift : []
        for mask in [NX_ALPHASHIFT_STATELESS_MASK, NX_DEVICE_ALPHASHIFT_STATELESS_MASK] {
            let held = latch.union(CGEventFlags(rawValue: UInt64(mask)))
            for capsCode: CGKeyCode in [57, 255] {
                for capsFirst in [false, true] {
                    var normalizer = QuickMarkKeyboardNormalizer()
                    var overview = OverviewSearchGesture(), global = QuickMarkGesture()
                    let first = capsFirst
                        ? send(capsCode, .flagsChanged, held, at: 0, normalizer: &normalizer, overview: &overview, global: &global)
                        : send(50, .keyDown, latch, at: 0, normalizer: &normalizer, overview: &overview, global: &global)
                    try expect(first?.overview == nil && first?.global == nil, "Run waits until both physical keys are held in the overview")
                    let second = capsFirst
                        ? send(50, .keyDown, held, at: 0.1, normalizer: &normalizer, overview: &overview, global: &global)
                        : send(capsCode, .flagsChanged, held, at: 0.1, normalizer: &normalizer, overview: &overview, global: &global)
                    try expect(second?.consume == true && second?.overview == .run && second?.global == nil,
                        "Physical Caps reaches the same overview owner as its prefix, in either order and latch state")
                    let repeated = send(50, .keyDown, held, at: 0.12, repeatKey: true,
                        normalizer: &normalizer, overview: &overview, global: &global)
                    try expect(repeated?.consume == true && repeated?.overview == nil && repeated?.global == nil,
                        "Holding Run never starts a second overview or global action")
                    try expect(send(capsCode, .flagsChanged, held, at: 0.13,
                        normalizer: &normalizer, overview: &overview, global: &global) == nil,
                        "Duplicate physical Caps flags cannot trigger another route")
                    _ = send(capsCode, .flagsChanged, .maskAlphaShift, at: 0.2,
                        normalizer: &normalizer, overview: &overview, global: &global)
                    let release = send(50, .keyUp, .maskAlphaShift, at: 0.25,
                        normalizer: &normalizer, overview: &overview, global: &global)
                    try expect(release?.consume == true && release?.overview == nil && global.expire(now: 1) == nil,
                        "Run release neither closes the overview nor schedules a delayed global single")
                    _ = send(50, .keyDown, .maskAlphaShift, at: 2,
                        normalizer: &normalizer, overview: &overview, global: &global)
                    let plain = send(50, .keyUp, .maskAlphaShift, at: 2.1,
                        normalizer: &normalizer, overview: &overview, global: &global)
                    try expect(plain?.overview == .close && plain?.global == nil,
                        "The capitals latch left after Run does not become a second Run chord")
                }
            }
        }
    }

    let physicalCaps = CGEventFlags(rawValue: UInt64(NX_ALPHASHIFT_STATELESS_MASK))
    for overviewVisible in [false, true] {
        var normalizer = QuickMarkKeyboardNormalizer()
        var overview = OverviewSearchGesture(), global = QuickMarkGesture()
        _ = send(50, .keyDown, [], at: 0, overviewVisible: overviewVisible,
            normalizer: &normalizer, overview: &overview, global: &global)
        for (step, code) in [CGKeyCode(18), 19, 18].enumerated() {
            let now = Double(step) * 0.1 + 0.1
            let press = send(code, .keyDown, [], at: now, overviewVisible: overviewVisible, editing: true,
                normalizer: &normalizer, overview: &overview, global: &global)
            let index = code == 18 ? 0 : 1
            try expect(overviewVisible ? press?.overview == .modification(index) : press?.global == .modification(index),
                "An owned prefix toggles modifiers on, off and consecutively after an editor opens")
            let repeatPress = send(code, .keyDown, [], at: now + 0.01, overviewVisible: overviewVisible, editing: true, repeatKey: true,
                normalizer: &normalizer, overview: &overview, global: &global)
            try expect(repeatPress?.consume == true && repeatPress?.overview == nil && repeatPress?.global == nil,
                "An owned number only toggles once per physical press")
            try expect(send(code, .keyUp, .maskShift, at: now + 0.02, overviewVisible: overviewVisible, editing: true,
                normalizer: &normalizer, overview: &overview, global: &global)?.consume == true,
                "Number release stays owned after Shift or text focus changes")
        }
        let run = send(57, .flagsChanged, physicalCaps, at: 0.5, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(overviewVisible ? run?.overview == .run : run?.global == .run,
            "Caps completes an already-owned prefix after a modifier opened an editor")
        _ = send(57, .flagsChanged, [], at: 0.6, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        let release = send(50, .keyUp, .maskControl, at: 0.7, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(release?.consume == true && release?.overview == nil && release?.global == nil && global.expire(now: 1) == nil,
            "Owned prefix release is swallowed after editor and system-modifier changes")

        let typing = send(50, .keyDown, [], at: 2, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(typing?.consume == overviewVisible && typing?.overview == nil && typing?.global == nil,
            "Overview owns its exit prefix while editing; ordinary external editors still receive literal text")
        let capsWhileTyping = send(57, .flagsChanged, physicalCaps, at: 2.1, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(capsWhileTyping?.consume == overviewVisible
            && capsWhileTyping?.overview == (overviewVisible ? .run : nil) && capsWhileTyping?.global == nil,
            "Caps Run works from an owned overview editor prefix but cannot manufacture Run in an external text editor")

        normalizer = QuickMarkKeyboardNormalizer(); overview = OverviewSearchGesture(); global.reset()
        _ = send(50, .keyDown, [], at: 3, overviewVisible: overviewVisible,
            normalizer: &normalizer, overview: &overview, global: &global)
        _ = send(18, .keyDown, [], at: 3.1, overviewVisible: overviewVisible,
            normalizer: &normalizer, overview: &overview, global: &global)
        _ = send(50, .keyUp, [], at: 3.2, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(send(18, .keyUp, .maskShift, at: 3.3, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)?.consume == true,
            "Number release remains owned even after prefix release into a newly opened editor")
    }
}
