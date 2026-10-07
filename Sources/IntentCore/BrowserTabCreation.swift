import Foundation
import Darwin

/// Creation has a separate small mailbox, so ordinary snapshots/previews cannot
/// overwrite a create or cancel. A lock serializes the app's enqueue with the
/// host's take; cancellation only replaces its own request, never a newer one.
public final class BrowserTabCreationMailbox {
    public let fileURL: URL
    private let session: String
    public init(browser: String, session: String, directory: URL = IntentEnvironment.dataDirectory) {
        let component = browser.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        fileURL = directory.appendingPathComponent("browser-create-\(String(component))-\(BrowserProfileSnapshots.component(session)).json")
        self.session = session
    }
    public func write(_ command: BrowserTabCommand) throws {
        guard UUID(uuidString: command.id) != nil, command.browserSessionID == session,
              command.action == .create || command.action == .cancelCreate else { throw BrowserTabCreationError.changed }
        try withQueue { rows in
            if let index = rows.firstIndex(where: { $0.id == command.id }) {
                if command.action == .cancelCreate { rows[index] = command }
            } else {
                guard rows.count < 32 else { throw BrowserTabCreationError.unavailable }
                rows.append(command)
            }
        }
    }
    public func take() -> BrowserTabCommand? {
        // The common idle path does not create a lock or write a file.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var result: BrowserTabCommand?
        do {
            try withQueue { rows in
                guard !rows.isEmpty else { return }
                let index = rows.firstIndex(where: { $0.action == .cancelCreate }) ?? 0
                result = rows.remove(at: index)
            }
            return result
        } catch {
            // Never deliver an effect that the durable queue still owns.
            return nil
        }
    }
    private func withQueue(_ edit: (inout [BrowserTabCommand]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BrowserTabCreationError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw BrowserTabCreationError.unavailable }
        defer { flock(fd, LOCK_UN) }
        let original: [BrowserTabCommand]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            original = try JSONDecoder().decode([BrowserTabCommand].self, from: Data(contentsOf: fileURL))
        } else { original = [] }
        guard original.count <= 32, original.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.browserSessionID == session
            && ($0.action == .create || $0.action == .cancelCreate) }) else { throw BrowserTabCreationError.changed }
        var rows = original
        try edit(&rows)
        if rows.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        } else if rows != original { try JSONEncoder().encode(rows).write(to: fileURL, options: .atomic) }
    }
}

public struct BrowserTabCreationReceipt: Codable, Equatable {
    public var requestID: String
    public var browserSessionID: String
    public var windowID: Int
    public var anchorTabID: Int
    public var url: String
    public var tab: BrowserTabItem?
    public var error: String?

    public func matches(_ command: BrowserTabCommand) -> Bool {
        guard command.action == .create, UUID(uuidString: requestID) != nil, requestID == command.id,
              browserSessionID == command.browserSessionID, windowID == command.windowID,
              anchorTabID == command.tabID, url == command.url,
              WebsiteFinderPolicy.validatedURL(url) != nil else { return false }
        if let tab { return error == nil && tab.id >= 0 && tab.id != anchorTabID && tab.windowID == windowID && !tab.active && WebsiteFinderPolicy.validatedURL(tab.url) != nil }
        return error.map { !$0.isEmpty && $0.utf8.count <= 1024 } == true
    }

    public static func fileURL(requestID: String, directory: URL = IntentEnvironment.dataDirectory) -> URL? {
        guard UUID(uuidString: requestID) != nil else { return nil }
        return directory.appendingPathComponent("browser-tab-created-\(requestID).json")
    }
}

public enum BrowserTabCreationError: LocalizedError {
    case unavailable, changed, active, invalidURL, cancelled, uncertain, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This Browser Guard cannot add tabs yet. Install the matching Intent Browser Guard update, then reopen the browser picker."
        case .changed: "The browser window or profile changed. Reopen its tab picker and try again."
        case .active: "Finish the running intention before adding a website."
        case .invalidURL: "Choose a valid http or https website address."
        case .cancelled: "Website selection was cancelled."
        case .uncertain: "The browser did not confirm the new tab. Check its tab list before trying again; Intent will not create a duplicate automatically."
        case .rejected(let detail): detail
        }
    }
}

