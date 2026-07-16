import AppKit
import SwiftUI
import IntentCore

struct IntentGraphView: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("intentAppearance") private var appearance = "dark"
    @AppStorage("intentWelcomeTitle") private var welcomeTitle = "Welcome to Intent"

    @State private var editMode = false
    @State private var selection: GraphSelection?
    @State private var cameraScale: CGFloat = 1
    @State private var cameraOffset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero
    @State private var hoverLocation: CGPoint?
    @State private var statusMessage: String?
    @State private var welcomeTitleDraft = ""
    @State private var editingWelcomeTitle = false
    @FocusState private var welcomeTitleFocused: Bool

    private let minimumScale: CGFloat = 0.35
    private let maximumScale: CGFloat = 2.35

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AdaptiveBackdropView()
                    .ignoresSafeArea()

                GraphTheme.background(colorScheme)
                    .opacity(GraphTheme.backdropTintOpacity(colorScheme))
                    .ignoresSafeArea()

                StarfieldView(scale: cameraScale, offset: cameraOffset)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        selection = nil
                    }

                connectionLayer(in: proxy.size)
                    .allowsHitTesting(false)

                welcomeView
                    .scaleEffect(cameraScale)
                    .position(screenPoint(for: .zero, in: proxy.size))

                graphNodes(in: proxy.size)

                if editMode, let selection {
                    editor(for: selection, in: proxy.size)
                }

                topBar
                    .frame(maxHeight: .infinity, alignment: .top)

                zoomControls(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(GraphTheme.glassTint(colorScheme), in: Capsule())
                        .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme)))
                        .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 8, y: 4)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

                GraphInputMonitor(
                    keyboardHandler: { key in
                        handleKeyboard(key, viewportSize: proxy.size)
                    },
                    magnificationHandler: { magnification in
                        applyTrackpadMagnification(magnification, viewportSize: proxy.size)
                    },
                    scrollHandler: { delta in
                        applyTrackpadPan(delta)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
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
                case .active(let location): hoverLocation = location
                case .ended: break
                }
            }
            .padding(18)
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

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .medium))
                Text("Intent")
                    .font(.system(size: 16, weight: .semibold))
            }

            Spacer()

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
                }
            } else {
                Text("Press E to edit")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Spacer()

            Text("~  hide")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GraphTheme.muted(colorScheme))

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
        .foregroundStyle(GraphTheme.text(colorScheme))
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.ultraThinMaterial)
        .background(GraphTheme.chrome(colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(GraphTheme.stroke(colorScheme)).frame(height: 1)
        }
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
                    if editMode {
                        selection = .intention(intention.id)
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
                    selected: selection == .intention(intention.id)
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
                        selection = .restriction(intentionID: intention.id, nodeID: node.id)
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
                        selection = .friction(intentionID: intention.id, nodeID: node.id)
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
                        let position = quickAddPosition(for: intentionID, kind: .restriction)
                        if let nodeID = model.addRestriction(to: intentionID, at: position) {
                            self.selection = .restriction(intentionID: intentionID, nodeID: nodeID)
                        }
                    },
                    onAddFriction: {
                        let position = quickAddPosition(for: intentionID, kind: .friction)
                        if let nodeID = model.addFriction(to: intentionID, at: position) {
                            self.selection = .friction(intentionID: intentionID, nodeID: nodeID)
                        }
                    },
                    onSave: { self.selection = nil }
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
        .padding(18)
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
        switch key {
        case .edit:
            guard !model.hasActiveSession else {
                showStatus("Finish the active intention before editing")
                return
            }
            editMode ? leaveEditMode() : enterEditMode()
        case .escape:
            if editMode {
                leaveEditMode()
            } else {
                model.hideOverlay()
            }
        case .intention:
            guard editMode else { return }
            let id = model.createIntention(at: pointerWorldPoint(in: viewportSize))
            selection = .intention(id)
        case .restriction:
            guard editMode else { return }
            guard let intentionID = selection?.intentionID else {
                showStatus("Select an intention first")
                return
            }
            if let id = model.addRestriction(to: intentionID, at: pointerWorldPoint(in: viewportSize)) {
                selection = .restriction(intentionID: intentionID, nodeID: id)
            }
        case .friction:
            guard editMode else { return }
            guard let intentionID = selection?.intentionID else {
                showStatus("Select an intention first")
                return
            }
            if let id = model.addFriction(to: intentionID, at: pointerWorldPoint(in: viewportSize)) {
                selection = .friction(intentionID: intentionID, nodeID: id)
            }
        case .save:
            guard editMode else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
            selection = nil
        case .delete:
            guard editMode else { return }
            deleteSelection()
        case .undo:
            guard editMode else { return }
            model.undoLastChange()
            selection = nil
        }
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
        editMode = false
        selection = nil
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
            get: { model.intentions.first(where: { $0.id == id }) ?? DefaultIntentions.make()[0] },
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
}

private enum QuickAddKind {
    case restriction
    case friction
}

private struct GraphInputMonitor: NSViewRepresentable {
    let keyboardHandler: (GraphKeyboardKey) -> Void
    let magnificationHandler: (CGFloat) -> Void
    let scrollHandler: (CGSize) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.keyboardHandler = keyboardHandler
        view.magnificationHandler = magnificationHandler
        view.scrollHandler = scrollHandler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.keyboardHandler = keyboardHandler
        nsView.magnificationHandler = magnificationHandler
        nsView.scrollHandler = scrollHandler
    }

    final class MonitorView: NSView {
        var keyboardHandler: ((GraphKeyboardKey) -> Void)?
        var magnificationHandler: ((CGFloat) -> Void)?
        var scrollHandler: ((CGSize) -> Void)?
        private var keyboardMonitor: Any?
        private var magnificationMonitor: Any?
        private var scrollMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, keyboardMonitor == nil {
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
                    self.magnificationHandler?(event.magnification)
                    return nil
                }

                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self,
                          self.window?.isKeyWindow == true,
                          event.window === self.window,
                          event.hasPreciseScrollingDeltas,
                          !Self.isOverScrollView(event, in: self.window) else {
                        return event
                    }
                    self.scrollHandler?(
                        CGSize(
                            width: event.scrollingDeltaX * 1.15,
                            height: event.scrollingDeltaY * 1.15
                        )
                    )
                    return nil
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
            keyboardMonitor = nil
            magnificationMonitor = nil
            scrollMonitor = nil
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
