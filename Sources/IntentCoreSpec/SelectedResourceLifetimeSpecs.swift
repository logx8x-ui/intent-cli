import Foundation
import IntentCore

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
    func finish(_ live: [String: Set<UInt32>], _ browsers: [String: SelectedResourceLifetime.BrowserPresence] = [:],
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
}
