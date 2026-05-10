import Foundation

public struct Intention: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var icon: String
    public var colorHex: String
    public var folder: String
    public var allowedApps: [AllowedApp]
    public var allowedWebsites: [AllowedWebsite]
    public var startupActions: [StartupAction]
    public var restrictions: RestrictionSet
    public var friction: Friction

    public init(
        id: String = UUID().uuidString,
        name: String,
        icon: String,
        colorHex: String,
        folder: String,
        allowedApps: [AllowedApp],
        allowedWebsites: [AllowedWebsite],
        startupActions: [StartupAction],
        restrictions: RestrictionSet,
        friction: Friction = .none
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.folder = folder
        self.allowedApps = allowedApps
        self.allowedWebsites = allowedWebsites
        self.startupActions = startupActions
        self.restrictions = restrictions
        self.friction = friction
    }
}

public struct AllowedApp: Codable, Equatable, Identifiable {
    public var id: String { bundleIdentifier }
    public var name: String
    public var bundleIdentifier: String

    public init(name: String, bundleIdentifier: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AllowedWebsite: Codable, Equatable, Identifiable {
    public var id: String { value }
    public var value: String

    public init(_ value: String) {
        self.value = Self.normalized(value)
    }

    public var displayName: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if trimmed.contains("://") {
            urlString = trimmed
        } else {
            urlString = "https://\(trimmed)"
        }

        guard let url = URL(string: urlString),
              var host = url.host?.lowercased() else {
            return trimmed
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .components(separatedBy: "/")
                .first?
                .components(separatedBy: ".")
                .first ?? trimmed
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        return host.components(separatedBy: ".").first ?? host
    }

    public static func normalized(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: urlString),
              var host = url.host?.lowercased() else {
            return trimmed
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }
}

public enum StartupAction: Codable, Equatable, Identifiable {
    case openApp(String)
    case openURL(String, browserBundleIdentifier: String)
    case selectSideberyDataSciencePanel
    case playSpotifyPlaylist(String)

    public var id: String {
        switch self {
        case .openApp(let bundleIdentifier): "openApp:\(bundleIdentifier)"
        case .openURL(let url, let browser): "openURL:\(browser):\(url)"
        case .selectSideberyDataSciencePanel: "selectSideberyDataSciencePanel"
        case .playSpotifyPlaylist(let uri): "playSpotifyPlaylist:\(uri)"
        }
    }
}

public struct RestrictionSet: Codable, Equatable {
    public var blockAppSwitching: Bool
    public var blockNewApps: Bool
    public var blockBrowserTabSwitching: Bool
    public var blockBrowserNavigation: Bool
    public var blockNewBrowserTabs: Bool
    public var keepFocused: Bool
    public var allowGoogleSearchTabs: Bool

    public init(
        blockAppSwitching: Bool = true,
        blockNewApps: Bool = true,
        blockBrowserTabSwitching: Bool = true,
        blockBrowserNavigation: Bool = true,
        blockNewBrowserTabs: Bool = true,
        keepFocused: Bool = true,
        allowGoogleSearchTabs: Bool = false
    ) {
        self.blockAppSwitching = blockAppSwitching
        self.blockNewApps = blockNewApps
        self.blockBrowserTabSwitching = blockBrowserTabSwitching
        self.blockBrowserNavigation = blockBrowserNavigation
        self.blockNewBrowserTabs = blockNewBrowserTabs
        self.keepFocused = keepFocused
        self.allowGoogleSearchTabs = allowGoogleSearchTabs
    }

    enum CodingKeys: String, CodingKey {
        case blockAppSwitching
        case blockNewApps
        case blockBrowserTabSwitching
        case blockBrowserNavigation
        case blockNewBrowserTabs
        case keepFocused
        case allowGoogleSearchTabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockAppSwitching = try container.decodeIfPresent(Bool.self, forKey: .blockAppSwitching) ?? true
        blockNewApps = try container.decodeIfPresent(Bool.self, forKey: .blockNewApps) ?? true
        blockBrowserTabSwitching = try container.decodeIfPresent(Bool.self, forKey: .blockBrowserTabSwitching) ?? true
        blockBrowserNavigation = try container.decodeIfPresent(Bool.self, forKey: .blockBrowserNavigation) ?? true
        blockNewBrowserTabs = try container.decodeIfPresent(Bool.self, forKey: .blockNewBrowserTabs) ?? true
        keepFocused = try container.decodeIfPresent(Bool.self, forKey: .keepFocused) ?? true
        allowGoogleSearchTabs = try container.decodeIfPresent(Bool.self, forKey: .allowGoogleSearchTabs) ?? false
    }
}

public enum Friction: Codable, Equatable {
    case none
    case typedPhrase(String)
    case countdown(seconds: Int)
    case reasonPrompt(String)
    case taskChecklist([String])
    case timeBudget(minutes: Int)

    public func validate(_ input: String) -> Bool {
        switch self {
        case .none:
            true
        case .typedPhrase(let phrase):
            input == phrase
        case .countdown, .reasonPrompt, .taskChecklist, .timeBudget:
            !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .typedPhrase: "Typed phrase"
        case .countdown: "Countdown"
        case .reasonPrompt: "Reason prompt"
        case .taskChecklist: "Task checklist"
        case .timeBudget: "Time budget"
        }
    }
}

public enum DefaultIntentions {
    public static func make() -> [Intention] {
        [
            Intention(
                id: "imessages",
                name: "Imessages",
                icon: "message.fill",
                colorHex: "#4A90E2",
                folder: "Shallow",
                allowedApps: [.init(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")],
                allowedWebsites: [],
                startupActions: [.openApp("com.apple.MobileSMS")],
                restrictions: .init(blockBrowserTabSwitching: false, blockBrowserNavigation: false, blockNewBrowserTabs: false)
            ),
            Intention(
                id: "instagram-replies",
                name: "Instagram replies",
                icon: "bubble.left.and.bubble.right.fill",
                colorHex: "#D9487D",
                folder: "Shallow",
                allowedApps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")],
                allowedWebsites: [.init("instagram.com/direct")],
                startupActions: [.openURL("https://www.instagram.com/direct/inbox/", browserBundleIdentifier: "org.mozilla.firefox")],
                restrictions: .init(),
                friction: .typedPhrase("I want to use instagram right now")
            ),
            Intention(
                id: "emails",
                name: "Emails",
                icon: "envelope.fill",
                colorHex: "#D97706",
                folder: "Shallow",
                allowedApps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")],
                allowedWebsites: [.init("mail.google.com")],
                startupActions: [.openURL("https://mail.google.com/mail/u/0/#inbox", browserBundleIdentifier: "org.mozilla.firefox")],
                restrictions: .init()
            ),
            Intention(
                id: "data-science",
                name: "Data Science",
                icon: "function",
                colorHex: "#7C3AED",
                folder: "Deep",
                allowedApps: [
                    .init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
                    .init(name: "RStudio", bundleIdentifier: "com.rstudio.desktop"),
                    .init(name: "Codex", bundleIdentifier: "com.openai.codex"),
                    .init(name: "RemNote", bundleIdentifier: "io.remnote"),
                    .init(name: "RemNote", bundleIdentifier: "com.remnote.desktop"),
                    .init(name: "Spotify", bundleIdentifier: "com.spotify.client")
                ],
                allowedWebsites: [.init("github.com"), .init("oasis.curtin.edu.au")],
                startupActions: [
                    .openApp("com.rstudio.desktop"),
                    .openApp("org.mozilla.firefox"),
                    .selectSideberyDataSciencePanel,
                    .openURL("https://github.com/", browserBundleIdentifier: "org.mozilla.firefox"),
                    .openURL("https://oasis.curtin.edu.au/", browserBundleIdentifier: "org.mozilla.firefox"),
                    .openApp("com.spotify.client"),
                    .playSpotifyPlaylist("spotify:playlist:0fbyat27nV9HP9WlSphWlS")
                ],
                restrictions: .init(),
                friction: .none
            )
        ]
    }
}
