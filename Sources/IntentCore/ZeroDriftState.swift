import Foundation

public struct ZeroDriftState: Codable, Equatable {
    public let startedAt: Date
    public let endsAt: Date

    public init(startedAt: Date, endsAt: Date) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        endsAt > date
    }
}

public enum ZeroDriftTiming {
    public static func durationEndDate(
        from start: Date = Date(),
        days: Int,
        hours: Int,
        minutes: Int
    ) -> Date? {
        let totalMinutes = max(0, days) * 24 * 60 + max(0, hours) * 60 + max(0, minutes)
        guard totalMinutes > 0 else { return nil }
        return start.addingTimeInterval(TimeInterval(totalMinutes * 60))
    }

    public static func nextEndDate(
        matching time: Date,
        after start: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(
            after: start,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

public final class ZeroDriftStateStore {
    public let fileURL: URL

    public init(fileURL: URL = ZeroDriftStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load(now: Date = Date()) throws -> ZeroDriftState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let state = try JSONDecoder().decode(ZeroDriftState.self, from: Data(contentsOf: fileURL))
        guard state.isActive(at: now) else {
            try clear()
            return nil
        }
        return state
    }

    public func save(_ state: ZeroDriftState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("zero-drift.json")
    }
}
