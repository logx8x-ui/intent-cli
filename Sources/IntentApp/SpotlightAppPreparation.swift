import AppKit
import IntentCore

/// Stage app identity, not a process: some macOS apps ignore activates=false and
/// hides=true. Launching only after Start guarantees a selection cannot steal focus.
@MainActor
final class SpotlightAppPreparation {
    static let shared = SpotlightAppPreparation()
    private struct OwnedApp: Codable { let bundle: String; let pid: pid_t; let launchDate: Date? }
    private var owned: [OwnedApp] = [] // Compatibility cleanup for older live preparations.
    private(set) var staged: Set<String> = []
    private let ledger = IntentEnvironment.dataDirectory.appendingPathComponent("spotlight-prepared-apps.json")

    func recover() {
        owned = (try? JSONDecoder().decode([OwnedApp].self, from: Data(contentsOf: ledger))) ?? []
        // Older builds started these processes; restore them without activation.
        for item in owned {
            guard let app = matching(item), app.isHidden else { continue }
            app.unhide()
        }
        owned = []; save()
    }
    func prepare(_ url: URL, completion: @escaping (String?) -> Void) {
        guard let app = Bundle(url: url), let id = app.bundleIdentifier,
              let executable = app.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion("This application is unavailable. Choose another app in Spotlight."); return
        }
        staged.insert(id)
        completion(nil)
    }
    func didStart() { owned = []; staged = []; save() }
    func release(except retained: Set<String> = []) {
        staged.formIntersection(retained)
        for item in owned where !retained.contains(item.bundle) {
            // Only processes started by Intent, with the exact launch identity,
            // can be closed. Never terminate an app the user already had open.
            matching(item)?.terminate()
        }
        owned.removeAll { !retained.contains($0.bundle) }; save()
    }
    private func matching(_ item: OwnedApp) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: item.pid),
              app.bundleIdentifier == item.bundle, let date = item.launchDate,
              app.launchDate == date else { return nil }
        return app
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(owned) else { return }
        try? FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: ledger, options: .atomic)
    }
}
