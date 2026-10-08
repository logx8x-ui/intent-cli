import Foundation
import IntentCore
import IntentLock

func runMissionControlRepresentationSpecs() throws {
    let applicationNames = ["org.mozilla.firefox": "Firefox", "com.apple.dock": "Dock",
        "com.apple.MobileSMS": "Messages", "com.microsoft.VSCode": "Visual Studio Code"]
    // The observed native tile is an AXButton named Example Domain, beneath
    // mc.windows. Neither its title nor a Dock owner ancestor identifies its app.
    for title in ["Example Domain", "Instagram Messages", "Visual Studio Code — Firefox"] {
        let labels = [title, "button", "exposéd windows", "group", "Dock", "application"]
        let represented = FocusClickTargetPolicy.representedBundleIdentifier(labels: labels,
            applicationNamesByBundleIdentifier: applicationNames, isMissionControl: true)
        try expect(represented == nil, "Free page text and Dock ancestry never infer an app from a native window tile")
        try expect(FocusClickTargetPolicy.shouldAllowMissionControlClick(ownerBundleIdentifier: "com.apple.dock",
            representedBundleIdentifier: represented, controlledBundleIdentifiers: ["org.mozilla.firefox"],
            accessMode: .whitelist), "A title-only permitted browser tile passes to native Mission Control")
    }
    for (role, identifier) in [("AXApplication", ""), ("AXGroup", "mc.windows"),
                               ("AXGroup", "mc.display"), ("AXGroup", "mc")] {
        try expect(FocusClickTargetPolicy.isMissionControlRepresentationBoundary(role: role, identifier: identifier),
            "Application/container ancestry is outside the tile's represented identity")
    }
    try expect(!FocusClickTargetPolicy.isMissionControlRepresentationBoundary(role: "AXButton", identifier: nil),
        "A real tile may still provide its own explicit app URL")
    try expect(FocusClickTargetPolicy.isMissionControlSpaceNavigation(ownerBundleIdentifier: "com.apple.dock",
        ancestorIdentifiers: ["mc.spaces.list"]), "Desktop navigation retains its independent ancestry route")
    try expect(FocusClickTargetPolicy.representedBundleIdentifier(labels: ["Messages"],
        applicationNamesByBundleIdentifier: applicationNames) == "com.apple.MobileSMS",
        "Ordinary Dock icons retain their existing exact app-name recognition")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-mc-target-\(UUID().uuidString)")
    let bundleURL = directory.appendingPathComponent("Blocked.app")
    let contents = bundleURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = "org.intent.fixture.blocked"
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": blocked], format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
    let verified = ApplicationBundleIdentifierResolver.resolve(from: bundleURL)
    try expect(verified == blocked, "The blocked fixture is resolved from an actual app bundle URL")
    let represented = FocusClickTargetPolicy.representedBundleIdentifier(labels: ["Firefox", "Dock"],
        applicationNamesByBundleIdentifier: applicationNames, verifiedApplicationBundleIdentifier: verified,
        isMissionControl: true)
    for mode: IntentionAccessMode in [.whitelist, .blacklist] {
        try expect(!FocusClickTargetPolicy.shouldAllowMissionControlClick(ownerBundleIdentifier: "com.apple.dock",
            representedBundleIdentifier: represented,
            controlledBundleIdentifiers: mode == .whitelist ? ["org.mozilla.firefox"] : [blocked], accessMode: mode),
            "An explicit forbidden app bundle remains blocked regardless of misleading allowed text")
    }
    try expect(ApplicationBundleIdentifierResolver.resolve(from: URL(string: "https://example.com/Firefox.app")!) == nil,
        "A page URL cannot stand in for an explicit native app identity")

    // Exercise the native window policy directly; this is not a browser
    // startup/coverage fixture and must not bypass its required snapshot gate.
    let scoped = FocusSessionSpec(displayName: "Native window scope", startupSteps: [],
        allowedBundleIdentifiers: ["org.mozilla.firefox"], fallbackBundleIdentifier: "org.mozilla.firefox",
        strictSingleApp: false, blockAppSwitching: true, blockNewApps: true, keepFocused: true,
        blockBrowserTabEscape: true, blockFirefoxChromeClicks: false, allowGoogleSearchTabs: false,
        spotifyPlaylistURI: nil, allowSpotifyForeground: false,
        selectedWindowIDsByApp: ["org.mozilla.firefox": [1]])
    try expect(scoped.permitsWindow(1, bundleIdentifier: "org.mozilla.firefox")
        && !scoped.permitsWindow(2, bundleIdentifier: "org.mozilla.firefox"),
        "Removing title guesses leaves exact forbidden sibling-window enforcement unchanged")
}
