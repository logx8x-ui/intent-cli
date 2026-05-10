import Foundation
import IntentCore
import IntentLock

struct SpecFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SpecFailure(description: message)
    }
}

do {
    try expect(IntentMenu.routeRootInput("s") == .shallow, "s should route to shallow")
    try expect(IntentMenu.routeRootInput("S") == .shallow, "S should route to shallow")
    try expect(IntentMenu.routeRootInput("d") == .deep, "d should route to deep")
    try expect(IntentMenu.routeRootInput("D") == .deep, "D should route to deep")

    var menu = IntentMenu()
    try expect(menu.screen == .root, "menu should start at root")
    try expect(menu.handle("s") == .showShallow, "s should show shallow")
    try expect(menu.screen == .shallow, "menu should enter shallow")
    try expect(menu.handle("\u{1B}") == .showRoot, "escape should return to root")
    try expect(menu.screen == .root, "escape should set root")
    try expect(menu.handle("s") == .showShallow, "s should show shallow again")
    try expect(menu.handle("b") == .showRoot, "b should return to root")
    try expect(menu.screen == .root, "b should set root")

    _ = menu.handle("s")
    try expect(menu.handle("1") == .start(.shallow(.imessages)), "1 should start Imessages")
    try expect(menu.handle("2") == .start(.shallow(.instagramReplies)), "2 should start Instagram replies")
    try expect(menu.handle("3") == .start(.shallow(.emails)), "3 should start Emails")

    _ = menu.handle("\u{1B}")
    _ = menu.handle("d")
    try expect(menu.handle("1") == .start(.deep(.dataScience)), "deep 1 should start Data Science")

    try expect(IntentCompleter.complete("i", in: ShallowTask.allCases) == nil, "ambiguous i should not complete")
    try expect(IntentCompleter.complete("ime", in: ShallowTask.allCases) == "imessages", "ime should complete")
    try expect(IntentCompleter.complete("im-", in: ShallowTask.allCases) == "imessages", "im- should complete")
    try expect(IntentCompleter.complete("insta", in: ShallowTask.allCases) == "instagram replies", "insta should complete")
    try expect(IntentCompleter.complete("em", in: ShallowTask.allCases) == "emails", "em should complete")
    try expect(IntentCompleter.complete("data", in: DeepTask.allCases) == "data science", "data should complete")
    try expect(IntentCompleter.complete("x", in: ShallowTask.allCases) == nil, "x should not complete")

    let intentions = DefaultIntentions.make()
    try expect(intentions.contains { $0.name == "Instagram replies" }, "defaults should include Instagram replies")
    try expect(intentions.contains { $0.name == "Emails" }, "defaults should include Emails")
    try expect(intentions.contains { $0.name == "Data Science" }, "defaults should include Data Science")

    let instagram = intentions.first { $0.name == "Instagram replies" }!
    try expect(instagram.friction.validate("I want to use instagram right now"), "Instagram phrase should validate")
    try expect(!instagram.friction.validate("instagram"), "wrong Instagram phrase should fail")
    try expect(instagram.allowedWebsites.contains { $0.value == "instagram.com/direct" }, "Instagram should allow DMs")
    try expect(AllowedWebsite("https://www.roblox.com/games").displayName == "roblox", "Website display name should simplify URLs")

    let legacyRestrictions = Data("""
    {
      "blockAppSwitching": true,
      "blockNewApps": true,
      "blockBrowserTabSwitching": true,
      "blockBrowserNavigation": true,
      "blockNewBrowserTabs": true,
      "keepFocused": true
    }
    """.utf8)
    let decodedLegacyRestrictions = try JSONDecoder().decode(RestrictionSet.self, from: legacyRestrictions)
    try expect(!decodedLegacyRestrictions.allowGoogleSearchTabs, "Legacy restrictions should default Google search tabs off")

    let dataScience = intentions.first { $0.name == "Data Science" }!
    try expect(dataScience.allowedApps.contains { $0.bundleIdentifier == "io.remnote" }, "Data Science should allow RemNote")
    try expect(dataScience.allowedApps.contains { $0.bundleIdentifier == "com.remnote.desktop" }, "Data Science should allow RemNote desktop bundle")
    try expect(!dataScience.startupActions.contains { action in
        if case .openApp(let bundleIdentifier) = action {
            return bundleIdentifier == "io.remnote"
        }
        return false
    }, "Data Science should not auto-open RemNote")
    let dataScienceSpec = FocusSessionSpec.make(for: dataScience)
    try expect(dataScienceSpec.allowedBundleIdentifiers.contains("io.remnote"), "Data Science spec should allow RemNote")
    try expect(dataScienceSpec.spotifyPlaylistURI == "spotify:playlist:0fbyat27nV9HP9WlSphWlS", "Data Science spec should keep the study playlist")
    try expect(!dataScienceSpec.allowSpotifyForeground, "Data Science should not allow Spotify as a foreground escape")

    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("intent-core-spec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let intentionStore = IntentionStore(fileURL: tempDirectory.appendingPathComponent("intentions.json"))
    try intentionStore.save(intentions)
    let loadedIntentions = try intentionStore.load()
    try expect(loadedIntentions == intentions, "IntentionStore should round-trip intentions")

    let rulesStore = ActiveBrowserRulesStore(fileURL: tempDirectory.appendingPathComponent("browser-rules.json"))
    let browserRules = ActiveBrowserRules(
        active: true,
        allowedWebsites: ["github.com"],
        blockTabSwitching: true,
        blockNavigation: true,
        blockNewTabs: false,
        allowGoogleSearchTabs: true
    )
    try rulesStore.write(browserRules)
    let loadedRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: Data(contentsOf: rulesStore.fileURL))
    try expect(loadedRules == browserRules, "Active browser rules should round-trip")
    try rulesStore.clear()
    let clearedRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: Data(contentsOf: rulesStore.fileURL))
    try expect(!clearedRules.active, "Clearing browser rules should make them inactive")
    try expect(!clearedRules.allowGoogleSearchTabs, "Clearing browser rules should disable Google search tabs")
    try? FileManager.default.removeItem(at: tempDirectory)

    print("IntentCoreSpec passed")
} catch {
    fputs("IntentCoreSpec failed: \(error)\n", stderr)
    exit(1)
}
