import AppKit
import SwiftUI
import IntentCore

struct IntentGraphView: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("intentAppearance") private var appearance = "dark"
    @AppStorage("intentWelcomeTitle") private var welcomeTitle = "Welcome to my desktop"
    @AppStorage("intentBackgroundSelection") private var backgroundSelection = IntentBackgroundChoice.none.rawValue
    @AppStorage("intentDidCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var editMode = false
    @State private var selection: GraphSelection?
    @State private var cameraScale: CGFloat = 1
    @State private var cameraOffset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero
    @State private var hoverLocation: CGPoint?
    @State private var statusMessage: String?
    @State private var welcomeTitleDraft = ""
    @State private var editingWelcomeTitle = false
    @State private var showSettings = false
    @State private var aiPrompt = ""
    @State private var aiWorkspaceRequest: AIWorkspaceRequest?
    @State private var pendingPlacementID: String?
    @State private var showQuickGuide = false
    @State private var backgroundRevision = 0
    @State private var overlayShortcut = OverlayShortcutStore.load()
    @State private var currentPage: OverlayPage = .desktop
    @State private var pagePosition: CGFloat = OverlayPage.desktop.position
    @State private var warningShakeCount: CGFloat = 0
    @FocusState private var welcomeTitleFocused: Bool
    @FocusState private var aiPromptFocused: Bool

    private let minimumScale: CGFloat = 0.35
    private let maximumScale: CGFloat = 2.35

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = CGSize(
                width: max(1, proxy.size.width - 36),
                height: max(1, proxy.size.height - 36)
            )

            ZStack {
                AdaptiveBackdropView()
                    .ignoresSafeArea()

                BackgroundArtworkView(
                    selection: IntentBackgroundChoice(rawValue: backgroundSelection) ?? .none,
                    revision: backgroundRevision
                )
                .frame(width: viewportSize.width, height: viewportSize.height)
                .clipped()
                .ignoresSafeArea()

                GraphTheme.background(colorScheme)
                    .opacity(GraphTheme.backdropTintOpacity(colorScheme))
                    .ignoresSafeArea()

                StarfieldView(scale: cameraScale, offset: cameraOffset)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    AIIntentionWorkspaceView(
                        catalog: model.installedApps,
                        request: aiWorkspaceRequest,
                        onFinalise: { draft in
                            finaliseAIDraft(draft, viewportSize: viewportSize)
                        }
                    )
                    .frame(width: viewportSize.width, height: viewportSize.height)

                    desktopPage(in: viewportSize)
                        .frame(width: viewportSize.width, height: viewportSize.height)

                    IntentSchedulerView()
                        .environmentObject(model)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                }
                .frame(width: viewportSize.width, height: viewportSize.height, alignment: .leading)
                .offset(x: -pagePosition * viewportSize.width)

                topBar(in: viewportSize)
                    .frame(maxHeight: .infinity, alignment: .top)

                bottomControls(in: viewportSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(50)

                if currentPage == .desktop {
                    aiPromptBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(51)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(GraphTheme.glassTint(colorScheme), in: Capsule())
                        .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme)))
                        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 8, y: 4)
                        .padding(.bottom, 82)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                if let warning = model.sessionSwitchWarning {
                    sessionSwitchWarningBanner(warning)
                        .padding(.top, 72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                GraphInputMonitor(
                    keyboardHandler: { key in
                        handleKeyboard(key, viewportSize: viewportSize)
                    },
                    magnificationHandler: { magnification in
                        applyTrackpadMagnification(magnification, viewportSize: viewportSize)
                    },
                    scrollHandler: { delta in
                        applyTrackpadPan(delta)
                    },
                    pageSwipeHandler: { event in
                        handlePageSwipe(event, viewportWidth: viewportSize.width)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                if showQuickGuide {
                    Color.black.opacity(0.34)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    IntentQuickGuideView {
                        didCompleteOnboarding = true
                        showQuickGuide = false
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .coordinateSpace(name: "graphViewport")
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(GraphTheme.stroke(colorScheme), lineWidth: 1)
                    if editMode {
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(GraphTheme.editBlue.opacity(0.88), lineWidth: 2.5)
                    }
                }
            )
            .shadow(
                color: editMode ? GraphTheme.editBlue.opacity(0.52) : Color.black.opacity(0.34),
                radius: editMode ? 18 : 12
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    if currentPage == .desktop, let pendingPlacementID {
                        model.moveIntentionGroup(
                            id: pendingPlacementID,
                            to: worldPoint(for: location, in: viewportSize),
                            persist: false
                        )
                    }
                case .ended: break
                }
            }
            .padding(18)
            .modifier(ShakeEffect(shakes: warningShakeCount))
            .onAppear {
                pagePosition = currentPage.position
                if !didCompleteOnboarding {
                    showQuickGuide = true
                }
            }
            .onChange(of: currentPage) { page in
                if page != .desktop {
                    leaveEditMode()
                }
                showSettings = false
            }
            .onChange(of: model.sessionSwitchWarning?.id) { warningID in
                guard let warningID else { return }
                withAnimation(.linear(duration: 0.54)) {
                    warningShakeCount += 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                    guard model.sessionSwitchWarning?.id == warningID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.sessionSwitchWarning = nil
                    }
                }
            }
        }
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .sheet(item: $model.pendingFriction) { pending in
            FrictionSheet(pending: pending)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .alert("Intent", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.activeSessionName) { activeSessionName in
            if activeSessionName != nil {
                leaveEditMode()
            }
        }
    }

    private func desktopPage(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture {
                    if commitPendingPlacement() { return }
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    finishEditingSelection()
                }

            connectionLayer(in: size)
                .allowsHitTesting(false)

            welcomeView
                .scaleEffect(cameraScale)
                .position(screenPoint(for: .zero, in: size))

            graphNodes(in: size)

            if editMode, let selection {
                editor(for: selection, in: size)
                    .zIndex(40)
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 6) {
            Text("ONE DESKTOP")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(GraphTheme.muted(colorScheme))
            Group {
                if editingWelcomeTitle {
                    TextField("Desktop title", text: $welcomeTitleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 29, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .focused($welcomeTitleFocused)
                        .onSubmit(commitWelcomeTitle)
                        .onChange(of: welcomeTitleFocused) { focused in
                            if !focused, editingWelcomeTitle {
                                commitWelcomeTitle()
                            }
                        }
                } else {
                    Text(welcomeTitle)
                        .font(.system(size: 29, weight: .semibold))
                        .onTapGesture(count: 2) {
                            if editMode {
                                beginEditingWelcomeTitle()
                            }
                        }
                        .help(editMode ? "Double-click to rename this desktop" : "Press E to edit")
                }
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .frame(width: 370, height: 38)
            Text("Choose one thing. Let everything else wait.")
                .font(.system(size: 12))
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .frame(width: 390)
    }

    private func beginEditingWelcomeTitle() {
        guard editMode else { return }
        welcomeTitleDraft = welcomeTitle
        editingWelcomeTitle = true
        DispatchQueue.main.async {
            welcomeTitleFocused = true
        }
    }

    private func commitWelcomeTitle() {
        let trimmedTitle = welcomeTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            welcomeTitle = trimmedTitle
        }
        editingWelcomeTitle = false
        welcomeTitleFocused = false
    }

    private func topBar(in viewportSize: CGSize) -> some View {
        ZStack {
            HStack(spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .medium))
                    Text("Intent")
                        .font(.system(size: 16, weight: .semibold))
                }

                Spacer()

                Button {
                    model.hideOverlay()
                } label: {
                    HStack(spacing: 7) {
                        Text(overlayShortcut.displayName)
                            .foregroundStyle(GraphTheme.text(colorScheme))
                        Text("hide")
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Intent (\(overlayShortcut.displayName))")

                if let activeSessionName = model.activeSessionName {
                    Button {
                        model.endActiveSession()
                    } label: {
                        Label("End \(activeSessionName)", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("End intention (Cmd+Shift+M)")
                }
            }

            HStack(spacing: 10) {
                pageSwitcher
                if currentPage == .desktop {
                    creationDock(in: viewportSize)
                }
            }
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.ultraThinMaterial)
        .background(GraphTheme.chrome(colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(GraphTheme.stroke(colorScheme)).frame(height: 1)
        }
    }

    private func creationDock(in viewportSize: CGSize) -> some View {
        HStack(spacing: 2) {
            creationDockButton(
                title: "Intention",
                key: "I",
                symbol: "square.roundedrectangle",
                action: .intention,
                viewportSize: viewportSize
            )
            creationDockButton(
                title: "Restriction",
                key: "R",
                symbol: "circle",
                action: .restriction,
                viewportSize: viewportSize
            )
            creationDockButton(
                title: "Friction",
                key: "F",
                symbol: "triangle",
                action: .friction,
                viewportSize: viewportSize
            )
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .background(GraphTheme.surface(colorScheme), in: Capsule())
        .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.8))
        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 7, y: 3)
    }

    private func creationDockButton(
        title: String,
        key: String,
        symbol: String,
        action: GraphKeyboardKey,
        viewportSize: CGSize
    ) -> some View {
        Button {
            performCreationAction(action, viewportSize: viewportSize)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Text(key)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .frame(width: 16, height: 16)
                    .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.7))
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Create \(title.lowercased()) (\(key))")
    }

    private var pageSwitcher: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                pageButton(.ai, icon: "sparkles")
                pageButton(.desktop, icon: "circle.hexagongrid")
                pageButton(.scheduler, icon: "calendar")
            }
            .padding(3)
            .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(GraphTheme.stroke(colorScheme)))

            if editMode {
                HStack(spacing: 7) {
                    Circle().fill(GraphTheme.editBlue).frame(width: 6, height: 6)
                    Text("EDIT MODE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                }
                .foregroundStyle(GraphTheme.editBlue)
            } else if let activeSessionName = model.activeSessionName {
                HStack(spacing: 7) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(activeSessionName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let endsAt = model.activeSessionEndsAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(sessionTimeRemaining(until: endsAt, now: context.date))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(GraphTheme.muted(colorScheme))
                        }
                    }
                }
                .frame(maxWidth: 180)
            } else {
                Text(currentPage == .desktop ? "Press E to edit" : "Three fingers to move")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        }
    }

    private func sessionTimeRemaining(until date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    private func pageButton(_ page: OverlayPage, icon: String) -> some View {
        Button {
            switchPage(to: page)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 26)
                .background(
                    currentPage == page ? GraphTheme.elevatedSurface(colorScheme) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help(page.helpText)
    }

    @ViewBuilder
    private func graphNodes(in size: CGSize) -> some View {
        ForEach(model.intentions) { intention in
            DraggableGraphNode(
                position: intention.graphPosition,
                screenPosition: screenPoint(for: intention.graphPosition, in: size),
                scale: cameraScale,
                enabled: editMode && !model.hasActiveSession,
                onTap: {
                    if pendingPlacementID == intention.id {
                        _ = commitPendingPlacement()
                        return
                    }
                    if editMode {
                        select(.intention(intention.id))
                        model.selectedID = intention.id
                    } else {
                        model.requestStart(intention)
                    }
                },
                onMove: { position, persist in
                    model.moveIntention(id: intention.id, to: position, persist: persist)
                }
            ) {
                IntentionNodeView(
                    intention: intention,
                    installedApps: model.installedApps,
                    selected: selection == .intention(intention.id),
                    cooldownExpiresAt: model.cooldownExpirations[intention.id]
                )
            }

            ForEach(intention.restrictionNodes) { node in
                DraggableGraphNode(
                    position: node.position,
                    screenPosition: screenPoint(for: node.position, in: size),
                    scale: cameraScale,
                    enabled: editMode && !model.hasActiveSession,
                    onTap: {
                        guard editMode else { return }
                        select(.restriction(intentionID: intention.id, nodeID: node.id))
                        model.selectedID = intention.id
                    },
                    onMove: { position, persist in
                        model.moveRestriction(intentionID: intention.id, nodeID: node.id, to: position, persist: persist)
                    }
                ) {
                    RestrictionNodeView(
                        node: node,
                        selected: selection == .restriction(intentionID: intention.id, nodeID: node.id)
                    )
                }
            }

            ForEach(intention.frictionNodes) { node in
                DraggableGraphNode(
                    position: node.position,
                    screenPosition: screenPoint(for: node.position, in: size),
                    scale: cameraScale,
                    enabled: editMode && !model.hasActiveSession,
                    onTap: {
                        guard editMode else { return }
                        select(.friction(intentionID: intention.id, nodeID: node.id))
                        model.selectedID = intention.id
                    },
                    onMove: { position, persist in
                        model.moveFriction(intentionID: intention.id, nodeID: node.id, to: position, persist: persist)
                    }
                ) {
                    FrictionNodeView(
                        node: node,
                        selected: selection == .friction(intentionID: intention.id, nodeID: node.id)
                    )
                }
            }
        }
    }

    private func connectionLayer(in size: CGSize) -> some View {
        Canvas { context, _ in
            for intention in model.intentions {
                let start = screenPoint(for: intention.graphPosition, in: size)
                for restriction in intention.restrictionNodes {
                    drawConnection(
                        from: start,
                        to: screenPoint(for: restriction.position, in: size),
                        context: &context
                    )
                }
                for friction in intention.frictionNodes {
                    drawConnection(
                        from: start,
                        to: screenPoint(for: friction.position, in: size),
                        context: &context
                    )
                }
            }
        }
    }

    private func drawConnection(
        from start: CGPoint,
        to end: CGPoint,
        context: inout GraphicsContext
    ) {
        let distance = abs(end.x - start.x)
        let bend = max(45, distance * 0.38)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + (end.x >= start.x ? bend : -bend), y: start.y),
            control2: CGPoint(x: end.x - (end.x >= start.x ? bend : -bend), y: end.y)
        )
        context.stroke(path, with: .color(GraphTheme.connection(colorScheme).opacity(0.30)), lineWidth: 3.4)
        context.stroke(path, with: .color(GraphTheme.connection(colorScheme)), lineWidth: 1.05)
    }

    @ViewBuilder
    private func editor(for selection: GraphSelection, in size: CGSize) -> some View {
        let anchor = editorPosition(for: selection, in: size)
        switch selection {
        case .intention(let intentionID):
            if model.intentions.contains(where: { $0.id == intentionID }) {
                IntentionEditorMenu(
                    intention: intentionBinding(id: intentionID),
                    catalog: model.installedApps,
                    onDelete: {
                        model.deleteIntention(id: intentionID)
                        self.selection = nil
                    },
                    onAddRestriction: {
                        guard intentionHasName(intentionID) else {
                            showStatus("Name the intention first")
                            return
                        }
                        let position = quickAddPosition(for: intentionID, kind: .restriction)
                        if let nodeID = model.addRestriction(to: intentionID, at: position) {
                            self.selection = .restriction(intentionID: intentionID, nodeID: nodeID)
                        }
                    },
                    onAddFriction: {
                        guard intentionHasName(intentionID) else {
                            showStatus("Name the intention first")
                            return
                        }
                        let position = quickAddPosition(for: intentionID, kind: .friction)
                        if let nodeID = model.addFriction(to: intentionID, at: position) {
                            self.selection = .friction(intentionID: intentionID, nodeID: nodeID)
                        }
                    },
                    onSave: finishEditingSelection
                )
                .position(anchor)
            }
        case .restriction(let intentionID, let nodeID):
            if let intention = model.intentions.first(where: { $0.id == intentionID }),
               intention.restrictionNodes.contains(where: { $0.id == nodeID }) {
                RestrictionEditorMenu(
                    node: restrictionBinding(intentionID: intentionID, nodeID: nodeID),
                    intention: intention,
                    onDelete: {
                        model.mutateIntention(id: intentionID) {
                            $0.restrictionNodes.removeAll { $0.id == nodeID }
                        }
                        self.selection = nil
                    },
                    onSave: { self.selection = nil }
                )
                .position(anchor)
            }
        case .friction(let intentionID, let nodeID):
            if let intention = model.intentions.first(where: { $0.id == intentionID }),
               intention.frictionNodes.contains(where: { $0.id == nodeID }) {
                FrictionEditorMenu(
                    node: frictionBinding(intentionID: intentionID, nodeID: nodeID),
                    onDelete: {
                        model.mutateIntention(id: intentionID) {
                            $0.frictionNodes.removeAll { $0.id == nodeID }
                        }
                        self.selection = nil
                    },
                    onSave: { self.selection = nil }
                )
                .position(anchor)
            }
        }
    }

    private func zoomControls(in size: CGSize) -> some View {
        HStack(spacing: 4) {
            Button {
                setScale(cameraScale / 1.18)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom out")

            Button {
                fitGraph(in: size)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit all intentions")

            Text("\(Int(cameraScale * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 42)
                .foregroundStyle(GraphTheme.muted(colorScheme))

            Button {
                setScale(cameraScale * 1.18)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom in")
        }
        .buttonStyle(.plain)
        .padding(10)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 12)
    }

    private func bottomControls(in size: CGSize) -> some View {
        VStack(alignment: .trailing, spacing: 9) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                IntentSettingsView(
                    appearance: $appearance,
                    backgroundSelection: $backgroundSelection,
                    requireManualFinishBeforeSwitching: $model.requireManualFinishBeforeSwitching,
                    overlayShortcut: $overlayShortcut,
                    onBackgroundChanged: { backgroundRevision += 1 },
                    onShowGuide: {
                        showSettings = false
                        showQuickGuide = true
                    }
                )
            }

            if currentPage == .desktop {
                zoomControls(in: size)
            }
        }
        .padding(18)
    }

    private var aiPromptBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GraphTheme.muted(colorScheme))

            TextField("What intention would you like to build today?", text: $aiPrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($aiPromptFocused)
                .onSubmit(submitAIPrompt)

            Button(action: submitAIPrompt) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(width: 28, height: 28)
                    .background(
                        aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? GraphTheme.muted(colorScheme).opacity(0.35)
                            : GraphTheme.text(colorScheme),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Build with Intent AI")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(maxWidth: 560)
        .frame(height: 48)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 24)
        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 16, y: 8)
        .padding(.horizontal, 96)
        .padding(.bottom, 18)
        .disabled(showQuickGuide)
    }

    private func submitAIPrompt() {
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !model.hasActiveSession else {
            showStatus("Finish the active intention before building with AI")
            return
        }
        aiPrompt = ""
        aiPromptFocused = false
        aiWorkspaceRequest = AIWorkspaceRequest(prompt: prompt)
        switchPage(to: .ai)
    }

    private func finaliseAIDraft(_ draft: Intention, viewportSize: CGSize) {
        guard !model.hasActiveSession else {
            showStatus("Finish the active intention before adding this draft")
            return
        }
        let placement = pointerWorldPoint(in: viewportSize)
        guard let id = model.addDraftIntention(draft, at: placement) else {
            showStatus("Name the intention and choose at least one app")
            return
        }

        pendingPlacementID = id
        selection = nil
        model.selectedID = nil
        editMode = true
        switchPage(to: .desktop)
        showStatus("Move the draft, then click to place it")
    }

    @discardableResult
    private func commitPendingPlacement() -> Bool {
        guard let id = pendingPlacementID,
              let intention = model.intentions.first(where: { $0.id == id }) else {
            return false
        }
        model.moveIntentionGroup(id: id, to: intention.graphPosition, persist: true)
        pendingPlacementID = nil
        selection = nil
        model.selectedID = nil
        editMode = false
        showStatus("Intention added")
        return true
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graphViewport"))
            .onChanged { value in
                cameraOffset = CGSize(
                    width: offsetAtGestureStart.width + value.translation.width,
                    height: offsetAtGestureStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                offsetAtGestureStart = cameraOffset
            }
    }

    private func handleKeyboard(_ key: GraphKeyboardKey, viewportSize: CGSize) {
        if showQuickGuide {
            if key == .escape {
                didCompleteOnboarding = true
                showQuickGuide = false
            }
            return
        }

        if showSettings {
            if key == .escape {
                showSettings = false
            }
            return
        }

        switch key {
        case .edit:
            guard !model.hasActiveSession else {
                showStatus("Finish the active intention before editing")
                return
            }
            if currentPage != .desktop {
                switchPage(to: .desktop)
            }
            editMode ? leaveEditMode() : enterEditMode()
        case .escape:
            if editMode {
                leaveEditMode()
            } else {
                model.hideOverlay()
            }
        case .intention:
            guard currentPage == .desktop, editMode else { return }
            finishEditingSelection()
            let id = model.createIntention(at: pointerWorldPoint(in: viewportSize))
            selection = .intention(id)
        case .restriction:
            guard currentPage == .desktop, editMode else { return }
            guard let intentionID = selection?.intentionID else {
                showStatus("Select an intention first")
                return
            }
            guard intentionHasName(intentionID) else {
                showStatus("Name the intention first")
                return
            }
            if let id = model.addRestriction(to: intentionID, at: pointerWorldPoint(in: viewportSize)) {
                selection = .restriction(intentionID: intentionID, nodeID: id)
            }
        case .friction:
            guard currentPage == .desktop, editMode else { return }
            guard let intentionID = selection?.intentionID else {
                showStatus("Select an intention first")
                return
            }
            guard intentionHasName(intentionID) else {
                showStatus("Name the intention first")
                return
            }
            if let id = model.addFriction(to: intentionID, at: pointerWorldPoint(in: viewportSize)) {
                selection = .friction(intentionID: intentionID, nodeID: id)
            }
        case .save:
            guard editMode else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
            finishEditingSelection()
        case .delete:
            guard editMode else { return }
            deleteSelection()
        case .undo:
            guard editMode else { return }
            model.undoLastChange()
            selection = nil
        case .pageLeft:
            switchPage(to: currentPage.previous)
        case .pageRight:
            switchPage(to: currentPage.next)
        }
    }

    private func performCreationAction(_ key: GraphKeyboardKey, viewportSize: CGSize) {
        guard !model.hasActiveSession else {
            showStatus("Finish the active intention before editing")
            return
        }
        if currentPage != .desktop {
            switchPage(to: .desktop)
        }
        if !editMode {
            enterEditMode()
        }
        if key == .intention {
            finishEditingSelection()
            let placement = worldPoint(
                for: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2 + 132),
                in: viewportSize
            )
            let id = model.createIntention(at: placement)
            selection = .intention(id)
            return
        }
        if key != .intention,
           selection?.intentionID == nil,
           let selectedID = model.selectedID,
           model.intentions.contains(where: { $0.id == selectedID }) {
            selection = .intention(selectedID)
        }
        guard let intentionID = selection?.intentionID else {
            showStatus("Select an intention first")
            return
        }
        guard intentionHasName(intentionID) else {
            showStatus("Name the intention first")
            return
        }
        switch key {
        case .restriction:
            let position = quickAddPosition(for: intentionID, kind: .restriction)
            if let nodeID = model.addRestriction(to: intentionID, at: position) {
                selection = .restriction(intentionID: intentionID, nodeID: nodeID)
            }
        case .friction:
            let position = quickAddPosition(for: intentionID, kind: .friction)
            if let nodeID = model.addFriction(to: intentionID, at: position) {
                selection = .friction(intentionID: intentionID, nodeID: nodeID)
            }
        default:
            handleKeyboard(key, viewportSize: viewportSize)
        }
    }

    private func handlePageSwipe(_ event: PageSwipeEvent, viewportWidth: CGFloat) {
        guard !showQuickGuide, viewportWidth > 0 else { return }
        let origin = currentPage.position

        switch event {
        case .changed(let translationX):
            pagePosition = min(max(origin - (translationX / viewportWidth), OverlayPage.minimumPosition), OverlayPage.maximumPosition)
        case .ended(let translationX, let velocityX):
            let crossedDistance = abs(translationX) >= viewportWidth * 0.18
            let crossedVelocity = abs(velocityX) >= 520
            let target = if crossedDistance || crossedVelocity {
                translationX < 0 ? currentPage.next : currentPage.previous
            } else {
                currentPage
            }
            settlePageSwipe(on: target)
        case .cancelled:
            settlePageSwipe(on: currentPage)
        }
    }

    private func settlePageSwipe(on page: OverlayPage) {
        if page != .desktop {
            leaveEditMode()
        }
        currentPage = page
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.9)) {
            pagePosition = page.position
        }
    }

    private func switchPage(to page: OverlayPage) {
        guard currentPage != page || pagePosition != page.position else { return }
        settlePageSwipe(on: page)
    }

    private func sessionSwitchWarningBanner(_ warning: SessionSwitchWarning) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(warning.message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 15)
        .frame(minHeight: 46)
        .background(Color.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2)))
        .shadow(color: Color.red.opacity(0.28), radius: 14, y: 6)
        .frame(maxWidth: 640)
        .padding(.horizontal, 26)
    }

    private func deleteSelection() {
        guard let selection else { return }
        switch selection {
        case .intention(let intentionID):
            model.deleteIntention(id: intentionID)
        case .restriction(let intentionID, let nodeID):
            model.mutateIntention(id: intentionID) {
                $0.restrictionNodes.removeAll { $0.id == nodeID }
            }
        case .friction(let intentionID, let nodeID):
            model.mutateIntention(id: intentionID) {
                $0.frictionNodes.removeAll { $0.id == nodeID }
            }
        }
        self.selection = nil
    }

    private func quickAddPosition(for intentionID: String, kind: QuickAddKind) -> GraphPoint {
        guard let intention = model.intentions.first(where: { $0.id == intentionID }) else {
            return .zero
        }

        let existingCount: Int
        let direction: Double
        switch kind {
        case .restriction:
            existingCount = intention.restrictionNodes.count
            direction = -1
        case .friction:
            existingCount = intention.frictionNodes.count
            direction = 1
        }

        return GraphPoint(
            x: intention.graphPosition.x + direction * 250,
            y: intention.graphPosition.y + Double(existingCount) * 145 - 45
        )
    }

    private func enterEditMode() {
        editMode = true
    }

    private func leaveEditMode() {
        if editingWelcomeTitle {
            commitWelcomeTitle()
        }
        finishEditingSelection()
        editMode = false
    }

    private func select(_ newSelection: GraphSelection) {
        if selection?.intentionID != newSelection.intentionID {
            discardSelectedIntentionIfUnnamed()
        }
        selection = newSelection
    }

    private func finishEditingSelection() {
        discardSelectedIntentionIfUnnamed()
        selection = nil
    }

    private func discardSelectedIntentionIfUnnamed() {
        guard let intentionID = selection?.intentionID else { return }
        model.discardIfUnnamed(id: intentionID)
    }

    private func intentionHasName(_ intentionID: String) -> Bool {
        guard let intention = model.intentions.first(where: { $0.id == intentionID }) else { return false }
        return !intention.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if statusMessage == message {
                statusMessage = nil
            }
        }
    }

    private func screenPoint(for point: GraphPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + cameraOffset.width + CGFloat(point.x) * cameraScale,
            y: size.height / 2 + cameraOffset.height + CGFloat(point.y) * cameraScale
        )
    }

    private func worldPoint(for point: CGPoint, in size: CGSize) -> GraphPoint {
        GraphPoint(
            x: Double((point.x - size.width / 2 - cameraOffset.width) / cameraScale),
            y: Double((point.y - size.height / 2 - cameraOffset.height) / cameraScale)
        )
    }

    private func pointerWorldPoint(in size: CGSize) -> GraphPoint {
        worldPoint(for: hoverLocation ?? CGPoint(x: size.width / 2, y: size.height / 2), in: size)
    }

    private func setScale(_ scale: CGFloat) {
        cameraScale = clampedScale(scale)
    }

    private func applyTrackpadMagnification(_ magnification: CGFloat, viewportSize size: CGSize) {
        guard magnification.isFinite, magnification != 0 else { return }

        let oldScale = cameraScale
        let newScale = clampedScale(oldScale * exp(magnification * 1.35))
        guard newScale != oldScale else { return }

        let anchor = hoverLocation ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let worldX = (anchor.x - size.width / 2 - cameraOffset.width) / oldScale
        let worldY = (anchor.y - size.height / 2 - cameraOffset.height) / oldScale

        cameraOffset = CGSize(
            width: anchor.x - size.width / 2 - worldX * newScale,
            height: anchor.y - size.height / 2 - worldY * newScale
        )
        offsetAtGestureStart = cameraOffset
        cameraScale = newScale
    }

    private func applyTrackpadPan(_ delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        cameraOffset.width += delta.width
        cameraOffset.height += delta.height
        offsetAtGestureStart = cameraOffset
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    private func fitGraph(in size: CGSize) {
        let points = model.intentions.flatMap { intention in
            [intention.graphPosition]
                + intention.restrictionNodes.map(\.position)
                + intention.frictionNodes.map(\.position)
        }
        guard !points.isEmpty else {
            setScale(1)
            cameraOffset = .zero
            offsetAtGestureStart = .zero
            return
        }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let worldWidth = max(420, maxX - minX + 360)
        let worldHeight = max(320, maxY - minY + 300)
        let fitted = min((size.width - 80) / CGFloat(worldWidth), (size.height - 100) / CGFloat(worldHeight))
        setScale(min(1.25, fitted))
        let centerX = CGFloat((minX + maxX) / 2)
        let centerY = CGFloat((minY + maxY) / 2)
        cameraOffset = CGSize(width: -centerX * cameraScale, height: -centerY * cameraScale + 20)
        offsetAtGestureStart = cameraOffset
    }

    private func editorPosition(for selection: GraphSelection, in size: CGSize) -> CGPoint {
        let point = selectionWorldPoint(selection) ?? .zero
        let nodePoint = screenPoint(for: point, in: size)
        let placeRight = nodePoint.x < size.width * 0.62
        let proposed = CGPoint(
            x: nodePoint.x + (placeRight ? 250 : -250),
            y: nodePoint.y
        )
        return clampedMenuPoint(proposed, menuSize: .init(width: 350, height: 490), in: size)
    }

    private func clampedMenuPoint(_ point: CGPoint, menuSize: CGSize, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(size.width - menuSize.width / 2 - 18, max(menuSize.width / 2 + 18, point.x)),
            y: min(size.height - menuSize.height / 2 - 18, max(menuSize.height / 2 + 58, point.y))
        )
    }

    private func selectionWorldPoint(_ selection: GraphSelection) -> GraphPoint? {
        switch selection {
        case .intention(let id):
            return model.intentions.first(where: { $0.id == id })?.graphPosition
        case .restriction(let intentionID, let nodeID):
            return model.intentions.first(where: { $0.id == intentionID })?
                .restrictionNodes.first(where: { $0.id == nodeID })?.position
        case .friction(let intentionID, let nodeID):
            return model.intentions.first(where: { $0.id == intentionID })?
                .frictionNodes.first(where: { $0.id == nodeID })?.position
        }
    }

    private func intentionBinding(id: String) -> Binding<Intention> {
        Binding(
            get: {
                model.intentions.first(where: { $0.id == id }) ?? Intention(
                    name: "",
                    icon: "target",
                    colorHex: "#F5F5F7",
                    folder: "",
                    allowedApps: [],
                    allowedWebsites: [],
                    startupActions: [],
                    restrictions: .init()
                )
            },
            set: { model.updateIntention($0) }
        )
    }

    private func restrictionBinding(intentionID: String, nodeID: String) -> Binding<RestrictionNode> {
        Binding(
            get: {
                model.intentions.first(where: { $0.id == intentionID })?
                    .restrictionNodes.first(where: { $0.id == nodeID })
                    ?? RestrictionNode(kind: .allowBrowserSearches, position: .zero)
            },
            set: { updated in
                model.mutateIntention(id: intentionID) { intention in
                    guard let index = intention.restrictionNodes.firstIndex(where: { $0.id == nodeID }) else { return }
                    intention.restrictionNodes[index] = updated
                }
            }
        )
    }

    private func frictionBinding(intentionID: String, nodeID: String) -> Binding<FrictionNode> {
        Binding(
            get: {
                model.intentions.first(where: { $0.id == intentionID })?
                    .frictionNodes.first(where: { $0.id == nodeID })
                    ?? FrictionNode(friction: .typedPhrase(""), position: .zero)
            },
            set: { updated in
                model.mutateIntention(id: intentionID) { intention in
                    guard let index = intention.frictionNodes.firstIndex(where: { $0.id == nodeID }) else { return }
                    intention.frictionNodes[index] = updated
                }
            }
        )
    }
}

