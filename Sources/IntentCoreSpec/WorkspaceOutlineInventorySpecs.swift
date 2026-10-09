import Foundation
import IntentCore

func runWorkspaceOutlineInventorySpecs() throws {
    let now = Date(), browser = "com.google.Chrome"
    let process = BrowserProcessIdentity(pid: 123, launched: 100)
    let tab = BrowserTabItem(id: 8, windowID: 44, index: 0, title: "Example Domain", url: "https://example.com", active: true)
    var owner = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: "outline-a", browserProfileID: "profile-a",
        tabs: [], updatedAt: now, allTabs: [], browserProcessIdentity: process, guardEnabled: true)
    guard let request = WorkspaceOutlineInventory.Request(browser: browser, expectedSession: "outline-a", owners: [owner],
        processes: [process], id: "outline-query", now: now) else { throw SpecFailure(description: "An exact live outline owner can be queried from an idle placeholder") }
    try expect(request.commands.count == 1 && request.commands[0].id == "outline-query"
        && request.commands[0].browserSessionID == "outline-a" && request.commands[0].createdAt == now,
        "Outline discovery sends its own correlated read-only command to the pinned profile")
    try expect(request.resolve(replies: [owner], current: [owner], processes: [process], now: now) == nil,
        "Forced ordinary idle [] cannot certify an empty tab strip or erase Chrome DBT outlines")
    var reply = owner
    reply.tabs = [tab]; reply.allTabs = [tab]; reply.profileDiscoveryRequestIDs = [request.id]
    reply.updatedAt = now.addingTimeInterval(0.1)
    guard let response = request.resolve(replies: [reply], current: [owner], processes: [process], now: now.addingTimeInterval(0.1)) else {
        throw SpecFailure(description: "A fresh correlated inventory resolves while ordinary current inventory remains an idle placeholder")
    }
    try expect(response.snapshot.allTabs == [tab] && response.nativeWindow(id: 44, selectedIDs: [8], process: process)?.selected == [8],
        "The exact discovery reply reaches actual native tab geometry with its selected raw identity")
    var unrelated = reply; unrelated.profileDiscoveryRequestIDs = ["overview-query"]
    try expect(request.resolve(replies: [unrelated], current: [owner], processes: [process], now: now.addingTimeInterval(0.1)) == nil,
        "Another overview or presence query cannot answer or renew the outline reader")
    var old = reply; old.updatedAt = now.addingTimeInterval(-0.1)
    try expect(request.resolve(replies: [old], current: [owner], processes: [process], now: now) == nil,
        "A retained pre-request sidecar never substitutes for a new discovery reply")
    try expect(request.resolve(replies: [reply], current: [owner], processes: [process], now: now.addingTimeInterval(3.2)) == nil,
        "Expired replies cannot renew a staged tab outline")
    var replacement = owner; replacement.browserProfileID = "replacement"
    try expect(!request.isCurrent(owners: [replacement], processes: [process]),
        "Same-session replacement profiles cancel prior outline inventory")
    let restarted = BrowserProcessIdentity(pid: process.pid, launched: 101)
    try expect(!request.isCurrent(owners: [owner], processes: [restarted]),
        "A recycled native PID cannot inherit outline inventory from the old browser lifetime")
    var disabled = owner; disabled.guardEnabled = false
    try expect(!request.isCurrent(owners: [disabled], processes: [process]),
        "A disabled Browser Guard cannot retain ownership of the staged tab contour")
    var noProof = owner; noProof.browserProcessIdentity = nil
    try expect(WorkspaceOutlineInventory.Request(browser: browser, expectedSession: "outline-a", owners: [noProof], processes: [process], now: now) == nil,
        "Outline discovery never guesses the native browser lifetime")
    var malformed = reply; malformed.allTabs = [tab, tab]
    try expect(request.resolve(replies: [malformed], current: [owner], processes: [process], now: now.addingTimeInterval(0.1)) == nil,
        "Duplicate tab identities cannot certify an actual tab-strip outline")

    var continuity = WorkspaceOutlineInventory.Continuity()
    _ = continuity.update(response, context: "selection:profile:process", authoritative: true, now: now)
    try expect(continuity.update(nil, context: "selection:profile:process", authoritative: false,
        now: now.addingTimeInterval(0.35))?.snapshot.allTabs == [tab],
        "A pending own query preserves recently confirmed inventory through an ordinary idle overwrite")
    try expect(continuity.update(nil, context: "selection:profile:process", authoritative: false,
        now: now.addingTimeInterval(0.61)) == nil,
        "A missing query reply clears continuity within its bounded window")
    _ = continuity.update(response, context: "selection:profile:process", authoritative: true, now: now)
    try expect(continuity.update(nil, context: "different-selection", authoritative: false, now: now.addingTimeInterval(0.1)) == nil,
        "Changing selected IDs clears the previous inventory immediately")
    _ = continuity.update(response, context: "selection:profile:process", authoritative: true, now: now)
    reply.tabs = []; reply.allTabs = []
    let empty = request.resolve(replies: [reply], current: [owner], processes: [process], now: now.addingTimeInterval(0.1))
    try expect(continuity.update(empty, context: "selection:profile:process", authoritative: true,
        now: now.addingTimeInterval(0.1))?.snapshot.allTabs == [],
        "An authoritative own empty reply clears previous marks immediately rather than retaining stale tab geometry")
    try expect(continuity.update(nil, context: "selection:profile:process", authoritative: true,
        now: now.addingTimeInterval(0.2)) == nil,
        "Native process or profile ownership loss clears the inventory immediately")

    var other = owner; other.browserSessionID = "outline-b"; other.browserProfileID = "profile-b"
    let nonce = BrowserProfileSnapshots.nonce([owner, other])!
    guard let multi = WorkspaceOutlineInventory.Request(browser: browser, expectedSession: nonce, owners: [owner, other],
        processes: [process], id: "multi-query", now: now) else { throw SpecFailure(description: "Connected profiles can each answer the outline query") }
    var a = owner; a.tabs = [tab]; a.allTabs = [tab]; a.profileDiscoveryRequestIDs = [multi.id]
    var b = other; b.tabs = [tab]; b.allTabs = [tab]; b.profileDiscoveryRequestIDs = [multi.id]
    try expect(multi.resolve(replies: [a], current: [owner, other], processes: [process], now: now) == nil,
        "A partial profile reply cannot reinterpret selected composite IDs or certify disappearance")
    guard let both = multi.resolve(replies: [a, b], current: [owner, other], processes: [process], now: now) else {
        throw SpecFailure(description: "All exact profile replies merge for outline presentation")
    }
    let selectedB = BrowserProfileSnapshots.compositeID(session: "outline-b", id: 8)
    let windowB = BrowserProfileSnapshots.compositeID(session: "outline-b", id: 44)
    let windowA = BrowserProfileSnapshots.compositeID(session: "outline-a", id: 44)
    try expect(both.nativeWindow(id: windowB, selectedIDs: [selectedB], process: process)?.selected == [8]
        && both.nativeWindow(id: windowA, selectedIDs: [selectedB], process: process)?.selected.isEmpty == true,
        "The outline walker receives raw Firefox DOM IDs only from the selected exact composite profile/window")

    let qaProcess = BrowserProcessIdentity(pid: 456, launched: 200)
    other.browserProcessIdentity = qaProcess
    guard let separate = WorkspaceOutlineInventory.Request(browser: browser, expectedSession: nonce, owners: [owner, other],
        processes: [qaProcess, process], id: "separate-process-query", now: now) else {
        throw SpecFailure(description: "Daily and QA profiles in separate browser parent processes retain their own native ownership")
    }
    a.profileDiscoveryRequestIDs = [separate.id]
    b.browserProcessIdentity = qaProcess; b.profileDiscoveryRequestIDs = [separate.id]
    guard let separateReply = separate.resolve(replies: [a, b], current: [owner, other], processes: [process, qaProcess], now: now) else {
        throw SpecFailure(description: "Process enumeration order cannot reject a valid multi-process profile response")
    }
    try expect(separateReply.tabs(for: process).map(\.windowID) == [windowA]
        && separateReply.tabs(for: qaProcess).map(\.windowID) == [windowB],
        "Native title and frame matching sees only rows owned by that exact parent PID and launch, retaining composite IDs")
    try expect(separateReply.nativeWindow(id: windowB, selectedIDs: [selectedB], process: qaProcess)?.selected == [8]
        && separateReply.nativeWindow(id: windowB, selectedIDs: [selectedB], process: process) == nil,
        "A same raw tab/window ID in another Firefox process cannot borrow the daily native contour")
    var wrongProcessReply = b; wrongProcessReply.browserProcessIdentity = process
    try expect(separate.resolve(replies: [a, wrongProcessReply], current: [owner, other], processes: [process, qaProcess], now: now) == nil,
        "A correlated receipt from the wrong parent process still fails exact profile ownership")
    let qaRestarted = BrowserProcessIdentity(pid: qaProcess.pid, launched: 201)
    try expect(!separate.isCurrent(owners: [owner, other], processes: [process, qaRestarted])
        && separateReply.tabs(for: qaRestarted).isEmpty,
        "Reusing a QA browser PID cannot inherit geometry or discovery receipts from its previous lifetime")
    try expect(!separate.isCurrent(owners: [owner, other], processes: [process]),
        "Losing one pinned profile process invalidates the aggregate namespace instead of silently changing selected IDs")
    try expect(separate.isCurrent(owners: [other, owner], processes: [qaProcess, process, .init(pid: 789, launched: 300)]),
        "An additional live browser process with no pinned profile does not invalidate the selected native owners")
    try expect(WorkspaceOutlineInventory.Request(browser: browser, expectedSession: nonce, owners: [owner, other],
        processes: [process, qaProcess, qaRestarted], now: now) == nil,
        "Two lifetimes claiming the same live parent PID are ambiguous and cannot own an outline query")
    owner.browserSessionID = "restarted-a"
    try expect(!multi.isCurrent(owners: [owner, other], processes: [process]),
        "A restarted profile cannot borrow a selected tab's old composite namespace")
}
