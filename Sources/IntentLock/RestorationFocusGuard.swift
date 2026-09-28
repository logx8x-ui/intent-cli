import AppKit
import ApplicationServices
import IntentCore

/// A short-lived restoration transaction. Never opens an app, changes Spaces,
/// or follows a stale session-start window. Real input ends preservation.
final class RestorationFocusGuard {
    private static var current: RestorationFocusGuard?
    private let application: NSRunningApplication
    private let window: AXUIElement?
    private var policy: RestorationFocusPolicy
    private var timer: Timer?
    private var globalInput: Any?
    private var localInput: Any?
    private var activation: NSObjectProtocol?

    private init(application: NSRunningApplication, restoringPIDs: Set<pid_t>) {
        self.application = application
        policy = RestorationFocusPolicy(originalPID: application.processIdentifier, restoringPIDs: restoringPIDs)
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.05)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            window = (focused as! AXUIElement)
            AXUIElementSetMessagingTimeout(window!, 0.05)
        } else { window = nil }
    }
    static func begin(restoringPIDs: Set<pid_t>) {
        precondition(Thread.isMainThread)
        cancel()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let guarder = RestorationFocusGuard(application: app, restoringPIDs: restoringPIDs)
        current = guarder
        let input: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        guarder.globalInput = NSEvent.addGlobalMonitorForEvents(matching: input) { _ in cancel() }
        guarder.localInput = NSEvent.addLocalMonitorForEvents(matching: input) { event in cancel(); return event }
        guarder.activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak guarder] _ in
            guarder?.preserve()
        }
        // Window deminiaturization and Browser Guard tab restoration finish
        // asynchronously after the native session loop has already stopped.
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak guarder] _ in
            guard let guarder else { return }
            if Date() >= deadline { cancel(); return }
            guarder.preserve()
        }
        guarder.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    static func preserveCurrent() { current?.preserve() }
    static func cancel() {
        guard let guarder = current else { return }
        current = nil
        guarder.policy.userInteracted()
        guarder.timer?.invalidate()
        if let monitor = guarder.globalInput { NSEvent.removeMonitor(monitor) }
        if let monitor = guarder.localInput { NSEvent.removeMonitor(monitor) }
        if let observer = guarder.activation { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func preserve() {
        guard !application.isTerminated, !application.isHidden else { Self.cancel(); return }
        // AppKit can briefly report no foreground application between activation
        // notifications; that is not evidence the user moved to another app.
        guard let foreground = NSWorkspace.shared.frontmostApplication else { return }
        guard policy.shouldPreserve(frontmostPID: foreground.processIdentifier) else { Self.cancel(); return }
        // Restore only the existing focused window. No launch, unhide, or
        // activateAllWindows: those would bring unrelated windows forward.
        if let window {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  minimized as? Bool != true else { Self.cancel(); return }
            var focused: CFTypeRef?
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.05)
            _ = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
            if !application.isActive || focused.map({ !CFEqual($0, window) }) != false {
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        if !application.isActive { application.activate(options: []) }
    }
}
