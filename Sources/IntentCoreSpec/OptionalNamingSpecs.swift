import Foundation
import IntentCore

func runOptionalNamingSpecs() throws {
    var draft = QuickSelection()
    try expect(!draft.hasDraftConfiguration, "An untouched unnamed draft does not preserve an empty selection")
    draft.restrictionNodes = [.init(kind: .stopwatch, position: .zero)]
    try expect(draft.hasDraftConfiguration, "Modifiers chosen before naming or app selection survive closing and mixed selection methods")
    draft.restrictionNodes = []; draft.accessMode = .blacklist
    try expect(draft.hasDraftConfiguration, "An unnamed blacklist draft retains its mode")
    let chrome = AllowedApp(name: "Chrome", bundleIdentifier: "com.google.Chrome")
    let chat = AllowedApp(name: "ChatGPT", bundleIdentifier: "com.openai.chat")
    let firefox = AllowedApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
    let whatsapp = AllowedApp(name: "WhatsApp", bundleIdentifier: "net.whatsapp")
    let apps = [whatsapp, chrome, firefox, chat]
    try expect(SessionNaming.summary(apps: apps, tabCounts: [chrome.bundleIdentifier: 3, firefox.bundleIdentifier: 2])
        == "chatgpt-chrome(3 tabs)-firefox(2 tabs)-whatsapp", "Automatic titles show selected apps and browser tab counts in a stable order")
    try expect(SessionNaming.summary(apps: [chrome, chrome], tabCounts: [chrome.bundleIdentifier: 1]) == "chrome(1 tab)", "Duplicate apps and singular tab grammar are handled")
    var selection = QuickSelection(); selection.apps = [chat.bundleIdentifier]
    let unnamed = try selection.makeIntention(apps: apps, snapshots: [])
    try expect(unnamed.name == "chatgpt" && unnamed.nameIsAutomatic && unnamed.automaticName == "chatgpt", "Starting without naming produces a useful, saveable title")
    selection.name = "   "
    let whitespace = try selection.makeIntention(apps: apps, snapshots: [])
    try expect(whitespace.nameIsAutomatic, "Whitespace remains optional")
    selection.name = "  Reply to emails  "
    let named = try selection.makeIntention(apps: apps, snapshots: [])
    try expect(named.name == "Reply to emails" && !named.nameIsAutomatic && named.automaticName == "chatgpt", "Explicit names are trimmed and retain the resource summary")
    let renamed = SessionNaming.rename(unnamed, to: "  Study  ")
    try expect(renamed.name == "Study" && !renamed.nameIsAutomatic, "Inline naming changes the automatic title into a full-opacity name")
    let cleared = SessionNaming.rename(renamed, to: "")
    try expect(cleared.name == "chatgpt" && cleared.nameIsAutomatic, "Clearing a name restores its original automatic title")
    var replay = QuickSelection(); replay.applySessionConfiguration(unnamed)
    try expect(replay.name.isEmpty, "Automatic titles do not fill the optional input on replay")
    replay.applySessionConfiguration(named)
    try expect(replay.name == named.name, "Explicit saved names remain editable on replay")
    let roundTrip = try JSONDecoder().decode(Intention.self, from: JSONEncoder().encode(unnamed))
    try expect(roundTrip.nameIsAutomatic && roundTrip.automaticName == unnamed.name, "Automatic naming metadata persists")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as! [String: Any]
    legacy.removeValue(forKey: "nameIsAutomatic"); legacy.removeValue(forKey: "automaticName")
    let legacyRestored = try JSONDecoder().decode(Intention.self, from: JSONSerialization.data(withJSONObject: legacy))
    try expect(!legacyRestored.nameIsAutomatic && legacyRestored.name == named.name, "Existing saved names migrate as explicit names")
    selection.name = ""; selection.apps = [chrome.bundleIdentifier]
    _ = selection.pinBrowserSession(chrome.bundleIdentifier, sessionID: "tabs-a")
    for id in [1, 2, 3] { selection.toggleTab(.init(browser: chrome.bundleIdentifier, id: id)) }
    let tabs = (1...3).map { BrowserTabItem(id: $0, windowID: 1, index: $0 - 1, title: "Tab", url: "https://example.com/\($0)", active: $0 == 1) }
    let snapshot = BrowserTabSnapshot(browserBundleIdentifier: chrome.bundleIdentifier, browserSessionID: "tabs-a", tabs: tabs)
    let browser = try selection.makeIntention(apps: apps, snapshots: [snapshot])
    try expect(browser.name == "chrome(3 tabs)" && browser.nameIsAutomatic, "Explicit tab selections count tabs rather than duplicate URLs")
    selection.accessMode = .blacklist
    let blocked = try selection.makeIntention(apps: apps, snapshots: [snapshot])
    try expect(blocked.name == "chrome(3 tabs)", "Blacklist sessions can remain unnamed")
    let order = SavedSlotOrder.normalized(["b", "b", "deleted"], available: ["a", "b", "c"])
    try expect(order == ["b", "a", "c"], "Saved slots preserve positions without duplicate or deleted entries")
    try expect(SavedSlotOrder.swapping("b", with: "c", order: order, available: ["a", "b", "c"]) == ["c", "a", "b"], "Dragging swaps occupied positions")
    try expect(SavedSlotOrder.swapping("missing", with: "c", order: order, available: ["a", "b", "c"]) == order, "Unknown drops cannot corrupt slot order")
    for (index, code) in [18,19,20,21,23,22,26,28,25].enumerated() {
        var gesture = OverviewSearchGesture()
        try expect(gesture.key(code: code, down: true, modified: false, repeated: false, editing: false).action == .savedSlot(index), "Every visible numbered slot can run")
        try expect(gesture.key(code: code, down: true, modified: false, repeated: true, editing: false).action == nil, "Holding a number cannot repeatedly run a slot")
        try expect(gesture.key(code: code, down: false, modified: false, repeated: false, editing: false).action == nil, "Number release cannot start again")
        try expect(!gesture.key(code: code, down: true, modified: false, repeated: false, editing: true).consume, "Numbers in names stay text")
        try expect(!gesture.key(code: code, down: true, modified: true, repeated: false, editing: false).consume, "Modified numbers stay available to system shortcuts")
    }
    var chord = OverviewSearchGesture()
    _ = chord.key(code: 50, down: true, modified: false, repeated: false, editing: false)
    for (index, code) in [18,19,20,21,23,22].enumerated() {
        try expect(chord.key(code: code, down: true, modified: false, repeated: false, editing: false).action == .modification(index), "Held prefix still controls all six modifiers")
    }
    try expect(chord.key(code: 50, down: false, modified: false, repeated: false, editing: false).action == nil, "Modifier chord release cannot close the workspace")
    var record = IntentSessionRecord(id: UUID(), intention: unnamed, workspace: nil)
    record.savedIntentionID = unnamed.id
    let restored = try JSONDecoder().decode(IntentSessionRecord.self, from: JSONEncoder().encode(record))
    try expect(restored.savedIntentionID == unnamed.id, "Filled bookmarks retain their saved setup identity across restarts")
    var legacyRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    legacyRecord.removeValue(forKey: "savedIntentionID")
    let oldRecord = try JSONDecoder().decode(IntentSessionRecord.self, from: JSONSerialization.data(withJSONObject: legacyRecord))
    try expect(oldRecord.savedIntentionID == nil, "Existing history remains readable without a bookmark link")
}
