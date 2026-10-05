import Foundation
import IntentCore

/// The duration UI uses text, not a formatted value binding that only commits
/// after Return/resigning first responder. Every complete valid edit is saved.
struct QuickSelectionDurationDraft: Equatable {
    var hours: String
    var minutes: String

    init(totalMinutes: Int) {
        let bounded = min(1440, max(1, totalMinutes))
        hours = String(bounded / 60)
        minutes = String(bounded % 60)
    }

    var validMinutes: Int? {
        guard !hours.isEmpty, !minutes.isEmpty,
              hours.allSatisfy(\.isNumber), minutes.allSatisfy(\.isNumber),
              let hours = Int(hours), let minutes = Int(minutes),
              (0...24).contains(hours), (0...59).contains(minutes) else { return nil }
        let result = hours * 60 + minutes
        return (1...1440).contains(result) ? result : nil
    }
}

enum QuickSelectionChecklistEditing {
    static func tasks(in selection: QuickSelection, nodeID: String) -> [String] {
        guard let node = selection.frictionNodes.first(where: { $0.id == nodeID }),
              case .taskChecklist(let tasks) = node.friction else { return [] }
        return tasks
    }

    static func edit(_ text: String, row: Int, in selection: inout QuickSelection, nodeID: String) {
        guard let index = selection.frictionNodes.firstIndex(where: { $0.id == nodeID }),
              case .taskChecklist(var tasks) = selection.frictionNodes[index].friction,
              row >= 0, row < max(3, tasks.count) else { return }
        while tasks.count <= row { tasks.append("") }
        tasks[row] = text
        selection.frictionNodes[index].friction = .taskChecklist(tasks)
    }

    static func appendRow(in selection: inout QuickSelection, nodeID: String) {
        guard let index = selection.frictionNodes.firstIndex(where: { $0.id == nodeID }),
              case .taskChecklist(var tasks) = selection.frictionNodes[index].friction else { return }
        while tasks.count < 3 { tasks.append("") }
        tasks.append("")
        selection.frictionNodes[index].friction = .taskChecklist(tasks)
    }

    /// Empty placeholders are provisional. Actual text is retained in this draft
    /// only; nothing is written to global preferences or another saved intention.
    static func dismiss(in selection: inout QuickSelection) {
        selection.frictionNodes.removeAll {
            guard case .taskChecklist(let tasks) = $0.friction else { return false }
            return tasks.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}
