import Foundation

public final class IntentionCooldownStore {
    public let fileURL: URL

    public init(fileURL: URL = IntentionCooldownStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func nextAllowedDate(for intentionID: String, now: Date = Date()) throws -> Date? {
        let records = try load()
        guard let date = records[intentionID], date > now else { return nil }
        return date
    }

    @discardableResult
    public func begin(
        intentionID: String,
        minutes: Int,
        now: Date = Date()
    ) throws -> Date {
        var records = try load()
        let nextAllowedDate = now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        records[intentionID] = nextAllowedDate
        try save(records)
        return nextAllowedDate
    }

    public func clear(intentionID: String) throws {
        var records = try load()
        records.removeValue(forKey: intentionID)
        try save(records)
    }

    public func activeCooldowns(now: Date = Date()) throws -> [String: Date] {
        let records = try load()
        let active = records.filter { $0.value > now }
        if active.count != records.count {
            try save(active)
        }
        return active
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("cooldowns.json")
    }

    private func load() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: Date].self, from: data)
    }

    private func save(_ records: [String: Date]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
