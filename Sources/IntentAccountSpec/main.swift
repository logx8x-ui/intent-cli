import Foundation
import IntentCore

private enum AccountSpecFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AccountSpecFailure.failed(message) }
}

private func runAccountSpecs() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("IntentAccountSpec-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let guest = IntentProfilePaths.guestDirectory(homeDirectory: home)
    let firstAccount = IntentProfilePaths.accountDirectory(
        userID: "FIRST-USER",
        homeDirectory: home
    )
    let secondAccount = IntentProfilePaths.accountDirectory(
        userID: "SECOND/USER",
        homeDirectory: home
    )

    try expect(guest != firstAccount, "Guest and account profiles must be isolated.")
    try expect(firstAccount != secondAccount, "Different accounts must use different profiles.")
    try expect(
        secondAccount.lastPathComponent == "SECOND_USER",
        "Account identifiers must be converted into safe path components."
    )

    let newAccountWorkspace = IntentAccountWorkspace()
    try expect(newAccountWorkspace.intentions.isEmpty, "A new account must start with zero intentions.")
    try expect(newAccountWorkspace.schedules.isEmpty, "A new account must start with zero schedules.")

    let preferences = IntentPortablePreferences(
        appearance: "light",
        welcomeTitle: "My focused Mac",
        backgroundSelection: "custom",
        didCompleteOnboarding: true,
        zeroDriftWarningSuppressed: true,
        purposeModeEnabled: true,
        requireManualFinishBeforeSwitching: false,
        overlayShortcutData: Data([1, 2, 3]),
        finishShortcutData: Data([4, 5, 6])
    )
    let original = IntentAccountWorkspace(
        preferences: preferences,
        customBackgroundPNG: Data([137, 80, 78, 71]),
        updatedAt: Date(timeIntervalSince1970: 123_456)
    )
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(IntentAccountWorkspace.self, from: data)
    try expect(restored == original, "Synced account workspaces must round-trip without data loss.")

    let legacyData = Data(#"{"intentions":[],"schedules":[]}"#.utf8)
    let legacyWorkspace = try JSONDecoder().decode(IntentAccountWorkspace.self, from: legacyData)
    try expect(
        legacyWorkspace.schemaVersion == 1 && legacyWorkspace.intentions.isEmpty,
        "Older cloud workspaces must remain readable after account schema changes."
    )
    try expect(
        legacyWorkspace.preferences.requireManualFinishBeforeSwitching,
        "Missing preference fields must use safe defaults instead of breaking account loading."
    )

    let older = IntentAccountWorkspace(updatedAt: Date(timeIntervalSince1970: 100))
    let newer = IntentAccountWorkspace(updatedAt: Date(timeIntervalSince1970: 200))
    try expect(
        IntentWorkspaceResolver.resolve(local: newer, remote: older) == .uploadLocal,
        "A newer offline edit must upload instead of being overwritten."
    )
    try expect(
        IntentWorkspaceResolver.resolve(local: older, remote: newer) == .useRemote,
        "A newer cloud edit must refresh the local account workspace."
    )
    try expect(
        IntentWorkspaceResolver.resolve(local: nil, remote: nil) == .createEmpty,
        "A first-time account must create one empty cloud workspace."
    )
    try expect(
        IntentOfflineAccountPolicy.canActivate(cachedWorkspace: newer),
        "A known account workspace must remain available while its Mac is offline."
    )
    try expect(
        !IntentOfflineAccountPolicy.canActivate(cachedWorkspace: nil),
        "A fresh offline device must not invent an empty account that could overwrite cloud data."
    )

    let accountIntentions = IntentProfilePaths.intentionsURL(in: firstAccount)
    let guestIntentions = IntentProfilePaths.intentionsURL(in: guest)
    try expect(
        accountIntentions.path.hasPrefix(firstAccount.path),
        "Account intention storage must stay inside its account profile."
    )
    try expect(
        guestIntentions.path.hasPrefix(guest.path),
        "Guest intention storage must stay inside the guest profile."
    )

    try expect(
        IntentAccountCallbackKind.classify(URL(string: "intent://auth-callback?code=test")!) == .authentication,
        "Email confirmation and OAuth callbacks must route to account authentication."
    )
    try expect(
        IntentAccountCallbackKind.classify(URL(string: "INTENT://password-reset?code=test")!) == .passwordReset,
        "Password reset callbacks must be recognised case-insensitively."
    )
    try expect(
        IntentAccountCallbackKind.classify(URL(string: "intent://unrelated")!) == nil,
        "Unrelated Intent deep links must not be consumed by account authentication."
    )
    try expect(
        IntentAccountCallbackKind.classify(URL(string: "https://auth-callback")!) == nil,
        "Web URLs must not be mistaken for Intent account callbacks."
    )
}

do {
    try runAccountSpecs()
    print("IntentAccountSpec passed")
} catch {
    fputs("IntentAccountSpec failed: \(error)\n", stderr)
    exit(1)
}
