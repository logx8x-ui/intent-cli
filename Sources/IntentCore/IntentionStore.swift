import Foundation

public final class IntentionStore {
    public let fileURL: URL
    public private(set) var didRecoverFromBackup = false

    private var recoveryFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("last-good.json")
    }

    public init(fileURL: URL = IntentionStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Intention] {
        didRecoverFromBackup = false

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let emptyDesktop: [Intention] = []
            try save(emptyDesktop)
            return emptyDesktop
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if data.range(of: Data("\"graphPosition\"".utf8)) == nil {
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("pre-graph-backup.json")
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    try? FileManager.default.copyItem(at: fileURL, to: backupURL)
                }
            }
            return try decode(data)
        } catch let primaryError {
            guard FileManager.default.fileExists(atPath: recoveryFileURL.path) else {
                throw primaryError
            }

            do {
                let recoveryData = try Data(contentsOf: recoveryFileURL)
                let recoveredIntentions = try decode(recoveryData)
                try recoveryData.write(to: fileURL, options: [.atomic])
                didRecoverFromBackup = true
                return recoveredIntentions
            } catch {
                throw primaryError
            }
        }
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
        try? data.write(to: recoveryFileURL, options: [.atomic])
    }

    private func decode(_ data: Data) throws -> [Intention] {
        var intentions = try JSONDecoder().decode([Intention].self, from: data)
        if intentions.contains(where: { $0.graphModelVersion < 3 }) {
            GraphLayoutMigration.arrangeLegacyCollisions(&intentions)
        }
        return intentions
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("intentions.json")
    }
}

public struct ActiveBrowserRules: Codable, Equatable {
    public static let freshnessWindow: TimeInterval = 5

    public var active: Bool
    public var accessMode: IntentionAccessMode
    public var allowedWebsites: [String]
    public var allowedWebsitesByBrowser: [String: [String]]
    public var startupWebsitesByBrowser: [String: [String]]
    public var startupSessionID: String?
    public var blockTabSwitching: Bool
    public var blockNavigation: Bool
    public var blockNewTabs: Bool
    public var allowGoogleSearchTabs: Bool
    public var updatedAt: Date

    public init(
        active: Bool,
        accessMode: IntentionAccessMode = .whitelist,
        allowedWebsites: [String],
        allowedWebsitesByBrowser: [String: [String]] = [:],
        startupWebsitesByBrowser: [String: [String]] = [:],
        startupSessionID: String? = nil,
        blockTabSwitching: Bool,
        blockNavigation: Bool,
        blockNewTabs: Bool,
        allowGoogleSearchTabs: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.active = active
        self.accessMode = accessMode
        self.allowedWebsites = allowedWebsites
        self.allowedWebsitesByBrowser = allowedWebsitesByBrowser
        self.startupWebsitesByBrowser = startupWebsitesByBrowser
        self.startupSessionID = startupSessionID
        self.blockTabSwitching = blockTabSwitching
        self.blockNavigation = blockNavigation
        self.blockNewTabs = blockNewTabs
        self.allowGoogleSearchTabs = allowGoogleSearchTabs
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case active
        case accessMode
        case allowedWebsites
        case allowedWebsitesByBrowser
        case startupWebsitesByBrowser
        case startupSessionID
        case blockTabSwitching
        case blockNavigation
        case blockNewTabs
        case allowGoogleSearchTabs
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        accessMode = try container.decodeIfPresent(IntentionAccessMode.self, forKey: .accessMode) ?? .whitelist
        allowedWebsites = try container.decodeIfPresent([String].self, forKey: .allowedWebsites) ?? []
        allowedWebsitesByBrowser = try container.decodeIfPresent([String: [String]].self, forKey: .allowedWebsitesByBrowser) ?? [:]
        startupWebsitesByBrowser = try container.decodeIfPresent([String: [String]].self, forKey: .startupWebsitesByBrowser) ?? [:]
        startupSessionID = try container.decodeIfPresent(String.self, forKey: .startupSessionID)
        blockTabSwitching = try container.decodeIfPresent(Bool.self, forKey: .blockTabSwitching) ?? false
        blockNavigation = try container.decodeIfPresent(Bool.self, forKey: .blockNavigation) ?? false
        blockNewTabs = try container.decodeIfPresent(Bool.self, forKey: .blockNewTabs) ?? false
        allowGoogleSearchTabs = try container.decodeIfPresent(Bool.self, forKey: .allowGoogleSearchTabs) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public func refreshed(at date: Date = Date()) -> ActiveBrowserRules {
        .init(
            active: active,
            accessMode: accessMode,
            allowedWebsites: allowedWebsites,
            allowedWebsitesByBrowser: allowedWebsitesByBrowser,
            startupWebsitesByBrowser: startupWebsitesByBrowser,
            startupSessionID: startupSessionID,
            blockTabSwitching: blockTabSwitching,
            blockNavigation: blockNavigation,
            blockNewTabs: blockNewTabs,
            allowGoogleSearchTabs: allowGoogleSearchTabs,
            updatedAt: date
        )
    }

    public func isFresh(now: Date = Date(), maxAge: TimeInterval = freshnessWindow) -> Bool {
        now.timeIntervalSince(updatedAt) <= maxAge
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

    public static func fileURL(for browserBundleIdentifier: String) -> URL {
        guard browserBundleIdentifier != "org.mozilla.firefox" else {
            return defaultFileURL()
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-guard-state-\(safeFileComponent(browserBundleIdentifier)).json")
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

    public static func fileURL(for browserBundleIdentifier: String) -> URL {
        guard browserBundleIdentifier != "org.mozilla.firefox" else {
            return defaultFileURL()
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-guard-heartbeat-\(safeFileComponent(browserBundleIdentifier)).json")
    }
}

private func safeFileComponent(_ value: String) -> String {
    value.map { character in
        character.isLetter || character.isNumber ? character : "-"
    }.reduce(into: "") { $0.append($1) }
}
