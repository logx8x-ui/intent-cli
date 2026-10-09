import Foundation
import CryptoKit

/// Native tab/window IDs are only unique inside one browser profile. Keep raw
/// snapshots partitioned and expose stable composite IDs to the app when two
/// profiles are connected. The extension continues to receive its native IDs.
public enum BrowserProfileSnapshots {
    public static func component(_ session: String) -> String {
        SHA256.hash(data: Data(session.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    public static func compositeID(session: String, id: Int) -> Int {
        // 48 bits are exact in both Swift Int and JavaScript Number.
        SHA256.hash(data: Data("\(session):\(id)".utf8)).prefix(6).reduce(0) { ($0 << 8) | Int($1) }
    }
    public static func partition(_ base: URL, session: String) -> URL {
        base.deletingPathExtension().appendingPathExtension("profile-\(component(session)).json")
    }
    public static func coveragePartition(_ base: URL, session: String) -> URL {
        base.deletingPathExtension().appendingPathExtension("coverage-profile-\(component(session)).json")
    }
    public static func discoveryPartition(_ base: URL, session: String) -> URL {
        base.deletingPathExtension().appendingPathExtension("discovery-profile-\(component(session)).json")
    }
    /// A heartbeat from one profile, or a newer merged timestamp from another,
    /// cannot prove that a saved tab is absent. Require this owner's exact query.
    public static func isDiscoveryReply(_ reply: BrowserTabSnapshot, owner: BrowserTabSnapshot,
                                        requestID: String, requestedAt: Date, now: Date = Date()) -> Bool {
        guard !requestID.isEmpty, requestID.utf8.count <= 256,
              let session = owner.browserSessionID, !session.isEmpty,
              reply.browserSessionID == session, reply.browserProfileID == owner.browserProfileID,
              reply.browserBundleIdentifier == owner.browserBundleIdentifier,
              reply.profileDiscoveryRequestIDs?.contains(requestID) == true,
              let rows = reply.allTabs, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.id >= 0 && $0.windowID >= 0 }),
              reply.updatedAt >= requestedAt else { return false }
        let age = now.timeIntervalSince(reply.updatedAt)
        return age >= -0.25 && age <= 3
    }
    public static func sessions(base: URL, now: Date = Date()) -> [BrowserTabSnapshot] {
        let prefix = base.deletingPathExtension().lastPathComponent + ".profile-"
        let files = (try? FileManager.default.contentsOfDirectory(at: base.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.compactMap { file in
            guard let heartbeat = try? Data(contentsOf: file.appendingPathExtension("heartbeat")),
                  let seen = try? JSONDecoder().decode(Date.self, from: heartbeat), now.timeIntervalSince(seen) <= 6,
                  let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
                  let session = snapshot.browserSessionID, !session.isEmpty else { return nil }
            return snapshot
        }.sorted { ($0.browserSessionID ?? "") < ($1.browserSessionID ?? "") }
    }
    /// Coverage must not borrow heartbeat freshness or another discovery reply.
    /// Returns immutable correlated candidates. Callers must revalidate with
    /// isCoverageSnapshotCurrent AFTER their post-reply native observation;
    /// this lets contradicted candidates trigger a bounded fresh query.
    public static func coverageSnapshots(base: URL, requestID: String, now: Date = Date()) -> [BrowserTabSnapshot] {
        guard !requestID.isEmpty, requestID.utf8.count <= 256 else { return [] }
        return sessions(base: base, now: now).compactMap { current in
            guard let profile = current.browserSessionID,
                  let data = try? Data(contentsOf: coveragePartition(base, session: profile)),
                  let snapshot = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
                  snapshot.snapshotRequestIDs?.contains(requestID) == true,
                  validCoverageSnapshot(snapshot, current: current, now: now, checkPositiveChanges: false) else { return nil }
            return snapshot
        }
    }
    /// Recheck the immutable reply AFTER native observation. A newer sidecar
    /// cannot replace the latched reply: its query may have begun after that scan.
    public static func isCoverageSnapshotCurrent(_ snapshot: BrowserTabSnapshot, base: URL, now: Date = Date()) -> Bool {
        guard let current = sessions(base: base, now: now).first(where: { $0.browserSessionID == snapshot.browserSessionID }) else { return false }
        return validCoverageSnapshot(snapshot, current: current, now: now)
    }
    private static func validCoverageSnapshot(_ snapshot: BrowserTabSnapshot, current: BrowserTabSnapshot, now: Date,
                                              checkPositiveChanges: Bool = true) -> Bool {
        guard let profile = snapshot.browserSessionID, !profile.isEmpty, current.browserSessionID == profile,
              snapshot.browserBundleIdentifier == current.browserBundleIdentifier,
              let proof = snapshot.browserProcessIdentity, proof.isValid, proof == current.browserProcessIdentity,
              let requests = snapshot.snapshotRequestIDs, !requests.isEmpty, requests.count <= 16,
              let complete = snapshot.allTabs, snapshot.completeWindowInventory == true,
              snapshot.guardEnabled == true, current.guardEnabled == true,
              snapshot.guardCapabilities?.contains(BrowserGuardCapability.nativeWindowVisibility.rawValue) == true,
              current.guardCapabilities?.contains(BrowserGuardCapability.nativeWindowVisibility.rawValue) == true else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -0.25 && age <= 3 else { return false }
        // Ordinary snapshots do not certify completeness. Positive changed
        // rows can invalidate an older proof, but absent/idle rows prove nothing.
        guard checkPositiveChanges, current.updatedAt >= snapshot.updatedAt else { return true }
        guard Set(complete.map(\.id)).count == complete.count else { return false }
        let previous = Dictionary(uniqueKeysWithValues: complete.map { ($0.id, $0) })
        let positive = current.allTabs ?? current.tabs
        guard Set(positive.map(\.id)).count == positive.count else { return false }
        return positive.allSatisfy { row in
            guard let before = previous[row.id], row.windowID == before.windowID, row.active == before.active else { return false }
            if row.active && row.title != before.title { return false }
            if let frame = row.windowFrame, frame != before.windowFrame { return false }
            return true
        }
    }

    /// Resolve selected IDs using the same one-profile/composite representation
    /// shown to the user. A partial profile reply cannot reinterpret those IDs.
    public static func selectedCoverageWindows(snapshots: [BrowserTabSnapshot], browser: String,
                                              expectedSession: String, selectedTabIDs: [Int]) -> Set<BrowserWindowCoveragePolicy.ReportedIdentity>? {
        guard !selectedTabIDs.isEmpty, Set(selectedTabIDs).count == selectedTabIDs.count,
              nonce(snapshots) == expectedSession,
              Set(snapshots.compactMap(\.browserSessionID)).count == snapshots.count,
              snapshots.allSatisfy({ $0.browserBundleIdentifier == browser && $0.allTabs != nil }) else { return nil }
        var rows: [Int: BrowserWindowCoveragePolicy.ReportedIdentity] = [:]
        for snapshot in snapshots {
            guard let profile = snapshot.browserSessionID, !profile.isEmpty else { return nil }
            for tab in snapshot.allTabs ?? [] {
                let id = snapshots.count > 1 ? compositeID(session: profile, id: tab.id) : tab.id
                guard tab.id >= 0, tab.windowID >= 0, rows[id] == nil else { return nil }
                rows[id] = .init(bundleIdentifier: browser, browserSessionID: profile, windowID: tab.windowID)
            }
        }
        let selected = selectedTabIDs.compactMap { rows[$0] }
        guard selected.count == selectedTabIDs.count else { return nil }
        return Set(selected)
    }

    /// Overview Run may activate an existing browser parent, but a bundle ID
    /// alone cannot choose it when two profiles have separate parent processes.
    /// Bind both selected IDs to the native host's exact process lifetime proof.
    public static func selectedProcess(snapshots: [BrowserTabSnapshot], browser: String,
                                       expectedSession: String, tabID: Int, windowID: Int,
                                       liveProcesses: [BrowserProcessIdentity]) -> BrowserProcessIdentity? {
        guard !expectedSession.isEmpty, tabID >= 0, windowID >= 0,
              !snapshots.isEmpty, nonce(snapshots) == expectedSession,
              Set(snapshots.compactMap(\.browserSessionID)).count == snapshots.count,
              snapshots.allSatisfy({ $0.browserBundleIdentifier == browser }) else { return nil }
        var matches: [BrowserProcessIdentity] = []
        for snapshot in snapshots {
            guard let session = snapshot.browserSessionID else { return nil }
            for row in snapshot.allTabs ?? snapshot.tabs {
                let composite = snapshots.count > 1
                guard (composite ? compositeID(session: session, id: row.id) : row.id) == tabID,
                      (composite ? compositeID(session: session, id: row.windowID) : row.windowID) == windowID else { continue }
                guard snapshot.guardEnabled == true,
                      let proof = snapshot.browserProcessIdentity, proof.isValid,
                      liveProcesses.filter({ $0 == proof }).count == 1,
                      liveProcesses.filter({ $0.pid == proof.pid }).count == 1 else { return nil }
                matches.append(proof)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func nonce(_ snapshots: [BrowserTabSnapshot]) -> String? {
        let sessions = snapshots.compactMap(\.browserSessionID).sorted()
        if sessions.count == 1 { return sessions.first }
        return sessions.isEmpty ? nil : "profiles:" + sessions.joined(separator: "|")
    }
    public static func merged(_ snapshots: [BrowserTabSnapshot]) -> BrowserTabSnapshot? {
        guard let first = snapshots.first else { return nil }
        if snapshots.count == 1 { return first }
        func rows(_ snapshot: BrowserTabSnapshot, all: Bool) -> [BrowserTabItem] {
            (all ? snapshot.allTabs ?? snapshot.tabs : snapshot.tabs).map { item in
                var item = item
                item.id = compositeID(session: snapshot.browserSessionID!, id: item.id)
                item.windowID = compositeID(session: snapshot.browserSessionID!, id: item.windowID)
                return item
            }
        }
        return BrowserTabSnapshot(browserBundleIdentifier: first.browserBundleIdentifier,
            browserSessionID: nonce(snapshots), tabs: snapshots.flatMap { rows($0, all: false) },
            updatedAt: snapshots.map(\.updatedAt).max() ?? Date(), allTabs: snapshots.flatMap { rows($0, all: true) })
    }
}
