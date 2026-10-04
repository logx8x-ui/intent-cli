import Foundation
import CoreGraphics
import IntentCore
import IntentLock

func runRestorationFocusSpecs() throws {
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
}
