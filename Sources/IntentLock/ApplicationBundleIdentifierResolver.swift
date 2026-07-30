import Foundation

public struct ApplicationBundleMetadata: Equatable {
    public let bundleIdentifier: String
    public let displayName: String?
    public let bundleName: String?
}

public enum ApplicationBundleIdentifierResolver {
    public static func resolve(from url: URL) -> String? {
        metadata(from: url)?.bundleIdentifier
    }

    public static func metadata(from url: URL) -> ApplicationBundleMetadata? {
        guard url.isFileURL,
              let appURL = enclosingApplicationURL(for: url) else {
            return nil
        }

        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoPlistURL, options: .mappedIfSafe),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let info = propertyList as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            return nil
        }

        let normalizedIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else { return nil }
        return ApplicationBundleMetadata(
            bundleIdentifier: normalizedIdentifier,
            displayName: info["CFBundleDisplayName"] as? String,
            bundleName: info["CFBundleName"] as? String
        )
    }

    private static func enclosingApplicationURL(for url: URL) -> URL? {
        var candidate = url.standardizedFileURL

        for _ in 0..<32 {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }

        return nil
    }
}
