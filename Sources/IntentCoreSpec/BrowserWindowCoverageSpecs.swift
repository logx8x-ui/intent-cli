import Foundation
import IntentCore

func runBrowserWindowCoverageSpecs() throws {
    typealias Policy = BrowserWindowCoveragePolicy
    let browser = "com.google.Chrome", proof = BrowserProcessIdentity(pid: 401, launched: 900)
    let frame = CGRect(x: 0, y: 30, width: 1000, height: 700)
    func native(_ id: UInt32, _ title: String, _ bounds: CGRect? = nil, process: BrowserProcessIdentity? = nil) -> Policy.NativeWindow {
        let p = process ?? proof
        return .init(identity: .init(bundleIdentifier: browser, pid: p.pid, launched: p.launched, windowID: id), title: title, frame: bounds ?? frame)
    }
    func report(_ id: Int, _ title: String, profile: String = "a", bounds: CGRect? = nil,
                process: BrowserProcessIdentity? = nil) -> Policy.ReportedWindow {
        .init(identity: .init(bundleIdentifier: browser, browserSessionID: profile, windowID: id), processIdentity: process ?? proof,
            title: title, frame: bounds ?? frame)
    }
    let a = native(11, "Allowed — Google Chrome – A"), b = native(12, "Other profile — Google Chrome – B")
    let auxiliary = native(13, "", CGRect(x: 99, y: 64, width: 1200, height: 139))
    let omittedOtherSpace = native(14, "Unknown Desktop — Google Chrome")
    let all = [a, b, auxiliary, omittedOtherSpace]
    let standard: [Policy.StandardWindow] = [a, b].map { .init(bundleIdentifier: browser, processIdentity: proof, title: $0.title, frame: $0.frame) }
    let observed = Policy.standardIdentities(native: all, standard: standard)
    try expect(observed == Set([a.identity, b.identity]), "AX positives classify real windows without size/title exceptions for auxiliary surfaces")
    let selected = report(100, "Allowed")
    guard case .complete(let coverage) = Policy.evaluate(browserBundleIdentifier: browser, native: all,
        observedStandard: observed!, reported: [selected], requiredSelected: [selected.identity], knownProfiles: ["a", "empty-profile"], continuousIdentities: observed!, witnessedBeforeSnapshot: observed!) else {
        throw NSError(domain: "Expected narrow observed Chrome coverage", code: 1)
    }
    try expect(coverage.unreported == [b] && coverage.matches[selected.identity] == a.identity,
        "A connected selected profile does not silently omit a real standard window in another profile")
    try expect(coverage.knownProfiles == ["a", "empty-profile"] && !coverage.observableIdentities.contains(auxiliary.identity)
        && !coverage.observableIdentities.contains(omittedOtherSpace.identity),
        "Empty reporting profiles retain freshness obligations; unreported AX-absent surfaces are outside claimed coverage")
    guard case .incomplete(.inventoryUnavailable) = Policy.evaluate(browserBundleIdentifier: browser, native: nil,
        observedStandard: [], reported: []) else { throw NSError(domain: "Inventory failure must not become empty success", code: 1) }
    guard case .incomplete(.selectedWindowMissing) = Policy.evaluate(browserBundleIdentifier: browser, native: all,
        observedStandard: observed!, reported: [], requiredSelected: [selected.identity]) else { throw NSError(domain: "Missing selection", code: 1) }
    let duplicate = native(99, a.title)
    try expect(Policy.standardIdentities(native: all + [duplicate], standard: standard) == nil,
        "One AX element cannot certify two indistinguishable native CG backing IDs")
    try expect(Policy.standardIdentities(native: all, standard: standard + [standard[0]]) == nil,
        "Two AX elements cannot bind the same native window")
    for reports in [[selected, report(101, "Allowed", profile: "b")], [report(100, "Allowed", process: .init(pid: proof.pid, launched: proof.launched + 1))]] {
        guard case .incomplete = Policy.evaluate(browserBundleIdentifier: browser, native: all,
            observedStandard: observed!, reported: reports) else { throw NSError(domain: "Reverse/profile/process ambiguity", code: 1) }
    }
    guard case .incomplete(.ambiguousIdentity) = Policy.evaluate(browserBundleIdentifier: browser, native: all,
        observedStandard: observed!, reported: [selected, report(140, "Unknown Desktop")],
        continuousIdentities: observed!, witnessedBeforeSnapshot: observed!) else {
        throw SpecFailure(description: "A newly reported AX-absent Chrome window cannot borrow a CG-only identity")
    }
    let equalTitleElsewhere = native(15, "Allowed", CGRect(x: 50, y: 70, width: 800, height: 600))
    guard case .complete(let byGeometry) = Policy.evaluate(browserBundleIdentifier: browser, native: all + [equalTitleElsewhere],
        observedStandard: observed!, reported: [selected], continuousIdentities: observed!, witnessedBeforeSnapshot: observed!) else { throw NSError(domain: "Exact geometry matching", code: 1) }
    try expect(byGeometry.matches[selected.identity] == a.identity, "Equal title at different geometry cannot override selected native identity")

    var snapshot = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: "a", tabs: [], allTabs: [
        .init(id: 1, windowID: 100, index: 0, title: "Allowed", url: "https://example.test", active: true,
              windowFrame: .init(left: 0, top: 30, width: 1000, height: 700))])
    snapshot.browserProcessIdentity = proof
    try expect(Policy.reportedWindows(snapshots: [snapshot])?.count == 1, "Raw profile rows retain host-stamped process identity")
    var missingAll = snapshot; missingAll.allTabs = nil
    try expect(Policy.reportedWindows(snapshots: [missingAll]) == nil, "Filtered tabs cannot substitute for full discovery")
    var mismatchedFrame = snapshot; var other = snapshot.allTabs![0]; other.id = 2; other.active = false; other.windowFrame?.left = 9
    mismatchedFrame.allTabs?.append(other)
    try expect(Policy.reportedWindows(snapshots: [mismatchedFrame]) == nil, "Conflicting per-window frames cannot supply coverage")
    var multipleActive = snapshot; other = snapshot.allTabs![0]; other.id = 2; multipleActive.allTabs?.append(other)
    try expect(Policy.reportedWindows(snapshots: [multipleActive]) == nil, "An ambiguous active tab cannot name a window")

    for kind in 0..<4 {
        var malformed = snapshot
        switch kind {
        case 0: malformed.allTabs?.append(snapshot.allTabs![0])
        case 1: malformed.allTabs?[0].id = -1
        case 2: malformed.allTabs?[0].index = -1
        default: malformed.allTabs?[0].index = 1
        }
        try expect(Policy.reportedWindows(snapshots: [malformed]) == nil, "Malformed tab identity/index fixture \(kind) is not complete coverage")
    }
    try runCoverageAnchorSpecs()

    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("intent-coverage-spec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let base = fixture.appendingPathComponent("chrome-tabs.json"), now = Date()
    snapshot.updatedAt = now; snapshot.snapshotRequestIDs = ["request-one", "request-two"]
    snapshot.completeWindowInventory = true
    snapshot.guardEnabled = true; snapshot.guardCapabilities = [BrowserGuardCapability.nativeWindowVisibility.rawValue]
    func writeSnapshot(_ value: BrowserTabSnapshot) throws {
        let partition = BrowserProfileSnapshots.partition(base, session: value.browserSessionID!)
        try JSONEncoder().encode(value).write(to: partition)
        try JSONEncoder().encode(value).write(to: BrowserProfileSnapshots.coveragePartition(base, session: value.browserSessionID!))
        try JSONEncoder().encode(now).write(to: partition.appendingPathExtension("heartbeat"))
    }
    try writeSnapshot(snapshot)
    try expect(BrowserProfileSnapshots.coverageSnapshots(base: base, requestID: "request-two", now: now).count == 1,
        "Concurrent correlated requests retain host proof and full profile inventory")
    try expect(BrowserProfileSnapshots.coverageSnapshots(base: base, requestID: "other", now: now).isEmpty,
        "A heartbeat or another command reply cannot satisfy discovery")
    for kind in 0..<9 {
        var invalid = snapshot
        switch kind {
        case 0: invalid.updatedAt = now.addingTimeInterval(-3.01)
        case 1: invalid.updatedAt = now.addingTimeInterval(1)
        case 2: invalid.browserProcessIdentity = nil
        case 3: invalid.allTabs = nil
        case 4: invalid.guardEnabled = false
        case 5: invalid.guardCapabilities = []
        case 6: invalid.snapshotRequestIDs = nil
        case 7: invalid.completeWindowInventory = nil
        default: invalid.completeWindowInventory = false
        }
        try writeSnapshot(invalid)
        try expect(BrowserProfileSnapshots.coverageSnapshots(base: base, requestID: "request-one", now: now).isEmpty,
            "Invalid discovery fixture \(kind) cannot become positive coverage")
    }
    try writeSnapshot(snapshot)
    let rawPartition = BrowserProfileSnapshots.partition(base, session: "a")
    var idle = snapshot
    idle.updatedAt = now.addingTimeInterval(0.05); idle.allTabs = nil; idle.tabs = []
    idle.snapshotRequestIDs = nil; idle.completeWindowInventory = nil
    try JSONEncoder().encode(idle).write(to: rawPartition)
    try expect(BrowserProfileSnapshots.coverageSnapshots(base: base, requestID: "request-one", now: now.addingTimeInterval(0.1)).count == 1
        && BrowserProfileSnapshots.isCoverageSnapshotCurrent(snapshot, base: base, now: now.addingTimeInterval(0.1)),
        "An ordinary empty/idle update cannot erase complete correlated proof or certify window absence")
    for kind in 0..<7 {
        var newer = snapshot; newer.updatedAt = now.addingTimeInterval(0.05)
        newer.completeWindowInventory = nil; newer.snapshotRequestIDs = nil
        switch kind {
        case 0: newer.allTabs?[0].title = "Changed active page"
        case 1: newer.allTabs?[0].windowFrame?.left = 400
        case 2: newer.allTabs?[0].windowID = 777
        case 3:
            var added = snapshot.allTabs![0]; added.id = 2; added.index = 1; added.active = false
            newer.allTabs?.append(added)
        case 4: newer.browserProcessIdentity = .init(pid: proof.pid, launched: proof.launched + 1)
        case 5: newer.guardEnabled = false
        default: newer.guardCapabilities = []
        }
        try JSONEncoder().encode(newer).write(to: rawPartition)
        let candidates = BrowserProfileSnapshots.coverageSnapshots(base: base, requestID: "request-one", now: now.addingTimeInterval(0.1))
        try expect((kind < 4 ? candidates.count == 1 : candidates.isEmpty)
            && !BrowserProfileSnapshots.isCoverageSnapshotCurrent(snapshot, base: base, now: now.addingTimeInterval(0.1)),
            "Newer positive raw contradiction \(kind) cannot be consumed; a correlated candidate may trigger a bounded requery")
    }
    var newerReply = snapshot; newerReply.updatedAt = now.addingTimeInterval(0.05)
    newerReply.snapshotRequestIDs = ["newer-request"]; newerReply.allTabs?[0].title = "Newer active page"
    try JSONEncoder().encode(newerReply).write(to: rawPartition)
    try JSONEncoder().encode(newerReply).write(to: BrowserProfileSnapshots.coveragePartition(base, session: "a"))
    try expect(!BrowserProfileSnapshots.isCoverageSnapshotCurrent(snapshot, base: base, now: now.addingTimeInterval(0.1))
        && BrowserProfileSnapshots.isCoverageSnapshotCurrent(newerReply, base: base, now: now.addingTimeInterval(0.1)),
        "Replacing a sidecar cannot silently replace the reply whose native postscan is being evaluated")
    try writeSnapshot(snapshot)
    try expect(BrowserProfileSnapshots.selectedCoverageWindows(snapshots: [snapshot], browser: browser,
        expectedSession: "a", selectedTabIDs: [1]) == [selected.identity], "Single profile selection resolves raw tab IDs")
    var profileB = snapshot; profileB.browserSessionID = "b"; profileB.allTabs?[0].windowID = 200
    let combined = [snapshot, profileB], nonce = BrowserProfileSnapshots.nonce(combined)!
    let compositeA = BrowserProfileSnapshots.compositeID(session: "a", id: 1)
    let compositeB = BrowserProfileSnapshots.compositeID(session: "b", id: 1)
    try expect(BrowserProfileSnapshots.selectedCoverageWindows(snapshots: combined, browser: browser, expectedSession: nonce,
        selectedTabIDs: [compositeA, compositeB]) == [selected.identity, report(200, "Allowed", profile: "b").identity],
        "Composite selected IDs stay profile scoped when native IDs collide")
    try expect(BrowserProfileSnapshots.selectedCoverageWindows(snapshots: [snapshot], browser: browser, expectedSession: nonce,
        selectedTabIDs: [compositeA]) == nil, "A missing profile cannot reinterpret a merged selection")
    try expect(BrowserProfileSnapshots.selectedCoverageWindows(snapshots: [], browser: browser, expectedSession: "a", selectedTabIDs: [1]) == nil,
        "Zero correlated replies cannot claim complete selected-window discovery")
    try expect(BrowserProfileSnapshots.selectedCoverageWindows(snapshots: [snapshot], browser: browser, expectedSession: "a", selectedTabIDs: [999]) == nil,
        "A vanished selected tab must be reselected, never substituted")

    try runCoverageEffectSpecs(window: b)

    var workerPending = BrowserWindowCoverageCohort(windows: [b], allowsLaterWindows: true)
    workerPending.beginPendingObservation(now: 10)
    workerPending.beginPendingObservation(now: 12)
    try expect(workerPending.expiredFailure(now: 12.9) == nil && workerPending.expiredFailure(now: 13)?.window == b.identity,
        "An in-flight inventory worker preserves the original three-second startup budget")

    var openEnded = BrowserWindowCoverageCohort(windows: [b], allowsLaterWindows: true)
    try expect(!openEnded.initialResolved && openEnded.targets.count == 1, "Initial unknown window stays pending before any effect")
    try expect(openEnded.observe(b.identity, outcome: .unresolved, now: 0) == nil, "Unconfirmed effect gets bounded grace")
    try expect(openEnded.observe(b.identity, outcome: .unresolved, now: 2.9) == nil, "Retry retains original failure clock")
    try expect(openEnded.observe(b.identity, outcome: .unresolved, now: 3)?.window == b.identity, "Silent AX failure stops after three seconds")
    _ = openEnded.observe(b.identity, outcome: .minimized, now: 3.1)
    try expect(openEnded.initialResolved && openEnded.targets.isEmpty, "Confirmed Add As You Go target allows later reopening")
    openEnded.enroll(omittedOtherSpace)
    try expect(openEnded.targets.isEmpty, "Add As You Go cannot widen its frozen initial cohort")
    var strict = BrowserWindowCoverageCohort(windows: [b], allowsLaterWindows: false)
    _ = strict.observe(b.identity, outcome: .minimized, now: 0)
    try expect(strict.initialResolved && strict.targets.count == 1, "Restrictive mode retains its exact native restriction after confirmation")
    _ = strict.observe(b.identity, outcome: .unresolved, now: 10)
    try expect(strict.observe(b.identity, outcome: .unresolved, now: 13) != nil, "A later failed re-hide gets a fresh bounded failure clock")
    _ = strict.observe(b.identity, outcome: .closed, now: 14)
    try expect(strict.targets.isEmpty && strict.initialResolved, "Positive native lifetime closure releases only that target")
    strict.enroll(omittedOtherSpace)
    try expect(strict.targets.count == 1, "Restrictive mode can enroll a later window after fresh discovery")
    let reused = native(14, "Reused", process: .init(pid: proof.pid, launched: proof.launched + 1))
    _ = strict.observe(reused.identity, outcome: .closed, now: 20)
    try expect(strict.targets.count == 1, "A different process lifetime cannot retire a previous target")
    print("Observed Chrome coverage / profile omission / AX-CG uniqueness / initial and restrictive cohort regressions passed")
}

