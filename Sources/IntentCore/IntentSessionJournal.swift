import Foundation

/// Local-only history and replay data. A record describes a run, never a claim
/// that the user completed their work.
public struct SessionWorkspace: Codable {
    public struct Window: Codable, Equatable {
        public var app: String
        public var title: String
        public init(app: String, title: String) { self.app = app; self.title = title }
    }
    public struct Tab: Codable, Equatable {
        public var browser: String
        public var url: String
        public var title: String
        public init(browser: String, url: String, title: String) { self.browser = browser; self.url = url; self.title = title }
    }
    public var selection: QuickSelection
    public var windows: [Window]
    public var tabs: [Tab]
    public init(selection: QuickSelection, windows: [Window], tabs: [Tab]) {
        self.selection = selection; self.windows = windows; self.tabs = tabs
    }
    public struct LiveWindow {
        public var id: UInt32
        public var app: String
        public var title: String
        public init(id: UInt32, app: String, title: String) { self.id = id; self.app = app; self.title = title }
    }
    /// Restore only unique, exact resources. Never reuse transient IDs across
    /// browser restarts or widen one missing window into a whole-app allowance.
    public func resolve(runningApps: Set<String>, windows liveWindows: [LiveWindow], snapshots: [BrowserTabSnapshot]) -> (selection: QuickSelection, missing: Int) {
        var draft = selection; draft.clearTargets()
        let scoped = Set(selection.windowIDsByApp.keys).union(selection.tabs.map(\.browser))
            .union(windows.map(\.app)).union(tabs.map(\.browser))
        let wholeApps = selection.apps.subtracting(scoped)
        draft.apps = wholeApps.intersection(runningApps)
        var missing = wholeApps.subtracting(runningApps).count
            + max(0, selection.windowIDsByApp.values.reduce(0) { $0 + $1.count } - windows.count)
            + max(0, selection.tabs.count - tabs.count)
        for window in windows {
            let matches = liveWindows.filter { $0.app == window.app && $0.title == window.title }
            if matches.count == 1 { draft.windowIDsByApp[window.app, default: []].insert(matches[0].id); draft.apps.insert(window.app) }
            else { missing += 1 }
        }
        for tab in tabs {
            let snapshot = snapshots.first { $0.browserBundleIdentifier == tab.browser }
            let matches = (snapshot.map { $0.allTabs ?? $0.tabs } ?? []).filter { $0.url == tab.url && $0.title == tab.title }
            if matches.count == 1, draft.pinBrowserSession(tab.browser, sessionID: snapshot?.browserSessionID) {
                draft.tabs.insert(.init(browser: tab.browser, id: matches[0].id)); draft.apps.insert(tab.browser)
            } else { missing += 1 }
        }
        return (draft, missing)
    }

}

public struct IntentSessionRecord: Codable, Identifiable {
    public var id: UUID
    public var intention: Intention
    public var workspace: SessionWorkspace?
    public var startedAt: Date
    public var endedAt: Date?
    public var completedTasks: Set<Int>
    public var remainingSeconds: TimeInterval?
    public init(id: UUID, intention: Intention, workspace: SessionWorkspace?, startedAt: Date = Date()) {
        self.id = id; self.intention = intention; self.workspace = workspace
        self.startedAt = startedAt; completedTasks = []
    }
}

public struct WorkPeriodSchedule: Codable, Identifiable {
    public var id = UUID()
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var startMinute = 9 * 60
    public var endMinute = 17 * 60
    public var enabled = true
    public init() {}
    public func occurrence(at now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard enabled, (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else { return nil }
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: day),
                  let endDay = calendar.date(byAdding: .day, value: endMinute <= startMinute ? 1 : 0, to: day),
                  let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay),
                  now >= start, now < end else { continue }
            return DateInterval(start: start, end: end)
        }
        return nil
    }
}

public struct IntentSessionJournal: Codable {
    public var records: [IntentSessionRecord] = []
    public var recovery: IntentSessionRecord?
    public var slotOrder: [String] = []
    public var workspaces: [String: SessionWorkspace] = [:]
    public var workSchedules: [WorkPeriodSchedule] = []
    public init() {}
    public mutating func upsert(_ record: IntentSessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }
    public func records(on day: Date, calendar: Calendar = .current) -> [IntentSessionRecord] {
        records.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.sorted { $0.startedAt > $1.startedAt }
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
