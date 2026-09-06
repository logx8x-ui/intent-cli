import Foundation

public enum PromptAutocompleteKind: Equatable {
    case intention(id: String)
    case application(bundleIdentifier: String)
    case website(browserBundleIdentifier: String, value: String)
}

public struct PromptAutocompleteCandidate: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: PromptAutocompleteKind

    public init(id: String, title: String, subtitle: String, kind: PromptAutocompleteKind) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

public struct PromptAutocompleteState: Equatable {
    public let replacementRange: NSRange
    public let query: String
    public let candidates: [PromptAutocompleteCandidate]

    public init(replacementRange: NSRange, query: String, candidates: [PromptAutocompleteCandidate]) {
        self.replacementRange = replacementRange
        self.query = query
        self.candidates = candidates
    }
}

public struct PromptTextEdit: Equatable {
    public let text: String
    public let cursorUTF16Offset: Int

    public init(text: String, cursorUTF16Offset: Int) {
        self.text = text
        self.cursorUTF16Offset = cursorUTF16Offset
    }
}

public enum PromptAutocompleteEngine {
    public static func state(
        for text: String,
        cursorUTF16Offset: Int,
        apps: [AllowedApp],
        intentions: [Intention],
        websitesByBrowser: [String: [PurposeKnownWebsite]],
        limit: Int = 6
    ) -> PromptAutocompleteState? {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        let prefix = source.substring(to: cursor)

        if let websiteState = websiteState(
            prefix: prefix,
            cursor: cursor,
            apps: apps,
            websitesByBrowser: websitesByBrowser,
            limit: limit
        ) {
            return websiteState
        }

        if let intentionState = intentionState(
            prefix: prefix,
            cursor: cursor,
            intentions: intentions,
            limit: limit
        ) {
            return intentionState
        }

        return applicationState(
            prefix: prefix,
            cursor: cursor,
            apps: apps,
            limit: limit
        )
    }

    public static func applying(
        _ candidate: PromptAutocompleteCandidate,
        to text: String,
        state: PromptAutocompleteState
    ) -> PromptTextEdit {
        let source = NSMutableString(string: text)
        let replacement: String
        let cursorAdjustment: Int

        switch candidate.kind {
        case .intention:
            replacement = "* \(candidate.title)"
            cursorAdjustment = 0
        case .application(let bundleIdentifier):
            if supportedBrowserAliases[bundleIdentifier] != nil {
                replacement = "\(candidate.title)()"
                cursorAdjustment = -1
            } else {
                replacement = candidate.title
                cursorAdjustment = 0
            }
        case .website:
            replacement = "\(candidate.title), "
            cursorAdjustment = 0
        }

        source.replaceCharacters(in: state.replacementRange, with: replacement)
        return PromptTextEdit(
            text: source as String,
            cursorUTF16Offset: state.replacementRange.location
                + (replacement as NSString).length
                + cursorAdjustment
        )
    }

    public static func insertingBrowserGroupIfNeeded(
        in text: String,
        cursorUTF16Offset: Int,
        apps: [AllowedApp]
    ) -> PromptTextEdit? {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        guard cursor > 0 else { return nil }
        if cursor < source.length, source.substring(with: NSRange(location: cursor, length: 1)) == "(" {
            return nil
        }

        let prefix = source.substring(to: cursor)
        guard unmatchedOpeningParenthesisCount(in: prefix) == 0 else { return nil }

        for app in supportedBrowsers(in: apps) {
            for alias in aliases(for: app).sorted(by: { $0.count > $1.count }) {
                let escaped = NSRegularExpression.escapedPattern(for: alias)
                let pattern = "(?i)(?<![\\p{L}\\p{N}])\(escaped)$"
                guard prefix.range(of: pattern, options: .regularExpression) != nil else { continue }
                let updated = NSMutableString(string: text)
                updated.insert("()", at: cursor)
                return PromptTextEdit(text: updated as String, cursorUTF16Offset: cursor + 1)
            }
        }
        return nil
    }

