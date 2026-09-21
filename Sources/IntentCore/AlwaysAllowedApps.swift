import Foundation

public final class AlwaysAllowedAppStore {
    public static let finder = AllowedApp(
        name: "Finder",
        bundleIdentifier: "com.apple.finder"
    )

    public static let systemSettings = AllowedApp(name: "System Settings", bundleIdentifier: "com.apple.systempreferences")
    public static let defaults = [finder, systemSettings]

    public let fileURL: URL

    public init(fileURL: URL = AlwaysAllowedAppStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> [AllowedApp] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let defaults = Self.defaults
            try save(defaults)
            try markDefaultsVersion()
            return defaults
        }

        let data = try Data(contentsOf: fileURL)
        var apps = Self.unique(try JSONDecoder().decode([AllowedApp].self, from: data))
        if fileURL.lastPathComponent == "always-allowed-apps.json",
           !FileManager.default.fileExists(atPath: defaultsVersionURL.path) {
            // Upgrade only the old untouched Finder default. Empty/custom lists
            // express a user's choice and must not acquire new permissions.
            if apps == [Self.finder] { apps = Self.defaults; try save(apps) }
            try markDefaultsVersion()
        }
        return apps
    }

    private var defaultsVersionURL: URL { fileURL.appendingPathExtension("defaults-v2") }
    private func markDefaultsVersion() throws {
        guard fileURL.lastPathComponent == "always-allowed-apps.json" else { return }
        try Data("2".utf8).write(to: defaultsVersionURL, options: .atomic)
    }

    public func save(_ apps: [AllowedApp]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Self.unique(apps)).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public static func applying(_ presets: [AllowedApp], to intention: Intention) -> Intention {
        guard !intention.selectionOnly else { return intention }
        var updated = intention
        let presetIDs = Set(presets.map(\.bundleIdentifier))

        switch updated.accessMode {
        case .whitelist:
            // Green presets grant access, never an implicit launch (including old intentions).
            updated.presetStartupExcludedResourceIDs = Set(presets.map(\.resourceID))
            for preset in presets where !updated.allowedApps.contains(where: {
                $0.bundleIdentifier == preset.bundleIdentifier
            }) {
                updated.allowedApps.append(preset)
            }
        case .blacklist:
            updated.allowedApps.removeAll { presetIDs.contains($0.bundleIdentifier) }
            updated.allowedWebsites.removeAll {
                guard let browserID = $0.browserBundleIdentifier else { return false }
                return presetIDs.contains(browserID)
            }
        }
        return updated
    }

    public static func applying(_ presets: [AllowedApp], to intentions: [Intention]) -> [Intention] {
        intentions.map { applying(presets, to: $0) }
    }

    private static func unique(_ apps: [AllowedApp]) -> [AllowedApp] {
        var seen = Set<String>()
        return apps.filter { app in
            !app.bundleIdentifier.isEmpty && seen.insert(app.bundleIdentifier).inserted
        }
    }

    public static func defaultFileURL() -> URL {
        IntentEnvironment.dataDirectory
            .appendingPathComponent("always-allowed-apps.json")
    }
}
