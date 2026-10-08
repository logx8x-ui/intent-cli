import Foundation
import IntentCore

public struct FocusSessionSpec {
    public var hideDistractions = false
    /// The exact shared-rule occurrence whose browser visibility plans this
    /// native lock may own. Nil keeps legacy/CLI sessions out of the bridge.
    public var nativeWindowVisibilitySessionID: String?
    public var browserWindowCoverage: [BrowserWindowCoveragePolicy.Coverage] = []
    public var browserCoverageObservations: [String: WorkspaceWindow.CoverageObservation] = [:]
    public var coverageAllowsLaterWindows = false
    public var initialAllowedApps: Set<String>?
    public var initialSelectedWindows: [String: Set<UInt32>] = [:]
    public var selectedWindowIDsByApp: [String: Set<UInt32>] = [:]
    public let presetAllowedBundleIdentifiers: Set<String>
    public let presetBlockedBundleIdentifiers: Set<String>
    public let accessMode: IntentionAccessMode
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
    public var closeSessionResourcesOnFinish: Bool
    public var restorePreviousApplicationOnStop: Bool
    /// GUI completion releases enforcement without reopening hidden windows.
    /// Legacy CLI specifications retain automatic restoration.
    public var hiddenWorkspaceRestorationOnStop: HiddenWorkspaceRestorationPolicy = .automatic
    /// DBT Run adopts the current permitted work window rather than activating
    /// the first app in the selection. Overview and saved launches keep their
    /// existing explicit startup destination.
    public var preservesCurrentWindowOnStart = false
    public var startupWindowAnchor: FocusStartAnchor?
    public let allowedWebsitesByBrowser: [String: [String]]

    public init(
        displayName: String,
        accessMode: IntentionAccessMode = .whitelist,
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
        allowsManualFinish: Bool = true,
        closeSessionResourcesOnFinish: Bool = false,
        restorePreviousApplicationOnStop: Bool = true,
        allowedWebsitesByBrowser: [String: [String]] = [:],
        selectedWindowIDsByApp: [String: Set<UInt32>] = [:],
        presetBlockedBundleIdentifiers: Set<String> = [],
        presetAllowedBundleIdentifiers: Set<String> = []
    ) {
        self.presetAllowedBundleIdentifiers = presetAllowedBundleIdentifiers
        self.presetBlockedBundleIdentifiers = presetBlockedBundleIdentifiers
        self.selectedWindowIDsByApp = selectedWindowIDsByApp
        self.displayName = displayName
        self.accessMode = accessMode
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
        self.closeSessionResourcesOnFinish = closeSessionResourcesOnFinish
        self.restorePreviousApplicationOnStop = restorePreviousApplicationOnStop
        self.allowedWebsitesByBrowser = allowedWebsitesByBrowser
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
        // An open-ended whitelist uses a deny list at the enforcement layer.
        // Keep the draft's mode and startup choices intact; persistent bans win.
        let openEnded = intention.addAsYouGo && intention.accessMode == .whitelist
        let controlledBundleIdentifiers = openEnded ? intention.presetBlockedBundleIdentifiers
            : (intention.accessMode == .blacklist ? intention.blockedAppBundleIdentifiers.union(intention.presetBlockedBundleIdentifiers)
                : Set(intention.allowedApps.map(\.bundleIdentifier)))
        let fallback = intention.accessMode == .blacklist || (intention.isLeisure && startupSteps.isEmpty)
            ? ""
            : IntentionStartupPlanner.fallbackBundleIdentifier(for: intention)
        let spotifyPlaylistURI = intention.accessMode == .blacklist ? nil : intention.startupActions.compactMap { action in
            if case .playSpotifyPlaylist(let uri) = action,
               !intention.dontStartResourceIDs.contains("app:com.spotify.client") {
                return uri
            }
            return nil
        }.first

        return FocusSessionSpec(
            displayName: intention.name,
            accessMode: openEnded ? .blacklist : intention.accessMode,
            startupSteps: startupSteps,
            allowedBundleIdentifiers: controlledBundleIdentifiers,
            fallbackBundleIdentifier: fallback,
            strictSingleApp: !openEnded && intention.accessMode == .whitelist && !intention.isLeisure && intention.allowedApps.count == 1,
            blockAppSwitching: !intention.isLeisure,
            blockNewApps: !intention.isLeisure,
            keepFocused: !intention.isLeisure,
            blockBrowserTabEscape: !openEnded && !intention.isLeisure && (
                intention.accessMode == .whitelist
                    ? intention.allowedApps.contains { $0.isBrowser && !intention.wholeBrowserBundleIdentifiers.contains($0.bundleIdentifier) }
                    : !intention.allowedWebsites.isEmpty || !intention.selectionBrowserBundleIdentifiers.isEmpty
            ),
            blockFirefoxChromeClicks: false,
            allowGoogleSearchTabs: intention.browserSearchesAllowed,
            spotifyPlaylistURI: spotifyPlaylistURI,
            allowSpotifyForeground: intention.allowedApps.contains { $0.bundleIdentifier == "com.spotify.client" },
            finishShortcut: finishShortcut,
            allowsManualFinish: !intention.sessionLocksManualFinish,
            closeSessionResourcesOnFinish: intention.accessMode == .whitelist && intention.closeSessionResourcesOnFinish,
            allowedWebsitesByBrowser: Dictionary(
                grouping: intention.allowedWebsites.compactMap { website -> (String, String)? in
                    guard let browser = website.browserBundleIdentifier else { return nil }
                    return (browser, website.value)
                },
                by: \.0
            ).mapValues { $0.map(\.1) },
            presetBlockedBundleIdentifiers: intention.presetBlockedBundleIdentifiers,
            presetAllowedBundleIdentifiers: intention.presetAllowedBundleIdentifiers.union(intention.accessMode == .whitelist ? intention.wholeBrowserBundleIdentifiers : [])
        )
    }

