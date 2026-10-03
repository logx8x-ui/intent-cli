import AppKit
import ApplicationServices
import IntentCore

/// A short-lived restoration transaction. Never opens an app, changes Spaces,
/// or follows a stale session-start window. Real input ends preservation.
final class RestorationFocusGuard {
    private static var current: RestorationFocusGuard?
    private let application: NSRunningApplication
    private let window: AXUIElement?
    private let visibleWindowID: UInt32
    private let targetResolution: String
    private var policy: RestorationFocusPolicy
    private var timer: Timer?
    private var globalInput: Any?
    private var localInput: Any?
    private var activation: NSObjectProtocol?
    private let beganAt = Date()
    private var observations: [[String: Any]] = []
    private var lastForegroundPID: pid_t?

    private init(application: NSRunningApplication, restoringPIDs: Set<pid_t>, visibleWindow: WorkspaceWindow) {
        self.application = application
        visibleWindowID = visibleWindow.id
        policy = RestorationFocusPolicy(originalPID: application.processIdentifier, restoringPIDs: restoringPIDs)
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.05)
        let target = Self.accessibilityWindow(matching: visibleWindow, application: element)
        window = target.window
        targetResolution = target.method
    }
    static func begin(restoringPIDs: Set<pid_t>) {
        precondition(Thread.isMainThread)
        cancel()
        let controllerPID = ProcessInfo.processInfo.processIdentifier
        let foreground = NSWorkspace.shared.frontmostApplication
        let fromControls = foreground?.processIdentifier == controllerPID
        guard let visible = WorkspaceWindow.list().first(where: {
            fromControls ? $0.pid != controllerPID : $0.pid == foreground?.processIdentifier
        }) else { return }
        guard let targetPID = RestorationFocusPolicy.targetPID(frontmostPID: foreground?.processIdentifier,
            controllerPID: controllerPID, visiblePID: visible.pid),
              let app = NSRunningApplication(processIdentifier: targetPID) else { return }
        // The Finish menu may still own activation until the controls close.
        // It is part of this restoration, not a new destination chosen by the user.
        let permittedPIDs = fromControls ? restoringPIDs.union([controllerPID]) : restoringPIDs
        let guarder = RestorationFocusGuard(application: app, restoringPIDs: permittedPIDs, visibleWindow: visible)
        // Match WindowServer's actual visible window for both keyboard and
        // menu completion, rather than relying on remembered AX focus alone.
        guarder.observe("begin", details: ["controllerPID": controllerPID, "targetPID": targetPID,
            "fromControls": fromControls, "matchedWindow": guarder.window != nil,
            "visibleWindowID": visible.id, "resolution": guarder.targetResolution])
        if guarder.window == nil { guarder.observe("unresolvedVisibleWindow"); return }
        current = guarder
        let input: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        guarder.globalInput = NSEvent.addGlobalMonitorForEvents(matching: input) { _ in cancel(reason: "globalInput") }
        guarder.localInput = NSEvent.addLocalMonitorForEvents(matching: input) { event in cancel(reason: "localInput"); return event }
        guarder.activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak guarder] _ in
            guarder?.preserve()
        }
        // Window deminiaturization and Browser Guard tab restoration finish
        // asynchronously after the native session loop has already stopped.
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak guarder] _ in
            guard let guarder else { return }
            if Date() >= deadline { cancel(reason: "complete"); return }
            guarder.preserve()
        }
        guarder.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    static func preserveCurrent() { current?.preserve() }
    private static func accessibilityWindow(matching visible: WorkspaceWindow, application: AXUIElement) -> (window: AXUIElement?, method: String) {
        let deadline = Date().addingTimeInterval(0.12)
        func stillFront() -> Bool {
            WorkspaceWindow.list().first(where: { $0.pid == visible.pid })?.id == visible.id
        }
        func matchesVisible(_ candidate: AXUIElement) -> Bool {
            guard Date() < deadline else { return false }
            var pid: pid_t = 0
            guard AXUIElementGetPid(candidate, &pid) == .success, pid == visible.pid else { return false }
            AXUIElementSetMessagingTimeout(candidate, 0.02)
            var position: CFTypeRef?, size: CFTypeRef?, title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(candidate, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
                  abs(point.x - visible.frame.minX) < 3, abs(point.y - visible.frame.minY) < 3,
                  abs(dimensions.width - visible.frame.width) < 3, abs(dimensions.height - visible.frame.height) < 3 else { return false }
            guard !visible.title.isEmpty else { return true }
            return AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &title) == .success
                && title as? String == visible.title
        }
        // Two browser windows can share both title and geometry. A hit on the
        // actual exposed window gives its AX identity without guessing between
        // duplicate windows or using a private WindowServer-ID API.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        for offset in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.3)] {
            guard Date() < deadline else { return (nil, "deadline") }
            var hit: AXUIElement?
            let x = visible.frame.minX + visible.frame.width * offset.x
            let y = visible.frame.minY + visible.frame.height * offset.y
            guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit) == .success, let hit else { continue }
            AXUIElementSetMessagingTimeout(hit, 0.02)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(value, to: AXUIElement.self)
                if matchesVisible(window), Date() < deadline, stillFront() { return (window, "visibleHit") }
            }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == kAXWindowRole, matchesVisible(hit), Date() < deadline, stillFront() {
                return (hit, "visibleHit")
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.count <= 32 else { return (nil, "unavailable") }
        let matches = windows.filter(matchesVisible)
        return Date() < deadline && matches.count == 1 && stillFront()
            ? (matches[0], "uniqueMatch") : (nil, "unresolvedMatches-\(matches.count)")
    }
    private func observe(_ event: String, details: [String: Any] = [:]) {
        // Counts and transient IDs only: no window titles, URLs or user content.
        guard observations.count < 80 else { return }
        var item = details
        item["event"] = event; item["elapsed"] = Date().timeIntervalSince(beganAt)
        observations.append(item)
        let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("restoration-focus-diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["startedAt": beganAt.timeIntervalSince1970, "events": observations]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    static func cancel(reason: String = "cancelled") {
        guard let guarder = current else { return }
        current = nil
        guarder.observe(reason)
        guarder.policy.userInteracted()
        guarder.timer?.invalidate()
        if let monitor = guarder.globalInput { NSEvent.removeMonitor(monitor) }
        if let monitor = guarder.localInput { NSEvent.removeMonitor(monitor) }
        if let observer = guarder.activation { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func preserve() {
        guard !application.isTerminated, !application.isHidden else { Self.cancel(reason: "targetUnavailable"); return }
        if !WorkspaceWindow.list().contains(where: { $0.id == visibleWindowID }) {
            Self.cancel(reason: "windowUnavailable"); return
        }
        // AppKit can briefly report no foreground application between activation
        // notifications; that is not evidence the user moved to another app.
        guard let foreground = NSWorkspace.shared.frontmostApplication else { return }
        if lastForegroundPID != foreground.processIdentifier {
            lastForegroundPID = foreground.processIdentifier
            observe("foreground", details: ["pid": foreground.processIdentifier])
        }
        guard policy.shouldPreserve(frontmostPID: foreground.processIdentifier) else { Self.cancel(reason: "unrelatedActivation"); return }
        // Restore only the existing focused window. No launch, unhide, or
        // activateAllWindows: those would bring unrelated windows forward.
        if let window {
            var minimized: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            // Firefox can briefly stop answering AX while its tabs/windows
            // return. A timeout is not evidence that the target closed; retry
            // on the bounded timer without activating a guessed replacement.
            if status == .cannotComplete { observe("windowProbeDeferred"); return }
            guard status == .success, minimized as? Bool != true else {
                observe("windowState", details: ["AXStatus": status.rawValue, "minimized": minimized as? Bool ?? false])
                Self.cancel(reason: "windowClosedOrMinimized"); return
            }
            var focused: CFTypeRef?
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.05)
            let focusStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
            guard focusStatus == .success else { observe("focusProbeDeferred"); return }
            if !application.isActive || focused.map({ !CFEqual($0, window) }) != false {
                observe("preserveWindow")
                if AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .cannotComplete { return }
                guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return }
            }
        }
        if !application.isActive { application.activate(options: []) }
    }
}
