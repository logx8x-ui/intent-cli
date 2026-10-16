import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IntentCore

private struct TaskWorkspaceActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var taskWorkspaceActive: Bool {
        get { self[TaskWorkspaceActiveKey.self] }
        set { self[TaskWorkspaceActiveKey.self] = newValue }
    }
}

/// A content page hosted over the overview's existing desktop wallpaper. The
/// caller owns channel gating, the two-finger gesture and the selection draft.
@MainActor
struct TaskWorkspaceView: View {
    @StateObject private var model: TaskWorkspaceViewModel
    let savedIntentions: [Intention]
    let onChooseTask: (TaskWorkspaceTask) -> Void
    let onBack: () -> Void
    let onEditingChanged: (Bool) -> Void
    @State private var openFolderIDs = Set<String>()
    @State private var frontFolderID: String?
    @State private var renameFolderID: String?
    @State private var editingFields = Set<String>()
    @State private var canvasSize = CGSize(width: 1000, height: 600)
    @State private var didOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: TaskWorkspaceViewModel? = nil, savedIntentions: [Intention],
         onChooseTask: @escaping (TaskWorkspaceTask) -> Void, onBack: @escaping () -> Void,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: viewModel ?? TaskWorkspaceViewModel())
        self.savedIntentions = savedIntentions
        self.onChooseTask = onChooseTask
        self.onBack = onBack
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            if let notice = model.notice { noticeView(notice) }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { resignEditing() }
                    ForEach(model.document.folders.filter { openFolderIDs.contains($0.id) }) { folder in
                        TaskWorkspaceNotepad(model: model, folder: folder,
                            savedIntentions: savedIntentions, canvas: geometry.size,
                            isRenaming: Binding(get: { renameFolderID == folder.id }, set: { value in
                                renameFolderID = value ? folder.id : nil
                            }),
                            onClose: { close(folder) },
                            onChooseTask: onChooseTask,
                            onEditingChanged: setEditing,
                            onBringForward: { frontFolderID = folder.id })
                        .zIndex(frontFolderID == folder.id ? 10 : 0)
                    }
                    if openFolderIDs.isEmpty, model.isAvailable {
                        VStack(spacing: 10) {
                            Image(systemName: "checklist").font(.system(size: 32, weight: .ultraLight))
                            Text("A little space to think.").font(.system(size: 25, weight: .regular, design: .serif))
                            Text("Open a list above, or make a new one.")
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "TaskWorkspaceDesktop")
                .onAppear { canvasSize = geometry.size }
                .onChange(of: geometry.size) { canvasSize = $0 }
            }
            HStack(spacing: 6) {
                Image(systemName: "hand.draw").font(.system(size: 12))
                Text("Drag lists to arrange · Drag tasks to organise · Click a task to choose your apps")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Button {
                    model.undo()
                    openFolderIDs.formUnion(model.document.folders.map(\.id))
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }.buttonStyle(.plain).disabled(!model.canUndo).help("Undo the last task or list change")
                Text("Test Intent").font(.system(size: 11, weight: .medium)).tracking(0.4)
            }.foregroundStyle(.white.opacity(0.6)).font(.system(size: 12))
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 22)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            if !didOpen {
                openFolderIDs = Set(model.document.folders.map(\.id))
                didOpen = true
            }
        }
        .onDisappear { onEditingChanged(false) }
        .onChange(of: editingFields) { onEditingChanged(!$0.isEmpty) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Button { resignEditing(); onBack() } label: {
                    Label("Choose apps", systemImage: "arrow.left").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }.buttonStyle(.plain).background(.ultraThinMaterial, in: Capsule())
                    .help("Return to your intention, or swipe right with two fingers")
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    Text("Make room for what matters.").font(.system(size: 26, weight: .regular, design: .serif))
                    Text("Your tasks, ready to become intentions.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Button(action: addFolder) {
                    Label("New list", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 15).padding(.vertical, 10)
                }.buttonStyle(.plain).background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .disabled(!model.isAvailable)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.document.folders) { folder in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                openFolderIDs.insert(folder.id)
                                frontFolderID = folder.id
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: folder.isInbox ? "tray" : "checklist")
                                Text(folder.title).lineLimit(1)
                                Text("\(folder.tasks.filter { !$0.isCompleted }.count)")
                                    .monospacedDigit().foregroundStyle(.white.opacity(0.6))
                            }.font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.white.opacity(openFolderIDs.contains(folder.id) ? 0.16 : 0.055), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.7))
                        }.buttonStyle(.plain).help("Open \(folder.title), or drop a task here")
                            .onDrop(of: [TaskWorkspaceTransfer.type], isTargeted: nil) { providers in
                                TaskWorkspaceTransfer.accept(providers) {
                                    model.moveTask($0, to: folder.id)
                                    openFolderIDs.insert(folder.id)
                                    frontFolderID = folder.id
                                }
                            }
                    }
                }
            }
        }
    }

    private func noticeView(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(notice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !model.isAvailable {
                Button("Try again") { model.reload(); openFolderIDs = Set(model.document.folders.map(\.id)) }
            } else {
                Button("Reload lists") { model.reload() }
                Button("Dismiss") { model.dismissNotice() }
            }
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }

    private func addFolder() {
        resignEditing()
        let position = TaskWorkspaceGeometry.newPosition(existing: model.document.folders, canvas: canvasSize)
        guard let id = model.addFolder(position: position) else { return }
        openFolderIDs.insert(id)
        frontFolderID = id
        renameFolderID = id
    }

    private func close(_ folder: TaskWorkspaceFolder) {
        resignEditing()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { _ = openFolderIDs.remove(folder.id) }
    }

    private func setEditing(_ id: String, _ editing: Bool) {
        if editing { editingFields.insert(id) } else { editingFields.remove(id) }
    }

    private func resignEditing() {
        // Ends the current field editor in-place. Never activates another window.
        NSApp.keyWindow?.makeFirstResponder(nil)
        renameFolderID = nil
    }
}

