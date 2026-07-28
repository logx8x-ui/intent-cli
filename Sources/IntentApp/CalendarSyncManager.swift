import AppKit
import Combine
import Foundation
import IntentCore

@MainActor
final class CalendarSyncManager: ObservableObject {
    @Published private(set) var appleState: CalendarConnectionState
    @Published private(set) var googleState: CalendarConnectionState
    @Published private(set) var externalEvents: [ExternalCalendarEvent] = []
    @Published private(set) var syncStatusMessage: String?
    @Published var preferences: CalendarPreferences

    private let preferencesStore: CalendarPreferencesStore
    private let coordinator = CalendarSyncCoordinator()
    private let appleProvider: AppleCalendarProvider
    private let googleProvider: GoogleCalendarProvider
    private var refreshTask: Task<Void, Never>?
    private var backgroundTimer: Timer?
    private weak var model: IntentAppModel?

    init(
        preferencesStore: CalendarPreferencesStore = CalendarPreferencesStore(),
        model: IntentAppModel? = nil
    ) {
        self.preferencesStore = preferencesStore
        let prefs = preferencesStore.load()
        self.preferences = prefs
        self.model = model
        self.appleState = CalendarConnectionState(provider: .apple)
        self.googleState = CalendarConnectionState(provider: .google)

        let relay = PreferencesRelay()
        appleProvider = AppleCalendarProvider(preferences: prefs) { updated in
            relay.publish(updated)
        }
        googleProvider = GoogleCalendarProvider(preferences: prefs) { updated in
            relay.publish(updated)
        }
        appleState = appleProvider.connectionState
        googleState = googleProvider.connectionState

        relay.handler = { [weak self] updated in
            Task { @MainActor in
                guard let self else { return }
                self.preferences = updated
                try? self.preferencesStore.save(updated)
            }
        }
    }

    func attach(model: IntentAppModel) {
        self.model = model
    }

    func appear() {
        publishStates()
        Task { await refresh(reason: .appear) }
        startBackgroundRefresh()
    }

    func appBecameActive() {
        Task { await refresh(reason: .active) }
    }

    func connectApple() async {
        do {
            try await appleProvider.connect()
            publishStates()
            await refresh(reason: .manual)
        } catch {
            publishStates()
            syncStatusMessage = error.localizedDescription
        }
    }

    func disconnectApple() async {
        await appleProvider.disconnect()
        publishStates()
        await refresh(reason: .manual)
    }

    func connectGoogle() async {
        do {
            try await googleProvider.connect()
            publishStates()
            await refresh(reason: .manual)
        } catch {
            publishStates()
            syncStatusMessage = error.localizedDescription
        }
    }

    func disconnectGoogle() async {
        await googleProvider.disconnect()
        publishStates()
        await refresh(reason: .manual)
    }

    func setAppleVisible(_ ids: Set<String>) async {
        await appleProvider.setVisibleCalendarIDs(ids)
        publishStates()
        await refresh(reason: .manual)
    }

    func setAppleWriteCalendar(_ id: String?) async {
        await appleProvider.setWriteCalendarID(id)
        publishStates()
    }

    func setGoogleVisible(_ ids: Set<String>) async {
        await googleProvider.setVisibleCalendarIDs(ids)
        publishStates()
        await refresh(reason: .manual)
    }

    func setGoogleWriteCalendar(_ id: String?) async {
        await googleProvider.setWriteCalendarID(id)
        publishStates()
    }

    func enableAppleReminders() async {
        do {
            try await appleProvider.enableRemindersIfNeeded()
            preferences.appleRemindersEnabled = true
            try? preferencesStore.save(preferences)
            await refresh(reason: .manual)
        } catch {
            syncStatusMessage = error.localizedDescription
        }
    }

