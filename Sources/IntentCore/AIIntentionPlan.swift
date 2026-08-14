import Foundation

public struct AIIntentionPlan: Codable, Equatable {
    public var intentions: [AIIntentionSuggestion]

    public init(intentions: [AIIntentionSuggestion]) {
        self.intentions = intentions
    }
}

public struct AIIntentionSuggestion: Codable, Equatable {
    public var name: String
    public var purpose: String
    public var appBundleIdentifiers: [String]
    public var websites: [AIWebsiteSuggestion]
    public var allowBrowserSearches: Bool
    public var restrictions: [AIRestrictionSuggestion]
    public var frictions: [AIFrictionSuggestion]
    public var isLeisure: Bool

    public init(
        name: String,
        purpose: String,
        appBundleIdentifiers: [String],
        websites: [AIWebsiteSuggestion],
        allowBrowserSearches: Bool,
        restrictions: [AIRestrictionSuggestion] = [],
        frictions: [AIFrictionSuggestion] = [],
        isLeisure: Bool = false
    ) {
        self.name = name
        self.purpose = purpose
        self.appBundleIdentifiers = appBundleIdentifiers
        self.websites = websites
        self.allowBrowserSearches = allowBrowserSearches
        self.restrictions = restrictions
        self.frictions = frictions
        self.isLeisure = isLeisure
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case purpose
        case appBundleIdentifiers
        case websites
        case allowBrowserSearches
        case restrictions
        case frictions
        case isLeisure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        purpose = try container.decode(String.self, forKey: .purpose)
        appBundleIdentifiers = try container.decode([String].self, forKey: .appBundleIdentifiers)
        websites = try container.decode([AIWebsiteSuggestion].self, forKey: .websites)
        allowBrowserSearches = try container.decodeIfPresent(Bool.self, forKey: .allowBrowserSearches) ?? false
        restrictions = try container.decodeIfPresent([AIRestrictionSuggestion].self, forKey: .restrictions) ?? []
        frictions = try container.decodeIfPresent([AIFrictionSuggestion].self, forKey: .frictions) ?? []
        isLeisure = try container.decodeIfPresent(Bool.self, forKey: .isLeisure) ?? false
    }
}

public struct AIRestrictionSuggestion: Codable, Equatable {
    public var kind: RestrictionKind
    public var durationMinutes: Int
    public var resourceIDs: [String]

    public init(
        kind: RestrictionKind,
        durationMinutes: Int = 0,
        resourceIDs: [String] = []
    ) {
        self.kind = kind
        self.durationMinutes = durationMinutes
        self.resourceIDs = resourceIDs
    }
}

public enum AIFrictionKind: String, Codable, Equatable {
    case typedPhrase
    case countdown
    case reasonPrompt
    case taskChecklist
    case timeBudget
}

public struct AIFrictionSuggestion: Codable, Equatable {
    public var kind: AIFrictionKind
    public var text: String
    public var seconds: Int
    public var minutes: Int
    public var tasks: [String]

    public init(
        kind: AIFrictionKind,
        text: String = "",
        seconds: Int = 0,
        minutes: Int = 0,
        tasks: [String] = []
    ) {
        self.kind = kind
        self.text = text
        self.seconds = seconds
        self.minutes = minutes
        self.tasks = tasks
    }

    public func friction(intentionName: String) -> Friction {
        switch kind {
        case .typedPhrase:
            let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .typedPhrase(phrase.isEmpty ? "I want to use \(intentionName) right now" : phrase)
        case .countdown:
            return .countdown(seconds: min(max(seconds, 1), 300))
        case .reasonPrompt:
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .reasonPrompt(prompt.isEmpty ? "What are you here to do?" : prompt)
        case .taskChecklist:
            let cleanedTasks = tasks
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .taskChecklist(cleanedTasks.isEmpty ? ["Finish the intended task"] : cleanedTasks)
        case .timeBudget:
            return .timeBudget(minutes: min(max(minutes, 1), 240))
        }
    }
}

public struct AIWebsiteSuggestion: Codable, Equatable {
    public var value: String
    public var browserBundleIdentifier: String

    public init(value: String, browserBundleIdentifier: String) {
        self.value = value
        self.browserBundleIdentifier = browserBundleIdentifier
    }
}