private struct StarfieldView: View {
    let scale: CGFloat
    let offset: CGSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let spacing = max(25, 54 * scale)
            let centerX = size.width / 2 + offset.width
            let centerY = size.height / 2 + offset.height
            let startX = centerX.truncatingRemainder(dividingBy: spacing) - spacing
            let startY = centerY.truncatingRemainder(dividingBy: spacing) - spacing
            let color = GraphTheme.text(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.11)

            var x = startX
            while x < size.width + spacing {
                var y = startY
                while y < size.height + spacing {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
    }
}

private struct DraggableGraphNode<Content: View>: View {
    let position: GraphPoint
    let screenPosition: CGPoint
    let scale: CGFloat
    let enabled: Bool
    let onTap: () -> Void
    let onMove: (GraphPoint, Bool) -> Void
    @ViewBuilder let content: Content

    @State private var dragOrigin: GraphPoint?

    var body: some View {
        content
            .scaleEffect(scale)
            .position(screenPosition)
            .onTapGesture(perform: onTap)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("graphViewport"))
                    .onChanged { value in
                        guard enabled else { return }
                        let origin = dragOrigin ?? position
                        if dragOrigin == nil { dragOrigin = position }
                        onMove(
                            GraphPoint(
                                x: origin.x + Double(value.translation.width / scale),
                                y: origin.y + Double(value.translation.height / scale)
                            ),
                            false
                        )
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        let origin = dragOrigin ?? position
                        onMove(
                            GraphPoint(
                                x: origin.x + Double(value.translation.width / scale),
                                y: origin.y + Double(value.translation.height / scale)
                            ),
                            true
                        )
                        dragOrigin = nil
                    }
            )
    }
}