@MainActor
private struct TaskWorkspaceNotepad: View {
    @ObservedObject var model: TaskWorkspaceViewModel
    let folder: TaskWorkspaceFolder
    let savedIntentions: [Intention]
    let canvas: CGSize
    @Binding var isRenaming: Bool
    let onClose: () -> Void
    let onChooseTask: (TaskWorkspaceTask) -> Void
    let onEditingChanged: (String, Bool) -> Void
    let onBringForward: () -> Void
    @State private var dragOrigin: CGPoint?
    @State private var dragOffset = CGSize.zero
    @State private var resizeOrigin: CGRect?
    @State private var resizeFrame: CGRect?
    @State private var titleDraft = ""
    @State private var showCompleted = true
    @State private var dropTargeted = false
    @State private var folderDropTargeted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var card: CGSize { resizeFrame?.size ?? TaskWorkspaceGeometry.cardSize(in: canvas, saved: folder.size) }
    private var origin: CGPoint {
        if let resizeFrame { return resizeFrame.origin }
        let saved = TaskWorkspaceGeometry.origin(for: folder.position, canvas: canvas, card: card)
        let moved = CGPoint(x: (dragOrigin ?? saved).x + dragOffset.width,
                            y: (dragOrigin ?? saved).y + dragOffset.height)
        let bounded = TaskWorkspaceGeometry.position(for: moved, canvas: canvas, card: card)
        return TaskWorkspaceGeometry.origin(for: bounded, canvas: canvas, card: card)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if folder.tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(folder.isInbox ? "Start with whatever’s on your mind." : "One small step at a time.")
                                .font(.system(size: 15, weight: .regular, design: .serif)).foregroundStyle(.white.opacity(0.85))
                            Text(folder.isInbox ? "Add a task below, then drag it into a list whenever you’re ready." : "Add tasks here, or drag them over from General.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.52)).lineSpacing(3)
                        }.padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 20)
                    }
                    ForEach(folder.tasks.filter { showCompleted || !$0.isCompleted }) { task in
                        TaskWorkspaceTaskRow(model: model, task: task, folderID: folder.id,
                            savedIntentions: savedIntentions, onChoose: { onChooseTask(task) },
                            onEditingChanged: onEditingChanged)
                    }
                    Color.clear.frame(height: 28).contentShape(Rectangle())
                        .onDrop(of: [TaskWorkspaceTransfer.type], isTargeted: $dropTargeted) { providers in
                            TaskWorkspaceTransfer.accept(providers) { model.moveTask($0, to: folder.id) }
                        }
                        .overlay {
                            if dropTargeted {
                                Text("Move to \(folder.title)").font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8)).allowsHitTesting(false)
                            }
                        }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                TaskWorkspaceComposer(model: model, savedIntentions: savedIntentions, fieldID: "add:" + folder.id,
                    initialTitle: "", initialLinkedID: nil, initiallyFocused: false,
                    placeholder: "Add a task · @ saved intention", actionTitle: "Add task",
                    onEditingChanged: onEditingChanged,
                    onSave: { model.addTask(title: $0, folderID: folder.id, linkedIntentionID: $1) },
                    onCancel: {})
                if folder.tasks.contains(where: \.isCompleted) {
                    Button { showCompleted.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            Text("\(folder.tasks.filter(\.isCompleted).count) completed")
                        }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
                .background(.white.opacity(0.035))
        }
        .frame(width: card.width, height: card.height)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.12))
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.12)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(
            LinearGradient(colors: [.white.opacity(folderDropTargeted ? 0.75 : 0.32), .white.opacity(folderDropTargeted ? 0.4 : 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: folderDropTargeted ? 2 : 1))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 9)
        .onDrop(of: [TaskWorkspaceTransfer.type], isTargeted: $folderDropTargeted) { providers in
            TaskWorkspaceTransfer.accept(providers) { model.moveTask($0, to: folder.id) }
        }
        .overlay { resizeHandles }
        .offset(x: origin.x, y: origin.y)
        .simultaneousGesture(TapGesture().onEnded { onBringForward() })
        .onChange(of: isRenaming) { if $0 { titleDraft = folder.title } }
        .onAppear { titleDraft = folder.title }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(folder.title) task list")
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.isInbox ? "tray" : "line.3.horizontal")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                .help("Drag to move this list")
            if isRenaming, !folder.isInbox {
                TaskWorkspaceInput(text: $titleDraft, placeholder: "Name this list", accessibilityName: "List name",
                    initiallyFocused: true, onCommand: { command in
                        if command == .submit { finishRename(); return true }
                        if command == .cancel { isRenaming = false; return true }
                        return false
                    }, onFocusChange: { editing in
                        onEditingChanged("folder:" + folder.id, editing)
                        if !editing { finishRename() }
                    }).frame(height: 26)
            } else {
                Text(folder.title).font(.system(size: 20, weight: .medium, design: .serif)).lineLimit(1)
                    .onTapGesture(count: 2) { if !folder.isInbox { titleDraft = folder.title; isRenaming = true } }
                    .help(folder.isInbox ? "Your general inbox" : "Double-click to rename; drag to move")
            }
            Spacer(minLength: 0)
            Menu {
                if !folder.isInbox {
                    Button("Rename list") { titleDraft = folder.title; isRenaming = true }
                    Divider()
                    Button("Move tasks to General and remove list") { model.removeFolder(folder.id) }
                }
                Button("Close list") { onClose() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 22, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(folder.title) list options")
            Button(action: onClose) {
                Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .help("Close this list; tasks stay saved")
                .accessibilityLabel("Close \(folder.title) list")
        }.padding(.horizontal, 18).frame(height: 61).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("TaskWorkspaceDesktop"))
                .onChanged { gesture in
                    guard !isRenaming else { return }
                    if dragOrigin == nil {
                        onBringForward()
                        dragOrigin = TaskWorkspaceGeometry.origin(for: folder.position, canvas: canvas, card: card)
                    }
                    dragOffset = gesture.translation
                }
                .onEnded { _ in
                    guard dragOrigin != nil else { return }
                    let final = TaskWorkspaceGeometry.position(for: origin, canvas: canvas, card: card)
                    model.moveFolder(folder.id, to: final)
                    dragOrigin = nil
                    dragOffset = .zero
                })
    }

    private var resizeHandles: some View {
        ZStack {
            ForEach(Array(TaskWorkspaceGeometry.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                Color.clear.contentShape(Rectangle()).frame(width: 24, height: 24)
                    .overlay(alignment: .center) {
                        if corner == .bottomRight {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).allowsHitTesting(false)
                        }
                    }
                    .position(x: corner.left ? 12 : card.width - 12, y: corner.top ? 12 : card.height - 12)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("TaskWorkspaceDesktop"))
                        .onChanged { value in
                            if resizeOrigin == nil {
                                onBringForward()
                                resizeOrigin = CGRect(origin: origin, size: card)
                            }
                            if let start = resizeOrigin {
                                resizeFrame = TaskWorkspaceGeometry.resized(start, corner: corner,
                                    translation: value.translation, canvas: canvas)
                            }
                        }
                        .onEnded { _ in
                            if let frame = resizeFrame { model.resizeFolder(folder.id, frame: frame, canvas: canvas) }
                            resizeOrigin = nil; resizeFrame = nil
                        })
                    .accessibilityLabel("Resize \(folder.title) from \(String(describing: corner))")
            }
        }
    }

    private func finishRename() {
        guard isRenaming else { return }
        model.renameFolder(folder.id, to: titleDraft)
        isRenaming = false
    }
}

