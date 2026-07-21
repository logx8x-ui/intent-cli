import AppKit
import SwiftUI
import IntentCore

struct AIWorkspaceRequest: Equatable {
    let id = UUID()
    let prompt: String
}

struct AIIntentionWorkspaceView: View {
    let catalog: [InstalledApp]
    let request: AIWorkspaceRequest?
    let onFinalise: (Intention) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: Intention?
    @State private var selection: AIDraftSelection?
    @State private var displayedPrompt = ""
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var handledRequestID: UUID?
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
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
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
        ZStack {
            if !displayedPrompt.isEmpty {
                Text(displayedPrompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GraphTheme.text(colorScheme))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(GraphTheme.stroke(colorScheme)))
                    .frame(maxWidth: min(460, size.width * 0.38), alignment: .trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 30)
                    .padding(.trailing, 34)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(GraphTheme.editBlue)
                    Text("Intent AI")
                        .font(.system(size: 13, weight: .semibold))
                    Text("DRAFT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .padding(.horizontal, 7)
                        .frame(height: 21)
                        .background(GraphTheme.editBlue.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(GraphTheme.editBlue.opacity(0.42)))
                        .foregroundStyle(GraphTheme.editBlue)
                }
                Text("I drafted one focused setup. Select any shape to change it before finalising.")
                    .font(.system(size: 11))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 32)
            .padding(.leading, max(36, size.width * 0.18))

            draftGraph(intention, in: size)

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

    private func draftGraph(_ intention: Intention, in size: CGSize) -> some View {
        let center = CGPoint(x: size.width * 0.47, y: size.height * 0.47)
        return ZStack {
            Text("DRAFT")
                .font(.system(size: min(92, size.width * 0.075), weight: .black, design: .rounded))
                .tracking(10)
                .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.035))
                .rotationEffect(.degrees(-9))
                .allowsHitTesting(false)

            Canvas { context, _ in
                for node in intention.restrictionNodes {
                    drawDraftConnection(
                        from: center,
                        to: draftPoint(node.position, center: center),
                        context: &context
                    )
                }
                for node in intention.frictionNodes {
                    drawDraftConnection(
                        from: center,
                        to: draftPoint(node.position, center: center),
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
                .position(draftPoint(node.position, center: center))
            }

            ForEach(intention.frictionNodes) { node in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = .friction(node.id) }
                } label: {
                    FrictionNodeView(node: node, selected: selection == .friction(node.id))
                }
                .buttonStyle(.plain)
                .position(draftPoint(node.position, center: center))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 52)
        .padding(.bottom, 78)
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
            TextField(draft == nil ? "What intention would you like to build today?" : "Describe a different intention", text: $prompt)
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
            selection = nil
            onFinalise(draft)
        } label: {
            Label("Finalise", systemImage: "cursorarrow.click.2")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(GraphTheme.editBlue)
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
        generate(value)
    }

    private func generatePendingRequest() {
        guard let request, handledRequestID != request.id else { return }
        handledRequestID = request.id
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
                    installedApps: installedApps
                ).validated(against: installedApps)
                guard let suggestion = plan.intentions.first else {
                    throw IntentAIError.invalidResponse
                }
                let intention = Self.makeDraft(from: suggestion, apps: installedApps)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.24)) { draft = intention }
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
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

    private func draftPoint(_ point: GraphPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + point.x, y: center.y + point.y)
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
