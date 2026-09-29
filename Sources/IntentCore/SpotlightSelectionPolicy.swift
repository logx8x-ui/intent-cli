import Foundation

public enum SpotlightSelectionPolicy {
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