/// A single bounded request. The browser owns tab creation; the app never opens
/// URLs through Launch Services, changes profile, or retries an uncertain effect.
@MainActor
public enum BrowserTabCreationService {
    public static func create(target: WebsiteFinderTarget, url: URL, requestID: String = UUID().uuidString,
                              isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserTabItem {
        guard UUID(uuidString: requestID) != nil, target.isValid, let destination = WebsiteFinderPolicy.validatedURL(url.absoluteString) else { throw BrowserTabCreationError.invalidURL }
        guard isCurrent(), !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
        try assertInactive()
        let browser = target.browserBundleIdentifier
        let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
        guard heartbeat.supports(.backgroundTabCreation, maxAge: 5),
              BrowserGuardStateStore(fileURL: BrowserGuardStateStore.fileURL(for: browser)).isEnabled() else { throw BrowserTabCreationError.unavailable }
        let profiles = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: browser))
        guard BrowserProfileSnapshots.nonce(profiles) == target.browserSessionID,
              let owner = profiles.first(where: { snapshot in
                  guard let session = snapshot.browserSessionID else { return false }
                  return (snapshot.allTabs ?? snapshot.tabs).contains { row in
                      (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: row.id) : row.id) == target.anchorTabID
                          && (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: row.windowID) : row.windowID) == target.browserWindowID
                  }
              }), let ownerSession = owner.browserSessionID else { throw BrowserTabCreationError.changed }
        guard owner.guardCapabilities?.contains(BrowserGuardCapability.backgroundTabCreation.rawValue) == true,
              owner.guardEnabled == true else { throw BrowserTabCreationError.unavailable }
        let rawAnchor = (owner.allTabs ?? owner.tabs).first { row in
            (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: ownerSession, id: row.id) : row.id) == target.anchorTabID
        }!
        let command = BrowserTabCommand(id: requestID, tabID: rawAnchor.id, windowID: rawAnchor.windowID, action: .create,
            browserSessionID: ownerSession, url: destination.absoluteString, expiresAtUnixMS: Date().timeIntervalSince1970 * 1000 + 8000)
        // Write to the resolved profile partition, never to a broadcast channel.
        let store = BrowserTabCreationMailbox(browser: browser, session: ownerSession)
        let receiptURL = BrowserTabCreationReceipt.fileURL(requestID: command.id)!
        defer { try? FileManager.default.removeItem(at: receiptURL) }
        try store.write(command)
        do {
            for _ in 0..<100 {
                guard isCurrent(), !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
                try assertInactive()
                let current = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: browser))
                guard BrowserProfileSnapshots.nonce(current) == target.browserSessionID,
                      let live = current.first(where: { $0.browserSessionID == ownerSession }),
                      (live.allTabs ?? live.tabs).contains(where: { $0.id == rawAnchor.id && $0.windowID == rawAnchor.windowID }) else { throw BrowserTabCreationError.changed }
                if let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(BrowserTabCreationReceipt.self, from: data), receipt.matches(command) {
                    if let error = receipt.error { throw BrowserTabCreationError.rejected(error) }
                    if var tab = receipt.tab {
                        if profiles.count > 1 {
                            tab.id = BrowserProfileSnapshots.compositeID(session: ownerSession, id: tab.id)
                            tab.windowID = BrowserProfileSnapshots.compositeID(session: ownerSession, id: tab.windowID)
                        }
                        return tab
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BrowserTabCreationError.uncertain
        } catch {
            var cancellation = command; cancellation.action = .cancelCreate
            try? store.write(cancellation)
            throw error
        }
    }

    private static func assertInactive() throws {
        let url = ActiveBrowserRulesStore.defaultFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url), let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data),
              !rules.active else { throw BrowserTabCreationError.active }
    }
}
