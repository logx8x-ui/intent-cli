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
        return (CGWindowListCopyWindowInfo(flags, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { item in
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
    public static func focused() -> WorkspaceWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = list().filter { $0.pid == app.processIdentifier }
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
    public static func raise(ids: Set<UInt32>, bundle: String) -> Bool {
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
    public init() {}
    public func update(_ selection: QuickSelection) {
        mutex.lock(); self.selection = selection; revision += 1; mutex.unlock()
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.18)
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
        for window in windows {
            if selection.windowIDsByApp[window.bundle]?.contains(window.id) == true {
                markedRegions[window.id] = [window.frame]
                continue
            }
            guard QuickSelection.browsers.contains(window.bundle),
                  let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: window.bundle).load(),
                  let id = BrowserWindowMatching.match(title: window.title, tabs: snapshot.tabs, nativeWindowCount: windows.filter { $0.bundle == window.bundle }.count) else { continue }
            let tabs = snapshot.tabs.filter { $0.windowID == id }
            let selectedIDs = Set(selection.tabs.filter { $0.browser == window.bundle }.map(\.id))
            guard tabs.contains(where: { selectedIDs.contains($0.id) }) else { continue }
            // Read background window chrome too so marks survive entering Mission Control.
            let scan = WorkspaceTabOutline.scan(window: window, tabs: tabs, selected: selectedIDs)
            let context = "\(window.pid):\(window.frame):\(tabs):\(selectedIDs.sorted())"
            var continuity = tabContinuity[window.id] ?? TabBlurContinuity()
            let regions = continuity.update(scan.regions, context: context, complete: scan.complete, now: Date())
            tabContinuity[window.id] = continuity
            markedRegions[window.id] = regions
        }
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
                    let view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 11; view.layer?.borderWidth = 3
                    panel.contentView = view; self.panels.append(panel)
                }
                let panel = self.panels[index]
                panel.contentView?.layer?.borderColor = (selection.accessMode == .blacklist ? NSColor.systemRed : NSColor.systemGreen).cgColor
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
