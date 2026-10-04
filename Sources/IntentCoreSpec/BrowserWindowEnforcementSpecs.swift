import Foundation
import IntentCore
import IntentLock

func runBrowserWindowEnforcementSpecs() throws {
    typealias Policy = BrowserWindowEnforcementPolicy
    let session = "active-occurrence"
    let proof = BrowserProcessIdentity(pid: 42, launched: 100)
    let window = BrowserWindowVisibilityWindow(windowID: 7, title: "Example Domain",
        frame: .init(left: 0, top: 40, width: 1200, height: 800), state: "normal")
    let record = BrowserWindowVisibilityRecord(browserBundleIdentifier: "com.google.Chrome",
        browserSessionID: "profile-one", receivedAt: Date(timeIntervalSinceReferenceDate: 200),
        plan: .init(intentionSessionID: session, revision: 1, windows: [window]), browserProcessIdentity: proof)
    func observation(_ outcome: Policy.Outcome, record value: BrowserWindowVisibilityRecord? = nil,
                     live: BrowserProcessIdentity? = .init(pid: 42, launched: 100), id: Int = 7) -> Policy.Observation {
        .init(record: value ?? record, windowID: id, liveProcessIdentity: live, outcome: outcome)
    }
    let unresolved = observation(.unresolved(.windowIdentityUnavailable))
    let hidden = observation(.verifiedMinimized)
    var delayed = Policy(intentionSessionID: session)
    try expect(delayed.update([unresolved], activeIntentionSessionID: session, now: 10) == nil,
        "A new ambiguous claim gets a bounded grace period")
    try expect(delayed.update([unresolved], activeIntentionSessionID: session, now: 12.9) == nil,
        "A delayed native result is not rejected before the grace deadline")
    try expect(delayed.update([hidden], activeIntentionSessionID: session, now: 13.1) == nil,
        "Actual minimized readback clears the deadline, including a pre-minimized unowned window")
    try expect(delayed.update([unresolved], activeIntentionSessionID: session, now: 600) == nil,
        "A previously satisfied window becoming visible starts its own fresh grace")
    try expect(delayed.update([unresolved], activeIntentionSessionID: session, now: 602.9) == nil,
        "Later re-enforcement does not borrow the startup timestamp")
    let failure = delayed.update([unresolved], activeIntentionSessionID: session, now: 603)
    try expect(failure?.windowID == 7 && failure?.browserSessionID == "profile-one"
        && failure?.reason == .windowIdentityUnavailable, "Continuously unresolved identity fails the exact profile/window")
    try expect(delayed.update([unresolved], activeIntentionSessionID: session, now: 900) == nil,
        "Failure is delivered once, never repeatedly")

    for reason: Policy.Reason in [.windowIdentityUnavailable, .accessibilityUnavailable, .ownershipNotSaved, .minimizeNotConfirmed] {
        var policy = Policy(intentionSessionID: session)
        let pending = observation(.unresolved(reason))
        _ = policy.update([pending], activeIntentionSessionID: session, now: 1)
        try expect(policy.update([pending], activeIntentionSessionID: session, now: 4)?.reason == reason,
            "Ambiguity, AX unavailability, persistence failure and unconfirmed effects fail visibly")
    }
    var changing = Policy(intentionSessionID: session)
    _ = changing.update([unresolved], activeIntentionSessionID: session, now: 20)
    var changed = record
    changed.plan.revision = 99; changed.plan.windows[0].title = "Navigating"
    changed.plan.windows[0].frame.left = 200; changed.plan.windows[0].state = "maximized"
    changed.receivedAt = Date(timeIntervalSinceReferenceDate: 900)
    _ = changing.update([observation(.unresolved(.accessibilityUnavailable), record: changed)], activeIntentionSessionID: session, now: 22)
    try expect(changing.update([observation(.unresolved(.minimizeNotConfirmed), record: changed)],
        activeIntentionSessionID: session, now: 23)?.reason == .minimizeNotConfirmed,
        "Revision/title/geometry/state/timestamp churn cannot perpetually reset one unresolved wire identity")

    var navigating = Policy(intentionSessionID: session)
    _ = navigating.update([unresolved], activeIntentionSessionID: session, now: 1)
    try expect(navigating.update([observation(.verifiedMinimized, record: changed)], activeIntentionSessionID: session, now: 4) == nil,
        "A bound window's actual AX success satisfies enforcement after navigation or stale record age")
    var omitted = Policy(intentionSessionID: session)
    _ = omitted.update([unresolved], activeIntentionSessionID: session, now: 1)
    try expect(omitted.update([], activeIntentionSessionID: session, now: 5) == nil,
        "Plan omission cancels an unresolved claim without demanding restoration")
    try expect(omitted.update([unresolved], activeIntentionSessionID: session, now: 6) == nil,
        "A later genuinely re-added claim starts a new grace period")
    try expect(omitted.update([observation(.noLongerExists)], activeIntentionSessionID: session, now: 20) == nil,
        "Positive closure of a previously bound native window retires the claim, not a restriction failure")

    for invalid in [observation(.unresolved(.windowIdentityUnavailable), live: nil),
                    observation(.unresolved(.windowIdentityUnavailable), live: .init(pid: 43, launched: 100)),
                    observation(.unresolved(.windowIdentityUnavailable), live: .init(pid: 42, launched: 101))] {
        var policy = Policy(intentionSessionID: session)
        _ = policy.update([unresolved], activeIntentionSessionID: session, now: 1)
        try expect(policy.update([invalid], activeIntentionSessionID: session, now: 5) == nil,
            "Unknown process proof, another PID and PID reuse never accuse a later lifetime")
    }
    var legacy = record; legacy.browserProcessIdentity = nil
    var old = record; old.plan.intentionSessionID = "old-occurrence"
    var parking = record
    parking.plan.windows = []; parking.plan.parkingWindows = [window]; parking.registeredParkingWindows = [window]
    for excluded in [legacy, old, parking] {
        var policy = Policy(intentionSessionID: session)
        _ = policy.update([observation(.unresolved(.windowIdentityUnavailable), record: excluded)], activeIntentionSessionID: session, now: 1)
        try expect(policy.update([observation(.unresolved(.windowIdentityUnavailable), record: excluded)],
            activeIntentionSessionID: session, now: 100) == nil,
            "Legacy proof, another occurrence and parking registrations never enter normal enforcement failure")
    }
    var differentProfile = record; differentProfile.browserSessionID = "profile-two"
    var profilePolicy = Policy(intentionSessionID: session)
    _ = profilePolicy.update([unresolved], activeIntentionSessionID: session, now: 1)
    try expect(profilePolicy.update([observation(.unresolved(.windowIdentityUnavailable), record: differentProfile)],
        activeIntentionSessionID: session, now: 4) == nil, "Profile-local IDs do not share unresolved deadlines")
    for inactiveSession: String? in [nil, "replacement-occurrence"] {
        var policy = Policy(intentionSessionID: session)
        _ = policy.update([unresolved], activeIntentionSessionID: session, now: 1)
        try expect(policy.update([unresolved], activeIntentionSessionID: inactiveSession, now: 10) == nil,
            "Inactive rules or a replacement occurrence cannot receive an old failure")
        if inactiveSession != nil {
            _ = policy.update([unresolved], activeIntentionSessionID: session, now: 20)
            try expect(policy.update([unresolved], activeIntentionSessionID: session, now: 25) == nil,
                "An old callback cannot rearm a policy that already observed its replacement occurrence")
        }
    }
    var stopped = Policy(intentionSessionID: session)
    _ = stopped.update([unresolved], activeIntentionSessionID: session, now: 1)
    stopped.stop()
    try expect(stopped.update([unresolved], activeIntentionSessionID: session, now: 10) == nil,
        "Stop disarms recovery and all later callbacks even if old rules remain briefly active")

    // Exercise production error routing without installing taps, permissions or
    // effects: the controller has never started, so stop cannot own any windows.
    guard let failure else { throw SpecFailure(description: "Missing enforcement failure fixture") }
    let spec = FocusSessionSpec(displayName: "QA", startupSteps: [], allowedBundleIdentifiers: [],
        fallbackBundleIdentifier: "", strictSingleApp: false, blockAppSwitching: false,
        blockNewApps: false, keepFocused: false, blockBrowserTabEscape: false,
        blockFirefoxChromeClicks: false, allowGoogleSearchTabs: false, spotifyPlaylistURI: nil, allowSpotifyForeground: false)
    let failedLock = FocusLock(spec: spec)
    failedLock.stopForSafety(failure: .browserWindowEnforcementFailed(failure))
    do {
        try failedLock.run { preconditionFailure("Failed visibility cannot report readiness") }
        throw SpecFailure(description: "Visibility safety failure was swallowed as ordinary completion")
    } catch let error as FocusLockError {
        try expect(error.description == failure.message && failedLock.didStopForSafety,
            "The exact restriction failure survives stop and reaches the app as an error")
    }
    for stop: (FocusLock) -> Void in [{ $0.stop() }, { $0.stopForExpiry() }] {
        let lock = FocusLock(spec: spec); stop(lock)
        lock.stopForSafety(failure: .browserWindowEnforcementFailed(failure))
        try lock.run { preconditionFailure("Stopped lock became ready") }
        try expect(!lock.didStopForSafety, "A late visibility callback cannot replace manual/expiry completion with failure")
    }
}
