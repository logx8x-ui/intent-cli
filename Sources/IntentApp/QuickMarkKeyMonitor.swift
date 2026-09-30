import AppKit
import IntentCore

/// Tiny input callback: no AX queries, disk IO or window capture in the tap.
final class QuickMarkKeyMonitor {
    var overviewKeyHandler: ((Int, Bool, Bool, Bool) -> Bool)?
    var spotlightContext: (() -> (Bool, [SpotlightApplicationCandidate]))?
    var onSpotlightOpening: (() -> Void)?
    var onAction: ((QuickMarkGesture.Action) -> Void)?
    let spotlight = SpotlightSelectionMonitor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var gesture = QuickMarkGesture()
    private var generation = UUID()
    func cancelPending() { gesture.reset(); generation = UUID() }
    private var editingText: Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow,
              window.isVisible, window.isKeyWindow, !window.isMiniaturized,
              window.alphaValue > 0, let responder = window.firstResponder else { return false }
        // An ordered-out dashboard may retain its last field editor. Only an
        // editor still attached to the visible key surface can own this input.
        if let view = responder as? NSView,
           view.window !== window || view.isHiddenOrHasHiddenAncestor { return false }
        if let editor = responder as? NSTextView { return editor.isEditable || editor.hasMarkedText() }
        return (responder as? NSTextInputClient)?.hasMarkedText() == true
    }
    func start() -> Bool {
        if tap != nil { return true }
        spotlight.start()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<QuickMarkKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.cancelPending()
                // Callback is bounded; recover once on the next main-loop turn.
                DispatchQueue.main.async { [weak owner] in if let tap = owner?.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if event.getIntegerValueField(.eventSourceUserData) == NativeSpotlightKeyboard.dismissalTag {
                return Unmanaged.passUnretained(event)
            }
            let opening = code == 49 && event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
            if let context = owner.spotlightContext?() { owner.spotlight.setOverview(active: context.0, candidates: context.1) }
            if opening && type == .keyDown { owner.cancelPending(); owner.onSpotlightOpening?() }
            let intentOwnsInput = NSApp.isActive
            // Escape is urgent even if Spotlight owns focus. Search text and
            // Return must reach the Spotlight route before overview shortcuts.
            if code == 53, owner.overviewKeyHandler?(code, type == .keyDown,
                !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
                event.getIntegerValueField(.keyboardEventAutorepeat) != 0) == true {
                owner.cancelPending()
                return intentOwnsInput ? nil : Unmanaged.passUnretained(event)
            }
            if let consume = owner.spotlight.handle(code: code, down: type == .keyDown,
                modified: !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
                openingShortcut: opening,
                repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
                owner.cancelPending()
                return consume ? nil : Unmanaged.passUnretained(event)
            }
            if intentOwnsInput, owner.overviewKeyHandler?(code, type == .keyDown,
                !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
                event.getIntegerValueField(.keyboardEventAutorepeat) != 0) == true {
                owner.cancelPending(); return nil
            }
            // Preserve Intent's text editors and marked IME composition. The
            // physical-key gesture is only active outside those text contexts.
            if owner.editingText && !owner.gesture.isHoldingPrefix { owner.cancelPending(); return Unmanaged.passUnretained(event) }
            let result = owner.gesture.key(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown,
                modified: !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
                repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, now: ProcessInfo.processInfo.systemUptime)
            if let action = result.action {
                let generation = owner.generation
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.generation == generation else { return }
                    owner.onAction?(action)
                }
            }
            return result.consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.editingText && !self.gesture.isHoldingPrefix { self.cancelPending(); return }
            guard let action = self.gesture.expire(now: ProcessInfo.processInfo.systemUptime) else { return }
            self.onAction?(action)
        }
        RunLoop.main.add(timer!, forMode: .common)
        return true
    }
    deinit {
        timer?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
