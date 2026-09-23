import Foundation
import IntentCore

func runHabitSessionSpecs() throws {
    var selection = QuickSelection()
    selection.name = "Study chapter 2"
    selection.sourceIntentionID = "saved-study"
    selection.apps = ["com.apple.TextEdit"]
    selection.toggleWindow(42, app: "org.example.notes")
    _ = selection.pinBrowserSession("com.google.Chrome", sessionID: "session-a")
    selection.toggleTab(.init(browser: "com.google.Chrome", id: 7))
    let encoded = try JSONEncoder().encode(selection)
    let restored = try JSONDecoder().decode(QuickSelection.self, from: encoded)
    try expect(restored.name == "Study chapter 2", "Named drafts survive persistence")
    try expect(restored.tabs == selection.tabs && restored.windowIDsByApp == selection.windowIDsByApp, "Replay snapshots preserve exact original scope")
    try expect(restored.browserSessionIDs == selection.browserSessionIDs, "Persisted browser IDs remain scoped to their original session")
    let workspace = SessionWorkspace(selection: selection, windows: [.init(app: "org.example.notes", title: "Notes")], tabs: [.init(browser: "com.google.Chrome", url: "https://example.com/work", title: "Work")])
    let tab = BrowserTabItem(id: 99, windowID: 3, index: 0, title: "Work", url: "https://example.com/work", active: true)
    let snapshot = BrowserTabSnapshot(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "new-session", tabs: [tab])
    let resolved = workspace.resolve(runningApps: ["com.apple.TextEdit", "org.example.notes", "com.google.Chrome"], windows: [.init(id: 200, app: "org.example.notes", title: "Notes")], snapshots: [snapshot])
    try expect(resolved.missing == 0 && resolved.selection.tabs.contains(.init(browser: "com.google.Chrome", id: 99)), "Replay resolves new IDs using exact workspace descriptors")
    try expect(resolved.selection.browserSessionIDs["com.google.Chrome"] == "new-session", "Replay pins the current browser lifetime")
    let duplicate = BrowserTabItem(id: 100, windowID: 4, index: 0, title: tab.title, url: tab.url, active: true)
    let ambiguous = workspace.resolve(runningApps: ["com.apple.TextEdit", "com.google.Chrome"], windows: [], snapshots: [.init(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "new-session", tabs: [tab, duplicate])])
    try expect(ambiguous.missing == 2 && ambiguous.selection.tabs.isEmpty, "Duplicate tabs require review rather than choosing the wrong browser window")
    try expect(!ambiguous.selection.apps.contains("org.example.notes") && !ambiguous.selection.apps.contains("com.google.Chrome"), "Missing scoped resources never become unrestricted whole apps")
    let missingDescriptors = SessionWorkspace(selection: selection, windows: [], tabs: []).resolve(runningApps: selection.apps, windows: [], snapshots: [])
    try expect(missingDescriptors.missing == 2 && missingDescriptors.selection.apps == ["com.apple.TextEdit"], "A disappearing resource at capture cannot broaden replay scope")
    let intention = Intention(name: "Study chapter 2", icon: "book", colorHex: "#34C759", folder: "", allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
    var edited = intention
    edited.name = "Updated study"
    edited.accessMode = .blacklist
    edited.restrictionNodes = [.init(kind: .timer, position: .zero, durationMinutes: 7, showsRemainingTime: true, locksSessionUntilTimerEnds: true)]
    var replay = resolved.selection
    replay.applySessionConfiguration(edited)
    try expect(replay.name == edited.name && replay.accessMode == .blacklist && replay.restrictionNodes.first?.durationMinutes == 7,
               "Saved replay uses current name, mode and modifiers, not stale snapshot settings")
    try expect(replay.tabs == resolved.selection.tabs && replay.windowIDsByApp == resolved.selection.windowIDsByApp && replay.browserSessionIDs == resolved.selection.browserSessionIDs,
               "Updating replay settings preserves resolved resource identity")
    var journal = IntentSessionJournal()
    var record = IntentSessionRecord(id: UUID(), intention: intention, workspace: .init(selection: selection, windows: [], tabs: []), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    journal.upsert(record)
    record.endedAt = record.startedAt.addingTimeInterval(600); record.remainingSeconds = 900; record.completedTasks = [0, 2]
    journal.upsert(record); journal.recovery = record
    try expect(journal.records.count == 1, "Ready and teardown cannot duplicate a history occurrence")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try journal.save(to: url)
    let loaded = try IntentSessionJournal.load(from: url)
    try expect(loaded.recovery?.remainingSeconds == 900 && loaded.recovery?.completedTasks == [0, 2], "Recovery preserves time remaining and checked tasks")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    try expect(loaded.records(on: record.startedAt, calendar: calendar).count == 1, "History groups runs by local day")
    try expect(loaded.records(on: record.startedAt.addingTimeInterval(86400), calendar: calendar).isEmpty, "Yesterday does not duplicate today's records")
    var schedule = WorkPeriodSchedule(); schedule.weekdays = [2]; schedule.startMinute = 22*60; schedule.endMinute = 2*60
    let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 23))!
    try expect(schedule.occurrence(at: monday, calendar: calendar) != nil, "Overnight work period starts on selected weekday")
    try expect(schedule.occurrence(at: monday.addingTimeInterval(7200), calendar: calendar) != nil, "Overnight work period crosses midnight")
    try expect(schedule.occurrence(at: monday.addingTimeInterval(10800), calendar: calendar) == nil, "Work period end boundary is exclusive")
    schedule.enabled = false
    try expect(schedule.occurrence(at: monday, calendar: calendar) == nil, "Disabled schedule never gates the desktop")
    try Data("not json".utf8).write(to: url)
    do { _ = try IntentSessionJournal.load(from: url); throw SpecFailure(description: "Corrupt history must not silently become empty") }
    catch is DecodingError { }
}