    public func deferringBrowserWebsiteStartupToGuard() -> FocusSessionSpec {
        var activatedBrowsers = Set<String>()
        let guardedStartupSteps = startupSteps.compactMap { step -> StartupStep? in
            guard case .openURL(_, let bundleIdentifier) = step else {
                return step
            }
            guard activatedBrowsers.insert(bundleIdentifier).inserted else {
                return nil
            }
            return .openBundle(bundleIdentifier)
        }

        var result = FocusSessionSpec(
            displayName: displayName,
            accessMode: accessMode,
            startupSteps: guardedStartupSteps,
            allowedBundleIdentifiers: allowedBundleIdentifiers,
            fallbackBundleIdentifier: fallbackBundleIdentifier,
            strictSingleApp: strictSingleApp,
            blockAppSwitching: blockAppSwitching,
            blockNewApps: blockNewApps,
            keepFocused: keepFocused,
            blockBrowserTabEscape: blockBrowserTabEscape,
            blockFirefoxChromeClicks: blockFirefoxChromeClicks,
            allowGoogleSearchTabs: allowGoogleSearchTabs,
            spotifyPlaylistURI: spotifyPlaylistURI,
            allowSpotifyForeground: allowSpotifyForeground,
            finishShortcut: finishShortcut,
            allowsManualFinish: allowsManualFinish,
            closeSessionResourcesOnFinish: closeSessionResourcesOnFinish,
            restorePreviousApplicationOnStop: restorePreviousApplicationOnStop,
            allowedWebsitesByBrowser: allowedWebsitesByBrowser,
            selectedWindowIDsByApp: selectedWindowIDsByApp,
            presetBlockedBundleIdentifiers: presetBlockedBundleIdentifiers,
            presetAllowedBundleIdentifiers: presetAllowedBundleIdentifiers
        )
        result.hideDistractions = hideDistractions
        result.nativeWindowVisibilitySessionID = nativeWindowVisibilitySessionID
        result.browserWindowCoverage = browserWindowCoverage
        result.browserCoverageObservations = browserCoverageObservations
        result.coverageAllowsLaterWindows = coverageAllowsLaterWindows
        result.initialAllowedApps = initialAllowedApps
        result.initialSelectedWindows = initialSelectedWindows
        result.hiddenWorkspaceRestorationOnStop = hiddenWorkspaceRestorationOnStop
        result.preservesCurrentWindowOnStart = preservesCurrentWindowOnStart
        result.startupWindowAnchor = startupWindowAnchor
        return result
    }

