import Foundation
import Darwin
import IntentCore

func runBrowserNativeFinderSpecs() throws {
    let finder = UUID().uuidString
    let open = BrowserFinderCommand(finderID: finder, action: .open, browserSessionID: "profile-a", windowID: 4, anchorTabID: 7,
        frame: .init(left: 100, top: 120, width: 720, height: 520))
    let commit = BrowserFinderCommand(finderID: finder, action: .commit, browserSessionID: "profile-a", windowID: 4, anchorTabID: 7,
        finderWindowID: 10, finderTabID: 20)
    let cancel = BrowserFinderCommand(finderID: finder, action: .cancel, browserSessionID: "profile-a", windowID: 4, anchorTabID: 7)
    try expect(open.isValid && commit.isValid && cancel.isValid, "Finder commands support exact ownership and cancellation before open completes")
    var invalid = commit; invalid.finderTabID = nil
    try expect(!invalid.isValid, "Commit cannot guess the newly owned tab")
    invalid = commit; invalid.finderTabID = commit.anchorTabID
    try expect(!invalid.isValid, "Finder never claims the original anchor")
    invalid = open; invalid.finderWindowID = 10; invalid.finderTabID = 20
    try expect(!invalid.isValid, "Opening cannot assert prior ownership")
    invalid = cancel; invalid.finderWindowID = 10
    try expect(!invalid.isValid, "Partially specified cancellation ownership is rejected")
    func receipt(_ command: BrowserFinderCommand, extra: [String: Any]) throws -> BrowserFinderReceipt {
        let row: [String: Any] = ["requestID": command.id, "finderID": command.finderID, "action": command.action.rawValue,
            "browserSessionID": command.browserSessionID, "originalWindowID": command.windowID, "anchorTabID": command.anchorTabID]
        return try JSONDecoder().decode(BrowserFinderReceipt.self, from: JSONSerialization.data(withJSONObject: row.merging(extra) { _, rhs in rhs }))
    }
    let opened = try receipt(open, extra: ["windowID": 10, "tabID": 20,
        "frame": ["left": 100, "top": 120, "width": 720, "height": 520]])
    try expect(opened.matches(open), "Exact new normal-window receipt is accepted")
    var changed = opened; changed.windowID = open.windowID
    try expect(!changed.matches(open), "An existing window cannot be presented as the owned new finder")
    changed = opened; changed.browserSessionID = "profile-b"
    try expect(!changed.matches(open), "A receipt from another profile cannot own the finder")
    let added = try receipt(commit, extra: ["windowID": 4, "tabID": 20,
        "tab": ["id": 20, "windowID": 4, "index": 2, "title": "Chosen", "url": "https://example.test/path", "active": false]])
    try expect(added.matches(commit), "Add receipt returns the exact newly owned tab in its original destination")
    changed = added; changed.tabID = 21; changed.tab?.id = 21
    try expect(!changed.matches(commit), "A different existing tab cannot be silently selected by a matching URL or title")
    changed = added; changed.tab?.windowID = 5
    try expect(!changed.matches(commit), "A receipt in another window fails closed")
    changed = added; changed.tab?.url = "https://name:secret@example.test"
    try expect(!changed.matches(commit), "Credential-bearing URL cannot be staged")
    let cancelled = try receipt(cancel, extra: [:])
    try expect(cancelled.matches(cancel), "Cancellation receipt is correlated without a captured website")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-finder-spec-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mailbox = BrowserFinderMailbox(browser: "com.google.Chrome", session: "profile-a", directory: directory)
    let other = BrowserFinderMailbox(browser: "com.google.Chrome", session: "profile-b", directory: directory)
    try mailbox.write(open); try mailbox.write(open); try mailbox.write(commit); try mailbox.write(cancel)
    try expect(other.take() == nil, "Finder queue is private to the selected browser profile")
    try expect(mailbox.take() == cancel, "Cancellation overtakes a pending open or commit")
    try expect(mailbox.take() == open && mailbox.take() == commit && mailbox.take() == nil, "Command IDs are queued once with independent action receipts")
    do {
        try other.write(open)
        throw SpecFailure(description: "Cross-profile finder write must fail")
    } catch is BrowserTabCreationError { }

    let lock = Darwin.open(mailbox.fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw SpecFailure(description: "Finder contention fixture lock unavailable") }
    defer { flock(lock, LOCK_UN); Darwin.close(lock) }
    try expect(flock(lock, LOCK_EX | LOCK_NB) == 0, "Fixture owns the finder mailbox lock")
    let began = ProcessInfo.processInfo.systemUptime
    do {
        try mailbox.write(cancel)
        throw SpecFailure(description: "Contended finder writes must not enter a blocking lock")
    } catch BrowserFinderMailbox.Error.busy { }
    try expect(ProcessInfo.processInfo.systemUptime - began < 0.5,
        "A contended synchronous mailbox attempt returns without blocking the UI")

    let delivered = FinderDeliveryResult()
    Task.detached {
        do { try await mailbox.writePending(cancel, timeout: 1); delivered.finish(nil) }
        catch { delivered.finish(error) }
    }
    try expect(delivered.done.wait(timeout: .now() + 0.1) == .timedOut,
        "Cancellation remains pending while the host owns the mailbox lock")
    flock(lock, LOCK_UN)
    try expect(delivered.done.wait(timeout: .now() + 2) == .success && delivered.error == nil,
        "Pending cancellation is delivered after contention clears")
    try expect(mailbox.take() == cancel && mailbox.take() == nil,
        "Retry delivers the same cancellation command exactly once")

    try expect(flock(lock, LOCK_EX | LOCK_NB) == 0, "Fixture can hold contention through a retry deadline")
    let expired = FinderDeliveryResult()
    Task.detached {
        do { try await mailbox.writePending(cancel, timeout: 0.1); expired.finish(nil) }
        catch { expired.finish(error) }
    }
    try expect(expired.done.wait(timeout: .now() + 1) == .success && expired.error != nil,
        "Persistent contention finishes within the bounded retry deadline")
    flock(lock, LOCK_UN)
    try expect(mailbox.take() == nil, "Expired delivery does not enqueue a late cancellation")

    let target = WebsiteFinderTarget(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "profile-a",
        browserWindowID: 4, anchorTabID: 7, overviewGeneration: UUID())
    let requestA = UUID(), requestB = UUID()
    var liveFinder: WebsiteFinderTarget? = target
    var completionEffects = 0
    let staleFailure = {
        BrowserFinderCompletion.performIfCurrent(requestID: requestA, currentRequestID: requestB,
            target: target, currentTarget: liveFinder, cancelled: false) {
            completionEffects += 1; liveFinder = nil
        }
    }
    _ = staleFailure()
    try expect(liveFinder == target && completionEffects == 0,
        "A stale snapshot failure cannot dismiss a replacement finder, even for the same target")
    BrowserFinderCompletion.performIfCurrent(requestID: requestB, currentRequestID: requestB,
        target: target, currentTarget: liveFinder, cancelled: true) { completionEffects += 1; liveFinder = nil }
    try expect(liveFinder == target && completionEffects == 0,
        "Cancellation blocks error presentation and dismissal as well as successful selection")
    BrowserFinderCompletion.performIfCurrent(requestID: requestB, currentRequestID: requestB,
        target: target, currentTarget: liveFinder, cancelled: false) { completionEffects += 1; liveFinder = nil }
    try expect(liveFinder == nil && completionEffects == 1, "The current finder completion applies its effect once")
}

private final class FinderDeliveryResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failure: Swift.Error?
    var error: Swift.Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func finish(_ error: Swift.Error?) {
        lock.lock(); failure = error; lock.unlock(); done.signal()
    }
}
