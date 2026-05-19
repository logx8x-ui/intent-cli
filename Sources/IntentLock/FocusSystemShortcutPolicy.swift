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