    /// Restore Intent-owned visibility without returning to the session-start
    /// app or closing resources. Already minimized/hidden user windows are not
    /// owned and must remain as they were.
    public func preservingForegroundOnStop() -> FocusSessionSpec {
        var result = self
        result.restorePreviousApplicationOnStop = false
        result.closeSessionResourcesOnFinish = false
        result.hiddenWorkspaceRestorationOnStop = .restoreOwnedWorkspace
        return result
    }

    public func shouldPreserveCurrentWindowOnStart(windowID: UInt32?, bundleIdentifier: String?,
                                                   controllerBundleIdentifier: String?) -> Bool {
        guard preservesCurrentWindowOnStart, startupSteps.isEmpty,
              let windowID, let bundleIdentifier, bundleIdentifier != controllerBundleIdentifier else { return false }
        return permitsWindow(windowID, bundleIdentifier: bundleIdentifier)
    }

    public static func workPeriodIdle(
        controllerBundleIdentifier: String,
        alwaysAllowed: Set<String>,
        currentWorkBundleIdentifier: String?,
        presentWorkspace: Bool,
        finishShortcut: FocusKeyboardShortcut
    ) -> FocusSessionSpec {
        let current = currentWorkBundleIdentifier.flatMap {
            $0 == "com.apple.loginwindow" || $0 == controllerBundleIdentifier ? nil : $0
        }
        return FocusSessionSpec(
            displayName: "Require an intention", startupSteps: [],
            allowedBundleIdentifiers: alwaysAllowed.union([controllerBundleIdentifier]).union(current.map { [$0] } ?? []),
            fallbackBundleIdentifier: presentWorkspace ? controllerBundleIdentifier : "",
            strictSingleApp: false, blockAppSwitching: false, blockNewApps: true,
            keepFocused: true, blockBrowserTabEscape: false, blockFirefoxChromeClicks: false,
            allowGoogleSearchTabs: false, spotifyPlaylistURI: nil, allowSpotifyForeground: false,
            finishShortcut: finishShortcut, allowsManualFinish: false,
            closeSessionResourcesOnFinish: false, restorePreviousApplicationOnStop: false
        )
    }

    public var applicationWideControlledBundleIdentifiers: Set<String> {
        accessMode == .blacklist ? allowedBundleIdentifiers.subtracting(selectedWindowIDsByApp.keys) : allowedBundleIdentifiers
    }

    public func permitsWindow(_ id: UInt32, bundleIdentifier: String) -> Bool {
        if FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) { return true }
        if presetBlockedBundleIdentifiers.contains(bundleIdentifier) { return false }
        guard let ids = selectedWindowIDsByApp[bundleIdentifier] else { return permitsApplication(bundleIdentifier) }
        return accessMode == .whitelist ? ids.contains(id) : !ids.contains(id)
    }

    public func permitsApplication(_ bundleIdentifier: String) -> Bool {
        if FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) { return true }
        if presetBlockedBundleIdentifiers.contains(bundleIdentifier) { return false }
        if !requiresEnforcement { return true }
        if selectedWindowIDsByApp[bundleIdentifier] != nil { return true }
        switch accessMode {
        case .whitelist: return allowedBundleIdentifiers.contains(bundleIdentifier)
        case .blacklist: return !allowedBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    public var requiresEnforcement: Bool {
        blockAppSwitching || blockNewApps || keepFocused || blockBrowserTabEscape || blockFirefoxChromeClicks
    }

    public func shouldHideApplication(_ bundleIdentifier: String, initialAllowedApps: Set<String>?) -> Bool {
        guard !FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) else { return false }
        return !permitsApplication(bundleIdentifier) || initialAllowedApps.map { !$0.contains(bundleIdentifier) } == true
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
        guard intention.isLeisure || intention.accessMode == .whitelist else { return [] }
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

public enum BrowserLaunchPlanner {
    public static func openArguments(
        bundleIdentifier: String,
        url: String,
        isRunning: Bool
    ) -> [String] {
        if !isRunning, bundleIdentifier == "org.mozilla.firefox" {
            return ["-b", bundleIdentifier, "--args", "-url", url]
        }
        return ["-b", bundleIdentifier, url]
    }
}
