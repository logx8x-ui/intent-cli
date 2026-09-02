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
    object.removeValue(forKey: "isLeisure")
    object.removeValue(forKey: "accessMode")
    return try JSONSerialization.data(withJSONObject: object)
}

do {
    try expect(AppReleaseVersion.isNewer("v0.8.1", than: "0.8.0"), "patch releases should compare correctly")
    try expect(AppReleaseVersion.isNewer("1.0.0", than: "0.99.9"), "major releases should compare correctly")
    try expect(!AppReleaseVersion.isNewer("0.8", than: "0.8.0"), "equivalent versions should not update")
    try expect(!AppReleaseVersion.isNewer("0.7.9", than: "0.8.0"), "older versions should not update")

    let legacyAccessIntention = Intention(
        name: "Legacy focus",
        icon: "target",
        colorHex: "#FFFFFF",
        folder: "",
        allowedApps: [.init(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")],
        allowedWebsites: [],
        startupActions: [],
        restrictions: .init()
    )
    let decodedLegacyAccess = try JSONDecoder().decode(
        Intention.self,
        from: legacyIntentionData(legacyAccessIntention)
    )
    try expect(decodedLegacyAccess.accessMode == .whitelist, "Legacy intentions should default to whitelist mode")

    let blacklistedIntention = Intention(
        name: "No distractions",
        icon: "nosign",
        colorHex: "#FF3344",
        folder: "",
        allowedApps: [
            .init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
            .init(name: "Discord", bundleIdentifier: "com.hnc.Discord")
        ],
        allowedWebsites: [
            .init("youtube.com", browserBundleIdentifier: "org.mozilla.firefox")
        ],
        startupActions: [],
        restrictions: .init(),
        accessMode: .blacklist
    )
    try expect(
        blacklistedIntention.blockedAppBundleIdentifiers == ["com.hnc.Discord"],
        "A browser used to scope blocked sites should remain usable"
    )
    try expect(
        IntentionStartupPlanner.steps(for: blacklistedIntention).isEmpty,
        "Blacklist sessions must never launch blocked resources"
    )
    let blacklistSpec = FocusSessionSpec.make(for: blacklistedIntention)
    try expect(blacklistSpec.accessMode == .blacklist, "Focus specs should preserve blacklist mode")
    try expect(blacklistSpec.permitsApplication("org.mozilla.firefox"), "Scoped browsers should remain permitted")
    try expect(!blacklistSpec.permitsApplication("com.hnc.Discord"), "Blacklisted apps should be denied")
    try expect(blacklistSpec.permitsApplication("com.apple.MobileSMS"), "Unlisted apps should remain available")
    try expect(
        !FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "com.hnc.Discord",
            representedBundleIdentifier: nil,
            allowedBundleIdentifiers: blacklistSpec.allowedBundleIdentifiers,
            intentBundleIdentifier: "dev.loganmondi.intent",
            accessMode: .blacklist
        ),
        "Clicks targeting blacklisted apps should be prevented"
    )

    let blacklistedRules = ActiveBrowserRules(
        active: true,
        accessMode: .blacklist,
        allowedWebsites: ["youtube.com"],
        blockTabSwitching: true,
        blockNavigation: true,
        blockNewTabs: false
    )
    let decodedBlacklistedRules = try JSONDecoder().decode(
        ActiveBrowserRules.self,
        from: JSONEncoder().encode(blacklistedRules)
    )
    try expect(decodedBlacklistedRules.accessMode == .blacklist, "Browser rules should round-trip blacklist mode")

    let installedForAI = [
        AllowedApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
        AllowedApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")
    ]
    let rawAIPlan = AIIntentionPlan(intentions: [
        AIIntentionSuggestion(
            name: "  Reply to messages  ",
            purpose: " Clear important replies ",
            appBundleIdentifiers: ["com.fake.app", "com.apple.MobileSMS", "org.mozilla.firefox"],
            websites: [
                .init(value: "https://instagram.com/direct", browserBundleIdentifier: "org.mozilla.firefox"),
                .init(value: "example.com", browserBundleIdentifier: "com.fake.app")
            ],
            allowBrowserSearches: true,
            restrictions: [
                .init(kind: .timer, durationMinutes: 3),
                .init(kind: .coolDown, durationMinutes: 0)
            ],
            frictions: [
                .init(kind: .typedPhrase, text: "I want to reply right now")
            ]
        ),
        AIIntentionSuggestion(
            name: "   ",
            purpose: "Discard me",
            appBundleIdentifiers: [],
            websites: [],
            allowBrowserSearches: false
        )
    ])
    let validatedAIPlan = rawAIPlan.validated(against: installedForAI)
    try expect(validatedAIPlan.intentions.count == 1, "AI plans should discard unnamed intentions")
    try expect(
        validatedAIPlan.intentions[0].appBundleIdentifiers == ["org.mozilla.firefox", "com.apple.MobileSMS"],
        "AI plans should discard invented apps and sort installed apps"
    )
    try expect(
        validatedAIPlan.intentions[0].websites == [.init(value: "instagram.com/direct", browserBundleIdentifier: "org.mozilla.firefox")],
        "AI plans should keep websites only for selected installed browsers"
    )
    try expect(
        validatedAIPlan.intentions[0].restrictions.contains { $0.kind == .timer && $0.durationMinutes == 3 },
        "AI plans should preserve requested timers"
    )
    try expect(
        validatedAIPlan.intentions[0].restrictions.contains { $0.kind == .coolDown && $0.durationMinutes == 1 },
        "AI plans should clamp restriction durations"
    )
    try expect(
        validatedAIPlan.intentions[0].frictions.first?.friction(intentionName: "Reply to messages")
            == .typedPhrase("I want to reply right now"),
        "AI plans should preserve editable friction suggestions"
    )
    let aiPrompt = AIIntentionPrompt.user(description: "University and messages", installedApps: installedForAI)
    try expect(aiPrompt.contains("Firefox | org.mozilla.firefox"), "AI prompts should include the installed app catalog")
    try expect(aiPrompt.contains("University and messages"), "AI prompts should include the person's activities")

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

    var leisure = instagram
    leisure.id = "leisure"
    leisure.name = "Leisure"
    leisure.isLeisure = true
    let leisureSpec = FocusSessionSpec.make(for: leisure)
    try expect(!leisureSpec.strictSingleApp, "Leisure should not lock to one app")
    try expect(!leisureSpec.blockAppSwitching, "Leisure should allow switching to every app")
    try expect(!leisureSpec.blockNewApps, "Leisure should allow launching every app")
    try expect(!leisureSpec.keepFocused, "Leisure should not force focus back to an allowed app")
    try expect(!leisureSpec.blockBrowserTabEscape, "Leisure should not lock browser tabs or websites")
    try expect(
        leisureSpec.startupSteps.contains { step in
            if case .openURL(_, let bundleIdentifier) = step {
                return bundleIdentifier == "org.mozilla.firefox"
            }
            return false
        },
        "Leisure should still open its configured websites"
    )
    let leisureRoundTrip = try JSONDecoder().decode(
        Intention.self,
        from: JSONEncoder().encode(leisure)
    )
    try expect(leisureRoundTrip.isLeisure, "Leisure should persist in intention storage")

    var emptyLeisure = leisure
    emptyLeisure.allowedApps = []
    emptyLeisure.allowedWebsites = []
    emptyLeisure.startupActions = []
    let emptyLeisureSpec = FocusSessionSpec.make(for: emptyLeisure)
    try expect(emptyLeisureSpec.startupSteps.isEmpty, "Leisure should be runnable without startup resources")
    try expect(emptyLeisureSpec.fallbackBundleIdentifier.isEmpty, "Empty Leisure should not force a fallback app")

    var timedLeisure = leisure
    timedLeisure.restrictionNodes.append(
        .init(kind: .timer, position: .zero, durationMinutes: 10)
    )
    try expect(
        !FocusSessionSpec.make(for: timedLeisure).allowsManualFinish,
        "Leisure should still honor time restrictions"
    )

    let legacyLeisureDefault = try JSONDecoder().decode(
        Intention.self,
        from: legacyIntentionData(instagram)
    )
    try expect(!legacyLeisureDefault.isLeisure, "Existing intentions should remain focused by default")
    try expect(
        FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: "com.apple.dock"),
        "Mission Control should be treated as a temporary system switcher"
    )
    try expect(
        !FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: "io.remnote"),
        "Regular unallowed apps should not get Mission Control grace"
    )
    try expect(
        FocusSystemShortcutPolicy.isSpaceNavigationKey(126),
        "Control-Up should remain available to open Mission Control"
    )
    try expect(
        FocusSystemShortcutPolicy.isSpaceNavigationKey(123),
        "Control-Left should remain available for macOS Space navigation"
    )
    let activeTransitionGrace = Date(timeIntervalSinceNow: 1)
    try expect(
        FocusForegroundPolicy.shouldHonorSystemTransitionGrace(
            bundleIdentifier: "com.apple.finder",
            graceUntil: activeTransitionGrace,
            now: Date()
        ),
        "Finder should get enough grace for a Mission Control Space transition to finish"
    )
    try expect(
        !FocusForegroundPolicy.shouldHonorSystemTransitionGrace(
            bundleIdentifier: "com.apple.finder",
            graceUntil: .distantPast,
            now: Date()
        ),
        "A blank desktop should refocus to an allowed application after transition grace"
    )
    let allowedClickBundles: Set<String> = ["org.mozilla.firefox"]
    try expect(
        FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "org.mozilla.firefox",
            representedBundleIdentifier: nil,
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "Clicks inside an allowed application should pass through"
    )
    try expect(
        !FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "com.spotify.client",
            representedBundleIdentifier: nil,
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "Clicks inside an unallowed application should stop before activation"
    )
    try expect(
        FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "com.apple.dock",
            representedBundleIdentifier: "org.mozilla.firefox",
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "A Dock or Mission Control target representing an allowed app should pass through"
    )
    try expect(
        !FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "com.apple.dock",
            representedBundleIdentifier: "com.spotify.client",
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "A Dock or Mission Control target representing an unallowed app should stop"
    )
    try expect(
        FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: "com.apple.Spotlight",
            representedBundleIdentifier: nil,
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "Spotlight should remain available to reopen an allowed app"
    )
    try expect(
        !FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: nil,
            representedBundleIdentifier: nil,
            allowedBundleIdentifiers: allowedClickBundles,
            intentBundleIdentifier: "dev.loganmondi.intent"
        ),
        "Unknown and desktop click targets should stay blocked"
    )
    let temporaryAppURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("IntentBundleResolver-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Transient.app", isDirectory: true)
    let temporaryContentsURL = temporaryAppURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryContentsURL,
        withIntermediateDirectories: true
    )
    let temporaryInfoPlist: [String: Any] = [
        "CFBundleIdentifier": "dev.intent.transient",
        "CFBundleDisplayName": "Transient Intent App"
    ]
    let temporaryInfoData = try PropertyListSerialization.data(
        fromPropertyList: temporaryInfoPlist,
        format: .binary,
        options: 0
    )
    try temporaryInfoData.write(
        to: temporaryContentsURL.appendingPathComponent("Info.plist"),
        options: .atomic
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryAppURL.deletingLastPathComponent())
    }
    try expect(
        ApplicationBundleIdentifierResolver.resolve(from: temporaryAppURL)
            == "dev.intent.transient",
        "Click targets should resolve an application bundle without constructing NSBundle"
    )
    try expect(
        ApplicationBundleIdentifierResolver.metadata(from: temporaryAppURL)?.displayName
            == "Transient Intent App",
        "The installed app catalog should read safe application metadata without constructing NSBundle"
    )
    try expect(
        ApplicationBundleIdentifierResolver.resolve(
            from: temporaryContentsURL.appendingPathComponent("MacOS/Transient")
        ) == "dev.intent.transient",
        "Click targets inside an application bundle should resolve the enclosing application"
    )
    try expect(
        ApplicationBundleIdentifierResolver.resolve(from: URL(string: "https://example.com")!) == nil,
        "Web URLs exposed by accessibility should not be treated as application bundles"
    )
    try expect(
        ApplicationBundleIdentifierResolver.resolve(
            from: FileManager.default.temporaryDirectory
                .appendingPathComponent("Missing.app")
        ) == nil,
        "Missing or transient application paths should fail closed without crashing"
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
    try expect(
        dataScienceStartup.first == .openURL("https://github.com", bundleIdentifier: "org.mozilla.firefox"),
        "The first allowed website should launch before secondary apps"
    )
    try expect(
        !dataScienceStartup.contains(.openBundle("org.mozilla.firefox")),
        "A browser opened by an allowed URL must not also create a spare blank tab"
    )
    try expect(
        IntentionStartupPlanner.fallbackBundleIdentifier(for: dataScience) == "org.mozilla.firefox",
        "An intention with a startup website should leave its browser in front"
    )
    try expect(!dataScienceStartup.contains(.openBundle("com.openai.codex")), "Don't-start-up should keep Codex closed initially")
    try expect(!dataScienceStartup.contains(.openBundle("io.remnote")), "Don't-start-up should keep RemNote closed initially")
    try expect(dataScienceStartup.contains(.openURL("https://github.com", bundleIdentifier: "org.mozilla.firefox")), "Allowed websites should start in their assigned browser")

    var frictionOrderIntention = dataScience
    frictionOrderIntention.frictionNodes = [
        .init(id: "second", friction: .typedPhrase("second"), position: .init(x: 0, y: 100)),
        .init(id: "first", friction: .countdown(seconds: 5), position: .init(x: 0, y: -100))
    ]
    try expect(frictionOrderIntention.orderedFrictionNodes.map(\.id) == ["first", "second"], "Higher friction nodes should run first")

    var timedIntention = dataScience
    timedIntention.restrictionNodes.append(contentsOf: [
        .init(kind: .coolDown, position: .zero, durationMinutes: 15),
        .init(kind: .coolDown, position: .zero, durationMinutes: 30),
        .init(kind: .timer, position: .zero, durationMinutes: 45),
        .init(kind: .timer, position: .zero, durationMinutes: 25)
    ])
    try expect(timedIntention.coolDownMinutes == 30, "The strictest cooldown should win")
    try expect(timedIntention.timerMinutes == 25, "The shortest session timer should win")
    try expect(timedIntention.showsCooldownRemainingTime, "Cooldown display should default on")
    try expect(timedIntention.timerLocksManualFinish, "Timer lock should default on")
    try expect(
        !FocusSessionSpec.make(for: timedIntention).allowsManualFinish,
        "A locked timer should prevent the finish shortcut from ending the session"
    )

    timedIntention.restrictionNodes = [
        .init(
            kind: .coolDown,
            position: .zero,
            durationMinutes: 30,
            showsRemainingTime: false
        ),
        .init(
            kind: .timer,
            position: .zero,
            durationMinutes: 25,
            showsRemainingTime: false,
            timerDisplayPosition: .bottomLeading,
            locksSessionUntilTimerEnds: false
        )
    ]
    try expect(!timedIntention.showsCooldownRemainingTime, "Cooldown badge should be configurable")
    try expect(!timedIntention.timerLocksManualFinish, "Timer lock should be configurable")

    var endTimeIntention = dataScience
    endTimeIntention.restrictionNodes = [
        .init(
            kind: .endTime,
            position: .zero,
            endTimeHour: 14,
            endTimeMinute: 0,
            usesPresetEndTime: true
        )
    ]
    var perthCalendar = Calendar(identifier: .gregorian)
    perthCalendar.timeZone = TimeZone(identifier: "Australia/Perth")!
    let startBeforeEndTime = perthCalendar.date(
        from: DateComponents(year: 2026, month: 7, day: 29, hour: 13, minute: 0)
    )!
    let expectedSameDayEnd = perthCalendar.date(
        from: DateComponents(year: 2026, month: 7, day: 29, hour: 14, minute: 0)
    )!
    try expect(
        endTimeIntention.endTimeDate(after: startBeforeEndTime, calendar: perthCalendar) == expectedSameDayEnd,
        "End Time should use the user's local clock on the same day"
    )
    let startAfterEndTime = perthCalendar.date(
        from: DateComponents(year: 2026, month: 7, day: 29, hour: 15, minute: 0)
    )!
    let expectedNextDayEnd = perthCalendar.date(
        from: DateComponents(year: 2026, month: 7, day: 30, hour: 14, minute: 0)
    )!
    try expect(
        endTimeIntention.endTimeDate(after: startAfterEndTime, calendar: perthCalendar) == expectedNextDayEnd,
        "End Time should use tomorrow when today's selected time has passed"
    )
    try expect(endTimeIntention.endTimeLocksManualFinish, "End Time should lock early finishing by default")
    try expect(
        !FocusSessionSpec.make(for: endTimeIntention).allowsManualFinish,
        "A locked End Time should prevent the finish shortcut before the selected time"
    )
    endTimeIntention.restrictionNodes[0].usesPresetEndTime = false
    try expect(endTimeIntention.requiresRuntimeEndTime, "End Time should choose its finish time at launch by default")
    try expect(
        endTimeIntention.endTimeDate(after: startBeforeEndTime, calendar: perthCalendar) == nil,
        "An End Time without a preset should not silently use a stored clock time"
    )

    endTimeIntention.closeSessionResourcesOnFinish = true
    try expect(
        FocusSessionSpec.make(for: endTimeIntention).closeSessionResourcesOnFinish,
        "The session spec should preserve the intention's resource cleanup preference"
    )
    try expect(
        FocusSessionSpec.make(for: endTimeIntention)
            .allowedWebsitesByBrowser["org.mozilla.firefox"]?
            .contains("github.com") == true,
        "The session spec should carry browser websites into cleanup"
    )
    let encodedCleanupIntention = try JSONEncoder().encode(endTimeIntention)
    let decodedCleanupIntention = try JSONDecoder().decode(Intention.self, from: encodedCleanupIntention)
    try expect(
        decodedCleanupIntention.closeSessionResourcesOnFinish,
        "The session resource cleanup preference should persist"
    )

    let firefoxStartupURL = "https://instagram.com/direct"
    try expect(
        BrowserLaunchPlanner.openArguments(
            bundleIdentifier: "org.mozilla.firefox",
            url: firefoxStartupURL,
            isRunning: false
        ) == ["-b", "org.mozilla.firefox", "--args", "-url", firefoxStartupURL],
        "A closed Firefox should receive its allowed URL at launch without creating a spare blank tab"
    )
    try expect(
        BrowserLaunchPlanner.openArguments(
            bundleIdentifier: "org.mozilla.firefox",
            url: firefoxStartupURL,
            isRunning: true
        ) == ["-b", "org.mozilla.firefox", firefoxStartupURL],
        "A running Firefox should open the allowed URL normally"
    )

    var artworkIntention = dataScience
    artworkIntention.usesCustomIcon = true
    artworkIntention.customIconData = Data([0, 1, 2, 3])
    let artworkRoundTrip = try JSONDecoder().decode(
        Intention.self,
        from: JSONEncoder().encode(artworkIntention)
    )
    try expect(artworkRoundTrip.usesCustomIcon, "Custom intention artwork choice should persist")
    try expect(artworkRoundTrip.customIconData == Data([0, 1, 2, 3]), "Custom intention artwork data should persist")

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
    let freshStore = IntentionStore(fileURL: tempDirectory.appendingPathComponent("fresh-intentions.json"))
    let freshIntentions = try freshStore.load()
    try expect(freshIntentions.isEmpty, "A first install should start with a blank desktop")
    try expect(FileManager.default.fileExists(atPath: freshStore.fileURL.path), "A blank first-run store should be persisted")

    let cooldownStore = IntentionCooldownStore(fileURL: tempDirectory.appendingPathComponent("cooldowns.json"))
    let cooldownStart = Date(timeIntervalSince1970: 1_800_000_000)
    let cooldownEnd = try cooldownStore.begin(
        intentionID: "instagram-replies",
        minutes: 30,
        now: cooldownStart
    )
    try expect(
        cooldownEnd == cooldownStart.addingTimeInterval(1_800),
        "Cooldown should begin when a session finishes"
    )
    let activeCooldown = try cooldownStore.nextAllowedDate(
        for: "instagram-replies",
        now: cooldownStart.addingTimeInterval(1_799)
    )
    try expect(
        activeCooldown == cooldownEnd,
        "Cooldown should block the intention until it expires"
    )
    let expiredCooldown = try cooldownStore.nextAllowedDate(
        for: "instagram-replies",
        now: cooldownEnd
    )
    try expect(
        expiredCooldown == nil,
        "Cooldown should allow the intention at its expiry time"
    )

    let tabSnapshotStore = BrowserTabSnapshotStore(
        fileURL: tempDirectory.appendingPathComponent("browser-tabs.json")
    )
    let tabSnapshot = BrowserTabSnapshot(
        browserBundleIdentifier: "org.mozilla.firefox",
        tabs: [
            .init(
                id: 8,
                windowID: 2,
                index: 0,
                title: "Instagram",
                url: "https://instagram.com/direct",
                active: true
            )
        ],
        updatedAt: cooldownStart
    )
    try tabSnapshotStore.write(tabSnapshot)
    try expect(
        tabSnapshotStore.load(maxAge: 1, now: cooldownStart) == tabSnapshot,
        "Browser tab snapshots should round-trip"
    )

    let tabCommandStore = BrowserTabCommandStore(
        fileURL: tempDirectory.appendingPathComponent("browser-tab-command.json")
    )
    let tabCommand = BrowserTabCommand(
        tabID: 8,
        windowID: 2,
        createdAt: cooldownStart,
        action: .close
    )
    try tabCommandStore.write(tabCommand)
    try expect(tabCommandStore.take() == tabCommand, "Browser tab commands should round-trip with their action")
    try expect(tabCommandStore.take() == nil, "Browser tab commands should be consumed once")

    let intentionStore = IntentionStore(fileURL: tempDirectory.appendingPathComponent("intentions.json"))
    try intentionStore.save(intentions)
    let loadedIntentions = try intentionStore.load()
    try expect(loadedIntentions == intentions, "IntentionStore should round-trip intentions")

    try Data("not valid intention JSON".utf8).write(to: intentionStore.fileURL, options: [.atomic])
    let recoveringIntentionStore = IntentionStore(fileURL: intentionStore.fileURL)
    let recoveredIntentions = try recoveringIntentionStore.load()
    try expect(recoveredIntentions == intentions, "IntentionStore should recover from its last-good backup")
    try expect(recoveringIntentionStore.didRecoverFromBackup, "IntentionStore should report backup recovery")

    var scheduleCalendar = Calendar(identifier: .gregorian)
    scheduleCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let scheduleDate = scheduleCalendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 20,
        hour: 9,
        minute: 30
    ))!
    let scheduleStore = IntentScheduleStore(fileURL: tempDirectory.appendingPathComponent("schedules.json"))
    let freshSchedules = try scheduleStore.load()
    try expect(freshSchedules.isEmpty, "A first install should start with no scheduled intentions")

    let onceSchedule = IntentSchedule(
        id: "once",
        intentionID: "data-science",
        recurrence: .once,
        scheduledAt: scheduleDate
    )
    let dailySchedule = IntentSchedule(
        id: "daily",
        intentionID: "emails",
        recurrence: .daily,
        scheduledAt: scheduleDate
    )
    let weeklySchedule = IntentSchedule(
        id: "weekly",
        intentionID: "instagram",
        recurrence: .weekly,
        scheduledAt: scheduleDate,
        weekdays: [ScheduleWeekday.monday.rawValue, ScheduleWeekday.wednesday.rawValue]
    )
    try scheduleStore.save([onceSchedule, dailySchedule, weeklySchedule])
    let loadedSchedules = try scheduleStore.load()
    try expect(
        loadedSchedules == [onceSchedule, dailySchedule, weeklySchedule],
        "IntentScheduleStore should round-trip schedules"
    )
    try Data("not valid schedule JSON".utf8).write(to: scheduleStore.fileURL, options: [.atomic])
    let recoveringScheduleStore = IntentScheduleStore(fileURL: scheduleStore.fileURL)
    let recoveredSchedules = try recoveringScheduleStore.load()
    try expect(
        recoveredSchedules == [onceSchedule, dailySchedule, weeklySchedule],
        "IntentScheduleStore should recover from its last-good backup"
    )
    try expect(recoveringScheduleStore.didRecoverFromBackup, "IntentScheduleStore should report backup recovery")
    try expect(onceSchedule.occurs(on: scheduleDate, calendar: scheduleCalendar), "A once schedule should occur on its saved date")
    try expect(onceSchedule.triggerKeyIfDue(at: scheduleDate, calendar: scheduleCalendar) != nil, "A schedule should become due at its saved minute")
    try expect(
        onceSchedule.triggerKeyIfDue(at: scheduleDate.addingTimeInterval(89), calendar: scheduleCalendar) != nil,
        "A schedule should survive a brief polling or wake delay"
    )
    try expect(
        onceSchedule.triggerKeyIfDue(at: scheduleDate.addingTimeInterval(90), calendar: scheduleCalendar) == nil,
        "A schedule should not launch after its catch-up window"
    )
    let nextDay = scheduleCalendar.date(byAdding: .day, value: 1, to: scheduleDate)!
    try expect(dailySchedule.occurs(on: nextDay, calendar: scheduleCalendar), "A daily schedule should occur the next day")
    let wednesday = scheduleCalendar.date(byAdding: .day, value: 2, to: scheduleDate)!
    let thursday = scheduleCalendar.date(byAdding: .day, value: 3, to: scheduleDate)!
    try expect(weeklySchedule.occurs(on: wednesday, calendar: scheduleCalendar), "A weekly schedule should occur on a selected weekday")
    try expect(!weeklySchedule.occurs(on: thursday, calendar: scheduleCalendar), "A weekly schedule should skip an unselected weekday")
    try expect(
        weeklySchedule.nextOccurrence(after: scheduleDate, calendar: scheduleCalendar) == wednesday,
        "A weekly schedule should find its next selected day"
    )

    let rulesStore = ActiveBrowserRulesStore(fileURL: tempDirectory.appendingPathComponent("browser-rules.json"))
    let browserRules = ActiveBrowserRules(
        active: true,
        allowedWebsites: ["github.com"],
        allowedWebsitesByBrowser: [
            "org.mozilla.firefox": ["github.com"],
            "com.google.Chrome": ["instagram.com/direct"]
        ],
        startupWebsitesByBrowser: [
            "org.mozilla.firefox": ["https://github.com/"],
            "com.google.Chrome": ["https://www.instagram.com/direct/inbox/"]
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
    try expect(
        loadedRules.startupWebsitesByBrowser["org.mozilla.firefox"] == ["https://github.com/"],
        "Full startup URLs should remain browser-specific"
    )
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

    // MARK: AI history
    let historyURL = tempDirectory.appendingPathComponent("ai-history.json")
    let historyStore = AIHistoryStore(fileURL: historyURL)
    try expect(historyStore.load().isEmpty, "Missing AI history should start empty")

    var session = AIWorkspaceSession(
        title: "Emails",
        messages: [
            .init(role: .user, content: "Add a timer to @[Emails](emails)"),
            .init(role: .assistant, content: "Updated @Emails with a 10-minute timer.")
        ],
        draft: Intention(
            id: "emails",
            name: "Emails",
            icon: "envelope",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init()
        ),
        targetIntentionID: "emails",
        status: .draft
    )
    try historyStore.save([session])
    let loadedHistory = historyStore.load()
    try expect(loadedHistory.count == 1, "AI history should round-trip")
    try expect(loadedHistory[0].targetIntentionID == "emails", "AI history should keep the stable intention id")
    try expect(loadedHistory[0].status == .draft, "AI history should preserve draft status")

    session.status = .applied
    session.finalisedAt = Date(timeIntervalSince1970: 1_800_000_100)
    session.touch(at: Date(timeIntervalSince1970: 1_800_000_100))
    try historyStore.save([session])
    try expect(historyStore.load()[0].status == .applied, "Applied drafts should remain in history")

    try "not-json".write(to: historyURL, atomically: true, encoding: .utf8)
    let recovered = AIHistoryStore(fileURL: historyURL).load()
    try expect(recovered.isEmpty, "Corrupt AI history should recover to an empty list")
    let backupNames = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
    try expect(
        backupNames.contains { $0.contains("corrupt-") },
        "Corrupt AI history should be backed up instead of deleting intentions"
    )

    let mentionIntentions = [
        Intention(
            id: "emails",
            name: "Emails",
            icon: "envelope",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init()
        ),
        Intention(
            id: "data-science",
            name: "Data Science",
            icon: "function",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init()
        )
    ]
    let encoded = AIIntentionMentionResolver.encodeMention(displayName: "Emails", intentionID: "emails")
    try expect(encoded == "@[Emails](emails)", "Mentions should encode a stable intention id")
    switch AIIntentionMentionResolver.resolvePrimaryTarget(
        in: "Add a 15-minute timer to \(encoded).",
        intentions: mentionIntentions
    ) {
    case .resolved(let id, let name):
        try expect(id == "emails" && name == "Emails", "Encoded mentions should resolve by id")
    default:
        throw SpecFailure(description: "Encoded mention should resolve")
    }

    var renamed = mentionIntentions
    renamed[0].name = "Inbox"
    switch AIIntentionMentionResolver.resolvePrimaryTarget(
        in: "Change \(encoded) so it opens WhatsApp too.",
        intentions: renamed
    ) {
    case .resolved(let id, let name):
        try expect(id == "emails" && name == "Inbox", "Renamed intentions should still resolve by id")
    default:
        throw SpecFailure(description: "Renamed intention mention should still resolve")
    }

    switch AIIntentionMentionResolver.resolvePrimaryTarget(
        in: "Update @[Gone](missing-id).",
        intentions: mentionIntentions
    ) {
    case .missing(let id, _):
        try expect(id == "missing-id", "Deleted intentions should surface a missing mention state")
    default:
        throw SpecFailure(description: "Missing intention should not resolve to another intention")
    }

    switch AIIntentionMentionResolver.resolvePrimaryTarget(
        in: "Update Emails and Data Science together",
        intentions: mentionIntentions
    ) {
    case .ambiguous(let matches):
        try expect(matches.count == 2, "Ambiguous multi-intention prompts should ask for clarification")
    default:
        throw SpecFailure(description: "Ambiguous prompts should not mutate multiple intentions")
    }

    let typeahead = AIIntentionMentionResolver.typeahead(query: "em", intentions: mentionIntentions)
    try expect(typeahead.map(\.id) == ["emails"], "@ typeahead should filter intentions case-insensitively")

    let noFrictionPlan = AIIntentionPlan(intentions: [
        AIIntentionSuggestion(
            name: "Study",
            purpose: "Focus",
            appBundleIdentifiers: ["org.mozilla.firefox"],
            websites: [],
            allowBrowserSearches: false,
            restrictions: [],
            frictions: []
        )
    ]).validated(against: [AllowedApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")])
    try expect(noFrictionPlan.intentions[0].frictions.isEmpty, "Unrequested friction must remain empty")
    try expect(noFrictionPlan.intentions[0].restrictions.isEmpty, "Unrequested restrictions must remain empty")

    // MARK: Calendar sync
    let prefsStore = CalendarPreferencesStore(fileURL: tempDirectory.appendingPathComponent("calendar-preferences.json"))
    try prefsStore.save(CalendarPreferences(appleVisibleCalendarIDs: ["home"]))
    try expect(prefsStore.load().appleVisibleCalendarIDs == ["home"], "Calendar preferences should round-trip")

    let localOnlySchedule = IntentSchedule(
        id: "local-1",
        intentionID: "emails",
        scheduledAt: scheduleDate
    )
    try expect(localOnlySchedule.sync == nil, "Local schedules should work with no providers")
    try expect(localOnlySchedule.triggerKeyIfDue(at: scheduleDate, calendar: scheduleCalendar) != nil, "Local schedules should still become due")

    let linkedEvent = ExternalCalendarEvent(
        id: "evt-1",
        provider: .apple,
        calendarID: "home",
        title: "Intent: Emails",
        startAt: scheduleDate.addingTimeInterval(3_600),
        linkedScheduleID: "local-1",
        supportsIntentSync: true,
        lastModifiedAt: scheduleDate.addingTimeInterval(10)
    )
    let unrelatedEvent = ExternalCalendarEvent(
        id: "evt-2",
        provider: .google,
        calendarID: "primary",
        title: "Dentist",
        startAt: scheduleDate,
        supportsIntentSync: false
    )
    let coordinator = CalendarSyncCoordinator()
    try expect(!coordinator.shouldLaunch(from: unrelatedEvent), "Unrelated external events must never trigger intentions")
    try expect(coordinator.shouldLaunch(from: linkedEvent), "Only linked Intent events may relate to launches")

    var syncedSchedule = localOnlySchedule
    syncedSchedule.sync = ScheduleSyncMetadata(
        provider: .apple,
        calendarID: "home",
        externalEventID: "evt-1",
        lastLocalModifiedAt: scheduleDate
    )
    let externallyUpdated = coordinator.applyExternalChange(to: syncedSchedule, from: linkedEvent)
    try expect(externallyUpdated?.scheduledAt == linkedEvent.startAt, "External edits should update linked local schedules")

    let deleted = coordinator.handleExternalDeletion(of: syncedSchedule)
    try expect(!deleted.isEnabled && deleted.sync == nil, "External deletion should disable/unlink without deleting the intention")

    let deduped = CalendarSyncMapper.deduplicatedEvents([
        linkedEvent,
        unrelatedEvent,
        linkedEvent
    ])
    try expect(deduped.count == 2, "Calendar events should deduplicate by provider/calendar/id")

    try expect(
        CalendarSyncMapper.resolveConflict(
            localModified: scheduleDate.addingTimeInterval(20),
            externalModified: scheduleDate.addingTimeInterval(5)
        ) == .keepLocal,
        "Newer local edits should win conflicts"
    )
    try expect(
        CalendarSyncMapper.resolveConflict(
            localModified: scheduleDate,
            externalModified: scheduleDate.addingTimeInterval(30)
        ) == .keepExternal,
        "Newer external edits should win conflicts"
    )

    let unsupported = ExternalCalendarEvent(
        id: "month",
        provider: .google,
        calendarID: "primary",
        title: "Monthly review",
        startAt: scheduleDate,
        recurrenceSummary: "MONTHLY",
        supportsIntentSync: false
    )
    try expect(!coordinator.shouldLaunch(from: unsupported), "Unsupported recurrence must remain display-only")

    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(account: "google-calendar", data: Data("token".utf8))
    let loadedToken = try tokenStore.load(account: "google-calendar")
    try expect(loadedToken == Data("token".utf8), "Token store abstraction should round-trip")
    try tokenStore.delete(account: "google-calendar")
    let clearedToken = try tokenStore.load(account: "google-calendar")
    try expect(clearedToken == nil, "Token store should clear credentials")

    try expect(
        CalendarSyncMapper.scheduleID(from: "intent://schedule/local-1") == "local-1",
        "Intent schedule URLs should map back to local schedule ids"
    )
    try expect(
        CalendarSyncMapper.googlePrivateProperty(scheduleID: "local-1")["intentScheduleId"] == "local-1",
        "Google private properties should carry the schedule id"
    )

    let display = coordinator.mergeVisibleEvents(
        localSchedules: [syncedSchedule],
        intentionNames: ["emails": "Emails"],
        externalEvents: [linkedEvent, unrelatedEvent, unsupported]
    )
    try expect(display.contains { if case .intentSchedule = $0 { return true }; return false }, "Merged display should keep Intent schedules")
    try expect(
        display.filter {
            switch $0 {
            case .intentSchedule(let schedule, _):
                return schedule.id == linkedEvent.linkedScheduleID
            case .linkedExternal(let event):
                return event.id == linkedEvent.id
            default:
                return false
            }
        }.count == 1,
        "A linked external event should not duplicate its local schedule"
    )
    try expect(display.contains { if case .external = $0 { return true }; return false }, "Merged display should keep unrelated events")

    // MARK: Zero Drift
    let zeroDriftStart = Date(timeIntervalSince1970: 1_800_000_000)
    let durationEnd = ZeroDriftTiming.durationEndDate(
        from: zeroDriftStart,
        days: 1,
        hours: 2,
        minutes: 3
    )
    try expect(
        durationEnd == zeroDriftStart.addingTimeInterval(TimeInterval((24 * 60 + 2 * 60 + 3) * 60)),
        "Zero Drift duration should combine days, hours, and minutes"
    )
    try expect(
        ZeroDriftTiming.durationEndDate(from: zeroDriftStart, days: 0, hours: 0, minutes: 0) == nil,
        "Zero Drift should reject an empty duration"
    )

    var zeroDriftCalendar = Calendar(identifier: .gregorian)
    zeroDriftCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let currentComponents = DateComponents(
        calendar: zeroDriftCalendar,
        timeZone: zeroDriftCalendar.timeZone,
        year: 2027,
        month: 1,
        day: 1,
        hour: 15,
        minute: 30
    )
    let targetComponents = DateComponents(
        calendar: zeroDriftCalendar,
        timeZone: zeroDriftCalendar.timeZone,
        year: 2027,
        month: 1,
        day: 1,
        hour: 14,
        minute: 0
    )
    let currentTime = zeroDriftCalendar.date(from: currentComponents)!
    let targetTime = zeroDriftCalendar.date(from: targetComponents)!
    let nextTarget = ZeroDriftTiming.nextEndDate(
        matching: targetTime,
        after: currentTime,
        calendar: zeroDriftCalendar
    )
    try expect(
        nextTarget == zeroDriftCalendar.date(byAdding: .day, value: 1, to: targetTime),
        "A passed Zero Drift clock time should resolve to the next day"
    )

    let zeroDriftURL = tempDirectory.appendingPathComponent("zero-drift.json")
    let zeroDriftStore = ZeroDriftStateStore(fileURL: zeroDriftURL)
    let zeroDriftState = ZeroDriftState(
        startedAt: zeroDriftStart,
        endsAt: zeroDriftStart.addingTimeInterval(3_600)
    )
    try zeroDriftStore.save(zeroDriftState)
    let loadedZeroDriftState = try zeroDriftStore.load(now: zeroDriftStart)
    try expect(
        loadedZeroDriftState == zeroDriftState,
        "An active Zero Drift state should survive relaunch"
    )
    let expiredZeroDriftState = try zeroDriftStore.load(
        now: zeroDriftStart.addingTimeInterval(7_200)
    )
    try expect(
        expiredZeroDriftState == nil,
        "An expired Zero Drift state should clear itself"
    )

    try? FileManager.default.removeItem(at: tempDirectory)

    print("IntentCoreSpec passed")
} catch {
    fputs("IntentCoreSpec failed: \(error)\n", stderr)
    exit(1)
}
