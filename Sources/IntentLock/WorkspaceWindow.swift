import AppKit
import ApplicationServices
import IntentCore

/// Public WindowServer IDs stay session-local and are never saved as intentions.
public struct WorkspaceWindow {
    public let id: UInt32
    public let pid: pid_t
    public let bundle: String
    public let title: String
    public let frame: CGRect
    public static func list(onScreen: Bool = true) -> [WorkspaceWindow] {
        let flags: CGWindowListOption = onScreen ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        return list(records: CGWindowListCopyWindowInfo(flags, kCGNullWindowID) as? [[String: Any]] ?? [])
    }
    static func list(records: [[String: Any]]) -> [WorkspaceWindow] {
        records.compactMap { item in
            guard item[kCGWindowLayer as String] as? Int == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 100, frame.height > 80 else { return nil }
            return .init(id: id, pid: pid, bundle: bundle, title: item[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// Positive AX standard windows only: CG also contains Chrome auxiliary
    /// backing surfaces. Unreported AX-absent windows are outside this narrowly
    /// observable cohort; the browser bridge still owns all reported windows.
    public struct CoverageObservation: @unchecked Sendable {
        public let inventory: BrowserWindowCoveragePolicy.Inventory
        public let continuousIdentities: Set<BrowserWindowCoveragePolicy.NativeIdentity>
        public let observedAt: TimeInterval
        public let sampledAt: TimeInterval
        fileprivate let anchors: [BrowserWindowCoveragePolicy.NativeIdentity: AXUIElement]
        fileprivate init(inventory: BrowserWindowCoveragePolicy.Inventory,
                         continuousIdentities: Set<BrowserWindowCoveragePolicy.NativeIdentity>, sampledAt: TimeInterval,
                         anchors: [BrowserWindowCoveragePolicy.NativeIdentity: AXUIElement]) {
            self.inventory = inventory; self.continuousIdentities = continuousIdentities
            self.anchors = anchors; self.sampledAt = sampledAt; observedAt = ProcessInfo.processInfo.systemUptime
        }
        func element(for identity: BrowserWindowCoveragePolicy.NativeIdentity) -> AXUIElement? { anchors[identity] }
        var bindings: [(BrowserWindowCoveragePolicy.NativeIdentity, AXUIElement)] { anchors.map { ($0.key, $0.value) } }
    }
    public static func browserCoverageInventory(bundleIdentifier: String, deadline: TimeInterval? = nil) -> BrowserWindowCoveragePolicy.Inventory? {
        browserCoverageObservation(bundleIdentifier: bundleIdentifier, deadline: deadline)?.inventory
    }
    public static func browserCoverageObservation(bundleIdentifier: String, deadline: TimeInterval? = nil,
                                                 prior: CoverageObservation? = nil) -> CoverageObservation? {
        let sampledAt = ProcessInfo.processInfo.systemUptime
        return browserCoverageObservation(bundleIdentifier: bundleIdentifier,
            rows: CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
            sampledAt: sampledAt, deadline: deadline, prior: prior)
    }
    private static func browserCoverageObservation(bundleIdentifier: String, rows: [[String: Any]]?, sampledAt: TimeInterval,
                                           deadline: TimeInterval? = nil, prior: CoverageObservation? = nil) -> CoverageObservation? {
        func hasTime() -> Bool { deadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? true }
        guard hasTime(), AXIsProcessTrusted(), let rows else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
        var native: [BrowserWindowCoveragePolicy.NativeWindow] = []
        var standard: [BrowserWindowCoveragePolicy.StandardWindow] = []
        var standardElements: [AXUIElement] = []
        for app in apps {
            guard hasTime(), let launched = app.launchDate else { return nil }
            let proof = BrowserProcessIdentity(pid: app.processIdentifier, launched: launched.timeIntervalSinceReferenceDate)
            for row in rows where row[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
                && row[kCGWindowLayer as String] as? Int == 0 {
                guard hasTime(), let id = row[kCGWindowNumber as String] as? UInt32,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), BrowserWindowCoveragePolicy.validFrame(frame) else { return nil }
                native.append(.init(identity: .init(bundleIdentifier: bundleIdentifier, pid: proof.pid, launched: proof.launched, windowID: id),
                    title: row[kCGWindowName as String] as? String ?? "", frame: frame))
            }
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                guard hasTime() else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.025)
                var result: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
            }
            guard let elements = attribute(AXUIElementCreateApplication(proof.pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
            for element in elements {
                guard hasTime(), let role = attribute(element, kAXRoleAttribute) as? String,
                      let subrole = attribute(element, kAXSubroleAttribute) as? String else { return nil }
                guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else { continue }
                var elementPID: pid_t = 0
                guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == proof.pid,
                      attribute(element, kAXMinimizedAttribute) as? Bool != nil,
                      let title = attribute(element, kAXTitleAttribute) as? String,
                      let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                      AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
                standardElements.append(element)
                standard.append(.init(bundleIdentifier: bundleIdentifier, processIdentity: proof, title: title,
                    frame: CGRect(origin: point, size: dimensions)))
            }
        }
        // CFEqual compares the same live accessible object, not its title or
        // frame. Only packets created by a previous successful bidirectional
        // match may anchor a row; the general AX cache is not this authority.
        guard hasTime(), let pinned = BrowserWindowCoveragePolicy.continuingAnchors(native: native, standard: standard,
            previous: prior?.anchors ?? [:], current: standardElements, equal: { CFEqual($0, $1) }) else { return nil }
        guard hasTime(), let identities = BrowserWindowCoveragePolicy.standardIdentityBindings(native: native, standard: standard, anchors: pinned) else { return nil }
        let anchors = Dictionary(uniqueKeysWithValues: zip(identities, standardElements))
        return .init(inventory: .init(windows: native, observedStandard: Set(identities)),
            continuousIdentities: Set(pinned.values), sampledAt: sampledAt, anchors: anchors)
    }

    /// A lifetime probe, not a presentation query. Restoration can temporarily
    /// move a live window off screen; that must not be mistaken for closure.
    /// nil means WindowServer could not answer, so a bounded caller can retry.
    public static func exists(id: UInt32, pid: pid_t,
        copyInfo: (CGWindowListOption, CGWindowID) -> CFArray? = CGWindowListCopyWindowInfo) -> Bool? {
        guard let records = copyInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return records.contains {
            $0[kCGWindowNumber as String] as? UInt32 == id &&
                $0[kCGWindowOwnerPID as String] as? pid_t == pid
        }
    }

    public static func focused() -> WorkspaceWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = list().filter { $0.pid == app.processIdentifier }
        // Outline/blur workers call this too. Never make a synchronous AX
        // request into our own SwiftUI while its field editor is changing.
        // WindowServer ordering is sufficient for our own foreground window.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return candidates.first }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.03)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            let focused = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(focused, 0.03)
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String {
                let matches = candidates.filter { $0.title == title }
                if matches.count == 1 { return matches[0] }
            }
        }
        // WindowServer order is front to back; only use a visible window of
        // the actual foreground application, never an arbitrary background app.
        return candidates.first
    }
    public static func raise(ids: Set<UInt32>, bundle: String, actionGate: DeferredSessionActionGate? = nil) -> Bool {
        guard let target = list(onScreen: false).first(where: { ids.contains($0.id) && $0.bundle == bundle }),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
        let element = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(element, 0.03)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.02)
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               title as? String == target.title {
                var position: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                      let position, CFGetTypeID(position) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero
                guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                      abs(point.x - target.frame.minX) < 3, abs(point.y - target.frame.minY) < 3 else { continue }
                // Focus enforcement may end while the AX queries above wait.
                // Session callers fence each side effect against that stop.
                if let actionGate {
                    guard actionGate.perform(ifCurrent: 0, { app.activate(options: []) }) != nil else { return false }
                    return actionGate.perform(ifCurrent: 0) {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
                    } ?? false
                }
                app.activate(options: [])
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }
        }
        return false
    }
}

