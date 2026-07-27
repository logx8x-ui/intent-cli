import Foundation

public struct GraphPoint: Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = GraphPoint(x: 0, y: 0)

    public static func defaultPosition(for id: String) -> GraphPoint {
        switch id {
        case "imessages":
            return .init(x: -430, y: -210)
        case "instagram-replies":
            return .init(x: -330, y: 230)
        case "emails":
            return .init(x: 320, y: 230)
        case "data-science":
            return .init(x: 410, y: -210)
        default:
            let seed = id.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { value, byte in
                (value ^ UInt64(byte)) &* 1_099_511_628_211
            }
            let angle = Double(seed % 360) * .pi / 180
            let radius = 260 + Double((seed >> 8) % 220)
            return .init(x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }
}

public enum BrowserApplication {
    public static let bundleIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]

    public static func isBrowser(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }
}

public enum RestrictionKind: String, Codable, CaseIterable, Equatable {
    case allowBrowserSearches
    case dontStartUp
    case coolDown
    case timer

    public var displayName: String {
        switch self {
        case .allowBrowserSearches:
            return "Allow tab creation for browser searches"
        case .dontStartUp:
            return "Don't start up"
        case .coolDown:
            return "Cooldown"
        case .timer:
            return "Timer"
        }
    }
}

public enum TimerDisplayPosition: String, Codable, CaseIterable, Equatable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var displayName: String {
        switch self {
        case .topLeading: "Top left"
        case .top: "Top"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }
}

public struct RestrictionNode: Identifiable, Codable, Equatable {
    public var id: String
    public var kind: RestrictionKind
    public var position: GraphPoint
    public var excludedResourceIDs: [String]
    public var durationMinutes: Int?
    public var showsRemainingTime: Bool?
    public var timerDisplayPosition: TimerDisplayPosition?
    public var locksSessionUntilTimerEnds: Bool?

    public init(
        id: String = UUID().uuidString,
        kind: RestrictionKind,
        position: GraphPoint,
        excludedResourceIDs: [String] = [],
        durationMinutes: Int? = nil,
        showsRemainingTime: Bool? = nil,
        timerDisplayPosition: TimerDisplayPosition? = nil,
        locksSessionUntilTimerEnds: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.excludedResourceIDs = excludedResourceIDs
        self.durationMinutes = durationMinutes
        self.showsRemainingTime = showsRemainingTime
        self.timerDisplayPosition = timerDisplayPosition
        self.locksSessionUntilTimerEnds = locksSessionUntilTimerEnds
    }
}

public struct FrictionNode: Identifiable, Codable, Equatable {
    public var id: String
    public var friction: Friction
    public var position: GraphPoint

    public init(
        id: String = UUID().uuidString,
        friction: Friction,
        position: GraphPoint
    ) {
        self.id = id
        self.friction = friction
        self.position = position
    }
}

public extension AllowedApp {
    var resourceID: String { "app:\(bundleIdentifier)" }
    var isBrowser: Bool { BrowserApplication.isBrowser(bundleIdentifier) }
}

public extension AllowedWebsite {
    var resourceID: String {
        "website:\(browserBundleIdentifier ?? "unassigned"):\(value)"
    }

    var startupURL: String {
        value.contains("://") ? value : "https://\(value)"
    }
}

public extension Intention {
    var browserSearchesAllowed: Bool {
        restrictionNodes.contains { $0.kind == .allowBrowserSearches }
    }

    var dontStartResourceIDs: Set<String> {
        Set(
            restrictionNodes
                .filter { $0.kind == .dontStartUp }
                .flatMap(\.excludedResourceIDs)
        )
    }

    var coolDownMinutes: Int? {
        effectiveCooldownRestriction.map { max(1, $0.durationMinutes ?? 30) }
    }

    var timerMinutes: Int? {
        effectiveTimerRestriction.map { max(1, $0.durationMinutes ?? 25) }
    }

    var effectiveCooldownRestriction: RestrictionNode? {
        restrictionNodes
            .filter { $0.kind == .coolDown }
            .max { max(1, $0.durationMinutes ?? 30) < max(1, $1.durationMinutes ?? 30) }
    }

    var effectiveTimerRestriction: RestrictionNode? {
        restrictionNodes
            .filter { $0.kind == .timer }
            .min { max(1, $0.durationMinutes ?? 25) < max(1, $1.durationMinutes ?? 25) }
    }

    var showsCooldownRemainingTime: Bool {
        effectiveCooldownRestriction?.showsRemainingTime ?? true
    }

    var timerLocksManualFinish: Bool {
        guard let restriction = effectiveTimerRestriction else { return false }
        return restriction.locksSessionUntilTimerEnds ?? true
    }

    var orderedFrictionNodes: [FrictionNode] {
        frictionNodes.sorted {
            if $0.position.y == $1.position.y {
                return $0.id < $1.id
            }
            return $0.position.y < $1.position.y
        }
    }

    func websites(for browserBundleIdentifier: String) -> [AllowedWebsite] {
        allowedWebsites.filter { $0.browserBundleIdentifier == browserBundleIdentifier }
    }

    var allResourceIDs: [String] {
        allowedApps.map(\.resourceID) + allowedWebsites.map(\.resourceID)
    }
}

public enum GraphLayoutMigration {
    public static func arrangeLegacyCollisions(_ intentions: inout [Intention]) {
        var occupied: [GraphPoint] = []

        for index in intentions.indices {
            let original = intentions[index].graphPosition
            var target = original
            if isCrowded(target, among: occupied) || distance(target, .zero) < 235 {
                target = firstAvailablePosition(seed: index, occupied: occupied)
            }

            if target != original {
                let deltaX = target.x - original.x
                let deltaY = target.y - original.y
                intentions[index].graphPosition = target
                intentions[index].restrictionNodes = intentions[index].restrictionNodes.map { node in
                    var moved = node
                    moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
                    return moved
                }
                intentions[index].frictionNodes = intentions[index].frictionNodes.map { node in
                    var moved = node
                    moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
                    return moved
                }
            }

            intentions[index].graphModelVersion = 3
            occupied.append(intentions[index].graphPosition)
        }
    }

    private static func firstAvailablePosition(seed: Int, occupied: [GraphPoint]) -> GraphPoint {
        for attempt in 0..<160 {
            let step = seed + attempt
            let angle = Double(step) * 2.399963229728653
            let radius = 330 + Double(step / 8) * 190
            let candidate = GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if !isCrowded(candidate, among: occupied) && distance(candidate, .zero) >= 235 {
                return candidate
            }
        }
        return .init(x: Double(seed) * 260, y: 520)
    }

    private static func isCrowded(_ point: GraphPoint, among occupied: [GraphPoint]) -> Bool {
        occupied.contains { distance(point, $0) < 235 }
    }

    private static func distance(_ lhs: GraphPoint, _ rhs: GraphPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
