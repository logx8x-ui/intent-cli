import Foundation
import IntentCore

func runDesktopSessionCoverageSpecs() throws {
    typealias Gate = DesktopSessionCoveragePolicy
    try expect(Gate.requiredDomains(enforcesVisibility: true, hasReportedWindowSession: false, browsers: []) == [.native],
        "Legacy/native-only intentions do not require nonexistent browser bridge receipts")
    try expect(Gate.requiredDomains(enforcesVisibility: false, hasReportedWindowSession: true, browsers: ["com.google.Chrome"]).isEmpty,
        "An intention without visibility enforcement has no coverage prerequisites")
    try expect(Gate.requiredDomains(enforcesVisibility: true, hasReportedWindowSession: true, browsers: ["com.google.Chrome"])
        == [.native, .reported, .browser("com.google.Chrome")], "Browser intentions require all current native and reported coverage")
    let browser = "com.google.Chrome"
    let domains: Set<Gate.Domain> = [.native, .reported, .browser(browser)]
    func finish(_ gate: inout Gate, _ sample: DesktopSessionObservation, resolved: Bool) {
        for domain in domains { gate.record(domain, resolved: resolved, generation: sample.generation) }
    }

    // Observed regression: good Chrome coverage, idle lock, three seconds of
    // unavailable AX. The production boundary must skip those packets entirely.
    var clock = DesktopSessionClock(), gate = Gate(required: domains)
    let initial = clock.observe(.available, uptime: 0)
    gate.update(initial); finish(&gate, initial, resolved: true)
    try expect(gate.isReady, "Initial complete coverage is ready")
    let beforeLockGeneration = initial.generation
    gate.update(clock.observe(.secured, uptime: 6))
    try expect(!gate.canObserve && !gate.isReady, "Lock withdraws proof without releasing restrictions")
    for time in [9.1, 10, 30, 60] {
        gate.update(clock.observe(.secured, uptime: time))
        try expect(!gate.canObserve && gate.expiredDomain() == nil,
            "Protected-desktop AX failure never consumes the visibility deadline")
        gate.record(.browser(browser), resolved: true, generation: beforeLockGeneration)
        try expect(!gate.isReady, "A pre-lock callback cannot publish ready during lock")
    }
    let resumed = clock.observe(.available, uptime: 61)
    gate.update(resumed)
    try expect(resumed.activeUptime == 6 && !gate.isReady, "Unlock preserves budget and requires complete fresh proof")
    for domain in domains { gate.record(domain, resolved: true, generation: beforeLockGeneration) }
    try expect(!gate.isReady, "Late pre-lock callback cannot publish ready after unlock either")
    finish(&gate, resumed, resolved: true)
    try expect(gate.isReady && gate.expiredDomain() == nil, "Fresh post-unlock complete coverage resumes normally")

    // A missing optional lock dictionary field is unknown, not indefinite
    // protection and not a permanent startup failure when real AX succeeds.
    var unknownClock = DesktopSessionClock(), unknown = Gate(required: domains)
    var unknownSample = unknownClock.observe(.unknown, uptime: 10)
    unknown.update(unknownSample); finish(&unknown, unknownSample, resolved: true)
    try expect(unknown.isReady, "Unknown secure state accepts fresh complete coverage")
    unknownSample = unknownClock.observe(.unknown, uptime: 11)
    unknown.update(unknownSample); finish(&unknown, unknownSample, resolved: false)
    unknownSample = unknownClock.observe(.unknown, uptime: 14)
    unknown.update(unknownSample)
    try expect(unknown.expiredDomain() == nil, "Ordinary unlocked observations do not arm a new generic runtime deadline")
    var unknownPending = Gate(required: domains, requiresInitialVerification: true)
    unknownPending.update(unknownClock.observe(.unknown, uptime: 20))
    unknownPending.update(unknownClock.observe(.unknown, uptime: 23))
    try expect(unknownPending.expiredDomain() != nil, "Unknown plus missing fresh AX cannot indefinitely suspend an armed deadline")

    var wakeClock = DesktopSessionClock(), wake = Gate(required: [.browser(browser)], requiresInitialVerification: true)
    wake.update(wakeClock.observe(.unknown, uptime: 0))
    wake.update(wakeClock.observe(.secured, uptime: 1))
    wake.update(wakeClock.observe(.available, uptime: 61))
    try expect(wake.hasPendingVerification && wake.expiredDomain() == nil, "A pending wake check keeps its two seconds after sixty seconds locked")
    wake.update(wakeClock.observe(.available, uptime: 62.9))
    try expect(wake.expiredDomain() == nil, "Wake grace does not fire before its original budget")
    wake.update(wakeClock.observe(.secured, uptime: 62.9))
    wake.update(wakeClock.observe(.unknown, uptime: 90))
    wake.update(wakeClock.observe(.unknown, uptime: 90.2))
    try expect(wake.expiredDomain() != nil, "Repeated lock and unknown state cannot replenish a pending wake deadline")

    // Real four-policy integration: every pending timer consumes the exact same
    // production activeUptime, including native startup, offscreen obligations,
    // browser cohort hiding, and profile-reported window enforcement.
    struct FourPolicies {
        let browser = "com.google.Chrome"
        let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: "test.excluded", pid: 42, launched: 1, windowID: 8)
        let identity = BrowserWindowCoveragePolicy.NativeIdentity(bundleIdentifier: "com.google.Chrome", pid: 43, launched: 2, windowID: 9)
        var clock = DesktopSessionClock()
        var gate = Gate(required: [.native, .reported, .browser("com.google.Chrome")])
        var native = NativeVisibilityCoveragePolicy(required: true)
        var offscreen = NativeOffscreenWindowCoveragePolicy()
        var cohort: BrowserWindowCoverageCohort
        var reported = BrowserWindowEnforcementPolicy(intentionSessionID: "occurrence")
        var record: BrowserWindowVisibilityRecord
        init() {
            cohort = .init(windows: [.init(identity: identity, title: "Fixture", frame: .init(x: 0, y: 0, width: 100, height: 100))], allowsLaterWindows: false)
            record = .init(browserBundleIdentifier: browser, browserSessionID: "profile", receivedAt: Date(),
                plan: .init(intentionSessionID: "occurrence", revision: 1, windows: [.init(windowID: 9, title: "Fixture", frame: .init(left: 0, top: 0, width: 100, height: 100), state: "normal")]),
                browserProcessIdentity: .init(pid: 43, launched: 2))
        }
        mutating func apply(_ state: DesktopSessionState, at time: Double) -> [String] {
            let sample = clock.observe(state, uptime: time)
            gate.update(sample)
            guard gate.canObserve else { return [] }
            let now = sample.activeUptime
            native.begin(now: now)
            if offscreen.targets.isEmpty { _ = offscreen.update([target: .offscreen], now: now) }
            var failures: [String] = []
            if native.update(nil, now: now) != nil { failures.append("native") }
            if offscreen.update(nil, now: now) != nil { failures.append("offscreen") }
            if cohort.observe(identity, outcome: .unresolved, now: now) != nil { failures.append("cohort") }
            if reported.update([.init(record: record, windowID: 9, liveProcessIdentity: record.browserProcessIdentity,
                outcome: .unresolved(.accessibilityUnavailable))], activeIntentionSessionID: "occurrence", now: now) != nil { failures.append("reported") }
            for domain in [Gate.Domain.native, .reported, .browser(browser)] {
                gate.record(domain, resolved: false, generation: sample.generation)
            }
            return failures
        }
        mutating func stop() { gate.stop(); native.stop(); offscreen.stop(); reported.stop() }
    }
    var combined = FourPolicies()
    try expect(combined.apply(.available, at: 10).isEmpty, "Four production deadlines begin unresolved")
    try expect(combined.apply(.secured, at: 12).isEmpty, "Lock retains the two seconds already consumed")
    try expect(combined.apply(.secured, at: 100).isEmpty, "Long lock does not spend any remaining deadline")
    try expect(combined.apply(.available, at: 100).isEmpty, "Unlock retains the original one second remaining")
    try expect(combined.apply(.available, at: 100.8).isEmpty, "No deadline fires prematurely after unlock")
    try expect(combined.apply(.secured, at: 100.8).isEmpty, "Repeated lock does not reset unresolved age")
    try expect(combined.apply(.available, at: 200).isEmpty, "Repeated unlock cannot replenish the original budget")
    combined.record.plan.revision = 8
    combined.record.plan.windows[0].title = "Changed"
    try expect(Set(combined.apply(.available, at: 200.25)) == Set(["native", "offscreen", "cohort", "reported"]),
        "All four deadlines fail after the same original three active seconds despite lock and metadata churn")
    try expect(combined.gate.hasPendingVerification, "Generic wake verification remains pending; earlier real obligations already fail at their retained deadlines")

    var oldClock = DesktopSessionClock(), oldUnarmed = Gate(required: domains)
    var oldSample = oldClock.observe(.available, uptime: 0)
    oldUnarmed.update(oldSample); finish(&oldUnarmed, oldSample, resolved: false)
    oldSample = oldClock.observe(.secured, uptime: 100)
    oldUnarmed.update(oldSample)
    oldSample = oldClock.observe(.available, uptime: 200)
    oldUnarmed.update(oldSample)
    try expect(oldUnarmed.expiredDomain() == nil, "Old unarmed ordinary ambiguity cannot cause an immediate new wake deadline")
    var oldFailure = oldUnarmed
    finish(&oldUnarmed, oldSample, resolved: true)
    try expect(oldUnarmed.isReady, "Long ordinary unresolved state can resume with fresh complete coverage")
    oldFailure.update(oldClock.observe(.available, uptime: 203))
    try expect(oldFailure.expiredDomain() != nil, "Unresolved fresh wake verification still has its bounded three active seconds")

    var ordinary = FourPolicies()
    _ = ordinary.apply(.available, at: 0)
    try expect(ordinary.apply(.available, at: 3).count == 4, "Ordinary unlocked AX failure retains every existing safety stop")
    var stopped = FourPolicies()
    _ = stopped.apply(.available, at: 0); _ = stopped.apply(.secured, at: 1)
    stopped.stop()
    try expect(stopped.apply(.available, at: 100).isEmpty && !stopped.gate.isReady && !stopped.gate.canObserve,
        "Stopping while locked prevents stale unlock work from resurrecting the occurrence")

    var transitionClock = DesktopSessionClock(), transitionGate = Gate(required: domains)
    let old = transitionClock.observe(.available, uptime: 0)
    transitionGate.update(old); finish(&transitionGate, old, resolved: true)
    _ = transitionClock.observe(.secured, uptime: 1)
    let current = transitionClock.observe(.available, uptime: 10)
    transitionGate.update(current)
    try expect(!transitionGate.accepts(generation: old.generation),
        "A lock and unlock observed by another consumer fences callbacks even if the visibility timer missed both")
    var uncertain = FourPolicies()
    _ = uncertain.apply(.available, at: 0); _ = uncertain.apply(.secured, at: 1)
    _ = uncertain.apply(.unknown, at: 50)
    try expect(uncertain.apply(.unknown, at: 52).count == 4, "A formerly secured dictionary becoming unknown resumes charging time")
    // The same fence used by static ownership recovery and focus correction.
    // AX may return only after the secure desktop replaced the user's session.
    var restoreClock = DesktopSessionClock()
    var restoreSample = restoreClock.observe(.available, uptime: 0)
    let oldFence = DesktopSessionEffectFence(restoreSample)
    var hidden = true, dispatches = 0
    let interrupted = NativeVisibilityCoverageEffects.restoreWithFallback(
        isCurrent: { oldFence.permits(restoreSample) }, readHidden: {
            restoreSample = restoreClock.observe(.secured, uptime: 1)
            return hidden
        }, shouldReveal: { true }, dispatchPrimary: { dispatches += 1; hidden = false }, dispatchFallback: { dispatches += 1 })
    try expect(!interrupted && dispatches == 0, "Lock during AX keeps restoration ownership and dispatches no reveal")
    restoreSample = restoreClock.observe(.available, uptime: 20)
    try expect(!oldFence.permits(restoreSample), "An old restoration transaction cannot resume after unlock")
    let retryFence = DesktopSessionEffectFence(restoreSample)
    let retried = NativeVisibilityCoverageEffects.restoreWithFallback(
        isCurrent: { retryFence.permits(restoreSample) }, readHidden: { hidden }, shouldReveal: { true },
        dispatchPrimary: { dispatches += 1; hidden = false }, dispatchFallback: { dispatches += 1 })
    try expect(retried && dispatches == 1, "A fresh wake retry restores retained ownership without requiring a changed browser plan")
    hidden = true
    let readbackFence = DesktopSessionEffectFence(restoreSample)
    let interruptedReadback = NativeVisibilityCoverageEffects.restoreWithFallback(
        isCurrent: { readbackFence.permits(restoreSample) }, readHidden: {
            if !hidden { restoreSample = restoreClock.observe(.secured, uptime: 21) }
            return hidden
        }, shouldReveal: { true }, dispatchPrimary: { dispatches += 1; hidden = false }, dispatchFallback: { dispatches += 1 })
    try expect(!interruptedReadback && dispatches == 2, "Lock after dispatch retains the journal until fresh visible readback")
    restoreSample = restoreClock.observe(.available, uptime: 40)
    let finalFence = DesktopSessionEffectFence(restoreSample)
    let retired = NativeVisibilityCoverageEffects.restoreWithFallback(
        isCurrent: { finalFence.permits(restoreSample) }, readHidden: { hidden }, shouldReveal: { true },
        dispatchPrimary: { dispatches += 1 }, dispatchFallback: { dispatches += 1 })
    try expect(retired && dispatches == 2, "Fresh retry retires already-visible ownership without a duplicate reveal")

}
