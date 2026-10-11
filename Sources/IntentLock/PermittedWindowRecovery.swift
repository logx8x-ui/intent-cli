import AppKit
import ApplicationServices
import IntentCore

/// Maps one native lifetime to one live AX object in both directions. Titles or
/// geometry alone cannot authorize an ambiguous sibling or a reused process.
struct PermittedWindowBinding: @unchecked Sendable {
    let identity: PermittedWindowRecoveryPolicy.Identity
    let element: AXUIElement

    static func identity(window: WorkspaceWindow, app: NSRunningApplication) -> PermittedWindowRecoveryPolicy.Identity? {
        guard !app.isTerminated, app.processIdentifier == window.pid, app.bundleIdentifier == window.bundle,
              let launched = app.launchDate else { return nil }
        return .init(bundleIdentifier: window.bundle, pid: window.pid,
                     launched: launched.timeIntervalSinceReferenceDate, windowID: window.id)
    }

    static func resolve(_ identity: PermittedWindowRecoveryPolicy.Identity,
                        requiring required: AXUIElement? = nil) -> Self? {
        guard identity.isValid, let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.bundleIdentifier == identity.bundleIdentifier,
              app.launchDate?.timeIntervalSinceReferenceDate == identity.launched else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.02)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let native = WorkspaceWindow.list(onScreen: false).filter { $0.pid == identity.pid && $0.bundle == identity.bundleIdentifier }.map {
            PermittedWindowRecoveryPolicy.Window(identity: .init(bundleIdentifier: $0.bundle, pid: $0.pid,
                launched: identity.launched, windowID: $0.id), title: $0.title, frame: $0.frame)
        }
        guard native.contains(where: { $0.identity == identity }),
              let windows = PublicAccessibilityWindowInventory.read(pid: identity.pid, deadline: deadline) else { return nil }
        var candidates: [AXUIElement] = []
        for element in windows {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == identity.pid,
                  let title = attribute(element, kAXTitleAttribute) as? String,
                  let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
            if PermittedWindowRecoveryPolicy.uniquelyMatches(expected: identity, title: title,
                frame: CGRect(origin: point, size: dimensions), native: native) { candidates.append(element) }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, candidates.count == 1,
              required.map({ CFEqual($0, candidates[0]) }) ?? true,
              !app.isTerminated, app.launchDate?.timeIntervalSinceReferenceDate == identity.launched else { return nil }
        return .init(identity: identity, element: candidates[0])
    }

    func isLive() -> Bool { Self.resolve(identity, requiring: element) != nil }
    func isMainWindow() -> Bool {
        let app = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(app, 0.02)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success
            && value.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } == true
    }
}

/// Keeps an AX reference to the actual last permitted window, not just its owning app.
final class PermittedWindowRecovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "intent.permitted-window-recovery", qos: .userInteractive)
    private let mutex = NSRecursiveLock()
    private let actions: DeferredSessionActionGate
    private let spec: FocusSessionSpec
    private var binding: PermittedWindowBinding?
    private var lastSample = Date.distantPast
    private var lastRestore = Date.distantPast
    private var stopped = false
    // Worker-queue diagnostics contain counts only, never window/app contents.
    private var spaceChanges = 0
    private var restoreRequests = 0
    private var verifiedReturns = 0
    private var awaitingVerification = false

    init(spec: FocusSessionSpec) { self.spec = spec; actions = DeferredSessionActionGate(lock: mutex) }

    func noteSpaceChange() {
        queue.async { [weak self] in
            guard let self else { return }
            self.spaceChanges += 1; self.publishDiagnostics()
        }
    }

    private func publishDiagnostics() {
        let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("space-recovery-diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["spaceChanges": spaceChanges, "restoreRequests": restoreRequests, "verifiedReturns": verifiedReturns]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func remember(_ application: NSRunningApplication, verifiedWindow: WorkspaceWindow?) {
        guard let verifiedWindow, let expected = PermittedWindowBinding.identity(window: verifiedWindow, app: application),
              spec.permitsWindow(expected.windowID, bundleIdentifier: expected.bundleIdentifier) else { return }
        let processID = application.processIdentifier
        mutex.lock()
        guard !stopped, Date().timeIntervalSince(lastSample) >= 0.15 else { mutex.unlock(); return }
        lastSample = Date(); mutex.unlock()
        queue.async { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                  Self.visibleApplication()?.processIdentifier == processID else { return }
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 0.02)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            let window = unsafeBitCast(value, to: AXUIElement.self)
            guard let sampled = PermittedWindowBinding.resolve(expected, requiring: window),
                  PermittedWindowRecoveryPolicy.accepts(expected: expected, sampled: sampled.identity,
                    permitted: self.spec.permitsWindow(sampled.identity.windowID, bundleIdentifier: sampled.identity.bundleIdentifier)) else { return }
            self.mutex.lock()
            guard !self.stopped else { self.mutex.unlock(); return }
            let verified = self.awaitingVerification && self.binding?.identity == expected
                && self.binding.map { CFEqual($0.element, window) } == true
            self.binding = sampled
            self.mutex.unlock()
            if verified {
                self.awaitingVerification = false; self.verifiedReturns += 1; self.publishDiagnostics()
            }
        }
    }

    @discardableResult func restore() -> Bool {
        mutex.lock()
        guard !stopped, let binding else { mutex.unlock(); return false }
        let identity = binding.identity
        guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.bundleIdentifier == identity.bundleIdentifier,
              app.launchDate?.timeIntervalSinceReferenceDate == identity.launched,
              spec.permitsWindow(identity.windowID, bundleIdentifier: identity.bundleIdentifier) else {
            self.binding = nil; mutex.unlock(); return false
        }
        guard Date().timeIntervalSince(lastRestore) >= 0.12 else { mutex.unlock(); return true }
        let token = actions.token
        lastRestore = Date(); mutex.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let stopped = self.stopped; self.mutex.unlock()
            guard !stopped else { return }
            self.restoreRequests += 1
            let outcome = PermittedWindowRecoveryPolicy.restore(perform: { self.actions.perform(ifCurrent: token, $0) },
                validate: {
                    !self.stopped && self.binding?.identity == identity
                        && self.spec.permitsWindow(identity.windowID, bundleIdentifier: identity.bundleIdentifier) && binding.isLive()
                }, setMain: { AXUIElementSetAttributeValue(binding.element, kAXMainAttribute as CFString, kCFBooleanTrue) },
                raise: { AXUIElementPerformAction(binding.element, kAXRaiseAction as CFString) == .success },
                activationTargetCurrent: { binding.isMainWindow() },
                activate: { app.activate(options: [.activateIgnoringOtherApps]) })
            self.awaitingVerification = outcome == .restored
            if outcome == .unavailable || outcome == .raiseFailed {
                self.mutex.lock()
                if self.binding?.identity == identity { self.binding = nil }
                self.mutex.unlock()
            }
            self.publishDiagnostics()
        }
        return true
    }

    func stop() {
        mutex.lock(); stopped = true; binding = nil; actions.invalidate(); mutex.unlock()
    }

    static func visibleApplication() -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.width > 140, bounds.height > 140,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
            return app
        }
        return nil
    }
}
