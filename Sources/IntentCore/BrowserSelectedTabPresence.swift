import Foundation

/// Ordinary snapshots can contain an empty idle placeholder. Only a new,
/// correlated full inventory may prove that every selected tab has closed.
public struct BrowserSelectedTabPresenceCheck {
    public enum Result: Equatable { case pending, present, closed, changed }
    private struct Query {
        let owner: BrowserTabSnapshot
        let command: BrowserTabCommand
    }
    private let browser: String
    private let expectedSession: String
    private let selectedIDs: Set<Int>
    private let snapshotURL: URL
    private let commandURL: URL
    private let requestedAt: Date
    private let queries: [Query]

    public init?(browser: String, expectedSession: String, selectedIDs: [Int],
                 snapshotURL: URL? = nil, commandURL: URL? = nil, now: Date = Date()) {
        let snapshotURL = snapshotURL ?? BrowserTabSnapshotStore.fileURL(for: browser)
        let owners = BrowserProfileSnapshots.sessions(base: snapshotURL, now: now)
        guard !selectedIDs.isEmpty, !expectedSession.isEmpty,
              BrowserProfileSnapshots.nonce(owners) == expectedSession,
              owners.allSatisfy({ $0.browserBundleIdentifier == browser }),
              Set(owners.compactMap(\.browserSessionID)).count == owners.count else { return nil }
        self.browser = browser; self.expectedSession = expectedSession
        self.selectedIDs = Set(selectedIDs); self.snapshotURL = snapshotURL
        self.commandURL = commandURL ?? BrowserTabCommandStore.fileURL(for: browser)
        self.requestedAt = now
        self.queries = owners.map { owner in
            Query(owner: owner, command: BrowserTabCommand(tabID: -1, windowID: -1, action: .snapshot,
                browserSessionID: owner.browserSessionID))
        }
    }

    public static func commandFileURL(base: URL, session: String) -> URL {
        base.deletingPathExtension().appendingPathExtension("presence-profile-\(BrowserProfileSnapshots.component(session)).json")
    }

    public func request() throws {
        for query in queries {
            let path = Self.commandFileURL(base: commandURL, session: query.owner.browserSessionID!)
            try JSONEncoder().encode(query.command).write(to: path, options: .atomic)
        }
    }

    public func poll(now: Date = Date()) -> Result {
        let current = BrowserProfileSnapshots.sessions(base: snapshotURL, now: now)
        guard current.count == queries.count, BrowserProfileSnapshots.nonce(current) == expectedSession,
              queries.allSatisfy({ query in current.contains { owner in
                  owner.browserSessionID == query.owner.browserSessionID
                      && owner.browserProfileID == query.owner.browserProfileID
                      && owner.browserBundleIdentifier == browser
              } }) else { return .changed }
        var replies: [BrowserTabSnapshot] = []
        for query in queries {
            let path = BrowserProfileSnapshots.discoveryPartition(snapshotURL, session: query.owner.browserSessionID!)
            guard let data = try? Data(contentsOf: path),
                  let reply = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
                  BrowserProfileSnapshots.isDiscoveryReply(reply, owner: query.owner,
                    requestID: query.command.id, requestedAt: requestedAt, now: now) else { return .pending }
            replies.append(reply)
        }
        // All owners must reply before absence has meaning. Reuse the same ID
        // representation as selection: native for one owner, composite for many.
        guard let snapshot = BrowserProfileSnapshots.merged(replies) else { return .pending }
        return (snapshot.allTabs ?? []).contains { selectedIDs.contains($0.id) } ? .present : .closed
    }
}
