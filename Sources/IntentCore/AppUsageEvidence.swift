import Foundation

/// Missing metadata is unknown usage, not evidence that an installed app is popular.
public struct AppUsageEvidence {
    public let bundleIdentifier: String
    public let useCount: Int
    public let lastUsedAt: Date?

    public init(bundleIdentifier: String, useCount: Int, lastUsedAt: Date?) {
        self.bundleIdentifier = bundleIdentifier
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public static func frequentIdentifiers(in evidence: [Self], now: Date = Date()) -> [String] {
        evidence.filter {
            guard $0.useCount >= 3, let lastUsed = $0.lastUsedAt else { return false }
            return lastUsed <= now && lastUsed >= now.addingTimeInterval(-30 * 24 * 60 * 60)
        }.sorted {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt! > $1.lastUsedAt! }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }.prefix(12).map(\.bundleIdentifier)
    }
}
