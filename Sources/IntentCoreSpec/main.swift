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

func legacyIntentionData(_ intention: Intention) throws -> Data {
    let encoded = try JSONEncoder().encode(intention)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object.removeValue(forKey: "graphPosition")
    object.removeValue(forKey: "restrictionNodes")
    object.removeValue(forKey: "frictionNodes")
    object.removeValue(forKey: "graphModelVersion")
    return try JSONSerialization.data(withJSONObject: object)
}

do {
    var permissionPromptCount = 0
    var permissionChecks = [false, false, true]
    let delayedPermission = AccessibilityAuthorizationGate(
        isTrusted: {
            permissionChecks.removeFirst()
        },
        requestPrompt: {
            permissionPromptCount += 1
        },
        pause: {}
    )
    try expect(delayedPermission.waitForTrust(maxPolls: 3), "Accessibility gate should wait for a later grant")
    try expect(permissionPromptCount == 1, "Accessibility gate should prompt once while waiting")

    var alreadyTrustedPromptCount = 0
    let alreadyTrustedPermission = AccessibilityAuthorizationGate(
        isTrusted: { true },
        requestPrompt: {
            alreadyTrustedPromptCount += 1
        },
        pause: {}
    )
    try expect(alreadyTrustedPermission.waitForTrust(maxPolls: 3), "Accessibility gate should pass immediately when already trusted")
    try expect(alreadyTrustedPromptCount == 0, "Accessibility gate should not prompt when already trusted")

    var deniedPromptCount = 0
    let deniedPermission = AccessibilityAuthorizationGate(
        isTrusted: { false },
        requestPrompt: {
            deniedPromptCount += 1
        },
        pause: {}
    )
    try expect(!deniedPermission.waitForTrust(maxPolls: 2), "Accessibility gate should stop after its polling budget")
    try expect(deniedPromptCount == 1, "Accessibility gate should not spam repeated prompts")

    let accessibilityPauseStartedAt = Date()
    AccessibilityAuthorizationGate.pollingPause(duration: 0.05)
    let accessibilityPauseElapsed = Date().timeIntervalSince(accessibilityPauseStartedAt)
    try expect(accessibilityPauseElapsed >= 0.04, "Accessibility polling pause should actually wait between trust checks")

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

    var runnerMenu = IntentionRunnerMenu(intentions: intentions)
    try expect(runnerMenu.screen == .folders, "runner should start at folders")
    try expect(runnerMenu.folderOptions.map(\.name) == ["Deep", "Shallow"], "runner folders should use intention folders")
    try expect(runnerMenu.handle("1") == .showIntentions("Deep"), "runner 1 should open Deep folder")
    try expect(runnerMenu.screen == .intentions("Deep"), "runner should enter Deep folder")
    try expect(runnerMenu.intentionOptions.map(\.name) == ["Data Science"], "Deep should show Data Science")
    try expect(runnerMenu.handle("1") == .start("data-science"), "Deep 1 should start Data Science")
    try expect(runnerMenu.handle("\u{1B}") == .showFolders, "escape should go back to folders")
    try expect(runnerMenu.screen == .folders, "escape should set runner folders")
    _ = runnerMenu.handle("2")
    try expect(runnerMenu.screen == .intentions("Shallow"), "runner 2 should enter Shallow folder")
    try expect(runnerMenu.handle("b") == .showFolders, "b should go back to folders")

    let instagram = intentions.first { $0.name == "Instagram replies" }!
    try expect(instagram.friction.validate("I want to use instagram right now"), "Instagram phrase should validate")
    try expect(!instagram.friction.validate("instagram"), "wrong Instagram phrase should fail")
    try expect(instagram.allowedWebsites.contains { $0.value == "instagram.com/direct" }, "Instagram should allow DMs")
    try expect(AllowedWebsite("https://www.roblox.com/games").displayName == "roblox", "Website display name should simplify URLs")
    let firefoxWebsite = AllowedWebsite("https://github.com", browserBundleIdentifier: "org.mozilla.firefox")
    try expect(firefoxWebsite.browserBundleIdentifier == "org.mozilla.firefox", "Allowed websites should remember their browser owner")
    try expect(firefoxWebsite.resourceID == "website:org.mozilla.firefox:github.com", "Website resource IDs should include the browser")
    let instagramSpec = FocusSessionSpec.make(for: instagram)
    try expect(instagramSpec.strictSingleApp, "Instagram should stay locked to one app")
    try expect(instagramSpec.allowedBundleIdentifiers == ["org.mozilla.firefox"], "Instagram should only allow Firefox")
    try expect(instagramSpec.blockAppSwitching, "Instagram should block switching to unallowed apps")
    try expect(instagramSpec.blockBrowserTabEscape, "Instagram should enable browser escape blocking")
    try expect(
        FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: "com.apple.dock"),
        "Mission Control should be treated as a temporary system switcher"
    )
    try expect(
        !FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: "io.remnote"),
        "Regular unallowed apps should not get Mission Control grace"
    )
    try expect(
        FocusForegroundPolicy.isMissionControlOverlay(
            ownerName: "Dock",
            layer: 20,
            bounds: .init(x: 0, y: 0, width: 1710, height: 1112),
            displayBounds: .init(x: 0, y: 0, width: 1710, height: 1112)
        ),
        "Mission Control's full-screen Dock overlay should allow click-through"
    )
    try expect(
        !FocusForegroundPolicy.isMissionControlOverlay(
            ownerName: "Firefox",
            layer: 0,
            bounds: .init(x: 0, y: 39, width: 1710, height: 1073),
            displayBounds: .init(x: 0, y: 0, width: 1710, height: 1112)
        ),
        "Normal app windows should not disable click protection"
    )
    try expect(!FocusSystemShortcutPolicy.shouldBlock(keyCode: 48), "Cmd+Tab should be handled by Intent's allowed-app switcher")
    try expect(!FocusSystemShortcutPolicy.shouldBlock(keyCode: 50), "Cmd+grave should keep normal within-app window switching")
    try expect(!FocusSystemShortcutPolicy.shouldBlock(keyCode: 49), "Cmd+Space should keep macOS Spotlight available")
    try expect(FocusSystemShortcutPolicy.shouldBlock(keyCode: 4), "Cmd+H should stay blocked as an escape shortcut")
    try expect(
        FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: "com.apple.Spotlight"),
        "Spotlight should remain usable while its system overlay is visible"
    )
    try expect(
        !FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: 21,
            command: true,
            control: false,
            option: false,
            shift: true,
            allowGoogleSearchTabs: false
        ),
        "Cmd+Shift+4 screenshot selection should stay available during browser-locked sessions"
    )
    try expect(
        !FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: 21,
            command: true,
            control: false,
            option: false,
            shift: false,
            allowGoogleSearchTabs: false
        ),
        "Cmd+4 should reach Firefox so Browser Guard can allow or bounce the destination tab"
    )
    try expect(
        !FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: 48,
            command: false,
            control: true,
            option: false,
            shift: false,
            allowGoogleSearchTabs: false
        ),
        "Ctrl+Tab should reach Firefox so Browser Guard can allow or bounce the destination tab"
    )
    try expect(
        !FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: 13,
            command: true,
            control: false,
            option: false,
            shift: false,
            allowGoogleSearchTabs: false
        ),
        "Cmd+W should stay available so tabs can always close"
    )
    try expect(
        !FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: 17,
            command: true,
            control: false,
            option: false,
            shift: false,
            allowGoogleSearchTabs: false
        ),
        "Cmd+T should always create a browser tab, even when browser searches are disabled"
    )

    let firefoxBounds = FirefoxWindowBounds(x: 100, y: 200, width: 1200, height: 800)
    try expect(
        !FirefoxClickProtection.isProtected(point: .init(x: 450, y: 500), windowBounds: firefoxBounds),
        "Firefox Sidebery tab list clicks should reach Browser Guard so allowed tabs can be selected"
    )
    try expect(
        !FirefoxClickProtection.isProtected(point: .init(x: 600, y: 230), windowBounds: firefoxBounds),
        "Firefox top browser chrome clicks should stay available for tab closing and normal controls"
    )
    try expect(
        !FirefoxClickProtection.isProtected(point: .init(x: 650, y: 500), windowBounds: firefoxBounds),
        "Firefox page content clicks should stay available during browser-locked sessions"
    )
    try expect(
        !FirefoxClickProtection.isProtected(
            point: .init(x: 600, y: 230),
            windowBounds: firefoxBounds,
            protectTopChrome: false
        ),
        "Google-search mode should allow Firefox search chrome clicks"
    )
    try expect(
        !FirefoxClickProtection.isProtected(
            point: .init(x: 450, y: 500),
            windowBounds: firefoxBounds,
            protectTopChrome: false
        ),
        "Google-search mode should also let Sidebery clicks reach Browser Guard"
    )

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

    let legacyInstagram = Intention(
        id: "legacy-instagram",
        name: "Legacy Instagram",
        icon: "globe",
        colorHex: "#FFFFFF",
        folder: "Shallow",
        allowedApps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")],
        allowedWebsites: [.init("instagram.com/direct")],
        startupActions: [.openURL("https://instagram.com/direct/inbox/", browserBundleIdentifier: "org.mozilla.firefox")],
        restrictions: .init()
    )
    let migratedInstagram = try JSONDecoder().decode(Intention.self, from: legacyIntentionData(legacyInstagram))
    try expect(
        !migratedInstagram.dontStartResourceIDs.contains("website:org.mozilla.firefox:instagram.com/direct"),
        "A more-specific legacy startup URL should count as starting its allowed website rule"
    )

    let legacyDataScience = Intention(
        id: "data-science",
        name: "Data Science",
        icon: "function",
        colorHex: "#FFFFFF",
        folder: "Deep",
        allowedApps: [
            .init(name: "RStudio", bundleIdentifier: "com.rstudio.desktop"),
            .init(name: "Codex", bundleIdentifier: "com.openai.codex"),
            .init(name: "RemNote", bundleIdentifier: "io.remnote")
        ],
        allowedWebsites: [],
        startupActions: [],
        restrictions: .init()
    )
    let migratedDataScience = try JSONDecoder().decode(Intention.self, from: legacyIntentionData(legacyDataScience))
    try expect(!migratedDataScience.dontStartResourceIDs.contains("app:com.rstudio.desktop"), "New automatic startup should open productive legacy apps by default")
    try expect(migratedDataScience.dontStartResourceIDs.contains("app:com.openai.codex"), "Known legacy Data Science exclusions should preserve Codex as allowed but closed")
    try expect(migratedDataScience.dontStartResourceIDs.contains("app:io.remnote"), "Known legacy Data Science exclusions should preserve RemNote as allowed but closed")

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
    try expect(dataScienceSpec.allowSpotifyForeground, "An explicitly allowed Spotify app should be switchable like other allowed apps")
    let dataScienceStartup = IntentionStartupPlanner.steps(for: dataScience)
    try expect(dataScienceStartup.contains(.openBundle("com.rstudio.desktop")), "Allowed apps should start automatically")
    try expect(!dataScienceStartup.contains(.openBundle("com.openai.codex")), "Don't-start-up should keep Codex closed initially")
    try expect(!dataScienceStartup.contains(.openBundle("io.remnote")), "Don't-start-up should keep RemNote closed initially")
    try expect(dataScienceStartup.contains(.openURL("https://github.com", bundleIdentifier: "org.mozilla.firefox")), "Allowed websites should start in their assigned browser")

    var frictionOrderIntention = dataScience
    frictionOrderIntention.frictionNodes = [
        .init(id: "second", friction: .typedPhrase("second"), position: .init(x: 0, y: 100)),
        .init(id: "first", friction: .countdown(seconds: 5), position: .init(x: 0, y: -100))
    ]
    try expect(frictionOrderIntention.orderedFrictionNodes.map(\.id) == ["first", "second"], "Higher friction nodes should run first")

    var collidedIntentions = [
        Intention(
            id: "collision-a",
            name: "A",
            icon: "target",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init(),
            graphPosition: .init(x: 300, y: 0),
            graphModelVersion: 2
        ),
        Intention(
            id: "collision-b",
            name: "B",
            icon: "target",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init(),
            graphPosition: .init(x: 300, y: 0),
            graphModelVersion: 2
        )
    ]
    GraphLayoutMigration.arrangeLegacyCollisions(&collidedIntentions)
    try expect(collidedIntentions[0].graphPosition != collidedIntentions[1].graphPosition, "Legacy overlapping intentions should be separated once")
    try expect(collidedIntentions.allSatisfy { $0.graphModelVersion == 3 }, "Collision migration should be versioned and never rearrange later edits")

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
        allowedWebsitesByBrowser: [
            "org.mozilla.firefox": ["github.com"],
            "com.google.Chrome": ["instagram.com/direct"]
        ],
        blockTabSwitching: true,
        blockNavigation: true,
        blockNewTabs: false,
        allowGoogleSearchTabs: true
    )
    try rulesStore.write(browserRules)
    let loadedRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: Data(contentsOf: rulesStore.fileURL))
    try expect(loadedRules == browserRules, "Active browser rules should round-trip")
    try expect(loadedRules.allowedWebsitesByBrowser["com.google.Chrome"] == ["instagram.com/direct"], "Chrome websites should remain browser-specific")
    try expect(loadedRules.isFresh(), "Freshly written active browser rules should be fresh")
    let staleLegacyRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: Data("""
    {
      "active": true,
      "allowedWebsites": ["instagram.com/direct"],
      "blockTabSwitching": true,
      "blockNavigation": true,
      "blockNewTabs": true,
      "allowGoogleSearchTabs": false
    }
    """.utf8))
    try expect(!staleLegacyRules.isFresh(), "Legacy active browser rules without updatedAt should be stale")
    try rulesStore.clear()
    let clearedRules = try JSONDecoder().decode(ActiveBrowserRules.self, from: Data(contentsOf: rulesStore.fileURL))
    try expect(!clearedRules.active, "Clearing browser rules should make them inactive")
    try expect(!clearedRules.allowGoogleSearchTabs, "Clearing browser rules should disable Google search tabs")

    let heartbeatStore = BrowserGuardHeartbeatStore(fileURL: tempDirectory.appendingPathComponent("browser-guard-heartbeat.json"))
    try expect(!heartbeatStore.isFresh(maxAge: 5, now: Date(timeIntervalSince1970: 100)), "Missing browser heartbeat should be stale")
    try heartbeatStore.write(date: Date(timeIntervalSince1970: 98))
    try expect(heartbeatStore.isFresh(maxAge: 5, now: Date(timeIntervalSince1970: 100)), "Recent browser heartbeat should be fresh")
    try expect(!heartbeatStore.isFresh(maxAge: 1, now: Date(timeIntervalSince1970: 100)), "Old browser heartbeat should expire")

    let guardStateStore = BrowserGuardStateStore(fileURL: tempDirectory.appendingPathComponent("browser-guard-state.json"))
    try expect(guardStateStore.isEnabled(), "Missing browser guard state should default to enabled")
    try guardStateStore.write(enabled: false, date: Date(timeIntervalSince1970: 99))
    try expect(!guardStateStore.isEnabled(), "Browser guard state should persist disabled")
    try guardStateStore.write(enabled: true, date: Date(timeIntervalSince1970: 100))
    try expect(guardStateStore.isEnabled(), "Browser guard state should persist enabled")
    try? FileManager.default.removeItem(at: tempDirectory)

    print("IntentCoreSpec passed")
} catch {
    fputs("IntentCoreSpec failed: \(error)\n", stderr)
    exit(1)
}
