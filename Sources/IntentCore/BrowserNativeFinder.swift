import Foundation
import Darwin

public struct BrowserFinderCommand: Codable, Equatable {
    public enum Action: String, Codable { case open, commit, cancel }
    public var id: String = UUID().uuidString
    public var finderID: String
    public var action: Action
    public var browserSessionID: String
    public var windowID: Int
    public var anchorTabID: Int
    public var frame: BrowserWindowFrame?
    public var finderWindowID: Int?
    public var finderTabID: Int?
    public var expiresAtUnixMS: Double = Date().timeIntervalSince1970 * 1000 + 8000
    public init(id: String = UUID().uuidString, finderID: String, action: Action, browserSessionID: String,
                windowID: Int, anchorTabID: Int, frame: BrowserWindowFrame? = nil,
                finderWindowID: Int? = nil, finderTabID: Int? = nil,
                expiresAtUnixMS: Double = Date().timeIntervalSince1970 * 1000 + 8000) {
        self.id = id; self.finderID = finderID; self.action = action; self.browserSessionID = browserSessionID
        self.windowID = windowID; self.anchorTabID = anchorTabID; self.frame = frame
        self.finderWindowID = finderWindowID; self.finderTabID = finderTabID; self.expiresAtUnixMS = expiresAtUnixMS
    }
    public var isValid: Bool {
        let owned = finderWindowID.map { $0 >= 0 && $0 != windowID } == true
            && finderTabID.map { $0 >= 0 && $0 != anchorTabID } == true
        let noOwned = finderWindowID == nil && finderTabID == nil
        guard action == .open ? noOwned : (action == .commit ? owned : (owned || noOwned)) else { return false }
        return UUID(uuidString: id) != nil && UUID(uuidString: finderID) != nil && !browserSessionID.isEmpty
            && browserSessionID.utf8.count <= 1024 && windowID >= 0 && anchorTabID >= 0
            && expiresAtUnixMS.isFinite
    }
}

public struct BrowserFinderReceipt: Codable, Equatable {
    public var requestID: String
    public var finderID: String
    public var action: BrowserFinderCommand.Action
    public var browserSessionID: String
    public var originalWindowID: Int
    public var anchorTabID: Int
    public var windowID: Int?
    public var tabID: Int?
    public var frame: BrowserWindowFrame?
    public var tab: BrowserTabItem?
    public var error: String?
    public func matches(_ command: BrowserFinderCommand) -> Bool {
        guard command.isValid, requestID == command.id, finderID == command.finderID, action == command.action,
              browserSessionID == command.browserSessionID, originalWindowID == command.windowID,
              anchorTabID == command.anchorTabID else { return false }
        if let error { return !error.isEmpty && error.utf8.count <= 2048 && tab == nil }
        switch action {
        case .open:
            guard let windowID, let tabID, let frame else { return false }
            return windowID >= 0 && windowID != originalWindowID && tabID >= 0 && tabID != anchorTabID
                && [frame.left, frame.top, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0 && tab == nil
        case .commit:
            guard let tab else { return false }
            return windowID == originalWindowID && tab.windowID == originalWindowID && tabID == tab.id
                && tab.id == command.finderTabID && tab.id >= 0 && tab.id != anchorTabID && WebsiteFinderPolicy.validatedURL(tab.url) != nil
        case .cancel: return tab == nil
        }
    }
    public static func fileURL(requestID: String, directory: URL = IntentEnvironment.dataDirectory) -> URL? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        return directory.appendingPathComponent("browser-finder-result-\(requestID).json")
    }
}

