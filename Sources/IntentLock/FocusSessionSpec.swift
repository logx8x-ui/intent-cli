import Foundation
import IntentCore

public struct FocusSessionSpec {
    public let displayName: String
    public let startupSteps: [StartupStep]
    public let allowedBundleIdentifiers: Set<String>
    public let fallbackBundleIdentifier: String
    public let strictSingleApp: Bool
    public let blockAppSwitching: Bool
    public let blockNewApps: Bool
    public let keepFocused: Bool
    public let blockBrowserTabEscape: Bool
    public let blockFirefoxChromeClicks: Bool
    public let allowGoogleSearchTabs: Bool
    public let spotifyPlaylistURI: String?
    public let allowSpotifyForeground: Bool
    public let finishShortcut: FocusKeyboardShortcut
    public let allowsManualFinish: Bool

    public init(
        displayName: String,
        startupSteps: [StartupStep],
        allowedBundleIdentifiers: Set<String>,
        fallbackBundleIdentifier: String,
        strictSingleApp: Bool,
        blockAppSwitching: Bool,
        blockNewApps: Bool,
        keepFocused: Bool,
        blockBrowserTabEscape: Bool,
        blockFirefoxChromeClicks: Bool,
        allowGoogleSearchTabs: Bool,
        spotifyPlaylistURI: String?,
        allowSpotifyForeground: Bool,
        finishShortcut: FocusKeyboardShortcut = .defaultFinish,
        allowsManualFinish: Bool = true
    ) {
        self.displayName = displayName
        self.startupSteps = startupSteps
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.fallbackBundleIdentifier = fallbackBundleIdentifier
        self.strictSingleApp = strictSingleApp
        self.blockAppSwitching = blockAppSwitching
        self.blockNewApps = blockNewApps
        self.keepFocused = keepFocused
        self.blockBrowserTabEscape = blockBrowserTabEscape
        self.blockFirefoxChromeClicks = blockFirefoxChromeClicks
        self.allowGoogleSearchTabs = allowGoogleSearchTabs
        self.spotifyPlaylistURI = spotifyPlaylistURI
        self.allowSpotifyForeground = allowSpotifyForeground
        self.finishShortcut = finishShortcut
        self.allowsManualFinish = allowsManualFinish
    }

    public static func make(for task: IntentWorkTask) -> FocusSessionSpec {
        switch task {
        case .shallow(let shallowTask):
            return make(for: shallowTask)
        case .deep(let deepTask):
            return make(for: deepTask)
        }
    }

    public static func make(
        for intention: Intention,
        finishShortcut: FocusKeyboardShortcut = .defaultFinish
    ) -> FocusSessionSpec {
        let startupSteps = IntentionStartupPlanner.steps(for: intention)
        let fallback = IntentionStartupPlanner.fallbackBundleIdentifier(for: intention)
        let spotifyPlaylistURI = intention.startupActions.compactMap { action in
            if case .playSpotifyPlaylist(let uri) = action,
               !intention.dontStartResourceIDs.contains("app:com.spotify.client") {
                return uri
            }
            return nil
        }.first

        return FocusSessionSpec(
            displayName: intention.name,
            startupSteps: startupSteps,
            allowedBundleIdentifiers: Set(intention.allowedApps.map(\.bundleIdentifier)),
            fallbackBundleIdentifier: fallback,
            strictSingleApp: intention.allowedApps.count == 1,
            blockAppSwitching: true,
            blockNewApps: true,
            keepFocused: true,
            blockBrowserTabEscape: intention.allowedApps.contains(where: \.isBrowser),
            blockFirefoxChromeClicks: false,
            allowGoogleSearchTabs: intention.browserSearchesAllowed,
            spotifyPlaylistURI: spotifyPlaylistURI,
            allowSpotifyForeground: intention.allowedApps.contains { $0.bundleIdentifier == "com.spotify.client" },
            finishShortcut: finishShortcut,
            allowsManualFinish: !intention.timerLocksManualFinish
        )
    }

    private static func make(for task: ShallowTask) -> FocusSessionSpec {
        switch task {
        case .imessages:
            return FocusSessionSpec(
                displayName: task.displayName,
                startupSteps: [.openBundle(task.bundleIdentifier)],
                allowedBundleIdentifiers: [task.bundleIdentifier],
                fallbackBundleIdentifier: task.bundleIdentifier,
                strictSingleApp: true,
                blockAppSwitching: true,
                blockNewApps: true,
                keepFocused: true,
                blockBrowserTabEscape: false,
                blockFirefoxChromeClicks: false,
                allowGoogleSearchTabs: false,
                spotifyPlaylistURI: nil,
                allowSpotifyForeground: false
            )

        case .instagramReplies:
            return FocusSessionSpec(
                displayName: task.displayName,
                startupSteps: [
                    .openURL("https://www.instagram.com/direct/inbox/", bundleIdentifier: task.bundleIdentifier)
                ],
                allowedBundleIdentifiers: [task.bundleIdentifier],
                fallbackBundleIdentifier: task.bundleIdentifier,
                strictSingleApp: true,
                blockAppSwitching: true,
                blockNewApps: true,
                keepFocused: true,
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: false,
                allowGoogleSearchTabs: false,
                spotifyPlaylistURI: nil,
                allowSpotifyForeground: false
            )

        case .emails:
            return FocusSessionSpec(
                displayName: task.displayName,
                startupSteps: [
                    .openURL("https://mail.google.com/mail/u/0/#inbox", bundleIdentifier: task.bundleIdentifier)
                ],
                allowedBundleIdentifiers: [task.bundleIdentifier],
                fallbackBundleIdentifier: task.bundleIdentifier,
                strictSingleApp: true,
                blockAppSwitching: true,
                blockNewApps: true,
                keepFocused: true,
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: false,
                allowGoogleSearchTabs: false,
                spotifyPlaylistURI: nil,
                allowSpotifyForeground: false
            )
        }
    }

