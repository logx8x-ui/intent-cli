import Foundation

public enum ScheduleRecurrence: String, Codable, CaseIterable, Equatable {
    case once
    case daily
    case weekly

    public var displayName: String {
        switch self {
        case .once: "Once"
        case .daily: "Every day"
        case .weekly: "Selected days"
        }
    }
}

public enum ScheduleWeekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    public var id: Int { rawValue }

    public var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    public static let mondayFirst: [ScheduleWeekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday
    ]
}

public struct IntentSchedule: Identifiable, Codable, Equatable {
    public var id: String
    public var intentionID: String
    public var recurrence: ScheduleRecurrence
    public var scheduledAt: Date
    public var weekdays: [Int]
    public var isEnabled: Bool
    public var lastTriggeredKey: String?
    public var sync: ScheduleSyncMetadata?
    public var lastLocalModifiedAt: Date?

    public init(
        id: String = UUID().uuidString,
        intentionID: String,
        recurrence: ScheduleRecurrence = .once,
        scheduledAt: Date,
        weekdays: [Int] = [],
        isEnabled: Bool = true,
        lastTriggeredKey: String? = nil,
        sync: ScheduleSyncMetadata? = nil,
        lastLocalModifiedAt: Date? = nil
    ) {
        self.id = id
        self.intentionID = intentionID
        self.recurrence = recurrence
        self.scheduledAt = scheduledAt
        self.weekdays = Array(Set(weekdays)).sorted()
        self.isEnabled = isEnabled
        self.lastTriggeredKey = lastTriggeredKey
        self.sync = sync
        self.lastLocalModifiedAt = lastLocalModifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, intentionID, recurrence, scheduledAt, weekdays
        case isEnabled, lastTriggeredKey, sync, lastLocalModifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        intentionID = try container.decode(String.self, forKey: .intentionID)
        recurrence = try container.decode(ScheduleRecurrence.self, forKey: .recurrence)
        scheduledAt = try container.decode(Date.self, forKey: .scheduledAt)
        weekdays = Array(Set(try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? [])).sorted()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastTriggeredKey = try container.decodeIfPresent(String.self, forKey: .lastTriggeredKey)
        sync = try container.decodeIfPresent(ScheduleSyncMetadata.self, forKey: .sync)
        lastLocalModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastLocalModifiedAt)
    }

    public var isSynced: Bool { sync != nil }

    public func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        switch recurrence {
        case .once:
            return calendar.isDate(scheduledAt, inSameDayAs: date)
        case .daily:
            return true
        case .weekly:
            let weekday = calendar.component(.weekday, from: date)
            return weekdays.contains(weekday)
        }
    }

    public func triggerKeyIfDue(at date: Date, calendar: Calendar = .current) -> String? {
        guard occurs(on: date, calendar: calendar) else { return nil }
        let scheduledTime = calendar.dateComponents([.hour, .minute], from: scheduledAt)
        let currentTime = calendar.dateComponents([.hour, .minute], from: date)
        guard scheduledTime.hour == currentTime.hour,
              scheduledTime.minute == currentTime.minute else {
            return nil
        }

        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let key = [day.year, day.month, day.day, currentTime.hour, currentTime.minute]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
        return "\(id):\(key)"
    }

    public func nextOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        if recurrence == .once {
            return scheduledAt > reference ? scheduledAt : nil
        }

        let time = calendar.dateComponents([.hour, .minute], from: scheduledAt)
        let startOfToday = calendar.startOfDay(for: reference)
        for offset in 0...14 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  occurs(on: day, calendar: calendar) else {
                continue
            }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = time.hour
            components.minute = time.minute
            guard let candidate = calendar.date(from: components), candidate > reference else {
                continue
            }
            return candidate
        }
        return nil
    }
}

public final class IntentScheduleStore {
    public let fileURL: URL

    public init(fileURL: URL = IntentScheduleStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> [IntentSchedule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try save([])
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([IntentSchedule].self, from: data)
    }

    public func save(_ schedules: [IntentSchedule]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(schedules).write(to: fileURL, options: .atomic)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("schedules.json")
    }
}
