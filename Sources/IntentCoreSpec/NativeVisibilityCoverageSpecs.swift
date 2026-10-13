import Foundation
import IntentCore
import IntentLock

func runNativeVisibilityCoverageSpecs() throws {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let birth = NativeProcessLaunchDate.kernelDate(pid: ownPID)
    try expect(birth != nil && birth! <= Date(), "Kernel birth time supplies a real process lifetime")
    try expect(NativeProcessLaunchDate.kernelDate(pid: ownPID) == birth,
        "Repeated observations retain the same exact lifetime for hiding and restoration")
    try expect(NativeProcessLaunchDate.kernelDate(pid: 0) == nil
        && NativeProcessLaunchDate.kernelDate(pid: -1) == nil,
        "Invalid PIDs cannot become guessed process identities")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run(); child.waitUntilExit()
    try expect(NativeProcessLaunchDate.kernelDate(pid: child.processIdentifier) == nil,
        "Exited processes cannot retain live identity proof")
    typealias Policy = NativeVisibilityCoveragePolicy
    let app = Policy.Target(bundleIdentifier: "blocked.app", pid: 41, launched: 100)
    let excludedWindow = Policy.Target(bundleIdentifier: "selected.app", pid: 42, launched: 101, windowID: 7)
    func observation(_ target: Policy.Target, _ outcome: Policy.Outcome) -> Policy.Observation {
        .init(target: target, outcome: outcome)
    }
    let finderWithoutLaunchDate: Double? = nil
    let permittedFinder = Policy.applicationAction(isCaptureTool: false, alwaysAllowed: false, explicitlyBlocked: false,
        applicationExcluded: false, excludedWindowIDs: [])
    try expect(finderWithoutLaunchDate == nil && !permittedFinder.requiresProcessIdentity,
        "A permitted Finder with no excluded windows cannot invalidate startup just because launchDate is nil")
    let presetFinder = Policy.applicationAction(isCaptureTool: false, alwaysAllowed: true, explicitlyBlocked: false,
        applicationExcluded: true, excludedWindowIDs: [7])
    try expect(!presetFinder.requiresProcessIdentity,
        "An always-allowed app remains exempt from startup app/window restrictions without needing launch metadata")
    let blockedFinder = Policy.applicationAction(isCaptureTool: false, alwaysAllowed: true, explicitlyBlocked: true,
        applicationExcluded: false, excludedWindowIDs: [])
    try expect(blockedFinder == .hideApplication && blockedFinder.requiresProcessIdentity,
        "An explicit ban still needs verified whole-app hiding and cannot use an always-allowed exemption")
    let captureTool = Policy.applicationAction(isCaptureTool: true, alwaysAllowed: false, explicitlyBlocked: true,
        applicationExcluded: true, excludedWindowIDs: [7])
    try expect(!captureTool.requiresProcessIdentity,
        "Screenshot tools stay exempt even when a normal selection would exclude their windows")
    let siblingSelection = Policy.applicationAction(isCaptureTool: false, alwaysAllowed: false, explicitlyBlocked: false,
        applicationExcluded: false, excludedWindowIDs: [7, 8])
    try expect(siblingSelection == .minimizeWindows([7, 8]) && siblingSelection.requiresProcessIdentity,
        "An allowed app with excluded sibling windows still requires verified lifetime and minimization")
    let windowlessExcluded = Policy.applicationAction(isCaptureTool: false, alwaysAllowed: false, explicitlyBlocked: false,
        applicationExcluded: true, excludedWindowIDs: [])
    try expect(windowlessExcluded.requiresProcessIdentity,
        "An ordinary excluded windowless app cannot waive unavailable process identity")
    try expect(Policy.isNonUserSurface(isUntitled: true, serverIdentityStable: true, isOnScreen: false,
        accessibilityInventoryComplete: true, accessibilityGeometryMatch: false, previouslyIdentifiedUserWindow: false, allUserWindowsBoundElsewhere: true),
        "A stable offscreen untitled CG backing surface absent from complete AX geometry is outside the user-window cohort")
    for facts in [(false, true, Optional(false), true, false, false),
                  (true, false, Optional(false), true, false, false),
                  (true, true, Optional(true), true, false, false),
                  (true, true, nil, true, false, false),
                  (true, true, Optional(false), false, false, false),
                  (true, true, Optional(false), true, true, false),
                  (true, true, Optional(false), true, false, true)] {
        try expect(!Policy.isNonUserSurface(isUntitled: facts.0, serverIdentityStable: facts.1, isOnScreen: facts.2,
            accessibilityInventoryComplete: facts.3, accessibilityGeometryMatch: facts.4, previouslyIdentifiedUserWindow: facts.5,
            allUserWindowsBoundElsewhere: true),
            "Titled, changing, visible, unknown, AX-bound minimized/off-Space, or previously identified user windows remain strict")
    }
    try expect(!Policy.isNonUserSurface(isUntitled: true, serverIdentityStable: true, isOnScreen: false,
        accessibilityInventoryComplete: true, accessibilityGeometryMatch: false, previouslyIdentifiedUserWindow: false),
        "A dormant real AX window with a mismatching stale CG frame cannot become backing just because geometry differs")
    try expect(Policy.allUserWindowsBoundElsewhere(candidates: [[8], [9]], excluding: 7),
        "Every real AX window positively binds uniquely to another native lifetime before waiving a backing row")
    for candidates: [Set<UInt32>] in [[[]], [[7]], [[8, 9]], [[8], [8]], [[0]]] {
        try expect(!Policy.allUserWindowsBoundElsewhere(candidates: candidates, excluding: 7),
            "Missing, target, ambiguous, duplicated or malformed AX-to-CG bindings cannot waive a real window")
    }
    try expect(Policy.serverIdentitiesAreComplete([]) && Policy.serverIdentitiesAreComplete([(42, 7), (43, 8)]),
        "A valid fresh empty or identified on-screen inventory can prove absence")
    for identities: [(pid: Int32, windowID: UInt32)]? in [nil, [(0, 7)], [(42, 0)], [(42, 7), (43, 7)]] {
        try expect(!Policy.serverIdentitiesAreComplete(identities),
            "Unavailable, malformed, missing or duplicate native identity inventory cannot prove offscreen absence")
    }
    try expect(Policy.windowFallbackIsCovered([.hidden, .hidden], hasUnclassifiedSurfaces: false),
        "Rejected app-hide APIs can be covered by complete actual window minimize readback")
    for outcomes: [Policy.Outcome]? in [nil, [], [.hidden, .unresolved], [.hidden, .closed], [.nonUserSurface]] {
        try expect(!Policy.windowFallbackIsCovered(outcomes, hasUnclassifiedSurfaces: false),
            "Unknown, empty, failed or incomplete real-window fallback cannot establish app coverage")
    }
    try expect(!Policy.windowFallbackIsCovered([.hidden], hasUnclassifiedSurfaces: true),
        "A minimized main window cannot hide an unclassified substantial auxiliary user window")
    try expect(Policy.usableOwnedWindowGeometry(x: 23, y: 53, width: 66, height: 20),
        "A positively bound small real dialog remains in the raw ownership and restoration cohort even when no overview card is shown")
    try expect(Policy.usableOwnedWindowGeometry(x: -500, y: -120, width: 1, height: 1),
        "Minimized/off-Space owned windows retain their exact lifetime regardless of preview size or screen location")
    for geometry in [(0.0, 0.0, 0.0, 20.0), (0, 0, 66, -1), (Double.nan, 0, 66, 20), (0, 0, Double.infinity, 20)] {
        try expect(!Policy.usableOwnedWindowGeometry(x: geometry.0, y: geometry.1, width: geometry.2, height: geometry.3),
            "Unknown or invalid raw window geometry cannot bind or restore journal ownership")
    }
    for subrole in ["AXSystemDialog", "AXFloatingWindow"] {
        try expect(Policy.permitsAuxiliary(role: "AXWindow", subrole: subrole, applicationPermitted: true,
            exactProcessParent: true, hasWindowAncestor: false, ancestorBoundToPermittedWindow: false,
            livePermittedNativeWork: true, previouslyStandardWindow: false),
            "A positively typed auxiliary may use its exact permitted application parent when live permitted standard work exists")
    }
    for type in [(Optional("AXWindow"), Optional("AXStandardWindow")),
                 (Optional("AXWindow"), Optional("AXDialog")),
                 (Optional("AXUnknown"), Optional("AXSystemDialog")),
                 (nil, Optional("AXSystemDialog")), (Optional("AXWindow"), nil)] {
        try expect(!Policy.permitsAuxiliary(role: type.0, subrole: type.1, applicationPermitted: true,
            exactProcessParent: true, hasWindowAncestor: false, ancestorBoundToPermittedWindow: false,
            livePermittedNativeWork: true, previouslyStandardWindow: false),
            "Standard documents and unknown/nonapproved AX roles or subroles never become permitted utilities")
    }
    for flags in [(false, true, false, false, true, false),
                  (true, false, false, false, true, false),
                  (true, true, false, false, false, false),
                  (true, true, true, false, true, false),
                  (true, true, false, false, true, true)] {
        try expect(!Policy.permitsAuxiliary(role: "AXWindow", subrole: "AXSystemDialog", applicationPermitted: flags.0,
            exactProcessParent: flags.1, hasWindowAncestor: flags.2, ancestorBoundToPermittedWindow: flags.3,
            livePermittedNativeWork: flags.4, previouslyStandardWindow: flags.5),
            "Excluded apps, wrong process parents, no permitted work, blocked/unbound ancestors and previously standard windows stay strict")
    }
    try expect(Policy.permitsAuxiliary(role: "AXWindow", subrole: "AXSystemDialog", applicationPermitted: true,
        exactProcessParent: true, hasWindowAncestor: true, ancestorBoundToPermittedWindow: true,
        livePermittedNativeWork: false, previouslyStandardWindow: false),
        "An existing exact permitted window ancestor supplies explicit scoped work authority without using generic app permission")
    try expect(!Policy.permitsAuxiliary(role: "AXWindow", subrole: "AXSystemDialog", applicationPermitted: true,
        exactProcessParent: true, hasWindowAncestor: false, ancestorBoundToPermittedWindow: false,
        livePermittedNativeWork: true, previouslyStandardWindow: false, explicitlyBlockedWindow: true),
        "An explicitly blacklisted auxiliary native window retains priority over otherwise permitted application-parent proof")
    try expect(Policy.auxiliaryProofIsFresh(observedAt: 10, now: 10) && Policy.auxiliaryProofIsFresh(observedAt: 10, now: 11),
        "Derived auxiliary proof is usable only in its bounded one-second lifetime")
    for times in [(10.0, 11.001), (10, 9), (Double.nan, 10), (10, Double.infinity)] {
        try expect(!Policy.auxiliaryProofIsFresh(observedAt: times.0, now: times.1),
            "Stale, future or unknown auxiliary samples cannot permit foreground/input effects")
    }
    var auxiliaryPanel = Policy(required: true)
    try expect(auxiliaryPanel.update([observation(excludedWindow, .permittedAuxiliary)], now: 1) == nil && auxiliaryPanel.initialResolved,
        "A positively scoped real permitted panel has its own truthful outcome rather than being claimed hidden or nonuser")
    var malformedPanel = Policy(required: true)
    malformedPanel.begin(now: 1)
    try expect(malformedPanel.update([observation(app, .permittedAuxiliary)], now: 4)?.reason == .inventoryUnavailable,
        "Auxiliary window proof cannot waive an excluded application target")
    var auxiliary = Policy(required: true)
    try expect(auxiliary.update([observation(excludedWindow, .nonUserSurface)], now: 1) == nil && auxiliary.initialResolved,
        "Positive backing-surface classification can resolve only a window target")
    var invalidAuxiliary = Policy(required: true)
    invalidAuxiliary.begin(now: 1)
    try expect(invalidAuxiliary.update([observation(app, .nonUserSurface)], now: 4)?.reason == .inventoryUnavailable,
        "Backing-surface classification cannot waive whole-app restrictions")
    try expect(Policy.applicationHidden(nativeHidden: false, accessibilityHidden: true, accessibilityHideOwned: false) == true,
        "AX-prehidden user apps stay hidden without acquiring ownership even when NS reports false")
    try expect(Policy.applicationHidden(nativeHidden: false, accessibilityHidden: nil, accessibilityHideOwned: true) == nil,
        "An owned AX hide cannot be discarded using NS=false when AX readback is unavailable")
    try expect(Policy.applicationHidden(nativeHidden: true, accessibilityHidden: false, accessibilityHideOwned: true) == true,
        "Either positive native or AX hidden readback keeps the application covered")
    try expect(Policy.applicationHidden(nativeHidden: false, accessibilityHidden: false, accessibilityHideOwned: true) == false,
        "A restored AX application needs positive visible readback")

    var appOnly = Policy(required: true)
    try expect(!appOnly.initialResolved, "No Chrome cohort cannot make restrictive app-only startup ready")
    appOnly.begin(now: 10)
    try expect(appOnly.update([observation(app, .unresolved)], now: 10) == nil && !appOnly.initialResolved,
        "An app-hide request is pending until live hidden readback")
    try expect(appOnly.update([observation(app, .unresolved)], now: 12.9) == nil && !appOnly.initialResolved,
        "A delayed app hide gets a bounded startup grace period")
    try expect(appOnly.update([observation(app, .hidden)], now: 13.1) == nil && appOnly.initialResolved,
        "Actual hidden readback can finish startup even when the confirmation arrives after its grace period")

    var empty = Policy(required: true)
    empty.begin(now: 1)
    try expect(!empty.initialResolved, "Even an empty native cohort requires its first valid inventory")
    try expect(empty.update([], now: 1) == nil && empty.initialResolved,
        "A valid complete inventory with no excluded apps/windows permits startup")
    var disabled = Policy(required: false)
    try expect(disabled.initialResolved && disabled.update(nil, now: 10) == nil,
        "No hiding or no enforcement does not require a native startup observation")

    var selected = Policy(required: true)
    selected.begin(now: 1)
    _ = selected.update([observation(app, .hidden), observation(excludedWindow, .unresolved)], now: 1)
    try expect(!selected.initialResolved, "Whole-app hide success cannot mask an unminimized excluded sibling window")
    _ = selected.update([observation(app, .unresolved), observation(excludedWindow, .hidden)], now: 2)
    try expect(!selected.initialResolved, "An app revealed again while startup is pending needs fresh hidden confirmation")
    _ = selected.update([observation(app, .hidden), observation(excludedWindow, .hidden)], now: 2.5)
    try expect(selected.initialResolved, "Selected exclusions and blocked apps must be covered in the same complete packet")

    var failed = Policy(required: true)
    failed.begin(now: 10)
    _ = failed.update([observation(app, .unresolved)], now: 10)
    let failure = failed.update([observation(app, .unresolved)], now: 13)
    try expect(failure?.reason == .hidingUnconfirmed && failure?.target == app && !failed.initialResolved,
        "An excluded app still visible at the deadline fails startup rather than reporting onReady")
    try expect(failure?.message.contains("blocked.app") == false,
        "The user explanation exposes no application identity")
    try expect(failed.update([observation(app, .hidden)], now: 14) == nil && !failed.initialResolved,
        "A late observation cannot revive a failed startup or repeatedly emit its callback")

    var omitted = Policy(required: true)
    omitted.begin(now: 1)
    _ = omitted.update([observation(excludedWindow, .unresolved)], now: 1)
    try expect(omitted.update([], now: 2) == nil && !omitted.initialResolved,
        "Omission from a presentation list is not positive proof of native window closure")
    try expect(omitted.update([], now: 4)?.reason == .inventoryUnavailable,
        "Incomplete observations stop boundedly instead of silently covering missing windows")
    var closed = Policy(required: true)
    closed.begin(now: 1)
    _ = closed.update([observation(excludedWindow, .unresolved)], now: 1)
    _ = closed.update([observation(excludedWindow, .closed)], now: 2)
    try expect(closed.initialResolved, "Positively proven process/window closure resolves its original target")

    var unavailable = Policy(required: true)
    unavailable.begin(now: 5)
    try expect(unavailable.update(nil, now: 7.9) == nil && !unavailable.initialResolved,
        "Unavailable WindowServer inventory cannot be treated as an empty successful inventory")
    try expect(unavailable.update(nil, now: 8)?.reason == .inventoryUnavailable,
        "A native inventory that never becomes available has a finite startup deadline")
    for packet in [[observation(app, .hidden), observation(app, .hidden)],
                   [observation(.init(bundleIdentifier: "", pid: 41, launched: 100), .hidden)],
                   [observation(.init(bundleIdentifier: "bad", pid: 0, launched: 100), .hidden)],
                   [observation(.init(bundleIdentifier: "bad", pid: 41, launched: .nan), .hidden)],
                   [observation(.init(bundleIdentifier: "bad", pid: 41, launched: 100, windowID: 0), .hidden)]] {
        var malformed = Policy(required: true)
        malformed.begin(now: 1)
        try expect(malformed.update(packet, now: 4)?.reason == .inventoryUnavailable && !malformed.initialResolved,
            "Duplicate or invalid native identities cannot prove startup coverage")
    }

    var lifetime = Policy(required: true)
    lifetime.begin(now: 1)
    _ = lifetime.update([observation(app, .unresolved)], now: 1)
    let replacement = Policy.Target(bundleIdentifier: app.bundleIdentifier, pid: app.pid, launched: app.launched + 1)
    _ = lifetime.update([observation(app, .closed), observation(replacement, .unresolved)], now: 3.9)
    try expect(!lifetime.initialResolved && lifetime.update([observation(app, .closed), observation(replacement, .unresolved)], now: 4)?.target == replacement,
        "PID reuse is a different target and cannot inherit success or reset the startup deadline")
    var canceled = Policy(required: true)
    canceled.begin(now: 1)
    _ = canceled.update([observation(app, .unresolved)], now: 1)
    canceled.stop()
    try expect(canceled.update([observation(app, .unresolved)], now: 20) == nil && !canceled.initialResolved,
        "Stop prevents later native observations from completing or failing a canceled occurrence")

    var events: [String] = [], hidden = false, current = true
    let result = NativeVisibilityCoverageEffects.hide(isCurrent: { current }, readHidden: {
        events.append("read"); return hidden
    }, saveOwnership: { events.append("save"); return true }, dispatch: {
        events.append("hide"); hidden = true; return true
    })
    try expect(result == .hidden && events == ["read", "save", "hide", "read"],
        "Durable ownership precedes native dispatch and visibility readback follows it")
    events = []
    let prehidden = NativeVisibilityCoverageEffects.hide(isCurrent: { true }, readHidden: { true },
        saveOwnership: { events.append("save"); return true }, dispatch: { events.append("hide"); return true })
    try expect(prehidden == .hidden && events.isEmpty,
        "Pre-hidden apps and pre-minimized user windows satisfy coverage without new ownership or restoration effects")
    events = []
    let falselyAccepted = NativeVisibilityCoverageEffects.hide(isCurrent: { true }, readHidden: { false },
        saveOwnership: { events.append("save"); return true }, dispatch: { events.append("hide"); return true })
    try expect(falselyAccepted == .unresolved && events == ["save", "hide"],
        "Native dispatch returning true without hidden/minimized readback never counts as success")
    events = []
    let rejected = NativeVisibilityCoverageEffects.hide(isCurrent: { true }, readHidden: { false },
        saveOwnership: { events.append("save"); return true }, dispatch: { events.append("hide"); return false })
    try expect(rejected == .unresolved && events == ["save", "hide"],
        "A rejected app.hide or AX minimize request remains pending with durable cleanup ownership")
    for unavailableRead: Bool? in [nil, false] {
        events = []
        let unavailableEffect = NativeVisibilityCoverageEffects.hide(isCurrent: { true }, readHidden: { unavailableRead },
            saveOwnership: { events.append("save"); return false }, dispatch: { events.append("hide"); return true })
        try expect(unavailableEffect == .unresolved && !events.contains("hide"),
            "Unknown visibility or failed journaling never dispatches native hiding")
    }
    events = []; current = true
    let canceledBeforeDispatch = NativeVisibilityCoverageEffects.hide(isCurrent: { current }, readHidden: { false },
        saveOwnership: { events.append("save"); current = false; return true }, dispatch: { events.append("hide"); return true })
    try expect(canceledBeforeDispatch == .unresolved && events == ["save"],
        "Canceled or replaced sessions cannot dispatch hiding after ownership persistence")
    events = []; current = true
    let canceledAfterDispatch = NativeVisibilityCoverageEffects.hide(isCurrent: { current }, readHidden: { false },
        saveOwnership: { true }, dispatch: { events.append("hide"); current = false; return true })
    try expect(canceledAfterDispatch == .unresolved && events == ["hide"],
        "A canceled occurrence cannot publish successful coverage after its native request")
    current = true
    let canceledDuringRead = NativeVisibilityCoverageEffects.hide(isCurrent: { current }, readHidden: { current = false; return true },
        saveOwnership: { preconditionFailure("Canceled hidden read must not acquire ownership") },
        dispatch: { preconditionFailure("Canceled hidden read must not dispatch") })
    try expect(canceledDuringRead == .unresolved,
        "Cancellation during even a pre-hidden state read cannot publish old-occurrence coverage")

    events = []; hidden = false; current = true
    let fallback = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: { current }, readHidden: {
        events.append("read"); return hidden
    }, saveOwnership: { events.append("save"); return true }, dispatchPrimary: {
        events.append("nativeRejected")
    }, saveFallbackOwnership: { events.append("saveAX"); return true }, dispatchFallback: {
        events.append("AXHidden"); hidden = true
    })
    try expect(fallback == .hidden && events == ["read", "save", "nativeRejected", "read", "saveAX", "AXHidden", "read"],
        "Rejected native hide uses durably owned AX fallback and requires actual hidden readback")
    events = []
    let bothRejected = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: { true }, readHidden: { false },
        saveOwnership: { true }, dispatchPrimary: { events.append("native") },
        saveFallbackOwnership: { true }, dispatchFallback: { events.append("AX") })
    try expect(bothRejected == .unresolved && events == ["native", "AX"],
        "Both native and AX rejection remain unresolved rather than weakening app coverage")
    events = []
    let axPrehidden = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: { true }, readHidden: { true },
        saveOwnership: { events.append("save"); return true }, dispatchPrimary: { events.append("native") },
        saveFallbackOwnership: { events.append("saveAX"); return true }, dispatchFallback: { events.append("AX") })
    try expect(axPrehidden == .hidden && events.isEmpty, "Prehidden AX apps are never owned or changed")
    events = []; current = true
    let fallbackCanceled = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: { current }, readHidden: { false },
        saveOwnership: { true }, dispatchPrimary: { events.append("native") },
        saveFallbackOwnership: { events.append("saveAX"); current = false; return true }, dispatchFallback: { events.append("AX") })
    try expect(fallbackCanceled == .unresolved && events == ["native", "saveAX"],
        "Cancellation or PID/lifetime replacement before fallback prevents AX dispatch")
    events = []; current = true
    let unsupportedFallback = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: { true }, readHidden: { false },
        saveOwnership: { true }, dispatchPrimary: { events.append("native") },
        saveFallbackOwnership: { false }, dispatchFallback: { events.append("AX") })
    try expect(unsupportedFallback == .unresolved && events == ["native"],
        "Unsupported/unsettable AX fallback cannot dispatch without durable supported ownership")
    events = []; hidden = true
    let restoredFallback = NativeVisibilityCoverageEffects.restoreWithFallback(isCurrent: { true }, readHidden: { hidden },
        shouldReveal: { true }, dispatchPrimary: { events.append("nativeRejected") }, dispatchFallback: {
            events.append("AXVisible"); hidden = false
        })
    try expect(restoredFallback && events == ["nativeRejected", "AXVisible"],
        "Rejected normal unhide restores via the same nonactivating AX path with visible readback")
    let unknownRestoration = NativeVisibilityCoverageEffects.restoreWithFallback(isCurrent: { true }, readHidden: { nil },
        shouldReveal: { true }, dispatchPrimary: { preconditionFailure("Unknown state cannot dispatch") },
        dispatchFallback: { preconditionFailure("Unknown state cannot dispatch") })
    try expect(!unknownRestoration, "Unavailable owned AX readback keeps durable restoration ownership")
    let rejectedRestoration = NativeVisibilityCoverageEffects.restoreWithFallback(isCurrent: { true }, readHidden: { true },
        shouldReveal: { true }, dispatchPrimary: {}, dispatchFallback: {})
    try expect(!rejectedRestoration, "Rejected or unconfirmed reveal retains the app's journal entry")
    events = []; current = true
    let canceledRestoration = NativeVisibilityCoverageEffects.restoreWithFallback(isCurrent: { current }, readHidden: { true },
        shouldReveal: { true }, dispatchPrimary: { events.append("native"); current = false }, dispatchFallback: { events.append("AX") })
    try expect(!canceledRestoration && events == ["native"], "Process replacement before restore fallback cannot affect a reused PID")
}
