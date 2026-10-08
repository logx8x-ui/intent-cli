import Foundation
import IntentCore
import IntentLock

func runSystemCaptureRegressionSpecs() throws {
    // Reproduce the actual earlier gate: a browser with zero permitted tabs is
    // inert before its browser-shortcut policy runs. Capture must bypass both.
    for code in [Int64(20), 21, 23, 22] { // macOS physical 3, 4, 5, 6
        for control in [false, true] {
            for option in [false, true] {
                for tabSearches in [false, true] {
                    var blockedWindowProbes = 0
                    func blockedWindow() -> Bool { blockedWindowProbes += 1; return true }
                    try expect(FocusSystemShortcutPolicy.isScreenshotShortcut(keyCode: code, command: true, shift: true),
                        "Screenshot chords bypass session input before Finish or browser routing")
                    try expect(!FocusSystemShortcutPolicy.shouldBlockInertBrowserInput(keyCode: code,
                        command: true, control: control, option: option, shift: true,
                        allowGoogleSearchTabs: tabSearches, hasPanelKeyboardFocus: false,
                        windowBlocked: blockedWindow()),
                        "Native and clipboard capture remain available above an otherwise inert browser window")
                    try expect(blockedWindowProbes == 0, "Capture does not consult stale browser blocking geometry")
                    try expect(!FocusBrowserShortcutPolicy.shouldBlock(keyCode: code, command: true,
                        control: control, option: option, shift: true, allowGoogleSearchTabs: tabSearches),
                        "The subsequent browser command policy also permits screenshot chords")
                }
            }
        }
        try expect(FocusSystemShortcutPolicy.shouldBlockInertBrowserInput(keyCode: code,
            command: true, control: false, option: false, shift: false,
            allowGoogleSearchTabs: false, hasPanelKeyboardFocus: false, windowBlocked: true),
            "Ordinary numeric tab shortcuts cannot activate an entirely forbidden browser window")
    }
    try expect(FocusSystemShortcutPolicy.shouldBlockInertBrowserInput(keyCode: 15,
        command: true, control: false, option: false, shift: true,
        allowGoogleSearchTabs: false, hasPanelKeyboardFocus: false, windowBlocked: true),
        "Screenshot exemptions do not widen to other Command-Shift shortcuts")
    let preservedInputs: [(Int64, Bool, Bool, Bool)] = [
        (50, false, false, false), (48, false, true, false), (48, true, false, false),
        (123, false, true, false), (17, true, false, true)
    ]
    for (code, command, control, searches) in preservedInputs {
        try expect(!FocusSystemShortcutPolicy.shouldBlockInertBrowserInput(keyCode: code,
            command: command, control: control, option: false, shift: false,
            allowGoogleSearchTabs: searches, hasPanelKeyboardFocus: false, windowBlocked: true),
            "Existing grave, switcher, Space and fresh-search controls retain their input exemptions")
    }

    for mode: IntentionAccessMode in [.whitelist, .blacklist] {
        for bundle in ["com.apple.screencaptureui", "com.apple.screenshot.launcher"] {
            let spec = FocusSessionSpec(displayName: "Capture regression", accessMode: mode,
                startupSteps: [], allowedBundleIdentifiers: mode == .whitelist ? ["org.mozilla.firefox"] : [bundle],
                fallbackBundleIdentifier: "org.mozilla.firefox", strictSingleApp: true,
                blockAppSwitching: true, blockNewApps: true, keepFocused: true,
                blockBrowserTabEscape: true, blockFirefoxChromeClicks: false,
                allowGoogleSearchTabs: false, spotifyPlaylistURI: nil, allowSpotifyForeground: false,
                selectedWindowIDsByApp: [bundle: [99]], presetBlockedBundleIdentifiers: [bundle])
            try expect(spec.permitsApplication(bundle) && spec.permitsWindow(99, bundleIdentifier: bundle),
                "macOS capture is a system tool independent of user app/window permissions")
            try expect(!spec.shouldHideApplication(bundle, initialAllowedApps: [])
                && !spec.shouldHideApplication(bundle, initialAllowedApps: nil),
                "Capture remains visible during both initial Add-as-you-go cleanup and subsequent enforcement")
            try expect(!FocusForegroundPolicy.shouldImmediatelyReject(bundleIdentifier: bundle,
                accessMode: mode, controlledBundleIdentifiers: [bundle], isRegularApplication: true),
                "Screenshot launcher and capture UI cannot trigger immediate recovery")
            try expect(!FocusForegroundPolicy.shouldRestoreVisibleWindow(visibleBundleIdentifier: bundle,
                accessMode: mode, controlledBundleIdentifiers: mode == .whitelist ? [] : [bundle], missionControlActive: false),
                "A visible Screenshot window cannot trigger Space recovery")
            try expect(FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: bundle),
                "Capture remains focused while its controls are in use")
            try expect(FocusClickTargetPolicy.shouldAllow(ownerBundleIdentifier: bundle,
                representedBundleIdentifier: "blocked.app", allowedBundleIdentifiers: ["blocked.app", bundle],
                intentBundleIdentifier: "dev.loganmondi.intent", accessMode: mode),
                "Capture tool controls remain clickable even when they label an unallowed target app")
        }
    }
    let unrelatedBundles: [String?] = [nil, "org.example.Screenshot", "com.apple.screencaptureui.fake", "com.apple.finder"]
    for unrelated in unrelatedBundles {
        try expect(!FocusSystemToolPolicy.isScreenshotApplication(unrelated),
            "The system exemption recognizes exact native bundle IDs, not an app's display name")
    }
    let restrictive = FocusSessionSpec.make(for: .shallow(.imessages))
    try expect(restrictive.shouldHideApplication("blocked.app", initialAllowedApps: nil),
        "Ordinary forbidden apps remain hidden")
    try expect(restrictive.shouldHideApplication(restrictive.fallbackBundleIdentifier, initialAllowedApps: []),
        "Initial selection cleanup still applies to ordinary permitted apps")
}
