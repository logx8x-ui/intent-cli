import AppKit
import ApplicationServices
import IntentCore

public enum FocusBlurPolicy {
    public static func appKitFrame(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Ambiguous labels must not obscure an allowed window.
    public static func shouldBlur(matches: [Bool]) -> Bool {
        !matches.isEmpty && matches.allSatisfy { $0 }
    }

    public static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy { $0.isFinite }
            && rect.width > 5 && rect.height > 5 && rect.width < 16000 && rect.height < 16000
    }
}

/// Visual-only panels: no event taps, activation, window mutation, or screen capture.
/// All Dock accessibility queries have a deadline on a dedicated worker queue.
final class FocusBlurController: @unchecked Sendable {
    private let spec: FocusSessionSpec
    private let tabGuard: NativeBrowserTabClickGuard
    private let queue = DispatchQueue(label: "intent.focus-blur", qos: .userInitiated)
    private let mutex = NSLock()
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var lastDiagnostics = ""
    private var scanDetails: [String: Int] = [:]
    // Main queue only.
    private var panels: [NSPanel] = []
    private var expiry: DispatchWorkItem?

    init(spec: FocusSessionSpec, tabGuard: NativeBrowserTabClickGuard) {
        self.spec = spec
        self.tabGuard = tabGuard
    }

    func start() {
        guard spec.requiresEnforcement else { return }
        mutex.lock(); generation += 1; let token = generation; mutex.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.15)
        timer.setEventHandler { [weak self] in self?.refresh(token: token) }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        mutex.lock(); generation += 1; mutex.unlock()
        timer?.cancel(); timer = nil
        DispatchQueue.main.async { [self] in clear() }
    }

    private func current(_ token: Int) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return generation == token
    }

    private func refresh(token: Int) {
        guard current(token) else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let dockOverlay = windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "Dock"
                && ($0[kCGWindowLayer as String] as? Int) == 20
        }
        scanDetails = [:]
        let rectangles: [CGRect]
        if dockOverlay {
            rectangles = missionControlRegions()
        } else {
            rectangles = tabGuard.blurRegions(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        scanDetails["dockOverlay"] = dockOverlay ? 1 : 0
        scanDetails["mappedRegions"] = rectangles.count
        let fingerprint = scanDetails.keys.sorted().map { "\($0)=\(scanDetails[$0]!)" }.joined(separator: ";")
        if fingerprint != lastDiagnostics {
            lastDiagnostics = fingerprint
            let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("focus-blur-diagnostics.json")
            if let data = try? JSONSerialization.data(withJSONObject: scanDetails) { try? data.write(to: url, options: .atomic) }
        }
        let sampledAt = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token), Date().timeIntervalSince(sampledAt) < 0.25 else { return }
            self.show(rectangles.filter(FocusBlurPolicy.valid))
        }
    }

    private func missionControlRegions() -> [CGRect] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let deadline = Date(timeIntervalSinceNow: 0.10)
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        // "mc" is the Dock subtree used by Hammerspoon's Mission Control support.
        // Do not fall back to scanning Dock icons, Launchpad, or the entire desktop.
        guard let root = children(application, deadline).first(where: {
            text($0, kAXIdentifierAttribute, deadline) == "mc"
        }) else { return [] }
        scanDetails["missionControlRoot"] = 1
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var known: [String: [Bool]] = [:]
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier,
                  let title = window[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            var blocked = !spec.permitsApplication(bundle)
            if !blocked, QuickSelection.browsers.contains(bundle),
               let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: bundle).load(),
               let allTabs = snapshot.allTabs,
               let id = BrowserWindowMatching.match(title: title, tabs: allTabs,
                   nativeWindowCount: Set(allTabs.map(\.windowID)).count),
               let active = allTabs.first(where: { $0.windowID == id && $0.active }) {
                // The snapshot's tabs are the guard's currently permitted subset.
                blocked = !snapshot.tabs.contains(where: { $0.id == active.id })
            }
            known[title, default: []].append(blocked)
        }
        var pending = children(root, deadline)
        var index = 0
        var result: [CGRect] = []
        while index < pending.count, index < 400, Date() < deadline {
            let element = pending[index]; index += 1
            let identifier = text(element, kAXIdentifierAttribute, deadline) ?? ""
            // Space thumbnails represent many windows, not one permission decision.
            if identifier.hasPrefix("mc.spaces") { continue }
            let role = text(element, kAXRoleAttribute, deadline) ?? ""
            scanDetails[role, default: 0] += 1
            if role == kAXButtonRole || role == kAXImageRole || role == kAXWindowRole {
                let labels = [text(element, kAXTitleAttribute, deadline), text(element, kAXDescriptionAttribute, deadline)].compactMap { $0 }
                let matches = labels.flatMap { known[$0] ?? [] }
                if FocusBlurPolicy.shouldBlur(matches: matches), let rect = bounds(element, deadline) {
                    result.append(rect)
                    continue
                }
            }
            pending.append(contentsOf: children(element, deadline).prefix(max(0, 400 - pending.count)))
        }
        return result
    }

    private func value(_ element: AXUIElement, _ attribute: String, _ deadline: Date) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.01)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func text(_ element: AXUIElement, _ attribute: String, _ deadline: Date) -> String? {
        value(element, attribute, deadline) as? String
    }
    private func children(_ element: AXUIElement, _ deadline: Date) -> [AXUIElement] {
        value(element, kAXChildrenAttribute, deadline) as? [AXUIElement] ?? []
    }
    private func bounds(_ element: AXUIElement, _ deadline: Date) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute, deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute, deadline), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func show(_ rectangles: [CGRect]) {
        expiry?.cancel()
        while panels.count > rectangles.count { panels.removeLast().orderOut(nil) }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        for (index, rect) in rectangles.enumerated() {
            if index == panels.count {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear
                panel.ignoresMouseEvents = true; panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                panel.level = .screenSaver
                panel.contentView = FocusBlurView()
                panels.append(panel)
            }
            let panel = panels[index]
            panel.setFrame(FocusBlurPolicy.appKitFrame(rect, primaryDisplayHeight: height), display: true)
            panel.orderFrontRegardless()
        }
        // A stalled scanner can never leave old masks over unrelated content.
        let expiry = DispatchWorkItem { [weak self] in self?.clear() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: expiry)
    }

    private func clear() {
        expiry?.cancel(); expiry = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

/// Keep the source recognisable. The restriction cue is an outline/badge, not a dark fill.
private final class FocusBlurView: NSView {
    private let effect = NSVisualEffectView()
    private let badge = NSTextField(labelWithString: "Not allowed")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.55).cgColor
        effect.blendingMode = .behindWindow
        effect.material = .underWindowBackground
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        effect.alphaValue = 0.64
        addSubview(effect)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .systemRed
        badge.alignment = .center
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.white.withAlphaComponent(0.78)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.masksToBounds = true
        addSubview(badge)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        effect.frame = bounds
        badge.isHidden = bounds.height < 70 || bounds.width < 110
        badge.frame = CGRect(x: (bounds.width - 82) / 2, y: 8, width: 82, height: 19)
    }
}