private enum GraphSelection: Equatable {
    case intention(String)
    case restriction(intentionID: String, nodeID: String)
    case friction(intentionID: String, nodeID: String)

    var intentionID: String {
        switch self {
        case .intention(let id): id
        case .restriction(let intentionID, _), .friction(let intentionID, _): intentionID
        }
    }
}

private enum GraphKeyboardKey {
    case edit
    case escape
    case intention
    case restriction
    case friction
    case save
    case delete
    case undo
    case pageLeft
    case pageRight
}

private enum QuickAddKind {
    case restriction
    case friction
}

private enum OverlayPage: CaseIterable {
    case ai
    case desktop
    case scheduler

    var position: CGFloat {
        switch self {
        case .ai: 0
        case .desktop: 1
        case .scheduler: 2
        }
    }

    var previous: OverlayPage {
        switch self {
        case .ai: .ai
        case .desktop: .ai
        case .scheduler: .desktop
        }
    }

    var next: OverlayPage {
        switch self {
        case .ai: .desktop
        case .desktop: .scheduler
        case .scheduler: .scheduler
        }
    }

    var helpText: String {
        switch self {
        case .ai: "Draft with Intent AI"
        case .desktop: "Intentions desktop"
        case .scheduler: "Scheduler"
        }
    }

    static let minimumPosition = OverlayPage.ai.position
    static let maximumPosition = OverlayPage.scheduler.position
}

