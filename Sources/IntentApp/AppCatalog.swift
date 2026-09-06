import AppKit
import Foundation
import IntentLock

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let url: URL
    let icon: NSImage

    func matchesSearch(_ rawQuery: String, anchored: Bool = false) -> Bool {
        let query = AppCatalog.visibleText(rawQuery)
        guard !query.isEmpty else { return true }

        let options: String.CompareOptions = anchored
            ? [.caseInsensitive, .diacriticInsensitive, .anchored]
            : [.caseInsensitive, .diacriticInsensitive]
        let filename = AppCatalog.visibleText(url.deletingPathExtension().lastPathComponent)

        return name.range(of: query, options: options) != nil
            || filename.range(of: query, options: options) != nil
            || bundleIdentifier.range(of: query, options: options) != nil
    }
}

enum AppCatalog {
    static let preferredBundleIdentifiers = [
        "com.apple.finder",
        "com.apple.MobileSMS",
        "org.mozilla.firefox",
        "com.google.Chrome",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.openai.codex",
        "com.spotify.client",
        "net.ankiweb.dtop",
        "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode",
        "com.rstudio.desktop",
        "io.remnote",
        "com.remnote.desktop",
        "net.whatsapp.WhatsApp",
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos"
    ]

    static func mostUsed(in catalog: [InstalledApp]) -> [InstalledApp] {
        let appsByIdentifier = Dictionary(
            catalog.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return preferredBundleIdentifiers.compactMap { appsByIdentifier[$0] }
    }

    static func load() -> [InstalledApp] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var seen = Set<String>()
        var apps: [InstalledApp] = []
        var candidateURLs: [URL] = []

        candidateURLs.append(URL(
            fileURLWithPath: "/System/Library/CoreServices/Finder.app",
            isDirectory: true
        ))

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                candidateURLs.append(url)
            }
        }

        candidateURLs.append(contentsOf: spotlightApplicationURLs())

        for url in candidateURLs {
            guard !url.path.contains(".app/Contents/"),
                  let metadata = ApplicationBundleIdentifierResolver.metadata(from: url) else {
                continue
            }
            let bundleIdentifier = metadata.bundleIdentifier
            guard !seen.contains(bundleIdentifier) else {
                continue
            }

            seen.insert(bundleIdentifier)
            let metadataName = metadata.displayName
                ?? metadata.bundleName
                ?? url.deletingPathExtension().lastPathComponent
            let name = visibleText(metadataName)

            apps.append(InstalledApp(
                name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                bundleIdentifier: bundleIdentifier,
                url: url,
                icon: NSWorkspace.shared.icon(forFile: url.path)
            ))
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func visibleText(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func spotlightApplicationURLs() -> [URL] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            guard let paths = String(data: data, encoding: .utf8) else { return [] }
            return paths.split(separator: "\n").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
            }
        } catch {
            return []
        }
    }
}
