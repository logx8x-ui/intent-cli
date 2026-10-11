import Foundation
import ApplicationServices
import IntentCore
import IntentLock

func runSelectedResourceLifetimeSpecs() throws {
    let explicitApps = SelectedResourceLifetime.wholeAppSelections(
        allowedAppIDs: ["finder", "preview", "chrome", "notes", "spotify"],
        presetAppIDs: ["finder", "preview"], windowSelectionAppIDs: ["notes"], tabSelectionAppIDs: ["chrome"])
    try expect(explicitApps == ["spotify"], "Persisted always-allowed presets cannot keep a selected-resource session alive")
    try expect(SelectedResourceLifetime.shouldFinish(restrictive: true, selectedWindows: ["notes": [1]],
        wholeApps: [], liveWindows: ["finder": [2], "preview": [3]], browsers: [:]),
        "Open default-app windows do not prevent normal completion after the selected work closes")
    let idle = BrowserTabSnapshot(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "owner",
        tabs: [], updatedAt: Date().addingTimeInterval(-60), allTabs: [])
    try expect(SelectedResourceLifetime.needsTabConfirmation(restrictive: true, snapshot: idle, selectedIDs: [8]),
        "An old idle inventory still requests exact closure confirmation after the last selected tab closes")
    try expect(!SelectedResourceLifetime.needsTabConfirmation(restrictive: false, snapshot: idle, selectedIDs: [8]),
        "Permissive intentions do not use selected-tab closure as completion")
    let windows: [String: Set<UInt32>] = ["notes": [1, 2], "editor": [3]]
    func finish(_ live: [String: Set<UInt32>]?, _ browsers: [String: SelectedResourceLifetime.BrowserPresence] = [:],
                wholeApps: Set<String> = [], restrictive: Bool = true) -> Bool {
        SelectedResourceLifetime.shouldFinish(restrictive: restrictive, selectedWindows: windows,
            wholeApps: wholeApps, liveWindows: live, browsers: browsers)
    }
    try expect(!finish(["notes": [2]]), "Closing one selected window retains the other selected window")
    try expect(!finish(["editor": [3]]), "Closing an entire selected app retains another selected app")
    try expect(finish(["notes": [99]]), "Unselected sibling windows do not keep an exhausted whitelist alive")
    try expect(!finish([:], ["firefox": .present]), "Selected tabs keep the session alive after native targets close")
    try expect(!finish(["editor": [3]], ["firefox": .closed]), "Closing all Firefox tabs does not stop the remaining selected editor")
    try expect(!finish([:], ["firefox": .closed, "chrome": .present]), "Closing one browser leaves another selected browser running")
    try expect(!finish([:], ["firefox": .unknown]), "Incomplete browser inventory is not ordinary completion")
    try expect(finish([:], ["firefox": .closed, "chrome": .closed]), "Confirmed closure of every target finishes the session")
    try expect(!finish(["spotify": [7]], wholeApps: ["spotify"]), "A selected whole app stays alive through a replacement window")
    try expect(!finish([:], restrictive: false), "Closing blocked selections or Add as you go targets never ends their permissive session")
    try expect(SelectedResourceLifetime.shouldFinish(restrictive: true, selectedWindows: ["firefox": [4]],
        wholeApps: [], liveWindows: ["firefox": [4]], browsers: ["firefox": .closed]),
        "An unselected tab left in a browser window cannot stand in for its closed selected tabs")

    // Exercise the real WindowServer adapter with injected rows and process
    // metadata. No desktop inventory, running process or visibility is touched.
    typealias AppIdentity = (bundleIdentifier: String?, isRegular: Bool)
    let apps: [Int32: AppIdentity] = [10: ("notes", true), 20: ("editor", true),
        30: ("spotify", true), 40: (nil, false)]
    var windowQuery: (CGWindowListOption, CGWindowID)?
    func inventory(_ rows: [[String: Any]]?, identities: [Int32: AppIdentity] = apps,
                   selected: [String: Set<UInt32>] = windows, whole: Set<String> = []) -> [String: Set<UInt32>]? {
        WorkspaceWindow.lifetimeInventory(selectedWindows: selected, wholeApps: whole, copyInfo: { options, relativeTo in
            windowQuery = (options, relativeTo)
            return rows.map { $0 as CFArray }
        }, resolveApplication: { identities[$0] })
    }
    func row(_ id: UInt32, _ pid: Int32, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer]
    }
    try expect(!finish(inventory(nil)), "An unavailable WindowServer query cannot finish an existing native intention")
    try expect(windowQuery?.0 == [.optionAll, .excludeDesktopElements] && windowQuery?.1 == kCGNullWindowID,
        "Selected-resource lifetime queries include offscreen and minimized windows")
    var small = row(2, 10)
    small[kCGWindowBounds as String] = CGRect(x: -900, y: 10, width: 66, height: 20).dictionaryRepresentation
    small[kCGWindowIsOnscreen as String] = false
    try expect(!finish(inventory([small])),
        "A small offscreen selected window keeps the intention alive after its other selected windows close")
    try expect(!finish(inventory([row(2, 10)])),
        "Positive native identity remains live even while preview geometry is unavailable")
    try expect(!finish(inventory([row(2, 10)], identities: [:])),
        "An existing selected row with unresolved process metadata is unknown, not closed")
    try expect(!finish(inventory([row(7, 30)], identities: [:], whole: ["spotify"]), wholeApps: ["spotify"]),
        "Unresolved whole-app window ownership cannot prove that the selected whole app has closed")
    try expect(!finish(inventory([row(7, 30)], whole: ["spotify"]), wholeApps: ["spotify"]),
        "Whole-app selection includes a replacement window without requiring an overview-sized frame")
    try expect(!finish(inventory([row(2, 10)], identities: [10: (nil, true)])),
        "Missing bundle identity of an existing selected row defers ordinary completion")
    try expect(!finish(inventory([row(2, 10, layer: 1)])),
        "An existing selected surface changing layer cannot become a false closure")
    try expect(finish(inventory([row(99, 10)])),
        "A positively identified unselected sibling still cannot replace a closed exact selected window")
    try expect(finish(inventory([])), "A successful empty native inventory finishes after the last selected target closes")
    var malformed = row(2, 10)
    malformed.removeValue(forKey: kCGWindowOwnerPID as String)
    try expect(!finish(inventory([malformed])) && !finish(inventory([row(2, 10), row(2, 10)])),
        "Malformed or duplicate native identities are incomplete evidence, never normal completion")
    try expect(finish(inventory([row(9, 40)])),
        "A positively classified unrelated system surface does not keep an exhausted whitelist alive")
    try expect(SelectedResourceLifetime.shouldFinish(restrictive: true, selectedWindows: ["firefox": [4]],
        wholeApps: [], liveWindows: nil, browsers: ["firefox": .closed]),
        "Confirmed browser-only closure remains authoritative when native inventory is unavailable")
    try expect(!finish(nil, ["firefox": .closed]) && !finish(nil, restrictive: false),
        "Confirmed browser closure cannot exhaust unresolved native work or a permissive intention")

    let searchSession = "current-browser-rules-occurrence"
    struct DomainFixture: Decodable { let hosts: [String] }
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/fixtures/google-search-domains.json")
    let googleDomains = try JSONDecoder().decode(DomainFixture.self, from: Data(contentsOf: fixtureURL)).hosts
    try expect(Set(googleDomains) == SelectedResourceLifetime.supportedGoogleSearchHosts
        && Set(googleDomains).count == googleDomains.count,
        "Native search domains match the same verified exact-host snapshot exercised by both browser guards")
    var search = BrowserTabItem(id: 19, windowID: 344, index: 1, title: "Search",
        url: "https://www.google.com/search?q=study", active: true, searchSessionID: searchSession)
    for host in googleDomains {
        search.url = "https://www.\(host)/search?q=study"
        try expect(SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
            "Every verified regional Google domain remains available: \(host)")
        search.url = "https://\(host).evil.example/search"
        try expect(!SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
            "A lookalike suffix never inherits a verified Google domain: \(host)")
    }
    search.url = "https://www.google.com/search?q=study"
    var searchSnapshot = idle; searchSnapshot.tabs = [search]; searchSnapshot.allTabs = [search]
    try expect(SelectedResourceLifetime.hasRemainingTabs(snapshot: searchSnapshot, selectedIDs: [8], searchSessionID: searchSession)
        && !SelectedResourceLifetime.needsTabConfirmation(restrictive: true, snapshot: searchSnapshot,
            selectedIDs: [8], searchSessionID: searchSession),
        "An actually authorized search tab keeps work alive after the originally selected tab closes")
    try expect(!SelectedResourceLifetime.hasRemainingTabs(snapshot: searchSnapshot, selectedIDs: [8])
        && !SelectedResourceLifetime.hasRemainingTabs(snapshot: searchSnapshot, selectedIDs: [8], searchSessionID: "other-occurrence"),
        "Searches off or a different rules occurrence cannot inherit runtime search membership")
    search.searchSessionID = nil; searchSnapshot.allTabs = [search]
    try expect(!SelectedResourceLifetime.hasRemainingTabs(snapshot: searchSnapshot, selectedIDs: [8], searchSessionID: searchSession),
        "An unselected old Google tab is not selected work merely because its URL is a search")
    search.searchSessionID = searchSession
    for url in ["", "about:blank", "about:newtab", "chrome://newtab/", "chrome://new-tab-page/", "chrome-search://local-ntp/",
                "https://www.google.com/", "https://google.co.kr/search/?q=study"] {
        search.url = url
        try expect(SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
            "Current ledger membership includes its permitted search or loading page: \(url)")
    }
    for url in ["moz-extension://intent/parked.html", "chrome-extension://intent/parked.html#intent-12345678-abcd-1234-abcd-123456789012",
                "https://blocked.example/", "https://www.google.com/maps", "https://google.com.evil.example/search", "https://google.com//search"] {
        search.url = url
        try expect(!SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
            "Holding, blocked and non-search destinations cannot keep a session alive even with an old marker: \(url)")
    }
    search.url = "https://www.google.com/search?q=study"; search.id = -1
    try expect(!SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
        "Malformed runtime search identity cannot count as remaining work")
    search.id = 19; search.windowID = -1
    try expect(!SelectedResourceLifetime.isRuntimeSearchTab(search, searchSessionID: searchSession),
        "A runtime search also needs its actual browser window identity")
}
