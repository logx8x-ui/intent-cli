import Foundation

/// Local app defaults are resolved at session start, including Quick Focus.
/// A blocked preset wins on corrupted overlapping input; the editor keeps lists disjoint.
public enum SessionAppPresets {
    public static func applying(allowed: [AllowedApp], blocked: [AllowedApp], to source: Intention) -> Intention {
        var result = source
        let blockedIDs = Set(blocked.map(\.bundleIdentifier))
        result.presetBlockedBundleIdentifiers = blockedIDs
        let allowed = allowed.filter { !blockedIDs.contains($0.bundleIdentifier) }
        result.presetAllowedBundleIdentifiers = Set(allowed.map(\.bundleIdentifier))
        let presetIDs = blockedIDs.union(allowed.map(\.bundleIdentifier))
        result.selectionBrowserBundleIdentifiers.removeAll { presetIDs.contains($0) }
        result.allowedWebsites.removeAll { presetIDs.contains($0.browserBundleIdentifier ?? "") }
        if result.isLeisure {
            guard !blocked.isEmpty else { return result }
            result.isLeisure = false
            result.accessMode = .blacklist
            result.allowedApps = blocked
            result.startupActions = []
        } else {
            result.allowedApps.removeAll { presetIDs.contains($0.bundleIdentifier) }
            result.allowedApps += result.accessMode == .whitelist ? allowed : blocked
        }
        result.presetStartupExcludedResourceIDs.formUnion(presetIDs.map { "app:" + $0 })
        return result
    }
}
