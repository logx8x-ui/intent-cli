import AppKit
import IntentCore

@MainActor
final class SpotlightAppPreparation {
    static let shared = SpotlightAppPreparation()
    private struct OwnedApp: Codable { let bundle: String; let pid: pid_t; let launchDate: Date? }
    private var owned: [OwnedApp] = []
    private var pending: [String: UUID] = [:]
    private let ledger = IntentEnvironment.dataDirectory.appendingPathComponent("spotlight-prepared-apps.json")

    func recover() {
        owned = (try? JSONDecoder().decode([OwnedApp].self, from: Data(contentsOf: ledger))) ?? []
        release()
    }
    func prepare(_ url: URL, completion: @escaping (String?) -> Void) {
        guard let bundle = Bundle(url: url)?.bundleIdentifier else { completion("That Spotlight result is not an application."); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { completion(nil); return }
        guard pending[bundle] == nil else { return }
        let token = UUID(); pending[bundle] = token
        let previous = NSWorkspace.shared.frontmostApplication
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false; config.hides = true; config.hidesOthers = false
        config.addsToRecentItems = false; config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                let cancelled = self.pending[bundle] != token
                if !cancelled { self.pending.removeValue(forKey: bundle) }
                guard let app, error == nil else { completion("Could not prepare \(url.deletingPathExtension().lastPathComponent). Try opening it normally before selecting it."); return }
                guard !cancelled else { if app.isHidden { app.unhide() }; completion(nil); return }
                let stoleFocus = app.isActive
                guard app.isHidden || app.hide() else {
                    if stoleFocus { previous?.activate(options: []) }
                    completion("macOS could not keep this app in the background. Turn background opening off in Settings and open it normally before selecting it.")
                    return
                }
                if stoleFocus { previous?.activate(options: []) }
                self.owned.append(.init(bundle: bundle, pid: app.processIdentifier, launchDate: app.launchDate)); self.save()
                completion(stoleFocus ? "This app ignored macOS background launch. Intent restored your previous app; background opening may not be supported by this application." : nil)
            }
        }
    }
    func didStart() { owned = []; pending = [:]; save() }
    func release(except retained: Set<String> = []) {
        pending = pending.filter { retained.contains($0.key) }
        let released = owned.filter { !retained.contains($0.bundle) }
        guard !released.isEmpty else { return }
        for item in released {
            guard let app = NSRunningApplication(processIdentifier: item.pid),
                  app.bundleIdentifier == item.bundle, let launch = item.launchDate,
                  app.launchDate == launch, app.isHidden else { continue }
            // unhide does not activate or raise the restored app's windows.
            app.unhide()
        }
        owned.removeAll { !retained.contains($0.bundle) }; save()
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(owned) else { return }
        try? FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: ledger, options: .atomic)
    }
}
