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
    public var graphPosition: GraphPoint
    public var restrictionNodes: [RestrictionNode]
    public var frictionNodes: [FrictionNode]
    public var graphModelVersion: Int
    public var usesCustomIcon: Bool
    public var customIconData: Data?

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
        friction: Friction = .none,
        graphPosition: GraphPoint? = nil,
        restrictionNodes: [RestrictionNode] = [],
        frictionNodes: [FrictionNode] = [],
        graphModelVersion: Int = 4,
        usesCustomIcon: Bool = false,
        customIconData: Data? = nil
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
        self.graphPosition = graphPosition ?? GraphPoint.defaultPosition(for: id)
        self.restrictionNodes = restrictionNodes
        self.frictionNodes = frictionNodes
        self.graphModelVersion = graphModelVersion
        self.usesCustomIcon = usesCustomIcon
        self.customIconData = customIconData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case colorHex
        case folder
        case allowedApps
        case allowedWebsites
        case startupActions
        case restrictions
        case friction
        case graphPosition
        case restrictionNodes
        case frictionNodes
        case graphModelVersion
        case usesCustomIcon
        case customIconData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled intention"
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "target"
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#6B7280"
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        allowedApps = try container.decodeIfPresent([AllowedApp].self, forKey: .allowedApps) ?? []
        allowedWebsites = try container.decodeIfPresent([AllowedWebsite].self, forKey: .allowedWebsites) ?? []
        startupActions = try container.decodeIfPresent([StartupAction].self, forKey: .startupActions) ?? []
        restrictions = try container.decodeIfPresent(RestrictionSet.self, forKey: .restrictions) ?? .init()
        friction = try container.decodeIfPresent(Friction.self, forKey: .friction) ?? .none
        usesCustomIcon = try container.decodeIfPresent(Bool.self, forKey: .usesCustomIcon) ?? false
        customIconData = try container.decodeIfPresent(Data.self, forKey: .customIconData)
        graphPosition = try container.decodeIfPresent(GraphPoint.self, forKey: .graphPosition)
            ?? GraphPoint.defaultPosition(for: id)
        let decodedGraphModelVersion = try container.decodeIfPresent(Int.self, forKey: .graphModelVersion)

        let firstBrowser = allowedApps.first(where: { $0.isBrowser })?.bundleIdentifier
        allowedWebsites = allowedWebsites.map { website in
            var assigned = website
            if assigned.browserBundleIdentifier == nil {
                assigned.browserBundleIdentifier = firstBrowser
            }
            return assigned
        }

        if container.contains(.restrictionNodes) {
            restrictionNodes = try container.decodeIfPresent([RestrictionNode].self, forKey: .restrictionNodes) ?? []
        } else {
            restrictionNodes = Self.migrateRestrictionNodes(
                position: graphPosition,
                allowedApps: allowedApps,
                allowedWebsites: allowedWebsites,
                startupActions: startupActions,
                restrictions: restrictions
            )
        }

        if container.contains(.frictionNodes) {
            frictionNodes = try container.decodeIfPresent([FrictionNode].self, forKey: .frictionNodes) ?? []
        } else if friction != .none {
            frictionNodes = [
                FrictionNode(
                    friction: friction,
                    position: .init(x: graphPosition.x, y: graphPosition.y + 230)
                )
            ]
        } else {
            frictionNodes = []
        }

        graphModelVersion = 4
        if (decodedGraphModelVersion ?? (container.contains(.restrictionNodes) ? 1 : 0)) < 2 {
            restrictionNodes = Self.repairFirstGraphMigration(
                id: id,
                nodes: restrictionNodes,
                allowedApps: allowedApps,
                allowedWebsites: allowedWebsites,
                startupActions: startupActions
            )
        }
    }

    private static func migrateRestrictionNodes(
        position: GraphPoint,
        allowedApps: [AllowedApp],
        allowedWebsites: [AllowedWebsite],
        startupActions: [StartupAction],
        restrictions: RestrictionSet
    ) -> [RestrictionNode] {
        var nodes: [RestrictionNode] = []

        if restrictions.allowGoogleSearchTabs {
            nodes.append(.init(
                kind: .allowBrowserSearches,
                position: .init(x: position.x + 210, y: position.y - 170)
            ))
        }

        var startedApps = Set<String>()
        var startedWebsites = Set<String>()
        for action in startupActions {
            switch action {
            case .openApp(let bundleIdentifier):
                startedApps.insert(bundleIdentifier)
            case .openURL(let url, let browserBundleIdentifier):
                startedApps.insert(browserBundleIdentifier)
                startedWebsites.insert(AllowedWebsite.normalized(url))
            case .selectSideberyDataSciencePanel:
                startedApps.insert("org.mozilla.firefox")
            case .playSpotifyPlaylist:
                startedApps.insert("com.spotify.client")
            }
        }

        let excludedApps = allowedApps
            .filter { !startedApps.contains($0.bundleIdentifier) }
            .map(\.resourceID)
        let excludedWebsites = allowedWebsites
            .filter { website in
                !startedWebsites.contains(where: { startedWebsite in
                    startedWebsite == website.value || startedWebsite.hasPrefix("\(website.value)/")
                })
            }
            .map(\.resourceID)
        let excluded = excludedApps + excludedWebsites

        if !excluded.isEmpty {
            nodes.append(.init(
                kind: .dontStartUp,
                position: .init(x: position.x + 220, y: position.y + 170),
                excludedResourceIDs: excluded
            ))
        }

        return nodes
    }

    private static func repairFirstGraphMigration(
        id: String,
        nodes: [RestrictionNode],
        allowedApps: [AllowedApp],
        allowedWebsites: [AllowedWebsite],
        startupActions: [StartupAction]
    ) -> [RestrictionNode] {
        var repaired = nodes
        let startedWebsites = startupActions.compactMap { action -> String? in
            guard case .openURL(let url, _) = action else { return nil }
            return AllowedWebsite.normalized(url)
        }

        for index in repaired.indices where repaired[index].kind == .dontStartUp {
            if startupActions.isEmpty {
                if id == "data-science" {
                    let intentionalLegacyExclusions = Set([
                        "com.openai.codex",
                        "io.remnote",
                        "com.remnote.desktop"
                    ])
                    repaired[index].excludedResourceIDs = allowedApps
                        .filter { intentionalLegacyExclusions.contains($0.bundleIdentifier) }
                        .map(\.resourceID)
                } else {
                    repaired[index].excludedResourceIDs = []
                }
                continue
            }

            let startupWebsiteResourceIDs = Set(allowedWebsites.compactMap { website -> String? in
                startedWebsites.contains(where: { started in
                    started == website.value || started.hasPrefix("\(website.value)/")
                }) ? website.resourceID : nil
            })
            repaired[index].excludedResourceIDs.removeAll { startupWebsiteResourceIDs.contains($0) }
        }

        return repaired.filter {
            $0.kind != .dontStartUp || !$0.excludedResourceIDs.isEmpty
        }
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
    public var id: String { "\(browserBundleIdentifier ?? "unassigned"):\(value)" }
    public var value: String
    public var browserBundleIdentifier: String?

    public init(_ value: String, browserBundleIdentifier: String? = nil) {
        self.value = Self.normalized(value)
        self.browserBundleIdentifier = browserBundleIdentifier
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
                allowedWebsites: [.init("instagram.com/direct", browserBundleIdentifier: "org.mozilla.firefox")],
                startupActions: [.openURL("https://www.instagram.com/direct/inbox/", browserBundleIdentifier: "org.mozilla.firefox")],
                restrictions: .init(),
                friction: .typedPhrase("I want to use instagram right now"),
                frictionNodes: [
                    .init(
                        id: "instagram-commitment",
                        friction: .typedPhrase("I want to use instagram right now"),
                        position: .init(x: -330, y: 470)
                    )
                ]
            ),
            Intention(
                id: "emails",
                name: "Emails",
                icon: "envelope.fill",
                colorHex: "#D97706",
                folder: "Shallow",
                allowedApps: [.init(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")],
                allowedWebsites: [.init("mail.google.com", browserBundleIdentifier: "org.mozilla.firefox")],
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
                allowedWebsites: [
                    .init("github.com", browserBundleIdentifier: "org.mozilla.firefox"),
                    .init("oasis.curtin.edu.au", browserBundleIdentifier: "org.mozilla.firefox")
                ],
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
                friction: .none,
                restrictionNodes: [
                    .init(
                        id: "data-science-dont-start",
                        kind: .dontStartUp,
                        position: .init(x: 650, y: -20),
                        excludedResourceIDs: [
                            "app:com.openai.codex",
                            "app:io.remnote",
                            "app:com.remnote.desktop"
                        ]
                    )
                ]
            )
        ]
    }
}
