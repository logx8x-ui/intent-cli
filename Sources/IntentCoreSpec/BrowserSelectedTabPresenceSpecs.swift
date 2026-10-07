import Foundation
import IntentCore

func runBrowserSelectedTabPresenceSpecs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshotURL = directory.appendingPathComponent("tabs.json")
    let commandURL = directory.appendingPathComponent("command.json")
    let browser = "org.mozilla.firefox", now = Date()
    let tab = BrowserTabItem(id: 8, windowID: 344, index: 0, title: "Example Domain",
        url: "https://example.com/?intent-qa=oct7-a", active: true)
    let owner = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: "session-a",
        browserProfileID: "profile-a", tabs: [], updatedAt: now, allTabs: [])
    func writeOwner(_ value: BrowserTabSnapshot) throws {
        let path = BrowserProfileSnapshots.partition(snapshotURL, session: value.browserSessionID!)
        try BrowserTabSnapshotStore(fileURL: path).write(value)
        try JSONEncoder().encode(now).write(to: path.appendingPathExtension("heartbeat"))
    }
    func command(_ owner: BrowserTabSnapshot) throws -> BrowserTabCommand {
        let path = BrowserSelectedTabPresenceCheck.commandFileURL(base: commandURL, session: owner.browserSessionID!)
        return try JSONDecoder().decode(BrowserTabCommand.self, from: Data(contentsOf: path))
    }
    func writeReply(_ value: BrowserTabSnapshot) throws {
        try BrowserTabSnapshotStore(fileURL: BrowserProfileSnapshots.discoveryPartition(snapshotURL,
            session: value.browserSessionID!)).write(value)
    }
    try writeOwner(owner)
    guard let check = BrowserSelectedTabPresenceCheck(browser: browser, expectedSession: "session-a", selectedIDs: [8,9],
        snapshotURL: snapshotURL, commandURL: commandURL, now: now) else {
        throw SpecFailure(description: "A live exact owner can be queried even when the ordinary inventory is an idle placeholder")
    }
    let normalCommandURL = BrowserProfileSnapshots.partition(commandURL, session: "session-a")
    let normalCommand = BrowserTabCommand(tabID: 8, windowID: 344, action: .activate, browserSessionID: "session-a")
    try JSONEncoder().encode(normalCommand).write(to: normalCommandURL)
    try check.request()
    let retained = try JSONDecoder().decode(BrowserTabCommand.self, from: Data(contentsOf: normalCommandURL))
    try expect(retained == normalCommand, "Presence discovery cannot replace a pending normal tab command")
    let request = try command(owner)
    try expect(request.action == .snapshot && request.browserSessionID == "session-a", "Closure confirmation queries the exact browser owner")
    try expect(check.poll(now: now) == .pending, "A fresh ordinary empty inventory is never evidence that selected tabs closed")
    var reply = owner
    reply.tabs = [tab]; reply.allTabs = [tab]
    reply.profileDiscoveryRequestIDs = ["old-overview-request"]
    try writeReply(reply)
    try expect(check.poll(now: now) == .pending, "Even a fresh pre-Run discovery cannot answer a new closure check")
    reply.profileDiscoveryRequestIDs = [request.id]; reply.updatedAt = now.addingTimeInterval(-0.1)
    try writeReply(reply)
    try expect(check.poll(now: now) == .pending, "The negative-observation query cannot accept a pre-query reply")
    reply.updatedAt = now.addingTimeInterval(0.1); try writeReply(reply)
    try expect(check.poll(now: now.addingTimeInterval(0.1)) == .present, "Delayed exact-query reply sees the still-open selected tab despite empty ordinary inventory")
    try expect(check.poll(now: now.addingTimeInterval(3.2)) == .pending, "A stale/disappeared reply cannot establish closure")
    reply.tabs = []; reply.allTabs = nil; try writeReply(reply)
    try expect(check.poll(now: now.addingTimeInterval(0.1)) == .pending, "A request ID without a complete tab inventory cannot prove closure")
    reply.allTabs = []; try writeReply(reply)
    try expect(check.poll(now: now.addingTimeInterval(0.1)) == .closed, "An exact fresh full inventory with no selected IDs proves real closure")
    reply.allTabs = [tab,tab]; try writeReply(reply)
    try expect(check.poll(now: now.addingTimeInterval(0.1)) == .pending, "Duplicate malformed rows cannot certify presence or absence")
    var wrongProfile = owner; wrongProfile.browserProfileID = "replacement-profile"
    try writeOwner(wrongProfile)
    try expect(check.poll(now: now.addingTimeInterval(0.1)) == .changed, "A different profile cannot borrow the previous browser lifetime")
    try writeOwner(owner)

    // Two connected profiles use composite IDs; raw IDs can overlap. A reply
    // from just one profile cannot silently drop the other selected owner.
    var other = owner; other.browserSessionID = "session-b"; other.browserProfileID = "profile-b"
    try writeOwner(other)
    let expected = BrowserProfileSnapshots.nonce([owner,other])!
    let selected = BrowserProfileSnapshots.compositeID(session: "session-b", id: 8)
    guard let multi = BrowserSelectedTabPresenceCheck(browser: browser, expectedSession: expected, selectedIDs: [selected],
        snapshotURL: snapshotURL, commandURL: commandURL, now: now) else { throw SpecFailure(description: "Two owners can be queried") }
    try multi.request()
    var firstReply = owner; firstReply.tabs = [tab]; firstReply.allTabs = [tab]
    firstReply.profileDiscoveryRequestIDs = [try command(owner).id]; try writeReply(firstReply)
    try expect(multi.poll(now: now) == .pending, "The first owner cannot prove the missing second owner's selection closed")
    var secondReply = other; secondReply.tabs = [tab]; secondReply.allTabs = [tab]
    secondReply.profileDiscoveryRequestIDs = [try command(other).id]; try writeReply(secondReply)
    try expect(multi.poll(now: now) == .present, "Composite selection finds the correct owner even when raw IDs overlap")
    secondReply.tabs = []; secondReply.allTabs = []; try writeReply(secondReply)
    try expect(multi.poll(now: now) == .closed, "The same raw ID in another profile cannot keep a genuinely closed selection alive")
    let otherPath = BrowserProfileSnapshots.partition(snapshotURL, session: "session-b")
    try FileManager.default.removeItem(at: otherPath.appendingPathExtension("heartbeat"))
    try expect(multi.poll(now: now) == .changed, "Owner loss uses browser-identity safety, never an inferred closure")
    var restarted = other; restarted.browserSessionID = "restarted-b"; restarted.tabs = [tab]; restarted.allTabs = [tab]
    try writeOwner(restarted)
    try expect(multi.poll(now: now) == .changed, "Recycled IDs after browser restart never replace the selected lifetime")
}