private func runCoverageEffectSpecs(window: BrowserWindowCoveragePolicy.NativeWindow) throws {
    typealias Effects = BrowserWindowCoverageEffects
    var journal: [Effects.Ownership] = [], minimized: Bool? = false
    var current = true, saveSucceeds = false, dispatchCount = 0, saveCount = 0, readAfterDispatch: Bool? = nil
    let owner = Effects.Ownership(native: window.identity, intentionSessionID: "occurrence")
    func apply() -> BrowserWindowCoverageCohort.Outcome {
        Effects.minimize(isCurrent: { current }, readMinimized: { minimized }, saveOwnership: {
            saveCount += 1
            guard saveSucceeds else { return false }
            if journal.isEmpty { journal.append(owner) }
            return true
        }, dispatch: { dispatchCount += 1; minimized = readAfterDispatch })
    }
    guard case .unresolved = apply() else { throw SpecFailure(description: "Failed save cannot grant effect") }
    try expect(dispatchCount == 0 && journal.isEmpty, "Native save failure forbids minimize and retains pending coverage")
    saveSucceeds = true
    guard case .unresolved = apply() else { throw SpecFailure(description: "Unknown readback cannot verify startup") }
    try expect(dispatchCount == 1 && journal == [owner], "Uncertain readback retains exactly one durable native owner")
    minimized = false; readAfterDispatch = true
    guard case .minimized = apply() else { throw SpecFailure(description: "Exact minimized readback verifies the cohort") }
    try expect(dispatchCount == 2 && journal == [owner], "A retry reuses original ownership instead of duplicating it")
    let savesBefore = saveCount, dispatchBefore = dispatchCount
    _ = apply()
    try expect(saveCount == savesBefore && dispatchCount == dispatchBefore, "Already minimized does not create ownership or effects")
    var preowned = false
    _ = Effects.minimize(isCurrent: { true }, readMinimized: { true }, saveOwnership: { preowned = true; return true }, dispatch: {})
    try expect(!preowned, "A user-minimized window is never owned")
    minimized = false
    var stoppedDispatch = false
    guard case .unresolved = Effects.minimize(isCurrent: { current }, readMinimized: { minimized }, saveOwnership: {
        current = false; return true
    }, dispatch: { stoppedDispatch = true }) else { throw SpecFailure(description: "Finish must fence pending effect") }
    try expect(!stoppedDispatch, "Finish between durable preparation and AX dispatch prevents the side effect")
    current = true
    func transfer(identity: BrowserWindowCoveragePolicy.NativeIdentity, occurrence: String = "occurrence", save: Bool = true) -> Bool {
        Effects.transfer(journal[0], native: identity, intentionSessionID: occurrence, browserSessionID: "profile-b", browserWindowID: 99,
            isCurrent: { current }, persist: { replacement in
                guard save else { return false }; journal[0] = replacement; return true
            })
    }
    try expect(!transfer(identity: window.identity, save: false) && journal == [owner], "Failed ownership-transfer persistence preserves original native record")
    try expect(!transfer(identity: window.identity, occurrence: "next") && journal == [owner], "A new intention cannot adopt historical ownership")
    var reused = window.identity; reused.launched += 1
    try expect(!transfer(identity: reused) && journal == [owner], "Reused PID/window with a different process lifetime cannot adopt ownership")
    try expect(transfer(identity: window.identity) && journal.count == 1 && journal[0].browserSessionID == "profile-b"
        && journal[0].browserWindowID == 99 && !journal[0].isNativeCoverage,
        "A late exact browser claim transfers the same record once")
    try expect(!transfer(identity: window.identity), "A transferred owner cannot be adopted a second time")
    var restoreEffects = 0
    minimized = true
    let newerSession = Effects.restore(ownershipSessionID: journal[0].intentionSessionID, activeSessionID: "next",
        readMinimized: { minimized }, dispatch: { restoreEffects += 1; minimized = false })
    try expect(!newerSession && restoreEffects == 0 && journal.count == 1,
        "Old native or transferred ownership cannot reveal a window under a newer active intention")
    let uncertain = Effects.restore(readMinimized: { minimized }, dispatch: { restoreEffects += 1; minimized = nil })
    try expect(!uncertain && journal.count == 1, "Failed restoration readback cannot discard ownership")
    // A fulfilled native unminimize with unknown readback is retained; when the
    // next read proves it completed, retirement needs no second effect.
    minimized = false
    if Effects.restore(readMinimized: { minimized }, dispatch: { restoreEffects += 1 }) { journal.removeAll() }
    try expect(journal.isEmpty && restoreEffects == 1, "Transferred ownership restores once and retires only after native confirmation")
}

