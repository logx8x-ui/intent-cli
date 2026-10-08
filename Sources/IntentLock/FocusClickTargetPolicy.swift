import Foundation
import IntentCore

public enum FocusClickTargetPolicy {
    public static func shouldAllow(
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?,
        allowedBundleIdentifiers: Set<String>,
        intentBundleIdentifier: String?,
        accessMode: IntentionAccessMode = .whitelist,
        isMenuBarClick: Bool = false
    ) -> Bool {
        // Intent's own editor may name disallowed apps. Its controls must always work.
        if let ownerBundleIdentifier, ownerBundleIdentifier == intentBundleIdentifier { return true }
        if FocusSystemToolPolicy.isScreenshotApplication(ownerBundleIdentifier) { return true }
        if isMenuBarClick {
            switch accessMode {
            case .whitelist:
                return true
            case .blacklist:
                guard let target = representedBundleIdentifier ?? ownerBundleIdentifier else {
                    return true
                }
                return !allowedBundleIdentifiers.contains(target)
            }
        }

        if let representedBundleIdentifier {
            return isPermitted(
                representedBundleIdentifier,
                controlledBundleIdentifiers: allowedBundleIdentifiers,
                accessMode: accessMode
            )
        }

        guard let ownerBundleIdentifier else {
            // Missing accessibility data is not permission to freeze the desktop.
            return true
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

        if accessMode == .blacklist,
           allowedBundleIdentifiers.contains(ownerBundleIdentifier) {
            return false
        }

        return trustedSystemBundles.contains(ownerBundleIdentifier)
    }

    public static func shouldAllowMissionControlClick(
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?,
        controlledBundleIdentifiers: Set<String>,
        accessMode: IntentionAccessMode,
        isSpaceNavigation: Bool = false
    ) -> Bool {
        // A desktop is a container, not an app permission. Its blocked windows
        // are owned by visibility enforcement even when its AX label names them.
        if isSpaceNavigation && missionControlOwners.contains(ownerBundleIdentifier ?? "") { return true }
        if FocusSystemToolPolicy.isScreenshotApplication(ownerBundleIdentifier) { return true }
        if let representedBundleIdentifier {
            return isPermitted(
                representedBundleIdentifier,
                controlledBundleIdentifiers: controlledBundleIdentifiers,
                accessMode: accessMode
            )
        }
        guard let ownerBundleIdentifier else { return true }
        if missionControlOwners.contains(ownerBundleIdentifier) { return true }
        return isPermitted(ownerBundleIdentifier,
                           controlledBundleIdentifiers: controlledBundleIdentifiers,
                           accessMode: accessMode)
    }

    public static func isMissionControlSpaceNavigation(ownerBundleIdentifier: String?,
                                                       ancestorIdentifiers: [String]) -> Bool {
        guard missionControlOwners.contains(ownerBundleIdentifier ?? "") else { return false }
        return ancestorIdentifiers.contains { $0 == "mc.spaces" || $0.hasPrefix("mc.spaces.") }
    }

    public static func isMissionControlRepresentationBoundary(role: String?, identifier: String?) -> Bool {
        role == "AXApplication" || ["mc.windows", "mc.display", "mc"].contains(identifier ?? "")
    }

    private static let missionControlOwners: Set<String> = ["com.apple.dock", "com.apple.WindowManager"]

    public static func shouldAllowAuxiliaryApplication(
        bundleIdentifier: String?,
        isRegularApplication: Bool,
        controlledBundleIdentifiers: Set<String>,
        accessMode: IntentionAccessMode
    ) -> Bool {
        guard !isRegularApplication else { return false }
        if let bundleIdentifier,
           ["com.apple.dock", "com.apple.WindowManager"].contains(bundleIdentifier) {
            return false
        }
        switch accessMode {
        case .whitelist:
            return true
        case .blacklist:
            guard let bundleIdentifier else { return true }
            return !controlledBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    public static func representedBundleIdentifier(
        labels: [String],
        applicationNamesByBundleIdentifier: [String: String],
        verifiedApplicationBundleIdentifier: String? = nil,
        isMissionControl: Bool = false
    ) -> String? {
        if let verifiedApplicationBundleIdentifier { return verifiedApplicationBundleIdentifier }
        // Window titles are content, not application identities. A page called
        // "Instagram Messages" or the owner's "Dock" ancestry must not turn a
        // permitted Firefox thumbnail into a forbidden application target.
        guard !isMissionControl else { return nil }
        let normalizedLabels = labels.map(normalized)
        return applicationNamesByBundleIdentifier
            .sorted { $0.value.count > $1.value.count }
            .first { _, appName in
                let normalizedName = normalized(appName)
                guard !normalizedName.isEmpty else { return false }
                return normalizedLabels.contains { label in
                    label == normalizedName
                        || containsWholePhrase(normalizedName, in: label)
                }
            }?.key
    }

    private static func isPermitted(
        _ bundleIdentifier: String,
        controlledBundleIdentifiers: Set<String>,
        accessMode: IntentionAccessMode
    ) -> Bool {
        if FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) { return true }
        switch accessMode {
        case .whitelist: return controlledBundleIdentifiers.contains(bundleIdentifier)
        case .blacklist: return !controlledBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private static let trustedSystemBundles: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.TextInputMenuAgent"
    ]

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsWholePhrase(_ phrase: String, in value: String) -> Bool {
        guard phrase.count > 1 else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
