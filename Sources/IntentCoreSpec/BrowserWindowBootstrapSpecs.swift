import Foundation
import IntentCore

func runBrowserWindowBootstrapSpecs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-bootstrap-spec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserWindowVisibilityStore(directory: directory)
    let now = Date(), proof = BrowserProcessIdentity(pid: 2100, launched: Date().timeIntervalSinceReferenceDate - 60)
    let window = BrowserWindowVisibilityWindow(windowID: 303, title: "Other Desktop", frame: .init(left: 0, top: 39, width: 1710, height: 1073), state: "maximized")
    let browser = "org.mozilla.firefox", profile = "profile", session = "session"
    var plan = BrowserWindowVisibilityPlan(intentionSessionID: session, revision: 1, windows: [window])
    _ = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: profile,
        currentIntentionSessionID: session, receivedAt: now, browserProcessIdentity: proof)
    func record() -> BrowserWindowVisibilityRecord {
        store.record(browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: session)!
    }
    func effect(_ id: String = "effect", native: UInt32 = 12687) -> BrowserWindowMinimizeBootstrap {
        .init(effectID: id, nativeWindowID: native, planRevision: record().plan.revision,
            expiresAtUnixMS: now.timeIntervalSince1970 * 1000 + 2500, descriptor: record().plan.windows[0])
    }
    func claim(_ id: String = "effect", current: String? = "session", identity: BrowserProcessIdentity? = nil,
               at: Date? = nil) throws -> Bool {
        try store.claimBootstrap(effectID: id, browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: session, browserProcessIdentity: identity ?? proof,
            currentIntentionSessionID: current, now: at ?? now)
    }
    func result(_ outcome: BrowserWindowMinimizeBootstrap.Outcome, id: String = "effect") throws -> Bool {
        try store.recordBootstrapResult(effectID: id, browserBundleIdentifier: browser, browserSessionID: profile,
            intentionSessionID: session, browserProcessIdentity: proof, outcome: outcome)
    }
    try expect(record().bootstrapEffects.isEmpty && record().verifiedWindowIDs.isEmpty,
        "Plan acceptance is neither a delegated effect nor native effect verification")
    let unpreparedClaim = try claim()
    try expect(!unpreparedClaim, "No claim can grant before native pending ownership publication")
    var stale = record(); stale.plan.revision += 1
    let rejectedPreparation = try store.prepareBootstrap(effect(), for: stale, now: now)
    try expect(!rejectedPreparation && record().bootstrapEffects.isEmpty,
        "An explicit prepare rejection cannot publish an effect or make a later claim valid")
    func recovered(_ saved: BrowserWindowVisibilityRecord?) -> BrowserWindowMinimizeBootstrap.Disposition {
        BrowserWindowBootstrapRecovery.disposition(record: saved, browser: browser, profile: profile,
            intention: session, process: proof, effectID: "effect", nativeWindowID: 12687, browserWindowID: 303)
    }
    try expect(recovered(record()) == .noEffect, "Exact valid monotonic record without effect safely retires a crash before publication")
    try expect(recovered(nil) == .pending, "Missing/unreadable record never proves non-dispatch")
    var foreign = record(); foreign.browserProcessIdentity = .init(pid: proof.pid, launched: proof.launched + 1)
    try expect(recovered(foreign) == .pending, "A different process cannot retire unpublished ownership")
    for failure in ["finish", "rejected", "throw", "retirement-save"] {
        var journalOwned = true, didPublish = false
        let accepted = BrowserWindowBootstrapRecovery.publishAfterJournal(mayEnforce: { failure != "finish" }, publish: {
            didPublish = true
            if failure == "throw" { throw NSError(domain: "write-possibly-committed", code: 1) }
            return false
        }, retireUnpublished: { if failure != "retirement-save" { journalOwned = false } })
        try expect(!accepted && didPublish == (failure != "finish"), "Finish after journal save prevents publication")
        try expect(journalOwned == ["throw", "retirement-save"].contains(failure),
            "Definite rejected publication retires only after saved cleanup; uncertain write/save failure retain ownership")
    }
    let holder = Process(), ready = directory.appendingPathComponent("lock-ready")
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = ["-c", "import fcntl,pathlib,sys,time; f=open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(3)",
        store.fileURL(browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: session).appendingPathExtension("lock").path, ready.path]
    try holder.run()
    defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
    let readyDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.01) }
    try expect(FileManager.default.fileExists(atPath: ready.path), "Contending writer acquired exact scoped record lock")
    let started = Date(); var threwBusy = false
    do { _ = try store.prepareBootstrap(effect(), for: record(), now: now) } catch { threwBusy = true }
    try expect(threwBusy && Date().timeIntervalSince(started) < 0.5 && record().bootstrapEffects.isEmpty,
        "Main-thread bootstrap preparation must fail promptly under a competing writer, without publishing")
    holder.terminate(); holder.waitUntilExit()
    let prepared = try store.prepareBootstrap(effect(), for: record(), now: now)
    try expect(prepared && record().bootstrapEffects.first?.disposition == .pending,
        "Prepared ownership is durable but not an observed effect")
    let preparedVerification = try store.writeVerification(for: record(), windowIDs: [303])
    try expect(!preparedVerification, "Prepared delegation cannot become verified through arbitrary later AX=true")
    let duplicate = try store.prepareBootstrap(effect("second"), for: record(), now: now)
    try expect(!duplicate, "One browser window gets only one delegated attempt per occurrence")
    let finishedClaim = try claim(current: nil), replacementClaim = try claim(current: "new-session")
    let foreignProof = try claim(identity: .init(pid: proof.pid, launched: proof.launched + 1))
    let expired = try claim(at: now.addingTimeInterval(4))
    try expect(!finishedClaim && !replacementClaim && !foreignProof && !expired,
        "Finish, replacement, process reuse and expiry cannot authorize the effect")
    // A parking registration and title/frame update do not unbind a native CG ID.
    plan.revision += 1; plan.windows[0].title = "Changed Title"; plan.windows[0].frame.left = 50
    plan.parkingWindows = [.init(windowID: 404, title: "Holder", frame: window.frame, state: "minimized")]
    _ = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: profile,
        currentIntentionSessionID: session, browserProcessIdentity: proof)
    let revisionClaim = try claim()
    try expect(revisionClaim && record().bootstrapEffects.first?.phase == .issued,
        "Unrelated parking revision and ordinary title/geometry changes cannot strand the same bound target")
    let replay = try claim()
    try expect(!replay, "Lost/repeated claim receipts never grant a second browser effect")
    let issuedVerification = try store.writeVerification(for: record(), windowIDs: [303])
    try expect(!issuedVerification, "Issued uncertainty cannot pass the AX=true early-success path")
    let uncertain = try result(.uncertain), uncertainReplay = try result(.uncertain), contradictory = try result(.settled)
    try expect(uncertain && uncertainReplay && !contradictory && record().bootstrapEffects[0].disposition == .pending,
        "Unknown dispatch is durable, idempotent, and cannot be upgraded by a later arbitrary observation")
    try store.cancelPreparedBootstrap(effectID: "effect", browserBundleIdentifier: browser, browserSessionID: profile,
        intentionSessionID: session, browserProcessIdentity: proof)
    try expect(record().bootstrapEffects[0].disposition == .pending,
        "Finish cannot rewrite already issued/uncertain ownership into no effect")
    plan.revision += 1; plan.windows = []
    _ = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: profile,
        currentIntentionSessionID: session, browserProcessIdentity: proof)
    try expect(record().bootstrapEffects.count == 1 && record().bootstrapEffects[0].disposition == .pending,
        "Plan omission never erases uncertain native recovery ownership")

    // Independent terminal settlement / cancellation / omission fixtures.
    for (suffix, terminal) in [("settled", BrowserWindowMinimizeBootstrap.Outcome.settled), ("skip", .notDispatched)] {
        let sid = "session-\(suffix)"
        let p = BrowserWindowVisibilityPlan(intentionSessionID: sid, revision: 1, windows: [window])
        _ = try store.accept(p, browserBundleIdentifier: browser, browserSessionID: profile,
            currentIntentionSessionID: sid, browserProcessIdentity: proof)
        func current() -> BrowserWindowVisibilityRecord { store.record(browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: sid)! }
        let e = BrowserWindowMinimizeBootstrap(effectID: suffix, nativeWindowID: 12687, planRevision: 1,
            expiresAtUnixMS: now.timeIntervalSince1970 * 1000 + 2500, descriptor: window)
        _ = try store.prepareBootstrap(e, for: current(), now: now)
        if terminal == .settled {
            _ = try store.claimBootstrap(effectID: suffix, browserBundleIdentifier: browser, browserSessionID: profile,
                intentionSessionID: sid, browserProcessIdentity: proof, currentIntentionSessionID: sid, now: now)
            let accepted = try store.recordBootstrapResult(effectID: suffix, browserBundleIdentifier: browser, browserSessionID: profile,
                intentionSessionID: sid, browserProcessIdentity: proof, outcome: .settled)
            try expect(accepted && current().bootstrapEffects[0].disposition == .nativeConfirmation,
                "Fulfilled API settlement permits exact native AX confirmation even after readback failure")
            let verified = try store.writeVerification(for: current(), windowIDs: [303])
            try expect(verified && current().verifiedWindowIDs == [303] && current().verificationRevision == 1,
                "Only app-confirmed latest claims publish native verification independent of plan ACK")
            var next = p; next.revision = 2; next.windows[0].title = "Later"
            _ = try store.accept(next, browserBundleIdentifier: browser, browserSessionID: profile,
                currentIntentionSessionID: sid, browserProcessIdentity: proof)
            try expect(current().verifiedWindowIDs.isEmpty && current().verificationRevision == nil,
                "A later descriptor needs native recomputation, not stale verification replay")
            let staleVerification = try store.writeVerification(for: .init(browserBundleIdentifier: browser,
                browserSessionID: profile, plan: p, browserProcessIdentity: proof), windowIDs: [303])
            try expect(!staleVerification, "A delayed observation cannot verify a superseded descriptor")
        } else {
            try store.cancelPreparedBootstrap(effectID: suffix, browserBundleIdentifier: browser, browserSessionID: profile,
                intentionSessionID: sid, browserProcessIdentity: proof)
            let cancelledClaim = try store.claimBootstrap(effectID: suffix, browserBundleIdentifier: browser, browserSessionID: profile,
                intentionSessionID: sid, browserProcessIdentity: proof, currentIntentionSessionID: sid, now: now)
            try expect(!cancelledClaim && current().bootstrapEffects[0].disposition == .noEffect,
                "Finish before claim makes a prepared effect conclusively non-dispatched")
        }
    }
    try expect(BrowserWindowVisibilityEnforcement(record: .init(browserBundleIdentifier: browser,
        browserSessionID: profile, plan: plan)) == nil, "Unproven records cannot construct verification receipts")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as! [String: Any]
    object.removeValue(forKey: "bootstrapEffects"); object.removeValue(forKey: "verificationRevision"); object.removeValue(forKey: "verifiedWindowIDs")
    let legacy = try JSONDecoder().decode(BrowserWindowVisibilityRecord.self, from: JSONSerialization.data(withJSONObject: object))
    try expect(legacy.bootstrapEffects.isEmpty && legacy.verifiedWindowIDs.isEmpty && legacy.verificationRevision == nil,
        "Existing records acquire neither delegated authority nor verification while decoding")
    print("Firefox bootstrap ownership / one-shot / uncertainty / native verification regressions passed")
}
