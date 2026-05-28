public enum FocusSystemShortcutPolicy {
    public static func shouldBlock(keyCode: Int64) -> Bool {
        [
            KeyCode.space,
            KeyCode.q,
            KeyCode.h,
            KeyCode.m,
            KeyCode.grave
        ].contains(keyCode)
    }
}

public enum FocusBrowserShortcutPolicy {
    public static func shouldBlock(
        keyCode: Int64,
        command: Bool,
        control: Bool,
        option: Bool,
        shift: Bool,
        allowGoogleSearchTabs: Bool
    ) -> Bool {
        if command && shift && screenshotKeyCodes.contains(keyCode) {
            return false
        }

        if control && keyCode == KeyCode.tab {
            return true
        }

        if command && option && [KeyCode.leftArrow, KeyCode.rightArrow].contains(keyCode) {
            return true
        }

        if allowGoogleSearchTabs,
           command,
           [KeyCode.l, KeyCode.t].contains(keyCode) {
            return false
        }

        if command && browserCommandKeys.contains(keyCode) {
            return true
        }

        return false
    }

    private static var screenshotKeyCodes: Set<Int64> {
        [
            KeyCode.three,
            KeyCode.four,
            KeyCode.five
        ]
    }

    private static var browserCommandKeys: Set<Int64> {
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
            KeyCode.nine,
            KeyCode.leftBracket,
            KeyCode.rightBracket,
            KeyCode.leftArrow,
            KeyCode.rightArrow,
            KeyCode.l,
            KeyCode.n,
            KeyCode.o,
            KeyCode.r,
            KeyCode.t,
            KeyCode.w
        ]
    }
}
