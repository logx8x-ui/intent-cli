import Foundation

public final class IntentionStore {
    public let fileURL: URL

    public init(fileURL: URL = IntentionStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Intention] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let defaults = DefaultIntentions.make()
            try save(defaults)
            return defaults
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Intention].self, from: data)
    }

    public func save(_ intentions: [Intention]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(intentions)
        try data.write(to: fileURL, options: [.atomic])
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("intentions.json")
    }
}

public struct ActiveBrowserRules: Codable, Equatable {
    public var active: Bool
    public var allowedWebsites: [String]
    public var blockTabSwitching: Bool
    public var blockNavigation: Bool
    public var blockNewTabs: Bool
    public var allowGoogleSearchTabs: Bool

    public init(
        active: Bool,
        allowedWebsites: [String],
        blockTabSwitching: Bool,
        blockNavigation: Bool,
        blockNewTabs: Bool,
        allowGoogleSearchTabs: Bool = false
    ) {
        self.active = active
        self.allowedWebsites = allowedWebsites
        self.blockTabSwitching = blockTabSwitching
        self.blockNavigation = blockNavigation
        self.blockNewTabs = blockNewTabs
        self.allowGoogleSearchTabs = allowGoogleSearchTabs
    }

    enum CodingKeys: String, CodingKey {
        case active
        case allowedWebsites
        case blockTabSwitching
        case blockNavigation
        case blockNewTabs
        case allowGoogleSearchTabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        allowedWebsites = try container.decodeIfPresent([String].self, forKey: .allowedWebsites) ?? []
        blockTabSwitching = try container.decodeIfPresent(Bool.self, forKey: .blockTabSwitching) ?? false
        blockNavigation = try container.decodeIfPresent(Bool.self, forKey: .blockNavigation) ?? false
        blockNewTabs = try container.decodeIfPresent(Bool.self, forKey: .blockNewTabs) ?? false
        allowGoogleSearchTabs = try container.decodeIfPresent(Bool.self, forKey: .allowGoogleSearchTabs) ?? false
    }
}

public final class ActiveBrowserRulesStore {
    public let fileURL: URL

    public init(fileURL: URL = ActiveBrowserRulesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func write(_ rules: ActiveBrowserRules) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(rules)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func clear() throws {
        try write(.init(active: false, allowedWebsites: [], blockTabSwitching: false, blockNavigation: false, blockNewTabs: false, allowGoogleSearchTabs: false))
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-rules.json")
    }
}

public struct BrowserGuardHeartbeat: Codable, Equatable {
    public var lastSeenAt: Date

    public init(lastSeenAt: Date) {
        self.lastSeenAt = lastSeenAt
    }
}

public struct BrowserGuardState: Codable, Equatable {
    public var enabled: Bool
    public var updatedAt: Date

    public init(enabled: Bool, updatedAt: Date = Date()) {
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

public final class BrowserGuardStateStore {
    public let fileURL: URL

    public init(fileURL: URL = BrowserGuardStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func write(enabled: Bool, date: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(BrowserGuardState(enabled: enabled, updatedAt: date))
        try data.write(to: fileURL, options: [.atomic])
    }

    public func isEnabled() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(BrowserGuardState.self, from: data) else {
            return true
        }
        return state.enabled
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-guard-state.json")
    }
}

public final class BrowserGuardHeartbeatStore {
    public let fileURL: URL

    public init(fileURL: URL = BrowserGuardHeartbeatStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func write(date: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(BrowserGuardHeartbeat(lastSeenAt: date))
        try data.write(to: fileURL, options: [.atomic])
    }

    public func lastSeenAt() -> Date? {
        guard let data = try? Data(contentsOf: fileURL),
              let heartbeat = try? JSONDecoder().decode(BrowserGuardHeartbeat.self, from: data) else {
            return nil
        }
        return heartbeat.lastSeenAt
    }

    public func isFresh(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastSeenAt = lastSeenAt() else {
            return false
        }
        return now.timeIntervalSince(lastSeenAt) <= maxAge
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-guard-heartbeat.json")
    }
}
