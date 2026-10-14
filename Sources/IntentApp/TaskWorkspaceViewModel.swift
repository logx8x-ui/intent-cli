import Foundation
import SwiftUI
import IntentCore

/// The task desktop is deliberately a separate document from saved intentions.
/// Publish only after an atomic save succeeds, so a failed write never looks saved.
@MainActor
final class TaskWorkspaceViewModel: ObservableObject {
    @Published private(set) var document: TaskWorkspaceDocument = .empty()
    @Published private(set) var notice: String?
    @Published private(set) var isAvailable = false
    @Published private(set) var canUndo = false
    private let store: TaskWorkspaceStore
    private var undoDocument: TaskWorkspaceDocument?
    private var pendingDrafts: [String: TaskWorkspaceDraft] = [:]

    struct TaskWorkspaceDraft: Equatable {
        var title: String
        var linkedIntentionID: String?
    }

    init(store: TaskWorkspaceStore = .init()) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            document = try store.load()
            isAvailable = true
            notice = nil
            undoDocument = nil
            canUndo = false
        } catch {
            isAvailable = false
            notice = "Your task lists could not be opened. Your saved file has been kept. Try again when it is available."
        }
    }

    @discardableResult
    private func change<Value>(_ mutation: (inout TaskWorkspaceDocument) throws -> Value) -> Value? {
        guard isAvailable else { return nil }
        do {
            var next = document
            let value = try mutation(&next)
            try store.save(next)
            undoDocument = document
            canUndo = true
            document = next
            notice = nil
            return value
        } catch {
            notice = "That change could not be saved. Your previous tasks are safe; please try the change again."
            return nil
        }
    }

    @discardableResult
    func addFolder(position: TaskWorkspacePosition) -> String? {
        change { try $0.addFolder(title: "New list", position: position) }
    }

    func renameFolder(_ id: String, to title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        change { try $0.renameFolder(id: id, title: title) }
    }

    func moveFolder(_ id: String, to position: TaskWorkspacePosition) {
        change { try $0.moveFolder(id: id, position: position) }
    }

    func removeFolder(_ id: String) {
        guard let folder = document.folders.first(where: { $0.id == id }) else { return }
        let addField = "add:" + id
        let pendingAdd = pendingDrafts[addField]
        let edits = folder.tasks.compactMap { task -> (String, TaskWorkspaceDraft)? in
            guard let draft = pendingDrafts["edit:" + task.id],
                  !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (task.id, draft)
        }
        let beforeRemoval = change { next -> TaskWorkspaceDocument in
            // Deleting an area is organisation, not disposal. Flush its live
            // text before moving tasks to General in the same atomic write.
            if let pendingAdd, !pendingAdd.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try next.addTask(title: pendingAdd.title, to: id, linkedIntentionID: pendingAdd.linkedIntentionID)
            }
            for (taskID, draft) in edits {
                try next.updateTask(id: taskID, title: draft.title, linkedIntentionID: draft.linkedIntentionID)
            }
            let prepared = next
            try next.removeFolder(id: id)
            return prepared
        }
        guard let beforeRemoval else { return }
        // Undo brings back the list and the just-written task, not a snapshot
        // from before the user typed that task.
        undoDocument = beforeRemoval
        pendingDrafts.removeValue(forKey: addField)
        for (taskID, _) in edits { pendingDrafts.removeValue(forKey: "edit:" + taskID) }
    }

    @discardableResult
    func addTask(title: String, folderID: String, linkedIntentionID: String?) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return change { try $0.addTask(title: title, to: folderID, linkedIntentionID: linkedIntentionID) } != nil
    }

    @discardableResult
    func editTask(_ id: String, title: String, linkedIntentionID: String?) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return change { try $0.updateTask(id: id, title: title, linkedIntentionID: linkedIntentionID) } != nil
    }

    func toggle(_ task: TaskWorkspaceTask) {
        change { try $0.setCompleted(taskID: task.id, completed: !task.isCompleted) }
    }

    func removeTask(_ id: String) {
        if change({ try $0.removeTask(id: id) }) != nil {
            pendingDrafts.removeValue(forKey: "edit:" + id)
        }
    }

    func moveTask(_ id: String, to folderID: String, before taskID: String? = nil) {
        change { try $0.moveTask(id: id, to: folderID, beforeTaskID: taskID) }
    }

    func dismissNotice() { notice = nil }

    /// The controller retains this model across workspace/list transitions. A
    /// failed save must retain text and its stable preset link after the field's
    /// SwiftUI state is destroyed. Reloading disk data deliberately keeps drafts.
    func draft(for fieldID: String) -> TaskWorkspaceDraft? { pendingDrafts[fieldID] }

    func rememberDraft(for fieldID: String, title: String, linkedIntentionID: String?) {
        pendingDrafts[fieldID] = .init(title: title, linkedIntentionID: linkedIntentionID)
    }

    func discardDraft(for fieldID: String) { pendingDrafts.removeValue(forKey: fieldID) }

    @discardableResult
    func saveDraft(for fieldID: String, using save: (String, String?) -> Bool) -> Bool {
        guard let draft = pendingDrafts[fieldID],
              !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              save(draft.title, draft.linkedIntentionID) else { return false }
        pendingDrafts.removeValue(forKey: fieldID)
        return true
    }

    func undo() {
        guard let previous = undoDocument, isAvailable else { return }
        do {
            try store.save(previous)
            document = previous
            undoDocument = nil
            canUndo = false
            notice = nil
        } catch {
            notice = "That change could not be undone yet. Your tasks have been kept; please try again."
        }
    }
}

