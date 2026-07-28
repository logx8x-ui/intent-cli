import Foundation

public protocol SecureTokenStoring: AnyObject {
    func save(account: String, data: Data) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

public final class InMemoryTokenStore: SecureTokenStoring {
    private var storage: [String: Data] = [:]

    public init() {}

    public func save(account: String, data: Data) throws {
        storage[account] = data
    }

    public func load(account: String) throws -> Data? {
        storage[account]
    }

    public func delete(account: String) throws {
        storage.removeValue(forKey: account)
    }
}

public struct OAuthTokenSet: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-60) <= Date()
    }
}

public final class OAuthTokenVault {
    private let store: SecureTokenStoring
    private let account: String

    public init(store: SecureTokenStoring, account: String) {
        self.store = store
        self.account = account
    }

    public func save(_ tokens: OAuthTokenSet) throws {
        let data = try JSONEncoder().encode(tokens)
        try store.save(account: account, data: data)
    }

    public func load() throws -> OAuthTokenSet? {
        guard let data = try store.load(account: account) else { return nil }
        return try JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    public func clear() throws {
        try store.delete(account: account)
    }
}
