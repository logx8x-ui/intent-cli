import Foundation

/// Persist the Run attempt before asking a browser to create anything. A missing
/// receipt is an uncertain effect, never permission to issue a new request ID.
/// Existing tabs can still be selected manually and run without creating tabs.
public final class SavedWorkspaceRestoreClaims {
    public struct Request: Codable, Equatable {
        public let requestID: String
        public let sourceID: String
        public let descriptorIndex: Int
        public let browser: String
        public let profileID: String?
        public let sessionID: String
        public let url: String
    }
    public let fileURL: URL
    public init(fileURL: URL = IntentEnvironment.dataDirectory.appendingPathComponent("saved-workspace-restore-claims.json")) {
        self.fileURL = fileURL
    }
    private func load() throws -> [Request] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Request].self, from: Data(contentsOf: fileURL))
    }
    public func begin(sourceID: String, tabs: [SessionWorkspace.PendingTab]) throws -> [Request] {
        guard !sourceID.isEmpty, !tabs.isEmpty else { return [] }
        var requests = try load()
        guard !requests.contains(where: { $0.sourceID == sourceID }) else { throw BrowserTabCreationError.uncertain }
        let new = tabs.map { pending in
            Request(requestID: UUID().uuidString, sourceID: sourceID, descriptorIndex: pending.descriptorIndex,
                    browser: pending.descriptor.browser, profileID: pending.descriptor.profileID,
                    sessionID: pending.ownerSessionID, url: pending.descriptor.url)
        }
        requests.append(contentsOf: new)
        try save(requests)
        return new
    }
    /// Only after every selected/created tab has a fresh confirmed identity and
    /// its replay binding has been saved may another future Run restore it again.
    public func complete(sourceID: String) throws {
        var requests = try load()
        requests.removeAll { $0.sourceID == sourceID }
        try save(requests)
    }
    private func save(_ requests: [Request]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(requests).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