/// Mouse-transparent borders on the desktop and Dock's native Mission Control
/// tiles. AX discovery is bounded and runs off the input/main threads.
public final class WorkspaceOutlineController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "intent.workspace-outlines", qos: .utility)
    private let mutex = NSLock()
    private var selection = QuickSelection()
    private var timer: DispatchSourceTimer?
    private var revision = 0
    private var lastSnapshotRequest = Date.distantPast // worker queue only
    private var tabContinuity: [UInt32: TabBlurContinuity] = [:] // worker queue only
    private var panels: [NSPanel] = [] // main queue only
    private var scanCache: [UInt32: (key: String, at: Date, regions: [CGRect])] = [:] // worker queue
    public init() {}
    public func update(_ selection: QuickSelection) {
        mutex.lock(); self.selection = selection; revision += 1; mutex.unlock()
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.35)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop() {
        timer?.cancel(); timer = nil
        mutex.lock(); revision += 1; selection = QuickSelection(); mutex.unlock()
        DispatchQueue.main.async { [weak self] in self?.panels.forEach { $0.orderOut(nil) }; self?.panels = [] }
    }
    private func refresh() {
        mutex.lock(); let selection = self.selection; let token = revision; mutex.unlock()
        // Idle browser extensions intentionally publish no spontaneous snapshots.
        // While marks are displayed, refresh so the border follows tab changes.
        if Date().timeIntervalSince(lastSnapshotRequest) >= 0.35 {
            lastSnapshotRequest = Date()
            for browser in Set(selection.tabs.map(\.browser)) {
                try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
            }
        }
        let windows = WorkspaceWindow.list(onScreen: false)
        var markedRegions: [UInt32: [CGRect]] = [:]
        let front = WorkspaceWindow.focused()
        let overviewVisible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).contains {
            $0[kCGWindowOwnerName as String] as? String == "Dock" && $0[kCGWindowLayer as String] as? Int == 20
        }
        for window in windows {
            if selection.windowIDsByApp[window.bundle]?.contains(window.id) == true {
                markedRegions[window.id] = [window.frame]
                continue
            }
            guard QuickSelection.browsers.contains(window.bundle),
                  let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: window.bundle).load(),
                  selection.browserSessionIDs[window.bundle] == snapshot.browserSessionID,
                  let id = BrowserWindowMatching.match(title: window.title, tabs: snapshot.allTabs ?? snapshot.tabs, nativeWindowCount: windows.filter { $0.bundle == window.bundle }.count, frame: window.frame, isFocused: front?.id == window.id) else { continue }
            let tabs = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == id }
            let selectedIDs = Set(selection.tabs.filter { $0.browser == window.bundle }.map(\.id))
            guard tabs.contains(where: { selectedIDs.contains($0.id) }) else { continue }
            if let whole = selection.browserWindowTabs[.init(browser: window.bundle, id: id)],
               !whole.isEmpty, whole.isSubset(of: selectedIDs), whole == Set(tabs.filter(QuickSelection.isSelectable).map(\.id)) {
                markedRegions[window.id] = [window.frame]
                continue
            }
            // Selection/geometry changes refresh immediately; an unchanged tab strip
            // needs no full accessibility traversal on every animation tick.
            let key = "\(window.pid):\(window.frame):\(tabs.map { "\($0.id):\($0.index):\($0.title):\($0.active)" }):\(selectedIDs.sorted())"
            if let cached = scanCache[window.id], cached.key == key, Date().timeIntervalSince(cached.at) < 1 {
                markedRegions[window.id] = cached.regions
                continue
            }
            if front?.id != window.id && !overviewVisible {
                markedRegions[window.id] = scanCache[window.id].flatMap { $0.key == key ? $0.regions : nil } ?? []
                continue
            }
            let scan = WorkspaceTabOutline.scan(window: window, tabs: tabs, selected: selectedIDs)
            let context = "\(window.pid):\(window.frame):\(tabs):\(selectedIDs.sorted())"
            var continuity = tabContinuity[window.id] ?? TabBlurContinuity()
            let regions = continuity.update(scan.regions, context: context, complete: scan.complete, now: Date())
            tabContinuity[window.id] = continuity
            markedRegions[window.id] = regions
            if scan.complete { scanCache[window.id] = (key, Date(), regions) }
        }
        scanCache = scanCache.filter { markedRegions[$0.key] != nil }
        tabContinuity = tabContinuity.filter { markedRegions[$0.key] != nil }
        let selected = windows.filter { markedRegions[$0.id]?.isEmpty == false }
        let mission = Self.missionRegions(selected: selected, all: windows, markedRegions: markedRegions)
        let dockTransition = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).contains {
            $0[kCGWindowOwnerName as String] as? String == "Dock" && $0[kCGWindowLayer as String] as? Int == 20
        }
        let rectangles: [CGRect]
        if let mission { rectangles = mission }
        else if dockTransition { rectangles = [] }
        else {
            // A full-window border must not float across a window covering it.
            // Render the focused marked window; Mission Control renders all marks.
            rectangles = front.flatMap { markedRegions[$0.id] } ?? []
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let current = self.revision == token; self.mutex.unlock()
            guard current else { return }
            while self.panels.count > rectangles.count { self.panels.removeLast().orderOut(nil) }
            for (index, rect) in rectangles.enumerated() {
                if index == self.panels.count {
                    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true; panel.hasShadow = false; panel.hidesOnDeactivate = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]; panel.level = .screenSaver
                    let view = WorkspaceMarkBorderView()
                    panel.contentView = view; self.panels.append(panel)
                }
                let panel = self.panels[index]
                if let view = panel.contentView as? WorkspaceMarkBorderView {
                    view.color = selection.accessMode == .blacklist ? .systemRed : .systemGreen
                    view.chromeTab = front?.bundle == "com.google.Chrome" && rect.height < 65 && rect.width > rect.height * 1.5
                    view.needsDisplay = true
                }
                panel.setFrame(FocusBlurPolicy.appKitFrame(rect, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height), display: false)
                if !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
    }
    private static func missionRegions(selected: [WorkspaceWindow], all: [WorkspaceWindow], markedRegions: [UInt32: [CGRect]]) -> [CGRect]? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let deadline = Date(timeIntervalSinceNow: 0.08)
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }; AXUIElementSetMessagingTimeout(element, 0.008)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let root = children(app).first(where: { value($0, kAXIdentifierAttribute) as? String == "mc" }) else { return nil }
        let titles = Set(selected.filter { window in !window.title.isEmpty && all.filter { $0.title == window.title }.count == 1 }.map(\.title))
        var pending = children(root); var index = 0; var result: [CGRect] = []
        while index < pending.count && index < 400 && Date() < deadline {
            let element = pending[index]; index += 1
            if (value(element, kAXIdentifierAttribute) as? String ?? "").hasPrefix("mc.spaces") { continue }
            let labels = [value(element, kAXTitleAttribute) as? String, value(element, kAXDescriptionAttribute) as? String].compactMap { $0 }
            if labels.contains(where: titles.contains),
               let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
               let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
                var point = CGPoint.zero; var dimensions = CGSize.zero
                if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                    let frame = CGRect(origin: point, size: dimensions)
                    if FocusBlurPolicy.valid(frame), let window = selected.first(where: { labels.contains($0.title) }) {
                        // Scale just the tab chrome into the thumbnail; a selected tab
                        // must never imply that the entire browser window was selected.
                        for region in markedRegions[window.id] ?? [] {
                            let source = window.frame
                            let mapped = CGRect(x: frame.minX + (region.minX - source.minX) * frame.width / source.width,
                                                y: frame.minY + (region.minY - source.minY) * frame.height / source.height,
                                                width: region.width * frame.width / source.width,
                                                height: region.height * frame.height / source.height)
                            if mapped.width > 2 && mapped.height > 2 { result.append(mapped) }
                        }
                        continue
                    }
                }
            }
            pending.append(contentsOf: children(element).prefix(max(0, 400 - pending.count)))
        }
        return result
    }
}

