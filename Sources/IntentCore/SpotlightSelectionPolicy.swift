import Foundation

public struct SpotlightApplicationCandidate: Equatable {
    public let name: String
    public let url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

public enum SpotlightSelectionPolicy {
    public static func isApplicationResult(metadata: String) -> Bool {
        metadata.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Bundle:com.apple.applications" }
    }

    /// Resolve only a selected APPLICATION result's exact label, never a query
    /// or a fuzzy match. Ambiguous labels must not add an unrelated app.
    public static func selectedApplication(named name: String, isApplication: Bool, candidates: [SpotlightApplicationCandidate]) -> URL? {
        guard isApplication else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let matches = Set(candidates.filter {
            $0.name.compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || $0.url.deletingPathExtension().lastPathComponent.compare(label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.map(\.url))
        return matches.count == 1 ? matches.first : nil
    }

    /// Only one explicit boundary marker is meaningful. Embedded/multiple
    /// backticks remain an ordinary search, never an implicit app selection.
    public static func markedQuery(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.filter({ $0 == "`" }).count == 1,
              value.first == "`" || value.last == "`" else { return nil }
        return value.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func applicationURL(_ value: String) -> URL? {
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }
        return url.standardizedFileURL
    }
}