private enum PageSwipeEvent {
    case changed(translationX: CGFloat)
    case ended(translationX: CGFloat, velocityX: CGFloat)
    case cancelled
}

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: 9 * sin(shakes * .pi * 2 * 3),
                y: 0
            )
        )
    }
}

private struct GraphInputMonitor: NSViewRepresentable {
    let keyboardHandler: (GraphKeyboardKey) -> Void
    let magnificationHandler: (CGFloat) -> Void
    let scrollHandler: (CGSize) -> Void
    let pageSwipeHandler: (PageSwipeEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.keyboardHandler = keyboardHandler
        view.magnificationHandler = magnificationHandler
        view.scrollHandler = scrollHandler
        view.pageSwipeHandler = pageSwipeHandler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.keyboardHandler = keyboardHandler
        nsView.magnificationHandler = magnificationHandler
        nsView.scrollHandler = scrollHandler
        nsView.pageSwipeHandler = pageSwipeHandler
    }

    final class MonitorView: NSView, NSGestureRecognizerDelegate {
        var keyboardHandler: ((GraphKeyboardKey) -> Void)?
        var magnificationHandler: ((CGFloat) -> Void)?
        var scrollHandler: ((CGSize) -> Void)?
        var pageSwipeHandler: ((PageSwipeEvent) -> Void)?
        private var keyboardMonitor: Any?
        private var magnificationMonitor: Any?
        private var scrollMonitor: Any?
        private var inputFrameTimer: Timer?
        private var pendingMagnification: CGFloat = 0
        private var pendingPan: CGSize = .zero
        private var swipeMonitor: Any?
        private var indirectGestureMonitor: Any?
        private weak var gestureHostView: NSView?
        private var threeFingerPanRecognizer: ThreeFingerSwipeGestureRecognizer?
        private var isTrackingThreeFingerPan = false
        private var lastThreeFingerCompletionTime: TimeInterval = 0
        private var indirectGestureOrigin: CGPoint?
        private var indirectGesturePrevious: CGPoint?
        private var indirectGesturePreviousTimestamp: TimeInterval = 0
        private var indirectGestureTranslationX: CGFloat = 0
        private var indirectGestureVelocityX: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, keyboardMonitor == nil {
                installThreeFingerPanRecognizer()
                startInputFrameTimer()
                keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.window?.isKeyWindow == true else {
                        return event
                    }

                    let editingText = Self.isEditingText(in: self.window)
                    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                    if event.keyCode == 6,
                       modifiers.contains(.command),
                       !modifiers.contains(.control),
                       !modifiers.contains(.option),
                       !modifiers.contains(.shift),
                       !editingText {
                        self.keyboardHandler?(.undo)
                        return nil
                    }

                    guard modifiers.intersection([.command, .control, .option]).isEmpty else {
                        return event
                    }

                    if event.keyCode == 53 {
                        self.keyboardHandler?(.escape)
                        return nil
                    }

                    guard !editingText else { return event }

                    let key: GraphKeyboardKey?
                    switch event.keyCode {
                    case 14: key = .edit
                    case 34: key = .intention
                    case 15: key = .restriction
                    case 3: key = .friction
                    case 1: key = .save
                    case 7, 51, 117: key = .delete
                    case 123: key = .pageLeft
                    case 124: key = .pageRight
                    default: key = nil
                    }

                    guard let key else { return event }
                    self.keyboardHandler?(key)
                    return nil
                }

                magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                    guard let self,
                          self.window?.isKeyWindow == true,
                          event.window === self.window else {
                        return event
                    }
                    self.pendingMagnification += event.magnification
                    return nil
                }

                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self,
                          self.window?.isKeyWindow == true,
                          event.window === self.window,
                          event.hasPreciseScrollingDeltas,
                          !self.isTrackingThreeFingerPan else {
                        return event
                    }

                    guard !Self.isOverScrollView(event, in: self.window) else { return event }
                    self.pendingPan.width += event.scrollingDeltaX * 1.28
                    self.pendingPan.height += event.scrollingDeltaY * 1.28
                    return nil
                }

                swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
                    guard let self,
                          self.window?.isKeyWindow == true,
                          !self.isTrackingThreeFingerPan,
                          event.timestamp - self.lastThreeFingerCompletionTime > 0.25,
                          self.isPointerInsideOverlay,
                          abs(event.deltaX) > abs(event.deltaY) else {
                        return event
                    }
                    self.pageSwipeHandler?(
                        .ended(
                            translationX: event.deltaX * self.bounds.width,
                            velocityX: event.deltaX * 1_200
                        )
                    )
                    return nil
                }

                if #available(macOS 26, *) {
                    indirectGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) { [weak self] event in
                        guard let self,
                              self.window?.isKeyWindow == true,
                              event.window === self.window,
                              self.isPointerInsideOverlay else {
                            return event
                        }
                        self.handleIndirectGesture(event)
                        return event
                    }
                }
            } else if window == nil {
                removeMonitors()
            }
        }

        deinit {
            removeMonitors()
        }

        private func removeMonitors() {
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
            if let magnificationMonitor { NSEvent.removeMonitor(magnificationMonitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
            if let indirectGestureMonitor { NSEvent.removeMonitor(indirectGestureMonitor) }
            inputFrameTimer?.invalidate()
            inputFrameTimer = nil
            pendingMagnification = 0
            pendingPan = .zero
            keyboardMonitor = nil
            magnificationMonitor = nil
            scrollMonitor = nil
            swipeMonitor = nil
            indirectGestureMonitor = nil
            if let threeFingerPanRecognizer {
                gestureHostView?.removeGestureRecognizer(threeFingerPanRecognizer)
            }
            threeFingerPanRecognizer = nil
            gestureHostView = nil
            isTrackingThreeFingerPan = false
            resetIndirectGesture()
        }

        private func startInputFrameTimer() {
            guard inputFrameTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let magnification = self.pendingMagnification
                let pan = self.pendingPan
                self.pendingMagnification = 0
                self.pendingPan = .zero

                if abs(magnification) > 0.000_01 {
                    self.magnificationHandler?(magnification)
                }
                if abs(pan.width) > 0.001 || abs(pan.height) > 0.001 {
                    self.scrollHandler?(pan)
                }
            }
            inputFrameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func installThreeFingerPanRecognizer() {
            if #available(macOS 26, *) { return }
            guard threeFingerPanRecognizer == nil,
                  let hostView = window?.contentView else { return }
            let recognizer = ThreeFingerSwipeGestureRecognizer(
                target: self,
                action: #selector(handleThreeFingerPan(_:))
            )
            recognizer.allowedTouchTypes = [.indirect]
            recognizer.delegate = self
            hostView.addGestureRecognizer(recognizer)
            gestureHostView = hostView
            threeFingerPanRecognizer = recognizer
        }

        @available(macOS 26, *)
        private func handleIndirectGesture(_ event: NSEvent) {
            let touches = Array(event.touches(matching: .touching, in: self))
            let finishing = event.phase.contains(.ended) || event.phase.contains(.cancelled)

            if touches.count == 3, let centroid = centroid(of: touches) {
                if indirectGestureOrigin == nil {
                    indirectGestureOrigin = centroid
                    indirectGesturePrevious = centroid
                    indirectGesturePreviousTimestamp = event.timestamp
                    indirectGestureTranslationX = 0
                    indirectGestureVelocityX = 0
                }

                guard let origin = indirectGestureOrigin else { return }
                let translationX = (centroid.x - origin.x) * bounds.width
                let translationY = (centroid.y - origin.y) * bounds.height

                if let previous = indirectGesturePrevious {
                    let elapsed = max(1.0 / 240.0, event.timestamp - indirectGesturePreviousTimestamp)
                    indirectGestureVelocityX = ((centroid.x - previous.x) * bounds.width) / elapsed
                }
                indirectGesturePrevious = centroid
                indirectGesturePreviousTimestamp = event.timestamp
                indirectGestureTranslationX = translationX

                if abs(translationX) > 5, abs(translationX) > abs(translationY) * 1.05 {
                    isTrackingThreeFingerPan = true
                    pageSwipeHandler?(.changed(translationX: translationX))
                }
            }

            if finishing {
                finishIndirectGesture(cancelled: event.phase.contains(.cancelled))
            }
        }

        private func finishIndirectGesture(cancelled: Bool) {
            guard indirectGestureOrigin != nil else { return }
            if isTrackingThreeFingerPan {
                if cancelled {
                    pageSwipeHandler?(.cancelled)
                } else {
                    pageSwipeHandler?(
                        .ended(
                            translationX: indirectGestureTranslationX,
                            velocityX: indirectGestureVelocityX
                        )
                    )
                    lastThreeFingerCompletionTime = ProcessInfo.processInfo.systemUptime
                }
            }
            resetIndirectGesture()
        }

        private func resetIndirectGesture() {
            indirectGestureOrigin = nil
            indirectGesturePrevious = nil
            indirectGesturePreviousTimestamp = 0
            indirectGestureTranslationX = 0
            indirectGestureVelocityX = 0
            isTrackingThreeFingerPan = false
        }

        private func centroid(of touches: [NSTouch]) -> CGPoint? {
            guard !touches.isEmpty else { return nil }
            let total = touches.reduce(CGPoint.zero) { partial, touch in
                CGPoint(
                    x: partial.x + touch.normalizedPosition.x,
                    y: partial.y + touch.normalizedPosition.y
                )
            }
            return CGPoint(x: total.x / CGFloat(touches.count), y: total.y / CGFloat(touches.count))
        }

        @objc private func handleThreeFingerPan(_ recognizer: ThreeFingerSwipeGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                isTrackingThreeFingerPan = true
                pageSwipeHandler?(.changed(translationX: recognizer.translationX))
            case .ended:
                pageSwipeHandler?(
                    .ended(
                        translationX: recognizer.translationX,
                        velocityX: recognizer.velocityX
                    )
                )
                isTrackingThreeFingerPan = false
                lastThreeFingerCompletionTime = ProcessInfo.processInfo.systemUptime
            case .cancelled, .failed:
                pageSwipeHandler?(.cancelled)
                isTrackingThreeFingerPan = false
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            gestureRecognizer === threeFingerPanRecognizer && isPointerInsideOverlay
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }

        private var isPointerInsideOverlay: Bool {
            guard let window else { return false }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let localPoint = convert(windowPoint, from: nil)
            return bounds.contains(localPoint)
        }

        private static func isEditingText(in window: NSWindow?) -> Bool {
            guard let responder = window?.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField
        }

        private static func isOverScrollView(_ event: NSEvent, in window: NSWindow?) -> Bool {
            guard let view = window?.contentView?.hitTest(event.locationInWindow) else { return false }
            return sequence(first: view as NSView?, next: { $0?.superview })
                .contains { $0 is NSScrollView }
        }
    }
}

