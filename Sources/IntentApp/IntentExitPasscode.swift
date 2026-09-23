import AppKit
import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import IntentLock

/// Local friction credential, separate from sign-in. Safety Stop never consults it.
@MainActor
enum IntentExitPasscode {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "dev.loganmondi.intent") + ".exit-passcode",
        kSecAttrAccount as String: "local-exit"] }
    private static func credential() -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static var isConfigured: Bool { credential() != nil }
    private static func random(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
    private static func digest(_ passcode: String, salt: Data) -> Data {
        var data = salt + Data(passcode.utf8)
        for _ in 0..<10_000 { data = Data(SHA256.hash(data: data)) }
        return data
    }
    static func offerOnce() {
        guard !isConfigured, !UserDefaults.standard.bool(forKey: "exitPasscodeOffered") else { return }
        configure()
        UserDefaults.standard.set(true, forKey: "exitPasscodeOffered")
    }
    static func configure() {
        guard !isConfigured else { return }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        guard let entropy = random(24) else { return }
        let suggestions = stride(from: 0, to: 24, by: 8).map { index in String(entropy[index..<index+8].map { alphabet[Int($0) % alphabet.count] }) }
        let alert = NSAlert()
        alert.messageText = "Exit passcode · Strongly recommended"
        alert.informativeText = "Use a suggestion or choose your own (at least 6 characters). Write it in a notebook. This lets you deliberately leave a locked session early. Safety Stop always remains available."
        alert.addButton(withTitle: "Save passcode"); alert.addButton(withTitle: "Not now")
        let view = NSView(frame: .init(x: 0, y: 0, width: 370, height: 114))
        let label = NSTextField(labelWithString: suggestions.joined(separator: "     "))
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium); label.frame = .init(x: 0, y: 88, width: 370, height: 22)
        let field = NSSecureTextField(frame: .init(x: 0, y: 48, width: 370, height: 26)); field.placeholderString = "Suggested or custom passcode"
        let confirmation = NSSecureTextField(frame: .init(x: 0, y: 8, width: 370, height: 26)); confirmation.placeholderString = "Enter again to confirm"
        [label, field, confirmation].forEach(view.addSubview); alert.accessoryView = view
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1); alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            guard field.stringValue.count >= 6, field.stringValue == confirmation.stringValue else {
                alert.messageText = "Use 6+ characters and enter the same passcode twice"; continue
            }
            guard let salt = random(32) else { return }
            var q = query; q[kSecValueData as String] = salt + digest(field.stringValue, salt: salt)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return }
            alert.messageText = "Could not save in Keychain. Try again." 
        }
    }
    private static var authorizationPanel: NSPanel?
    private static var previousApplication: NSRunningApplication?
    private static var authorizationCompletion: ((Bool) -> Void)?
    static func cancelAuthorization() { completeAuthorization(false) }
    private static func completeAuthorization(_ result: Bool) {
        authorizationPanel?.orderOut(nil); authorizationPanel = nil
        let previous = previousApplication; previousApplication = nil
        if !result { previous?.activate(options: [.activateIgnoringOtherApps]) }
        let completion = authorizationCompletion; authorizationCompletion = nil
        completion?(result)
    }
    static func authorize(title: String) async -> Bool {
        guard authorizationCompletion == nil, let stored = credential(), stored.count == 64 else { return false }
        previousApplication = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { continuation in
            authorizationCompletion = { continuation.resume(returning: $0) }
            let panel = IntentInteractivePanel(contentRect: .init(x: 0, y: 0, width: 420, height: 245), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Intent"; panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            panel.contentView = NSHostingView(rootView: IntentPasscodeEntry(title: title, verify: { value in
                let candidate = digest(value, salt: stored.prefix(32))
                return zip(candidate, stored.suffix(32)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            }, finish: completeAuthorization).preferredColorScheme(.dark))
            authorizationPanel = panel; panel.center()
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        }
    }
    static func reset() async -> Bool {
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reset your Intent exit passcode") else { return false }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                UserDefaults.standard.set(false, forKey: "exitPasscodeOffered"); return true
            }
        } catch { }
        return false
    }
}

private struct IntentPasscodeEntry: View {
    let title: String
    let verify: (String) -> Bool
    let finish: (Bool) -> Void
    @State private var value = ""
    @State private var failed = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            Text("Enter your Intent exit passcode. Your work can be resumed later.").font(.callout).foregroundStyle(.secondary)
            SecureField("Exit passcode", text: $value).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
            if failed { Text("That passcode did not match.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Keep working") { finish(false) }.keyboardShortcut(.cancelAction)
                Spacer(); Button("End now", action: submit).buttonStyle(.borderedProminent).tint(.green)
            }
        }.padding(24).frame(width: 420).onAppear { focused = true }
    }
    private func submit() { if verify(value) { finish(true) } else { value = ""; failed = true } }
}