private func runCoverageAnchorSpecs() throws {
    typealias Policy = BrowserWindowCoveragePolicy
    let browser = "com.google.Chrome", process = BrowserProcessIdentity(pid: 41, launched: 90)
    let frame = CGRect(x: 20, y: 30, width: 1000, height: 700)
    func native(_ id: UInt32, title: String = "New Tab") -> Policy.NativeWindow {
        .init(identity: .init(bundleIdentifier: browser, pid: process.pid, launched: process.launched, windowID: id), title: title, frame: frame)
    }
    func standard(_ title: String = "New Tab") -> Policy.StandardWindow {
        .init(bundleIdentifier: browser, processIdentity: process, title: title, frame: frame)
    }
    func report(_ id: Int, profile: String = "a", title: String = "New Tab") -> Policy.ReportedWindow {
        .init(identity: .init(bundleIdentifier: browser, browserSessionID: profile, windowID: id), processIdentity: process, title: title, frame: frame)
    }
    let selected = native(9047, title: "Study"), old = native(6782), new = native(15672)
    let twins = [old, new], rows = [standard(), standard()]
    try expect(Policy.standardIdentityBindings(native: twins, standard: rows) == nil, "Regression: cold equal-title/frame windows remain unresolved")
    let anchors = Policy.continuingAnchors(native: twins, standard: rows, previous: [old.identity: "old-AX"], current: ["new-AX", "old-AX"], equal: ==)
    try expect(anchors == [1: old.identity], "Only the exact equal AX object continues its original native binding")
    try expect(Policy.standardIdentityBindings(native: twins, standard: rows, anchors: anchors ?? [:]) == [new.identity, old.identity],
        "Previously bound minimized6782 allows newly created15672 to resolve by unique residual matching")
    try expect(Policy.continuingAnchors(native: twins, standard: rows, previous: [old.identity: "old-AX"], current: ["old-AX", "old-AX"], equal: ==) == nil,
        "Duplicate-equal AX rows never become separate windows")
    try expect(Policy.continuingAnchors(native: twins, standard: rows, previous: [old.identity: "same", new.identity: "same"], current: ["same", "new"], equal: ==) == nil,
        "Conflicting old native anchors cannot claim the same current AX object")
    let absent = Policy.continuingAnchors(native: twins, standard: [standard()], previous: [old.identity: "closed-AX"], current: ["new-AX"], equal: ==)
    try expect(absent?.isEmpty == true && Policy.standardIdentityBindings(native: twins, standard: [standard()], anchors: absent ?? [:]) == nil,
        "Lingering CG with absent old AX loses its anchor; ambiguity still cannot be bypassed")
    let closedNative = Policy.continuingAnchors(native: [new], standard: [standard()], previous: [old.identity: "old-AX"], current: ["new-AX"], equal: ==)
    try expect(closedNative?.isEmpty == true, "Missing native lifetime cannot retain prior anchor proof")
    try expect(Policy.continuingAnchors(native: [selected, old], standard: [standard("Study"), standard()], previous: [old.identity: "study-AX"],
        current: ["study-AX", "old-AX"], equal: ==) == nil, "An equal token with incompatible current title/frame is not a valid anchor")
    var reused = old.identity; reused.launched += 1
    let reusedAnchors = Policy.continuingAnchors(native: twins, standard: rows, previous: [reused: "old-AX"], current: ["new-AX", "old-AX"], equal: ==)
    try expect(reusedAnchors?.isEmpty == true, "Process lifetime changes invalidate all old anchor authority")

    let selectedReport = report(1, title: "Study")
    guard case .complete(let initial) = Policy.evaluate(browserBundleIdentifier: browser, native: [selected, old],
        observedStandard: [selected.identity, old.identity], reported: [selectedReport], requiredSelected: [selectedReport.identity], knownProfiles: ["a"],
        continuousIdentities: [selected.identity, old.identity], witnessedBeforeSnapshot: [selected.identity, old.identity]) else {
        throw SpecFailure(description: "Complete bracketed initial receipt should establish scoped exclusion")
    }
    try expect(initial.profileExclusions[old.identity] == ["a"], "Already observed old window earns exclusion only from a complete bracketed profile receipt")
    let newReport = report(2), bothObserved: Set<Policy.NativeIdentity> = [selected.identity, old.identity, new.identity]
    guard case .complete(let resolved) = Policy.evaluate(browserBundleIdentifier: browser, native: [selected, old, new], observedStandard: bothObserved,
        reported: [selectedReport, newReport], knownProfiles: ["a"], priorCoverage: initial,
        continuousIdentities: bothObserved, witnessedBeforeSnapshot: bothObserved) else {
        throw SpecFailure(description: "Historical profile exclusion must resolve the new reported twin")
    }
    try expect(resolved.matches[newReport.identity] == new.identity && resolved.unreported == [old],
        "Reported twin maps to new15672 while old6782 retains its native-only ownership")
    for (prior, continuous, profile) in [(Optional<Policy.Coverage>.none, bothObserved, "a"), (initial, Set<Policy.NativeIdentity>(), "a"), (initial, bothObserved, "new-profile")] {
        guard case .incomplete = Policy.evaluate(browserBundleIdentifier: browser, native: [selected, old, new], observedStandard: bothObserved,
            reported: [selectedReport, report(2, profile: profile)], knownProfiles: ["a", profile], priorCoverage: prior,
            continuousIdentities: continuous, witnessedBeforeSnapshot: bothObserved) else {
            throw SpecFailure(description: "Cold/new session/new profile cannot borrow another profile's missing-window proof")
        }
    }
    guard case .complete(let noWitness) = Policy.evaluate(browserBundleIdentifier: browser, native: [selected, old],
        observedStandard: [selected.identity, old.identity], reported: [selectedReport], knownProfiles: ["a"],
        continuousIdentities: [selected.identity, old.identity], witnessedBeforeSnapshot: [selected.identity]) else { throw SpecFailure(description: "No witness setup") }
    try expect(noWitness.profileExclusions[old.identity] == nil, "A window born after the pre-query observation cannot earn absence proof")
    guard case .incomplete = Policy.evaluate(browserBundleIdentifier: browser, native: [selected, new], observedStandard: [selected.identity, new.identity],
        reported: [selectedReport, newReport], knownProfiles: ["a"], priorCoverage: resolved,
        continuousIdentities: [selected.identity], witnessedBeforeSnapshot: [selected.identity]) else {
        throw SpecFailure(description: "Losing a proven reported window anchor cannot silently rebind its ID to a replacement")
    }
    let replacement = native(20000, title: "Study")
    guard case .incomplete(.ambiguousIdentity) = Policy.evaluate(browserBundleIdentifier: browser, native: [replacement],
        observedStandard: [replacement.identity], reported: [selectedReport], knownProfiles: ["a"],
        continuousIdentities: [], witnessedBeforeSnapshot: [selected.identity]) else {
        throw SpecFailure(description: "R closing after receipt and M opening before final scan must not bind old report R to replacement M")
    }
    try expect(Policy.needsDiscovery(native: [], reported: [report(5, profile: "late-profile").identity])
        && !Policy.needsDiscovery(native: [], reported: []),
        "A late reporting profile triggers discovery even when its native window was already in the known cohort")
    let lostAnchor = resolved.retainingContinuous([selected.identity])
    try expect(!Policy.permitsReportedCandidate(newReport.identity, candidate: old.identity, coverage: lostAnchor)
        && !Policy.permitsReportedCandidate(newReport.identity, candidate: old.identity, coverage: resolved)
        && !Policy.permitsReportedCandidate(report(99).identity, candidate: old.identity, coverage: initial)
        && Policy.permitsReportedCandidate(newReport.identity, candidate: new.identity, coverage: resolved),
        "Native normal-window fallback cannot override invalidated, already-bound, or profile-excluded identity")
    try expect(!Policy.isPostReceiptObservation(receiptAt: 12, sampledAt: 11, now: 12.1, deadline: 13)
        && !Policy.isPostReceiptObservation(receiptAt: 12, sampledAt: 12, now: 12.1, deadline: 13)
        && Policy.isPostReceiptObservation(receiptAt: 12, sampledAt: 12.01, now: 12.1, deadline: 13)
        && !Policy.isPostReceiptObservation(receiptAt: 12, sampledAt: 12.01, now: 13, deadline: 13),
        "Only a native CG sample begun after the latched receipt and before deadline can complete discovery")
    print("Coverage anchor identity / temporal receipt / profile exclusion regressions passed")
}