    private static func make(for task: DeepTask) -> FocusSessionSpec {
        switch task {
        case .dataScience:
            return FocusSessionSpec(
                displayName: task.displayName,
                startupSteps: [
                    .openBundle("com.rstudio.desktop"),
                    .openBundle("org.mozilla.firefox"),
                    .selectSideberyDataSciencePanel,
                    .openURL("https://github.com/", bundleIdentifier: "org.mozilla.firefox"),
                    .openURL("https://oasis.curtin.edu.au/", bundleIdentifier: "org.mozilla.firefox"),
                    .openBundle("com.spotify.client"),
                    .playSpotifyPlaylist("spotify:playlist:0fbyat27nV9HP9WlSphWlS")
                ],
                allowedBundleIdentifiers: [
                    "org.mozilla.firefox",
                    "com.rstudio.desktop",
                    "com.openai.codex",
                    "io.remnote",
                    "com.spotify.client"
                ],
                fallbackBundleIdentifier: "com.rstudio.desktop",
                strictSingleApp: false,
                blockAppSwitching: true,
                blockNewApps: true,
                keepFocused: true,
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: false,
                allowGoogleSearchTabs: false,
                spotifyPlaylistURI: "spotify:playlist:0fbyat27nV9HP9WlSphWlS",
                allowSpotifyForeground: false
            )
        }
    }
}

public enum IntentionStartupPlanner {
    public static func steps(for intention: Intention) -> [StartupStep] {
        let excluded = intention.dontStartResourceIDs
        let websiteSteps = intention.allowedWebsites.compactMap { website -> StartupStep? in
            guard !excluded.contains(website.resourceID),
                  let browserBundleIdentifier = website.browserBundleIdentifier,
                  intention.allowedApps.contains(where: { $0.bundleIdentifier == browserBundleIdentifier }),
                  !excluded.contains("app:\(browserBundleIdentifier)") else {
                return nil
            }
            return .openURL(website.startupURL, bundleIdentifier: browserBundleIdentifier)
        }
        let browsersStartedByURL = Set(websiteSteps.compactMap { step -> String? in
            guard case .openURL(_, let bundleIdentifier) = step else { return nil }
            return bundleIdentifier
        })
        var steps = websiteSteps

        steps.append(contentsOf: intention.allowedApps.compactMap { app in
            guard !excluded.contains(app.resourceID),
                  !browsersStartedByURL.contains(app.bundleIdentifier) else {
                return nil
            }
            return .openBundle(app.bundleIdentifier)
        })

        if intention.startupActions.contains(.selectSideberyDataSciencePanel),
           !excluded.contains("app:org.mozilla.firefox") {
            steps.append(.selectSideberyDataSciencePanel)
        }

        for action in intention.startupActions {
            guard case .playSpotifyPlaylist(let uri) = action,
                  !excluded.contains("app:com.spotify.client") else {
                continue
            }
            steps.append(.playSpotifyPlaylist(uri))
        }

        return steps
    }

    public static func fallbackBundleIdentifier(for intention: Intention) -> String {
        let excluded = intention.dontStartResourceIDs
        if let browserBundleIdentifier = intention.allowedWebsites.compactMap({ website -> String? in
            guard !excluded.contains(website.resourceID),
                  let browserBundleIdentifier = website.browserBundleIdentifier,
                  !excluded.contains("app:\(browserBundleIdentifier)"),
                  intention.allowedApps.contains(where: { $0.bundleIdentifier == browserBundleIdentifier }) else {
                return nil
            }
            return browserBundleIdentifier
        }).first {
            return browserBundleIdentifier
        }
        return intention.allowedApps.first(where: { !excluded.contains($0.resourceID) })?.bundleIdentifier
            ?? intention.allowedApps.first?.bundleIdentifier
            ?? "org.mozilla.firefox"
    }
}

public struct FocusKeyboardShortcut: Equatable {
    public let keyCode: Int64
    public let command: Bool
    public let shift: Bool
    public let control: Bool
    public let option: Bool

    public init(
        keyCode: Int64,
        command: Bool,
        shift: Bool,
        control: Bool,
        option: Bool
    ) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.control = control
        self.option = option
    }

    public static let defaultFinish = FocusKeyboardShortcut(
        keyCode: KeyCode.m,
        command: true,
        shift: true,
        control: false,
        option: false
    )

    func matches(
        keyCode: Int64,
        command: Bool,
        shift: Bool,
        control: Bool,
        option: Bool
    ) -> Bool {
        self.keyCode == keyCode &&
            self.command == command &&
            self.shift == shift &&
            self.control == control &&
            self.option == option
    }
}

public enum StartupStep: Equatable {
    case openBundle(String)
    case openURL(String, bundleIdentifier: String)
    case selectSideberyDataSciencePanel
    case playSpotifyPlaylist(String)

    init(_ action: StartupAction) {
        switch action {
        case .openApp(let bundleIdentifier):
            self = .openBundle(bundleIdentifier)
        case .openURL(let url, let browserBundleIdentifier):
            self = .openURL(url, bundleIdentifier: browserBundleIdentifier)
        case .selectSideberyDataSciencePanel:
            self = .selectSideberyDataSciencePanel
        case .playSpotifyPlaylist(let uri):
            self = .playSpotifyPlaylist(uri)
        }
    }
}
