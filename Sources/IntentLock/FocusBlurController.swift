import AppKit
import ApplicationServices
import IntentCore
import CoreImage

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

/// Visual-only panels: no event taps, activation, window mutation, or input interception. Captures stay in memory and exclude our own overlays.
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
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
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
        let sampledAt = Date()
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        scanDetails = [:]
        let rectangles: [CGRect]
        if dockOverlay {
            rectangles = missionControlRegions()
        } else {
            rectangles = tabGuard.blurRegions(frontmostPID: foregroundPID)
        }
        scanDetails["dockOverlay"] = dockOverlay ? 1 : 0
        scanDetails["mappedRegions"] = rectangles.count
        let fingerprint = scanDetails.keys.sorted().map { "\($0)=\(scanDetails[$0]!)" }.joined(separator: ";")
        if fingerprint != lastDiagnostics {
            lastDiagnostics = fingerprint
            let url = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("focus-blur-diagnostics.json")
            if let data = try? JSONSerialization.data(withJSONObject: scanDetails) { try? data.write(to: url, options: .atomic) }
        }
        // Capture only the mapped regions, excluding Intent so the blur never feeds
        // back into itself. No images are persisted or sent to the browser.
        let sourceWindows = windows.compactMap { window -> NSNumber? in
            guard window[kCGWindowOwnerPID as String] as? pid_t != ProcessInfo.processInfo.processIdentifier else { return nil }
            return window[kCGWindowNumber as String] as? NSNumber
        }
        let validRectangles = rectangles.filter(FocusBlurPolicy.valid)
        let images: [CGImage?] = validRectangles.map { rect in
            guard CGPreflightScreenCaptureAccess(),
                  let capture = CGImage(windowListFromArrayScreenBounds: rect, windowArray: sourceWindows as CFArray, imageOption: [.bestResolution]) else { return nil }
            let source = CIImage(cgImage: capture)
            let scale = CGFloat(capture.width) / rect.width
            let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(10, rect.height * 0.18) * scale]).cropped(to: source.extent)
            return imageContext.createCGImage(blurred, from: source.extent)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token), Date().timeIntervalSince(sampledAt) < 0.35,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID else { return }
            self.show(validRectangles, images: images)
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

    private func show(_ rectangles: [CGRect], images: [CGImage?]) {
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
            let frame = FocusBlurPolicy.appKitFrame(rect, primaryDisplayHeight: height)
            let moved = panel.frame != frame
            if moved { panel.setFrame(frame, display: false) }
            (panel.contentView as? FocusBlurView)?.update(images[index], moved: moved)
            if !panel.isVisible { panel.orderFrontRegardless() }
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

/// Untinted source pixels: no border, badge, shadow, or material animation.
private final class FocusBlurView: NSView {
    private let fallback = NSVisualEffectView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // Keep a permission-free fallback; never prompt during enforcement.
        fallback.blendingMode = .behindWindow
        fallback.material = .underWindowBackground
        fallback.state = .active
        fallback.alphaValue = 0.45
        addSubview(fallback)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ image: CGImage?, moved: Bool) {
        // A single failed capture must not flash the material fallback. Never
        // retain an old image after the region moves to different content.
        if image == nil, !moved, layer?.contents != nil { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        fallback.isHidden = image != nil
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        fallback.frame = bounds
    }
}
