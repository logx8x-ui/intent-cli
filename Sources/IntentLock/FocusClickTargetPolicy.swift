public enum FocusClickTargetPolicy {
    public static func shouldAllow(
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?,
        allowedBundleIdentifiers: Set<String>,
        intentBundleIdentifier: String?
    ) -> Bool {
        if let representedBundleIdentifier {
            return allowedBundleIdentifiers.contains(representedBundleIdentifier)
        }

        guard let ownerBundleIdentifier else {
            return false
        }

        if allowedBundleIdentifiers.contains(ownerBundleIdentifier) {
            return true
        }

        if ownerBundleIdentifier == intentBundleIdentifier {
            return true
        }

        return trustedSystemBundles.contains(ownerBundleIdentifier)
    }

    private static let trustedSystemBundles: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.screencaptureui"
    ]
}