/// Finder commands have their own locked queue, independent from snapshot and
/// preview refreshes. Only the native host for this profile can consume them.
public final class BrowserFinderMailbox: @unchecked Sendable {
    public enum Error: Swift.Error { case busy }
    private static let deliveryQueue = DispatchQueue(label: "intent.native-finder-mailbox", qos: .utility)
    public let fileURL: URL
    private let session: String
    public init(browser: String, session: String, directory: URL = IntentEnvironment.dataDirectory) {
        let component = String(browser.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        fileURL = directory.appendingPathComponent("browser-finder-\(component)-\(BrowserProfileSnapshots.component(session)).json")
        self.session = session
    }
    public func write(_ command: BrowserFinderCommand) throws {
        guard command.isValid, command.browserSessionID == session else { throw BrowserTabCreationError.changed }
        try edit { rows in
            guard !rows.contains(where: { $0.id == command.id }) else { return }
            guard rows.count < 32 else { throw BrowserTabCreationError.unavailable }
            rows.append(command)
        }
    }
    /// File work stays off the caller's actor. A busy host never blocks Cancel
    /// or typing; the same immutable command remains pending within its deadline.
    public func writePending(_ command: BrowserFinderCommand, timeout: TimeInterval = 8) async throws {
        let remaining = command.expiresAtUnixMS / 1000 - Date().timeIntervalSince1970
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(0, timeout), max(0, remaining))
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                    Self.deliveryQueue.async {
                        do { try self.write(command); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                return
            } catch Error.busy {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw BrowserTabCreationError.unavailable
    }
    public func take() -> BrowserFinderCommand? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var result: BrowserFinderCommand?
        do { try edit { rows in
            guard !rows.isEmpty else { return }
            result = rows.remove(at: rows.firstIndex(where: { $0.action == .cancel }) ?? 0)
        }; return result } catch { return nil }
    }
    private func edit(_ body: (inout [BrowserFinderCommand]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BrowserTabCreationError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Error.busy }
            throw BrowserTabCreationError.unavailable
        }
        defer { flock(fd, LOCK_UN) }
        let original = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONDecoder().decode([BrowserFinderCommand].self, from: Data(contentsOf: fileURL)) : []
        guard original.count <= 32, original.allSatisfy({ $0.isValid && $0.browserSessionID == session }) else { throw BrowserTabCreationError.changed }
        var rows = original; try body(&rows)
        if rows.isEmpty { try? FileManager.default.removeItem(at: fileURL) }
        else if rows != original { try JSONEncoder().encode(rows).write(to: fileURL, options: .atomic) }
    }
}

/// A snapshot reply may outlive its finder. Apply every completion effect,
/// including error presentation and dismissal, only to its original attempt.
public enum BrowserFinderCompletion {
    @discardableResult public static func performIfCurrent(requestID: UUID, currentRequestID: UUID,
        target: WebsiteFinderTarget, currentTarget: WebsiteFinderTarget?, cancelled: Bool,
        effect: () -> Void) -> Bool {
        guard !cancelled, requestID == currentRequestID, target == currentTarget else { return false }
        effect()
        return true
    }
}

