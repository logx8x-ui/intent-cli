import Foundation

/// Staged tab marks use their own correlated discovery. An ordinary idle
/// placeholder or a receipt for another reader cannot erase or renew a mark.
public enum WorkspaceOutlineInventory {
    public struct Response {
        public let snapshot: BrowserTabSnapshot
        public let profiles: [BrowserTabSnapshot]

        /// Preserve the aggregate ID namespace, but never match a native
        /// window against rows owned by a different browser parent process.
        public func tabs(for process: BrowserProcessIdentity) -> [BrowserTabItem] {
            profiles.filter { $0.browserProcessIdentity == process }.flatMap { profile in
                guard let session = profile.browserSessionID else { return [BrowserTabItem]() }
                return (profile.allTabs ?? []).map { row in
                    var row = row
                    if profiles.count > 1 {
                        row.id = BrowserProfileSnapshots.compositeID(session: session, id: row.id)
                        row.windowID = BrowserProfileSnapshots.compositeID(session: session, id: row.windowID)
                    }
                    return row
                }
            }
        }

        /// Native Firefox sidebar DOM IDs stay raw even when Intent shows
        /// composite IDs for multiple profiles. Resolve the exact profile first.
        public func nativeWindow(id: Int, selectedIDs: Set<Int>, process: BrowserProcessIdentity) -> (tabs: [BrowserTabItem], selected: Set<Int>)? {
            let matches = profiles.compactMap { profile -> (tabs: [BrowserTabItem], selected: Set<Int>)? in
                guard profile.browserProcessIdentity == process,
                      let session = profile.browserSessionID else { return nil }
                let tabs = (profile.allTabs ?? []).filter {
                    (profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: $0.windowID) : $0.windowID) == id
                }
                guard !tabs.isEmpty else { return nil }
                let selected = Set(tabs.filter {
                    selectedIDs.contains(profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: $0.id) : $0.id)
                }.map(\.id))
                return (tabs, selected)
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }
    public struct Request {
        public let id: String
        public let requestedAt: Date
        public let browser: String
        public let expectedSession: String
        public let owners: [BrowserTabSnapshot]

        public init?(browser: String, expectedSession: String, owners: [BrowserTabSnapshot],
                     processes: [BrowserProcessIdentity], id: String = UUID().uuidString, now: Date = Date()) {
            guard !id.isEmpty, id.utf8.count <= 256, Self.validProcesses(processes),
                  !owners.isEmpty, BrowserProfileSnapshots.nonce(owners) == expectedSession,
                  Set(owners.compactMap(\.browserSessionID)).count == owners.count,
                  owners.allSatisfy({ owner in
                      guard owner.browserBundleIdentifier == browser, owner.guardEnabled == true,
                            let process = owner.browserProcessIdentity, process.isValid else { return false }
                      return processes.contains(process)
                  }) else { return nil }
            self.id = id; self.requestedAt = now; self.browser = browser
            self.expectedSession = expectedSession; self.owners = owners
        }

        private static func validProcesses(_ processes: [BrowserProcessIdentity]) -> Bool {
            !processes.isEmpty && processes.allSatisfy(\.isValid)
                && Set(processes.map(\.pid)).count == processes.count
        }

        public func isCurrent(owners current: [BrowserTabSnapshot], processes: [BrowserProcessIdentity]) -> Bool {
            Self.validProcesses(processes) && current.count == owners.count
                && BrowserProfileSnapshots.nonce(current) == expectedSession
                && owners.allSatisfy { owner in
                    guard let process = owner.browserProcessIdentity, processes.contains(process) else { return false }
                    return current.contains { candidate in
                    candidate.browserSessionID == owner.browserSessionID
                        && candidate.browserProfileID == owner.browserProfileID
                        && candidate.browserBundleIdentifier == browser
                        && candidate.guardEnabled == true && candidate.browserProcessIdentity == process
                } }
        }

        public var commands: [BrowserTabCommand] {
            owners.map { BrowserTabCommand(id: id, tabID: -1, windowID: -1, createdAt: requestedAt,
                action: .snapshot, browserSessionID: $0.browserSessionID) }
        }

        public func resolve(replies: [BrowserTabSnapshot], current: [BrowserTabSnapshot],
                            processes: [BrowserProcessIdentity], now: Date = Date()) -> Response? {
            guard isCurrent(owners: current, processes: processes), replies.count == owners.count,
                  Set(replies.compactMap(\.browserSessionID)).count == owners.count else { return nil }
            for owner in owners {
                guard let reply = replies.first(where: { $0.browserSessionID == owner.browserSessionID }),
                      reply.browserProcessIdentity == owner.browserProcessIdentity,
                      BrowserProfileSnapshots.isDiscoveryReply(reply, owner: owner, requestID: id,
                          requestedAt: requestedAt, now: now) else { return nil }
            }
            guard let snapshot = BrowserProfileSnapshots.merged(replies),
                  Set((snapshot.allTabs ?? []).map(\.id)).count == snapshot.allTabs?.count else { return nil }
            return Response(snapshot: snapshot, profiles: replies)
        }
    }

    /// During one read-only query retain only recently confirmed inventory for
    /// the exact selection/profile/process context. Geometry has its additional
    /// native-window/frame fence in WorkspaceOutlineController.
    public struct Continuity {
        private var context = ""
        private var confirmed: Response?
        private var confirmedAt = Date.distantPast
        public init() {}

        public mutating func update(_ snapshot: Response?, context: String,
                                    authoritative: Bool, now: Date) -> Response? {
            if self.context != context { confirmed = nil; confirmedAt = .distantPast }
            self.context = context
            if authoritative {
                confirmed = snapshot
                confirmedAt = now
            }
            guard now.timeIntervalSince(confirmedAt) >= 0, now.timeIntervalSince(confirmedAt) < 0.6 else {
                confirmed = nil
                return nil
            }
            return confirmed
        }
    }
}
