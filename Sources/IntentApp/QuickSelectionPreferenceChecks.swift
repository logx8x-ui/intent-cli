import Foundation
import IntentCore
import SwiftUI

/// Uses a unique defaults domain; these checks never touch the user's preference.
@MainActor
enum QuickSelectionPreferenceChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let suite = "dev.loganmondi.intent.qa.timer-recall.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
              let reloadedDefaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "QuickSelectionPreferenceChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create isolated timer preferences"])
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        var firstDraft = QuickSelection()
        QuickSelectionOptionsSection.timer.enable(in: &firstDraft, defaults: defaults)
        try check(firstDraft.restrictionNodes.first?.durationMinutes == 25,
                  "A new installation starts quick timers at 25 minutes")
        try check(defaults.object(forKey: QuickSelectionPreferences.timerDurationKey) == nil,
                  "Creating or viewing a timer does not record a user edit")

        QuickSelectionPreferences.editTimerDuration(47, in: &firstDraft, at: 0, defaults: defaults)
        try check(firstDraft.restrictionNodes[0].durationMinutes == 47
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 47,
                  "An actual duration edit updates the draft and remembers its valid value")
        QuickSelectionOptionsSection.timer.disable(in: &firstDraft)
        QuickSelectionOptionsSection.timer.enable(in: &firstDraft, defaults: defaults)
        try check(firstDraft.restrictionNodes.first?.durationMinutes == 47,
                  "Turning the timer off then on reuses the last entered duration")

        var nextDraft = QuickSelection()
        QuickSelectionOptionsSection.timer.enable(in: &nextDraft, defaults: reloadedDefaults)
        try check(nextDraft.restrictionNodes.first?.durationMinutes == 47,
                  "A fresh draft and recreated preference reader reuse the persisted duration")
        try check(defaults.persistentDomain(forName: suite)?[QuickSelectionPreferences.timerDurationKey] as? Int == 47,
                  "The last entered duration is stored in the persistent defaults domain")

        var savedDraft = QuickSelection()
        savedDraft.restrictionNodes = [.init(kind: .timer, position: .zero, durationMinutes: 12)]
        QuickSelectionOptionsSection.timer.enable(in: &savedDraft, defaults: defaults)
        try check(savedDraft.restrictionNodes.count == 1 && savedDraft.restrictionNodes[0].durationMinutes == 12,
                  "Opening an existing saved timer preserves its own duration")
        try check(QuickSelectionPreferences.timerDuration(defaults: defaults) == 47,
                  "Viewing an old saved timer cannot overwrite the last entered duration")
        var legacyDraft = QuickSelection()
        legacyDraft.restrictionNodes = [.init(kind: .timer, position: .zero)]
        QuickSelectionOptionsSection.timer.enable(in: &legacyDraft, defaults: defaults)
        legacyDraft.apps = ["qa.timer-native"]
        let legacyIntention = try legacyDraft.makeIntention(
            apps: [.init(name: "QA timer", bundleIdentifier: "qa.timer-native")], snapshots: [])
        try check(legacyDraft.restrictionNodes[0].durationMinutes == nil
                  && QuickSelectionPreferences.configuredTimerDuration(legacyDraft.restrictionNodes[0]) == 25
                  && legacyIntention.timerMinutes == 25
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 47,
                  "A legacy saved timer without duration keeps its displayed and runtime 25-minute meaning")

        var cooldown = QuickSelection()
        QuickSelectionOptionsSection.cooldown.enable(in: &cooldown, defaults: defaults)
        QuickSelectionPreferences.editTimerDuration(80, in: &cooldown, at: 0, defaults: defaults)
        try check(cooldown.restrictionNodes[0].durationMinutes == 30
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 47,
                  "Cooldown defaults and edits are independent of remembered timer duration")
        savedDraft.restrictionNodes[0].kind = .endTime
        QuickSelectionPreferences.editTimerDuration(80, in: &savedDraft, at: 0, defaults: defaults)
        QuickSelectionPreferences.editTimerDuration(80, in: &savedDraft, at: 99, defaults: defaults)
        try check(savedDraft.restrictionNodes[0].durationMinutes == 12
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 47,
                  "End-time mode and stale field callbacks do not change timer preferences")

        var callbackDraft = QuickSelection()
        let editedID = "qa-edited-timer"
        callbackDraft.restrictionNodes = [
            .init(id: editedID, kind: .timer, position: .zero),
            .init(id: "qa-other-timer", kind: .timer, position: .zero, durationMinutes: 12)
        ]
        let retainedField = Binding<Int>(get: {
            QuickSelectionPreferences.configuredTimerDuration(in: callbackDraft, nodeID: editedID)
        }, set: {
            QuickSelectionPreferences.editTimerDuration($0, in: &callbackDraft, nodeID: editedID, defaults: defaults)
        })
        try check(retainedField.wrappedValue == 25,
                  "An identity-bound field preserves a legacy timer's 25-minute default")
        callbackDraft.restrictionNodes.swapAt(0, 1)
        retainedField.wrappedValue = 63
        try check(retainedField.wrappedValue == 63
                  && callbackDraft.restrictionNodes[0].durationMinutes == 12
                  && callbackDraft.restrictionNodes[1].durationMinutes == 63
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 63,
                  "A retained duration field follows its original timer after restriction reordering")
        callbackDraft.restrictionNodes[1].kind = .endTime
        retainedField.wrappedValue = 81
        try check(retainedField.wrappedValue == 25
                  && callbackDraft.restrictionNodes[1].durationMinutes == 63
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 63,
                  "A retained duration field cannot read or edit a node switched to end-time mode")
        callbackDraft.restrictionNodes.removeAll { $0.id == editedID }
        retainedField.wrappedValue = 82
        try check(retainedField.wrappedValue == 25
                  && callbackDraft.restrictionNodes[0].durationMinutes == 12
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 63,
                  "Reads and writes after timer removal are safe and leave the remaining timer and preference unchanged")
        callbackDraft.restrictionNodes.append(.init(id: "qa-replacement-timer", kind: .timer,
            position: .zero, durationMinutes: 29))
        retainedField.wrappedValue = 90
        try check(retainedField.wrappedValue == 25
                  && callbackDraft.restrictionNodes[1].durationMinutes == 29
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 63,
                  "A replacement timer at the old index cannot receive a stale field's final edit")

        for (entered, expected) in [(Int.min, 1), (0, 1), (1, 1), (1440, 1440), (Int.max, 1440)] {
            QuickSelectionPreferences.editTimerDuration(entered, in: &nextDraft, at: 0, defaults: defaults)
            try check(nextDraft.restrictionNodes[0].durationMinutes == expected
                      && QuickSelectionPreferences.timerDuration(defaults: defaults) == expected,
                      "Entered timer duration \(entered) is bounded to \(expected) minutes")
        }
        defaults.set("invalid duration", forKey: QuickSelectionPreferences.timerDurationKey)
        try check(QuickSelectionPreferences.timerDuration(defaults: defaults) == 25,
                  "An invalid stored duration safely falls back to the initial default")
    }
}
