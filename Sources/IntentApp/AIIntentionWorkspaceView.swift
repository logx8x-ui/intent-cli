import AppKit
import SwiftUI
import IntentCore

struct AIWorkspaceRequest: Equatable {
    let id = UUID()
    let prompt: String
    let targetIntentionID: String?
    let currentIntention: Intention?

    init(prompt: String, targetIntentionID: String? = nil, currentIntention: Intention? = nil) {
        self.prompt = prompt
        self.targetIntentionID = targetIntentionID
        self.currentIntention = currentIntention
    }
}

struct AIIntentionWorkspaceView: View {
    let catalog: [InstalledApp]
    let existingIntentions: [Intention]
    let request: AIWorkspaceRequest?
    let onFinalise: (Intention, String?) -> Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: Intention?
    @State private var selection: AIDraftSelection?
    @State private var displayedPrompt = ""
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var handledRequestID: UUID?
    @State private var targetIntentionID: String?
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
    }

    private var emptyView: some View {
        VStack(spacing: 13) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(GraphTheme.editBlue)
            Text("What intention would you like to build today?")
                .font(.system(size: 24, weight: .medium))
            Text("Describe one outcome. Intent will draft the apps, websites, restrictions, and friction around it.")
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
                    Text(displayedPrompt)
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
                },
                onAddRestriction: addRestriction,
                onAddFriction: addFriction,
                onSave: { selection = nil }
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
                    },
                    onSave: { selection = nil }
                )
            }
        case .friction(let id):
            if draft?.frictionNodes.contains(where: { $0.id == id }) == true {
                FrictionEditorMenu(
                    node: frictionBinding(id),
                    onDelete: {
                        draft?.frictionNodes.removeAll { $0.id == id }
                        selection = nil
                    },
                    onSave: { selection = nil }
                )
            }
        }
    }

    private var bottomComposer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GraphTheme.muted(colorScheme))
            TextField(draft == nil ? "What intention would you like to build today?" : "Add or change something in this intention", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($promptFocused)
                .onSubmit(submitPrompt)
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
        .padding(.horizontal, 170)
        .padding(.bottom, 18)
    }

    private var finaliseButton: some View {
        Button {
            guard let draft,
                  !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !draft.allowedApps.isEmpty else {
                errorMessage = "Name the intention and choose at least one app."
                return
            }
            let finalDraft = draft
            let finalTargetID = targetIntentionID
            NSApp.keyWindow?.makeFirstResponder(nil)
            selection = nil
            if onFinalise(finalDraft, finalTargetID) {
                self.draft = nil
                targetIntentionID = nil
                displayedPrompt = ""
                errorMessage = nil
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
            set: { draft = $0 }
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
            }
        )
    }

    private func addRestriction() {
        guard draft != nil else { return }
        let count = draft?.restrictionNodes.count ?? 0
        let node = RestrictionNode(
            kind: .allowBrowserSearches,
            position: .init(x: Double((count % 3) - 1) * 155, y: -205 - Double(count / 3) * 130)
        )
        draft?.restrictionNodes.append(node)
        selection = .restriction(node.id)
    }

    private func addFriction() {
        guard draft != nil else { return }
        let count = draft?.frictionNodes.count ?? 0
        let node = FrictionNode(
            friction: .typedPhrase("I want to do this right now"),
            position: .init(x: Double((count % 3) - 1) * 155, y: 220 + Double(count / 3) * 135)
        )
        draft?.frictionNodes.append(node)
        selection = .friction(node.id)
    }

    private func submitPrompt() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isGenerating else { return }
        prompt = ""
        promptFocused = false
        if let referenced = intentionReferenced(in: value) {
            draft = referenced
            targetIntentionID = referenced.id
        }
        generate(value)
    }

    private func intentionReferenced(in prompt: String) -> Intention? {
        existingIntentions
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.count > $1.name.count }
            .first { intention in
                let escaped = NSRegularExpression.escapedPattern(for: intention.name)
                let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
                return prompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
    }

    private func generatePendingRequest() {
        guard let request, handledRequestID != request.id else { return }
        handledRequestID = request.id
        targetIntentionID = request.targetIntentionID
        if let currentIntention = request.currentIntention {
            draft = currentIntention
        }
        generate(request.prompt)
    }

    private func generate(_ description: String) {
        let installedApps = catalog.map {
            AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
        }
        displayedPrompt = description
        errorMessage = nil
        isGenerating = true
        selection = nil

        Task {
            do {
                let plan = try await service.generate(
                    description: description,
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
                let updatedIntention = intention
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.24)) { draft = updatedIntention }
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
                showsRemainingTime: item.kind == .timer || item.kind == .coolDown ? true : nil
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
