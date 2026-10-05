import AppKit
import ApplicationServices
import IntentCore

/// A short-lived exact-window restoration transaction. Never opens an app or
/// follows a stale session-start window. Observed input ends preservation.
final class RestorationFocusGuard {
    private static var current: RestorationFocusGuard?
    private let application: NSRunningApplication
    private let window: AXUIElement?
    private let visibleWindowID: UInt32
    private let targetResolution: String
    private let observationOnly: Bool
    // NSEvent monitors are delivered on the main queue. AX IPC can briefly
    // block that queue, so also consult public WindowServer input counters
    // before effects rather than waiting for a queued cancellation callback.
    private static let cancellingInput: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    private let initialInputCounts: [UInt32]
    private var policy: RestorationFocusPolicy
    private var timer: Timer?
    private var globalInput: Any?
    private var localInput: Any?
    private var activation: NSObjectProtocol?
    private var spaceChange: NSObjectProtocol?
    private let beganAt = Date()
    private let beganUptime = ProcessInfo.processInfo.systemUptime
    private var observations: [[String: Any]] = []
    private var lastForegroundPID: pid_t?
    private var lastFrontWindowID: UInt32?
    private var lastTargetOnScreen: Bool?
    private var lastTargetMinimized: Bool?

    private init(application: NSRunningApplication, restoringPIDs: Set<pid_t>, visibleWindow: WorkspaceWindow,
                 observationOnly: Bool) {
        self.application = application
        self.observationOnly = observationOnly
        initialInputCounts = Self.inputCounts()
        visibleWindowID = visibleWindow.id
        policy = RestorationFocusPolicy(originalPID: application.processIdentifier, restoringPIDs: restoringPIDs)
        if observationOnly {
            window = nil
            targetResolution = "native-observation-only"
        } else {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.05)
            let target = Self.accessibilityWindow(matching: visibleWindow, application: element)
            window = target.window
            targetResolution = target.method
        }
    }
    static func begin(restoringPIDs: Set<pid_t>, observationOnly: Bool = false) {
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
        let guarder = RestorationFocusGuard(application: app, restoringPIDs: permittedPIDs,
                                            visibleWindow: visible, observationOnly: observationOnly)
        // Match WindowServer's actual visible window for both keyboard and
        // menu completion, rather than relying on remembered AX focus alone.
        guarder.observe("begin", details: ["controllerPID": controllerPID, "targetPID": targetPID,
            "fromControls": fromControls, "matchedWindow": guarder.window != nil,
            "visibleWindowID": visible.id, "resolution": guarder.targetResolution, "observationOnly": observationOnly])
        if !observationOnly && guarder.window == nil { guarder.observe("unresolvedVisibleWindow"); return }
        current = guarder
        let input: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            .gesture, .beginGesture, .swipe, .magnify, .rotate, .smartMagnify]
        guarder.globalInput = NSEvent.addGlobalMonitorForEvents(matching: input) { [weak guarder] _ in
            guard let guarder, current === guarder else { return }
            cancel(reason: "globalInput")
        }
        guarder.localInput = NSEvent.addLocalMonitorForEvents(matching: input) { [weak guarder] event in
            if let guarder, current === guarder { cancel(reason: "localInput") }
            return event
        }
        guarder.activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak guarder] _ in
            guarder?.preserve()
        }
        // The notification cannot distinguish a user Space gesture from a
        // programmatic restore. Never chase the old target across Spaces.
        // Quiet restoration must prevent the transition at its owning layer.
        guarder.spaceChange = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak guarder] _ in
            guard let guarder, current === guarder else { return }
            cancel(reason: "spaceChanged")
        }
        // Window deminiaturization and Browser Guard tab restoration finish
        // asynchronously after the native session loop has already stopped.
        let deadline = guarder.beganUptime + 5
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak guarder] _ in
            guard let guarder, current === guarder else { return }
            // Uptime may pause during sleep. The wall-time fence additionally
            // prevents an old transaction from replaying after waking.
            if ProcessInfo.processInfo.systemUptime >= deadline || Date().timeIntervalSince(guarder.beganAt) >= 5 {
                cancel(reason: "complete"); return
            }
            guarder.preserve()
        }
        guarder.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    static func preserveCurrent() { current?.preserve() }
    static func preserveAfterOwnedVisibilityChange() {
        precondition(Thread.isMainThread)
        current?.preserveOwnedVisibilityChange()
    }

    private static func inputCounts() -> [UInt32] {
        cancellingInput.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
    }
    private func inputCancelled() -> Bool {
        guard Self.current === self else { return true }
        if RestorationFocusPolicy.inputChanged(initial: initialInputCounts, current: Self.inputCounts()) {
            Self.cancel(reason: "inputCountChanged")
            return true
        }
        return false
    }

    private func preserveOwnedVisibilityChange() {
        guard !observationOnly, let window else { return }
        func nativePermission() -> (permitted: Bool, wasFront: Bool) {
            guard !inputCancelled(), ProcessInfo.processInfo.systemUptime - beganUptime <= 5,
                  Date().timeIntervalSince(beganAt) <= 5,
                  !application.isTerminated, !application.isHidden else { return (false, false) }
            let exists = WorkspaceWindow.exists(id: visibleWindowID, pid: application.processIdentifier)
            let windows = WorkspaceWindow.list()
            let visible = windows.contains { $0.id == visibleWindowID && $0.pid == application.processIdentifier }
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let permitted = policy.shouldPreserveOwnedVisibilityChange(targetExists: exists, targetOnScreen: visible,
                frontmostPID: foreground)
            let wasFront = foreground == application.processIdentifier
                && windows.first(where: { $0.pid == application.processIdentifier })?.id == visibleWindowID
            return (permitted && !inputCancelled(), wasFront)
        }
        let before = nativePermission()
        guard before.permitted else { return }
        // AXMinimized=false may enqueue an asynchronous deminiaturization that
        // raises its window. Queue the already-bound work window behind that
        // operation immediately. Waiting for AXMinimized/AXFocusedWindow reads
        // first left Chrome displaced for a second while those reads timed out.
        // Never guess a window, deminiaturize it or launch an app. Fresh native
        // checks narrow (but cannot eliminate) cross-process timing races.
        let mainStatus = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let beforeRaise = nativePermission()
        guard beforeRaise.permitted else {
            observe("ownedRestorePreservationCancelled", details: ["mainStatus": mainStatus.rawValue,
                "targetWasFront": before.wasFront])
            return
        }
        // cannotComplete means dispatch may still be pending, not that a second
        // independent AX action must be suppressed. The bounded timer remains
        // a fallback, and input/new-session/Space cancellation still owns it.
        let raiseStatus = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        observe("ownedRestorePreservation", details: ["mainStatus": mainStatus.rawValue, "raiseStatus": raiseStatus.rawValue,
            "targetWasFront": before.wasFront, "targetWasFrontBeforeRaise": beforeRaise.wasFront])
    }
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
            guard AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &title) == .success,
                  let title = title as? String else { return false }
            // Chrome's AX title includes its browser/profile suffix while the
            // WindowServer title contains only the page. Identity still requires
            // the same PID and exact frame, plus hit-testing or a unique match.
            return title == visible.title || BrowserWindowMatching.sameWindowTitle(title, visible.title)
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
        if let observer = guarder.spaceChange { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func preserve() {
        guard !inputCancelled() else { return }
        guard !application.isTerminated, !application.isHidden else { Self.cancel(reason: "targetUnavailable"); return }
        switch WorkspaceWindow.exists(id: visibleWindowID, pid: application.processIdentifier) {
        case false?: Self.cancel(reason: "windowClosed"); return
        case nil: observe("windowInventoryDeferred"); return
        case true?: break
        }
        let onScreenWindows = WorkspaceWindow.list()
        let frontWindow = onScreenWindows.first
        if lastFrontWindowID != frontWindow?.id {
            lastFrontWindowID = frontWindow?.id
            // PID alone misses a different Firefox/Chrome window coming
            // forward. Observe the separately queried onscreen native order;
            // never derive z-order by filtering an all-window inventory.
            observe("frontWindow", details: ["windowID": frontWindow?.id ?? 0,
                "pid": frontWindow?.pid ?? 0,
                "targetIsFront": frontWindow?.id == visibleWindowID
                    && frontWindow?.pid == application.processIdentifier])
        }
        let onScreen = onScreenWindows.contains {
            $0.id == visibleWindowID && $0.pid == application.processIdentifier
        }
        if lastTargetOnScreen != onScreen {
            lastTargetOnScreen = onScreen
            observe("windowVisibility", details: ["exists": true, "onScreen": onScreen])
        }
        // AppKit can briefly report no foreground application between activation
        // notifications; that is not evidence the user moved to another app.
        guard let foreground = NSWorkspace.shared.frontmostApplication else { return }
        if lastForegroundPID != foreground.processIdentifier {
            lastForegroundPID = foreground.processIdentifier
            observe("foreground", details: ["pid": foreground.processIdentifier])
        }
        // Quiet completion does not dispatch an effect to correct focus later.
        // This finite observer is diagnostic only, with no AX calls, activation
        // or window raising; exact-window acceptance is independently sampled.
        if observationOnly { return }
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
            if status == .success, let isMinimized = minimized as? Bool, lastTargetMinimized != isMinimized {
                lastTargetMinimized = isMinimized
                observe("windowMinimized", details: ["minimized": isMinimized])
            }
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
                guard !inputCancelled() else { return }
                observe("preserveWindow")
                if AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .cannotComplete { return }
                guard !inputCancelled() else { return }
                guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return }
            }
        }
        if !application.isActive, !inputCancelled() { application.activate(options: []) }
    }
}
