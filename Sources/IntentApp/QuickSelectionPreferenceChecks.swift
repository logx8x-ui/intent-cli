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

        var fieldDraft = QuickSelection()
        QuickSelectionOptionsSection.timer.enable(in: &fieldDraft, defaults: defaults)
        let timerID = fieldDraft.restrictionNodes[0].id
        var durationText = QuickSelectionDurationDraft(totalMinutes: 25)
        // The actual text-binding setter saves every valid edit, without Return,
        // dismissal, or a change of focus being necessary for persistence.
        let minuteText = Binding<String>(get: { durationText.minutes }, set: {
            durationText.minutes = $0
            QuickSelectionPreferences.editDurationDraft(durationText, in: &fieldDraft, nodeID: timerID,
                                                        section: .timer, defaults: defaults)
        })
        minuteText.wrappedValue = "2"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 2
                  && QuickSelectionPreferences.timerDuration(defaults: reloadedDefaults) == 2,
                  "Typing two minutes immediately persists two without requiring Return or focus loss")
        for invalid in ["", " ", "-1", "1.5", "60", "99999999999999999999999999", "abc"] {
            minuteText.wrappedValue = invalid
            try check(fieldDraft.restrictionNodes[0].durationMinutes == 2
                      && QuickSelectionPreferences.timerDuration(defaults: defaults) == 2,
                      "Incomplete or invalid duration text cannot overwrite the last valid edit: \(invalid)")
        }
        durationText.hours = "1"; minuteText.wrappedValue = "5"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 65,
                  "Hour and minute fields combine into the configured timer duration")
        durationText.hours = "24"; minuteText.wrappedValue = "0"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 1440,
                  "The duration editor supports an exact 24-hour duration")
        minuteText.wrappedValue = "1"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 1440,
                  "A duration longer than 24 hours stays an uncommitted edit")
        durationText.hours = "0"; minuteText.wrappedValue = "0"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 1440,
                  "An intermediate zero duration never silently turns into a different timer")
        minuteText.wrappedValue = "2"
        fieldDraft.restrictionNodes[0].kind = .endTime
        minuteText.wrappedValue = "3"
        try check(fieldDraft.restrictionNodes[0].durationMinutes == 2
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 2,
                  "A late compact-duration edit cannot alter an end-time node or global default")

        let cooldownID = cooldown.restrictionNodes[0].id
        QuickSelectionPreferences.editDurationDraft(.init(totalMinutes: 92), in: &cooldown,
                                                   nodeID: cooldownID, section: .cooldown, defaults: defaults)
        var freshCooldown = QuickSelection()
        QuickSelectionOptionsSection.cooldown.enable(in: &freshCooldown, defaults: reloadedDefaults)
        try check(freshCooldown.restrictionNodes[0].durationMinutes == 92
                  && QuickSelectionPreferences.timerDuration(defaults: defaults) == 2,
                  "Cooldown edits persist for the next draft without changing timer defaults")
        var savedCooldown = QuickSelection()
        savedCooldown.restrictionNodes = [.init(kind: .coolDown, position: .zero, durationMinutes: 7)]
        QuickSelectionOptionsSection.cooldown.enable(in: &savedCooldown, defaults: defaults)
        try check(savedCooldown.restrictionNodes[0].durationMinutes == 7
                  && QuickSelectionPreferences.cooldownDuration(defaults: defaults) == 92,
                  "A saved intention retains its own cooldown without overwriting the quick default")
        cooldown.restrictionNodes.removeAll()
        cooldown.restrictionNodes.append(.init(kind: .coolDown, position: .zero, durationMinutes: 4))
        QuickSelectionPreferences.editDurationDraft(.init(totalMinutes: 18), in: &cooldown,
                                                   nodeID: cooldownID, section: .cooldown, defaults: defaults)
        try check(cooldown.restrictionNodes[0].durationMinutes == 4
                  && QuickSelectionPreferences.cooldownDuration(defaults: defaults) == 92,
                  "A stale cooldown field cannot write into a replacement node")

        var checklist = QuickSelection()
        QuickSelectionOptionsSection.checklist.enable(in: &checklist, defaults: defaults)
        QuickSelectionOptionsSection.checklist.dismissEditor(in: &checklist)
        try check(!QuickSelectionOptionsSection.checklist.enabled(in: checklist),
                  "Dismissing an untouched checklist removes its provisional activation")
        QuickSelectionOptionsSection.checklist.enable(in: &checklist, defaults: defaults)
        let checklistID = checklist.frictionNodes[0].id
        QuickSelectionChecklistEditing.edit(" \n ", row: 0, in: &checklist, nodeID: checklistID)
        QuickSelectionOptionsSection.checklist.dismissEditor(in: &checklist)
        try check(!QuickSelectionOptionsSection.checklist.enabled(in: checklist),
                  "Whitespace-only checklist lines do not keep the modifier active")
        QuickSelectionOptionsSection.checklist.enable(in: &checklist, defaults: defaults)
        let writtenID = checklist.frictionNodes[0].id
        QuickSelectionChecklistEditing.edit("Write the first draft", row: 1, in: &checklist, nodeID: writtenID)
        QuickSelectionOptionsSection.checklist.dismissEditor(in: &checklist)
        QuickSelectionOptionsSection.checklist.enable(in: &checklist, defaults: defaults)
        try check(QuickSelectionOptionsSection.checklist.enabled(in: checklist)
                  && QuickSelectionChecklistEditing.tasks(in: checklist, nodeID: writtenID) == ["", "Write the first draft"],
                  "Typing on a plain line keeps the checklist active and reopening preserves its text")
        QuickSelectionChecklistEditing.appendRow(in: &checklist, nodeID: writtenID)
        QuickSelectionChecklistEditing.edit("Review", row: 3, in: &checklist, nodeID: writtenID)
        try check(QuickSelectionChecklistEditing.tasks(in: checklist, nodeID: writtenID) == ["", "Write the first draft", "", "Review"],
                  "The plus control adds another editable line after the three visible starter lines")
        checklist.apps = ["qa.checklist"]
        let savedChecklist = try checklist.makeIntention(apps: [.init(name: "Checklist QA", bundleIdentifier: "qa.checklist")], snapshots: [])
        var restoredChecklist = QuickSelection()
        restoredChecklist.applySessionConfiguration(savedChecklist)
        try check(QuickSelectionOptionsSection.checklist.enabled(in: restoredChecklist)
                  && restoredChecklist.frictionNodes.contains { if case .taskChecklist(let tasks) = $0.friction { return tasks == ["Write the first draft", "Review"] }; return false },
                  "Saving and reloading an intention explicitly preserves its checklist contents")
        var newChecklist = QuickSelection()
        QuickSelectionOptionsSection.checklist.enable(in: &newChecklist, defaults: defaults)
        try check(newChecklist.frictionNodes.allSatisfy { if case .taskChecklist(let tasks) = $0.friction { return tasks.allSatisfy(\.isEmpty) }; return true },
                  "A new unsaved session begins with blank checklist lines rather than the last session's tasks")
        QuickSelectionOptionsSection.checklist.disable(in: &checklist)
        QuickSelectionChecklistEditing.edit("Stale", row: 0, in: &checklist, nodeID: writtenID)
        try check(checklist.frictionNodes.isEmpty,
                  "Removing a checklist from its editor cannot be undone by a stale text-field callback")
    }
}
