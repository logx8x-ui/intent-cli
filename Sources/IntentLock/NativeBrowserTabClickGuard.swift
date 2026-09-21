import AppKit
import ApplicationServices
import IntentCore

public enum NativeTabClickPolicy {
    /// If this exact window has no permitted tab to return to, its current page
    /// still needs protection (including browser pages without content scripts).
    public static func blocksWholeWindow(tabs: [BrowserTabItem], allowedIDs: Set<Int>) -> Bool {
        !tabs.isEmpty && tabs.allSatisfy { !allowedIDs.contains($0.id) }
    }

    /// Wheel input is restricted only over the fully blocked foreground window;
    /// header-only masks and system overview navigation must retain scrolling.
    public static func blocksScroll(wholeWindowBlocked: Bool, pointerBlocked: Bool, missionControl: Bool) -> Bool {
        wholeWindowBlocked && pointerBlocked && !missionControl
    }

    public static func blocksSidebarTitle(_ title: String, tabs: [BrowserTabItem], allowedIDs: Set<Int>) -> Bool {
        let matches = tabs.filter { $0.title == title }
        // Ambiguous duplicate labels must never grant access to a forbidden tab.
        return !matches.isEmpty && matches.contains { !allowedIDs.contains($0.id) }
    }
    /// Collapsed groups/pinned strips may expose only part of the tab list.
    /// In that case use explicit labels, never an index into the full browser list.
    public static func visualBlockedPositions(labels: [[String]], tabs: [BrowserTabItem], allowedIDs: Set<Int>) -> Set<Int> {
        Set(labels.indices.filter { position in
            let matches = tabs.filter { tab in
                !tab.title.isEmpty && labels[position].contains { label in
                    label == tab.title || label.hasPrefix(tab.title + " - Memory usage - ")
                }
            }
            return !matches.isEmpty && matches.allSatisfy { !allowedIDs.contains($0.id) }
        })
    }

    public static func blockedIndices(nativeCount: Int, tabs: [BrowserTabItem], allowedIDs: Set<Int>) -> Set<Int>? {
        guard nativeCount > 0, tabs.count == nativeCount,
              tabs.map(\.index).sorted() == Array(0..<nativeCount) else { return nil }
        return Set(tabs.filter { !allowedIDs.contains($0.id) }.map(\.index))
    }
}

/// An incomplete scan is not evidence that previously mapped tabs disappeared.
/// Reuse is bounded and only valid for the same window, geometry and permissions.
public struct TabBlurContinuity {
    private var context = ""
    private var entries: [(rect: CGRect, seen: Date)] = []
    public init() {}
    public mutating func update(_ sample: [CGRect], context: String, complete: Bool, now: Date) -> [CGRect] {
        if self.context != context || complete { entries = [] }
        self.context = context
        entries.removeAll { now.timeIntervalSince($0.seen) >= 0.6 }
        // A bounded AX scan often reaches only some Firefox sidebar rows.
        // Renew each validated row independently instead of dropping/recreating
        // the entire strip whenever a later branch hits its deadline.
        for rect in sample {
            if let index = entries.firstIndex(where: { $0.rect == rect }) { entries[index].seen = now }
            else { entries.append((rect, now)) }
        }
        return entries.map(\.rect)
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
    private var visualRectangles: [CGRect] = []
    private var foregroundWindowBlocked = false
    private var addressSubmissionBlocked = false
    private var updatedAt = Date.distantPast
    private var blockedClicks = 0
    private var mouseDownEvents = 0
    private var missionControlEvents = 0
    private var lastDiagnostics = ""
    private var ignoreUntil = Date.distantPast
    private var sidebarLabels = 0
    private var sidebarMatches = 0
    private var sidebarRoles: [String: Int] = [:]
    private var scanState = "idle"
    private var windowMatches = 0
    private var tabGroups = 0
    private var blurContinuity = TabBlurContinuity()

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
        mutex.lock(); stopped = true; rectangles = []; visualRectangles = []; foregroundWindowBlocked = false; mutex.unlock()
    }

