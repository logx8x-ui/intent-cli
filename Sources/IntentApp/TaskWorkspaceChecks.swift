import AppKit
import SwiftUI
import IntentCore

/// Isolated production-view checks. These create no visible window, post no
/// input and never read the daily Test Intent task file.
@MainActor
enum TaskWorkspaceChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        guard IntentEnvironment.isQA else { throw failure("Task workspace checks require isolated QA data") }
        try checkGeometry(check)
        try checkMentionRouting(check)
        try checkPersistenceBoundary(check)
        try render(check)
    }

    private static func checkGeometry(_ check: (Bool, String) throws -> Void) throws {
        for canvas in [CGSize(width: 320, height: 230), CGSize(width: 744, height: 390),
                       CGSize(width: 1224, height: 590), CGSize(width: 1654, height: 900)] {
            let card = TaskWorkspaceGeometry.cardSize(in: canvas)
            let bounds = CGRect(origin: .zero, size: canvas)
            for coordinate in [0.0, 0.04, 0.5, 1.0] {
                let position = TaskWorkspacePosition(x: coordinate, y: 1 - coordinate)
                let origin = TaskWorkspaceGeometry.origin(for: position, canvas: canvas, card: card)
                try check(bounds.contains(CGRect(origin: origin, size: card)),
                    "The entire task notepad stays reachable after display resizing")
                for travel in [CGPoint(x: -2000, y: -2000), CGPoint(x: 2000, y: 2000)] {
                    let clamped = TaskWorkspaceGeometry.position(for: travel, canvas: canvas, card: card)
                    let result = TaskWorkspaceGeometry.origin(for: clamped, canvas: canvas, card: card)
                    try check(bounds.contains(CGRect(origin: result, size: card)),
                        "Dragging cannot lose a task list beyond the desktop edge")
                }
            }
        }
        let canvas = CGSize(width: 1224, height: 590)
        let card = TaskWorkspaceGeometry.cardSize(in: canvas)
        let first = TaskWorkspaceFolder(title: "General", position: .init(x: 0.04, y: 0.05))
        let next = TaskWorkspaceGeometry.newPosition(existing: [first], canvas: canvas)
        let firstFrame = CGRect(origin: TaskWorkspaceGeometry.origin(for: first.position, canvas: canvas, card: card), size: card)
        let nextFrame = CGRect(origin: TaskWorkspaceGeometry.origin(for: next, canvas: canvas, card: card), size: card)
        try check(!firstFrame.intersects(nextFrame), "A new list uses available desktop space instead of covering the existing list")
    }

    private static func checkMentionRouting(_ check: (Bool, String) throws -> Void) throws {
        try check(TaskWorkspaceMention.parse("@") == .init(prefix: "", query: ""),
            "A lone @ opens saved intention suggestions")
        try check(TaskWorkspaceMention.parse("Read chapter two @Study biology") == .init(prefix: "Read chapter two", query: "Study biology"),
            "A multiword saved intention mention retains the user's task title")
        try check(TaskWorkspaceMention.parse("Email sam@example.com") == nil,
            "An email address does not become a saved intention mention")
        try check(TaskWorkspaceMention.parse("한국어 연습 @Korean")?.prefix == "한국어 연습",
            "Mention parsing preserves Unicode task text")

        var text = "@Korean"
        var commands: [TaskWorkspaceInputCommand] = []
        let input = TaskWorkspaceInput(text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "Task", accessibilityName: "QA task input", onCommand: { command in
                commands.append(command)
                return command == .down || command == .submit || command == .cancel
            })
        let coordinator = input.makeCoordinator()
        let field = TaskWorkspaceTextField(frame: .zero)
        field.stringValue = text
        coordinator.field = field
        let editor = NSTextView()
        try check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))),
            "The local field routes mention navigation without a global shortcut")
        try check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "Return reaches the mention/task submit owner")
        try check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
            "Escape can dismiss a mention before closing the workspace")
        try check(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))),
            "Ordinary text editing arrows retain native field-editor behaviour")
        try check(commands == [.down, .submit, .cancel], "Each local editor key has one owner")
        try check(field.window == nil, "Editor command fixtures never create or activate a desktop window")
    }

    private static func checkPersistenceBoundary(_ check: (Bool, String) throws -> Void) throws {
        let file = IntentEnvironment.dataDirectory.appendingPathComponent("task-ui-persistence-\(UUID().uuidString).json")
        let model = TaskWorkspaceViewModel(store: TaskWorkspaceStore(fileURL: file))
        try check(model.isAvailable, "An isolated empty task document opens without onboarding or account setup")
        try check(model.addTask(title: "Review lecture", folderID: TaskWorkspaceFolder.inboxID, linkedIntentionID: nil),
            "A task is accepted only after its store save succeeds")
        guard let task = model.document.folders.first?.tasks.first else { throw failure("No saved task") }
        model.removeTask(task.id)
        try check(model.document.task(id: task.id) == nil && model.canUndo, "Deleting a task exposes Undo")
        model.undo()
        try check(model.document.task(id: task.id) == task, "Undo restores the deleted task with its stable identity")

        let before = model.document
        let otherStore = TaskWorkspaceStore(fileURL: file)
        var other = try otherStore.load()
        try other.addTask(title: "Added elsewhere", to: TaskWorkspaceFolder.inboxID)
        try otherStore.save(other)
        model.toggle(task)
        try check(model.document == before && model.notice != nil,
            "A stale writer cannot show a successful completion that was not saved")
        try check(try TaskWorkspaceStore(fileURL: file).load() == other,
            "The UI preserves tasks written elsewhere when a save conflicts")
        let fieldID = "add:" + TaskWorkspaceFolder.inboxID
        let draft = TaskWorkspaceViewModel.TaskWorkspaceDraft(title: "다음 과제 @ personal title", linkedIntentionID: "stable-saved-id")
        model.rememberDraft(for: fieldID, title: draft.title, linkedIntentionID: draft.linkedIntentionID)
        let failedSave = model.saveDraft(for: fieldID) {
            model.addTask(title: $0, folderID: TaskWorkspaceFolder.inboxID, linkedIntentionID: $1)
        }
        try check(!failedSave && model.draft(for: fieldID) == draft && model.document == before,
            "A failed departure save retains the exact task text and preset link outside the destroyed view")
        model.reload()
        try check(model.document == other && model.notice == nil, "Retry reloads the current task file without resetting it")
        try check(model.draft(for: fieldID) == draft,
            "Reopening a field after reloading lists recovers its unsaved draft instead of replacing it with an empty input")
        let retried = model.saveDraft(for: fieldID) {
            model.addTask(title: $0, folderID: TaskWorkspaceFolder.inboxID, linkedIntentionID: $1)
        }
        try check(retried && model.draft(for: fieldID) == nil
            && model.document.folders.first?.tasks.contains(where: { $0.title == draft.title && $0.linkedIntentionID == draft.linkedIntentionID }) == true,
            "Successful retry persists the pending text and link once, then releases the draft")

        guard let folderID = model.addFolder(position: .init(x: 0.5, y: 0.5)) else { throw failure("No temporary list") }
        _ = model.addTask(title: "Original task", folderID: folderID, linkedIntentionID: nil)
        guard let edited = model.document.folders.first(where: { $0.id == folderID })?.tasks.first else { throw failure("No list task") }
        let addID = "add:" + folderID
        let editID = "edit:" + edited.id
        model.rememberDraft(for: addID, title: "Typed without Return", linkedIntentionID: "add-link")
        model.rememberDraft(for: editID, title: "Edited without Return", linkedIntentionID: "edit-link")
        model.removeFolder(folderID)
        let inboxTasks = model.document.folders.first(where: \.isInbox)?.tasks ?? []
        try check(inboxTasks.contains(where: { $0.title == "Typed without Return" && $0.linkedIntentionID == "add-link" })
            && inboxTasks.contains(where: { $0.id == edited.id && $0.title == "Edited without Return" && $0.linkedIntentionID == "edit-link" }),
            "Removing a list atomically saves its unsent addition and edit into General")
        try check(model.draft(for: addID) == nil && model.draft(for: editID) == nil,
            "Disappearing fields do not retain already-committed list-removal drafts")
        var staleSaves = 0
        _ = model.saveDraft(for: addID) { _, _ in staleSaves += 1; return true }
        try check(staleSaves == 0, "A stale disappearing composer cannot duplicate the task after list removal")
        model.undo()
        let restored = model.document.folders.first { $0.id == folderID }
        try check(restored?.tasks.count == 2 && restored?.tasks.contains(where: { $0.title == "Typed without Return" }) == true
            && restored?.tasks.contains(where: { $0.id == edited.id && $0.title == "Edited without Return" }) == true,
            "Undo restores the removed list including both live drafts, not their pre-edit snapshot")
    }

    private static func render(_ check: (Bool, String) throws -> Void) throws {
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let file = IntentEnvironment.dataDirectory.appendingPathComponent("task-ui-render-\(UUID().uuidString).json")
        let store = TaskWorkspaceStore(fileURL: file)
        var document = try store.load()
        let study = try document.addFolder(title: "Study", position: .init(x: 0.52, y: 0.12))
        try document.addTask(title: "Read chapter two and write down the questions I want to ask", to: TaskWorkspaceFolder.inboxID)
        try document.addTask(title: "A task with a removed saved intention", to: TaskWorkspaceFolder.inboxID, linkedIntentionID: "removed-preset")
        let completed = try document.addTask(title: "A completed task", to: study)
        try document.setCompleted(taskID: completed, completed: true)
        try document.addTask(title: "한국어를 조금씩 공부하기", to: study)
        try store.save(document)
        let model = TaskWorkspaceViewModel(store: store)

        for size in [CGSize(width: 800, height: 600), CGSize(width: 1280, height: 800)] {
            let view = TaskWorkspaceView(viewModel: model, savedIntentions: [], onChooseTask: { _ in }, onBack: {})
                .frame(width: size.width, height: size.height)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.23, blue: 0.28), Color(white: 0.07)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No task workspace bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No task workspace PNG") }
            try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("task-workspace-\(Int(size.width))x\(Int(size.height)).png"))
            try check(host.window == nil && host.bounds.size == size, "Task workspace renders offscreen at the intended viewport size")
        }
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "Rendering the task desktop does not activate an app or change the foreground window")
        try check(try store.load() == document, "Rendering does not rewrite task titles, positions, links or completion state")
    }

    private static func failure(_ detail: String) -> NSError {
        NSError(domain: "TaskWorkspaceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
