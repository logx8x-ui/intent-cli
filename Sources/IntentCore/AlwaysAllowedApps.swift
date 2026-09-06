import Foundation

public final class AlwaysAllowedAppStore {
    public static let finder = AllowedApp(
        name: "Finder",
        bundleIdentifier: "com.apple.finder"
    )

    public let fileURL: URL

    public init(fileURL: URL = AlwaysAllowedAppStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> [AllowedApp] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let defaults = [Self.finder]
            try save(defaults)
            return defaults
        }

        let data = try Data(contentsOf: fileURL)
        return Self.unique(try JSONDecoder().decode([AllowedApp].self, from: data))
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
        var updated = intention
        let presetIDs = Set(presets.map(\.bundleIdentifier))

        switch updated.accessMode {
        case .whitelist:
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
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("always-allowed-apps.json")
    }
}
