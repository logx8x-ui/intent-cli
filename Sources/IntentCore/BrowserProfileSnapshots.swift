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
