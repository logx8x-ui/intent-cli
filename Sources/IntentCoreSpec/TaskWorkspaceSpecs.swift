import Foundation
import IntentCore

func runTaskWorkspaceSpecs() throws {
    func rejects(_ expected: TaskWorkspaceError? = nil, _ message: String,
                 _ action: () throws -> Void) throws {
        do { try action() }
        catch {
            if let expected { try expect(error as? TaskWorkspaceError == expected, message) }
            return
        }
        throw SpecFailure(description: message)
    }

    var workspace = TaskWorkspaceDocument.empty()
    let inbox = TaskWorkspaceFolder.inboxID
    try expect(workspace.folders.count == 1 && workspace.folders[0].isInbox,
               "A new workspace has one General inbox, with no invented user tasks")
    let korean = try workspace.addFolder(title: "  Korean  ", position: .init(x: 0.45, y: 0.2))
    let school = try workspace.addFolder(title: "Schoolwork", position: .init(x: 0.8, y: 0.5))
    let reading = try workspace.addTask(title: "  Read chapter 3  ", to: inbox)
    let words = try workspace.addTask(title: "Learn today's words", to: inbox, linkedIntentionID: "korean-preset")
    let essay = try workspace.addTask(title: "Draft essay", to: school)
    try workspace.setCompleted(taskID: words, completed: true)
    try workspace.moveTask(id: words, to: korean)
    try workspace.moveTask(id: reading, to: school, beforeTaskID: essay)
    try expect(workspace.folders.first(where: { $0.id == school })?.tasks.map(\.id) == [reading, essay],
               "A cross-folder drop inserts above the intended task and removes its old row")
    try expect(workspace.folders.first(where: { $0.id == inbox })?.tasks.isEmpty == true
        && workspace.task(id: words)?.isCompleted == true
        && workspace.task(id: words)?.linkedIntentionID == "korean-preset",
               "Moving a task preserves completion and its stable saved-intention reference")
    try workspace.moveTask(id: reading, to: school)
    try expect(workspace.folders.first(where: { $0.id == school })?.tasks.map(\.id) == [essay, reading],
               "Dropping onto the same checklist's end reorders without losing the task")
    let beforeSelfDrop = workspace
    try workspace.moveTask(id: essay, to: school, beforeTaskID: essay)
    try expect(workspace == beforeSelfDrop, "Dropping a task onto itself is an idempotent no-op")
    try rejects(.missingTask, "A stale drop target is rejected before removing the original task") {
        try workspace.moveTask(id: reading, to: korean, beforeTaskID: "already-removed")
    }
    try expect(workspace == beforeSelfDrop, "A rejected drag leaves both checklists intact")
    try rejects(.missingFolder, "Dropping onto a removed checklist cannot lose a task") {
        try workspace.moveTask(id: reading, to: "already-removed")
    }
    try workspace.renameFolder(id: korean, title: "한국어")
    try workspace.moveFolder(id: korean, position: .init(x: 0.73, y: 0.06))
    try workspace.updateTask(id: words, title: "Review Korean words", linkedIntentionID: "renamed-preset")
    try workspace.setCompleted(taskID: words, completed: false)
    try expect(workspace.task(id: words)?.title == "Review Korean words"
        && workspace.task(id: words)?.isCompleted == false,
               "Editing or reopening a completed task does not create a duplicate")
    try workspace.setFolderFrame(id: korean, position: .init(x: 0.2, y: 0.3), size: .init(width: 510, height: 370))
    let roundTrip = try JSONDecoder().decode(TaskWorkspaceDocument.self, from: JSONEncoder().encode(workspace))
    try expect(roundTrip == workspace && roundTrip.folders.first(where: { $0.id == korean })?.size == .init(width: 510, height: 370),
        "Resized notes preserve dimensions, position, tasks and links after reopening")
    let legacy = Data(#"{"schemaVersion":1,"folders":[{"id":"general","title":"General","position":{"x":0.1,"y":0.2},"tasks":[]}]}"#.utf8)
    let legacyDocument = try JSONDecoder().decode(TaskWorkspaceDocument.self, from: legacy)
    try legacyDocument.validate()
    try expect(legacyDocument.folders[0].size == nil, "Existing task files without dimensions retain their default size")
    try rejects(.invalidDocument, "Invalid resize cannot corrupt the saved workspace") {
        try workspace.setFolderFrame(id: korean, position: .init(x: 0, y: 0), size: .init(width: .nan, height: 100))
    }
    try workspace.removeFolder(id: korean)
    try expect(workspace.folders.first(where: { $0.id == inbox })?.tasks.map(\.id) == [words]
        && workspace.task(id: words)?.linkedIntentionID == "renamed-preset",
               "Removing an area moves its tasks into General instead of deleting the work")
    try rejects(.inboxIsPermanent, "General cannot be removed") { try workspace.removeFolder(id: inbox) }
    try rejects(.inboxIsPermanent, "General retains its predictable title") { try workspace.renameFolder(id: inbox, title: "Other") }
    let beforeBlank = workspace
    try rejects(.emptyTitle, "Blank task edits are rejected without deleting the existing title") {
        try workspace.updateTask(id: words, title: " \n ", linkedIntentionID: nil)
    }
    try expect(workspace == beforeBlank, "Invalid text edits keep the previous task and link")
    try rejects(.emptyTitle, "Blank folders cannot be created") {
        _ = try workspace.addFolder(title: "  ", position: .init(x: 0, y: 0))
    }
    try workspace.removeTask(id: essay)
    try expect(workspace.task(id: essay) == nil && workspace.task(id: reading) != nil,
               "Deleting one task leaves adjacent work untouched")
    let clamped = TaskWorkspacePosition(x: -4, y: 8)
    try expect(clamped == .init(x: 0, y: 1)
        && TaskWorkspacePosition(x: .infinity, y: .nan) == .init(x: 0, y: 0),
               "Folder positions stay reachable even with an out-of-bounds drag")

    var preset = Intention(id: "renamed-preset", name: "Vocabulary", icon: "book", colorHex: "#ffffff",
        folder: "", allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
    let linked = workspace.task(id: words)!
    preset.name = "Korean practice"
    try expect(linked.linkedIntention(in: [preset])?.name == "Korean practice"
        && linked.title == "Review Korean words", "Renaming a preset keeps its link without renaming the task")
    var replacement = preset; replacement.id = "different-preset"
    try expect(linked.linkedIntention(in: [replacement]) == nil
        && linked.linkedIntention(in: [preset, preset]) == nil,
               "Deleted or ambiguous preset identities cannot silently resolve by a matching name")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("intent-task-workspace-spec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.json")
    let first = TaskWorkspaceStore(fileURL: url)
    let empty = try first.load()
    try expect(empty == .empty() && !FileManager.default.fileExists(atPath: url.path),
               "Opening a nonexistent workspace is read-only until the first edit")
    try first.save(workspace)
    let second = TaskWorkspaceStore(fileURL: url)
    let reopened = try second.load()
    try expect(reopened == workspace, "Task order, completion, links and folder positions survive reopening")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "Task data is readable only by its owner")
    var newer = workspace
    _ = try newer.addTask(title: "Newer task", to: inbox)
    try first.save(newer)
    try rejects(.changedOnDisk, "A stale writer cannot silently overwrite a newer task") { try second.save(workspace) }
    let afterConflict = try TaskWorkspaceStore(fileURL: url).load()
    try expect(afterConflict == newer, "The newer saved tasks remain intact after a conflict")

    let malformed = Data("{interrupted or malformed file".utf8)
    try malformed.write(to: url)
    let recovering = TaskWorkspaceStore(fileURL: url)
    let recovered = try recovering.load()
    try expect(recovered == newer && recovering.didRecoverFromBackup,
               "A readable backup recovers task content without inventing a blank workspace")
    let afterRecoveryRead = try Data(contentsOf: url)
    try expect(afterRecoveryRead == malformed, "Recovery does not rewrite the malformed original on read")
    try recovering.save(recovered)
    let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("task-workspace-recovered-") }
    let preservedBytes = try preserved.first.map { try Data(contentsOf: $0) }
    try expect(preserved.count == 1 && preservedBytes == malformed,
               "The original malformed bytes remain recoverable after an edited save")
    let afterRecoverySave = try TaskWorkspaceStore(fileURL: url).load()
    try expect(afterRecoverySave == newer,
               "Recovered edits atomically become the main workspace")
    try FileManager.default.removeItem(at: url)
    let missingPrimary = TaskWorkspaceStore(fileURL: url)
    let missingRecovered = try missingPrimary.load()
    try expect(missingRecovered == newer && missingPrimary.didRecoverFromBackup,
               "A missing primary file reuses the backup instead of silently resetting all tasks")
    try missingPrimary.save(missingRecovered)

    let future = Data("{\"schemaVersion\":999,\"aNewShape\":true}".utf8)
    try future.write(to: url)
    let futureStore = TaskWorkspaceStore(fileURL: url)
    try rejects(.unsupportedVersion(999), "A future schema cannot fall back to an old backup") { _ = try futureStore.load() }
    try rejects(.unsupportedVersion(999), "Saving before a successful load cannot overwrite a future schema") { try futureStore.save(.empty()) }
    let afterFutureAttempt = try Data(contentsOf: url)
    try expect(afterFutureAttempt == future, "Newer data remains byte-for-byte intact")
    var unknown = try JSONSerialization.jsonObject(with: JSONEncoder().encode(newer)) as! [String: Any]
    var futureFolders = unknown["folders"] as! [[String: Any]]
    futureFolders[0]["futureDetail"] = "keep me"
    unknown["folders"] = futureFolders
    let unknownBytes = try JSONSerialization.data(withJSONObject: unknown)
    try unknownBytes.write(to: url)
    let unknownStore = TaskWorkspaceStore(fileURL: url)
    try rejects(.unknownFields, "Unknown nested fields cannot be dropped by a rollback") { _ = try unknownStore.load() }
    try rejects(.unknownFields, "Unknown fields prevent saving a truncated document") { try unknownStore.save(newer) }
    let afterUnknownAttempt = try Data(contentsOf: url)
    try expect(afterUnknownAttempt == unknownBytes, "Unknown details remain byte-for-byte intact")

    var duplicate = newer
    duplicate.folders[0].tasks.append(duplicate.folders[0].tasks[0])
    try rejects(.invalidDocument, "Duplicate task identity cannot be saved") { try first.save(duplicate) }
    let linkURL = root.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)
    try rejects(.unsafeFile, "A symlink cannot redirect task writes to another workspace") {
        _ = try TaskWorkspaceStore(fileURL: linkURL).load()
    }
    let noBackupURL = root.appendingPathComponent("no-backup.json")
    try malformed.write(to: noBackupURL)
    let noBackup = TaskWorkspaceStore(fileURL: noBackupURL)
    try rejects(nil, "Unreadable data without a backup cannot be replaced by an empty board") {
        try noBackup.save(.empty())
    }
    let afterNoBackup = try Data(contentsOf: noBackupURL)
    try expect(afterNoBackup == malformed, "Failed recovery leaves the only copy of the data untouched")
    if IntentBuildChannel.current == .launch && !IntentEnvironment.isQA {
        try rejects(.developmentOnly, "The launch app cannot open the default experimental workspace") {
            _ = try TaskWorkspaceStore().load()
        }
    }
}
