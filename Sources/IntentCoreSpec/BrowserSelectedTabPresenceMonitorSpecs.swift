import Foundation
import IntentCore

/// Runs the production asynchronous monitor phase with real isolated mailbox
/// files; the callback stands in for the model's synchronous stop decision.
func runBrowserSelectedTabPresenceMonitorSpecs() throws {
    let completion = PresenceMonitorSpecCompletion()
    let task = Task { @MainActor in
        do { try await exercisePresenceMonitor(); completion.finish(nil) }
        catch { completion.finish(error) }
    }
    let deadline = Date().addingTimeInterval(6)
    while !completion.isFinished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard completion.isFinished else {
        task.cancel()
        throw SpecFailure(description: "The isolated selected-tab monitor regression timed out")
    }
    if let error = completion.error { throw error }
}

@MainActor
private func exercisePresenceMonitor() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-presence-monitor-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshotURL = directory.appendingPathComponent("tabs.json")
    let commandURL = directory.appendingPathComponent("command.json")
    let browser = "org.mozilla.firefox", session = "monitor-owner"
    let ownerPath = BrowserProfileSnapshots.partition(snapshotURL, session: session)
    let requestPath = BrowserSelectedTabPresenceCheck.commandFileURL(base: commandURL, session: session)
    let replyPath = BrowserProfileSnapshots.discoveryPartition(snapshotURL, session: session)
    let selected = BrowserTabItem(id: 8, windowID: 344, index: 0, title: "Selected",
        url: "https://example.test/", active: true)
    let owner = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: session,
        browserProfileID: "monitor-profile", tabs: [], updatedAt: Date(), allTabs: [])
    try BrowserTabSnapshotStore(fileURL: ownerPath).write(owner)
    try JSONEncoder().encode(Date()).write(to: ownerPath.appendingPathExtension("heartbeat"))

    @MainActor func makeCheck(searchSessionID: String? = nil) throws -> BrowserSelectedTabPresenceCheck {
        try? FileManager.default.removeItem(at: requestPath)
        guard let value = BrowserSelectedTabPresenceCheck(browser: browser, expectedSession: session,
            selectedIDs: [8,9], searchSessionID: searchSessionID, snapshotURL: snapshotURL, commandURL: commandURL) else {
            throw SpecFailure(description: "The isolated monitor has its exact live owner")
        }
        return value
    }
    @MainActor func awaitRequest() async throws -> BrowserTabCommand {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: requestPath),
               let value = try? JSONDecoder().decode(BrowserTabCommand.self, from: data) { return value }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw SpecFailure(description: "The production confirmation phase must issue discovery before waiting")
    }
    @MainActor func reply(_ command: BrowserTabCommand, tabs: [BrowserTabItem]) throws {
        var value = owner
        value.updatedAt = Date(); value.tabs = tabs; value.allTabs = tabs
        value.profileDiscoveryRequestIDs = [command.id]
        try BrowserTabSnapshotStore(fileURL: replyPath).write(value)
    }

    for tabs in [[selected], []] {
        let check = try makeCheck()
        var decisions: [BrowserSelectedTabPresenceCheck.Result] = []
        let phase = Task { @MainActor in
            await BrowserSelectedTabPresenceMonitor.confirm(check, isCurrent: { true }, didConfirm: { decisions.append($0) })
        }
        let command = try await awaitRequest()
        try expect(decisions.isEmpty, "An ordinary empty snapshot cannot deliver a stop decision while discovery is pending")
        try reply(command, tabs: tabs)
        await phase.value
        try expect(decisions == [tabs.isEmpty ? .closed : .present],
            "Only the correlated delayed inventory reaches the monitor decision callback, exactly once")
    }

    let searchSession = "monitor-current-rules"
    let search = BrowserTabItem(id: 19, windowID: 344, index: 1, title: "Study search",
        url: "https://www.google.com/search?q=study", active: true, searchSessionID: searchSession)
    for searchesEnabled in [true, false] {
        let check = try makeCheck(searchSessionID: searchesEnabled ? searchSession : nil)
        var decisions: [BrowserSelectedTabPresenceCheck.Result] = []
        let phase = Task { @MainActor in
            await BrowserSelectedTabPresenceMonitor.confirm(check, isCurrent: { true }, didConfirm: { decisions.append($0) })
        }
        let command = try await awaitRequest()
        try reply(command, tabs: [search])
        await phase.value
        try expect(decisions == [searchesEnabled ? .present : .closed],
            "The actual asynchronous closure callback counts current search work only when its modification is enabled")
    }

    for cancel in [false, true] {
        let check = try makeCheck()
        let startedOccurrence = UUID()
        var currentOccurrence = startedOccurrence
        var decisions: [BrowserSelectedTabPresenceCheck.Result] = []
        let phase = Task { @MainActor in
            await BrowserSelectedTabPresenceMonitor.confirm(check,
                isCurrent: { currentOccurrence == startedOccurrence }, didConfirm: { decisions.append($0) })
        }
        let command = try await awaitRequest()
        if cancel { phase.cancel() } else { currentOccurrence = UUID() }
        try reply(command, tabs: [])
        await phase.value
        try expect(decisions.isEmpty,
            "Explicit monitor cancellation or a new occurrence prevents a late closed reply from delivering any stop decision")
    }

    // Production Finish/expiry/checklist requests stop first. The occurrence
    // and monitor task remain alive until the lock's asynchronous teardown, so
    // task cancellation alone is not the boundary for accepting this reply.
    let stopping = try makeCheck()
    let stoppingOccurrence = UUID()
    let currentOccurrence = stoppingOccurrence
    var stopRequested = false
    var stoppingDecisions: [BrowserSelectedTabPresenceCheck.Result] = []
    let stoppingPhase = Task { @MainActor in
        await BrowserSelectedTabPresenceMonitor.confirm(stopping,
            isCurrent: { currentOccurrence == stoppingOccurrence && !stopRequested },
            didConfirm: { stoppingDecisions.append($0) })
    }
    let stoppingCommand = try await awaitRequest()
    stopRequested = true
    try reply(stoppingCommand, tabs: [])
    await stoppingPhase.value
    try expect(!stoppingPhase.isCancelled && currentOccurrence == stoppingOccurrence && stoppingDecisions.isEmpty,
        "A stop request rejects a late closure before teardown cancels the monitor or replaces its occurrence")

    // A query started late in wake-up verification must use the remaining
    // active-time budget, including time spent before another lock interval.
    let waking = try makeCheck()
    var desktopClock = DesktopSessionClock()
    var wakePolicy = DesktopSessionCoveragePolicy(required: [.browser(browser)], requiresInitialVerification: true)
    wakePolicy.update(desktopClock.observe(.available, uptime: 0))
    wakePolicy.update(desktopClock.observe(.secured, uptime: 1))
    wakePolicy.update(desktopClock.observe(.available, uptime: 61))
    var queryUptime: TimeInterval = 62.9
    var wakeExpired = false
    var wakingDecisions: [BrowserSelectedTabPresenceCheck.Result] = []
    let wakingPhase = Task { @MainActor in
        await BrowserSelectedTabPresenceMonitor.confirm(waking, isCurrent: {
            wakePolicy.update(desktopClock.observe(.available, uptime: queryUptime))
            if wakePolicy.hasPendingVerification, wakePolicy.expiredDomain(grace: 3) != nil {
                wakeExpired = true
                return false
            }
            return true
        }, didConfirm: { wakingDecisions.append($0) })
    }
    let wakingCommand = try await awaitRequest()
    queryUptime = 63.01
    try reply(wakingCommand, tabs: [selected])
    await wakingPhase.value
    try expect(wakeExpired && wakingDecisions.isEmpty,
        "A late successful exact-profile reply cannot extend a wake deadline beyond its retained active-time budget")

    let obsolete = try makeCheck()
    var obsoleteDecisions: [BrowserSelectedTabPresenceCheck.Result] = []
    await BrowserSelectedTabPresenceMonitor.confirm(obsolete, isCurrent: { false },
        didConfirm: { obsoleteDecisions.append($0) })
    try expect(!FileManager.default.fileExists(atPath: requestPath.path) && obsoleteDecisions.isEmpty,
        "An already replaced occurrence cannot issue discovery or deliver a decision")

    let unanswered = try makeCheck()
    var timeoutDecisions: [BrowserSelectedTabPresenceCheck.Result] = []
    await BrowserSelectedTabPresenceMonitor.confirm(unanswered, isCurrent: { true },
        didConfirm: { timeoutDecisions.append($0) })
    try expect(timeoutDecisions == [.pending], "The bounded unanswered query reports uncertainty, never tab closure")
}

private final class PresenceMonitorSpecCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func finish(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        failure = error; finished = true
    }
}
