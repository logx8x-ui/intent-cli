import Foundation

/// Local, resumable onboarding data. The user's answer is the intention name.
public struct FirstIntentionDraft: Codable, Equatable {
    public var name = ""
    public var appIDs: Set<String> = []
    public var websites: [AllowedWebsite] = []
    public var step = 0
    public var savedIntentionID: String?
    public init() {}

    public func makeIntention(availableApps: [AllowedApp]) throws -> Intention {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DraftError.name }
        let chosen = availableApps.filter { appIDs.contains($0.bundleIdentifier) }
        guard !chosen.isEmpty, Set(chosen.map(\.bundleIdentifier)) == appIDs else { throw DraftError.apps }
        for app in chosen where app.isBrowser {
            guard QuickSelection.browsers.contains(app.bundleIdentifier),
                  websites.contains(where: { $0.browserBundleIdentifier == app.bundleIdentifier }) else { throw DraftError.websites }
        }
        guard websites.allSatisfy({ site in
            guard let browser = site.browserBundleIdentifier, appIDs.contains(browser),
                  let url = URL(string: site.startupURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return false }
            return true
        }) else { throw DraftError.websites }
        var intention = Intention(name: title, icon: "target", colorHex: "#34C759", folder: "",
                                  allowedApps: chosen, allowedWebsites: websites, startupActions: [], restrictions: .init())
        intention.selectionOnly = true
        return intention
    }

    public enum DraftError: LocalizedError {
        case name, apps, websites
        public var errorDescription: String? {
            switch self {
            case .name: "Give your first intention a name."
            case .apps: "Choose at least one available app."
            case .websites: "Choose a website for each browser. Intent supports Chrome and Firefox."
            }
        }
    }
}
