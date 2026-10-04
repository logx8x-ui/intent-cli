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
    private let expiryTimer = QuickMarkExpiryTimer()
    private var gesture = QuickMarkGesture()
    private var normalizer = QuickMarkKeyboardNormalizer()
    private var generation = UUID()
    func cancelPending() {
        gesture.reset()
        expiryTimer.cancel()
        generation = UUID()
    }
    private func refreshExpiryTimer() {
        let generation = generation
        expiryTimer.schedule(deadline: gesture.pendingSingleDeadline) { [weak self] in
            guard let self, self.generation == generation else { return }
            if self.editingText && !self.gesture.isHoldingPrefix { self.cancelPending(); return }
            let action = self.gesture.expire(now: ProcessInfo.processInfo.systemUptime)
            self.refreshExpiryTimer()
            if let action { self.onAction?(action) }
        }
    }
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
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<QuickMarkKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
            defer { owner.refreshExpiryTimer() }
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
            guard let input = owner.normalizer.normalize(type: type, event: event) else {
                return Unmanaged.passUnretained(event)
            }
            if type == .flagsChanged {
                guard !owner.editingText else { owner.cancelPending(); return Unmanaged.passUnretained(event) }
                let result = owner.gesture.key(input, now: ProcessInfo.processInfo.systemUptime)
                if let action = result.action {
                    let generation = owner.generation
                    DispatchQueue.main.async { [weak owner] in
                        guard let owner, owner.generation == generation else { return }
                        owner.onAction?(action)
                    }
                }
                return result.consume ? nil : Unmanaged.passUnretained(event)
            }
            let opening = input.opensSpotlight
            if let context = owner.spotlightContext?() { owner.spotlight.setOverview(active: context.0, candidates: context.1) }
            if opening && type == .keyDown { owner.cancelPending(); owner.onSpotlightOpening?() }
            let intentOwnsInput = NSApp.isActive
            // Escape is urgent even if Spotlight owns focus. Search text and
            // Return must reach the Spotlight route before overview shortcuts.
            if code == 53, owner.overviewKeyHandler?(code, input.down,
                input.modified, input.repeatKey) == true {
                owner.cancelPending()
                return intentOwnsInput ? nil : Unmanaged.passUnretained(event)
            }
            if let consume = owner.spotlight.handle(code: code, down: input.down,
                modified: input.modified,
                openingShortcut: opening,
                repeatKey: input.repeatKey) {
                owner.cancelPending()
                return consume ? nil : Unmanaged.passUnretained(event)
            }
            if intentOwnsInput, owner.overviewKeyHandler?(code, input.down,
                input.modified, input.repeatKey) == true {
                owner.cancelPending(); return nil
            }
            // Preserve Intent's text editors and marked IME composition. The
            // physical-key gesture is only active outside those text contexts.
            if owner.editingText && !owner.gesture.isHoldingPrefix { owner.cancelPending(); return Unmanaged.passUnretained(event) }
            let result = owner.gesture.key(input, now: ProcessInfo.processInfo.systemUptime)
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
        return true
    }
    deinit {
        expiryTimer.cancel()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
