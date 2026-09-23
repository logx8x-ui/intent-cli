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
    private let spec: FocusSessionSpec
    private let queue = DispatchQueue(label: "intent.visibility")
    private var timer: DispatchSourceTimer?
    private var entries: [Entry] = []
    private var stopped = false
    public init(spec: FocusSessionSpec) { self.spec = spec }

    public func start() {
        guard spec.hideDistractions && spec.requiresEnforcement else { return }
        queue.sync {
            guard !stopped, timer == nil else { return }
            entries = Self.restore()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop() {
        queue.sync {
            stopped = true
            guard timer != nil else { return }
            timer?.cancel(); timer = nil
            entries = Self.restore()
        }
    }
    public static func restoreInterruptedSession() { _ = restore() }

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
