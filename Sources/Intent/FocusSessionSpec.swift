import Foundation
import IntentCore

struct FocusSessionSpec {
    let displayName: String
    let startupSteps: [StartupStep]
    let allowedBundleIdentifiers: Set<String>
    let fallbackBundleIdentifier: String
    let strictSingleApp: Bool
    let blockBrowserTabEscape: Bool
    let blockFirefoxChromeClicks: Bool
    let spotifyPlaylistURI: String?
    let allowSpotifyForeground: Bool

    static func make(for task: IntentWorkTask) -> FocusSessionSpec {
        switch task {
        case .shallow(let shallowTask):
            return make(for: shallowTask)
        case .deep(let deepTask):
            return make(for: deepTask)
        }
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
                blockBrowserTabEscape: false,
                blockFirefoxChromeClicks: false,
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
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: true,
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
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: true,
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
                blockBrowserTabEscape: true,
                blockFirefoxChromeClicks: true,
                spotifyPlaylistURI: "spotify:playlist:0fbyat27nV9HP9WlSphWlS",
                allowSpotifyForeground: false
            )
        }
    }
}

enum StartupStep {
    case openBundle(String)
    case openURL(String, bundleIdentifier: String)
    case selectSideberyDataSciencePanel
    case playSpotifyPlaylist(String)
}
