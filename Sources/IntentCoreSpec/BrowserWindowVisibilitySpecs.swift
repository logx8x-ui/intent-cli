import Foundation
import Darwin
import IntentCore

func runBrowserWindowVisibilitySpecs() throws {
    let browser = "org.mozilla.firefox"
    let frame = BrowserWindowFrame(left: -900, top: 45, width: 800, height: 700)
    let window = BrowserWindowVisibilityWindow(windowID: 7, title: "Work", frame: frame, state: "normal")
    let plan = BrowserWindowVisibilityPlan(intentionSessionID: "intention-one", revision: 2, windows: [window])
    try expect(plan.isValid, "A whole-window plan accepts valid offscreen/secondary-display coordinates")
    let decoded = try JSONDecoder().decode(BrowserWindowVisibilityPlan.self, from: JSONEncoder().encode(plan))
    try expect(decoded == plan, "Visibility plans round-trip without converting browser IDs to native IDs")

    var badWindow = window
    for state in ["", "unknown"] {
        badWindow.state = state
        try expect(!badWindow.isValid, "Unknown browser window state is rejected")
    }
    badWindow = window; badWindow.windowID = -1
    try expect(!badWindow.isValid, "Negative browser IDs cannot request native ownership")
    badWindow.windowID = 9_007_199_254_740_992
    try expect(!badWindow.isValid, "Wire IDs cannot exceed JavaScript's exact integer range")
    badWindow = window; badWindow.title = " \n"
    try expect(!badWindow.isValid, "Blank titles do not establish native identity")
    badWindow.title = String(repeating: "x", count: 4097)
    try expect(!badWindow.isValid, "Oversized titles are rejected")
    for invalidFrame in [
        BrowserWindowFrame(left: .infinity, top: 0, width: 100, height: 100),
        BrowserWindowFrame(left: 0, top: .nan, width: 100, height: 100),
        BrowserWindowFrame(left: 100_001, top: 0, width: 100, height: 100),
        BrowserWindowFrame(left: 0, top: -100_001, width: 100, height: 100),
        BrowserWindowFrame(left: 0, top: 0, width: 0, height: 100),
        BrowserWindowFrame(left: 0, top: 0, width: -100, height: 100),
        BrowserWindowFrame(left: 0, top: 0, width: 100, height: .infinity),
        BrowserWindowFrame(left: 0, top: 0, width: 100_001, height: 100)
    ] {
        badWindow = window; badWindow.frame = invalidFrame
        try expect(!badWindow.isValid, "Nonfinite, empty, negative and out-of-range bounds are rejected")
    }
    var badPlan = plan; badPlan.windows = [window, window]
    try expect(!badPlan.isValid, "A profile plan cannot repeat a browser window ID")
    badPlan = plan; badPlan.revision = -1
    try expect(!badPlan.isValid, "Negative revisions cannot reset ordering")
    badPlan.revision = 9_007_199_254_740_992
    try expect(!badPlan.isValid, "Wire revisions must survive a JavaScript round-trip exactly")
    for session in ["", " \n", String(repeating: "s", count: 257)] {
        badPlan = plan; badPlan.intentionSessionID = session
        try expect(!badPlan.isValid, "Intention identity must be nonempty and bounded")
    }
    badPlan = plan; badPlan.windows = (0..<257).map { id in
        .init(windowID: id, title: "Work", frame: frame, state: "normal")
    }
    try expect(!badPlan.isValid, "A plan cannot trigger an unbounded native scan")
    var parking = window; parking.windowID = 80; parking.title = "Intent holding window"; parking.frame.left = 100
    var parkedPlan = plan; parkedPlan.parkingWindows = [parking]
    try expect(parkedPlan.isValid, "A plan distinguishes native-managed user and extension-owned parking windows")
    badPlan = parkedPlan; badPlan.parkingWindows.append(parking)
    try expect(!badPlan.isValid, "Parking IDs are unique within a plan")
    badPlan = plan; badPlan.parkingWindows = [window]
    try expect(!badPlan.isValid, "A user window cannot also be claimed as a parking window")
    badPlan = parkedPlan; badPlan.revealWindowIDs = [7]
    try expect(!badPlan.isValid, "Only registered parking windows can be explicitly revealed")
    badPlan.revealWindowIDs = [80, 80]
    try expect(!badPlan.isValid, "Reveal IDs cannot repeat")
    badPlan.revealWindowIDs = [80]
    try expect(badPlan.isValid, "A reveal targets only its registered parking ID")
    var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
    legacyObject.removeValue(forKey: "parkingWindows"); legacyObject.removeValue(forKey: "revealWindowIDs")
    let legacyDecoded = try JSONDecoder().decode(BrowserWindowVisibilityPlan.self,
        from: JSONSerialization.data(withJSONObject: legacyObject))
    try expect(legacyDecoded.parkingWindows.isEmpty && legacyDecoded.revealWindowIDs.isEmpty,
        "Omitted optional parking metadata decodes as empty")

    typealias Matcher = BrowserWindowVisibilityMatching
    let native = Matcher.NativeCandidate(id: 12687, pid: 31075, bundle: browser,
        title: "Work — Mozilla Firefox", frame: frame.rect)
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [native]) == native,
        "Strict title and geometry matching accepts an offscreen candidate without assuming browser ID equals native ID")
    var shifted = native; shifted.frame.origin.x += 4
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [shifted]) == nil,
        "Even one uniquely titled window must match geometry")
    shifted = native; shifted.frame.origin.y += 3; shifted.frame.size.width += 3
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [shifted]) == shifted,
        "Bounds tolerate at most three points of API rounding")
    shifted = native; shifted.title = "Other page"
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [shifted]) == nil,
        "Geometry alone cannot borrow another profile's window")
    shifted = native; shifted.bundle = "com.google.Chrome"
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [shifted]) == nil,
        "A different browser cannot satisfy an otherwise identical window")
    shifted = native; shifted.id += 1
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [native, shifted]) == nil,
        "Identical overlapping native windows are ambiguous")
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [native, native]) == nil,
        "Duplicate native inventory records fail closed")
    shifted = native; shifted.pid = 0
    try expect(Matcher.match(window: window, browserBundleIdentifier: browser, candidates: [shifted]) == nil,
        "An unidentified process cannot receive visibility changes")

    let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let first = BrowserWindowVisibilityRecord(browserBundleIdentifier: browser, browserSessionID: "profile-a",
        receivedAt: timestamp, plan: plan)
    var second = first; second.browserSessionID = "profile-b"
    try expect(Matcher.matches(records: [first, second], candidates: [native]).isEmpty,
        "Two profile claims cannot acquire the same native window")
    var otherWindow = window; otherWindow.title = "Other"; otherWindow.frame.left = 100
    second.plan.windows = [otherWindow]
    let otherNative = Matcher.NativeCandidate(id: 11783, pid: 31076, bundle: browser,
        title: "Other - Mozilla Firefox", frame: otherWindow.frame.rect)
    let matches = Matcher.matches(records: [first, second], candidates: [native, otherNative])
    try expect(matches.count == 2 && matches.map(\.window.windowID) == [7, 7]
        && Set(matches.map(\.record.browserSessionID)) == ["profile-a", "profile-b"],
        "The same browser ID in two profiles maps independently to exact native candidates")
    var duplicateClaim = first; otherWindow = window; otherWindow.windowID = 8
    duplicateClaim.plan.windows.append(otherWindow)
    try expect(Matcher.matches(records: [duplicateClaim], candidates: [native]).isEmpty,
        "Two browser windows in one profile cannot claim the same native window")
    var parkedRecord = BrowserWindowVisibilityRecord(browserBundleIdentifier: browser, browserSessionID: "profile-a", plan: parkedPlan)
    let parkingNative = Matcher.NativeCandidate(id: 12800, pid: 31075, bundle: browser,
        title: "Intent holding window", frame: parking.frame.rect)
    let parkingMatches = Matcher.matches(records: [parkedRecord], candidates: [native, parkingNative])
    try expect(parkingMatches.count == 2 && parkingMatches.filter(\.isParking).map(\.window.windowID) == [80],
        "Native matching identifies parking windows without treating them as normal restore targets")
    var closedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parkedRecord)) as! [String: Any]
    closedObject["closedParkingWindowIDs"] = [parking.windowID]
    let closedRecord = try JSONDecoder().decode(BrowserWindowVisibilityRecord.self,
        from: JSONSerialization.data(withJSONObject: closedObject))
    let closedRoundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closedRecord)) as! [String: Any]
    try expect(closedRoundTrip["closedParkingWindowIDs"] as? [Int] == [parking.windowID],
        "A confirmed closed holder must survive native record decoding and re-encoding")
    try expect(Matcher.matches(records: [closedRecord], candidates: [native, parkingNative]).map(\.window.windowID) == [window.windowID],
        "Closed parking cannot rebind its old native CG window even if WindowServer still reports it")
    parkedRecord.plan.parkingWindows[0].title = window.title; parkedRecord.plan.parkingWindows[0].frame = window.frame
    try expect(Matcher.matches(records: [parkedRecord], candidates: [native]).isEmpty,
        "A parking and user-window claim cannot both own the same native window")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-window-visibility-spec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserWindowVisibilityStore(directory: directory)
    try expect(BrowserWindowVisibilityStore().directory == ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent(),
        "Default visibility storage follows the isolated QA rules directory")
    let file = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "profile-a", intentionSessionID: plan.intentionSessionID)
    try expect(file.lastPathComponent.hasPrefix("browser-window-visibility-org-mozilla-firefox.profile-"),
        "Visibility ownership uses the existing hashed profile partition convention")
    let written = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID, receivedAt: timestamp)
    try expect(written == .written && store.records(browserBundleIdentifier: browser) == [first],
        "A validated current plan is persisted with host-supplied profile identity and reception time")
    let originalData = try Data(contentsOf: file)
    let unchanged = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID, receivedAt: timestamp.addingTimeInterval(10))
    let unchangedData = try Data(contentsOf: file)
    try expect(unchanged == .unchanged && unchangedData == originalData,
        "Duplicate delivery neither rewrites ownership nor refreshes receipt age")
    var older = plan; older.revision -= 1
    let staleResult = try store.accept(older, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID)
    try expect(staleResult == .rejected, "An older revision cannot replace the current plan")
    var changed = plan; changed.windows = []
    let reusedResult = try store.accept(changed, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID)
    try expect(reusedResult == .rejected, "A reused revision with different content is rejected")
    changed.revision += 1
    let newerResult = try store.accept(changed, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID)
    try expect(newerResult == .written && store.records(browserBundleIdentifier: browser).first?.plan.windows.isEmpty == true,
        "A newer empty plan clears desired minimization without erasing native recovery ownership")
    let secondResult = try store.accept(second.plan, browserBundleIdentifier: browser, browserSessionID: "profile-b",
        currentIntentionSessionID: plan.intentionSessionID, receivedAt: timestamp)
    try expect(secondResult == .written && store.records(browserBundleIdentifier: browser).count == 2,
        "The second profile has independent revision ordering and storage")
    var replacement = plan; replacement.intentionSessionID = "intention-two"; replacement.revision = 0
    let wrongSession = try store.accept(replacement, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: plan.intentionSessionID)
    let noSession = try store.accept(replacement, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: nil)
    try expect(wrongSession == .rejected && noSession == .rejected,
        "A request cannot nominate a new intention unless current rules authorize it")
    let nextSession = try store.accept(replacement, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: replacement.intentionSessionID)
    try expect(nextSession == .written && store.records(browserBundleIdentifier: browser).count == 3,
        "A caller-verified new intention gets independent storage without erasing old recovery plans")
    let oldSession = try store.accept(plan, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: replacement.intentionSessionID)
    try expect(oldSession == .rejected, "A late old intention cannot overwrite its replacement")
    badPlan = replacement; badPlan.windows = [badWindow]
    let invalid = try store.accept(badPlan, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: replacement.intentionSessionID)
    let invalidProfile = try store.accept(replacement, browserBundleIdentifier: browser, browserSessionID: "",
        currentIntentionSessionID: replacement.intentionSessionID)
    let invalidBundle = try store.accept(replacement, browserBundleIdentifier: "../escape", browserSessionID: "profile-a",
        currentIntentionSessionID: replacement.intentionSessionID)
    try expect(invalid == .rejected && invalidProfile == .rejected && invalidBundle == .rejected,
        "Invalid payloads or envelope identities never write a visibility request")
    let forgedFile = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "profile-forged", intentionSessionID: plan.intentionSessionID)
    try JSONEncoder().encode(first).write(to: forgedFile)
    try expect(store.records(browserBundleIdentifier: browser).count == 3,
        "A record in the wrong profile partition is not trusted")

    parkedPlan.intentionSessionID = "parking-intention"
    let unregisteredReveal = try store.acceptReveal(parkedPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    try expect(unregisteredReveal == .rejected, "An inactive reveal cannot establish new ownership")
    _ = try store.accept(parkedPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        currentIntentionSessionID: parkedPlan.intentionSessionID, receivedAt: timestamp)
    var reveal = parkedPlan; reveal.revision += 1; reveal.revealWindowIDs = [parking.windowID]
    let revealResult = try store.acceptReveal(reveal, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    try expect(revealResult == .written, "Completion may reveal only a previously registered parking window")
    let repeatReveal = try store.acceptReveal(reveal, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    try expect(repeatReveal == .unchanged, "A lost completion ACK may be retried without changing durable ownership")
    let staleReveal = try store.acceptReveal(parkedPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    try expect(staleReveal == .rejected, "A stale reveal revision cannot retract a newer accepted request")
    var mutated = reveal; mutated.revision += 1; mutated.windows[0].title = "A different window"
    let mutatedUserWindow = try store.acceptReveal(mutated, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    mutated = reveal; mutated.revision += 1; mutated.parkingWindows[0].frame.left += 10
    let mutatedParkingWindow = try store.acceptReveal(mutated, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    mutated = reveal; mutated.revision += 1
    var newParking = parking; newParking.windowID += 1; mutated.parkingWindows.append(newParking)
    let addedParkingWindow = try store.acceptReveal(mutated, browserBundleIdentifier: browser, browserSessionID: "parking-profile")
    try expect(mutatedUserWindow == .rejected && mutatedParkingWindow == .rejected && addedParkingWindow == .rejected,
        "Post-completion requests cannot change user-window metadata, mutate parking identity or register a new window")
    let capture = BrowserWindowVisibilityCaptureReceipt(browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        intentionSessionID: reveal.intentionSessionID, windowIDs: [parking.windowID])
    let captured = try store.writeCaptureReceipt(capture)
    try expect(captured && store.capturedWindowIDs(browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        intentionSessionID: reveal.intentionSessionID) == [parking.windowID],
        "Native identity capture receipt is scoped to the exact registered profile and intention")
    let captureFile = store.captureReceiptFileURL(browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        intentionSessionID: reveal.intentionSessionID)
    let captureDate = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes([.modificationDate: captureDate], ofItemAtPath: captureFile.path)
    let repeatedCapture = try store.writeCaptureReceipt(capture)
    let afterCapture = try FileManager.default.attributesOfItem(atPath: captureFile.path)[.modificationDate] as? Date
    try expect(repeatedCapture && afterCapture == captureDate,
        "Repeated native capture ACKs do not rewrite the file or trigger a directory-watcher/battery loop")
    var badCapture = capture; badCapture.windowIDs = [999]
    let unknownCapture = try store.writeCaptureReceipt(badCapture)
    badCapture = capture; badCapture.browserSessionID = "unregistered-profile"
    let wrongProfileCapture = try store.writeCaptureReceipt(badCapture)
    badCapture = capture; badCapture.intentionSessionID = "unregistered-intention"
    let wrongIntentionCapture = try store.writeCaptureReceipt(badCapture)
    try expect(!unknownCapture && !wrongProfileCapture && !wrongIntentionCapture,
        "Capture receipts cannot acknowledge unregistered windows, another profile or another intention")
    badCapture = capture; badCapture.browserSessionID = "other-profile"
    try JSONEncoder().encode(badCapture).write(to: captureFile, options: .atomic)
    try expect(store.capturedWindowIDs(browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        intentionSessionID: reveal.intentionSessionID).isEmpty,
        "A receipt copied from another profile cannot satisfy the identity barrier")
    _ = try store.writeCaptureReceipt(capture)
    var retitledParkingPlan = reveal; retitledParkingPlan.revision += 1
    retitledParkingPlan.parkingWindows[0].title = "User tab now in holding window"
    _ = try store.accept(retitledParkingPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        currentIntentionSessionID: reveal.intentionSessionID)
    var omittedParkingPlan = retitledParkingPlan; omittedParkingPlan.revision += 1
    omittedParkingPlan.parkingWindows = []; omittedParkingPlan.revealWindowIDs = []
    _ = try store.accept(omittedParkingPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        currentIntentionSessionID: reveal.intentionSessionID)
    let stickyRecord = store.records(browserBundleIdentifier: browser).first {
        $0.browserSessionID == "parking-profile" && $0.plan.intentionSessionID == reveal.intentionSessionID
    }
    try expect(stickyRecord?.plan == omittedParkingPlan && stickyRecord?.registeredParkingWindows == [parking]
        && stickyRecord?.requestedRevealWindowIDs == [parking.windowID],
        "Later plans preserve the first parking descriptor and accepted reveal while keeping the exact latest wire plan")
    try expect(stickyRecord.map { store.capturedWindowIDs(for: $0) } == [parking.windowID],
        "Omitting current desired parking metadata cannot discard a durable native identity capture")
    var nextPlan = plan; nextPlan.intentionSessionID = "next-intention"; nextPlan.revision = 0
    _ = try store.accept(nextPlan, browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        currentIntentionSessionID: nextPlan.intentionSessionID)
    let olderRevealRecord = store.records(browserBundleIdentifier: browser).first {
        $0.browserSessionID == "parking-profile" && $0.plan.intentionSessionID == reveal.intentionSessionID
    }
    try expect(olderRevealRecord?.requestedRevealWindowIDs == reveal.revealWindowIDs,
        "Starting another intention cannot overwrite an accepted orphan reveal before native recovery reads it")
    var oversizedHistory = first
    oversizedHistory.registeredParkingWindows = (0..<1025).map { id in
        .init(windowID: id, title: "Holder", frame: frame, state: "minimized")
    }
    try expect(!oversizedHistory.isValid, "Durable parking history is bounded even across many desired-plan updates")
    let separatorA = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "a\nb", intentionSessionID: "c")
    let separatorB = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "a", intentionSessionID: "b\nc")
    try expect(separatorA != separatorB, "Composite storage identity cannot collide through embedded separators")

    let process = BrowserProcessIdentity(pid: 31075, launched: timestamp.timeIntervalSinceReferenceDate - 100)
    let restarted = BrowserProcessIdentity(pid: 32000, launched: timestamp.timeIntervalSinceReferenceDate + 100)
    let recycled = BrowserProcessIdentity(pid: process.pid, launched: restarted.launched)
    try expect(process.isValid && !BrowserProcessIdentity(pid: 0, launched: 1).isValid
        && !BrowserProcessIdentity(pid: -1, launched: 1).isValid
        && !BrowserProcessIdentity(pid: 1, launched: .nan).isValid
        && !BrowserProcessIdentity(pid: 1, launched: .infinity).isValid,
        "Process lifetime proofs require a positive PID and finite Foundation launch timestamp")
    var proofRecord = BrowserWindowVisibilityRecord(browserBundleIdentifier: browser, browserSessionID: "proof-profile",
        receivedAt: timestamp, plan: plan, browserProcessIdentity: process)
    try expect(proofRecord.isValid, "A process existing before the host receipt can be recorded")
    proofRecord.browserProcessIdentity = restarted
    try expect(!proofRecord.isValid, "A record cannot claim a process launched after that record was received")
    var backwardObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
    backwardObject.removeValue(forKey: "browserProcessIdentity")
    let backwardRecord = try JSONDecoder().decode(BrowserWindowVisibilityRecord.self,
        from: JSONSerialization.data(withJSONObject: backwardObject))
    try expect(backwardRecord.isValid && backwardRecord.browserProcessIdentity == nil,
        "Older records remain readable without fabricating process proof")

    var processPlan = plan; processPlan.intentionSessionID = "proof-intention"
    let proofAccepted = try store.accept(processPlan, browserBundleIdentifier: browser, browserSessionID: "proof-profile",
        currentIntentionSessionID: processPlan.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    try expect(proofAccepted == .written, "The host can attach verified process proof to a new occurrence")
    processPlan.revision += 1; processPlan.windows = []
    let omittedProof = try store.accept(processPlan, browserBundleIdentifier: browser, browserSessionID: "proof-profile",
        currentIntentionSessionID: processPlan.intentionSessionID, receivedAt: timestamp)
    let persistedProof = store.records(browserBundleIdentifier: browser).first { $0.browserSessionID == "proof-profile" }
    try expect(omittedProof == .written && persistedProof?.browserProcessIdentity == process,
        "Omitting proof on a later delivery preserves the first durable native process identity")
    var changedProcessPlan = processPlan; changedProcessPlan.revision += 1
    let changedProof = try store.accept(changedProcessPlan, browserBundleIdentifier: browser, browserSessionID: "proof-profile",
        currentIntentionSessionID: processPlan.intentionSessionID, receivedAt: timestamp.addingTimeInterval(200),
        browserProcessIdentity: restarted)
    try expect(changedProof == .rejected, "A later host cannot overwrite an occurrence's established process proof")
    var legacyUpgrade = replacement; legacyUpgrade.revision += 1
    let upgradedProof = try store.accept(legacyUpgrade, browserBundleIdentifier: browser, browserSessionID: "profile-a",
        currentIntentionSessionID: replacement.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    try expect(upgradedProof == .rejected, "Legacy proofless records cannot be retrofitted with an unproven lifetime")
    let revealKeepsProof = try store.acceptReveal(changedProcessPlan, browserBundleIdentifier: browser,
        browserSessionID: "proof-profile", receivedAt: timestamp)
    try expect(revealKeepsProof == .written && store.records(browserBundleIdentifier: browser).first {
        $0.browserSessionID == "proof-profile"
    }?.browserProcessIdentity == process, "Frozen completion delivery retains process proof without changing it")

    var registeredRecoveryPlan = plan
    registeredRecoveryPlan.intentionSessionID = "extension-update-recovery"
    registeredRecoveryPlan.parkingWindows = [parking]
    _ = try store.accept(registeredRecoveryPlan, browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
        currentIntentionSessionID: registeredRecoveryPlan.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    let recoverRegistered: ([Int], BrowserProcessIdentity) throws -> BrowserWindowVisibilityStore.Acceptance = { ids, proof in
        try store.requestRegisteredRecovery(browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
            intentionSessionID: registeredRecoveryPlan.intentionSessionID, browserProcessIdentity: proof,
            windowIDs: ids, receivedAt: timestamp.addingTimeInterval(20))
    }
    let uncapturedRecovery = try recoverRegistered([parking.windowID], process)
    try expect(uncapturedRecovery == .rejected, "Recovery cannot reveal a registered holder before durable native identity capture")
    _ = try store.writeCaptureReceipt(.init(browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
        intentionSessionID: registeredRecoveryPlan.intentionSessionID, windowIDs: [parking.windowID]))
    registeredRecoveryPlan.revision += 1; registeredRecoveryPlan.parkingWindows = []
    _ = try store.accept(registeredRecoveryPlan, browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
        currentIntentionSessionID: registeredRecoveryPlan.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    let wrongRecoveryProof = try recoverRegistered([parking.windowID], .init(pid: process.pid + 1, launched: process.launched))
    let unknownRecoveryWindow = try recoverRegistered([999], process)
    let partlyUnknownRecovery = try recoverRegistered([parking.windowID, 999], process)
    let duplicateRecoveryWindow = try recoverRegistered([parking.windowID, parking.windowID], process)
    let emptyRecovery = try recoverRegistered([], process)
    let oversizedRecovery = try recoverRegistered(Array(0..<257), process)
    let invalidRecoveryWindow = try recoverRegistered([-1], process)
    let unsafeRecoveryWindow = try recoverRegistered([9_007_199_254_740_992], process)
    try expect([wrongRecoveryProof, unknownRecoveryWindow, partlyUnknownRecovery, duplicateRecoveryWindow,
                emptyRecovery, oversizedRecovery, invalidRecoveryWindow, unsafeRecoveryWindow].allSatisfy { $0 == .rejected },
        "Native registered recovery rejects mismatched proof and unknown, repeated, empty or oversized ID requests")
    let missingRecoveryProof = try store.requestRegisteredRecovery(browserBundleIdentifier: browser, browserSessionID: "parking-profile",
        intentionSessionID: reveal.intentionSessionID, browserProcessIdentity: process, windowIDs: [parking.windowID], receivedAt: timestamp)
    try expect(missingRecoveryProof == .rejected, "A legacy record without native process proof cannot gain same-process recovery authority")
    let recoveredRegistration = try recoverRegistered([parking.windowID], process)
    let registeredRecoveryRecord = store.records(browserBundleIdentifier: browser).first {
        $0.browserSessionID == "old-extension-profile"
    }
    try expect(recoveredRegistration == .written && registeredRecoveryRecord?.plan == registeredRecoveryPlan
        && registeredRecoveryRecord?.registeredParkingWindows == [parking]
        && registeredRecoveryRecord?.requestedRevealWindowIDs == [parking.windowID],
        "Session-storage-loss recovery uses captured historical parking without changing the desired plan or revision")
    let recoveryFile = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
        intentionSessionID: registeredRecoveryPlan.intentionSessionID)
    let recoveryFileDate = Date(timeIntervalSince1970: 2_000)
    try FileManager.default.setAttributes([.modificationDate: recoveryFileDate], ofItemAtPath: recoveryFile.path)
    let repeatedRegisteredRecovery = try recoverRegistered([parking.windowID], process)
    let afterRecoveryDate = try FileManager.default.attributesOfItem(atPath: recoveryFile.path)[.modificationDate] as? Date
    try expect(repeatedRegisteredRecovery == .unchanged && afterRecoveryDate == recoveryFileDate,
        "Duplicate native recovery receipts are idempotent without revision churn or file-watcher wakeups")
    registeredRecoveryPlan.revision += 1; registeredRecoveryPlan.windows = []
    _ = try store.accept(registeredRecoveryPlan, browserBundleIdentifier: browser, browserSessionID: "old-extension-profile",
        currentIntentionSessionID: registeredRecoveryPlan.intentionSessionID, receivedAt: timestamp.addingTimeInterval(30),
        browserProcessIdentity: process)
    let laterRecoveryRecord = store.records(browserBundleIdentifier: browser).first { $0.browserSessionID == "old-extension-profile" }
    try expect(laterRecoveryRecord?.plan == registeredRecoveryPlan && laterRecoveryRecord?.requestedRevealWindowIDs == [parking.windowID],
        "A later desired plan cannot retract a registered-recovery receipt")

    // Closure is a terminal, same-process acknowledgment, not a reveal or plan.
    var closurePlan = plan; closurePlan.intentionSessionID = "closed-parking-intention"
    var secondParking = parking; secondParking.windowID += 1
    closurePlan.parkingWindows = [parking, secondParking]
    _ = try store.accept(closurePlan, browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        currentIntentionSessionID: closurePlan.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    func confirmClosed(_ ids: [Int], proof: BrowserProcessIdentity = process,
                       bundle: String = "org.mozilla.firefox", profile: String = "closure-profile",
                       intention: String = "closed-parking-intention") throws -> BrowserWindowVisibilityStore.Acceptance {
        try store.confirmRegisteredParkingClosed(browserBundleIdentifier: bundle, browserSessionID: profile,
            intentionSessionID: intention, browserProcessIdentity: proof, windowIDs: ids, receivedAt: timestamp)
    }
    let closureBeforeCapture = try confirmClosed([parking.windowID])
    try expect(closureBeforeCapture == .rejected, "Registration without native capture cannot retire a holder")
    _ = try store.writeCaptureReceipt(.init(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID, windowIDs: [parking.windowID]))
    let closureFile = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID)
    let closureBytes = try Data(contentsOf: closureFile)
    let invalidClosures = try [
        confirmClosed([]), confirmClosed([parking.windowID, parking.windowID]), confirmClosed([-1]),
        confirmClosed([9_007_199_254_740_992]), confirmClosed(Array(0..<257)), confirmClosed([999]),
        confirmClosed([parking.windowID, 999]), confirmClosed([window.windowID]), confirmClosed([secondParking.windowID]),
        confirmClosed([parking.windowID], proof: restarted), confirmClosed([parking.windowID], proof: recycled),
        confirmClosed([parking.windowID], bundle: "com.google.Chrome"), confirmClosed([parking.windowID], profile: "foreign"),
        confirmClosed([parking.windowID], intention: "foreign"), confirmClosed([parking.windowID], profile: " ")
    ]
    try expect(invalidClosures.allSatisfy { $0 == .rejected },
        "Closures reject malformed IDs, uncaptured/ordinary windows and foreign process/profile/intention proof")
    let closureBytesAfterDenials = try Data(contentsOf: closureFile)
    try expect(closureBytesAfterDenials == closureBytes, "Rejected closure cannot mutate the registered plan")
    let closureAccepted = try confirmClosed([parking.windowID])
    let closureRecord = store.record(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID)!
    try expect(closureAccepted == .written && closureRecord.closedParkingWindowIDs == [parking.windowID]
        && closureRecord.plan == closurePlan && closureRecord.requestedRevealWindowIDs.isEmpty
        && closureRecord.registeredParkingWindows == [parking, secondParking],
        "Confirmed closure adds only the terminal parking ID without a reveal, revision or registration")
    let closureFileDate = Date(timeIntervalSince1970: 3_000)
    try FileManager.default.setAttributes([.modificationDate: closureFileDate], ofItemAtPath: closureFile.path)
    let closureReplay = try confirmClosed([parking.windowID])
    let afterClosureDate = try FileManager.default.attributesOfItem(atPath: closureFile.path)[.modificationDate] as? Date
    try expect(closureReplay == .unchanged && afterClosureDate == closureFileDate,
        "Closure acknowledgment survives host reload without repeating writes")
    closurePlan.revision += 1; closurePlan.parkingWindows = []
    _ = try store.accept(closurePlan, browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        currentIntentionSessionID: closurePlan.intentionSessionID, receivedAt: timestamp, browserProcessIdentity: process)
    closurePlan.revision += 1
    _ = try store.acceptReveal(closurePlan, browserBundleIdentifier: browser, browserSessionID: "closure-profile", receivedAt: timestamp)
    _ = try store.requestRegisteredRecovery(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID, browserProcessIdentity: process, windowIDs: [parking.windowID], receivedAt: timestamp)
    let afterClosurePlans = store.record(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID)!
    try expect(afterClosurePlans.closedParkingWindowIDs == [parking.windowID] && afterClosurePlans.plan == closurePlan,
        "Later active, reveal and recovery plans cannot erase a terminal closure")
    _ = try store.writeCaptureReceipt(.init(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID, windowIDs: [secondParking.windowID]))
    let secondClosure = try confirmClosed([secondParking.windowID])
    let combinedClosure = store.record(browserBundleIdentifier: browser, browserSessionID: "closure-profile",
        intentionSessionID: closurePlan.intentionSessionID)!
    try expect(secondClosure == .written && combinedClosure.closedParkingWindowIDs == [parking.windowID, secondParking.windowID],
        "Multiple confirmed closures accumulate independently of current desired parking descriptors")
    var legacyClosureObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closureRecord)) as! [String: Any]
    legacyClosureObject.removeValue(forKey: "closedParkingWindowIDs")
    let legacyClosureRecord = try JSONDecoder().decode(BrowserWindowVisibilityRecord.self,
        from: JSONSerialization.data(withJSONObject: legacyClosureObject))
    try expect(legacyClosureRecord.closedParkingWindowIDs.isEmpty && legacyClosureRecord.isValid,
        "Compatible older records default to no confirmed closures")
    var invalidClosureRecord = closureRecord
    invalidClosureRecord.closedParkingWindowIDs = [parking.windowID, parking.windowID]
    try expect(!invalidClosureRecord.isValid, "A malformed duplicate closure record is invalid")
    invalidClosureRecord.closedParkingWindowIDs = [window.windowID]
    try expect(!invalidClosureRecord.isValid, "A record cannot claim ordinary windows as closed parking")
    var staleParkingPlan = closureRecord
    staleParkingPlan.plan.windows = []; staleParkingPlan.plan.parkingWindows = [parking]
    try expect(Matcher.matches(records: [staleParkingPlan], candidates: [parkingNative]).isEmpty,
        "A stale descriptor cannot recapture the old CG window after confirmed closure")
    var changedRole = staleParkingPlan
    changedRole.plan.windows = [parking]; changedRole.plan.parkingWindows = []
    try expect(Matcher.matches(records: [changedRole], candidates: [parkingNative]).isEmpty,
        "A later ordinary-window descriptor cannot rebind an already closed parking ID")
    func retiresClosed(record: BrowserWindowVisibilityRecord = closureRecord,
                       proof: BrowserProcessIdentity = process, bundle: String = "org.mozilla.firefox",
                       profile: String? = "closure-profile", intention: String? = "closed-parking-intention",
                       browserWindow: Int? = parking.windowID, nativeWindow: UInt32? = 12800, isParking: Bool = true) -> Bool {
        BrowserWindowVisibilityRestorationPolicy.parkingDisposition(expectedIdentity: proof,
            expectedBundleIdentifier: bundle, browserSessionID: profile, intentionSessionID: intention,
            browserWindowID: browserWindow, nativeWindowID: nativeWindow, isParking: isParking, record: record) == .discard
    }
    try expect(retiresClosed(), "The exact captured parking journal tuple can retire without inspecting CG/AX state")
    try expect(!retiresClosed(isParking: false) && !retiresClosed(nativeWindow: nil) && !retiresClosed(nativeWindow: 0),
        "A closure cannot retire an ordinary window or whole-app visibility entry")
    try expect(!retiresClosed(profile: "foreign") && !retiresClosed(intention: "foreign")
        && !retiresClosed(browserWindow: secondParking.windowID) && !retiresClosed(bundle: "com.google.Chrome")
        && !retiresClosed(proof: recycled) && !retiresClosed(proof: restarted)
        && !retiresClosed(profile: nil) && !retiresClosed(intention: nil) && !retiresClosed(browserWindow: nil),
        "Closure retirement requires every profile, intention, window and process identity component to match")
    var queuedReveal = closureRecord
    queuedReveal.closedParkingWindowIDs = []; queuedReveal.requestedRevealWindowIDs = [parking.windowID]
    func pendingParkingAction(_ record: BrowserWindowVisibilityRecord) -> BrowserWindowVisibilityRestorationPolicy.Disposition {
        BrowserWindowVisibilityRestorationPolicy.parkingDisposition(expectedIdentity: process,
            expectedBundleIdentifier: browser, browserSessionID: "closure-profile", intentionSessionID: closurePlan.intentionSessionID,
            browserWindowID: parking.windowID, nativeWindowID: 12800, isParking: true, record: record)
    }
    try expect(pendingParkingAction(queuedReveal) == .restore,
        "An exact captured parking entry can reveal while its latest durable record still permits it")
    queuedReveal.closedParkingWindowIDs = [parking.windowID]
    try expect(pendingParkingAction(queuedReveal) == .discard,
        "A closure received during queued AX work overrides the old reveal snapshot before the effect")
    queuedReveal.closedParkingWindowIDs = []; queuedReveal.requestedRevealWindowIDs = []
    try expect(pendingParkingAction(queuedReveal) == .retain,
        "Missing current reveal permission retains a pending parking entry")
    var missingProofClosure = closureRecord; missingProofClosure.browserProcessIdentity = nil
    try expect(!retiresClosed(record: missingProofClosure) && !retiresClosed(record: legacyClosureRecord),
        "Legacy missing process/closure proof retains native ownership")

    // The app reveal guard never blocks behind a host writer, and the same
    // per-occurrence lock serializes an accepted closure with effect dispatch.
    let lockFile = store.fileURL(browserBundleIdentifier: browser, browserSessionID: "closure-lock-profile",
        intentionSessionID: closureRecord.plan.intentionSessionID)
    var lockRecord = closureRecord; lockRecord.browserSessionID = "closure-lock-profile"
    lockRecord.closedParkingWindowIDs = []; lockRecord.requestedRevealWindowIDs = [parking.windowID]
    try JSONEncoder().encode(lockRecord).write(to: lockFile, options: .atomic)
    _ = try store.writeCaptureReceipt(.init(browserBundleIdentifier: browser, browserSessionID: lockRecord.browserSessionID,
        intentionSessionID: lockRecord.plan.intentionSessionID, windowIDs: [parking.windowID]))
    let writerStarted = DispatchSemaphore(value: 0), writerFinished = DispatchSemaphore(value: 0)
    final class ClosureWriteOutcome: @unchecked Sendable {
        var result: BrowserWindowVisibilityStore.Acceptance?
        var error: Error?
    }
    let closureWriteOutcome = ClosureWriteOutcome()
    let lockProfile = lockRecord.browserSessionID, lockIntention = lockRecord.plan.intentionSessionID
    var lockRejected = false, closureWaitedForDispatch = false
    try store.withLockedRecordForRestoration(browserBundleIdentifier: browser, browserSessionID: lockProfile,
                                            intentionSessionID: lockIntention) { record in
        try expect(record?.closedParkingWindowIDs == [], "The first locked read sees the existing reveal authority")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try store.withLockedRecordForRestoration(browserBundleIdentifier: browser, browserSessionID: lockProfile,
                intentionSessionID: lockIntention) { _ in throw SpecFailure(description: "Busy restore lock ran its effect") }
        } catch let error as NSError {
            lockRejected = error.domain == NSPOSIXErrorDomain && (error.code == Int(EWOULDBLOCK) || error.code == Int(EAGAIN))
        }
        try expect(ProcessInfo.processInfo.systemUptime - started < 0.5,
            "A contended restoration lock fails promptly instead of blocking the app's main thread")
        DispatchQueue.global().async {
            writerStarted.signal()
            do {
                closureWriteOutcome.result = try store.confirmRegisteredParkingClosed(browserBundleIdentifier: browser,
                    browserSessionID: lockProfile, intentionSessionID: lockIntention, browserProcessIdentity: process,
                    windowIDs: [parking.windowID], receivedAt: timestamp)
            } catch { closureWriteOutcome.error = error }
            writerFinished.signal()
        }
        try expect(writerStarted.wait(timeout: .now() + 1) == .success, "Concurrent closure writer starts")
        closureWaitedForDispatch = writerFinished.wait(timeout: .now() + 0.05) == .timedOut
        let during = store.record(browserBundleIdentifier: browser, browserSessionID: lockProfile, intentionSessionID: lockIntention)
        try expect(during?.closedParkingWindowIDs == [], "Closure cannot be accepted while a preceding reveal dispatch holds the lock")
    }
    try expect(writerFinished.wait(timeout: .now() + 2) == .success && closureWriteOutcome.result == .written
        && closureWriteOutcome.error == nil && closureWaitedForDispatch && lockRejected,
        "Closure acceptance and parking dispatch share one exact-record lock, with nonblocking app contention")
    var effectsAfterClosure = 0
    try store.withLockedRecordForRestoration(browserBundleIdentifier: browser, browserSessionID: lockProfile,
                                            intentionSessionID: lockIntention) { record in
        guard let record else { throw SpecFailure(description: "Locked closure record disappeared") }
        let disposition = BrowserWindowVisibilityRestorationPolicy.parkingDisposition(expectedIdentity: process,
            expectedBundleIdentifier: browser, browserSessionID: lockProfile, intentionSessionID: lockIntention,
            browserWindowID: parking.windowID, nativeWindowID: 12800, isParking: true, record: record)
        if disposition == .restore { effectsAfterClosure += 1 }
        try expect(disposition == .discard, "The locked latest record overrides a queued old reveal after closure acceptance")
    }
    try expect(effectsAfterClosure == 0, "No parking reveal effect can dispatch after its closure receipt was accepted")

    typealias RestartPolicy = BrowserWindowVisibilityRestartPolicy
    func permitsRestart(requested: BrowserProcessIdentity? = process, stored: BrowserProcessIdentity? = process,
                        current: BrowserProcessIdentity? = restarted,
                        state: RestartPolicy.PreviousProcessState = .terminated, active: Bool = false,
                        requestedSession: String = "old-profile", storedSession: String = "old-profile",
                        currentSession: String = "new-profile") -> Bool {
        RestartPolicy.permits(requestedPreviousIdentity: requested, storedPreviousIdentity: stored,
            currentIdentity: current, previousProcessState: state, hasFreshActiveIntention: active,
            requestedPreviousBrowserSessionID: requestedSession, storedPreviousBrowserSessionID: storedSession,
            currentBrowserSessionID: currentSession)
    }
    try expect(permitsRestart(), "A confirmed full-process restart can recover its exact old durable ownership")
    try expect(!permitsRestart(current: process, state: .running),
        "An extension-worker reload inside the same browser process cannot use restart recovery")
    try expect(!permitsRestart(current: process), "Changed session IDs alone do not prove a process restart")
    try expect(!permitsRestart(state: .running) && !permitsRestart(state: .unknown),
        "A live old process, unknown AppKit state or EPERM never authorizes restart recovery")
    try expect(permitsRestart(current: recycled, state: .reused(recycled)),
        "A recycled PID is accepted only with verified different launch identity")
    try expect(!permitsRestart(current: recycled, state: .terminated),
        "ESRCH cannot be claimed for the same PID verified as the currently running browser")
    try expect(!permitsRestart(state: .reused(process)), "Unchanged launch evidence is not PID reuse")
    try expect(!permitsRestart(state: .reused(restarted)), "Reuse evidence must refer to the exact old PID")
    try expect(permitsRestart(state: .reused(recycled)),
        "A verified other lifetime at the old PID proves the old browser process ended")
    try expect(!permitsRestart(current: recycled,
        state: .reused(.init(pid: process.pid, launched: recycled.launched + 1))),
        "Conflicting current evidence for the same recycled PID fails closed")
    try expect(!permitsRestart(active: true), "No fresh active intention can be bypassed by restart recovery")
    try expect(!permitsRestart(requested: restarted) && !permitsRestart(requested: nil)
        && !permitsRestart(stored: nil) && !permitsRestart(current: nil),
        "Wrong, stale or absent process proofs cannot authorize browser-side restoration")
    try expect(!permitsRestart(requestedSession: "different-profile")
        && !permitsRestart(currentSession: "old-profile") && !permitsRestart(storedSession: ""),
        "Restart recovery requires the exact prior profile session and a different valid current one")

    typealias RestorationPolicy = BrowserWindowVisibilityRestorationPolicy
    func restorationDisposition(_ state: RestorationPolicy.ProcessState) -> RestorationPolicy.Disposition {
        RestorationPolicy.disposition(expectedIdentity: process, expectedBundleIdentifier: browser, processState: state)
    }
    try expect(restorationDisposition(.running(identity: process, bundleIdentifier: browser)) == .restore,
        "Recovery may touch only the exact live process identity and expected application")
    for bundle in ["com.apple.finder", "com.apple.calculator"] {
        try expect(RestorationPolicy.disposition(expectedIdentity: process, expectedBundleIdentifier: bundle,
            processState: .running(identity: process, bundleIdentifier: bundle)) == .restore,
            "The same exact-process recovery policy preserves ordinary hidden Finder and Calculator apps")
        try expect(RestorationPolicy.disposition(expectedIdentity: process, expectedBundleIdentifier: bundle,
            processState: .running(identity: nil, bundleIdentifier: bundle)) == .retain,
            "A generic hidden app retains recovery ownership while launch metadata is unavailable")
    }
    try expect(restorationDisposition(.missing) == .discard,
        "Positive ESRCH permits releasing ownership of a terminated process")
    try expect(restorationDisposition(.running(identity: recycled, bundleIdentifier: browser)) == .discard,
        "Verified different launch identity at the old PID permits retiring old ownership")
    try expect(restorationDisposition(.running(identity: recycled, bundleIdentifier: nil)) == .discard,
        "Positive PID reuse proves the old lifetime ended even if the replacement bundle is unavailable")
    try expect(restorationDisposition(.unknown) == .retain,
        "EPERM and other inconclusive liveness results retain ownership without restoring")
    try expect(restorationDisposition(.running(identity: nil, bundleIdentifier: nil)) == .retain,
        "A missing NSRunningApplication object is not evidence that its windows are gone")
    try expect(restorationDisposition(.running(identity: nil, bundleIdentifier: browser)) == .retain,
        "Temporarily unavailable AppKit launch metadata retains exact-window recovery ownership")
    try expect(restorationDisposition(.running(identity: process, bundleIdentifier: nil)) == .retain
        && restorationDisposition(.running(identity: process, bundleIdentifier: "com.other.application")) == .retain,
        "Missing or conflicting bundle metadata cannot authorize restoration or discard ownership")
    try expect(restorationDisposition(.running(identity: restarted, bundleIdentifier: browser)) == .retain,
        "An observation of a different PID is not proof that the expected PID was reused")
    try expect(restorationDisposition(.running(identity: .init(pid: process.pid, launched: .nan), bundleIdentifier: browser)) == .retain,
        "Invalid process metadata never causes a visibility change or erases recovery ownership")
}
