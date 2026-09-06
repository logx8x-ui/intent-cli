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
        accessMode: IntentionAccessMode
    ) -> Bool {
        if let representedBundleIdentifier {
            return isPermitted(
                representedBundleIdentifier,
                controlledBundleIdentifiers: controlledBundleIdentifiers,
                accessMode: accessMode
            )
        }
        return ["com.apple.dock", "com.apple.WindowManager"].contains(ownerBundleIdentifier)
    }

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
        applicationNamesByBundleIdentifier: [String: String]
    ) -> String? {
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
        switch accessMode {
        case .whitelist: controlledBundleIdentifiers.contains(bundleIdentifier)
        case .blacklist: !controlledBundleIdentifiers.contains(bundleIdentifier)
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
