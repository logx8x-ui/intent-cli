import AppKit
import ApplicationServices
import IntentCore

/// Owns only reversible visibility changes. Never closes a process or window.
public final class FocusVisibilityController: @unchecked Sendable {
    private struct Entry: Codable {
        var pid: pid_t
        var launched: Date
        var bundle: String
        var window: UInt32? // nil means this controller hid the whole app
    }
    private static let file = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("hidden-workspace.json")
    // Main-thread generation prevents a recovery retry from touching a newer session.
    private static var recoveryGeneration = 0
    private let spec: FocusSessionSpec
    // AppKit visibility requests must run on the application main thread.
    // A background unhide can fail even after hide succeeded.
    private let queue = DispatchQueue.main
    private var timer: DispatchSourceTimer?
    private var entries: [Entry] = []
    private var stopped = false
    public init(spec: FocusSessionSpec) { self.spec = spec }

    public func start() {
        guard spec.hideDistractions && spec.requiresEnforcement else { return }
        onMain {
            guard !stopped, timer == nil else { return }
            Self.recoveryGeneration &+= 1
            entries = Self.restore()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop() {
        onMain {
            stopped = true
            guard timer != nil else { return }
            timer?.cancel(); timer = nil
            entries = Self.beginRecovery()
        }
    }
    public static func restoreInterruptedSession() {
        if Thread.isMainThread { _ = beginRecovery() }
        else { DispatchQueue.main.sync { _ = beginRecovery() } }
    }
    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }

    @discardableResult private static func beginRecovery() -> [Entry] {
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let pending = restore()
        if !pending.isEmpty { retryRecovery(generation: generation, attempts: 4) }
        return pending
    }
    private static func retryRecovery(generation: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard generation == recoveryGeneration else { return }
            // unhide() may report false while the visibility request is still in flight.
            // Re-read macOS state before discarding ownership, or retry if it really failed.
            let pending = restore()
            if !pending.isEmpty && attempts > 1 {
                retryRecovery(generation: generation, attempts: attempts - 1)
            }
        }
    }

    private func refresh() {
        guard !stopped else { return }
        let windows = WorkspaceWindow.list(onScreen: false)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, let launched = app.launchDate else { continue }
            if !spec.permitsApplication(bundle) {
                guard !app.isHidden else { continue }
                let entry = Entry(pid: app.processIdentifier, launched: launched, bundle: bundle, window: nil)
                if !entries.contains(where: { $0.pid == entry.pid && $0.window == nil }) {
                    entries.append(entry)
                    guard Self.save(entries) else { entries.removeLast(); continue }
                }
                _ = app.hide()
            } else {
                for window in windows where window.pid == app.processIdentifier && !spec.permitsWindow(window.id, bundleIdentifier: bundle) {
                    guard let element = Self.element(window), Self.value(element, kAXMinimizedAttribute) as? Bool == false else { continue }
                    if !entries.contains(where: { $0.pid == window.pid && $0.window == window.id }) {
                        entries.append(Entry(pid: window.pid, launched: launched, bundle: bundle, window: window.id))
                        guard Self.save(entries) else { entries.removeLast(); continue }
                    }
                    _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
    }
    @discardableResult private static func save(_ entries: [Entry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }
    private static func restore() -> [Entry] {
        guard let data = try? Data(contentsOf: file), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let windows = WorkspaceWindow.list(onScreen: false)
        var pending: [Entry] = []
        for entry in entries {
            // PID/window numbers may be reused after an app or Mac restart.
            guard let app = NSRunningApplication(processIdentifier: entry.pid), app.bundleIdentifier == entry.bundle,
                  app.launchDate == entry.launched else { continue }
            if let id = entry.window {
                guard let window = windows.first(where: { $0.id == id && $0.pid == entry.pid }) else { continue }
                guard let element = element(window) else { pending.append(entry); continue }
                if AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) != .success { pending.append(entry) }
            } else if app.isHidden && !app.unhide() { pending.append(entry) }
        }
        _ = save(pending)
        return pending
    }
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private static func element(_ window: WorkspaceWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        guard let elements = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let matches = elements.filter { element in
            guard value(element, kAXTitleAttribute) as? String == window.title,
                  let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero
            return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point)
                && abs(point.x - window.frame.minX) < 3 && abs(point.y - window.frame.minY) < 3
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