    func syncSchedule(_ schedule: IntentSchedule, intentionName: String) async -> IntentSchedule {
        guard let syncTarget = schedule.sync?.provider ?? preferredWriteProvider() else {
            return schedule
        }
        do {
            let metadata: ScheduleSyncMetadata
            switch syncTarget {
            case .apple:
                metadata = try await appleProvider.upsertLinkedEvent(for: schedule, intentionName: intentionName)
            case .google:
                metadata = try await googleProvider.upsertLinkedEvent(for: schedule, intentionName: intentionName)
            case .local:
                return schedule
            }
            var updated = schedule
            updated.sync = metadata
            updated.lastLocalModifiedAt = Date()
            await refresh(reason: .mutation)
            return updated
        } catch {
            syncStatusMessage = error.localizedDescription
            return schedule
        }
    }

    func deleteSyncedEvent(for schedule: IntentSchedule) async {
        guard let metadata = schedule.sync else { return }
        do {
            switch metadata.provider {
            case .apple:
                try await appleProvider.deleteLinkedEvent(metadata: metadata)
            case .google:
                try await googleProvider.deleteLinkedEvent(metadata: metadata)
            case .local:
                break
            }
        } catch {
            syncStatusMessage = error.localizedDescription
        }
    }

    func displayItems(
        schedules: [IntentSchedule],
        intentions: [Intention],
        on date: Date,
        calendar: Calendar = .current
    ) -> [SchedulerDisplayItem] {
        let names = Dictionary(uniqueKeysWithValues: intentions.map { ($0.id, $0.name) })
        return coordinator
            .mergeVisibleEvents(
                localSchedules: schedules,
                intentionNames: names,
                externalEvents: externalEvents
            )
            .filter { $0.occurs(on: date, calendar: calendar) }
            .sorted { $0.sortDate < $1.sortDate }
    }

    private enum RefreshReason {
        case appear, active, manual, mutation, background
    }

    private func refresh(reason: RefreshReason) async {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            publishStates()
            let interval = DateInterval(
                start: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date(),
                end: Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date()
            )
            var collected: [ExternalCalendarEvent] = []
            if appleProvider.connectionState.isConnected {
                if let events = try? await appleProvider.fetchEvents(from: interval.start, to: interval.end) {
                    collected.append(contentsOf: events)
                }
            }
            if googleProvider.connectionState.isConnected {
                if let events = try? await googleProvider.fetchEvents(from: interval.start, to: interval.end) {
                    collected.append(contentsOf: events)
                }
            }
            externalEvents = CalendarSyncMapper.deduplicatedEvents(collected)
            await applyInboundSync()
            if reason != .background {
                syncStatusMessage = nil
            }
        }
        refreshTask = task
        await task.value
    }

    private func applyInboundSync() async {
        guard let model else { return }
        var changed = false
        for index in model.schedules.indices {
            guard let sync = model.schedules[index].sync else { continue }
            let linked = externalEvents.first {
                $0.id == sync.externalEventID && $0.provider == sync.provider
            }
            if let linked {
                if let updated = coordinator.applyExternalChange(to: model.schedules[index], from: linked) {
                    model.schedules[index] = updated
                    changed = true
                    syncStatusMessage = "Updated a linked schedule from \(sync.provider.displayName)."
                }
            } else if sync.unlinkOnExternalDelete {
                // Only unlink when provider is connected; offline should not wipe links.
                let providerConnected = (sync.provider == .apple && appleState.isConnected)
                    || (sync.provider == .google && googleState.isConnected)
                if providerConnected {
                    model.schedules[index] = coordinator.handleExternalDeletion(of: model.schedules[index])
                    changed = true
                    syncStatusMessage = "A linked calendar event was removed. The local schedule was disabled."
                }
            }
        }
        if changed {
            model.persistSchedulesFromSync()
        }
    }

    private func preferredWriteProvider() -> CalendarProviderKind? {
        if appleState.isConnected, appleState.writeCalendarID != nil { return .apple }
        if googleState.isConnected, googleState.writeCalendarID != nil { return .google }
        return nil
    }

    private func publishStates() {
        appleState = appleProvider.connectionState
        googleState = googleProvider.connectionState
    }

    private func startBackgroundRefresh() {
        guard backgroundTimer == nil else { return }
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.refresh(reason: .background)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }
}

private final class PreferencesRelay: @unchecked Sendable {
    var handler: ((CalendarPreferences) -> Void)?

    func publish(_ preferences: CalendarPreferences) {
        handler?(preferences)
    }
}
