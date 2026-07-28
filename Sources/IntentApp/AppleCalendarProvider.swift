import EventKit
import Foundation
import IntentCore

@MainActor
final class AppleCalendarProvider: CalendarProvider {
    let kind: CalendarProviderKind = .apple
    private(set) var connectionState: CalendarConnectionState

    private let store: EKEventStore
    private let reminderStore: EKEventStore
    private var preferences: CalendarPreferences
    private let onPreferencesChange: (CalendarPreferences) -> Void
    private var didRequestAccess = false

    init(
        preferences: CalendarPreferences,
        onPreferencesChange: @escaping (CalendarPreferences) -> Void,
        eventStore: EKEventStore = EKEventStore()
    ) {
        self.preferences = preferences
        self.onPreferencesChange = onPreferencesChange
        self.store = eventStore
        self.reminderStore = eventStore
        self.connectionState = CalendarConnectionState(provider: .apple)
        refreshAuthorizationState()
    }

    func connect() async throws {
        connectionState.status = .connecting
        connectionState.message = nil
        didRequestAccess = true

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToEvents()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { ok, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
        }

        guard granted else {
            connectionState.status = .permissionDenied
            connectionState.message = CalendarProviderError.permissionDenied.errorDescription
            throw CalendarProviderError.permissionDenied
        }

        try await refreshCalendars()
        connectionState.status = .connected
    }

    func disconnect() async {
        preferences.appleVisibleCalendarIDs = []
        preferences.appleWriteCalendarID = nil
        preferences.appleRemindersEnabled = false
        onPreferencesChange(preferences)
        connectionState = CalendarConnectionState(
            provider: .apple,
            status: .disconnected,
            message: "Apple Calendar stays available locally. Intent schedules were not deleted."
        )
    }

    func refreshCalendars() async throws {
        refreshAuthorizationState()
        guard connectionState.status == .connected || store.authorizationStatusCompatible == .fullAccess else {
            return
        }

        let calendars = store.calendars(for: .event).map { calendar in
            ExternalCalendar(
                id: calendar.calendarIdentifier,
                provider: .apple,
                title: calendar.title,
                accountLabel: calendar.source.title,
                allowsModifications: !calendar.isImmutable,
                colorHex: nil
            )
        }
        connectionState.calendars = calendars
        connectionState.status = .connected
        connectionState.accountLabel = calendars.first?.accountLabel

        if preferences.appleVisibleCalendarIDs.isEmpty {
            preferences.appleVisibleCalendarIDs = calendars.map(\.id)
        }
        if preferences.appleWriteCalendarID == nil {
            preferences.appleWriteCalendarID = store.defaultCalendarForNewEvents?.calendarIdentifier
                ?? calendars.first(where: \.allowsModifications)?.id
        }
        connectionState.visibleCalendarIDs = Set(preferences.appleVisibleCalendarIDs)
        connectionState.writeCalendarID = preferences.appleWriteCalendarID
        onPreferencesChange(preferences)
    }

    func setVisibleCalendarIDs(_ ids: Set<String>) async {
        preferences.appleVisibleCalendarIDs = Array(ids).sorted()
        connectionState.visibleCalendarIDs = ids
        onPreferencesChange(preferences)
    }

    func setWriteCalendarID(_ id: String?) async {
        preferences.appleWriteCalendarID = id
        connectionState.writeCalendarID = id
        onPreferencesChange(preferences)
    }

