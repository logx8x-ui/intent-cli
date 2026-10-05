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
    try runOverviewKeyboardRoutingSpecs()
    print("Native keyboard normalization and routing regressions passed (overview and staged selection, physical Caps, both key orders, keycodes 57/255)")
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
        try expect(typing?.consume == false && typing?.overview == nil && typing?.global == nil,
            "A fresh prefix inside an editor stays text instead of silently starting shortcut state")
        let capsWhileTyping = send(57, .flagsChanged, physicalCaps, at: 2.1, overviewVisible: overviewVisible, editing: true,
            normalizer: &normalizer, overview: &overview, global: &global)
        try expect(capsWhileTyping?.consume == false && capsWhileTyping?.overview == nil && capsWhileTyping?.global == nil,
            "Caps typed in a text editor cannot manufacture Run from an unowned prefix")

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