@MainActor
private struct TaskWorkspaceTaskRow: View {
    @ObservedObject var model: TaskWorkspaceViewModel
    let task: TaskWorkspaceTask
    let folderID: String
    let savedIntentions: [Intention]
    let onChoose: () -> Void
    let onEditingChanged: (String, Bool) -> Void
    @State private var editing = false
    @State private var hovered = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggle(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(task.isCompleted ? .white.opacity(0.4) : .white.opacity(0.72))
                    .frame(width: 22, height: 26)
            }.buttonStyle(.plain).accessibilityLabel(task.isCompleted ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
            if editing {
                TaskWorkspaceComposer(model: model, savedIntentions: savedIntentions, fieldID: "edit:" + task.id,
                    initialTitle: task.title, initialLinkedID: task.linkedIntentionID, initiallyFocused: true,
                    placeholder: "Task name", actionTitle: "Save task",
                    onEditingChanged: onEditingChanged,
                    onSave: { title, link in
                        let saved = model.editTask(task.id, title: title, linkedIntentionID: link)
                        if saved { editing = false }
                        return saved
                    }, onCancel: { editing = false })
            } else {
                Button(action: onChoose) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                            .strikethrough(task.isCompleted).foregroundStyle(.white.opacity(task.isCompleted ? 0.42 : 0.96))
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        if task.linkedIntentionID != nil {
                            let linked = task.linkedIntention(in: savedIntentions)
                            HStack(spacing: 4) {
                                Image(systemName: linked == nil ? "link.badge.plus" : "at")
                                Text(linked?.name ?? "Saved intention removed · choose apps").lineLimit(1)
                            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.57))
                        }
                    }.padding(.top, 4).padding(.bottom, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Prepare an intention for \(task.title)")
                    .accessibilityLabel("Choose apps for \(task.title)")
                    .onDrag { TaskWorkspaceTransfer.provider(task.id) }
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).frame(width: 22, height: 26)
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(hovered ? 0.7 : 0.22))
                    .accessibilityLabel("Edit \(task.title)")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) {
            if dropTargeted { Capsule().fill(.white.opacity(0.7)).frame(height: 2) }
        }
        .onHover { hovered = $0 }
        .onDrop(of: [TaskWorkspaceTransfer.type], isTargeted: $dropTargeted) { providers in
            TaskWorkspaceTransfer.accept(providers) { model.moveTask($0, to: folderID, before: task.id) }
        }
        .contextMenu {
            Button("Choose apps for this task", action: onChoose)
            Button("Edit task") { editing = true }
            Button(task.isCompleted ? "Mark incomplete" : "Mark complete") { model.toggle(task) }
            Menu("Move to list") {
                ForEach(model.document.folders.filter { $0.id != folderID }) { folder in
                    Button(folder.title) { model.moveTask(task.id, to: folder.id) }
                }
            }
            Divider()
            Button("Delete task") { model.removeTask(task.id) }
        }
    }
}

