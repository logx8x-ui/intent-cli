import Foundation

public struct PurposeLiveInterpretation: Equatable {
    public var includedAppBundleIdentifiers: [String]
    public var excludedAppBundleIdentifiers: [String]
    public var explicitlyIncludedAppBundleIdentifiers: [String]
    public var includedIntentionIDs: [String]
    public var excludedIntentionIDs: [String]
    public var usedCorrection: Bool
    public var limitsAppsToSelection: Bool

    public init(
        includedAppBundleIdentifiers: [String] = [],
        excludedAppBundleIdentifiers: [String] = [],
        explicitlyIncludedAppBundleIdentifiers: [String] = [],
        includedIntentionIDs: [String] = [],
        excludedIntentionIDs: [String] = [],
        usedCorrection: Bool = false,
        limitsAppsToSelection: Bool = false
    ) {
        self.includedAppBundleIdentifiers = includedAppBundleIdentifiers
        self.excludedAppBundleIdentifiers = excludedAppBundleIdentifiers
        self.explicitlyIncludedAppBundleIdentifiers = explicitlyIncludedAppBundleIdentifiers
        self.includedIntentionIDs = includedIntentionIDs
        self.excludedIntentionIDs = excludedIntentionIDs
        self.usedCorrection = usedCorrection
        self.limitsAppsToSelection = limitsAppsToSelection
    }
}

public enum PurposeLiveInterpreter {
    private enum EntityKind: Int {
        case intention
        case app
    }

    private enum Operation {
        case include
        case exclude
    }

    private struct Alias {
        let id: String
        let kind: EntityKind
        let words: [String]
    }

    private struct Mention {
        let id: String
        let kind: EntityKind
        let start: Int
        let end: Int
        let operation: Operation
        let narrowsApps: Bool
        let fromPronoun: Bool
    }

    public static func interpret(
        _ rawText: String,
        apps: [AllowedApp],
        intentions: [Intention]
    ) -> PurposeLiveInterpretation {
        let words = normalizedWords(rawText)
        guard !words.isEmpty else { return PurposeLiveInterpretation() }

        let aliases = makeAliases(apps: apps, intentions: intentions)
        var mentions = findMentions(in: words, aliases: aliases)
        mentions.append(contentsOf: pronounMentions(in: words, existing: mentions))
        mentions.sort {
            if $0.start == $1.start {
                if $0.fromPronoun != $1.fromPronoun { return !$0.fromPronoun }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.end > $1.end
            }
            return $0.start < $1.start
        }

        var appOperations: [String: Operation] = [:]
        var appOrder: [String] = []
        var intentionOperations: [String: Operation] = [:]
        var intentionOrder: [String] = []
        var usedCorrection = false
        var limitsAppsToSelection = false

        for mention in mentions {
            if mention.narrowsApps, mention.kind == .app, mention.operation == .include {
                appOperations = appOperations.mapValues { _ in .exclude }
                usedCorrection = true
                limitsAppsToSelection = true
            }

            switch mention.kind {
            case .app:
                if appOperations[mention.id] != nil || mention.operation == .exclude {
                    usedCorrection = true
                }
                appOperations[mention.id] = mention.operation
                if !appOrder.contains(mention.id) { appOrder.append(mention.id) }
            case .intention:
                if intentionOperations[mention.id] != nil || mention.operation == .exclude {
                    usedCorrection = true
                }
                intentionOperations[mention.id] = mention.operation
                if !intentionOrder.contains(mention.id) { intentionOrder.append(mention.id) }
            }
        }

        let includedIntentions = intentionOrder.filter { intentionOperations[$0] == .include }
        let excludedIntentions = intentionOrder.filter { intentionOperations[$0] == .exclude }
        let intentionsByID = Dictionary(uniqueKeysWithValues: intentions.map { ($0.id, $0) })

        var includedApps: [String] = []
        for intentionID in includedIntentions {
            for app in intentionsByID[intentionID]?.allowedApps ?? [] where !includedApps.contains(app.bundleIdentifier) {
                includedApps.append(app.bundleIdentifier)
            }
        }

        let explicitlyIncludedApps = appOrder.filter { appOperations[$0] == .include }
        let excludedApps = appOrder.filter { appOperations[$0] == .exclude }
        for bundleIdentifier in explicitlyIncludedApps where !includedApps.contains(bundleIdentifier) {
            includedApps.append(bundleIdentifier)
        }
        includedApps.removeAll { excludedApps.contains($0) }

        return PurposeLiveInterpretation(
            includedAppBundleIdentifiers: includedApps,
            excludedAppBundleIdentifiers: excludedApps,
            explicitlyIncludedAppBundleIdentifiers: explicitlyIncludedApps,
            includedIntentionIDs: includedIntentions,
            excludedIntentionIDs: excludedIntentions,
            usedCorrection: usedCorrection,
            limitsAppsToSelection: limitsAppsToSelection
        )
    }