/// Positions describe the available travel of a whole card, not the screen.
/// Changing display size therefore keeps its title, input and controls reachable.
enum TaskWorkspaceGeometry {
    static func cardSize(in canvas: CGSize) -> CGSize {
        CGSize(width: min(330, max(1, canvas.width)), height: min(420, max(1, canvas.height)))
    }

    static func origin(for position: TaskWorkspacePosition, canvas: CGSize, card: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(position.x) * max(0, canvas.width - card.width),
                y: CGFloat(position.y) * max(0, canvas.height - card.height))
    }

    static func position(for origin: CGPoint, canvas: CGSize, card: CGSize) -> TaskWorkspacePosition {
        let x = max(0, min(max(0, canvas.width - card.width), origin.x))
        let y = max(0, min(max(0, canvas.height - card.height), origin.y))
        return .init(x: canvas.width > card.width ? Double(x / (canvas.width - card.width)) : 0,
                     y: canvas.height > card.height ? Double(y / (canvas.height - card.height)) : 0)
    }

    static func newPosition(existing: [TaskWorkspaceFolder], canvas: CGSize) -> TaskWorkspacePosition {
        let card = cardSize(in: canvas)
        let columns = max(1, Int((canvas.width + 20) / (card.width + 20)))
        let rows = max(1, Int((canvas.height + 20) / (card.height + 20)))
        let candidates: [CGPoint] = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGPoint(x: CGFloat(column) * (card.width + 20), y: CGFloat(row) * (card.height + 20))
            }
        }
        let occupied = existing.map { CGRect(origin: origin(for: $0.position, canvas: canvas, card: card), size: card) }
        let best = candidates.min { lhs, rhs in
            func overlap(_ point: CGPoint) -> CGFloat {
                let rect = CGRect(origin: point, size: card).insetBy(dx: -8, dy: -8)
                return occupied.reduce(0) { total, other in
                    let intersection = rect.intersection(other)
                    return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
            }
            return overlap(lhs) < overlap(rhs)
        } ?? .zero
        // A full desktop gets a small cascade, with all lists still reachable in
        // the list strip. Never shrink every notepad to make one more fit.
        let overflow = existing.count >= candidates.count ? CGFloat(existing.count % 6) * 22 : 0
        return position(for: CGPoint(x: best.x + overflow, y: best.y + overflow), canvas: canvas, card: card)
    }
}
