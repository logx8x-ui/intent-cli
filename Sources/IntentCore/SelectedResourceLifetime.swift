import Foundation

/// Ordinary resource closure is completion only when the entire explicit
/// whitelist is gone. Unknown browser inventory never proves closure.
public enum SelectedResourceLifetime {
    public enum BrowserPresence { case present, unknown, closed }

    /// Persisted intentions include app presets for enforcement. Those defaults
    /// are not selected work and cannot keep an exhausted session alive.
    public static func wholeAppSelections(allowedAppIDs: Set<String>, presetAppIDs: Set<String>,
                                          windowSelectionAppIDs: Set<String>, tabSelectionAppIDs: Set<String>) -> Set<String> {
        allowedAppIDs.subtracting(presetAppIDs).subtracting(windowSelectionAppIDs).subtracting(tabSelectionAppIDs)
    }

    /// Ordinary snapshots can remain idle after a close. A missing selected ID
    /// always needs a new exact-owner query; timestamp age cannot suppress it.
    public static func needsTabConfirmation(restrictive: Bool, snapshot: BrowserTabSnapshot,
                                            selectedIDs: Set<Int>) -> Bool {
        restrictive && !(snapshot.allTabs ?? snapshot.tabs).contains { selectedIDs.contains($0.id) }
    }

    public static func shouldFinish(restrictive: Bool,
                                    selectedWindows: [String: Set<UInt32>],
                                    wholeApps: Set<String>,
                                    liveWindows: [String: Set<UInt32>],
                                    browsers: [String: BrowserPresence]) -> Bool {
        guard restrictive else { return false }
        if browsers.values.contains(where: { $0 != .closed }) { return false }
        for app in wholeApps where !(liveWindows[app] ?? []).isEmpty { return false }
        for (app, selected) in selectedWindows where browsers[app] == nil {
            if !selected.isDisjoint(with: liveWindows[app] ?? []) { return false }
        }
        return !selectedWindows.isEmpty || !wholeApps.isEmpty || !browsers.isEmpty
    }
}
