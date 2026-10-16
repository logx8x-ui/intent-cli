import AppKit
import ApplicationServices
import IntentCore

/// Presentation evidence only. A Mission Control tile never grants permission
/// to use a window: native/browser enforcement retains its exact identities.
public enum MissionControlOutline {
    public enum Status: String { case complete, partial, unavailable }
    public struct Window: Equatable {
        public let id: UInt32
        public let pid: Int32
        public let launched: TimeInterval
        public let bundle: String
        public let title: String
        public let selected: Bool
        /// Nil means the whole native window; a number means only these tabs.
        public let selectedTabCount: Int?
        public init(id: UInt32, pid: Int32, launched: TimeInterval, bundle: String,
                    title: String, selected: Bool, selectedTabCount: Int? = nil) {
            self.id = id; self.pid = pid; self.launched = launched; self.bundle = bundle
            self.title = title; self.selected = selected; self.selectedTabCount = selectedTabCount
        }
    }
    public struct Tile: Equatable {
        public let labels: [String]
        public let frame: CGRect
        /// Only an explicit native app-bundle URL, never title/app-name inference.
        public let representedBundle: String?
        public init(labels: [String], frame: CGRect, representedBundle: String? = nil) {
            self.labels = labels; self.frame = frame; self.representedBundle = representedBundle
        }
    }
    public struct Scan {
        public let status: Status
        public let present: Bool
        public let dockIdentity: String
        public let tiles: [Tile]
        public let visitedCount: Int
        public init(status: Status, present: Bool, dockIdentity: String, tiles: [Tile], visitedCount: Int = 0) {
            self.status = status; self.present = present; self.dockIdentity = dockIdentity
            self.tiles = tiles; self.visitedCount = visitedCount
        }
    }
    public struct Region: Equatable {
        public let window: Window
        public let frame: CGRect
        public var badge: String? {
            window.selectedTabCount.map { "\($0) selected tab\($0 == 1 ? "" : "s")" }
        }
    }
    public struct Resolution {
        public let regions: [Region]
        public let unresolvedCount: Int
    }

    private static func candidates(for tile: Tile, windows: [Window]) -> [Window] {
        windows.filter { window in
            !window.title.isEmpty && tile.labels.contains(window.title)
                && (tile.representedBundle == nil || tile.representedBundle == window.bundle)
        }
    }
    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 4 && frame.height > 4
    }
    private static func uniqueTiles(_ tiles: [Tile]) -> [Tile] {
        var result: [Tile] = []
        for tile in tiles where valid(tile.frame) {
            // AX occasionally exposes the same tile through two subtrees.
            if !result.contains(tile) { result.append(tile) }
        }
        return result
    }
    private static func resolve(_ tiles: [Tile], windows: [Window]) -> [Region] {
        let matches = uniqueTiles(tiles).map { ($0, candidates(for: $0, windows: windows)) }
        return matches.compactMap { tile, candidates in
            guard candidates.count == 1, let window = candidates.first, window.selected,
                  window.id > 0, window.pid > 0, window.launched.isFinite, window.launched > 0,
                  window.selectedTabCount.map({ $0 > 0 }) ?? true,
                  matches.filter({ $0.1.contains(window) }).count == 1 else { return nil }
            // Draw the actual thumbnail contour. Scaling a 28-point tab strip
            // into a tiny thumbnail made the previous green mark disappear.
            return Region(window: window, frame: tile.frame)
        }
    }
    public static func map(_ scan: Scan, windows: [Window]) -> Resolution {
        guard scan.present else { return .init(regions: [], unresolvedCount: 0) }
        let regions = resolve(scan.tiles, windows: windows)
        return .init(regions: regions, unresolvedCount: max(0, windows.filter(\.selected).count - regions.count))
    }

    /// A short partial read cannot erase a verified mark, but it cannot extend
    /// that mark indefinitely either. Selection/window changes, Dock restart,
    /// leaving Mission Control or contradictory tile evidence clear it at once.
    public struct Continuity {
        public static let maximumAge: TimeInterval = 0.9
        private var revision = -1
        private var dockIdentity = ""
        private var windows: [Window] = []
        private var retained: [(region: Region, verifiedAt: TimeInterval)] = []
        public init() {}
        public mutating func update(_ scan: Scan, windows: [Window], revision: Int, now: TimeInterval) -> Resolution {
            if self.revision != revision || self.dockIdentity != scan.dockIdentity || self.windows != windows || !scan.present {
                retained = []
            }
            self.revision = revision; self.dockIdentity = scan.dockIdentity; self.windows = windows
            guard scan.present else { return .init(regions: [], unresolvedCount: 0) }
            let current = MissionControlOutline.map(scan, windows: windows)
            let tiles = MissionControlOutline.uniqueTiles(scan.tiles)
            if scan.status == .complete { retained = [] }
            retained.removeAll { old in
                guard now >= old.verifiedAt, now - old.verifiedAt <= Self.maximumAge else { return true }
                let related = tiles.filter { tile in
                    let overlap = tile.frame.intersection(old.region.frame)
                    let substantialOverlap = !overlap.isNull && overlap.width * overlap.height
                        > old.region.frame.width * old.region.frame.height * 0.6
                    return substantialOverlap || MissionControlOutline.candidates(for: tile, windows: windows).contains(old.region.window)
                }
                // Any current observation of this identity or its prior tile
                // rectangle must uniquely agree. This includes duplicate titles.
                return !related.isEmpty && !current.regions.contains(where: { $0.window == old.region.window })
            }
            for region in current.regions {
                retained.removeAll { $0.region.window.id == region.window.id }
                retained.append((region, now))
            }
            let regions = retained.map(\.region)
            return .init(regions: regions, unresolvedCount: max(0, windows.filter(\.selected).count - regions.count))
        }
    }
}

