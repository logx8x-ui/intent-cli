import AppKit
import ApplicationServices
import IntentCore

public enum NativeTabClickPolicy {
    public static func blockedIndices(nativeCount: Int, tabs: [BrowserTabItem], allowedIDs: Set<Int>) -> Set<Int>? {
        guard nativeCount > 0, tabs.count == nativeCount,
              tabs.map(\.index).sorted() == Array(0..<nativeCount) else { return nil }
        return Set(tabs.filter { !allowedIDs.contains($0.id) }.map(\.index))
    }
}

/// The event tap only reads this short-lived geometry cache. AX work never runs in it.
final class NativeBrowserTabClickGuard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "intent.native-tab-hit-regions", qos: .userInteractive)
    private let mutex = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = true
    private var pid: pid_t = 0
    private var rectangles: [CGRect] = []
    private var updatedAt = Date.distantPast
    private var blockedClicks = 0
    private var mouseDownEvents = 0
    private var missionControlEvents = 0
    private var lastDiagnostics = ""
    private var ignoreUntil = Date.distantPast

    func recordMouseDown(missionControl: Bool) {
        mutex.lock(); mouseDownEvents += 1
        if missionControl { missionControlEvents += 1 }
        mutex.unlock()
    }

    func invalidateDuringDrag() {
        mutex.lock(); ignoreUntil = Date(timeIntervalSinceNow: 0.25); mutex.unlock()
    }

    func start() {
        mutex.lock(); stopped = false; mutex.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.15)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer; timer.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        mutex.lock(); stopped = true; rectangles = []; mutex.unlock()
    }

    func shouldBlock(_ point: CGPoint, frontmostPID: pid_t?) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        let blocked = !stopped && Date() >= ignoreUntil && frontmostPID == pid && Date().timeIntervalSince(updatedAt) < 0.45
            && rectangles.contains { $0.contains(point) }
        if blocked { blockedClicks += 1 }
        return blocked
    }

    private func publish(_ rectangles: [CGRect], pid: pid_t) {
        mutex.lock()
        guard !stopped else { mutex.unlock(); return }
        self.rectangles = rectangles; self.pid = pid; updatedAt = Date()
        let clicks = blockedClicks
        let events = mouseDownEvents
        let missionControl = missionControlEvents
        mutex.unlock()
        // Counts only: no titles, URLs, click positions, or screenshots. Disk IO
        // stays on the scanner queue, outside both the input callback and its mutex.
        let fingerprint = "\(clicks):\(rectangles.count):\(events):\(missionControl)"
        if fingerprint != lastDiagnostics {
            lastDiagnostics = fingerprint
            let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("native-tab-click-diagnostics.json")
            if let data = try? JSONSerialization.data(withJSONObject: ["blockedClicks": clicks, "blockedRegions": rectangles.count, "mouseDownEvents": events, "missionControlEvents": missionControl]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let browser = app.bundleIdentifier, QuickSelection.browsers.contains(browser),
              let data = try? Data(contentsOf: ActiveBrowserRulesStore.defaultFileURL()),
              let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data), rules.active, rules.isFresh(),
              let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: browser).load(),
              let allTabs = snapshot.allTabs else {
            publish([], pid: 0); return
        }
        let deadline = Date(timeIntervalSinceNow: 0.10)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows = elements(application, kAXWindowsAttribute, deadline)
        var blocked: [CGRect] = []
        for window in windows {
            guard Date() < deadline else { break }
            let title = string(window, kAXTitleAttribute, deadline) ?? ""
            guard let windowID = BrowserWindowMatching.match(title: title, tabs: allTabs, nativeWindowCount: windows.count) else { continue }
            let windowTabs = allTabs.filter { $0.windowID == windowID }
            let allowedIDs = Set(rules.selectedTabIDsByBrowser?[browser] ?? snapshot.tabs.map(\.id))
            var pending = [window]
            var visited = 0
            while !pending.isEmpty, visited < 100, Date() < deadline {
                let element = pending.removeFirst(); visited += 1
                let role = string(element, kAXRoleAttribute, deadline) ?? ""
                // Page controls (including ARIA tabs) must never be treated as browser chrome.
                if role == "AXWebArea" || role == kAXToolbarRole { continue }
                let children = elements(element, kAXChildrenAttribute, deadline)
                if role == kAXTabGroupRole {
                    let tabs = children.filter {
                        let role = string($0, kAXRoleAttribute, deadline)
                        return role == kAXRadioButtonRole || role == "AXTab"
                    }
                    guard let blockedIndices = NativeTabClickPolicy.blockedIndices(nativeCount: tabs.count, tabs: windowTabs, allowedIDs: allowedIDs) else { continue }
                    for (index, tab) in tabs.enumerated() where blockedIndices.contains(index) {
                        if let rect = bounds(tab, deadline), rect.width > 5, rect.height > 5 { blocked.append(rect) }
                    }
                } else { pending.append(contentsOf: children.prefix(100 - visited)) }
            }
        }
        // An incomplete scan must not infer tab indices from a truncated list.
        publish(Date() < deadline ? blocked : [], pid: app.processIdentifier)
    }

    private func value(_ element: AXUIElement, _ attribute: String, _ deadline: Date) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.01)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ attribute: String, _ deadline: Date) -> String? {
        value(element, attribute, deadline) as? String
    }
    private func elements(_ element: AXUIElement, _ attribute: String, _ deadline: Date) -> [AXUIElement] {
        value(element, attribute, deadline) as? [AXUIElement] ?? []
    }
    private func bounds(_ element: AXUIElement, _ deadline: Date) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute, deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute, deadline), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