    private static func makeAliases(apps: [AllowedApp], intentions: [Intention]) -> [Alias] {
        var aliases: [Alias] = []
        for app in apps {
            var values = [app.name]
            values.append(contentsOf: knownAliases[app.bundleIdentifier, default: []])
            for value in values {
                let words = normalizedWords(value)
                if !words.isEmpty {
                    aliases.append(Alias(id: app.bundleIdentifier, kind: .app, words: words))
                }
            }
        }
        for intention in intentions {
            let words = normalizedWords(intention.name)
            if !words.isEmpty {
                aliases.append(Alias(id: intention.id, kind: .intention, words: words))
            }
        }
        return aliases
    }

    private static func findMentions(in words: [String], aliases: [Alias]) -> [Mention] {
        var matches: [Mention] = []
        for alias in aliases where alias.words.count <= words.count {
            for start in 0...(words.count - alias.words.count) {
                let end = start + alias.words.count
                guard Array(words[start..<end]) == alias.words else { continue }
                let operation = operation(before: start, after: end, in: words)
                matches.append(Mention(
                    id: alias.id,
                    kind: alias.kind,
                    start: start,
                    end: end,
                    operation: operation,
                    narrowsApps: operation == .include && hasNarrowingWord(before: start, in: words),
                    fromPronoun: false
                ))
            }
        }

        let grouped = Dictionary(grouping: matches) { "\($0.kind.rawValue):\($0.id):\($0.start)" }
        return grouped.values.compactMap { group in
            group.max { ($0.end - $0.start) < ($1.end - $1.start) }
        }
    }

    private static func pronounMentions(in words: [String], existing: [Mention]) -> [Mention] {
        let ordered = existing.sorted { $0.start < $1.start }
        var additions: [Mention] = []
        for index in words.indices where ["it", "that"].contains(words[index]) {
            guard let previous = ordered.last(where: { $0.end <= index }) else { continue }
            let operation = operation(before: index, after: index + 1, in: words)
            let prefix = phrase(before: index, count: 5, in: words)
            guard operation == .exclude || containsAny(prefix, phrases: positiveCorrectionPhrases) else {
                continue
            }
            additions.append(Mention(
                id: previous.id,
                kind: previous.kind,
                start: index,
                end: index + 1,
                operation: operation,
                narrowsApps: false,
                fromPronoun: true
            ))
        }
        return additions
    }

    private static func operation(before start: Int, after end: Int, in words: [String]) -> Operation {
        let prefixWords = Array(words[max(0, start - 8)..<start])
        let positiveIndex = latestPhraseEnd(in: prefixWords, phrases: positivePhrases)
        let negativeIndex = latestPhraseEnd(in: prefixWords, phrases: negativePhrases)
        let correctionIndex = latestPhraseEnd(in: prefixWords, phrases: positiveCorrectionPhrases)

        if let correctionIndex, correctionIndex >= (negativeIndex ?? -1) { return .include }
        if let negativeIndex, negativeIndex >= (positiveIndex ?? -1) { return .exclude }
        return .include
    }

    private static func hasNarrowingWord(before start: Int, in words: [String]) -> Bool {
        let prefix = Array(words[max(0, start - 3)..<start])
        return prefix.contains("only") || prefix.contains("just")
    }

    private static func phrase(before index: Int, count: Int, in words: [String]) -> String {
        words[max(0, index - count)..<index].joined(separator: " ")
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private static func latestPhraseEnd(in words: [String], phrases: [String]) -> Int? {
        var latest: Int?
        for phrase in phrases {
            let phraseWords = normalizedWords(phrase)
            guard !phraseWords.isEmpty, phraseWords.count <= words.count else { continue }
            for start in 0...(words.count - phraseWords.count)
                where Array(words[start..<(start + phraseWords.count)]) == phraseWords {
                latest = max(latest ?? -1, start + phraseWords.count - 1)
            }
        }
        return latest
    }

    private static func normalizedWords(_ value: String) -> [String] {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let negativePhrases = [
        "remove", "take away", "get rid of", "without", "exclude", "drop",
        "leave out", "dont use", "do not use", "not use", "dont need",
        "do not need", "dont want", "do not want", "no longer", "stop using",
        "dont add", "do not add", "forget", "cancel", "not"
    ]

    private static let positiveCorrectionPhrases = [
        "add back", "put back", "bring back", "keep", "still use", "actually use",
        "do not remove", "dont remove"
    ]

    private static let positivePhrases = [
        "use", "open", "add", "include", "need", "want", "keep", "with", "plus",
        "also", "bring", "put", "run", "launch"
    ]

    private static let knownAliases: [String: [String]] = [
        "com.apple.MobileSMS": ["imessage", "imessages", "messages", "message app"],
        "com.apple.mail": ["mail", "apple mail", "email", "emails"],
        "org.mozilla.firefox": ["firefox"],
        "com.google.Chrome": ["chrome", "google chrome"],
        "com.spotify.client": ["spotify"],
        "com.apple.Notes": ["notes", "apple notes"],
        "com.apple.reminders": ["reminders", "apple reminders"],
        "com.apple.iCal": ["calendar", "apple calendar"]
    ]
}
