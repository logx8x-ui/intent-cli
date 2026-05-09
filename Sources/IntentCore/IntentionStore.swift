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

    public init(
        active: Bool,
        allowedWebsites: [String],
        blockTabSwitching: Bool,
        blockNavigation: Bool,
        blockNewTabs: Bool
    ) {
        self.active = active
        self.allowedWebsites = allowedWebsites
        self.blockTabSwitching = blockTabSwitching
        self.blockNavigation = blockNavigation
        self.blockNewTabs = blockNewTabs
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
        try write(.init(active: false, allowedWebsites: [], blockTabSwitching: false, blockNavigation: false, blockNewTabs: false))
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("browser-rules.json")
    }
}