public enum AIIntentionPrompt {
    public static let system = """
    You design focused computer sessions for Intent, an app that lets a person use only the resources needed for one task at a time.

    Turn the person's request into exactly one specific, reusable intention. An intention is one concrete outcome such as Reply to messages, Write an assignment, or Review pull requests. Do not create a vague category such as Work or Productivity.

    Choose only applications from the installed-app catalog supplied by the user. Copy bundle identifiers exactly. Include only apps genuinely needed for the outcome. Suggest narrow website hosts or paths only when a selected installed app is a browser, and assign each website to that browser's exact bundle identifier. Do not invent applications or bundle identifiers. Keep the name short. Add explicitly requested timers, cooldowns, restrictions, and friction. Never infer or suggest friction from the selected apps, websites, or task; when the user does not explicitly request friction, return no friction. Only allow browser searches when the person explicitly asks to search, browse, Google, look something up, or do research; never infer it merely because a browser is needed. When a request names an existing intention with @ or an intention-id marker, modify that intention and preserve every field the user did not ask to change.
    """

    public static func user(description: String, installedApps: [AllowedApp]) -> String {
        let catalog = installedApps
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { "- \($0.name) | \($0.bundleIdentifier)" }
            .joined(separator: "\n")

        return """
        What this person does on their computer:
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        Installed applications available to choose from:
        \(catalog)
        """
    }
}

public extension AIIntentionPlan {
    func validated(against installedApps: [AllowedApp]) -> AIIntentionPlan {
        let appsByIdentifier = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleIdentifier, $0) })

        let validatedIntentions = intentions.compactMap { suggestion -> AIIntentionSuggestion? in
            let trimmedName = suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }

            let validIdentifiers = Array(
                Set(suggestion.appBundleIdentifiers.filter { appsByIdentifier[$0] != nil })
            ).sorted { left, right in
                let leftName = appsByIdentifier[left]?.name ?? left
                let rightName = appsByIdentifier[right]?.name ?? right
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
            let browserIdentifiers = Set(validIdentifiers.filter(BrowserApplication.isBrowser))
            let websites = suggestion.websites.compactMap { website -> AIWebsiteSuggestion? in
                guard browserIdentifiers.contains(website.browserBundleIdentifier) else { return nil }
                let normalized = AllowedWebsite.normalized(website.value)
                guard !normalized.isEmpty else { return nil }
                return AIWebsiteSuggestion(
                    value: normalized,
                    browserBundleIdentifier: website.browserBundleIdentifier
                )
            }

            let allowedResourceIDs = Set(
                validIdentifiers.map { "app:\($0)" }
                + websites.map { "website:\($0.browserBundleIdentifier):\($0.value)" }
            )
            var seenRestrictionKinds = Set<RestrictionKind>()
            var restrictions = suggestion.restrictions.compactMap { restriction -> AIRestrictionSuggestion? in
                guard seenRestrictionKinds.insert(restriction.kind).inserted else { return nil }
                switch restriction.kind {
                case .allowBrowserSearches:
                    guard !browserIdentifiers.isEmpty else { return nil }
                    return .init(kind: .allowBrowserSearches)
                case .dontStartUp:
                    let resources = restriction.resourceIDs.filter { allowedResourceIDs.contains($0) }
                    guard !resources.isEmpty else { return nil }
                    return .init(kind: .dontStartUp, resourceIDs: resources)
                case .coolDown, .timer:
                    return .init(
                        kind: restriction.kind,
                        durationMinutes: min(max(restriction.durationMinutes, 1), 1_440)
                    )
                case .endTime:
                    return nil
                }
            }
            if suggestion.allowBrowserSearches,
               !browserIdentifiers.isEmpty,
               !seenRestrictionKinds.contains(.allowBrowserSearches) {
                restrictions.append(.init(kind: .allowBrowserSearches))
            }

            let frictions = Array(suggestion.frictions.prefix(3))

            return AIIntentionSuggestion(
                name: trimmedName,
                purpose: suggestion.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                appBundleIdentifiers: validIdentifiers,
                websites: websites,
                allowBrowserSearches: restrictions.contains { $0.kind == .allowBrowserSearches },
                restrictions: restrictions,
                frictions: frictions,
                isLeisure: suggestion.isLeisure
            )
        }

        return AIIntentionPlan(intentions: validatedIntentions)
    }
}
