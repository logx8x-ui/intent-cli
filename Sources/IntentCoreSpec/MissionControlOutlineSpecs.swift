import Foundation
import IntentLock

func runMissionControlOutlineSpecs() throws {
    typealias Outline = MissionControlOutline
    func window(_ id: UInt32, _ title: String, selected: Bool = true, bundle: String = "org.mozilla.firefox",
                pid: Int32 = 42, launched: TimeInterval = 100, tabs: Int? = 1) -> Outline.Window {
        .init(id: id, pid: pid, launched: launched, bundle: bundle, title: title, selected: selected, selectedTabCount: tabs)
    }
    func tile(_ title: String, x: CGFloat = 20, y: CGFloat = 150, width: CGFloat = 280,
              height: CGFloat = 160, bundle: String? = nil) -> Outline.Tile {
        .init(labels: [title, "window"], frame: CGRect(x: x, y: y, width: width, height: height), representedBundle: bundle)
    }
    func scan(_ tiles: [Outline.Tile], status: Outline.Status = .complete,
              present: Bool = true, dock: String = "9:100") -> Outline.Scan {
        .init(status: status, present: present, dockIdentity: dock, tiles: tiles)
    }
    let firefox = window(1, "Biology", tabs: 2)
    let chrome = window(2, "Chemistry", bundle: "com.google.Chrome", pid: 44, tabs: 1)
    let messages = window(3, "Messages", bundle: "com.apple.MobileSMS", pid: 46, tabs: nil)
    let tiny = tile("Biology", width: 70, height: 42)
    let secondDisplay = tile("Chemistry", x: -1_200, y: -300)
    let mappings = Outline.map(scan([tiny, secondDisplay, tile("Messages", x: 500)]), windows: [firefox, chrome, messages])
    try expect(mappings.regions.count == 3 && mappings.unresolvedCount == 0,
        "Complete mixed-browser/native Mission Control tiles map independently on both displays")
    try expect(mappings.regions[0].frame == tiny.frame && mappings.regions[0].badge == "2 selected tabs",
        "A tiny thumbnail outlines the complete native tile with an explicit partial-tab count, never an invisible scaled strip")
    try expect(mappings.regions[1].frame == secondDisplay.frame && mappings.regions[1].window.bundle == "com.google.Chrome"
        && mappings.regions[1].badge == "1 selected tab" && mappings.regions[2].badge == nil,
        "Each region carries its own browser/selection identity rather than inheriting the frontmost browser")

    let unselectedSibling = window(4, "Biology", selected: false)
    let ambiguous = Outline.map(scan([tiny]), windows: [firefox, unselectedSibling])
    try expect(ambiguous.regions.isEmpty && ambiguous.unresolvedCount == 1,
        "Identical selected and unselected native titles cannot guess a green thumbnail; they request a selection summary")
    let duplicateTiles = Outline.map(scan([tiny, tile("Biology", x: 450)]), windows: [firefox])
    try expect(duplicateTiles.regions.isEmpty && duplicateTiles.unresolvedCount == 1,
        "Two distinct tiles claiming the same native identity are ambiguous")
    try expect(Outline.map(scan([tiny, tiny]), windows: [firefox]).regions.count == 1,
        "The same tile repeated through AX subtrees is deduplicated without dropping a valid outline")
    let crossAppDuplicate = window(4, "Biology", selected: false, bundle: "com.google.Chrome", pid: 44)
    let provenApp = Outline.map(scan([tile("Biology", bundle: "org.mozilla.firefox")]), windows: [firefox, crossAppDuplicate])
    try expect(provenApp.regions.count == 1, "An explicit app-bundle identity can disambiguate same-title windows across apps")
    try expect(Outline.map(scan([tile("Biology", bundle: "com.google.Chrome")]), windows: [firefox, crossAppDuplicate]).regions.isEmpty,
        "A positive excluded app identity cannot inherit the selected same-title app's outline")
    try expect(Outline.map(scan([tile("Messages")]), windows: [window(3, "Different title", bundle: "com.apple.MobileSMS", tabs: nil)]).regions.isEmpty,
        "A window title changing mid-scan cannot map stale tile text onto its new identity")
    for invalid in [window(1, "Biology", launched: 0), window(1, "Biology", tabs: 0)] {
        try expect(Outline.map(scan([tiny]), windows: [invalid]).regions.isEmpty,
            "An unavailable process lifetime or empty tab selection cannot acquire a Mission Control contour")
    }

    var continuity = Outline.Continuity()
    try expect(continuity.update(scan([tiny]), windows: [firefox], revision: 1, now: 10).regions.count == 1,
        "A complete verified mapping seeds Mission Control continuity")
    try expect(continuity.update(scan([], status: .partial), windows: [firefox], revision: 1, now: 10.35).regions.count == 1,
        "A bounded partial AX scan is not authoritative evidence of an empty selection")
    try expect(continuity.update(scan([], status: .unavailable), windows: [firefox], revision: 1, now: 10.7).regions.count == 1,
        "A temporarily unavailable same-Dock read retains the last positive tile briefly")
    try expect(continuity.update(scan([], status: .partial), windows: [firefox], revision: 1, now: 11).regions.isEmpty,
        "Partial reads cannot refresh the last verification time and retain stale geometry indefinitely")

    for (name, nextScan, nextWindows, nextRevision) in [
        ("complete absence", scan([]), [firefox], 1),
        ("Mission Control exit", scan([], present: false), [firefox], 1),
        ("Dock restart", scan([], status: .partial, dock: "10:200"), [firefox], 1),
        ("selection revision", scan([], status: .partial), [firefox], 2),
        ("native title change", scan([], status: .partial), [window(1, "Biology — Updated", tabs: 2)], 1),
        ("native process restart", scan([], status: .partial), [window(1, "Biology", launched: 200, tabs: 2)], 1),
        ("new ambiguous sibling", scan([], status: .partial), [firefox, unselectedSibling], 1),
        ("contradictory tile at old rectangle", scan([tile("Not selected", width: 70, height: 42)], status: .partial), [firefox], 1),
        ("duplicate tile contradiction", scan([tiny, tile("Biology", x: 450)], status: .partial), [firefox], 1)
    ] {
        var state = Outline.Continuity()
        _ = state.update(scan([tiny]), windows: [firefox], revision: 1, now: 20)
        try expect(state.update(nextScan, windows: nextWindows, revision: nextRevision, now: 20.1).regions.isEmpty,
            "\(name) immediately invalidates prior Mission Control geometry")
    }
    var moving = Outline.Continuity()
    _ = moving.update(scan([tiny]), windows: [firefox], revision: 1, now: 30)
    let moved = tile("Biology", x: 800, y: 200, width: 90, height: 50)
    let movedResult = moving.update(scan([moved], status: .partial), windows: [firefox], revision: 1, now: 30.1)
    try expect(movedResult.regions.count == 1 && movedResult.regions[0].frame == moved.frame,
        "A positively identified moving thumbnail replaces its former rectangle during a partial transition")
    var reentry = Outline.Continuity()
    _ = reentry.update(scan([tiny]), windows: [firefox], revision: 1, now: 40)
    _ = reentry.update(scan([], present: false), windows: [firefox], revision: 1, now: 40.1)
    try expect(reentry.update(scan([], status: .partial), windows: [firefox], revision: 1, now: 40.2).regions.isEmpty,
        "Fast exit and reentry cannot resurrect geometry from the previous Mission Control visit")
}
