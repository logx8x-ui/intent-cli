import Foundation
import CoreGraphics
import IntentCore

func runPermittedWindowRecoverySpecs() throws {
    typealias Policy = PermittedWindowRecoveryPolicy
    let selected = Policy.Identity(bundleIdentifier: "selected.app", pid: 42, launched: 100, windowID: 7)
    let sibling = Policy.Identity(bundleIdentifier: "selected.app", pid: 42, launched: 100, windowID: 8)
    try expect(Policy.accepts(expected: selected, sampled: selected, permitted: true), "An exactly verified allowed window can be remembered")
    for changed in [sibling, .init(bundleIdentifier: "selected.app", pid: 43, launched: 100, windowID: 7),
                    .init(bundleIdentifier: "selected.app", pid: 42, launched: 101, windowID: 7),
                    .init(bundleIdentifier: "other.app", pid: 42, launched: 100, windowID: 7)] {
        try expect(!Policy.accepts(expected: selected, sampled: changed, permitted: true), "A delayed worker cannot substitute a sibling, other app or process birth")
    }
    try expect(!Policy.accepts(expected: selected, sampled: nil, permitted: true)
        && !Policy.accepts(expected: selected, sampled: selected, permitted: false), "Unknown and excluded windows cannot enter the recovery cache")
    let frame = CGRect(x: 100, y: 40, width: 800, height: 600)
    let native = Policy.Window(identity: selected, title: "Study", frame: frame)
    try expect(Policy.uniquelyMatches(expected: selected, title: "Study", frame: frame, native: [native]), "Exact unique title, position and size bind the selected native ID")
    try expect(!Policy.uniquelyMatches(expected: selected, title: "Study", frame: frame,
        native: [native, .init(identity: sibling, title: "Study", frame: frame)]), "Identical sibling geometry is ambiguous, never a first-match guess")
    try expect(!Policy.uniquelyMatches(expected: selected, title: "Study", frame: CGRect(x: 100, y: 40, width: 400, height: 600), native: [native]), "Matching title and position with another size cannot bind")
    try expect(!Policy.uniquelyMatches(expected: selected, title: "Study", frame: frame,
        native: [.init(identity: sibling, title: "Study", frame: frame)]), "A uniquely matching excluded sibling still cannot become the expected window")

    for failure in [Policy.Outcome.raiseFailed, .activationRejected, .restored] {
        let gate = DeferredSessionActionGate(), token = gate.token
        var effects: [String] = []
        let outcome = Policy.restore(perform: { gate.perform(ifCurrent: token, $0) }, validate: { true },
            setMain: { effects.append("main") }, raise: { effects.append("raise"); return failure != .raiseFailed },
            activationTargetCurrent: { failure != .activationRejected }, activate: { effects.append("activate"); return true })
        try expect(outcome == failure, "Raise and verified-main failures preserve exact recovery outcome")
        try expect(effects == (failure == .restored ? ["main", "raise", "activate"] : ["main", "raise"]),
            "Invalid AXRaise or changed main sibling never activates the app")
    }
    for stopAfter in ["before", "main", "raise"] {
        let gate = DeferredSessionActionGate(), token = gate.token
        var effects: [String] = []
        if stopAfter == "before" { gate.invalidate() }
        let outcome = Policy.restore(perform: { gate.perform(ifCurrent: token, $0) }, validate: { true },
            setMain: { effects.append("main"); if stopAfter == "main" { gate.invalidate() } },
            raise: { effects.append("raise"); if stopAfter == "raise" { gate.invalidate() }; return true },
            activationTargetCurrent: { true }, activate: { effects.append("activate"); return true })
        try expect(outcome == .unavailable && !effects.contains("activate"), "Stop fences every queued recovery effect, including a synchronous stop inside AX callbacks")
        try expect(effects == (stopAfter == "before" ? [] : stopAfter == "main" ? ["main"] : ["main", "raise"]), "No later old-session effect starts after stop")
    }
    for loseIdentityAfter in ["main", "raise"] {
        var valid = true, effects: [String] = []
        _ = Policy.restore(perform: { $0() }, validate: { valid },
            setMain: { effects.append("main"); if loseIdentityAfter == "main" { valid = false } },
            raise: { effects.append("raise"); if loseIdentityAfter == "raise" { valid = false }; return true },
            activationTargetCurrent: { true }, activate: { effects.append("activate"); return true })
        try expect(!effects.contains("activate") && (loseIdentityAfter != "main" || !effects.contains("raise")),
            "Closure, identity replacement or policy rejection between AX effects cancels the next effect")
    }
}