    func enableRemindersIfNeeded() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await reminderStore.requestFullAccessToReminders()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                reminderStore.requestAccess(to: .reminder) { ok, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
        }
        guard granted else {
            throw CalendarProviderError.permissionDenied
        }
        preferences.appleRemindersEnabled = true
        onPreferencesChange(preferences)
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [ExternalCalendarEvent] {
        guard connectionState.isConnected || store.authorizationStatusCompatible == .fullAccess else {
            return []
        }

        let visible = connectionState.visibleCalendarIDs
        let calendars = store.calendars(for: .event).filter { visible.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var events = store.events(matching: predicate).map { event -> ExternalCalendarEvent in
            let linked = CalendarSyncMapper.scheduleID(from: event.url?.absoluteString)
                ?? CalendarSyncMapper.scheduleID(fromNotes: event.notes)
            return ExternalCalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                provider: .apple,
                calendarID: event.calendar.calendarIdentifier,
                title: event.title ?? "Event",
                startAt: event.startDate,
                endAt: event.endDate,
                isAllDay: event.isAllDay,
                linkedScheduleID: linked,
                recurrenceSummary: event.hasRecurrenceRules ? "Repeats" : nil,
                supportsIntentSync: linked != nil && !(event.hasRecurrenceRules && event.recurrenceRules?.first?.frequency == .monthly),
                kind: .event,
                lastModifiedAt: event.lastModifiedDate
            )
        }

        if preferences.appleRemindersEnabled {
            let reminderCalendars = reminderStore.calendars(for: .reminder)
            let reminderPredicate = reminderStore.predicateForIncompleteReminders(
                withDueDateStarting: start,
                ending: end,
                calendars: reminderCalendars
            )
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                reminderStore.fetchReminders(matching: reminderPredicate) { items in
                    continuation.resume(returning: items ?? [])
                }
            }
            events.append(contentsOf: reminders.compactMap { reminder in
                guard let components = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: components) else {
                    return nil
                }
                return ExternalCalendarEvent(
                    id: reminder.calendarItemIdentifier,
                    provider: .apple,
                    calendarID: reminder.calendar.calendarIdentifier,
                    title: reminder.title ?? "Reminder",
                    startAt: due,
                    endAt: nil,
                    isAllDay: true,
                    supportsIntentSync: false,
                    kind: .reminder,
                    lastModifiedAt: reminder.lastModifiedDate
                )
            })
        }

        return CalendarSyncMapper.deduplicatedEvents(events)
    }

    func upsertLinkedEvent(
        for schedule: IntentSchedule,
        intentionName: String
    ) async throws -> ScheduleSyncMetadata {
        guard let calendarID = connectionState.writeCalendarID
                ?? preferences.appleWriteCalendarID,
              let calendar = store.calendar(withIdentifier: calendarID) else {
            throw CalendarProviderError.notConnected
        }

        let event: EKEvent
        if let existingID = schedule.sync?.externalEventID, !existingID.isEmpty,
           let existing = store.event(withIdentifier: existingID) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }

        event.title = CalendarSyncMapper.eventTitle(for: intentionName)
        event.startDate = schedule.scheduledAt
        event.endDate = schedule.scheduledAt.addingTimeInterval(3_600)
        event.url = CalendarSyncMapper.intentURL(for: schedule.id)
        event.notes = "Managed by Intent\n\(CalendarSyncMapper.intentURL(for: schedule.id).absoluteString)"
        event.recurrenceRules = Self.recurrenceRules(for: schedule)

        try store.save(event, span: .futureEvents, commit: true)
        let eventID = event.eventIdentifier ?? UUID().uuidString
        return ScheduleSyncMetadata(
            provider: .apple,
            calendarID: calendar.calendarIdentifier,
            externalEventID: eventID,
            lastSyncedAt: Date(),
            lastLocalModifiedAt: Date(),
            lastExternalModifiedAt: event.lastModifiedDate
        )
    }

    func deleteLinkedEvent(metadata: ScheduleSyncMetadata) async throws {
        guard let event = store.event(withIdentifier: metadata.externalEventID) else { return }
        try store.remove(event, span: .futureEvents, commit: true)
    }

    private func refreshAuthorizationState() {
        switch store.authorizationStatusCompatible {
        case .fullAccess:
            connectionState.status = .connected
            connectionState.message = nil
        case .denied:
            connectionState.status = didRequestAccess ? .permissionDenied : .disconnected
            if didRequestAccess {
                connectionState.message = CalendarProviderError.permissionDenied.errorDescription
            }
        case .restricted:
            connectionState.status = .restricted
            connectionState.message = CalendarProviderError.restricted.errorDescription
        case .writeOnly:
            connectionState.status = .connected
            connectionState.message = "Intent can write events. Full calendar reading may be limited."
        case .notDetermined:
            connectionState.status = .disconnected
        }
    }

    private static func recurrenceRules(for schedule: IntentSchedule) -> [EKRecurrenceRule]? {
        switch schedule.recurrence {
        case .once:
            return nil
        case .daily:
            return [EKRecurrenceRule(
                recurrenceWith: .daily,
                interval: 1,
                end: nil
            )]
        case .weekly:
            let days: [EKRecurrenceDayOfWeek] = schedule.weekdays.compactMap { raw in
                guard let weekday = EKWeekday(rawValue: raw) else { return nil }
                return EKRecurrenceDayOfWeek(weekday)
            }
            return [EKRecurrenceRule(
                recurrenceWith: .weekly,
                interval: 1,
                daysOfTheWeek: days.isEmpty ? nil : days,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: nil
            )]
        }
    }
}

private enum AppleAuthStatus {
    case notDetermined, restricted, denied, writeOnly, fullAccess
}

private extension EKEventStore {
    var authorizationStatusCompatible: AppleAuthStatus {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .fullAccess
            case .writeOnly: return .writeOnly
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return .fullAccess
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            case .fullAccess: return .fullAccess
            case .writeOnly: return .writeOnly
            @unknown default: return .notDetermined
            }
        }
    }
}
