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
        allowSpotifyForeground: Bool
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
    }

    public static func make(for task: IntentWorkTask) -> FocusSessionSpec {
        switch task {
        case .shallow(let shallowTask):
            return make(for: shallowTask)
        case .deep(let deepTask):
            return make(for: deepTask)
        }
    }

    public static func make(for intention: Intention) -> FocusSessionSpec {
        FocusSessionSpec(
            displayName: intention.name,
            startupSteps: intention.startupActions.map(StartupStep.init),
            allowedBundleIdentifiers: Set(intention.allowedApps.map(\.bundleIdentifier)),
            fallbackBundleIdentifier: intention.allowedApps.first?.bundleIdentifier ?? "org.mozilla.firefox",
            strictSingleApp: intention.allowedApps.count == 1 && intention.restrictions.blockAppSwitching,
            blockAppSwitching: intention.restrictions.blockAppSwitching,
            blockNewApps: intention.restrictions.blockNewApps,
            keepFocused: intention.restrictions.keepFocused,
            blockBrowserTabEscape: intention.restrictions.blockBrowserTabSwitching,
            blockFirefoxChromeClicks: false,
            allowGoogleSearchTabs: intention.restrictions.allowGoogleSearchTabs,
            spotifyPlaylistURI: intention.startupActions.compactMap { action in
                if case .playSpotifyPlaylist(let uri) = action {
                    return uri
                }
                return nil
            }.first,
            allowSpotifyForeground: intention.allowedApps.contains { $0.bundleIdentifier == "com.spotify.client" } && intention.id != "data-science"
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

public enum StartupStep {
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
