import Foundation

/// macOS owns these capture surfaces. They remain usable without becoming a
/// saved app permission, including the launcher's first visibility pass.
public enum FocusSystemToolPolicy {
    public static func isScreenshotApplication(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ["com.apple.screencaptureui", "com.apple.screenshot.launcher"].contains(bundleIdentifier)
    }
}

public enum FocusSystemShortcutPolicy {
    public enum TabRoute: Equatable { case nativeBrowser, allowedApplications, ordinary }

    public static func tabRoute(keyCode: Int64, command: Bool, control: Bool,
                                restrictApplicationSwitching: Bool) -> TabRoute {
        guard keyCode == KeyCode.tab else { return .ordinary }
        if command && restrictApplicationSwitching { return .allowedApplications }
        // Shift, repeat timing and browser-specific ordering belong to the
        // browser. Never substitute Intent's application-style chooser here.
        if control && !command { return .nativeBrowser }
        return .ordinary
    }

    public static func shouldBlock(keyCode: Int64) -> Bool {
        [
            KeyCode.q,
            KeyCode.h,
            KeyCode.m
        ].contains(keyCode)
    }

    public static func isScreenshotShortcut(keyCode: Int64, command: Bool, shift: Bool) -> Bool {
        // Control copies to the clipboard, and Option is used by capture modes.
        command && shift && [KeyCode.three, KeyCode.four, KeyCode.five, KeyCode.six].contains(keyCode)
    }

    /// This is the event tap's whole-browser input gate, before the narrower
    /// browser-command policy. System capture must pass this earlier gate too.
    public static func shouldBlockInertBrowserInput(keyCode: Int64, command: Bool, control: Bool,
        option: Bool, shift: Bool, allowGoogleSearchTabs: Bool, hasPanelKeyboardFocus: Bool,
        windowBlocked: @autoclosure () -> Bool) -> Bool {
        guard !isScreenshotShortcut(keyCode: keyCode, command: command, shift: shift),
              keyCode != KeyCode.grave,
              !(keyCode == KeyCode.tab && (command || control)),
              !(control && isSpaceNavigationKey(keyCode)),
              !FocusBrowserShortcutPolicy.createsSearchSurface(keyCode: keyCode, command: command, control: control,
                  option: option, shift: shift, allowGoogleSearchTabs: allowGoogleSearchTabs),
              !hasPanelKeyboardFocus else { return false }
        return windowBlocked()
    }

    public static func isSpaceNavigationKey(_ keyCode: Int64) -> Bool {
        [
            KeyCode.leftArrow,
            KeyCode.rightArrow,
            KeyCode.upArrow,
            KeyCode.downArrow
        ].contains(keyCode)
    }
}

public enum FocusBrowserShortcutPolicy {
    /// Creating a fresh search surface remains available even when the current
    /// browser window contains only blocked tabs. Private/reopen shortcuts do
    /// not inherit this exception.
    public static func createsSearchSurface(keyCode: Int64, command: Bool, control: Bool,
        option: Bool, shift: Bool, allowGoogleSearchTabs: Bool) -> Bool {
        allowGoogleSearchTabs && command && !control && !option && !shift
            && [KeyCode.t, KeyCode.n].contains(keyCode)
    }

    public static func shouldBlock(
        keyCode: Int64,
        command: Bool,
        control: Bool,
        option: Bool,
        shift: Bool,
        allowGoogleSearchTabs: Bool
    ) -> Bool {
        if FocusSystemShortcutPolicy.isScreenshotShortcut(keyCode: keyCode, command: command, shift: shift) {
            return false
        }

        if control && keyCode == KeyCode.tab {
            return false
        }

        if createsSearchSurface(keyCode: keyCode, command: command, control: control,
            option: option, shift: shift, allowGoogleSearchTabs: allowGoogleSearchTabs) {
            return false
        }

        if command && keyCode == KeyCode.w {
            return false
        }

        if command && numberKeyCodes.contains(keyCode) {
            return false
        }

        if command && option && [KeyCode.leftArrow, KeyCode.rightArrow].contains(keyCode) {
            return true
        }

        if command && keyCode == KeyCode.t {
            return !allowGoogleSearchTabs
        }

        if allowGoogleSearchTabs,
           command,
           keyCode == KeyCode.l {
            return false
        }

        if command && browserCommandKeys.contains(keyCode) {
            return true
        }

        return false
    }

    private static var browserCommandKeys: Set<Int64> {
        [
            KeyCode.leftBracket,
            KeyCode.rightBracket,
            KeyCode.leftArrow,
            KeyCode.rightArrow,
            KeyCode.l,
            KeyCode.n,
            KeyCode.o,
            KeyCode.r,
            KeyCode.t
        ]
    }

    private static var numberKeyCodes: Set<Int64> {
        [
            KeyCode.zero,
            KeyCode.one,
            KeyCode.two,
            KeyCode.three,
            KeyCode.four,
            KeyCode.five,
            KeyCode.six,
            KeyCode.seven,
            KeyCode.eight,
            KeyCode.nine
        ]
    }
}

public enum BrowserAddressPolicy {
    public static func isAddressControl(labels: [String]) -> Bool {
        labels.contains { label in
            let value = label.lowercased()
            return value.contains("address") || value.contains("urlbar") || value.contains("omnibox") || value == "location"
        }
    }

    public static func isDirectDestination(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("://") || ["about:", "file:", "javascript:", "data:"].contains(where: value.hasPrefix) { return true }
        return !value.contains(where: { $0.isWhitespace }) && (value.contains(".") || value == "localhost" || value.contains("/"))
    }
}
