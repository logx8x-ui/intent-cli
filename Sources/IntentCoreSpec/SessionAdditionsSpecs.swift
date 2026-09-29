import Foundation
import IntentCore
import IntentLock

func runSessionAdditionsSpecs() throws {
    try expect(SpotlightSelectionPolicy.markedQuery("`Notes") == "Notes", "Spotlight accepts a leading marker")
    try expect(SpotlightSelectionPolicy.markedQuery("Notes `") == "Notes", "Spotlight accepts a trailing marker")
    try expect(SpotlightSelectionPolicy.markedQuery("Notes") == nil && SpotlightSelectionPolicy.markedQuery("No`tes") == nil && SpotlightSelectionPolicy.markedQuery("`Notes`") == nil, "Ordinary, embedded and multiple markers are never guessed")
    try expect(SpotlightSelectionPolicy.applicationURL("file:///System/Applications/Notes.app")?.path == "/System/Applications/Notes.app", "Spotlight requires an application file URL")
    try expect(SpotlightSelectionPolicy.applicationURL("https://example.com/Notes.app") == nil && SpotlightSelectionPolicy.applicationURL("/tmp/Notes.pdf") == nil, "Web and document results cannot launch as apps")
    var appSelection = QuickSelection(); appSelection.name = "Write"
    appSelection.apps = ["com.apple.Notes"]; appSelection.startupAppIDs = ["com.apple.Notes"]
    let pendingApp = try appSelection.makeIntention(apps: [.init(name: "Notes", bundleIdentifier: "com.apple.Notes")], snapshots: [])
    try expect(FocusSessionSpec.make(for: pendingApp).startupSteps == [.openBundle("com.apple.Notes")], "A deferred Spotlight app opens when the intention starts")
    appSelection.apps = ["org.mozilla.firefox"]; appSelection.wholeBrowserApps = ["org.mozilla.firefox"]; appSelection.startupAppIDs = ["org.mozilla.firefox"]
    let browserApp = try appSelection.makeIntention(apps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")], snapshots: [])
    try expect(!FocusSessionSpec.make(for: browserApp).blockBrowserTabEscape && browserApp.wholeBrowserBundleIdentifiers == ["org.mozilla.firefox"], "Explicit Spotlight application selection can prepare an unopened whole browser")
    let browserRoundTrip = try JSONDecoder().decode(Intention.self, from: JSONEncoder().encode(browserApp))
    try expect(browserRoundTrip.wholeBrowserBundleIdentifiers == ["org.mozilla.firefox"], "Explicit whole-browser scope survives saving")
    let workspace = SessionWorkspace(selection: appSelection, windows: [], tabs: [])
    var replay = workspace.resolve(runningApps: ["org.mozilla.firefox"], windows: [], snapshots: []).selection
    replay.applySessionConfiguration(browserRoundTrip)
    let replayedBrowser = try replay.makeIntention(apps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")], snapshots: [])
    try expect(replayedBrowser.wholeBrowserBundleIdentifiers == ["org.mozilla.firefox"] && replay.startupAppIDs == ["org.mozilla.firefox"], "Saved explicit whole-browser startup survives workspace replay")
    var intention = Intention(id: "additions", name: "Write", icon: "pencil", colorHex: "#34C759", folder: "",
        allowedApps: [.init(name: "Notes", bundleIdentifier: "com.apple.Notes")], allowedWebsites: [], startupActions: [], restrictions: .init())
    let old = try JSONDecoder().decode(Intention.self, from: legacyIntentionData(intention))
    try expect(!old.addAsYouGo && !old.showsStopwatch, "Older intentions remain restrictive with no new modifiers")
    let lockedSpec = FocusSessionSpec.make(for: intention)
    intention.restrictionNodes = [.init(kind: .addAsYouGo, position: .zero), .init(kind: .stopwatch, position: .zero)]
    intention.presetBlockedBundleIdentifiers = ["blocked.app"]
    let permissiveSpec = FocusSessionSpec.make(for: intention)
    try expect(!lockedSpec.permitsApplication("another.app"), "A captured running spec cannot be changed by editing the intention")
    try expect(permissiveSpec.permitsApplication("another.app"), "Add as you go accepts a newly opened application")
    try expect(permissiveSpec.permitsWindow(42, bundleIdentifier: "com.apple.Notes"), "New windows are permitted in an open-ended whitelist")
    try expect(!permissiveSpec.permitsApplication("blocked.app"), "Always-banned applications take priority over Add as you go")
    try expect(permissiveSpec.startupSteps.contains(.openBundle("com.apple.Notes")), "Selected whitelist apps are still prepared at startup")
    try expect(!intention.sessionLocksManualFinish, "Stopwatch and Add as you go do not lock finishing")
    let decoded = try JSONDecoder().decode(Intention.self, from: JSONEncoder().encode(intention))
    try expect(decoded.addAsYouGo && decoded.showsStopwatch, "Both additions survive saved intention round trips")
    intention.accessMode = .blacklist
    let deny = FocusSessionSpec.make(for: intention)
    try expect(!deny.permitsApplication("com.apple.Notes") && !deny.permitsApplication("blocked.app") && deny.permitsApplication("another.app"), "Blacklist and preset bans survive Add as you go")
    intention.restrictionNodes.append(.init(kind: .timer, position: .zero, durationMinutes: 1))
    try expect(intention.sessionLocksManualFinish, "Timer keeps its authority when Stopwatch coexists")
    intention.restrictionNodes.removeAll { $0.kind == .timer }
    intention.frictionNodes = [.init(friction: .taskChecklist(["Finish draft"]), position: .zero)]
    try expect(intention.sessionLocksManualFinish, "Checklist keeps its authority when Stopwatch coexists")

    var rules = ActiveBrowserRules(active: true, allowedWebsites: [], blockTabSwitching: true, blockNavigation: true, blockNewTabs: false)
    rules.addAsYouGo = true
    let restored = try JSONDecoder().decode(ActiveBrowserRules.self, from: JSONEncoder().encode(rules.refreshed()))
    try expect(restored.addAsYouGo, "Native rule renewal retains the immutable session policy")
    let newOrder = ["Timer", "Checklist", "Searches", "Cooldown", "Add as you go", "Stopwatch"]
    try expect(SessionModificationOrder.migrated(stored: ["Cooldown", "Timer", "Checklist", "Searches"], available: newOrder) == ["Cooldown", "Timer", "Checklist", "Searches", "Add as you go", "Stopwatch"], "New modifiers append without resetting a customized order")
    try expect(SessionModificationOrder.migrated(stored: ["Timer", "Timer", "removed"], available: newOrder) == newOrder, "Invalid and duplicate stored controls cannot hide new modifications")
    var gesture = QuickMarkGesture()
    _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    for (index, code) in [18, 19, 20, 21, 23, 22].enumerated() {
        try expect(gesture.key(code: code, down: true, modified: false, repeatKey: false, now: 0.1).action == .modification(index), "Every modification works while backtick stays held")
        _ = gesture.key(code: code, down: false, modified: false, repeatKey: false, now: 0.2)
    }
    _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.3)
    try expect(gesture.expire(now: 1) == nil, "Modifier chords never turn into a delayed overview gesture")
    try expect(SessionStopwatch.text(elapsed: 3661.9) == "01:01:01", "Stopwatch formats hours and elapsed sleep time")
    try expect(SessionStopwatch.text(elapsed: 0) == "00:00:00", "A new stopwatch starts from zero")
    var overlay = SessionOverlayPolicy()
    let occurrence = UUID()
    overlay.update(occurrenceID: occurrence, hasTimer: false, hasChecklist: false, hasStopwatch: true)
    try expect(overlay.visible && overlay.expanded, "Stopwatch alone owns an eligible session bar")
    _ = overlay.collapse(); overlay.toggleVisibility()
    overlay.update(occurrenceID: occurrence, hasTimer: true, hasChecklist: true, hasStopwatch: true)
    try expect(!overlay.visible && !overlay.expanded, "Updates preserve a hidden compact stopwatch")
    overlay.toggleVisibility()
    try expect(overlay.visible && !overlay.expanded, "Backtick restores the compact stopwatch")
    overlay.end()
    try expect(!overlay.visible && !overlay.eligible, "Every completion removes stopwatch controls")
}
