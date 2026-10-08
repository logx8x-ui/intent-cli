import Foundation
import CoreGraphics
import IntentCore
import IntentLock

func runRestorationFocusSpecs() throws {
    try expect(HiddenWorkspaceRestorationPolicy.onUserReveal.historicalDeferredVisibility(isHidden: true) == .alreadyHidden,
        "A historical deferred minimized window satisfies the next session's coverage without transferring ownership or revealing it")
    try expect(HiddenWorkspaceRestorationPolicy.onUserReveal.historicalDeferredVisibility(isHidden: false) == .retireForCurrentOwnership,
        "A positively revealed historical window retires its old entry before the new controller acquires a new hiding effect")
    try expect(HiddenWorkspaceRestorationPolicy.onUserReveal.historicalDeferredVisibility(isHidden: nil) == .unresolved,
        "Unavailable AX visibility cannot retire historical ownership or falsely satisfy hidden coverage")
    for hidden in [Optional(true), Optional(false), nil] {
        try expect(HiddenWorkspaceRestorationPolicy.automatic.historicalDeferredVisibility(isHidden: hidden) == .unresolved,
            "An automatic recovery entry cannot use the historical quiet-ownership shortcut")
    }
    try expect(HiddenWorkspaceRestorationPolicy.onUserReveal.atStop(requested: .automatic, ownsEntry: false) == .onUserReveal
        && HiddenWorkspaceRestorationPolicy.onUserReveal.atStop(requested: .automatic, ownsEntry: true) == .automatic,
        "Safety recovery retains earlier quiet ownership but releases visibility effects acquired by the current controller")
    for previous in [HiddenWorkspaceRestorationPolicy.automatic, .onUserReveal, .restoreOwnedWorkspace] {
        for currentOwner in [false, true] {
            let recovered = previous.atStop(requested: .restoreOwnedWorkspace, ownsEntry: currentOwner)
            try expect(recovered == .automatic && recovered.action(isHidden: true) == .reveal,
                "Finish restores both current ownership and older Intent-owned deferred visibility")
            try expect(recovered.action(isHidden: false) == .relinquish && recovered.action(isHidden: nil) == .retain,
                "Restoration neither touches already visible windows nor guesses unavailable state")
            let persisted = try JSONDecoder().decode(HiddenWorkspaceRestorationPolicy.self,
                from: JSONEncoder().encode(recovered))
            try expect(persisted.needsRecoveryObservation(isParking: false),
                "Failed restoration remains retryable across restart instead of becoming permanently minimized")
        }
    }
    let firefoxAnchor = FocusStartAnchor(nativeWindowID: 118, pid: 77, bundleIdentifier: "org.mozilla.firefox",
        browserWindowID: 8, browserTabID: 82, browserSessionID: "profile-A")
    let nativeAnchor = FocusStartAnchor(nativeWindowID: 119, pid: 78, bundleIdentifier: "com.apple.calculator")
    try expect(nativeAnchor.isValid && nativeAnchor.matchesBrowserSnapshot(nil),
        "Non-browser startup anchors require no invented browser identity")
    try expect(firefoxAnchor.matchesNative(windowID: 118, pid: 77, bundleIdentifier: "org.mozilla.firefox")
        && !firefoxAnchor.matchesNative(windowID: 119, pid: 77, bundleIdentifier: "org.mozilla.firefox")
        && !firefoxAnchor.matchesNative(windowID: 118, pid: 78, bundleIdentifier: "org.mozilla.firefox"),
        "A DBT start anchor rejects a sibling native window in the same PID and a recycled window in another PID")
    let otherWindowTab = BrowserTabItem(id: 71, windowID: 7, index: 0, title: "QA other", url: "about:blank", active: true)
    let inactiveTab = BrowserTabItem(id: 81, windowID: 8, index: 0, title: "QA inactive", url: "about:blank", active: false)
    let activeTab = BrowserTabItem(id: 82, windowID: 8, index: 1, title: "QA active", url: "about:blank", active: true)
    let anchorSnapshot = BrowserTabSnapshot(browserBundleIdentifier: "org.mozilla.firefox", browserSessionID: "profile-A",
        tabs: [otherWindowTab, inactiveTab, activeTab])
    try expect(firefoxAnchor.matchesBrowserSnapshot(anchorSnapshot),
        "The exact browser-window active tab, not the first active tab or first index in the snapshot, owns DBT startup")
    var allTabsSnapshot = anchorSnapshot
    allTabsSnapshot.tabs = [otherWindowTab]
    allTabsSnapshot.allTabs = [otherWindowTab, inactiveTab, activeTab]
    try expect(firefoxAnchor.matchesBrowserSnapshot(allTabsSnapshot),
        "The complete allTabs inventory preserves the anchor when visible tabs omit the anchored window")
    var changedTab = anchorSnapshot
    changedTab.tabs[1].active = true; changedTab.tabs[2].active = false
    var restarted = anchorSnapshot; restarted.browserSessionID = "profile-B"
    var wrongBrowser = anchorSnapshot; wrongBrowser.browserBundleIdentifier = "com.google.Chrome"
    var ambiguous = anchorSnapshot; ambiguous.tabs[1].active = true
    try expect(!firefoxAnchor.matchesBrowserSnapshot(changedTab)
        && !firefoxAnchor.matchesBrowserSnapshot(restarted)
        && !firefoxAnchor.matchesBrowserSnapshot(wrongBrowser)
        && !firefoxAnchor.matchesBrowserSnapshot(ambiguous)
        && !firefoxAnchor.matchesBrowserSnapshot(nil),
        "Tab changes, profile/restart changes, wrong browser and ambiguous active tabs cancel stale DBT startup")
    try expect(firefoxAnchor.isPermitted(nativeWindowPermitted: true, accessMode: .whitelist, selectedTabIDs: [82], browserIsUnrestricted: false)
        && !firefoxAnchor.isPermitted(nativeWindowPermitted: true, accessMode: .whitelist, selectedTabIDs: [81], browserIsUnrestricted: false)
        && !firefoxAnchor.isPermitted(nativeWindowPermitted: true, accessMode: .blacklist, selectedTabIDs: [82], browserIsUnrestricted: false)
        && firefoxAnchor.isPermitted(nativeWindowPermitted: true, accessMode: .blacklist, selectedTabIDs: [81], browserIsUnrestricted: false),
        "Whitelist and blacklist startup permissions apply to the exact anchored tab without weakening either access mode")
    for mode in [IntentionAccessMode.whitelist, .blacklist] {
        try expect(!firefoxAnchor.isPermitted(nativeWindowPermitted: false, accessMode: mode, selectedTabIDs: [81], browserIsUnrestricted: true),
            "Leisure/unrestricted browser and Add As You Go never override forbidden native-window permission")
    }
    try expect(firefoxAnchor.isPermitted(nativeWindowPermitted: true, accessMode: .whitelist, selectedTabIDs: [81], browserIsUnrestricted: true),
        "Whitelist Add As You Go can begin on an otherwise unselected current tab without activating another tab")
    let originalResources = FocusStartAnchor.StartupResources(appIDs: ["org.mozilla.firefox"],
        windowIDs: ["org.mozilla.firefox": [117]], tabIDs: ["org.mozilla.firefox": [81]])
    let seededResources = firefoxAnchor.seedingCurrentResources(originalResources, addAsYouGo: true,
        accessMode: .whitelist, blockedAppIDs: [])
    var seededRules = ActiveBrowserRules(active: true, allowedWebsites: [], selectedTabIDsByBrowser: seededResources.tabIDs,
        selectedBrowserSessionIDsByBrowser: ["org.mozilla.firefox": "profile-A"],
        blockTabSwitching: true, blockNavigation: true, blockNewTabs: false)
    seededRules.addAsYouGo = true
    var seededNative = FocusSessionSpec(displayName: "Add current work", startupSteps: [], allowedBundleIdentifiers: [],
        fallbackBundleIdentifier: "", strictSingleApp: false, blockAppSwitching: false, blockNewApps: false,
        keepFocused: false, blockBrowserTabEscape: false, blockFirefoxChromeClicks: false,
        allowGoogleSearchTabs: false, spotifyPlaylistURI: nil, allowSpotifyForeground: false)
    seededNative.initialAllowedApps = seededResources.appIDs
    seededNative.initialSelectedWindows = seededResources.windowIDs
    try expect(seededRules.selectedTabIDsByBrowser?["org.mozilla.firefox"] == [81, 82]
        && seededNative.initialAllowedApps?.contains("org.mozilla.firefox") == true
        && seededNative.initialSelectedWindows["org.mozilla.firefox"] == [117, 118],
        "Actual browser rules and native initial-hide owners include Add As You Go's current tab/window, not only preflight permission")
    try expect(originalResources.tabIDs?["org.mozilla.firefox"] == [81]
        && originalResources.windowIDs["org.mozilla.firefox"] == [117],
        "Runtime Add As You Go adoption leaves the marked draft and saved selection unchanged")
    try expect(firefoxAnchor.seedingCurrentResources(originalResources, addAsYouGo: true,
        accessMode: .whitelist, blockedAppIDs: ["org.mozilla.firefox"]) == originalResources
        && firefoxAnchor.seedingCurrentResources(originalResources, addAsYouGo: true,
        accessMode: .blacklist, blockedAppIDs: []) == originalResources
        && firefoxAnchor.seedingCurrentResources(originalResources, addAsYouGo: false,
        accessMode: .whitelist, blockedAppIDs: []) == originalResources,
        "Current-resource seeding cannot override a blocked preset or alter blacklist/non-Add-As-You-Go sessions")
    let nativeSeed = nativeAnchor.seedingCurrentResources(originalResources, addAsYouGo: true,
        accessMode: .whitelist, blockedAppIDs: [])
    try expect(nativeSeed.appIDs.contains("com.apple.calculator")
        && nativeSeed.windowIDs["com.apple.calculator"] == [119] && nativeSeed.tabIDs == originalResources.tabIDs,
        "An allowed new native app seeds only its exact current window without changing browser scopes")
    let unrestricted = FocusStartAnchor.StartupResources(appIDs: ["org.mozilla.firefox"], windowIDs: [:], tabIDs: nil)
    try expect(firefoxAnchor.seedingCurrentResources(unrestricted, addAsYouGo: true,
        accessMode: .whitelist, blockedAppIDs: []) == unrestricted,
        "Adopting current work must not introduce a selected-tab or selected-window restriction on a whole browser")
    for hidden in [true, false] {
        let expected: HiddenWorkspaceRestorationPolicy.Action = hidden ? .retain : .relinquish
        try expect(HiddenWorkspaceRestorationPolicy.onUserReveal.action(isHidden: hidden) == expected,
            "Deferred ownership never reveals a hidden window and releases only after the user reveals it")
    }
    try expect(HiddenWorkspaceRestorationPolicy.automatic.action(isHidden: true) == .reveal
        && HiddenWorkspaceRestorationPolicy.automatic.action(isHidden: false) == .relinquish,
        "Default restoration retains existing automatic semantics")
    try expect(!HiddenWorkspaceRestorationPolicy.onUserReveal.needsRecoveryObservation(isParking: false)
        && HiddenWorkspaceRestorationPolicy.onUserReveal.needsRecoveryObservation(isParking: true)
        && HiddenWorkspaceRestorationPolicy.automatic.needsRecoveryObservation(isParking: false),
        "Deferred ordinary windows do not leave an idle recovery watcher, while holder closure receipts stay observed")
    for policy in [HiddenWorkspaceRestorationPolicy.automatic, .onUserReveal] {
        try expect(policy.action(isHidden: nil) == .retain,
            "Unavailable visibility cannot authorize an effect or discard ownership")
        let saved = try JSONEncoder().encode(policy)
        let recovered = try JSONDecoder().decode(HiddenWorkspaceRestorationPolicy.self, from: saved)
        try expect(recovered == policy && recovered.action(isHidden: true) == policy.action(isHidden: true),
            "The deferred policy survives persistence without reverting to automatic reveal")
        try expect(policy.atStop(requested: .onUserReveal, ownsEntry: false) == .onUserReveal
            && policy.atStop(requested: .onUserReveal, ownsEntry: true) == .onUserReveal,
            "Normal completion cannot reveal current or historical pending windows")
        try expect(policy.atStop(requested: .automatic, ownsEntry: false) == policy
            && policy.atStop(requested: .automatic, ownsEntry: true) == .automatic,
            "Explicit safety or failed-start recovery affects only the current controller's ownership")
    }
    do {
        // Real durable browser receipts promise native ownership, not that a
        // window is visible. A same-process extension reload must be able to
        // settle its retry queue without overriding quiet native completion.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-quiet-parking-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserWindowVisibilityStore(directory: directory)
        let browser = "org.mozilla.firefox", profile = "quiet-profile", occurrence = "quiet-occurrence"
        let process = BrowserProcessIdentity(pid: 77, launched: 100)
        let holder = BrowserWindowVisibilityWindow(windowID: 9, title: "QA holding window",
            frame: .init(left: 0, top: 40, width: 800, height: 600), state: "minimized")
        let plan = BrowserWindowVisibilityPlan(intentionSessionID: occurrence, revision: 1, windows: [], parkingWindows: [holder])
        let accepted = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: profile,
            currentIntentionSessionID: occurrence, browserProcessIdentity: process)
        let captured = try store.writeCaptureReceipt(.init(browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: occurrence, windowIDs: [9]))
        try expect(accepted == .written && captured, "A quiet holder remains durably captured before any user tabs can enter it")
        let restoredStore = BrowserWindowVisibilityStore(directory: directory)
        let queued = try restoredStore.requestRegisteredRecovery(browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: occurrence, browserProcessIdentity: process, windowIDs: [9])
        let repeatRequest = try restoredStore.requestRegisteredRecovery(browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: occurrence, browserProcessIdentity: process, windowIDs: [9])
        try expect(queued == .written && repeatRequest == .unchanged,
            "Reloaded browser recovery settles idempotently without retrying until a holder becomes visible")
        let record = restoredStore.record(browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: occurrence)!
        let disposition = BrowserWindowVisibilityRestorationPolicy.parkingDisposition(expectedIdentity: process,
            expectedBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: occurrence,
            browserWindowID: 9, nativeWindowID: 900, isParking: true, record: record)
        let persistedQuietPolicy = try JSONDecoder().decode(HiddenWorkspaceRestorationPolicy.self,
            from: JSONEncoder().encode(HiddenWorkspaceRestorationPolicy.onUserReveal))
        try expect(disposition == .restore && persistedQuietPolicy.action(isHidden: true) == .retain,
            "An automatic orphan reveal receipt is not a user gesture and cannot raise a quiet holder after restart")
        try expect(persistedQuietPolicy.action(isHidden: false) == .relinquish,
            "Deliberately reopening the holder releases native ownership without another visibility effect")
        let closed = try restoredStore.confirmRegisteredParkingClosed(browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: occurrence, browserProcessIdentity: process, windowIDs: [9])
        let closedRecord = restoredStore.record(browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: occurrence)!
        try expect(closed == .written && BrowserWindowVisibilityRestorationPolicy.parkingDisposition(expectedIdentity: process,
            expectedBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: occurrence,
            browserWindowID: 9, nativeWindowID: 900, isParking: true, record: closedRecord) == .discard,
            "A confirmed emptied holder is retired even under quiet completion; no hidden tab is deleted to clear ownership")
    }
    try expect(!RestorationFocusPolicy.inputChanged(initial: [1, 2, 3, 4, 5], current: [1, 2, 3, 4, 5]),
        "Unchanged input counters do not cancel restoration")
    try expect(RestorationFocusPolicy.inputChanged(initial: [1, 2, 3, 4, 5], current: [2, 2, 3, 4, 5])
        && RestorationFocusPolicy.inputChanged(initial: [UInt32.max], current: [0])
        && RestorationFocusPolicy.inputChanged(initial: [1, 2], current: [1]),
        "Fresh input, counter wrap and an inconsistent snapshot cancel before queued main-thread callbacks")
    // The real CG provider seam catches query-flag regressions as well as
    // identity matching: optionAll has value zero, so contains(optionAll) alone
    // would not detect an accidental optionOnScreenOnly query.
    var windowQuery: (CGWindowListOption, CGWindowID)?
    func targetExists(_ records: [[String: Any]]?) -> Bool? {
        WorkspaceWindow.exists(id: 12687, pid: 31075) { options, relativeTo in
            windowQuery = (options, relativeTo)
            return records.map { $0 as CFArray }
        }
    }
    let target: [String: Any] = [kCGWindowNumber as String: UInt32(12687),
        kCGWindowOwnerPID as String: Int32(31075), kCGWindowIsOnscreen as String: true]
    var temporarilyOffscreen = target
    temporarilyOffscreen[kCGWindowIsOnscreen as String] = false
    try expect(targetExists([target]) == true, "Restoration recognizes its visible window")
    try expect(windowQuery?.0 == [.optionAll, .excludeDesktopElements] && windowQuery?.1 == kCGNullWindowID,
        "Restoration lifetime query must include offscreen windows, not just presentation candidates")
    let other: [String: Any] = [kCGWindowNumber as String: UInt32(11783),
        kCGWindowOwnerPID as String: Int32(31075), kCGWindowIsOnscreen as String: true]
    try expect(targetExists([other, temporarilyOffscreen]) == true,
        "An old window coming forward cannot make the still-live offscreen work window count as closed")
    try expect(targetExists([temporarilyOffscreen]) == true,
        "An offscreen target remains the same identity even without presentation frame/title data")
    var recycledID = temporarilyOffscreen
    recycledID[kCGWindowOwnerPID as String] = Int32(999)
    try expect(targetExists([other, recycledID]) == false, "A reused window number in a different process is not the target")
    try expect(targetExists([]) == false, "A successful inventory without the target confirms closure")
    try expect(targetExists(nil) == nil, "Unavailable WindowServer inventory defers instead of manufacturing closure")

    let actions = DeferredSessionActionGate()
    var effects: [String] = []
    let queuedSwitcher = actions.token
    actions.invalidate()
    actions.perform(ifCurrent: queuedSwitcher) { effects.append("stale-switcher") }
    try expect(effects.isEmpty, "Completion cancels a queued app/tab-switcher activation before it runs")
    let recovery = actions.token
    actions.perform(ifCurrent: recovery) {
        effects.append("first-AX-effect")
        actions.invalidate() // completion or an AppKit callback during an effect
    }
    actions.perform(ifCurrent: recovery) { effects.append("late-raise") }
    actions.perform(ifCurrent: recovery) { effects.append("late-activation") }
    try expect(effects == ["first-AX-effect"], "Cancellation between AX effects blocks the remaining raise and activation")
    actions.perform(ifCurrent: actions.token) { effects.append("new-work") }
    try expect(effects.last == "new-work", "Cancelling old work does not prevent an explicitly new generation")
    var intention = Intention(name: "Stay on my screen", icon: "app", colorHex: "#00ff00", folder: "QA",
        allowedApps: [.init(name: "Calculator", bundleIdentifier: "com.apple.calculator")],
        allowedWebsites: [], startupActions: [], restrictions: .init())
    intention.closeSessionResourcesOnFinish = true
    let legacySpec = FocusSessionSpec.make(for: intention)
    let appSpec = legacySpec.preservingForegroundOnStop()
    try expect(legacySpec.hiddenWorkspaceRestorationOnStop == .automatic
        && appSpec.hiddenWorkspaceRestorationOnStop == .restoreOwnedWorkspace,
        "GUI completion restores Intent-owned visibility without reopening or returning to the start app")
    var quietSpec = appSpec
    quietSpec.hiddenWorkspaceRestorationOnStop = .onUserReveal
    try expect(quietSpec.deferringBrowserWebsiteStartupToGuard().hiddenWorkspaceRestorationOnStop == .onUserReveal,
        "Explicit deferred restoration survives browser startup specification copying")
    var marked = FocusSessionSpec(displayName: "Marked current window", startupSteps: [],
        allowedBundleIdentifiers: ["org.mozilla.firefox", "com.apple.calculator"], fallbackBundleIdentifier: "com.apple.calculator",
        strictSingleApp: false, blockAppSwitching: true, blockNewApps: true, keepFocused: true,
        blockBrowserTabEscape: true, blockFirefoxChromeClicks: false, allowGoogleSearchTabs: false,
        spotifyPlaylistURI: nil, allowSpotifyForeground: false,
        selectedWindowIDsByApp: ["org.mozilla.firefox": [118]])
    try expect(!marked.shouldPreserveCurrentWindowOnStart(windowID: 118, bundleIdentifier: "org.mozilla.firefox", controllerBundleIdentifier: "test.intent"),
        "Overview and saved startup retain their destination semantics")
    marked.preservesCurrentWindowOnStart = true
    marked.startupWindowAnchor = firefoxAnchor
    try expect(marked.deferringBrowserWebsiteStartupToGuard().startupWindowAnchor == firefoxAnchor
        && marked.preservingForegroundOnStop().startupWindowAnchor == firefoxAnchor,
        "Startup deferral and quiet completion retain the exact captured native/profile/window/tab anchor")
    try expect(marked.shouldPreserveCurrentWindowOnStart(windowID: 118, bundleIdentifier: "org.mozilla.firefox", controllerBundleIdentifier: "test.intent"),
        "DBT Run stays on its permitted current Firefox window instead of activating the first selected app")
    try expect(!marked.shouldPreserveCurrentWindowOnStart(windowID: 119, bundleIdentifier: "org.mozilla.firefox", controllerBundleIdentifier: "test.intent"),
        "Same application does not authorize preserving a different excluded native window")
    try expect(!marked.shouldPreserveCurrentWindowOnStart(windowID: nil, bundleIdentifier: "org.mozilla.firefox", controllerBundleIdentifier: "test.intent")
        && !marked.shouldPreserveCurrentWindowOnStart(windowID: 118, bundleIdentifier: "test.intent", controllerBundleIdentifier: "test.intent"),
        "An unresolved native window or transient Intent editor is never adopted as DBT's work destination")
    try expect(marked.deferringBrowserWebsiteStartupToGuard().preservesCurrentWindowOnStart,
        "Browser startup deferral preserves DBT's current-window contract")
    var launching = appSpec
    launching.preservesCurrentWindowOnStart = true
    try expect(!launching.shouldPreserveCurrentWindowOnStart(windowID: 5, bundleIdentifier: "com.apple.calculator", controllerBundleIdentifier: "test.intent"),
        "Explicit launch steps are not suppressed by current-window fallback preservation")
    try expect(legacySpec.closeSessionResourcesOnFinish && legacySpec.restorePreviousApplicationOnStop,
        "Explicit CLI teardown policy remains compatible")
    try expect(!appSpec.closeSessionResourcesOnFinish && !appSpec.restorePreviousApplicationOnStop,
        "GUI completion cannot close the user's work or activate the session-start application")
    try expect(!appSpec.deferringBrowserWebsiteStartupToGuard().closeSessionResourcesOnFinish
        && !appSpec.deferringBrowserWebsiteStartupToGuard().restorePreviousApplicationOnStop,
        "Browser startup deferral preserves the no-focus-changing completion contract")
    var nativeVisibilitySpec = appSpec
    nativeVisibilitySpec.hideDistractions = true
    nativeVisibilitySpec.nativeWindowVisibilitySessionID = "current-browser-visibility-occurrence"
    nativeVisibilitySpec.initialAllowedApps = ["org.mozilla.firefox"]
    nativeVisibilitySpec.initialSelectedWindows = ["org.mozilla.firefox": [42]]
    let deferredVisibility = nativeVisibilitySpec.deferringBrowserWebsiteStartupToGuard()
    try expect(deferredVisibility.hideDistractions
        && deferredVisibility.nativeWindowVisibilitySessionID == nativeVisibilitySpec.nativeWindowVisibilitySessionID
        && deferredVisibility.initialAllowedApps == nativeVisibilitySpec.initialAllowedApps
        && deferredVisibility.initialSelectedWindows == nativeVisibilitySpec.initialSelectedWindows,
        "Deferring browser startup cannot erase exact visibility occurrence ownership or initial selection policy")
    let idle = FocusSessionSpec.workPeriodIdle(controllerBundleIdentifier: "test.intent", alwaysAllowed: ["test.preset"],
        currentWorkBundleIdentifier: "org.mozilla.firefox", presentWorkspace: false, finishShortcut: .defaultFinish)
    try expect(idle.startupSteps.isEmpty && idle.fallbackBundleIdentifier.isEmpty
        && !idle.restorePreviousApplicationOnStop && !idle.closeSessionResourcesOnFinish,
        "A continuing work period never launches, chooses or restores an application at the completion boundary")
    try expect(idle.permitsApplication("org.mozilla.firefox") && idle.permitsApplication("test.intent")
        && idle.permitsApplication("test.preset") && !idle.permitsApplication("other.app") && idle.requiresEnforcement,
        "Silent work-period handoff keeps current work usable without dropping restrictions on other apps")
    let locked = FocusSessionSpec.workPeriodIdle(controllerBundleIdentifier: "test.intent", alwaysAllowed: [],
        currentWorkBundleIdentifier: "com.apple.loginwindow", presentWorkspace: false, finishShortcut: .defaultFinish)
    try expect(!locked.permitsApplication("com.apple.loginwindow"), "The login screen is never adopted as a work destination")
    let stopRequests: [(FocusLock) -> Void] = [{ $0.stop() }, { $0.stopForExpiry() }, { $0.stopForSafety() }]
    for requestStop in stopRequests {
        let lock = FocusLock(spec: appSpec)
        requestStop(lock)
        try expect(lock.isStopRequested, "Each completion route synchronously cancels the real focus runtime")
        try lock.run { preconditionFailure("A stopped session must never execute startup or become ready") }
        try expect(lock.isStopRequested, "A stop before worker startup cannot restart enforcement, request permissions or restore visibility")
    }
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: 2) == 2,
        "Finishing from Intent's controls preserves the visible work app, not the disappearing controls")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 1, controllerPID: 10, visiblePID: 2) == 1,
        "A hotkey finish preserves the current app even when another app has an exposed window")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: nil) == nil,
        "A finish without a visible work app must not guess or reopen a stale application")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: nil, controllerPID: 10, visiblePID: 2) == nil,
        "An inactive desktop must not activate an exposed application")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: 10) == nil,
        "Transient Intent panels cannot become their own restoration target")
    do {
        var policy = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2, 3])
        try expect(policy.shouldPreserve(frontmostPID: 1), "Keep the current window within the same app")
        try expect(policy.shouldPreserve(frontmostPID: 2), "Undo a hidden-app restoration stealing focus")
        try expect(policy.shouldPreserve(frontmostPID: 3), "Undo asynchronous browser restoration stealing focus")
        policy.userInteracted()
        try expect(!policy.shouldPreserve(frontmostPID: 2), "A real click or key cancels focus preservation even for a restored app")
    }
    var policy = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2])
    try expect(!policy.shouldPreserve(frontmostPID: 9), "Do not fight unrelated app activation")
    try expect(!policy.shouldPreserve(frontmostPID: 2), "Do not return to a stale app after the user moved on")
    var immediate = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2])
    try expect(!immediate.shouldPreserveOwnedVisibilityChange(targetExists: nil, targetOnScreen: true, frontmostPID: 1),
        "An unavailable inventory never authorizes an immediate AX effect")
    try expect(!immediate.shouldPreserveOwnedVisibilityChange(targetExists: false, targetOnScreen: true, frontmostPID: 1),
        "An already closed working window cannot be raised")
    try expect(!immediate.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: false, frontmostPID: 1),
        "Owned restoration cannot chase an offscreen or minimized target")
    try expect(immediate.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: true, frontmostPID: 1),
        "An exact onscreen working window can be queued directly after an owned restore")
    immediate.userInteracted()
    try expect(!immediate.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: true, frontmostPID: 2),
        "User input cancels immediate owned-restore preservation as well as timer recovery")
    var unrelated = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2])
    try expect(!unrelated.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: true, frontmostPID: 9)
        && !unrelated.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: true, frontmostPID: 1),
        "An unrelated activation irrevocably cancels immediate restoration for this occurrence")
    var unavailable = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2])
    try expect(!unavailable.shouldPreserveOwnedVisibilityChange(targetExists: nil, targetOnScreen: false, frontmostPID: 9)
        && !unavailable.shouldPreserveOwnedVisibilityChange(targetExists: true, targetOnScreen: true, frontmostPID: 1),
        "Unrelated activation still cancels when the native inventory is temporarily unavailable")
}