/// Called only on WorkspaceOutlineController's serial discovery queue. It has
/// a total deadline, an individual IPC timeout and a node budget; no AX read is
/// permitted on the input tap or main/render queue.
enum MissionControlOutlineScanner {
    static func scan(overlayVisible: Bool, maximumDuration: TimeInterval = 0.25,
                     maximumNodes: Int = 1_500) -> MissionControlOutline.Scan {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let launched = dock.launchDate else {
            return .init(status: .unavailable, present: overlayVisible, dockIdentity: "", tiles: [])
        }
        let identity = "\(dock.processIdentifier):\(launched.timeIntervalSinceReferenceDate)"
        let deadline = ProcessInfo.processInfo.systemUptime + maximumDuration
        var partial = false, visited = 0
        func hasTime() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard hasTime() else { partial = true; return nil }
            AXUIElementSetMessagingTimeout(element, 0.008)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            if error == .success { return result }
            if error != .attributeUnsupported && error != .noValue { partial = true }
            return nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var roots = children(app)
        var root: AXUIElement?
        // Find the root before walking its contents. Dock's ordinary icon list
        // may precede mc; traversing that list first exhausts the useful budget.
        // One wrapper level is tolerated without exploring arbitrary Dock UI.
        for depth in 0..<2 where root == nil && hasTime() {
            var wrappers: [AXUIElement] = []
            for element in roots.prefix(64) where hasTime() {
                visited += 1
                let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
                if identifier == "mc" || identifier == "mc.windows" { root = element; break }
                if depth == 0 && !identifier.hasPrefix("mc.spaces") { wrappers.append(element) }
            }
            if roots.count > 64 { partial = true }
            if root == nil && depth == 0 {
                roots = wrappers.flatMap { children($0) }
            }
        }
        guard let root else {
            return .init(status: .unavailable, present: overlayVisible, dockIdentity: identity,
                         tiles: [], visitedCount: visited)
        }
        var pending = [(root, false)]
        var index = 0, tiles: [MissionControlOutline.Tile] = []
        while index < pending.count && visited < maximumNodes && hasTime() {
            let (element, inWindows) = pending[index]; index += 1; visited += 1
            let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
            if identifier.hasPrefix("mc.spaces") { continue }
            let isWindows = inWindows || identifier == "mc.windows"
            let role = value(element, kAXRoleAttribute) as? String
            if isWindows && role == kAXButtonRole {
                let labels = [value(element, kAXTitleAttribute) as? String,
                              value(element, kAXDescriptionAttribute) as? String].compactMap { $0 }.filter { !$0.isEmpty }
                if let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                   let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                       AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                        let url = value(element, kAXURLAttribute) as? URL
                        let bundle = url.flatMap(ApplicationBundleIdentifierResolver.resolve(from:))
                        tiles.append(.init(labels: labels, frame: CGRect(origin: point, size: dimensions), representedBundle: bundle))
                    } else { partial = true }
                } else { partial = true }
                // Child title/image controls repeat the tile's label and must
                // not become a second candidate with a tiny label-sized frame.
                continue
            }
            let next = children(element)
            let available = max(0, maximumNodes - pending.count)
            if next.count > available { partial = true }
            pending.append(contentsOf: next.prefix(available).map { ($0, isWindows) })
        }
        if index < pending.count || !hasTime() { partial = true }
        let status: MissionControlOutline.Status = partial ? .partial : .complete
        return .init(status: status, present: true, dockIdentity: identity,
                     tiles: tiles, visitedCount: visited)
    }
}
