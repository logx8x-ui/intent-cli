import AppKit
import SwiftUI
import IntentCore

struct AIWorkspaceRequest: Equatable {
    let id = UUID()
    let prompt: String
    let targetIntentionID: String?
    let currentIntention: Intention?
    let resumeSessionID: String?

    init(
        prompt: String,
        targetIntentionID: String? = nil,
        currentIntention: Intention? = nil,
        resumeSessionID: String? = nil
    ) {
        self.prompt = prompt
        self.targetIntentionID = targetIntentionID
        self.currentIntention = currentIntention
        self.resumeSessionID = resumeSessionID
    }
}

struct AIIntentionWorkspaceView: View {
    let catalog: [InstalledApp]
    let existingIntentions: [Intention]
    let request: AIWorkspaceRequest?
    let onFinalise: (Intention, String?) -> Bool

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var history = AIWorkspaceSessionController()
    @State private var draft: Intention?
    @State private var selection: AIDraftSelection?
    @State private var displayedPrompt = ""
    @State private var assistantSummary = ""
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var handledRequestID: UUID?
    @State private var targetIntentionID: String?
    @State private var showHistory = false
    @State private var pendingDeleteID: String?
    @State private var mentionQuery: String?
    @FocusState private var promptFocused: Bool

    private let service = IntentAIService()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        selection = nil
                        withAnimation(.easeOut(duration: 0.16)) {
                            showHistory = false
                            mentionQuery = nil
                        }
                    }

                if isGenerating {
                    thinkingView
                } else if let draft {
                    draftConversation(draft, in: proxy.size)
                } else {
                    emptyView
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 84)
                }

                if let clarification = history.clarificationMessage {
                    Text(clarification)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GraphTheme.text(colorScheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 14)
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 88)
                }

                historyButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 22)
                    .padding(.top, 64)

                if showHistory {
                    historyRail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 18)
                        .padding(.top, 104)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(30)
                }

                bottomComposer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                if draft != nil {
                    finaliseButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 76)
                        .padding(.bottom, 22)
                }
            }
            .padding(.top, 52)
        }
        .task(id: request?.id) {
            generatePendingRequest()
        }
        .onExitCommand {
            if showHistory {
                showHistory = false
            } else if mentionQuery != nil {
                mentionQuery = nil
            }
        }
        .confirmationDialog(
            "Delete this draft history?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteID {
                    history.delete(id: pendingDeleteID)
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("The conversation and structured draft will be removed. Your canvas intentions stay as they are.")
        }
    }

    private var historyButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                showHistory.toggle()
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)
        .help("Draft history")
    }

    private var historyRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DRAFTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Spacer()
                Button("New") {
                    beginNewDraft()
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(GraphTheme.editBlue)
            }

            if history.sessions.isEmpty {
                Text("No drafts yet")
                    .font(.system(size: 11))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(history.sessions) { session in
                            historyRow(session)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280, height: 360, alignment: .top)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 16)
        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 18, y: 8)
    }

    private func historyRow(_ session: AIWorkspaceSession) -> some View {
        let selected = history.activeSessionID == session.id
        return Button {
            resume(session)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                appPreview(for: session.draft)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(GraphTheme.text(colorScheme))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                    Text(session.status == .applied ? "Applied" : "Draft")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(session.status == .applied
                            ? Color(red: 0.32, green: 0.72, blue: 0.42)
                            : GraphTheme.editBlue)
                }
                Spacer(minLength: 0)
                Button {
                    pendingDeleteID = session.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(
                selected ? GraphTheme.elevatedSurface(colorScheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appPreview(for intention: Intention?) -> some View {
        let apps = Array((intention?.allowedApps ?? []).prefix(3))
        return ZStack {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                if let installed = catalog.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    Image(nsImage: installed.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .offset(x: CGFloat(index) * 8)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 10))
                        .frame(width: 16, height: 16)
                        .offset(x: CGFloat(index) * 8)
                }
            }
        }
        .frame(width: 36, height: 18, alignment: .leading)
    }

    private var emptyView: some View {
        VStack(spacing: 13) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(GraphTheme.editBlue)
            Text("What intention would you like to build today?")
                .font(.system(size: 24, weight: .medium))
            Text("Describe one outcome, or type @ to revise an existing intention.")
                .font(.system(size: 12))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .offset(y: -28)
    }

    private var thinkingView: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(GraphTheme.editBlue)
            Text("Drafting your intention")
                .font(.system(size: 20, weight: .medium))
            ProgressView()
                .controlSize(.small)
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .offset(y: -30)
    }

    private func draftConversation(_ intention: Intention, in size: CGSize) -> some View {
        let boardWidth = min(max(size.width * 0.72, 680), 1_020)
        let boardHeight = min(max(size.height * 0.62, 440), 650)

        return ZStack {
            VStack(spacing: 14) {
                if !displayedPrompt.isEmpty {
                    Text(AIIntentionMentionResolver.displayText(for: displayedPrompt, intentions: existingIntentions))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GraphTheme.text(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: min(620, boardWidth * 0.72), alignment: .leading)
                        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(GraphTheme.stroke(colorScheme)))
                        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 12, y: 6)
                }

                if !assistantSummary.isEmpty {
                    Text(assistantSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .frame(maxWidth: min(620, boardWidth * 0.72), alignment: .leading)
                }

                if let targetIntentionID,
                   existingIntentions.first(where: { $0.id == targetIntentionID }) == nil {
                    Label("Intention no longer exists", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }

                draftWhiteboard(
                    intention,
                    size: CGSize(width: boardWidth, height: boardHeight)
                )
                .frame(width: boardWidth, height: boardHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 74)

            if let selection {
                draftEditor(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 24)
                    .padding(.top, 110)
                    .padding(.bottom, 90)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .zIndex(20)
            }
        }
    }

    private func draftWhiteboard(_ intention: Intention, size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(GraphTheme.surface(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.84))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    withAnimation(.easeOut(duration: 0.14)) { selection = nil }
                }

            Canvas { context, canvasSize in
                let spacing: CGFloat = 26
                let dotColor = GraphTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.085 : 0.075)
                var x: CGFloat = 22
                while x < canvasSize.width - 22 {
                    var y: CGFloat = 22
                    while y < canvasSize.height - 22 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                            with: .color(dotColor)
                        )
                        y += spacing
                    }
                    x += spacing
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .allowsHitTesting(false)

            Text("DRAFT")
                .font(.system(size: min(108, size.width * 0.12), weight: .black, design: .rounded))
                .tracking(12)
                .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.045))
                .rotationEffect(.degrees(-8))
                .allowsHitTesting(false)

            draftGraph(intention, in: size)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.and.outline")
                    Text("DRAFT BOARD")
                        .tracking(1.2)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.82))

                Text("Select any shape to refine it before finalising.")
                    .font(.system(size: 10))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    GraphTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.52 : 0.38),
                    style: StrokeStyle(lineWidth: 1.35, dash: [7, 7], dashPhase: 1)
                )
        )
        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 24, y: 12)
    }

    private func draftGraph(_ intention: Intention, in size: CGSize) -> some View {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.48)
        return ZStack {
            Canvas { context, _ in
                for node in intention.restrictionNodes {
                    drawDraftConnection(
                        from: center,
                        to: draftPoint(node.position, center: center, size: size),
                        context: &context
                    )
                }
                for node in intention.frictionNodes {
                    drawDraftConnection(
                        from: center,
                        to: draftPoint(node.position, center: center, size: size),
                        context: &context
                    )
                }
            }
            .allowsHitTesting(false)

            Button {
                withAnimation(.easeOut(duration: 0.16)) { selection = .intention }
            } label: {
                IntentionNodeView(
                    intention: intention,
                    installedApps: catalog,
                    selected: selection == .intention,
                    cooldownExpiresAt: nil
                )
                .padding(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            GraphTheme.editBlue.opacity(0.58),
                            style: StrokeStyle(lineWidth: 1.2, dash: [7, 6])
                        )
                )
            }
            .buttonStyle(.plain)
            .position(center)

            ForEach(intention.restrictionNodes) { node in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = .restriction(node.id) }
                } label: {
                    RestrictionNodeView(node: node, selected: selection == .restriction(node.id))
                }
                .buttonStyle(.plain)
                .position(draftPoint(node.position, center: center, size: size))
            }

            ForEach(intention.frictionNodes) { node in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = .friction(node.id) }
                } label: {
                    FrictionNodeView(node: node, selected: selection == .friction(node.id))
                }
                .buttonStyle(.plain)
                .position(draftPoint(node.position, center: center, size: size))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    @ViewBuilder
    private func draftEditor(_ selected: AIDraftSelection) -> some View {
        switch selected {
        case .intention:
            IntentionEditorMenu(
                intention: draftBinding,
                catalog: catalog,
                onDelete: {
                    draft = nil
                    selection = nil
                    history.recordDraftEdit(nil)
                },
                onAddRestriction: addRestriction,
                onAddFriction: addFriction
            )
        case .restriction(let id):
            if let intention = draft,
               intention.restrictionNodes.contains(where: { $0.id == id }) {
                RestrictionEditorMenu(
                    node: restrictionBinding(id),
                    intention: intention,
                    onDelete: {
                        draft?.restrictionNodes.removeAll { $0.id == id }
                        selection = nil
                        history.recordDraftEdit(draft)
                    }
                )
            }
        case .friction(let id):
            if draft?.frictionNodes.contains(where: { $0.id == id }) == true {
                FrictionEditorMenu(
                    node: frictionBinding(id),
                    onDelete: {
                        draft?.frictionNodes.removeAll { $0.id == id }
                        selection = nil
                        history.recordDraftEdit(draft)
                    }
                )
            }
        }
    }

    private var bottomComposer: some View {
        VStack(spacing: 8) {
            if let mentionQuery {
                mentionTypeahead(query: mentionQuery)
            }

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                TextField(
                    draft == nil
                        ? "What intention would you like to build today?"
                        : "Add or change something — type @ to target an intention",
                    text: $prompt
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($promptFocused)
                .onSubmit(submitPrompt)
                .onChange(of: prompt) { value in
                    mentionQuery = AIIntentionMentionResolver.extractAtQuery(from: value)
                }
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: submitPrompt) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .frame(width: 28, height: 28)
                            .background(
                                prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? GraphTheme.muted(colorScheme).opacity(0.35)
                                    : GraphTheme.text(colorScheme),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(maxWidth: 650)
            .frame(height: 48)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 24)
            .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 16, y: 8)
        }
        .padding(.horizontal, 170)
        .padding(.bottom, 18)
    }

    private func mentionTypeahead(query: String) -> some View {
        let matches = AIIntentionMentionResolver.typeahead(query: query, intentions: existingIntentions).prefix(6)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(matches)) { intention in
                Button {
                    insertMention(intention)
                } label: {
                    HStack(spacing: 10) {
                        appPreview(for: intention)
                        Text(intention.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GraphTheme.text(colorScheme))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 420, alignment: .leading)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 14)
    }

    private var finaliseButton: some View {
        Button {
            guard let draft,
                  !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.allowedApps.isEmpty else {
                errorMessage = "Name the intention and choose at least one app."
                return
            }
            if let targetIntentionID,
               existingIntentions.first(where: { $0.id == targetIntentionID }) == nil {
                errorMessage = "That intention no longer exists. Start a new draft or choose another @ mention."
                return
            }
            let finalDraft = draft
            let finalTargetID = targetIntentionID
            NSApp.keyWindow?.makeFirstResponder(nil)
            selection = nil
            if onFinalise(finalDraft, finalTargetID) {
                history.markFinalised(draft: finalDraft, targetIntentionID: finalTargetID)
                self.draft = nil
                targetIntentionID = nil
                displayedPrompt = ""
                assistantSummary = ""
                errorMessage = nil
                history.startNewDraft()
            }
        } label: {
            Label("Finalise", systemImage: "cursorarrow.click.2")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.22, green: 0.72, blue: 0.38))
        .disabled(isGenerating)
        .zIndex(100)
        .help("Move this draft to the intentions desktop")
    }

    private var draftBinding: Binding<Intention> {
        Binding(
            get: { draft ?? Self.emptyDraft },
            set: {
                draft = $0
                history.recordDraftEdit($0)
            }
        )
    }

    private func restrictionBinding(_ id: String) -> Binding<RestrictionNode> {
        Binding(
            get: {
                draft?.restrictionNodes.first(where: { $0.id == id })
                    ?? RestrictionNode(id: id, kind: .allowBrowserSearches, position: .zero)
            },
            set: { updated in
                guard let index = draft?.restrictionNodes.firstIndex(where: { $0.id == id }) else { return }
                draft?.restrictionNodes[index] = updated
                history.recordDraftEdit(draft)
            }
        )
    }

    private func frictionBinding(_ id: String) -> Binding<FrictionNode> {
        Binding(
            get: {
                draft?.frictionNodes.first(where: { $0.id == id })
                    ?? FrictionNode(id: id, friction: .typedPhrase("I want to do this right now"), position: .zero)
            },
            set: { updated in
                guard let index = draft?.frictionNodes.firstIndex(where: { $0.id == id }) else { return }
                draft?.frictionNodes[index] = updated
                history.recordDraftEdit(draft)
            }
        )
    }

    private func addRestriction(_ kind: RestrictionKind = .allowBrowserSearches) {
        guard draft != nil else { return }
        let count = draft?.restrictionNodes.count ?? 0
        let node = RestrictionNode(
            kind: kind,
            position: .init(x: Double((count % 3) - 1) * 155, y: -205 - Double(count / 3) * 130)
        )
        draft?.restrictionNodes.append(node)
        selection = .restriction(node.id)
        history.recordDraftEdit(draft)
    }

    private func addFriction(
        _ friction: Friction = .typedPhrase("I want to do this right now")
    ) {
        guard draft != nil else { return }
        let count = draft?.frictionNodes.count ?? 0
        let node = FrictionNode(
            friction: friction,
            position: .init(x: Double((count % 3) - 1) * 155, y: 220 + Double(count / 3) * 135)
        )
        draft?.frictionNodes.append(node)
        selection = .friction(node.id)
        history.recordDraftEdit(draft)
    }

    private func insertMention(_ intention: Intention) {
        guard let atIndex = prompt.lastIndex(of: "@") else { return }
        let prefix = prompt[..<atIndex]
        let token = AIIntentionMentionResolver.encodeMention(
            displayName: intention.name,
            intentionID: intention.id
        )
        prompt = prefix + token + " "
        mentionQuery = nil
        targetIntentionID = intention.id
        draft = intention
        history.recordTargetChange(intention.id)
        history.recordDraftEdit(intention)
    }

    private func beginNewDraft() {
        history.startNewDraft()
        draft = nil
        targetIntentionID = nil
        displayedPrompt = ""
        assistantSummary = ""
        selection = nil
        errorMessage = nil
        showHistory = false
    }

    private func resume(_ session: AIWorkspaceSession) {
        history.resume(id: session.id)
        draft = session.draft
        targetIntentionID = session.targetIntentionID
        displayedPrompt = session.messages.last(where: { $0.role == .user })?.content ?? ""
        assistantSummary = session.messages.last(where: { $0.role == .assistant })?.content ?? ""
        selection = nil
        errorMessage = nil
        showHistory = false
    }

    private func submitPrompt() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isGenerating else { return }
        prompt = ""
        promptFocused = false
        mentionQuery = nil

        let resolution = history.resolveTarget(
            for: value,
            intentions: existingIntentions,
            currentTarget: targetIntentionID
        )
        if resolution.blocked {
            return
        }
        if let intention = resolution.intention {
            draft = intention
            targetIntentionID = resolution.targetID
        } else if resolution.targetID == nil, targetIntentionID != nil,
                  existingIntentions.first(where: { $0.id == targetIntentionID }) == nil {
            targetIntentionID = nil
        }

        history.recordUserPrompt(value, draft: draft, targetIntentionID: targetIntentionID)
        generate(value)
    }

    private func generatePendingRequest() {
        guard let request, handledRequestID != request.id else { return }
        handledRequestID = request.id
        if let resumeSessionID = request.resumeSessionID,
           let session = history.sessions.first(where: { $0.id == resumeSessionID }) {
            resume(session)
            return
        }
        _ = history.ensureActiveSession()
        targetIntentionID = request.targetIntentionID
        if let currentIntention = request.currentIntention {
            draft = currentIntention
            history.recordDraftEdit(currentIntention)
            history.recordTargetChange(request.targetIntentionID)
        }
        history.recordUserPrompt(request.prompt, draft: draft, targetIntentionID: targetIntentionID)
        generate(request.prompt)
    }

    private func generate(_ description: String) {
        let installedApps = catalog.map {
            AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
        }
        let aiPrompt = AIIntentionMentionResolver.promptForAI(
            stored: description,
            intentions: existingIntentions
        )
        displayedPrompt = description
        errorMessage = nil
        isGenerating = true
        selection = nil

        Task {
            do {
                let plan = try await service.generate(
                    description: aiPrompt,
                    installedApps: installedApps,
                    currentIntention: draft
                ).validated(against: installedApps)
                guard let suggestion = plan.intentions.first else {
                    throw IntentAIError.invalidResponse
                }
                var intention = Self.makeDraft(from: suggestion, apps: installedApps)
                if let current = draft {
                    intention.id = current.id
                    intention.icon = current.icon
                    intention.colorHex = current.colorHex
                    intention.graphPosition = current.graphPosition
                }
                let summary = Self.summary(
                    for: suggestion,
                    targetName: existingIntentions.first { $0.id == targetIntentionID }?.name
                        ?? suggestion.name,
                    isUpdate: targetIntentionID != nil
                )
                let updatedIntention = intention
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.24)) {
                        draft = updatedIntention
                        assistantSummary = summary
                    }
                    history.recordAssistantResult(
                        summary: summary,
                        draft: updatedIntention,
                        targetIntentionID: targetIntentionID
                    )
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = draft == nil
                        ? "Intent AI paused for a moment. Send that request again."
                        : "Your draft is safe. Send that change again."
                    isGenerating = false
                }
            }
        }
    }

    private static func summary(
        for suggestion: AIIntentionSuggestion,
        targetName: String,
        isUpdate: Bool
    ) -> String {
        if isUpdate {
            if let timer = suggestion.restrictions.first(where: { $0.kind == .timer }) {
                return "Updated @\(targetName) with a \(timer.durationMinutes)-minute timer."
            }
            if suggestion.frictions.contains(where: { $0.kind == .typedPhrase }) {
                return "Updated @\(targetName) with a typed phrase friction."
            }
            return "Updated @\(targetName)."
        }
        return "Drafted \(suggestion.name)."
    }

    private static func makeDraft(
        from suggestion: AIIntentionSuggestion,
        apps: [AllowedApp]
    ) -> Intention {
        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, $0) })
        let allowedApps = suggestion.appBundleIdentifiers.compactMap { appsByID[$0] }
        let websites = suggestion.websites.map {
            AllowedWebsite($0.value, browserBundleIdentifier: $0.browserBundleIdentifier)
        }
        let restrictions = suggestion.restrictions.enumerated().map { index, item in
            RestrictionNode(
                kind: item.kind,
                position: connectedPosition(index: index, total: suggestion.restrictions.count, above: true),
                excludedResourceIDs: item.resourceIDs,
                durationMinutes: item.kind == .timer || item.kind == .coolDown ? max(1, item.durationMinutes) : nil,
                showsRemainingTime: item.kind == .timer || item.kind == .coolDown ? true : nil,
                locksSessionUntilTimerEnds: item.kind == .timer ? true : nil
            )
        }
        let frictions = suggestion.frictions.enumerated().map { index, item in
            FrictionNode(
                friction: item.friction(intentionName: suggestion.name),
                position: connectedPosition(index: index, total: suggestion.frictions.count, above: false)
            )
        }

        return Intention(
            name: suggestion.name,
            icon: "sparkles",
            colorHex: "#F5F5F7",
            folder: "",
            allowedApps: allowedApps,
            allowedWebsites: websites,
            startupActions: [],
            restrictions: .init(),
            graphPosition: .zero,
            restrictionNodes: restrictions,
            frictionNodes: frictions
        )
    }

    private static func connectedPosition(index: Int, total: Int, above: Bool) -> GraphPoint {
        let offset = (Double(index) - Double(max(total, 1) - 1) / 2) * 155
        return .init(x: offset, y: above ? -210 : 225)
    }

    private func draftPoint(_ point: GraphPoint, center: CGPoint, size: CGSize) -> CGPoint {
        let horizontalScale = min(1, max(0.7, (size.width - 220) / 620))
        let verticalScale = min(1, max(0.65, (size.height - 160) / 450))
        return CGPoint(
            x: center.x + point.x * horizontalScale,
            y: center.y + point.y * verticalScale
        )
    }

    private func drawDraftConnection(
        from start: CGPoint,
        to end: CGPoint,
        context: inout GraphicsContext
    ) {
        let bend = max(38, abs(end.x - start.x) * 0.36)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + (end.x >= start.x ? bend : -bend), y: start.y),
            control2: CGPoint(x: end.x - (end.x >= start.x ? bend : -bend), y: end.y)
        )
        context.stroke(path, with: .color(GraphTheme.connection(colorScheme).opacity(0.28)), lineWidth: 3.2)
        context.stroke(path, with: .color(GraphTheme.connection(colorScheme)), lineWidth: 1)
    }

    private static let emptyDraft = Intention(
        name: "",
        icon: "sparkles",
        colorHex: "#F5F5F7",
        folder: "",
        allowedApps: [],
        allowedWebsites: [],
        startupActions: [],
        restrictions: .init(),
        graphPosition: .zero
    )
}

private enum AIDraftSelection: Equatable {
    case intention
    case restriction(String)
    case friction(String)
}
