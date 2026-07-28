import Foundation

public enum CalendarProviderKind: String, Codable, CaseIterable, Equatable {
    case local
    case apple
    case google

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .apple: "Apple Calendar"
        case .google: "Google Calendar"
        }
    }
}

public enum CalendarConnectionStatus: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case permissionDenied
    case restricted
    case configurationMissing
    case offline
    case error
}

public struct CalendarConnectionState: Equatable, Identifiable {
    public var id: CalendarProviderKind { provider }
    public var provider: CalendarProviderKind
    public var status: CalendarConnectionStatus
    public var accountLabel: String?
    public var message: String?
    public var calendars: [ExternalCalendar]
    public var visibleCalendarIDs: Set<String>
    public var writeCalendarID: String?

    public init(
        provider: CalendarProviderKind,
        status: CalendarConnectionStatus = .disconnected,
        accountLabel: String? = nil,
        message: String? = nil,
        calendars: [ExternalCalendar] = [],
        visibleCalendarIDs: Set<String> = [],
        writeCalendarID: String? = nil
    ) {
        self.provider = provider
        self.status = status
        self.accountLabel = accountLabel
        self.message = message
        self.calendars = calendars
        self.visibleCalendarIDs = visibleCalendarIDs
        self.writeCalendarID = writeCalendarID
    }

    public var isConnected: Bool { status == .connected }
}

public struct ExternalCalendar: Identifiable, Codable, Equatable {
    public var id: String
    public var provider: CalendarProviderKind
    public var title: String
    public var accountLabel: String?
    public var allowsModifications: Bool
    public var colorHex: String?

    public init(
        id: String,
        provider: CalendarProviderKind,
        title: String,
        accountLabel: String? = nil,
        allowsModifications: Bool = true,
        colorHex: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.accountLabel = accountLabel
        self.allowsModifications = allowsModifications
        self.colorHex = colorHex
    }
}

public enum ExternalCalendarItemKind: String, Codable, Equatable {
    case event
    case reminder
    case task
}

public struct ExternalCalendarEvent: Identifiable, Codable, Equatable {
    public var id: String
    public var provider: CalendarProviderKind
    public var calendarID: String
    public var title: String
    public var startAt: Date
    public var endAt: Date?
    public var isAllDay: Bool
    public var linkedScheduleID: String?
    public var recurrenceSummary: String?
    public var supportsIntentSync: Bool
    public var kind: ExternalCalendarItemKind
    public var lastModifiedAt: Date?

    public init(
        id: String,
        provider: CalendarProviderKind,
        calendarID: String,
        title: String,
        startAt: Date,
        endAt: Date? = nil,
        isAllDay: Bool = false,
        linkedScheduleID: String? = nil,
        recurrenceSummary: String? = nil,
        supportsIntentSync: Bool = false,
        kind: ExternalCalendarItemKind = .event,
        lastModifiedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.calendarID = calendarID
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.linkedScheduleID = linkedScheduleID
        self.recurrenceSummary = recurrenceSummary
        self.supportsIntentSync = supportsIntentSync
        self.kind = kind
        self.lastModifiedAt = lastModifiedAt
    }

    public func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        if let endAt, endAt > startAt {
            let dayStart = calendar.startOfDay(for: date)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return calendar.isDate(startAt, inSameDayAs: date)
            }
            return startAt < dayEnd && endAt > dayStart
        }
        return calendar.isDate(startAt, inSameDayAs: date)
    }
}

public struct ScheduleSyncMetadata: Codable, Equatable {
    public var provider: CalendarProviderKind
    public var accountID: String?
    public var calendarID: String
    public var externalEventID: String
    public var lastSyncedAt: Date?
    public var lastLocalModifiedAt: Date?
    public var lastExternalModifiedAt: Date?
    public var unlinkOnExternalDelete: Bool