    func shouldBlock(_ point: CGPoint, frontmostPID: pid_t?) -> Bool {
        guard !IntentInteractivePanelRegions.shared.contains(point) else { return false }
        mutex.lock(); defer { mutex.unlock() }
        let blocked = !stopped && (foregroundWindowBlocked || Date() >= ignoreUntil) && frontmostPID == pid && Date().timeIntervalSince(updatedAt) < 0.45
            && rectangles.contains { $0.contains(point) }
        if blocked { blockedClicks += 1 }
        return blocked
    }

    /// Keyboard handling reads only the same short-lived, focused-window cache.
    func blocksForegroundWindow(_ frontmostPID: pid_t?) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return !stopped && foregroundWindowBlocked && frontmostPID == pid
            && Date().timeIntervalSince(updatedAt) < 0.45
    }

    func blocksAddressSubmission(_ frontmostPID: pid_t?) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return !stopped && addressSubmissionBlocked && frontmostPID == pid && Date().timeIntervalSince(updatedAt) < 0.45
    }

    /// A separate visual consumer; never performs AX work on the main thread.
    func blurRegions(frontmostPID: pid_t?) -> [CGRect] {
        mutex.lock(); defer { mutex.unlock() }
        // Page-selection drags invalidate click hit testing, not visual content.
        // The scanner continues to validate geometry while the mouse is held.
        guard !stopped, frontmostPID == pid,
              Date().timeIntervalSince(updatedAt) < 0.8 else { return [] }
        return visualRectangles
    }

    private func publish(_ rectangles: [CGRect], pid: pid_t, visualRectangles: [CGRect] = [], blocksForegroundWindow: Bool = false, blocksAddressSubmission: Bool = false) {
        mutex.lock()
        guard !stopped else { mutex.unlock(); return }
        self.rectangles = rectangles; self.visualRectangles = visualRectangles; self.pid = pid; updatedAt = Date()
        foregroundWindowBlocked = blocksForegroundWindow
        addressSubmissionBlocked = blocksAddressSubmission
        let clicks = blockedClicks
        let events = mouseDownEvents
        let missionControl = missionControlEvents
        mutex.unlock()
        // Counts only: no titles, URLs, click positions, or screenshots. Disk IO
        // stays on the scanner queue, outside both the input callback and its mutex.
        let fingerprint = "\(clicks):\(rectangles.count):\(events):\(missionControl):\(sidebarLabels):\(sidebarMatches):\(scanState):\(windowMatches):\(tabGroups):\(visualRectangles.count)"
        if fingerprint != lastDiagnostics {
            lastDiagnostics = fingerprint
            let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("native-tab-click-diagnostics.json")
            if let data = try? JSONSerialization.data(withJSONObject: ["scanState": scanState, "windowMatches": windowMatches, "tabGroups": tabGroups, "blurRegions": visualRectangles.count, "blockedClicks": clicks, "blockedRegions": rectangles.count, "mouseDownEvents": events, "missionControlEvents": missionControl, "sidebarLabels": sidebarLabels, "sidebarMatches": sidebarMatches, "sidebarRoles": sidebarRoles]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func refresh() {
        sidebarLabels = 0; sidebarMatches = 0; sidebarRoles = [:]
        windowMatches = 0; tabGroups = 0
        scanState = "not-frontmost-browser"
        guard let app = NSWorkspace.shared.frontmostApplication,
              let browser = app.bundleIdentifier, QuickSelection.browsers.contains(browser) else {
            blurContinuity = TabBlurContinuity(); publish([], pid: 0); return
        }
        scanState = "rules-or-snapshot-unavailable"
        guard
              let data = try? Data(contentsOf: ActiveBrowserRulesStore.defaultFileURL()),
              let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data), rules.active, rules.isFresh(),
              let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: browser).load(),
              !rules.unrestrictedBrowserBundleIdentifiers.contains(browser),
              rules.matchesBrowserSession(snapshot),
              let allTabs = snapshot.allTabs else {
            blurContinuity = TabBlurContinuity(); publish([], pid: 0); return
        }
        scanState = "scanning"
        let deadline = Date(timeIntervalSinceNow: 0.10)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focused = value(application, kAXFocusedWindowAttribute, deadline)
            ?? value(application, kAXMainWindowAttribute, deadline)
        let windows = elements(application, kAXWindowsAttribute, deadline).sorted {
            lhs, rhs in
            let left = focused.map { CFEqual($0, lhs) } ?? false
            let right = focused.map { CFEqual($0, rhs) } ?? false
            return left && !right
        }
        let focusedElement = value(application, kAXFocusedUIElementAttribute, deadline)
        var blocksAddress = false
        var blocked: [CGRect] = []
        var visual: [CGRect] = []
        var visualComplete = false
        var blocksForegroundWindow = false
        var visualContext = ""
        if let focused, let frame = bounds(unsafeBitCast(focused, to: AXUIElement.self), deadline) {
            visualContext = "\(app.processIdentifier):\(CFHash(focused)):\(frame):\(allTabs):\(rules.selectedTabIDsByBrowser?[browser] ?? snapshot.tabs.map(\.id))"
        }
        for window in windows {
            guard Date() < deadline else { break }
            let isFocused = focused.map { CFEqual($0, window) } ?? false
            let title = string(window, kAXTitleAttribute, deadline) ?? ""
            guard let windowID = BrowserWindowMatching.match(title: title, tabs: allTabs, nativeWindowCount: windows.count, frame: bounds(window, deadline), isFocused: isFocused) else { continue }
            windowMatches += 1
            let windowTabs = allTabs.filter { $0.windowID == windowID }
            let selected = rules.selectedTabIDsByBrowser?[browser]
            let allowedIDs = rules.accessMode == .blacklist && selected != nil ? Set(allTabs.map(\.id)).subtracting(selected!) : Set(selected ?? snapshot.tabs.map(\.id)).union(rules.allowGoogleSearchTabs && rules.startupSessionID != nil ? Set(allTabs.filter { $0.searchSessionID == rules.startupSessionID }.map(\.id)) : [])
            if isFocused, NativeTabClickPolicy.blocksWholeWindow(tabs: windowTabs, allowedIDs: allowedIDs),
               let frame = bounds(window, deadline), frame.width > 5, frame.height > 5 {
                blocked.append(frame)
                visual.append(frame)
                visualComplete = true
                blocksForegroundWindow = true
                continue
            }
            var pending: [(AXUIElement, CGRect?)] = [(window, nil)]
            var visited = 0
            var seen: [CFHashCode: [AXUIElement]] = [:]
            while !pending.isEmpty, visited < 1600, Date() < deadline {
                let (element, inheritedSidebar) = pending.removeFirst()
                let hash = CFHash(element)
                if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { continue }
                seen[hash, default: []].append(element)
                visited += 1
                let role = string(element, kAXRoleAttribute, deadline) ?? ""
                // SVG favicon descendants can exhaust the bounded scan before
                // Firefox's actual tab-label leaves are reached.
                if role == kAXImageRole { continue }
                var sidebar = inheritedSidebar
                // Page controls (including ARIA tabs) must never be treated as browser chrome.
                if role == "AXWebArea" {
                    let url = value(element, kAXURLAttribute, deadline).map { String(describing: $0) }
                        ?? string(element, kAXValueAttribute, deadline)
                        ?? string(element, kAXTitleAttribute, deadline) ?? ""
                    if browser == "org.mozilla.firefox", url == "chrome://browser/content/webext-panels.xhtml" {
                        sidebar = bounds(element, deadline)
                    } else if sidebar == nil { continue }
                }
                let isAddress = sidebar == nil && [kAXTextFieldRole, kAXComboBoxRole].contains(role)
                    && BrowserAddressPolicy.isAddressControl(labels: [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { string(element, $0, deadline) })
                if isAddress, let focusedElement, CFEqual(focusedElement, element) {
                    let input = string(element, kAXValueAttribute, deadline) ?? ""
                    blocksAddress = !rules.allowGoogleSearchTabs || BrowserAddressPolicy.isDirectDestination(input)
                }
                // Browser chrome only: page text fields remain fully usable.
                if isAddress, !rules.allowGoogleSearchTabs,
                   let rect = bounds(element, deadline) {
                    blocked.append(rect)
                }
                let children = elements(element, kAXChildrenAttribute, deadline)
                if sidebar != nil { sidebarRoles[role, default: 0] += 1 }
                // Firefox exposes some sidebar text as non-static leaf roles.
                // Match exact extension tab titles, not a particular text role.
                let sidebarLabel = children.isEmpty && role != kAXImageRole
                if sidebar != nil, sidebarLabel { sidebarLabels += 1 }
                var unambiguousBlur = false
                if let sidebar, sidebarLabel,
                   [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { attribute in
                       guard let title = string(element, attribute, deadline), !title.isEmpty else { return false }
                       let matches = windowTabs.filter { $0.title == title }
                       unambiguousBlur = !matches.isEmpty && matches.allSatisfy { !allowedIDs.contains($0.id) }
                       return NativeTabClickPolicy.blocksSidebarTitle(title, tabs: windowTabs, allowedIDs: allowedIDs)
                   }),
                   let label = bounds(element, deadline) {
                    sidebarMatches += 1
                    let row = CGRect(x: sidebar.minX, y: label.minY - 3, width: sidebar.width, height: label.height + 6).intersection(sidebar)
                    if !row.isEmpty {
                        blocked.append(row)
                        if isFocused, unambiguousBlur { visual.append(row) }
                    }
                }
                // Sidebar tab groups contain nested rows, not native radio-button
                // tabs. Keep traversing them rather than stopping at the group.
                if role == kAXTabGroupRole && sidebar == nil {
                    tabGroups += 1
                    let tabs = nativeTabs(in: children, deadline: deadline)
                    let blockedIndices = NativeTabClickPolicy.blockedIndices(nativeCount: tabs.count, tabs: windowTabs, allowedIDs: allowedIDs)
                    let visualIndices: Set<Int>
                    if let blockedIndices {
                        visualIndices = blockedIndices
                    } else {
                        let labels = tabs.map { tab in
                            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(tab, $0, deadline) }
                        }
                        visualIndices = NativeTabClickPolicy.visualBlockedPositions(labels: labels, tabs: windowTabs, allowedIDs: allowedIDs)
                    }
                    for (index, tab) in tabs.enumerated() {
                        guard (blockedIndices?.contains(index) ?? false) || (isFocused && visualIndices.contains(index)),
                              let rect = bounds(tab, deadline), rect.width > 5, rect.height > 5 else { continue }
                        if blockedIndices?.contains(index) == true { blocked.append(rect) }
                        if isFocused && visualIndices.contains(index) { visual.append(rect.insetBy(dx: 1, dy: 1)) }
                    }
                } else { pending.append(contentsOf: children.prefix(1600 - visited).map { ($0, sidebar) }) }
            }
            if isFocused { visualComplete = pending.isEmpty && Date() < deadline && (tabGroups > 0 || sidebarLabels > 0) }
        }
        if !visualContext.isEmpty {
            visual = blurContinuity.update(visual, context: visualContext, complete: visualComplete, now: Date())
        } else {
            blurContinuity = TabBlurContinuity()
        }
        // Each completed rectangle is independently validated. Preserve those
        // checks if another branch runs out of time; never infer missing rows.
        publish(blocked, pid: app.processIdentifier, visualRectangles: visual, blocksForegroundWindow: blocksForegroundWindow, blocksAddressSubmission: blocksAddress)
    }

    private func nativeTabs(in children: [AXUIElement], deadline: Date) -> [AXUIElement] {
        var pending = children.reversed().map { ($0, 0) }
        var tabs: [AXUIElement] = []
        var visited = 0
        while let (element, depth) = pending.popLast(), visited < 200, Date() < deadline {
            visited += 1
            let role = string(element, kAXRoleAttribute, deadline)
            if role == kAXRadioButtonRole || role == "AXTab" { tabs.append(element); continue }
            guard depth < 4, role != "AXWebArea", role != kAXImageRole else { continue }
            pending.append(contentsOf: elements(element, kAXChildrenAttribute, deadline).reversed().map { ($0, depth + 1) })
        }
        return tabs
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
        let children = value(element, attribute, deadline) as? [AXUIElement] ?? []
        if children.isEmpty, attribute == kAXChildrenAttribute {
            return value(element, kAXVisibleChildrenAttribute, deadline) as? [AXUIElement] ?? []
        }
        return children
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
