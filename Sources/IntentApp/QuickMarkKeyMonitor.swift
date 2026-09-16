import AppKit
import IntentCore

/// Tiny input callback: no AX queries, disk IO or window capture in the tap.
final class QuickMarkKeyMonitor {
    var onAction: ((QuickMarkGesture.Action) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var gesture = QuickMarkGesture()
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<QuickMarkKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.gesture.reset()
                // Callback is bounded; recover once on the next main-loop turn.
                DispatchQueue.main.async { [weak owner] in if let tap = owner?.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let result = owner.gesture.key(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown,
                modified: !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
                repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, now: ProcessInfo.processInfo.systemUptime)
            if let action = result.action { DispatchQueue.main.async { [weak owner] in owner?.onAction?(action) } }
            return result.consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self, let action = self.gesture.expire(now: ProcessInfo.processInfo.systemUptime) else { return }
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
