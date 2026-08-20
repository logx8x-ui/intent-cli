import Foundation

public struct PurposeWebsiteSelection: Equatable, Identifiable {
    public var id: String { "\(browserBundleIdentifier ?? "unassigned"):\(value)" }
    public var name: String
    public var value: String
    public var browserBundleIdentifier: String?

    public init(name: String, value: String, browserBundleIdentifier: String? = nil) {
        self.name = name
        self.value = AllowedWebsite.normalized(value)
        self.browserBundleIdentifier = browserBundleIdentifier
    }
}

public struct PurposeKnownWebsite: Equatable, Identifiable {
    public var id: String { value }
    public let name: String
    public let value: String
    public let aliases: [String]
    public let iconResource: String?

    public init(name: String, value: String, aliases: [String] = [], iconResource: String? = nil) {
        self.name = name
        self.value = AllowedWebsite.normalized(value)
        self.aliases = aliases
        self.iconResource = iconResource
    }
}

public enum PurposeWebsiteCatalog {
    public static let common: [PurposeKnownWebsite] = [
        .init(name: "YouTube", value: "youtube.com", aliases: ["you tube"], iconResource: "youtube"),
        .init(name: "Gmail", value: "mail.google.com", aliases: ["google mail"], iconResource: "gmail"),
        .init(name: "Instagram", value: "instagram.com", aliases: ["insta"], iconResource: "instagram"),
        .init(name: "GitHub", value: "github.com", aliases: ["git hub"], iconResource: "github"),
        .init(name: "ChatGPT", value: "chatgpt.com", aliases: ["chat gpt", "chat g p t"], iconResource: "chatgpt"),
        .init(name: "Notion", value: "notion.so", iconResource: "notion"),
        .init(name: "Reddit", value: "reddit.com", iconResource: "reddit"),
        .init(name: "LinkedIn", value: "linkedin.com", aliases: ["linked in"], iconResource: "linkedin"),
        .init(name: "X", value: "x.com", aliases: ["twitter website"], iconResource: "x"),
        .init(name: "Google Calendar", value: "calendar.google.com", iconResource: "google-calendar"),
        .init(name: "Google Drive", value: "drive.google.com", iconResource: "google-drive"),
        .init(name: "Spotify Web", value: "open.spotify.com", aliases: ["spotify website"], iconResource: "spotify"),
        .init(name: "Discord Web", value: "discord.com", aliases: ["discord website"], iconResource: "discord"),
        .init(name: "WhatsApp Web", value: "web.whatsapp.com", aliases: ["whatsapp website", "whats app web"]),
        .init(name: "TikTok", value: "tiktok.com", aliases: ["tik tok"]),
        .init(name: "Twitch", value: "twitch.tv"),
        .init(name: "Netflix", value: "netflix.com"),
        .init(name: "Facebook", value: "facebook.com"),
        .init(name: "Roblox", value: "roblox.com"),
        .init(name: "Canva", value: "canva.com"),
        .init(name: "Figma", value: "figma.com"),
        .init(name: "Gemini", value: "gemini.google.com"),
        .init(name: "Wikipedia", value: "wikipedia.org")
    ]

    public static func website(for value: String) -> PurposeKnownWebsite? {
        let normalized = AllowedWebsite.normalized(value)
        return common.first { $0.value == normalized }
    }
}

public struct PurposeLiveInterpretation: Equatable {
    public var includedAppBundleIdentifiers: [String]
    public var excludedAppBundleIdentifiers: [String]
    public var explicitlyIncludedAppBundleIdentifiers: [String]
    public var includedWebsites: [PurposeWebsiteSelection]
    public var excludedWebsites: [PurposeWebsiteSelection]
    public var explicitlyIncludedWebsiteValues: [String]
    public var includedIntentionIDs: [String]
    public var excludedIntentionIDs: [String]
    public var conflictingIntentionIDs: [String]
    public var usedCorrection: Bool
    public var limitsAppsToSelection: Bool
    public var limitsWebsitesToSelection: Bool

