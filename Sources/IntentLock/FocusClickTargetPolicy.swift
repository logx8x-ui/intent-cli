import IntentCore

public enum FocusClickTargetPolicy {
    public static func shouldAllow(
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?,
        allowedBundleIdentifiers: Set<String>,
        intentBundleIdentifier: String?,
        accessMode: IntentionAccessMode = .whitelist
    ) -> Bool {
        if let representedBundleIdentifier {
            return isPermitted(
                representedBundleIdentifier,
                controlledBundleIdentifiers: allowedBundleIdentifiers,
                accessMode: accessMode
            )
        }

        guard let ownerBundleIdentifier else {
            return false
        }

        if isPermitted(
            ownerBundleIdentifier,
            controlledBundleIdentifiers: allowedBundleIdentifiers,
            accessMode: accessMode
        ) {
            return true
        }

        if ownerBundleIdentifier == intentBundleIdentifier {
            return true
        }

        return trustedSystemBundles.contains(ownerBundleIdentifier)
    }

    private static func isPermitted(
        _ bundleIdentifier: String,
        controlledBundleIdentifiers: Set<String>,
        accessMode: IntentionAccessMode
    ) -> Bool {
        switch accessMode {
        case .whitelist: controlledBundleIdentifiers.contains(bundleIdentifier)
        case .blacklist: !controlledBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private static let trustedSystemBundles: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.screencaptureui"
    ]
}