    private static func websiteState(
        prefix: String,
        cursor: Int,
        apps: [AllowedApp],
        websitesByBrowser: [String: [PurposeKnownWebsite]],
        limit: Int
    ) -> PromptAutocompleteState? {
        let source = prefix as NSString
        for app in supportedBrowsers(in: apps) {
            let aliasPattern = aliases(for: app)
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            guard !aliasPattern.isEmpty,
                  let regex = try? NSRegularExpression(
                    pattern: "(?i)(?<![\\p{L}\\p{N}])(?:\(aliasPattern))\\s*\\(([^)]*)$"
                  ),
                  let match = regex.matches(
                    in: prefix,
                    range: NSRange(location: 0, length: source.length)
                  ).last else { continue }

            let contentsRange = match.range(at: 1)
            let contents = source.substring(with: contentsRange) as NSString
            let comma = contents.range(of: ",", options: .backwards)
            var queryStart = contentsRange.location + (comma.location == NSNotFound ? 0 : comma.location + 1)
            while queryStart < cursor,
                  CharacterSet.whitespacesAndNewlines.contains(
                    UnicodeScalar(source.character(at: queryStart)) ?? " "
                  ) {
                queryStart += 1
            }
            let range = NSRange(location: queryStart, length: max(0, cursor - queryStart))
            let query = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let foldedQuery = folded(query)
            let candidates = uniqueWebsites(websitesByBrowser[app.bundleIdentifier, default: []])
                .filter { website in
                    guard !foldedQuery.isEmpty else { return true }
                    return ([website.name, website.value] + website.aliases).contains { value in
                        let candidate = folded(value)
                        return candidate.hasPrefix(foldedQuery)
                            || candidate.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) })
                    }
                }
                .prefix(max(0, limit))
                .map { website in
                    PromptAutocompleteCandidate(
                        id: "website:\(app.bundleIdentifier):\(website.value)",
                        title: website.name,
                        subtitle: website.value,
                        kind: .website(
                            browserBundleIdentifier: app.bundleIdentifier,
                            value: website.value
                        )
                    )
                }
            guard !candidates.isEmpty else { return nil }
            return PromptAutocompleteState(
                replacementRange: range,
                query: query,
                candidates: Array(candidates)
            )
        }
        return nil
    }

    private static func intentionState(
        prefix: String,
        cursor: Int,
        intentions: [Intention],
        limit: Int
    ) -> PromptAutocompleteState? {
        let source = prefix as NSString
        let marker = source.range(of: "*", options: .backwards)
        guard marker.location != NSNotFound else { return nil }
        let suffixRange = NSRange(
            location: marker.location + marker.length,
            length: source.length - marker.location - marker.length
        )
        let suffix = source.substring(with: suffixRange)
        guard suffix.rangeOfCharacter(from: CharacterSet(charactersIn: "\n.,;:!?()[]{}")) == nil else {
            return nil
        }
        let query = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = folded(query)
        let candidates = intentions
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { intention in
                guard !foldedQuery.isEmpty else { return true }
                let name = folded(intention.name)
                return name.hasPrefix(foldedQuery)
                    || name.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) })
            }
            .filter { folded($0.name) != foldedQuery }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(max(0, limit))
            .map { intention in
                PromptAutocompleteCandidate(
                    id: "intention:\(intention.id)",
                    title: intention.name,
                    subtitle: "Saved intention",
                    kind: .intention(id: intention.id)
                )
            }
        guard !candidates.isEmpty else { return nil }
        return PromptAutocompleteState(
            replacementRange: NSRange(location: marker.location, length: cursor - marker.location),
            query: query,
            candidates: Array(candidates)
        )
    }

    private static func applicationState(
        prefix: String,
        cursor: Int,
        apps: [AllowedApp],
        limit: Int
    ) -> PromptAutocompleteState? {
        let source = prefix as NSString
        let separators = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let clauseSeparator = source.rangeOfCharacter(from: separators, options: .backwards)
        let clauseStart = clauseSeparator.location == NSNotFound ? 0 : clauseSeparator.location + 1
        let clauseRange = NSRange(location: clauseStart, length: source.length - clauseStart)
        let clause = source.substring(with: clauseRange)
        let words = clause.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }

        for wordCount in stride(from: min(3, words.count), through: 1, by: -1) {
            let queryWords = words.suffix(wordCount)
            let query = queryWords.joined(separator: " ")
            guard query.count >= 2 else { continue }
            let foldedQuery = folded(query)
            let candidates = apps
                .filter { app in
                    let name = folded(app.name)
                    return name != foldedQuery && (
                        name.hasPrefix(foldedQuery)
                            || name.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) })
                    )
                }
                .sorted { lhs, rhs in
                    let leftPrefix = folded(lhs.name).hasPrefix(foldedQuery)
                    let rightPrefix = folded(rhs.name).hasPrefix(foldedQuery)
                    if leftPrefix != rightPrefix { return leftPrefix }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .prefix(max(0, limit))
                .map { app in
                    PromptAutocompleteCandidate(
                        id: "app:\(app.bundleIdentifier)",
                        title: app.name,
                        subtitle: "Application",
                        kind: .application(bundleIdentifier: app.bundleIdentifier)
                    )
                }
            guard !candidates.isEmpty else { continue }

            let queryLength = (query as NSString).length
            return PromptAutocompleteState(
                replacementRange: NSRange(location: cursor - queryLength, length: queryLength),
                query: query,
                candidates: Array(candidates)
            )
        }
        return nil
    }

    private static func supportedBrowsers(in apps: [AllowedApp]) -> [AllowedApp] {
        apps.filter { supportedBrowserAliases[$0.bundleIdentifier] != nil }
    }

    private static func aliases(for app: AllowedApp) -> [String] {
        [app.name] + supportedBrowserAliases[app.bundleIdentifier, default: []]
    }

    private static func unmatchedOpeningParenthesisCount(in value: String) -> Int {
        value.reduce(into: 0) { count, character in
            if character == "(" { count += 1 }
            if character == ")" { count = max(0, count - 1) }
        }
    }

    private static func uniqueWebsites(_ websites: [PurposeKnownWebsite]) -> [PurposeKnownWebsite] {
        var seen = Set<String>()
        return websites.filter { seen.insert($0.value).inserted }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static let supportedBrowserAliases: [String: [String]] = [
        "org.mozilla.firefox": ["Firefox", "Fire Fox"],
        "com.google.Chrome": ["Chrome", "Google Chrome"]
    ]
}