private final class ThreeFingerSwipeGestureRecognizer: NSGestureRecognizer {
    private(set) var translationX: CGFloat = 0
    private(set) var velocityX: CGFloat = 0

    private var initialCentroid: CGPoint?
    private var previousCentroid: CGPoint?
    private var previousTimestamp: TimeInterval = 0

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        let touches = activeTouches(in: event)
        guard touches.count <= 3 else {
            state = .failed
            return
        }
        guard touches.count == 3, let centroid = centroid(of: touches) else { return }
        initialCentroid = centroid
        previousCentroid = centroid
        previousTimestamp = event.timestamp
        translationX = 0
        velocityX = 0
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        let touches = activeTouches(in: event)
        guard touches.count == 3,
              let origin = initialCentroid,
              let centroid = centroid(of: touches),
              let view else {
            if state == .began || state == .changed {
                state = .cancelled
            }
            return
        }

        let translation = CGPoint(
            x: (centroid.x - origin.x) * view.bounds.width,
            y: (centroid.y - origin.y) * view.bounds.height
        )

        if let previousCentroid {
            let elapsed = max(1.0 / 240.0, event.timestamp - previousTimestamp)
            velocityX = ((centroid.x - previousCentroid.x) * view.bounds.width) / elapsed
        }
        previousCentroid = centroid
        previousTimestamp = event.timestamp
        translationX = translation.x

        if state == .possible {
            let distance = hypot(translation.x, translation.y)
            guard distance >= 6 else { return }
            guard abs(translation.x) > abs(translation.y) * 1.08 else {
                state = .failed
                return
            }
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        if state == .began || state == .changed {
            state = .ended
        } else if state == .possible {
            state = .failed
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        if state == .began || state == .changed {
            state = .cancelled
        } else {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        translationX = 0
        velocityX = 0
        initialCentroid = nil
        previousCentroid = nil
        previousTimestamp = 0
    }

    private func activeTouches(in event: NSEvent) -> [NSTouch] {
        Array(event.touches(matching: .touching, in: view))
    }

    private func centroid(of touches: [NSTouch]) -> CGPoint? {
        guard !touches.isEmpty else { return nil }
        let total = touches.reduce(CGPoint.zero) { partial, touch in
            CGPoint(
                x: partial.x + touch.normalizedPosition.x,
                y: partial.y + touch.normalizedPosition.y
            )
        }
        return CGPoint(x: total.x / CGFloat(touches.count), y: total.y / CGFloat(touches.count))
    }
}
