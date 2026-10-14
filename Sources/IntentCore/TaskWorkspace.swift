import Foundation

/// Coordinates describe the available travel of a card, not absolute screen
/// points. A card remains reachable after changing displays or their resolution.
public struct TaskWorkspacePosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0
        self.y = y.isFinite ? min(1, max(0, y)) : 0
    }
}

public struct TaskWorkspaceTask: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var isCompleted: Bool
    public var linkedIntentionID: String?

    public init(id: String = UUID().uuidString, title: String, isCompleted: Bool = false,
                linkedIntentionID: String? = nil) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.linkedIntentionID = linkedIntentionID
    }

    /// A deleted/ambiguous preset remains a visible, editable task. Never attach
    /// a new preset just because it has the same name as the old one.
    public func linkedIntention(in intentions: [Intention]) -> Intention? {
        guard let linkedIntentionID else { return nil }
        let matches = intentions.filter { $0.id == linkedIntentionID }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct TaskWorkspaceFolder: Identifiable, Codable, Equatable, Sendable {
    public static let inboxID = "general"
    public var id: String
    public var title: String
    public var position: TaskWorkspacePosition
    public var tasks: [TaskWorkspaceTask]
    public var isInbox: Bool { id == Self.inboxID }

    public init(id: String = UUID().uuidString, title: String,
                position: TaskWorkspacePosition = .init(x: 0.04, y: 0.05),
                tasks: [TaskWorkspaceTask] = []) {
        self.id = id
        self.title = title
        self.position = position
        self.tasks = tasks
    }
}

public struct TaskWorkspaceDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var folders: [TaskWorkspaceFolder]

    public init(schemaVersion: Int = Self.currentSchemaVersion, folders: [TaskWorkspaceFolder]) {
        self.schemaVersion = schemaVersion
        self.folders = folders
    }

    public static func empty() -> Self {
        .init(folders: [.init(id: TaskWorkspaceFolder.inboxID, title: "General")])
    }

    public func task(id: String) -> TaskWorkspaceTask? {
        folders.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    @discardableResult
    public mutating func addFolder(title: String, position: TaskWorkspacePosition) throws -> String {
        let folder = TaskWorkspaceFolder(title: try Self.cleanTitle(title), position: position)
        folders.append(folder)
        return folder.id
    }

    public mutating func renameFolder(id: String, title: String) throws {
        let index = try folderIndex(id)
        // General remains the predictable landing place for unsorted tasks.
        guard !folders[index].isInbox else { throw TaskWorkspaceError.inboxIsPermanent }
        folders[index].title = try Self.cleanTitle(title)
    }

    public mutating func moveFolder(id: String, position: TaskWorkspacePosition) throws {
        let index = try folderIndex(id)
        folders[index].position = .init(x: position.x, y: position.y)
    }

    public mutating func removeFolder(id: String) throws {
        let index = try folderIndex(id)
        guard !folders[index].isInbox else { throw TaskWorkspaceError.inboxIsPermanent }
        let inbox = try folderIndex(TaskWorkspaceFolder.inboxID)
        // Folder removal is reversible organisation, never bulk task deletion.
        folders[inbox].tasks.append(contentsOf: folders[index].tasks)
        folders.remove(at: index)
    }

    @discardableResult
    public mutating func addTask(title: String, to folderID: String,
                                 linkedIntentionID: String? = nil) throws -> String {
        let index = try folderIndex(folderID)
        let task = TaskWorkspaceTask(title: try Self.cleanTitle(title),
                                     linkedIntentionID: Self.cleanLink(linkedIntentionID))
        folders[index].tasks.append(task)
        return task.id
    }

    public mutating func updateTask(id: String, title: String, linkedIntentionID: String?) throws {
        let (folder, task) = try taskIndex(id)
        folders[folder].tasks[task].title = try Self.cleanTitle(title)
        folders[folder].tasks[task].linkedIntentionID = Self.cleanLink(linkedIntentionID)
    }

    public mutating func setCompleted(taskID: String, completed: Bool) throws {
        let (folder, task) = try taskIndex(taskID)
        folders[folder].tasks[task].isCompleted = completed
    }

    /// Uses a stable destination task identity; indices from a drag's stale
    /// snapshot cannot silently reorder the wrong task. Nil appends to the end.
    public mutating func moveTask(id: String, to folderID: String, beforeTaskID: String? = nil) throws {
        let (sourceFolder, sourceTask) = try taskIndex(id)
        let destination = try folderIndex(folderID)
        if beforeTaskID == id, sourceFolder == destination { return }
        if let beforeTaskID {
            guard folders[destination].tasks.contains(where: { $0.id == beforeTaskID }) else {
                throw TaskWorkspaceError.missingTask
            }
        }
        let task = folders[sourceFolder].tasks.remove(at: sourceTask)
        let insertion = beforeTaskID.flatMap { before in
            folders[destination].tasks.firstIndex { $0.id == before }
        } ?? folders[destination].tasks.count
        folders[destination].tasks.insert(task, at: insertion)
    }

    public mutating func removeTask(id: String) throws {
        let (folder, task) = try taskIndex(id)
        folders[folder].tasks.remove(at: task)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TaskWorkspaceError.unsupportedVersion(schemaVersion)
        }
        guard folders.filter(\.isInbox).count == 1,
              Set(folders.map(\.id)).count == folders.count else { throw TaskWorkspaceError.invalidDocument }
        var taskIDs = Set<String>()
        for folder in folders {
            guard !folder.id.isEmpty, !folder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folder.position.x.isFinite, folder.position.y.isFinite,
                  (0...1).contains(folder.position.x), (0...1).contains(folder.position.y) else {
                throw TaskWorkspaceError.invalidDocument
            }
            for task in folder.tasks {
                guard !task.id.isEmpty, taskIDs.insert(task.id).inserted,
                      !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TaskWorkspaceError.invalidDocument
                }
            }
        }
    }

    private func folderIndex(_ id: String) throws -> Int {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw TaskWorkspaceError.missingFolder }
        return index
    }

    private func taskIndex(_ id: String) throws -> (Int, Int) {
        for folder in folders.indices {
            if let task = folders[folder].tasks.firstIndex(where: { $0.id == id }) { return (folder, task) }
        }
        throw TaskWorkspaceError.missingTask
    }

    private static func cleanTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskWorkspaceError.emptyTitle }
        return title
    }

    private static func cleanLink(_ id: String?) -> String? {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }
}

public enum TaskWorkspaceError: LocalizedError, Equatable {
    case developmentOnly, emptyTitle, inboxIsPermanent, missingFolder, missingTask
    case invalidDocument, unsupportedVersion(Int), unknownFields, changedOnDisk, unsafeFile

    public var errorDescription: String? {
        switch self {
        case .developmentOnly: return "The task workspace is available in Test Intent."
        case .emptyTitle: return "Give this item a name first."
        case .inboxIsPermanent: return "General is the home for your unsorted tasks."
        case .missingFolder: return "That checklist has changed. Reopen the workspace and try again."
        case .missingTask: return "That task has changed. Reopen the workspace and try again."
        case .invalidDocument: return "This workspace could not be read. Your saved file has been kept."
        case .unsupportedVersion: return "This workspace was saved by a different version of Test Intent. Its file has been kept."
        case .unknownFields: return "This workspace has newer details that this Test Intent cannot edit. Its file has been kept."
        case .changedOnDisk: return "Your workspace changed elsewhere. Reopen it to load the latest tasks."
        case .unsafeFile: return "This workspace location is unavailable. Your saved file has been kept."
        }
    }
}
