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

    public init(
        name: String,
        purpose: String,
        appBundleIdentifiers: [String],
        websites: [AIWebsiteSuggestion],
        allowBrowserSearches: Bool
    ) {
        self.name = name
        self.purpose = purpose
        self.appBundleIdentifiers = appBundleIdentifiers
        self.websites = websites
        self.allowBrowserSearches = allowBrowserSearches
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

    Turn the person's real computer activities into 2 to 8 specific, reusable intentions. An intention is one concrete outcome such as Reply to messages, Write an assignment, or Review pull requests. Do not create vague categories such as Work or Productivity.

    Choose only applications from the installed-app catalog supplied by the user. Copy bundle identifiers exactly. Include only apps genuinely needed for the outcome. Suggest narrow website hosts or paths only when a selected installed app is a browser, and assign each website to that browser's exact bundle identifier. Do not invent applications or bundle identifiers. Keep names short and distinct. Allow browser searches only when discovery or research is genuinely part of the task.
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

            return AIIntentionSuggestion(
                name: trimmedName,
                purpose: suggestion.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                appBundleIdentifiers: validIdentifiers,
                websites: websites,
                allowBrowserSearches: suggestion.allowBrowserSearches && !browserIdentifiers.isEmpty
            )
        }

        return AIIntentionPlan(intentions: validatedIntentions)
    }
}