    public init(
        provider: CalendarProviderKind,
        accountID: String? = nil,
        calendarID: String,
        externalEventID: String,
        lastSyncedAt: Date? = nil,
        lastLocalModifiedAt: Date? = nil,
        lastExternalModifiedAt: Date? = nil,
        unlinkOnExternalDelete: Bool = true
    ) {
        self.provider = provider
        self.accountID = accountID
        self.calendarID = calendarID
        self.externalEventID = externalEventID
        self.lastSyncedAt = lastSyncedAt
        self.lastLocalModifiedAt = lastLocalModifiedAt
        self.lastExternalModifiedAt = lastExternalModifiedAt
        self.unlinkOnExternalDelete = unlinkOnExternalDelete
    }
}

public enum CalendarSyncConflictResolution: Equatable {
    case keepLocal
    case keepExternal
    case unchanged
}

public enum CalendarSyncMapper {
    public static let intentURLScheme = "intent"
    public static let scheduleHost = "schedule"

    public static func intentURL(for scheduleID: String) -> URL {
        URL(string: "\(intentURLScheme)://\(scheduleHost)/\(scheduleID)")!
    }

    public static func scheduleID(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == intentURLScheme,
              url.host?.lowercased() == scheduleHost else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    public static func scheduleID(fromNotes notes: String?) -> String? {
        guard let notes else { return nil }
        if let urlMatch = notes.range(of: #"intent://schedule/[A-Za-z0-9._-]+"#, options: .regularExpression) {
            return scheduleID(from: String(notes[urlMatch]))
        }
        return nil
    }

    public static func googlePrivateProperty(scheduleID: String) -> [String: String] {
        ["intentScheduleId": scheduleID]
    }

    public static func deduplicatedEvents(_ events: [ExternalCalendarEvent]) -> [ExternalCalendarEvent] {
        var seen = Set<String>()
        var result: [ExternalCalendarEvent] = []
        for event in events {
            let key = "\(event.provider.rawValue)|\(event.calendarID)|\(event.id)"
            if seen.insert(key).inserted {
                result.append(event)
            }
        }
        return result
    }

    public static func resolveConflict(
        localModified: Date?,
        externalModified: Date?
    ) -> CalendarSyncConflictResolution {
        switch (localModified, externalModified) {
        case (nil, nil):
            return .unchanged
        case (let local?, nil):
            return local.timeIntervalSince1970 > 0 ? .keepLocal : .unchanged
        case (nil, let external?):
            return external.timeIntervalSince1970 > 0 ? .keepExternal : .unchanged
        case (let local?, let external?):
            if abs(local.timeIntervalSince(external)) < 1 {
                return .unchanged
            }
            return local > external ? .keepLocal : .keepExternal
        }
    }

    public static func eventTitle(for intentionName: String) -> String {
        let trimmed = intentionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Intent session" : "Intent: \(trimmed)"
    }

    public static func canConvertRecurrence(_ recurrence: ScheduleRecurrence) -> Bool {
        switch recurrence {
        case .once, .daily, .weekly:
            return true
        }
    }
}

@MainActor
public protocol CalendarProvider: AnyObject {
    var kind: CalendarProviderKind { get }
    var connectionState: CalendarConnectionState { get }

    func connect() async throws
    func disconnect() async
    func refreshCalendars() async throws
    func setVisibleCalendarIDs(_ ids: Set<String>) async
    func setWriteCalendarID(_ id: String?) async
    func fetchEvents(from start: Date, to end: Date) async throws -> [ExternalCalendarEvent]
    func upsertLinkedEvent(
        for schedule: IntentSchedule,
        intentionName: String
    ) async throws -> ScheduleSyncMetadata
    func deleteLinkedEvent(metadata: ScheduleSyncMetadata) async throws
}

public struct CalendarPreferences: Codable, Equatable {
    public var appleVisibleCalendarIDs: [String]
    public var appleWriteCalendarID: String?
    public var googleVisibleCalendarIDs: [String]
    public var googleWriteCalendarID: String?
    public var appleRemindersEnabled: Bool
    public var googleTasksEnabled: Bool

