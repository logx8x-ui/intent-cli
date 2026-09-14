import AppKit
import Security

/// Only the installer creates this marker, after observing that Intent was removed.
/// Sparkle and development updates never create it.
@MainActor
enum IntentFreshInstallation {
    static func prepare() throws {
        try prepare(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".intent"), defaults: .standard, clearAccount: clearAccount)
    }
    static func prepare(root: URL, defaults: UserDefaults, clearAccount: () throws -> Void) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent("reset-on-next-launch")
        guard fm.fileExists(atPath: marker.path) else { return }
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard !["bin", "browser-guard", "reset-on-next-launch"].contains(file.lastPathComponent) else { continue }
            try fm.removeItem(at: file)
        }
        try clearAccount()
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        defaults.synchronize()
        try fm.removeItem(at: marker)
    }
    private static func clearAccount() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.loganmondi.intent.account", kSecUseDataProtectionKeychain as String: true]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn’t clear the previous Intent sign-in. Restart Intent to finish the fresh installation."])
        }
    }
}
