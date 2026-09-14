import Foundation

@main
struct FreshInstallSpec {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("IntentFreshInstall-" + UUID().uuidString)
        let suite = "IntentFreshInstallSpec." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let saved = root.appendingPathComponent("intentions.json")
        let marker = root.appendingPathComponent("reset-on-next-launch")
        try Data("saved intention".utf8).write(to: saved)
        defaults.set(true, forKey: "intentDidCompleteOnboarding")
        var signOutCount = 0
        try IntentFreshInstallation.prepare(root: root, defaults: defaults) { signOutCount += 1 }
        precondition(fm.fileExists(atPath: saved.path) && defaults.bool(forKey: "intentDidCompleteOnboarding") && signOutCount == 0, "Updates must preserve local data and sign-in")
        try Data().write(to: marker)
        try IntentFreshInstallation.prepare(root: root, defaults: defaults) { signOutCount += 1 }
        precondition(!fm.fileExists(atPath: saved.path) && !defaults.bool(forKey: "intentDidCompleteOnboarding") && signOutCount == 1, "Reinstall must reset data, onboarding and sign-in")
        precondition(fm.fileExists(atPath: root.appendingPathComponent("bin").path) && !fm.fileExists(atPath: marker.path))
        try Data().write(to: marker)
        do {
            try IntentFreshInstallation.prepare(root: root, defaults: defaults) { throw NSError(domain: "test", code: 1) }
            preconditionFailure("Reset failure must propagate")
        } catch {}
        precondition(fm.fileExists(atPath: marker.path), "An incomplete reset must retry on next launch")
        print("Fresh-install reset and update preservation spec passed")
    }
}