    public init(
        appleVisibleCalendarIDs: [String] = [],
        appleWriteCalendarID: String? = nil,
        googleVisibleCalendarIDs: [String] = [],
        googleWriteCalendarID: String? = nil,
        appleRemindersEnabled: Bool = false,
        googleTasksEnabled: Bool = false
    ) {
        self.appleVisibleCalendarIDs = appleVisibleCalendarIDs
        self.appleWriteCalendarID = appleWriteCalendarID
        self.googleVisibleCalendarIDs = googleVisibleCalendarIDs
        self.googleWriteCalendarID = googleWriteCalendarID
        self.appleRemindersEnabled = appleRemindersEnabled
        self.googleTasksEnabled = googleTasksEnabled
    }
}

public final class CalendarPreferencesStore {
    public let fileURL: URL

    public init(fileURL: URL = CalendarPreferencesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() -> CalendarPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(CalendarPreferences.self, from: data) else {
            return CalendarPreferences()
        }
        return prefs
    }

    public func save(_ preferences: CalendarPreferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: fileURL, options: .atomic)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("calendar-preferences.json")
    }
}

public struct CalendarSyncCoordinator {
    public init() {}

    public func applyExternalChange(
        to schedule: IntentSchedule,
        from event: ExternalCalendarEvent,
        now: Date = Date()
    ) -> IntentSchedule? {
        guard event.linkedScheduleID == schedule.id || schedule.sync?.externalEventID == event.id else {
            return nil
        }
        guard event.supportsIntentSync else {
            return nil
        }

        var updated = schedule
        let resolution = CalendarSyncMapper.resolveConflict(
            localModified: schedule.sync?.lastLocalModifiedAt,
            externalModified: event.lastModifiedAt
        )
        guard resolution == .keepExternal || resolution == .unchanged && event.startAt != schedule.scheduledAt else {
            if resolution == .keepLocal {
                return nil
            }
            return nil
        }

        if event.startAt != schedule.scheduledAt {
            updated.scheduledAt = event.startAt
        }
        if var sync = updated.sync {
            sync.lastExternalModifiedAt = event.lastModifiedAt ?? now
            sync.lastSyncedAt = now
            updated.sync = sync
        }
        return updated
    }

    public func handleExternalDeletion(
        of schedule: IntentSchedule
    ) -> IntentSchedule {
        var updated = schedule
        updated.isEnabled = false
        updated.sync = nil
        return updated
    }

    public func shouldLaunch(from event: ExternalCalendarEvent) -> Bool {
        event.linkedScheduleID != nil && event.supportsIntentSync
    }

    public func mergeVisibleEvents(
        localSchedules: [IntentSchedule],
        intentionNames: [String: String],
        externalEvents: [ExternalCalendarEvent]
    ) -> [SchedulerDisplayItem] {
        var items: [SchedulerDisplayItem] = []

        for schedule in localSchedules {
            let name = intentionNames[schedule.intentionID] ?? "Missing intention"
            items.append(.intentSchedule(schedule, intentionName: name))
        }

        for event in CalendarSyncMapper.deduplicatedEvents(externalEvents) {
            if let linkedID = event.linkedScheduleID,
               localSchedules.contains(where: { $0.id == linkedID }) {
                // The local schedule already represents this linked event.
                continue
            } else if event.kind == .reminder || event.kind == .task {
                items.append(.task(event))
            } else {
                items.append(.external(event))
            }
        }
        return items
    }
}

public enum SchedulerDisplayItem: Identifiable, Equatable {
    case intentSchedule(IntentSchedule, intentionName: String)
    case linkedExternal(ExternalCalendarEvent)
    case external(ExternalCalendarEvent)
    case task(ExternalCalendarEvent)

    public var id: String {
        switch self {
        case .intentSchedule(let schedule, _):
            return "local:\(schedule.id)"
        case .linkedExternal(let event):
            return "linked:\(event.provider.rawValue):\(event.id)"
        case .external(let event):
            return "external:\(event.provider.rawValue):\(event.id)"
        case .task(let event):
            return "task:\(event.provider.rawValue):\(event.id)"
        }
    }

