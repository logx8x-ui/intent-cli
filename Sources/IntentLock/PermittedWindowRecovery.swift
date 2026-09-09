import AppKit
import ApplicationServices
import IntentCore

/// Keeps an AX reference to the actual last permitted window, not just its owning app.
final class PermittedWindowRecovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "intent.permitted-window-recovery", qos: .userInteractive)
    private let mutex = NSLock()
    private var window: AXUIElement?
    private var pid: pid_t = 0
    private var lastSample = Date.distantPast
    private var lastRestore = Date.distantPast
    private var stopped = false
    // Worker-queue diagnostics contain counts only, never window/app contents.
    private var spaceChanges = 0
    private var restoreRequests = 0
    private var verifiedReturns = 0
    private var awaitingVerification = false

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

    func remember(_ application: NSRunningApplication) {
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
            self.mutex.lock()
            guard !self.stopped else { self.mutex.unlock(); return }
            let verified = self.awaitingVerification && self.pid == processID && self.window.map { CFEqual($0, window) } == true
            self.window = window; self.pid = processID
            self.mutex.unlock()
            if verified {
                self.awaitingVerification = false; self.verifiedReturns += 1; self.publishDiagnostics()
            }
        }
    }

    @discardableResult func restore() -> Bool {
        mutex.lock()
        guard !stopped, let window else { mutex.unlock(); return false }
        let processID = pid
        guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else {
            self.window = nil; mutex.unlock(); return false
        }
        guard Date().timeIntervalSince(lastRestore) >= 0.12 else { mutex.unlock(); return true }
        lastRestore = Date(); mutex.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let stopped = self.stopped; self.mutex.unlock()
            guard !stopped, let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else { return }
            self.restoreRequests += 1
            AXUIElementSetMessagingTimeout(window, 0.02)
            // Selecting/raising the remembered window also handles a different full-screen
            // Space belonging to an app macOS still reports as already active.
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            self.awaitingVerification = raised == .success
            if raised == .invalidUIElement {
                self.mutex.lock(); self.window = nil; self.mutex.unlock()
            }
            app.activate(options: [.activateIgnoringOtherApps])
            self.publishDiagnostics()
        }
        return true
    }

    func stop() {
        mutex.lock(); stopped = true; window = nil; mutex.unlock()
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
