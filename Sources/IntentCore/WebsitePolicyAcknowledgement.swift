import Foundation

/// A capability is not an installation receipt. Each browser connection must
/// acknowledge this exact session after its network and page guards are ready.
public struct WebsitePolicyAcknowledgement: Codable {
    public var startupSessionID: String
    public var browserSessionID: String
    public var updatedAt: Date
    public init(startupSessionID: String, browserSessionID: String, updatedAt: Date = Date()) {
        self.startupSessionID = startupSessionID
        self.browserSessionID = browserSessionID
        self.updatedAt = updatedAt
    }
    public static func fileURL(browser: String, directory: URL = IntentEnvironment.dataDirectory) -> URL {
        let safe = browser.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent("website-policy-ack-\(String(safe)).json")
    }
    public static func isReady(browser: String, session: String, since: Date, directory: URL = IntentEnvironment.dataDirectory) -> Bool {
        let snapshot = directory.appendingPathComponent(BrowserTabSnapshotStore.fileURL(for: browser).lastPathComponent)
        let profiles = BrowserProfileSnapshots.sessions(base: snapshot)
        let base = fileURL(browser: browser, directory: directory)
        let files = profiles.isEmpty ? [base] : profiles.compactMap { $0.browserSessionID.map { BrowserProfileSnapshots.partition(base, session: $0) } }
        return !files.isEmpty && files.allSatisfy { file in
        guard let data = try? Data(contentsOf: file),
              let ack = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return ack.startupSessionID == session && !ack.browserSessionID.isEmpty && ack.updatedAt >= since
        }
    }
}
