import Foundation
import IntentCore

/// Defaults for new quick-focus timers, not a replacement for saved session settings.
enum QuickSelectionPreferences {
    static let timerDurationKey = "quickSelectionLastTimerDurationMinutes"
    static let initialTimerDuration = 25
    static let cooldownDurationKey = "quickSelectionLastCooldownDurationMinutes"
    static let initialCooldownDuration = 30

    static func configuredTimerDuration(_ node: RestrictionNode) -> Int {
        // Legacy saved timers with no explicit value mean 25 at runtime.
        max(1, node.durationMinutes ?? initialTimerDuration)
    }

    static func configuredTimerDuration(in selection: QuickSelection, nodeID: String) -> Int {
        guard let node = selection.restrictionNodes.first(where: { $0.id == nodeID && $0.kind == .timer }) else {
            // SwiftUI may read a field binding while its removed popover tears
            // down. Never index into a replacement node or change preferences.
            return initialTimerDuration
        }
        return configuredTimerDuration(node)
    }

    static func timerDuration(defaults: UserDefaults = .standard) -> Int {
        guard let minutes = defaults.object(forKey: timerDurationKey) as? Int else {
            return initialTimerDuration
        }
        return boundedDuration(minutes)
    }

    static func cooldownDuration(defaults: UserDefaults = .standard) -> Int {
        guard let minutes = defaults.object(forKey: cooldownDurationKey) as? Int else {
            return initialCooldownDuration
        }
        return boundedDuration(minutes)
    }

    static func configuredDuration(in selection: QuickSelection, nodeID: String,
                                   section: QuickSelectionOptionsSection) -> Int {
        let kind: RestrictionKind = section == .cooldown ? .coolDown : .timer
        let fallback = section == .cooldown ? initialCooldownDuration : initialTimerDuration
        guard let node = selection.restrictionNodes.first(where: { $0.id == nodeID && $0.kind == kind }) else { return fallback }
        return boundedDuration(node.durationMinutes ?? fallback)
    }

    /// Identity-bound and edit-only: a closing field cannot overwrite a new node,
    /// and loading a saved intention never changes the next quick-session default.
    static func editDuration(_ minutes: Int, in selection: inout QuickSelection,
                             nodeID: String, section: QuickSelectionOptionsSection,
                             defaults: UserDefaults = .standard) {
        guard section == .timer || section == .cooldown else { return }
        let kind: RestrictionKind = section == .cooldown ? .coolDown : .timer
        guard let index = selection.restrictionNodes.firstIndex(where: { $0.id == nodeID && $0.kind == kind }) else { return }
        let value = boundedDuration(minutes)
        selection.restrictionNodes[index].durationMinutes = value
        defaults.set(value, forKey: section == .cooldown ? cooldownDurationKey : timerDurationKey)
    }

    static func editDurationDraft(_ draft: QuickSelectionDurationDraft, in selection: inout QuickSelection,
                                  nodeID: String, section: QuickSelectionOptionsSection,
                                  defaults: UserDefaults = .standard) {
        guard let minutes = draft.validMinutes else { return }
        editDuration(minutes, in: &selection, nodeID: nodeID, section: section, defaults: defaults)
    }

    /// Use only after an explicit duration edit, including in the graph editor.
    @discardableResult
    static func recordTimerDuration(_ minutes: Int, defaults: UserDefaults = .standard) -> Int {
        let duration = boundedDuration(minutes)
        defaults.set(duration, forKey: timerDurationKey)
        return duration
    }

    /// Called only by the duration field's edit binding. Merely opening/replaying
    /// a saved timer must neither replace its duration nor change the next default.
    static func editTimerDuration(_ minutes: Int, in selection: inout QuickSelection,
                                  at index: Int, defaults: UserDefaults = .standard) {
        guard selection.restrictionNodes.indices.contains(index) else { return }
        let nodeID = selection.restrictionNodes[index].id
        editTimerDuration(minutes, in: &selection, nodeID: nodeID, defaults: defaults)
    }

    static func editTimerDuration(_ minutes: Int, in selection: inout QuickSelection,
                                  nodeID: String, defaults: UserDefaults = .standard) {
        guard let index = selection.restrictionNodes.firstIndex(where: { $0.id == nodeID && $0.kind == .timer }) else { return }
        selection.restrictionNodes[index].durationMinutes = recordTimerDuration(minutes, defaults: defaults)
    }

    private static func boundedDuration(_ minutes: Int) -> Int {
        min(1440, max(1, minutes))
    }
}
