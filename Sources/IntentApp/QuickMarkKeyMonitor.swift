import AppKit
import IntentCore

/// Tiny input callback: no AX queries, disk IO or window capture in the tap.
final class QuickMarkKeyMonitor {
    var onAction: ((QuickMarkGesture.Action) -> Void)?
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
            // Preserve Intent's text editors and marked IME composition. The
            // physical-key gesture is only active outside those text contexts.
            if owner.editingText { owner.cancelPending(); return Unmanaged.passUnretained(event) }
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
            if self.editingText { self.cancelPending(); return }
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