@MainActor
private struct TaskWorkspaceComposer: View {
    @ObservedObject var model: TaskWorkspaceViewModel
    let savedIntentions: [Intention]
    let fieldID: String
    let initialTitle: String
    let initialLinkedID: String?
    let initiallyFocused: Bool
    let placeholder: String
    let actionTitle: String
    let onEditingChanged: (String, Bool) -> Void
    let onSave: (String, String?) -> Bool
    let onCancel: () -> Void
    @State private var text = ""
    @State private var linkedID: String?
    @State private var suggestionIndex = 0
    @State private var mentionDismissed = false
    @State private var focusRequest = 0
    @State private var focused = false
    @State private var loaded = false
    @State private var cancelled = false
    @State private var saved = false
    @Environment(\.taskWorkspaceActive) private var workspaceActive

    private var mention: TaskWorkspaceMention? {
        mentionDismissed ? nil : TaskWorkspaceMention.parse(text)
    }

    private var editorText: Binding<String> {
        Binding(get: { text }, set: { value in
            guard text != value else { return }
            text = value
            suggestionIndex = 0
            mentionDismissed = false
            cancelled = false
            saved = false
            rememberDraft()
        })
    }

    private var suggestions: [Intention] {
        guard let mention else { return [] }
        let counts = Dictionary(grouping: savedIntentions, by: \.id).mapValues(\.count)
        return Array(savedIntentions.filter {
            counts[$0.id] == 1 && (
            mention.query.isEmpty || $0.name.localizedStandardContains(mention.query.trimmingCharacters(in: .whitespaces))
            )
        }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if focused, mention != nil {
                mentionMenu
            }
            if let linkedID {
                HStack(spacing: 5) {
                    Image(systemName: "at").font(.system(size: 10, weight: .semibold))
                    Text(savedIntentions.first { $0.id == linkedID }?.name ?? "Saved intention no longer available")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Button { self.linkedID = nil; rememberDraft(); focusRequest += 1 } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 16, height: 16)
                    }.buttonStyle(.plain).accessibilityLabel("Unlink saved intention")
                }.padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 6) {
                TaskWorkspaceInput(text: editorText, placeholder: placeholder, accessibilityName: actionTitle,
                    focusRequest: focusRequest, initiallyFocused: initiallyFocused,
                    onCommand: command, onFocusChange: {
                        focused = $0
                        onEditingChanged(fieldID, $0)
                    }).frame(height: 26)
                Button { submit() } label: {
                    Image(systemName: initiallyFocused ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).background(.white.opacity(0.1), in: Circle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(actionTitle)
            }
        }.onAppear {
            guard !loaded else { return }
            if let pending = model.draft(for: fieldID) {
                text = pending.title
                linkedID = pending.linkedIntentionID
            } else {
                text = initialTitle
                linkedID = initialLinkedID
            }
            loaded = true
        }.onChange(of: workspaceActive) { active in
            if !active { persistOnDeparture() }
        }.onDisappear { persistOnDeparture() }
    }

