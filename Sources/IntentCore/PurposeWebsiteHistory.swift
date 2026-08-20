import Foundation

public struct PurposeWebsiteHistoryEntry: Codable, Equatable {
    public var name: String
    public var value: String
    public var aliases: [String]
    public var visitCount: Int
    public var lastVisitedAt: Date

    public init(
        name: String,
        value: String,
        aliases: [String],
        visitCount: Int = 1,
        lastVisitedAt: Date = Date()
    ) {
        self.name = name
        self.value = AllowedWebsite.normalized(value)
        self.aliases = aliases
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }
}

public final class PurposeWebsiteHistoryStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(browserBundleIdentifier: String) {
        self.init(fileURL: Self.fileURL(for: browserBundleIdentifier))
    }

    public static func fileURL(for browserBundleIdentifier: String) -> URL {
        let safeIdentifier = browserBundleIdentifier
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return defaultDirectoryURL()
            .appendingPathComponent("purpose-websites-\(safeIdentifier).json")
    }

    public func record(urlString: String, title: String, now: Date = Date()) throws {
        guard let identity = Self.websiteIdentity(urlString: urlString, title: title) else { return }
        var entries = loadEntries()
        if let index = entries.firstIndex(where: { $0.value == identity.value }) {
            entries[index].visitCount += 1
            entries[index].lastVisitedAt = now
            if Self.shouldPreferName(identity.name, over: entries[index].name) {
                entries[index].name = identity.name
            }
            entries[index].aliases = Self.uniqueAliases(entries[index].aliases + identity.aliases)
        } else {
            entries.append(PurposeWebsiteHistoryEntry(
                name: identity.name,
                value: identity.value,
                aliases: identity.aliases,
                lastVisitedAt: now
            ))
        }
        try write(entries: entries)
    }

    public func loadEntries() -> [PurposeWebsiteHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([PurposeWebsiteHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    public static func frequentKnownWebsites(limit: Int = 80) -> [PurposeKnownWebsite] {
        let directory = defaultDirectoryURL()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var merged: [String: PurposeWebsiteHistoryEntry] = [:]
        for file in files where file.lastPathComponent.hasPrefix("purpose-websites-") && file.pathExtension == "json" {
            for entry in PurposeWebsiteHistoryStore(fileURL: file).loadEntries() {
                if var existing = merged[entry.value] {
                    existing.visitCount += entry.visitCount
                    existing.lastVisitedAt = max(existing.lastVisitedAt, entry.lastVisitedAt)
                    if shouldPreferName(entry.name, over: existing.name) { existing.name = entry.name }
                    existing.aliases = uniqueAliases(existing.aliases + entry.aliases)
                    merged[entry.value] = existing
                } else {
                    merged[entry.value] = entry
                }
            }
        }

        return merged.values
            .sorted {
                if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
                return $0.lastVisitedAt > $1.lastVisitedAt
            }
            .prefix(max(0, limit))
            .map {
                PurposeKnownWebsite(name: $0.name, value: $0.value, aliases: $0.aliases)
            }
    }

    private func write(entries: [PurposeWebsiteHistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    private static func defaultDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".intent", isDirectory: true)
    }

    private static func websiteIdentity(
        urlString: String,
        title: String
    ) -> (name: String, value: String, aliases: [String])? {
        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let hostParts = host.split(separator: ".")
        if hostParts.count >= 3, hostParts[0].count == 2 {
            host = hostParts.dropFirst().joined(separator: ".")
        }
        guard host != "localhost", host != "127.0.0.1", host != "::1" else { return nil }

        let hostWords = meaningfulHostWords(host)
        let hostName = hostWords.first?.capitalized ?? host
        let titleName = cleanedTitle(title, fallback: hostName)
        var aliases = [titleName, host, hostName]
        if hostWords.count >= 2 {
            aliases.append(hostWords.prefix(2).joined(separator: " "))
            aliases.append(hostWords.prefix(2).reversed().joined(separator: " "))
        }
        aliases.append(contentsOf: titleAliases(title))
        return (titleName, host, uniqueAliases(aliases))
    }

    private static func cleanedTitle(_ rawTitle: String, fallback: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let separators = [" | ", " — ", " – ", " - ", " · ", " • "]
        var candidate = trimmed
        for separator in separators {
            if let first = candidate.components(separatedBy: separator).first,
               !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate = first
            }
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["new tab", "home", "login", "sign in", "untitled"]
        guard candidate.count >= 2,
              candidate.count <= 48,
              !generic.contains(candidate.lowercased()) else { return fallback }
        return candidate
    }

    private static func titleAliases(_ title: String) -> [String] {
        let words = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !["the", "and", "for", "with", "login", "home"].contains($0) }
        guard !words.isEmpty else { return [] }
        var aliases = [words.prefix(4).joined(separator: " ")]
        aliases.append(contentsOf: words.prefix(6))
        return aliases
    }

    private static func meaningfulHostWords(_ host: String) -> [String] {
        let ignored = Set(["www", "en", "app", "web", "open", "mail", "com", "org", "net", "edu", "gov", "au", "uk"])
        return host.split(separator: ".").map(String.init).filter { !ignored.contains($0) }
    }

    private static func shouldPreferName(_ candidate: String, over existing: String) -> Bool {
        let candidateWords = candidate.split(separator: " ").count
        let existingWords = existing.split(separator: " ").count
        return candidateWords > existingWords || (candidateWords == existingWords && candidate.count > existing.count)
    }

    private static func uniqueAliases(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
            guard key.count >= 2, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}
