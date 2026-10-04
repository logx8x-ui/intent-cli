import Foundation
import IntentCore
import IntentLock

func runRestorationFocusSpecs() throws {
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