    private func persistOnDeparture() {
        onEditingChanged(fieldID, false)
        guard loaded, !cancelled, !saved, let draft = model.draft(for: fieldID),
              !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Pages stay mounted during a swipe. A departure still has the same
        // atomic-save semantics as the former view disappearance, and failures
        // retain the shared draft rather than displaying an empty editor.
        if model.saveDraft(for: fieldID, using: onSave) {
            text = ""; linkedID = nil; saved = initiallyFocused
        }
    }

    private var mentionMenu: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SAVED INTENTIONS").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 8).padding(.top, 5)
            if suggestions.isEmpty {
                Text(savedIntentions.isEmpty ? "Bookmark an intention to mention it here." : "No saved intention matches.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).padding(8)
            }
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, intention in
                Button { choose(intention) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bookmark.fill").font(.system(size: 10))
                        Text(intention.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if index == suggestionIndex { Image(systemName: "return").font(.system(size: 10)) }
                    }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                        .background(.white.opacity(index == suggestionIndex ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel("Mention saved intention \(intention.name)")
            }
        }.padding(5).background(Color(white: 0.12).opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }

    private func choose(_ intention: Intention) {
        let prefix = mention?.prefix ?? text
        linkedID = intention.id
        text = prefix.isEmpty ? intention.name : prefix
        mentionDismissed = true
        rememberDraft()
        focusRequest += 1
    }

    private func command(_ command: TaskWorkspaceInputCommand) -> Bool {
        switch command {
        case .up, .down:
            guard mention != nil, !suggestions.isEmpty else { return false }
            suggestionIndex = (suggestionIndex + (command == .down ? 1 : suggestions.count - 1)) % suggestions.count
            return true
        case .submit, .complete:
            if mention != nil, !suggestions.isEmpty {
                choose(suggestions[min(suggestionIndex, suggestions.count - 1)])
                return true
            }
            guard command == .submit else { return false }
            submit()
            return true
        case .cancel:
            if mention != nil { mentionDismissed = true; return true }
            cancelled = true
            model.discardDraft(for: fieldID)
            text = ""
            linkedID = nil
            onCancel()
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
    }

    private func submit() {
        rememberDraft()
        guard model.saveDraft(for: fieldID, using: onSave) else { return }
        saved = initiallyFocused
        text = ""
        linkedID = nil
        mentionDismissed = true
    }

    private func rememberDraft() {
        guard loaded else { return }
        model.rememberDraft(for: fieldID, title: text, linkedIntentionID: linkedID)
    }
}

private enum TaskWorkspaceTransfer {
    static let type = UTType(exportedAs: "app.livewithintent.workspace-task")

    static func provider(_ id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }

    @MainActor
    static func accept(_ providers: [NSItemProvider], move: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, data.count < 128, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else { return }
            DispatchQueue.main.async { move(id) }
        }
        return true
    }
}
