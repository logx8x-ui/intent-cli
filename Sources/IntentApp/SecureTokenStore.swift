import Foundation
import LocalAuthentication
import Security
import IntentCore

enum SecureTokenStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))."
        }
    }
}

final class KeychainTokenStore: SecureTokenStoring {
    private let service: String

    init(service: String = "dev.loganmondi.intent.calendar.v3") {
        self.service = service
    }

    func save(account: String, data: Data) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(
            noninteractive(identity) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecureTokenStoreError.unexpectedStatus(updateStatus)
        }

        let query: [String: Any] = identity.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureTokenStoreError.unexpectedStatus(status)
        }
    }

    func load(account: String) throws -> Data? {
        let query = noninteractive([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ])
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureTokenStoreError.unexpectedStatus(status)
        }
        return item as? Data
    }

    func delete(account: String) throws {
        let query = noninteractive([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess
            || status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed else {
            throw SecureTokenStoreError.unexpectedStatus(status)
        }
    }

    private func noninteractive(_ query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