    public init(
        includedAppBundleIdentifiers: [String] = [],
        excludedAppBundleIdentifiers: [String] = [],
        explicitlyIncludedAppBundleIdentifiers: [String] = [],
        includedWebsites: [PurposeWebsiteSelection] = [],
        excludedWebsites: [PurposeWebsiteSelection] = [],
        explicitlyIncludedWebsiteValues: [String] = [],
        includedIntentionIDs: [String] = [],
        excludedIntentionIDs: [String] = [],
        conflictingIntentionIDs: [String] = [],
        usedCorrection: Bool = false,
        limitsAppsToSelection: Bool = false,
        limitsWebsitesToSelection: Bool = false
    ) {
        self.includedAppBundleIdentifiers = includedAppBundleIdentifiers
        self.excludedAppBundleIdentifiers = excludedAppBundleIdentifiers
        self.explicitlyIncludedAppBundleIdentifiers = explicitlyIncludedAppBundleIdentifiers
        self.includedWebsites = includedWebsites
        self.excludedWebsites = excludedWebsites
        self.explicitlyIncludedWebsiteValues = explicitlyIncludedWebsiteValues
        self.includedIntentionIDs = includedIntentionIDs
        self.excludedIntentionIDs = excludedIntentionIDs
        self.conflictingIntentionIDs = conflictingIntentionIDs
        self.usedCorrection = usedCorrection
        self.limitsAppsToSelection = limitsAppsToSelection
        self.limitsWebsitesToSelection = limitsWebsitesToSelection
    }
}

public enum PurposeLiveInterpreter {
    private static let markerToken = "intentmarker"

