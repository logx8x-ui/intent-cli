import Foundation
import IntentCore
import IntentLock

func runTabSelectionSpecs() throws {
    let browser = "com.google.Chrome"
    let firefox = "org.mozilla.firefox"
    let app = AllowedApp(name: "Chrome", bundleIdentifier: browser)
    let urls = ["https://example.org/page", "https://example.org/manual.pdf", "file:///tmp/manual.pdf", "about:blank", "chrome://newtab/", "", "chrome://settings/", "https://example.org/page"]
    let rows = urls.enumerated().map { offset, url in
        BrowserTabItem(id: offset + 1, windowID: 10, index: offset, title: "", url: url, active: offset == 1,
                       highlighted: (1...6).contains(offset), pinned: offset == 0, discarded: offset == 7, groupID: 4)
    }
    let snapshot = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: "selection-spec-session", tabs: rows)
    try expect(rows.allSatisfy(QuickSelection.isSelectable), "Web, PDF, local, new, blank, internal and discarded tabs are selectable by identity")
    try expect(rows[5].displayTitle == "New tab", "Missing title and URL still produce a readable row")
    var all = QuickSelection()
    all.toggleBrowserWindow(browser: browser, windowID: 10, snapshots: [snapshot])
    try expect(all.tabIDsByBrowser[browser] == Array(1...8), "Select all includes every actual browser tab")
    let intention = try all.makeIntention(apps: [app], snapshots: [snapshot])
    try expect(intention.allowedWebsites.count == 2 && all.tabs.count == 8, "Duplicate URLs share optional site metadata but never merge tab identity")
    try expect(intention.selectionBrowserBundleIdentifiers == [browser], "Tab-scoped browsers survive independently of website metadata")
    let restored = try JSONDecoder().decode(Intention.self, from: JSONEncoder().encode(intention))
    try expect(restored.selectionBrowserBundleIdentifiers == [browser] && restored.selectionRequiresTabReselection, "Saved mixed/internal intentions retain the need to reselect ephemeral tabs")

    for mode in [IntentionAccessMode.whitelist, .blacklist] {
        var native = QuickSelection(); native.accessMode = mode
        native.toggleNativeTabGroup(browser: browser, windowID: 10, snapshot: snapshot)
        try expect(native.tabIDsByBrowser[browser] == Array(2...7), "Native highlighted group reaches \(mode) policy intact")
        let grouped = try native.makeIntention(apps: [app], snapshots: [snapshot])
        try expect(grouped.permitsApplication(browser), "A selected tab group must not block its whole browser")
        native.toggleNativeTabGroup(browser: browser, windowID: 10, snapshot: snapshot)
        try expect(native.tabs.isEmpty, "Repeating a native group mark deselects the complete group")
        var internalOnly = QuickSelection(); internalOnly.accessMode = mode
        internalOnly.toggleTab(.init(browser: browser, id: 5), browserSessionID: "selection-spec-session")
        let internalIntention = try internalOnly.makeIntention(apps: [app], snapshots: [snapshot])
        let spec = FocusSessionSpec.make(for: internalIntention)
        try expect(internalIntention.allowedWebsites.isEmpty && spec.permitsApplication(browser) && spec.blockBrowserTabEscape,
                   "Internal-only \(mode) selection uses tab enforcement without banning the browser or inventing a URL")
    }

    var webOnly = QuickSelection(); webOnly.toggleTab(.init(browser: browser, id: 1), browserSessionID: "selection-spec-session")
    let savedWeb = try webOnly.makeIntention(apps: [app], snapshots: [snapshot])
    try expect(!savedWeb.selectionRequiresTabReselection, "Saved web-only intentions keep their established website replay behavior")
    let frameA = BrowserWindowFrame(left: 20, top: 40, width: 900, height: 700)
    let frameB = BrowserWindowFrame(left: 700, top: 80, width: 800, height: 600)
    var sameTitle = [
        BrowserTabItem(id: 101, windowID: 101, index: 0, title: "New Tab", url: "", active: true, windowFrame: frameA, windowFocused: true),
        BrowserTabItem(id: 102, windowID: 102, index: 0, title: "New Tab", url: "", active: true, windowFrame: frameB, windowFocused: false)
    ]
    try expect(BrowserWindowMatching.match(title: "New Tab", tabs: sameTitle, nativeWindowCount: 2, frame: frameB.rect) == 102, "Equal browser titles match their own window geometry")
    sameTitle[1].windowFrame = frameA
    try expect(BrowserWindowMatching.match(title: "New Tab", tabs: sameTitle, nativeWindowCount: 2, frame: frameA.rect) == nil, "Identical overlapping previews never guess a window identity")
    try expect(BrowserWindowMatching.match(title: "New Tab", tabs: sameTitle, nativeWindowCount: 2, frame: frameA.rect, isFocused: true) == 101, "Foreground quick-mark uses confirmed native/browser focus to disambiguate equal geometry")

    var selected = QuickSelection()
    func click(_ id: Int, shift: Bool = false, displayed: [BrowserTabItem] = rows, window: Int = 10, appID: String = browser) {
        selected.selectTab(.init(browser: appID, id: id), windowID: window, displayedTabs: displayed, extendingRange: shift)
    }
    click(8); click(2); click(7, shift: true)
    try expect(selected.tabIDsByBrowser[browser] == Array(2...8), "Click 2 then Shift-click 7 includes both endpoints and independent tab 8")
    click(4, shift: true)
    try expect(selected.tabIDsByBrowser[browser] == [2, 3, 4, 8], "Range shrink removes only range-owned tabs")
    click(1, shift: true)
    try expect(selected.tabIDsByBrowser[browser] == [1, 2, 8], "Reverse Shift range uses the same anchor")
    var moved = rows
    moved.swapAt(0, 4)
    click(1, shift: true, displayed: moved)
    try expect(selected.tabIDsByBrowser[browser] == [1, 2, 3, 4, 8], "Reordered range uses stable anchor identity in displayed order")
    let withoutAnchor = rows.filter { $0.id != 2 }
    click(6, shift: true, displayed: withoutAnchor)
    try expect(selected.tabs.contains(.init(browser: browser, id: 6)), "Disappearing anchor safely creates a new additive anchor")
    let secondWindow = [BrowserTabItem(id: 20, windowID: 20, index: 0, title: "Other", url: "", active: true)]
    click(20, shift: true, displayed: secondWindow, window: 20)
    try expect(selected.tabs.contains(.init(browser: browser, id: 20)) && !selected.tabs.contains(.init(browser: browser, id: 7)), "A range never crosses browser windows")
    click(2, shift: true, appID: firefox)
    try expect(selected.tabs.contains(.init(browser: firefox, id: 2)) && selected.tabs.contains(.init(browser: browser, id: 2)), "Browser-scoped IDs remain separate")

    selected.clearTargets()
    click(7, shift: true)
    try expect(selected.tabIDsByBrowser[browser] == [7] && selected.browserSessionIDs.isEmpty,
               "Clear removes range anchors and browser pins, so the next Shift-click starts fresh")

    // Revalidating a selected identity follows URL and window changes, but never
    // transfers the mark to a replacement tab with the same title/URL.
    var identity = QuickSelection(); identity.toggleTab(.init(browser: browser, id: 1), browserSessionID: "selection-spec-session")
    var navigated = rows; navigated[0].url = "file:///tmp/another.pdf"; navigated[0].windowID = 30
    _ = try identity.makeIntention(apps: [app], snapshots: [.init(browserBundleIdentifier: browser, browserSessionID: "selection-spec-session", tabs: navigated)])
    var restarted = snapshot; restarted.browserSessionID = "a-different-browser-session"
    do {
        _ = try identity.makeIntention(apps: [app], snapshots: [restarted])
        throw SpecFailure(description: "Reused IDs after browser restart must not target unrelated tabs")
    } catch QuickSelectionError.browserSessionChanged {}
    try expect(!identity.pinBrowserSession(browser, sessionID: restarted.browserSessionID), "A refresh must never replace the pinned identity of existing marks")
    let rules = ActiveBrowserRules(active: true, allowedWebsites: [], selectedTabIDsByBrowser: [browser: [1]],
                                   selectedBrowserSessionIDsByBrowser: [browser: "selection-spec-session"],
                                   blockTabSwitching: true, blockNavigation: true, blockNewTabs: true)
    let restoredRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: JSONEncoder().encode(rules))
    try expect(restoredRules.refreshed().selectedBrowserSessionIDsByBrowser == rules.selectedBrowserSessionIDsByBrowser,
               "Browser session identity survives rule persistence and heartbeat refresh")
    navigated[0].id = 100
    do {
        _ = try identity.makeIntention(apps: [app], snapshots: [.init(browserBundleIdentifier: browser, browserSessionID: "selection-spec-session", tabs: navigated)])
        throw SpecFailure(description: "Closed tab identity must not be substituted by its matching URL/title")
    } catch is QuickSelectionError {}

    let legacy = Data(#"{"id":5,"windowID":10,"index":0,"title":"","url":"","active":true}"#.utf8)
    let legacyTab = try JSONDecoder().decode(BrowserTabItem.self, from: legacy)
    var legacySelection = QuickSelection()
    let legacyApplied = legacySelection.toggleNativeTabGroup(browser: browser, windowID: 10, snapshot: .init(browserBundleIdentifier: browser, browserSessionID: "selection-spec-session", tabs: [legacyTab]))
    try expect(!legacyApplied && legacySelection.tabs.isEmpty, "Older bridges without group metadata must report failure instead of silently applying only the active member")
    let roundTrip = try JSONDecoder().decode(BrowserTabItem.self, from: JSONEncoder().encode(rows[1]))
    try expect(roundTrip == rows[1], "Native selection, grouping and loading metadata survive the Codable bridge")
}