/// Thin, inset contours follow the tab chrome instead of boxing its hit target.
private final class WorkspaceMarkBorderView: NSView {
    var color: NSColor = .systemGreen
    var chromeTab = false
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.25, dy: 1.25)
        guard rect.width > 0, rect.height > 0 else { return }
        let path: NSBezierPath
        if chromeTab {
            let r = min(9, rect.height / 3)
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.curve(to: NSPoint(x: rect.minX + r, y: rect.minY + r), controlPoint1: NSPoint(x: rect.minX + r, y: rect.minY), controlPoint2: NSPoint(x: rect.minX + r, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY - r))
            path.curve(to: NSPoint(x: rect.minX + 2*r, y: rect.maxY), controlPoint1: NSPoint(x: rect.minX + r, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX + r, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - 2*r, y: rect.maxY))
            path.curve(to: NSPoint(x: rect.maxX - r, y: rect.maxY - r), controlPoint1: NSPoint(x: rect.maxX - r, y: rect.maxY), controlPoint2: NSPoint(x: rect.maxX - r, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY + r))
            path.curve(to: NSPoint(x: rect.maxX, y: rect.minY), controlPoint1: NSPoint(x: rect.maxX - r, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX - r, y: rect.minY))
            path.close()
        } else {
            path = NSBezierPath(roundedRect: rect, xRadius: min(8, rect.height / 4), yRadius: min(8, rect.height / 4))
        }
        color.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}