/// Session identity pins the live profile. No default browser launch, guessed
/// profile name, copied cookies, or URL recreation is involved.
@MainActor
public final class BrowserFinderClient {
    public let target: WebsiteFinderTarget
    public let finderID = UUID().uuidString
    private let ownerSession: String
    private let anchorID: Int
    private let windowID: Int
    private let mailbox: BrowserFinderMailbox
    private var opened = false
    private var ownedWindowID: Int?
    private var ownedTabID: Int?
    private var cancellationTask: Task<Void, Never>?
    public init(target: WebsiteFinderTarget) throws {
        self.target = target
        guard target.isValid else { throw BrowserTabCreationError.changed }
        try Self.assertInactive()
        let profiles = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: target.browserBundleIdentifier))
        guard BrowserProfileSnapshots.nonce(profiles) == target.browserSessionID,
              let owner = profiles.first(where: { snapshot in
                  guard let session = snapshot.browserSessionID else { return false }
                  return (snapshot.allTabs ?? snapshot.tabs).contains { tab in
                      (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: tab.id) : tab.id) == target.anchorTabID
                          && (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: tab.windowID) : tab.windowID) == target.browserWindowID
                  }
              }), let session = owner.browserSessionID,
              let anchor = (owner.allTabs ?? owner.tabs).first(where: { tab in
                  (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: tab.id) : tab.id) == target.anchorTabID
              }) else { throw BrowserTabCreationError.changed }
        guard owner.guardEnabled == true, owner.guardCapabilities?.contains("native-website-finder-v1") == true else {
            throw BrowserTabCreationError.rejected("Update Browser Guard to use your real browser for website search.")
        }
        ownerSession = session; anchorID = anchor.id; windowID = anchor.windowID
        mailbox = BrowserFinderMailbox(browser: target.browserBundleIdentifier, session: session)
    }
    public func open(frame: BrowserWindowFrame) async throws -> BrowserFinderReceipt {
        guard !opened else { throw BrowserTabCreationError.uncertain }
        opened = true
        let receipt = try await request(.open, frame: frame)
        ownedWindowID = receipt.windowID; ownedTabID = receipt.tabID
        return receipt
    }
    public func commit() async throws -> BrowserTabItem {
        let receipt = try await request(.commit)
        guard var tab = receipt.tab else { throw BrowserTabCreationError.uncertain }
        let profiles = try currentProfiles()
        if profiles.count > 1 {
            tab.id = BrowserProfileSnapshots.compositeID(session: ownerSession, id: tab.id)
            tab.windowID = BrowserProfileSnapshots.compositeID(session: ownerSession, id: tab.windowID)
        }
        return tab
    }
    public func cancel() {
        guard opened, cancellationTask == nil else { return }
        let command = BrowserFinderCommand(finderID: finderID, action: .cancel, browserSessionID: ownerSession,
            windowID: windowID, anchorTabID: anchorID, finderWindowID: ownedWindowID, finderTabID: ownedTabID)
        // This task deliberately survives the cancelled open/commit/UI task.
        // It retains one cancellation command while the mailbox is contended.
        let mailbox = mailbox
        cancellationTask = Task {
            do { try await mailbox.writePending(command) }
            catch { /* The bounded delivery attempt retains the command until its deadline. */ }
        }
    }
    private func currentProfiles() throws -> [BrowserTabSnapshot] {
        let profiles = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: target.browserBundleIdentifier))
        guard BrowserProfileSnapshots.nonce(profiles) == target.browserSessionID,
              let owner = profiles.first(where: { $0.browserSessionID == ownerSession }), owner.guardEnabled == true,
              owner.guardCapabilities?.contains("native-website-finder-v1") == true else { throw BrowserTabCreationError.changed }
        // Idle snapshots may intentionally contain no rows. Only the extension
        // can recheck the exact anchor immediately before an effect. Absence in
        // this heartbeat-backed identity read is not proof of a closed window.
        return profiles
    }
    private func request(_ action: BrowserFinderCommand.Action, frame: BrowserWindowFrame? = nil) async throws -> BrowserFinderReceipt {
        try Self.assertInactive(); _ = try currentProfiles()
        let command = BrowserFinderCommand(finderID: finderID, action: action, browserSessionID: ownerSession,
            windowID: windowID, anchorTabID: anchorID, frame: frame,
            finderWindowID: ownedWindowID, finderTabID: ownedTabID)
        let url = BrowserFinderReceipt.fileURL(requestID: command.id)!
        defer { try? FileManager.default.removeItem(at: url) }
        try await mailbox.writePending(command)
        for _ in 0..<100 {
            guard !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
            try Self.assertInactive(); _ = try currentProfiles()
            if let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(BrowserFinderReceipt.self, from: data), receipt.matches(command) {
                if let error = receipt.error { throw BrowserTabCreationError.rejected(error) }
                return receipt
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserTabCreationError.uncertain
    }
    private static func assertInactive() throws {
        let url = ActiveBrowserRulesStore.defaultFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url), let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data), !rules.active else { throw BrowserTabCreationError.active }
    }
}