    private enum EntityKind: Int { case intention, app, website }
    private enum Operation { case include, exclude }

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
        let narrowsSelection: Bool
        let fromPronoun: Bool
        let browserBundleIdentifier: String?
    }

    public static func canonicalizedDisplayText(_ rawText: String, apps: [AllowedApp] = []) -> String {
        let normalizedMarker = rawText.replacingOccurrences(
            of: #"(?i)\b(?:asterisk|asterix|astrix|astrics|asterics|astericks?)\b"#,
            with: "*",
            options: .regularExpression
        )
        guard !apps.isEmpty else { return normalizedMarker }
        return canonicalizedBrowserGroups(in: normalizedMarker, apps: apps)
    }

    public static func intentionAutocompleteCandidates(
        for rawText: String,
        intentions: [Intention],
        limit: Int = 6
    ) -> [Intention] {
        guard let query = activeIntentionMentionQuery(in: rawText) else { return [] }
        let foldedQuery = folded(query)
        if intentions.contains(where: { folded($0.name) == foldedQuery }) { return [] }
        return intentions
            .filter { intention in
                let name = folded(intention.name)
                return foldedQuery.isEmpty || name.hasPrefix(foldedQuery)
                    || name.split(separator: " ").contains(where: { $0.hasPrefix(foldedQuery) })
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public static func completingIntentionMention(in rawText: String, with intention: Intention) -> String {
        guard let marker = rawText.lastIndex(of: "*"),
              activeIntentionMentionQuery(in: rawText) != nil else { return rawText }
        return String(rawText[..<marker]) + "* \(intention.name)"
    }

    public static func browserDisplayAliases(apps: [AllowedApp]) -> [String] {
        var values: [String] = []
        for app in apps where app.isBrowser {
            values.append(app.name)
            values.append(contentsOf: knownAppAliases[app.bundleIdentifier, default: []])
        }
        var seen = Set<String>()
        return values
            .sorted { $0.count > $1.count }
            .filter { seen.insert(folded($0)).inserted }
    }

    public static func speechVocabulary(apps: [AllowedApp], intentions: [Intention]) -> [String] {
        var values = apps.map(\.name)
        for app in apps {
            values.append(contentsOf: knownAppAliases[app.bundleIdentifier, default: []])
        }
        for website in PurposeWebsiteCatalog.common {
            values.append(website.name)
            values.append(contentsOf: website.aliases)
        }
        values.append(contentsOf: intentions.map(\.name))
        values.append(contentsOf: ["asterisk", "add back", "take away", "remove", "on Firefox", "on Chrome"])

        var seen = Set<String>()
        return values.filter { value in
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    public static func clarificationPrompt(
        for rawText: String,
        interpretation: PurposeLiveInterpretation
    ) -> String? {
        let words = normalizedWords(rawText)
        guard words.count >= 2,
              interpretation.includedIntentionIDs.isEmpty,
              interpretation.includedAppBundleIdentifiers.isEmpty,
              interpretation.includedWebsites.isEmpty else {
            return nil
        }

        if words.contains(where: { ["study", "studying", "revise", "revision"].contains($0) }) {
            return "Okay, awesome. What apps or websites do you want to use to study?"
        }
        if words.contains(where: { ["work", "working", "assignment", "project"].contains($0) }) {
            return "What apps or websites do you need for that work?"
        }
        if words.contains(where: { ["play", "game", "games", "gaming"].contains($0) }) {
            return "What game or apps do you want to use?"
        }
        if words.contains(where: { ["reply", "message", "messages", "email", "emails"].contains($0) }) {
            return "Which messaging or email apps do you want to use?"
        }
        if words.contains(where: { ["research", "write", "writing", "plan", "planning", "relax"].contains($0) }) {
            return "What apps or websites do you need for that?"
        }
        return nil
    }

    public static func incrementalSpeechAppend(previous: String, current: String) -> String {
        let previousWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = current.split(whereSeparator: \.isWhitespace).map(String.init)
        guard currentWords.count > previousWords.count else { return "" }

        var commonPrefix = 0
        while commonPrefix < min(previousWords.count, currentWords.count),
              folded(previousWords[commonPrefix]) == folded(currentWords[commonPrefix]) {
            commonPrefix += 1
        }

        // Speech recognition revises earlier partial words frequently. Only append words
        // that are genuinely new so manual deletions are never restored by a later partial.
        let appendStart = max(previousWords.count, commonPrefix)
        guard appendStart < currentWords.count else { return "" }
        return currentWords[appendStart...].joined(separator: " ")
    }

    public static func interpret(
        _ rawText: String,
        apps: [AllowedApp],
        intentions: [Intention]
    ) -> PurposeLiveInterpretation {
        let words = normalizedWordsPreservingMarker(rawText)
        guard !words.isEmpty else { return PurposeLiveInterpretation() }

        let aliases = makeAliases(apps: apps, intentions: intentions)
        var mentions = findMentions(in: words, aliases: aliases)
        mentions.append(contentsOf: fuzzyAppMentions(in: words, aliases: aliases, existing: mentions))
        mentions = websiteQualifiedMentions(in: words, mentions: mentions, apps: apps)
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
        var websiteOperations: [String: Operation] = [:]
        var websiteOrder: [String] = []
        var intentionOperations: [String: Operation] = [:]
        var intentionOrder: [String] = []
        var usedCorrection = false
        var limitsAppsToSelection = false
        var limitsWebsitesToSelection = false

        for mention in mentions {
            if mention.narrowsSelection, mention.operation == .include {
                switch mention.kind {
                case .app:
                    appOperations = appOperations.mapValues { _ in .exclude }
                    limitsAppsToSelection = true
                case .website:
                    websiteOperations = websiteOperations.mapValues { _ in .exclude }
                    limitsWebsitesToSelection = true
                case .intention:
                    break
                }
                usedCorrection = true
            }

            switch mention.kind {
            case .app:
                if appOperations[mention.id] != nil || mention.operation == .exclude { usedCorrection = true }
                appOperations[mention.id] = mention.operation
                if !appOrder.contains(mention.id) { appOrder.append(mention.id) }
            case .website:
                if websiteOperations[mention.id] != nil || mention.operation == .exclude { usedCorrection = true }
                websiteOperations[mention.id] = mention.operation
                if !websiteOrder.contains(mention.id) { websiteOrder.append(mention.id) }
            case .intention:
                if intentionOperations[mention.id] != nil || mention.operation == .exclude { usedCorrection = true }
                intentionOperations[mention.id] = mention.operation
                if !intentionOrder.contains(mention.id) { intentionOrder.append(mention.id) }
            }
        }

        let activeIntentions = intentionOrder.filter { intentionOperations[$0] == .include }
        let includedIntentions = Array(activeIntentions.prefix(1))
        let conflictingIntentions = Array(activeIntentions.dropFirst())
        let excludedIntentions = intentionOrder.filter { intentionOperations[$0] == .exclude }
        let intentionsByID = Dictionary(uniqueKeysWithValues: intentions.map { ($0.id, $0) })

        // A starred saved intention is an exact session reference. It cannot be combined
        // with loose app or website mentions, and only one can be active at a time.
        if let intentionID = includedIntentions.first, let intention = intentionsByID[intentionID] {
            let websites = intention.allowedWebsites.map { website in
                let known = PurposeWebsiteCatalog.website(for: website.value)
                return PurposeWebsiteSelection(
                    name: known?.name ?? website.displayName.capitalized,
                    value: website.value,
                    browserBundleIdentifier: website.browserBundleIdentifier
                )
            }
            return PurposeLiveInterpretation(
                includedAppBundleIdentifiers: intention.allowedApps.map(\.bundleIdentifier),
                includedWebsites: websites,
                includedIntentionIDs: [intentionID],
                excludedIntentionIDs: excludedIntentions,
                conflictingIntentionIDs: conflictingIntentions,
                usedCorrection: usedCorrection
            )
        }

        var includedApps: [String] = []
        for intentionID in includedIntentions {
            for app in intentionsByID[intentionID]?.allowedApps ?? [] where !includedApps.contains(app.bundleIdentifier) {
                includedApps.append(app.bundleIdentifier)
            }
        }

        let explicitlyIncludedApps = appOrder.filter { appOperations[$0] == .include }
        let excludedApps = appOrder.filter { appOperations[$0] == .exclude }
        if limitsAppsToSelection {
            includedApps = explicitlyIncludedApps
        } else {
            for bundleIdentifier in explicitlyIncludedApps where !includedApps.contains(bundleIdentifier) {
                includedApps.append(bundleIdentifier)
            }
        }
        includedApps.removeAll { excludedApps.contains($0) }

        var includedWebsiteValues: [String] = []
        var websiteByValue: [String: PurposeWebsiteSelection] = [:]
        for intentionID in includedIntentions {
            for website in intentionsByID[intentionID]?.allowedWebsites ?? [] {
                let known = PurposeWebsiteCatalog.website(for: website.value)
                let selection = PurposeWebsiteSelection(
                    name: known?.name ?? website.displayName.capitalized,
                    value: website.value,
                    browserBundleIdentifier: website.browserBundleIdentifier
                )
                if websiteByValue[selection.value] == nil { includedWebsiteValues.append(selection.value) }
                websiteByValue[selection.value] = selection
            }
        }

        let explicitlyIncludedWebsiteValues = websiteOrder.filter { websiteOperations[$0] == .include }
        let excludedWebsiteValues = websiteOrder.filter { websiteOperations[$0] == .exclude }
        if limitsWebsitesToSelection {
            includedWebsiteValues.removeAll()
            websiteByValue.removeAll()
        }

        let appsByIdentifier = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, $0) })
        for value in explicitlyIncludedWebsiteValues {
            guard let known = PurposeWebsiteCatalog.website(for: value) else { continue }
            let siteMention = mentions.last { $0.kind == .website && $0.id == value && $0.operation == .include }
            let selection = PurposeWebsiteSelection(
                name: known.name,
                value: known.value,
                browserBundleIdentifier: siteMention?.browserBundleIdentifier
            )
            if websiteByValue[value] == nil { includedWebsiteValues.append(value) }
            websiteByValue[value] = selection
        }

        includedWebsiteValues.removeAll { excludedWebsiteValues.contains($0) }
        for value in excludedWebsiteValues { websiteByValue.removeValue(forKey: value) }
        let excludedBrowserIDs = Set(excludedApps.filter { appsByIdentifier[$0]?.isBrowser == true })
        includedWebsiteValues.removeAll { value in
            guard let browser = websiteByValue[value]?.browserBundleIdentifier else { return false }
            return excludedBrowserIDs.contains(browser)
        }

        let excludedWebsites = excludedWebsiteValues.compactMap { value -> PurposeWebsiteSelection? in
            guard let known = PurposeWebsiteCatalog.website(for: value) else { return nil }
            let mention = mentions.last { $0.kind == .website && $0.id == value }
            return PurposeWebsiteSelection(
                name: known.name,
                value: known.value,
                browserBundleIdentifier: mention?.browserBundleIdentifier
            )
        }

        return PurposeLiveInterpretation(
            includedAppBundleIdentifiers: includedApps,
            excludedAppBundleIdentifiers: excludedApps,
            explicitlyIncludedAppBundleIdentifiers: explicitlyIncludedApps,
            includedWebsites: includedWebsiteValues.compactMap { websiteByValue[$0] },
            excludedWebsites: excludedWebsites,
            explicitlyIncludedWebsiteValues: explicitlyIncludedWebsiteValues,
            includedIntentionIDs: includedIntentions,
            excludedIntentionIDs: excludedIntentions,
            conflictingIntentionIDs: conflictingIntentions,
            usedCorrection: usedCorrection,
            limitsAppsToSelection: limitsAppsToSelection,
            limitsWebsitesToSelection: limitsWebsitesToSelection
        )
    }

    private static func makeAliases(apps: [AllowedApp], intentions: [Intention]) -> [Alias] {
        var aliases: [Alias] = []
        for app in apps {
            var values = [app.name]
            values.append(contentsOf: knownAppAliases[app.bundleIdentifier, default: []])
            for value in values {
                let words = normalizedWords(value)
                if !words.isEmpty { aliases.append(Alias(id: app.bundleIdentifier, kind: .app, words: words)) }
            }
        }
        for website in PurposeWebsiteCatalog.common {
            for value in [website.name] + website.aliases {
                let words = normalizedWords(value)
                if !words.isEmpty { aliases.append(Alias(id: website.value, kind: .website, words: words)) }
            }
        }
        for intention in intentions {
            let words = normalizedWords(intention.name)
            if !words.isEmpty { aliases.append(Alias(id: intention.id, kind: .intention, words: words)) }
        }
        return aliases
    }

    private static func findMentions(in words: [String], aliases: [Alias]) -> [Mention] {
        var matches: [Mention] = []
        for alias in aliases where alias.words.count <= words.count {
            for start in 0...(words.count - alias.words.count) {
                let end = start + alias.words.count
                guard Array(words[start..<end]) == alias.words else { continue }
                if alias.kind == .intention, !hasIntentionMarker(before: start, in: words) { continue }
                let operation = operation(before: start, in: words)
                matches.append(Mention(
                    id: alias.id,
                    kind: alias.kind,
                    start: start,
                    end: end,
                    operation: operation,
                    narrowsSelection: operation == .include && hasNarrowingWord(before: start, in: words),
                    fromPronoun: false,
                    browserBundleIdentifier: nil
                ))
            }
        }

        let grouped = Dictionary(grouping: matches) { "\($0.kind.rawValue):\($0.id):\($0.start)" }
        return grouped.values.compactMap { group in
            group.max { ($0.end - $0.start) < ($1.end - $1.start) }
        }
    }

    private static func fuzzyAppMentions(
        in words: [String],
        aliases: [Alias],
        existing: [Mention]
    ) -> [Mention] {
        let existingKeys = Set(existing.map { "\($0.kind.rawValue):\($0.id):\($0.start)" })
        var matches: [Mention] = []
        for alias in aliases where alias.kind == .app {
            let target = alias.words.joined()
            guard target.count >= 6 else { continue }
            let minimumWindow = max(1, alias.words.count - 1)
            let maximumWindow = min(3, alias.words.count + 1)
            guard minimumWindow <= maximumWindow else { continue }
            for size in minimumWindow...maximumWindow where size <= words.count {
                for start in 0...(words.count - size) {
                    let end = start + size
                    let candidateWords = Array(words[start..<end])
                    guard !candidateWords.contains(markerToken),
                          candidateWords.allSatisfy({ !commandWords.contains($0) }) else { continue }
                    let candidate = candidateWords.joined()
                    guard abs(candidate.count - target.count) <= 2 else { continue }
                    let threshold = target.count >= 9 ? 2 : 1
                    guard levenshteinDistance(candidate, target) <= threshold else { continue }
                    let key = "\(EntityKind.app.rawValue):\(alias.id):\(start)"
                    guard !existingKeys.contains(key) else { continue }
                    let operation = operation(before: start, in: words)
                    matches.append(Mention(
                        id: alias.id,
                        kind: .app,
                        start: start,
                        end: end,
                        operation: operation,
                        narrowsSelection: operation == .include && hasNarrowingWord(before: start, in: words),
                        fromPronoun: false,
                        browserBundleIdentifier: nil
                    ))
                }
            }
        }
        let grouped = Dictionary(grouping: matches) { "\($0.id):\($0.start)" }
        return grouped.values.compactMap { $0.first }
    }

    private static func pronounMentions(in words: [String], existing: [Mention]) -> [Mention] {
        let ordered = existing.sorted { $0.start < $1.start }
        var additions: [Mention] = []
        for index in words.indices where ["it", "that"].contains(words[index]) {
            guard let previous = ordered.last(where: { $0.end <= index }) else { continue }
            let operation = operation(before: index, in: words)
            let prefix = phrase(before: index, count: 5, in: words)
            guard operation == .exclude || containsAny(prefix, phrases: positiveCorrectionPhrases) else { continue }
            additions.append(Mention(
                id: previous.id,
                kind: previous.kind,
                start: index,
                end: index + 1,
                operation: operation,
                narrowsSelection: false,
                fromPronoun: true,
                browserBundleIdentifier: previous.browserBundleIdentifier
            ))
        }
        return additions
    }

    private static func websiteQualifiedMentions(
        in words: [String],
        mentions: [Mention],
        apps: [AllowedApp]
    ) -> [Mention] {
        let browserIDs = Set(apps.filter(\.isBrowser).map(\.bundleIdentifier))
        let browserMentions = mentions.filter {
            $0.kind == .app && browserIDs.contains($0.id) && $0.operation == .include
        }
        var rememberedBrowsers: [String: String] = [:]
        var qualifiedSites: [Mention] = []
        var lastQualifiedBrowser: String?
        var lastQualifiedWebsiteEnd: Int?

        for mention in mentions.filter({ $0.kind == .website }).sorted(by: { $0.start < $1.start }) {
            let appQualifierRange = mention.end..<min(words.count, mention.end + 3)
            let explicitlyRequestsApp = words[appQualifierRange].contains(where: {
                ["app", "application", "desktop"].contains($0)
            })
            if explicitlyRequestsApp { continue }

            let explicitBrowser = explicitlyLinkedBrowser(
                to: mention,
                browserMentions: browserMentions,
                words: words
            )
            let adjacentBrowser = browserMentions
                .filter { $0.end == mention.start }
                .max { $0.start < $1.start }?
                .id
            let chainedBrowser: String?
            if let lastQualifiedBrowser, let lastQualifiedWebsiteEnd,
               lastQualifiedWebsiteEnd <= mention.start,
               words[lastQualifiedWebsiteEnd..<mention.start].allSatisfy({
                   ["and", "plus", "with", "also"].contains($0)
               }) {
                chainedBrowser = lastQualifiedBrowser
            } else {
                chainedBrowser = nil
            }
            let browserMentionedSinceLastWebsite: Bool
            if let lastQualifiedWebsiteEnd {
                browserMentionedSinceLastWebsite = browserMentions.contains {
                    $0.start >= lastQualifiedWebsiteEnd && $0.start < mention.start
                }
            } else {
                browserMentionedSinceLastWebsite = false
            }
            let continuingBrowser = browserMentionedSinceLastWebsite ? nil : lastQualifiedBrowser
            let browser = explicitBrowser
                ?? adjacentBrowser
                ?? chainedBrowser
                ?? rememberedBrowsers[mention.id]
                ?? continuingBrowser
            guard let browser else { continue }
            rememberedBrowsers[mention.id] = browser
            lastQualifiedBrowser = browser
            lastQualifiedWebsiteEnd = mention.end
            qualifiedSites.append(Mention(
                id: mention.id,
                kind: mention.kind,
                start: mention.start,
                end: mention.end,
                operation: mention.operation,
                narrowsSelection: mention.narrowsSelection,
                fromPronoun: mention.fromPronoun,
                browserBundleIdentifier: browser
            ))
        }

        let qualifiedRanges = qualifiedSites.map { ($0.start, $0.end) }
        let nonWebsiteMentions = mentions.filter { mention in
            guard mention.kind != .website else { return false }
            guard mention.kind == .app, !browserIDs.contains(mention.id) else { return true }
            return !qualifiedRanges.contains { start, end in
                max(start, mention.start) < min(end, mention.end)
            }
        }
        return nonWebsiteMentions + qualifiedSites
    }

    private static func explicitlyLinkedBrowser(
        to website: Mention,
        browserMentions: [Mention],
        words: [String]
    ) -> String? {
        let connectors = Set(["with", "on", "in", "through", "using", "via", "inside", "browser", "website", "site"])
        return browserMentions
            .compactMap { browser -> (id: String, distance: Int)? in
                let bridge: ArraySlice<String>
                let distance: Int
                if browser.end <= website.start {
                    bridge = words[browser.end..<website.start]
                    distance = website.start - browser.end
                } else if website.end <= browser.start {
                    bridge = words[website.end..<browser.start]
                    distance = browser.start - website.end
                } else {
                    return nil
                }
                guard distance <= 6, bridge.contains(where: connectors.contains) else { return nil }
                return (browser.id, distance)
            }
            .min { $0.distance < $1.distance }?
            .id
    }

    private static func operation(before start: Int, in words: [String]) -> Operation {
        let prefixWords = Array(words[max(0, start - 8)..<start])
        let positiveIndex = latestPhraseEnd(in: prefixWords, phrases: positivePhrases)
        let negativeIndex = latestPhraseEnd(in: prefixWords, phrases: negativePhrases)
        let correctionIndex = latestPhraseEnd(in: prefixWords, phrases: positiveCorrectionPhrases)

        if let correctionIndex, correctionIndex >= (negativeIndex ?? -1) { return .include }
        if let negativeIndex, negativeIndex >= (positiveIndex ?? -1) { return .exclude }
        return .include
    }

    private static func hasIntentionMarker(before start: Int, in words: [String]) -> Bool {
        let prefix = Array(words[max(0, start - 4)..<start])
        guard let markerIndex = prefix.lastIndex(of: markerToken) else { return false }
        let fillers = Set(["the", "intention", "called", "named"])
        let followingMarker = prefix.index(after: markerIndex)
        return prefix[followingMarker..<prefix.endIndex].allSatisfy { fillers.contains($0) }
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

    private static func normalizedWordsPreservingMarker(_ value: String) -> [String] {
        let canonical = canonicalizedDisplayText(value).replacingOccurrences(of: "*", with: " \(markerToken) ")
        return normalizedWords(canonical)
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

    private static func activeIntentionMentionQuery(in value: String) -> String? {
        guard let marker = value.lastIndex(of: "*") else { return nil }
        let suffix = String(value[value.index(after: marker)...])
        let terminators = CharacterSet(charactersIn: "\n.,;:!?()[]{}")
        guard suffix.rangeOfCharacter(from: terminators) == nil else { return nil }
        return suffix.trimmingCharacters(in: .whitespaces)
    }

    private static func canonicalizedBrowserGroups(in value: String, apps: [AllowedApp]) -> String {
        var result = value
        let sites = PurposeWebsiteCatalog.common
        let siteAliases = sites.flatMap { site in ([site.name] + site.aliases).map { ($0, site) } }
            .sorted { $0.0.count > $1.0.count }
        let sitePattern = siteAliases
            .map { NSRegularExpression.escapedPattern(for: $0.0) }
            .joined(separator: "|")
        guard !sitePattern.isEmpty else { return result }

        for app in apps.filter(\.isBrowser) {
            let aliases = ([app.name] + knownAppAliases[app.bundleIdentifier, default: []])
                .sorted { $0.count > $1.count }
            let browserPattern = aliases
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            guard !browserPattern.isEmpty else { continue }
            let listPattern = "(?:\(sitePattern))(?:\\s*(?:,|and|plus|with)\\s*(?:\(sitePattern)))*"
            let patterns = [
                "(?i)\\b(?:\(browserPattern))\\b\\s*(?:with|using|via|for)\\s*(\(listPattern))",
                "(?i)\\b(?:\(browserPattern))\\b\\s*\\(([^)]*)\\)\\s*(?:and|plus|with)\\s*(\(listPattern))"
            ]

            for (patternIndex, pattern) in patterns.enumerated() {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                let matches = expression.matches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result)
                )
                for match in matches.reversed() {
                    let source = result as NSString
                    var siteText = source.substring(with: match.range(at: 1))
                    if patternIndex == 1, match.numberOfRanges > 2 {
                        siteText += " " + source.substring(with: match.range(at: 2))
                    }
                    let matchedSites = orderedSites(in: siteText, aliases: siteAliases)
                    guard !matchedSites.isEmpty else { continue }
                    let replacement = "\(app.name)(\(matchedSites.map(\.name).joined(separator: ", ")))"
                    guard let swiftRange = Range(match.range, in: result) else { continue }
                    result.replaceSubrange(swiftRange, with: replacement)
                }
            }
        }
        return result
    }

    private static func orderedSites(
        in text: String,
        aliases: [(String, PurposeKnownWebsite)]
    ) -> [PurposeKnownWebsite] {
        var matches: [(location: Int, site: PurposeKnownWebsite)] = []
        for (alias, site) in aliases {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: alias))\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ) else { continue }
            matches.append((match.range.location, site))
        }
        var seen = Set<String>()
        return matches.sorted { $0.location < $1.location }.compactMap { match in
            seen.insert(match.site.value).inserted ? match.site : nil
        }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private static let negativePhrases = [
        "remove", "take away", "get rid of", "without", "exclude", "drop",
        "leave out", "dont use", "do not use", "not use", "dont need",
        "do not need", "dont want", "do not want", "no longer", "stop using",
        "dont add", "do not add", "forget", "cancel", "delete", "clear", "not"
    ]

    private static let positiveCorrectionPhrases = [
        "add back", "put back", "bring back", "keep", "still use", "actually use",
        "do not remove", "dont remove", "restore"
    ]

    private static let positivePhrases = [
        "use", "open", "add", "include", "need", "want", "keep", "with", "plus",
        "also", "bring", "put", "run", "launch", "restore"
    ]

    private static let commandWords = Set(
        negativePhrases.flatMap(normalizedWords)
            + positivePhrases.flatMap(normalizedWords)
            + [markerToken, "actually", "oops", "then"]
    )

    private static let knownAppAliases: [String: [String]] = [
        "com.apple.MobileSMS": ["imessage", "imessages", "i message", "i messages", "messages", "message app"],
        "com.apple.mail": ["mail", "apple mail", "email app"],
        "org.mozilla.firefox": ["firefox", "fire fox"],
        "com.google.Chrome": ["chrome", "google chrome"],
        "com.spotify.client": ["spotify", "spotify app"],
        "com.apple.Notes": ["notes", "apple notes"],
        "com.apple.reminders": ["reminders", "apple reminders"],
        "com.apple.iCal": ["calendar", "apple calendar"],
        "net.ankiweb.dtop": ["anki", "ankee", "an key"],
        "com.rstudio.desktop": ["r studio", "rstudio"],
        "com.microsoft.VSCode": ["v s code", "vs code", "visual studio code"],
        "io.remnote": ["remnote", "rem note", "ram note", "rem node"],
        "com.remnote.desktop": ["remnote", "rem note", "ram note", "rem node"],
        "net.whatsapp.WhatsApp": ["whatsapp", "whats app"],
        "com.hnc.Discord": ["discord"]
    ]
}
