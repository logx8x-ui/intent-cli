import Foundation

/// A one-time copy of durable workspace data, never shared mutable storage.
/// Runtime effects, browser transport files, authentication and recovery ledgers
/// are deliberately outside this allowlist.
public enum IntentChannelSeed {
    public static let markerName = ".development-seed-v1"
    public static let workspaceFiles = [
        "intentions.json", "intentions.last-good.json", "schedules.json",
        "session-journal.json", "portable-preferences.json"
    ]
    public static let rootFiles = ["always-allowed-apps.json", "always-blocked-apps.json"]
    public static let preferenceKeys = [
        "intentAppearance", "intentWelcomeTitle", "intentBackgroundSelection",
        "intentGentleReminder", "intentPurposeModeEnabled", "intentPurposeAccessMode",
        "intentRequireManualFinishBeforeSwitching", "intentFinishShortcut", "intentOverlayShortcut",
        "intentZeroDriftWarningSuppressed", "distractionAppearance", "overviewShowClock",
        "overviewShowTitles", "overviewNotesX", "overviewNotesY", "quickModificationOrder",
        "quickSelectionLastTimerDurationMinutes", "quickSelectionLastCooldownDurationMinutes",
        "explainedTimerChecklist"
    ]

    public static func prepareDevelopment(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          defaults: UserDefaults = .standard) throws {
        guard IntentBuildChannel.current == .development, !IntentEnvironment.isQA else { return }
        let launchDefaults = UserDefaults.standard.persistentDomain(forName: IntentBuildChannel.launch.bundleIdentifier) ?? [:]
        try seed(from: IntentEnvironment.channelDataDirectory(channel: .launch, home: home),
                 to: IntentEnvironment.channelDataDirectory(channel: .development, home: home),
                 preferences: launchDefaults, defaults: defaults)
    }

    public static func seed(from source: URL, to destination: URL,
                            preferences: [String: Any], defaults: UserDefaults) throws {
        let fm = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw IntentEngineLeaseError.invalidDirectory
        }
        try privateDirectory(destination)
        let marker = destination.appendingPathComponent(markerName)
        guard !fm.fileExists(atPath: marker.path) else { return }

        try copyWorkspace(from: source, to: destination)
        for name in rootFiles { try copyRegularFile(source.appendingPathComponent(name), to: destination.appendingPathComponent(name)) }
        let accounts = source.appendingPathComponent("accounts", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: accounts, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try copyWorkspace(from: child, to: destination.appendingPathComponent("accounts").appendingPathComponent(child.lastPathComponent))
            }
        }

        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            if let value = preferences[key] { defaults.set(value, forKey: key) }
        }
        // The new app must obtain its own OS grants. It starts local-only; never
        // copy an onboarding completion, account token, pending callback or login item.
        defaults.set(true, forKey: "intentAccountChoiceMade")
        defaults.set(false, forKey: "intentLaunchAtLogin")
        defaults.synchronize()
        try Data("Independent Test Intent workspace v1\n".utf8).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private static func copyWorkspace(from source: URL, to destination: URL) throws {
        guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try privateDirectory(destination)
        for name in workspaceFiles {
            let input = source.appendingPathComponent(name), output = destination.appendingPathComponent(name)
            if name == "session-journal.json" { try copyCompletedJournal(input, to: output) }
            else { try copyRegularFile(input, to: output) }
        }
        let background = "backgrounds/custom-background.png"
        try copyRegularFile(source.appendingPathComponent(background), to: destination.appendingPathComponent(background))
    }

    private static func copyRegularFile(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return }
        // Refuse symlinked background/account parents as well as symlinked files.
        guard source.deletingLastPathComponent().resolvingSymlinksInPath() == source.deletingLastPathComponent().standardizedFileURL else { return }
        try privateDirectory(destination.deletingLastPathComponent())
        try fm.copyItem(at: source, to: destination)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func copyCompletedJournal(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              source.deletingLastPathComponent().resolvingSymlinksInPath() == source.deletingLastPathComponent().standardizedFileURL,
              var journal = (try? JSONSerialization.jsonObject(with: Data(contentsOf: source))) as? [String: Any],
              let records = journal["records"] as? [[String: Any]],
              journal["slotOrder"] is [String], journal["workspaces"] is [String: Any] else { return }
        // Use the durable IntentSessionJournal field names without importing its
        // entire browser model graph into the standalone seed/lease fixtures.
        // A running launch session must never become Test's recovery session.
        journal.removeValue(forKey: "recovery")
        journal["records"] = records.compactMap { record -> [String: Any]? in
            guard record["endedAt"] is NSNumber else { return nil }
            var completed = record
            completed.removeValue(forKey: "remainingSeconds")
            return completed
        }
        try privateDirectory(destination.deletingLastPathComponent())
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func privateDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath() == directory.standardizedFileURL else {
                throw IntentEngineLeaseError.invalidDirectory
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