    public func occurs(on date: Date, calendar: Calendar) -> Bool {
        switch self {
        case .intentSchedule(let schedule, _):
            var visible = schedule
            visible.isEnabled = true
            return visible.occurs(on: date, calendar: calendar)
        case .linkedExternal(let event), .external(let event), .task(let event):
            return event.occurs(on: date, calendar: calendar)
        }
    }

    public var sortDate: Date {
        switch self {
        case .intentSchedule(let schedule, _):
            return schedule.scheduledAt
        case .linkedExternal(let event), .external(let event), .task(let event):
            return event.startAt
        }
    }
}

/// In-memory provider used by specs.
@MainActor
public final class FakeCalendarProvider: CalendarProvider {
    public let kind: CalendarProviderKind
    public private(set) var connectionState: CalendarConnectionState
    public var events: [ExternalCalendarEvent]
    public var shouldFailConnect = false
    public var deletedEventIDs: [String] = []

    public init(
        kind: CalendarProviderKind,
        status: CalendarConnectionStatus = .disconnected,
        calendars: [ExternalCalendar] = [],
        events: [ExternalCalendarEvent] = []
    ) {
        self.kind = kind
        self.connectionState = CalendarConnectionState(
            provider: kind,
            status: status,
            calendars: calendars,
            visibleCalendarIDs: Set(calendars.map(\.id)),
            writeCalendarID: calendars.first?.id
        )
        self.events = events
    }

    public func connect() async throws {
        if shouldFailConnect {
            connectionState.status = .permissionDenied
            connectionState.message = "Calendar access was denied."
            throw CalendarProviderError.permissionDenied
        }
        connectionState.status = .connected
        connectionState.message = nil
    }

    public func disconnect() async {
        connectionState.status = .disconnected
        connectionState.accountLabel = nil
        connectionState.message = nil
        events.removeAll { $0.linkedScheduleID != nil }
    }

    public func refreshCalendars() async throws {}

    public func setVisibleCalendarIDs(_ ids: Set<String>) async {
        connectionState.visibleCalendarIDs = ids
    }

    public func setWriteCalendarID(_ id: String?) async {
        connectionState.writeCalendarID = id
    }

    public func fetchEvents(from start: Date, to end: Date) async throws -> [ExternalCalendarEvent] {
        events.filter { $0.startAt >= start && $0.startAt <= end }
    }

    public func upsertLinkedEvent(
        for schedule: IntentSchedule,
        intentionName: String
    ) async throws -> ScheduleSyncMetadata {
        guard connectionState.isConnected,
              let calendarID = connectionState.writeCalendarID else {
            throw CalendarProviderError.notConnected
        }
        let eventID = schedule.sync?.externalEventID ?? UUID().uuidString
        let event = ExternalCalendarEvent(
            id: eventID,
            provider: kind,
            calendarID: calendarID,
            title: CalendarSyncMapper.eventTitle(for: intentionName),
            startAt: schedule.scheduledAt,
            endAt: schedule.scheduledAt.addingTimeInterval(3_600),
            linkedScheduleID: schedule.id,
            supportsIntentSync: true,
            lastModifiedAt: Date()
        )
        if let index = events.firstIndex(where: { $0.id == eventID }) {
            events[index] = event
        } else {
            events.append(event)
        }
        return ScheduleSyncMetadata(
            provider: kind,
            calendarID: calendarID,
            externalEventID: eventID,
            lastSyncedAt: Date(),
            lastLocalModifiedAt: Date()
        )
    }

    public func deleteLinkedEvent(metadata: ScheduleSyncMetadata) async throws {
        deletedEventIDs.append(metadata.externalEventID)
        events.removeAll { $0.id == metadata.externalEventID }
    }
}

public enum CalendarProviderError: LocalizedError, Equatable {
    case permissionDenied
    case restricted
    case notConnected
    case configurationMissing
    case offline
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access was denied. You can enable it later in System Settings."
        case .restricted:
            return "Calendar access is restricted on this Mac."
        case .notConnected:
            return "This calendar account is not connected."
        case .configurationMissing:
            return "Google Calendar is not configured for this build yet."
        case .offline:
            return "Calendar sync needs a network connection."
        case .underlying(let message):
            return message
        }
    }
}
