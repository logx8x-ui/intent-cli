import AppKit
import SwiftUI
import IntentCore

struct IntentQuickGuideView: View {
    let catalog: [InstalledApp]
    let onAdd: ([AIIntentionSuggestion]) -> Void
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var page = 0
    @State private var purpose = ""
    @State private var draft: AIIntentionSuggestion?
    @State private var appQuery = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var includeTimer = false
    @State private var timerMinutes = 25
    @State private var includeBrowserSearches = false
    @State private var includeCountdown = false
    @State private var includeReason = false
    @State private var createdCount = 0

    private let service = IntentAIService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch page {
                case 0: purposeStep
                case 1: reviewStep
                case 2: guardrailStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .animation(.easeOut(duration: 0.18), value: page)

            Divider()
            footer
        }
        .frame(width: 780, height: 590)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 20)
        .shadow(color: .black.opacity(0.48), radius: 30, y: 16)
        .foregroundStyle(GraphTheme.text(colorScheme))
        .tint(GraphTheme.editBlue)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "scope")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Intent")
                    .font(.system(size: 17, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme))
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }

            Button("Skip") { onFinish() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .padding(.leading, 12)
        }
        .padding(.horizontal, 24)
        .frame(height: 62)
    }

    private var headerSubtitle: String {
        switch page {
        case 0: "START WITH WHAT MATTERS"
        case 1: "CHECK THE AI DRAFT"
        case 2: "CHOOSE YOUR GUARDRAILS"
        default: "YOUR DESKTOP IS READY"
        }
    }

    private var purposeStep: some View {
        HStack(spacing: 36) {
            onboardingIllustration(
                symbol: "sparkles",
                title: "One thing at a time",
                detail: "Intent turns the way you already use your Mac into clear, reusable sessions."
            )

            VStack(alignment: .leading, spacing: 16) {
                Text("When you sit down at your computer, what are you usually here to do?")
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Start with one real outcome. Intent AI will choose only installed apps and turn it into a specific first intention.")
                    .font(.system(size: 13))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $purpose)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(11)
                    .frame(height: 132)
                    .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(GraphTheme.stroke(colorScheme)))
                    .overlay(alignment: .topLeading) {
                        if purpose.isEmpty {
                            Text("Example: Reply to messages in Messages and Gmail, or work on my data science assignments.")
                                .font(.system(size: 12))
                                .foregroundStyle(GraphTheme.muted(colorScheme).opacity(0.72))
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text("Only this answer and your installed app names are sent to Intent AI.")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reviewStep: some View {
        HStack(spacing: 36) {
            draftPreview

            VStack(alignment: .leading, spacing: 15) {
                Text("Intent AI drafted this for you")
                    .font(.system(size: 24, weight: .semibold))
                Text("A square is an intention. Its app icons are everything the session can open and use.")
                    .font(.system(size: 13))
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                if draft != nil {
                    TextField("Intention name", text: draftName)
                        .textFieldStyle(.roundedBorder)

                    fieldLabel("ALLOWED APPS")
                    selectedApps

                    TextField("Search installed apps", text: $appQuery)
                        .textFieldStyle(.roundedBorder)

                    if !appMatches.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(appMatches.prefix(4)) { app in
                                Button { addApp(app.bundleIdentifier) } label: {
                                    HStack(spacing: 8) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 22, height: 22)
                                        Text(app.name)
                                        Spacer()
                                        Image(systemName: "plus")
                                    }
                                    .padding(.horizontal, 9)
                                    .frame(height: 34)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                    }

                    if let websites = draft?.websites, !websites.isEmpty {
                        fieldLabel("ALLOWED WEBSITES")
                        Text(websites.map(\.value).joined(separator: "  •  "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var guardrailStep: some View {
        HStack(spacing: 36) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(GraphTheme.surface(colorScheme))

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for end in [CGPoint(x: size.width * 0.78, y: size.height * 0.28), CGPoint(x: size.width * 0.76, y: size.height * 0.75)] {
                        var path = Path()
                        path.move(to: center)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(GraphTheme.connection(colorScheme)), lineWidth: 1)
                    }
                }

                RoundedRectangle(cornerRadius: 15)
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 116, height: 116)
                    .overlay(Image(systemName: "square.grid.2x2").font(.system(size: 34)))
                    .offset(x: -55)

                Circle()
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 80, height: 80)
                    .overlay(Image(systemName: "timer").font(.system(size: 22)))
                    .offset(x: 104, y: -62)

                TriangleShape()
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 90, height: 82)
                    .overlay(Image(systemName: "hourglass").font(.system(size: 20)).offset(y: 10))
                    .offset(x: 101, y: 72)
            }
            .frame(width: 330, height: 330)

            VStack(alignment: .leading, spacing: 13) {
                Text("Add only the guardrails you need")
                    .font(.system(size: 24, weight: .semibold))
                Text("Circles are restrictions. Triangles are friction. Nothing is added unless you choose it.")
                    .font(.system(size: 13))
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                choiceToggle(
                    title: "25 minute timer",
                    detail: "End the session when its time is up.",
                    symbol: "timer",
                    isOn: $includeTimer
                )
                choiceToggle(
                    title: "Allow browser searches",
                    detail: "Search results work; unallowed websites stay blocked.",
                    symbol: "magnifyingglass",
                    isOn: $includeBrowserSearches,
                    disabled: !draftUsesBrowser
                )
                choiceToggle(
                    title: "5 second countdown",
                    detail: "A small pause before the intention starts.",
                    symbol: "hourglass",
                    isOn: $includeCountdown
                )
                choiceToggle(
                    title: "Write a reason",
                    detail: "State what you came to finish before entering.",
                    symbol: "square.and.pencil",
                    isOn: $includeReason
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var readyStep: some View {
        HStack(spacing: 36) {
            draftPreview

            VStack(alignment: .leading, spacing: 15) {
                Label("Your first intention is ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(GraphTheme.text(colorScheme))

                Text("We’ll place it on your desktop. Click the square whenever you want your Mac to become that task.")
                    .font(.system(size: 13))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    shortcut("Click", "Run an intention")
                    shortcut("Tab", "Enter edit mode")
                    shortcut("I / R / F", "Add an intention, restriction, or friction")
                    shortcut(FinishShortcutStore.load().displayName, "Finish the active intention")
                    shortcut(OverlayShortcutStore.load().displayName, "Show or hide Intent")
                }
                .padding(14)
                .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))

                Text("You can build more with the AI bar at the bottom, or press I to make one manually.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("Back") { page -= 1 }
                    .buttonStyle(.plain)
            } else if createdCount > 0 {
                Text("\(createdCount) added")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Spacer()

            if page == 3 {
                Button("Build another") {
                    importDraft()
                    resetForAnother()
                }
                .buttonStyle(.bordered)

                Button("Open my desktop") {
                    importDraft()
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draftIsReady)
            } else {
                Button(nextButtonTitle, action: advance)
                    .buttonStyle(.borderedProminent)
                    .disabled(nextDisabled)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private var nextButtonTitle: String {
        switch page {
        case 0: isGenerating ? "Thinking" : "Draft my intention"
        case 1: "Choose guardrails"
        default: "Review"
        }
    }

    private var nextDisabled: Bool {
        if page == 0 {
            return isGenerating || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !draftIsReady
    }

    private func advance() {
        switch page {
        case 0: generateDraft()
        case 1: page = 2
        case 2:
            applyGuardrails()
            page = 3
        default: break
        }
    }

    private func generateDraft() {
        let installed = catalog.map { AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let plan = try await service.generate(description: purpose, installedApps: installed)
                    .validated(against: installed)
                await MainActor.run {
                    guard let suggestion = plan.intentions.first,
                          !suggestion.appBundleIdentifiers.isEmpty else {
                        errorMessage = "Intent AI could not match that task to an installed app. Add the app name and try again."
                        isGenerating = false
                        return
                    }
                    draft = suggestion
                    includeTimer = suggestion.restrictions.contains { $0.kind == .timer }
                    timerMinutes = suggestion.restrictions.first { $0.kind == .timer }?.durationMinutes ?? 25
                    includeBrowserSearches = suggestion.restrictions.contains { $0.kind == .allowBrowserSearches }
                    includeCountdown = suggestion.frictions.contains { $0.kind == .countdown }
                    includeReason = suggestion.frictions.contains { $0.kind == .reasonPrompt }
                    isGenerating = false
                    page = 1
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }

    private func applyGuardrails() {
        guard var draft else { return }
        draft.restrictions.removeAll { $0.kind == .timer || $0.kind == .allowBrowserSearches }
        if includeTimer {
            draft.restrictions.append(.init(kind: .timer, durationMinutes: max(1, timerMinutes)))
        }
        if includeBrowserSearches, draftUsesBrowser {
            draft.restrictions.append(.init(kind: .allowBrowserSearches))
        }
        draft.allowBrowserSearches = includeBrowserSearches && draftUsesBrowser

        draft.frictions.removeAll { $0.kind == .countdown || $0.kind == .reasonPrompt }
        if includeCountdown {
            draft.frictions.append(.init(kind: .countdown, seconds: 5))
        }
        if includeReason {
            draft.frictions.append(.init(kind: .reasonPrompt, text: "What are you here to finish?"))
        }
        self.draft = draft
    }

    private func importDraft() {
        guard let draft, draftIsReady else { return }
        applyGuardrails()
        onAdd([self.draft ?? draft])
        createdCount += 1
    }

    private func resetForAnother() {
        purpose = ""
        draft = nil
        appQuery = ""
        errorMessage = nil
        includeTimer = false
        includeBrowserSearches = false
        includeCountdown = false
        includeReason = false
        page = 0
    }

    private var draftName: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0 }
        )
    }

    private var draftIsReady: Bool {
        guard let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.appBundleIdentifiers.isEmpty
    }

    private var draftUsesBrowser: Bool {
        guard let draft else { return false }
        return draft.appBundleIdentifiers.contains(where: BrowserApplication.isBrowser)
    }

    private var selectedCatalogApps: [InstalledApp] {
        guard let draft else { return [] }
        let selected = Set(draft.appBundleIdentifiers)
        return catalog.filter { selected.contains($0.bundleIdentifier) }
    }

    private var appMatches: [InstalledApp] {
        let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let selected = Set(draft?.appBundleIdentifiers ?? [])
        return catalog.filter { !selected.contains($0.bundleIdentifier) && $0.matchesSearch(query) }
    }

    private var selectedApps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(selectedCatalogApps) { app in
                    HStack(spacing: 7) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                        Text(app.name)
                            .font(.system(size: 11, weight: .medium))
                        Button { removeApp(app.bundleIdentifier) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func addApp(_ identifier: String) {
        guard draft != nil, !(draft?.appBundleIdentifiers.contains(identifier) ?? true) else { return }
        draft?.appBundleIdentifiers.append(identifier)
        appQuery = ""
    }

    private func removeApp(_ identifier: String) {
        draft?.appBundleIdentifiers.removeAll { $0 == identifier }
        draft?.websites.removeAll { $0.browserBundleIdentifier == identifier }
        if !draftUsesBrowser {
            includeBrowserSearches = false
        }
    }

    private var draftPreview: some View {
        VStack(spacing: 12) {
            Text(draft?.name ?? "Your intention")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 190, height: 190)
                if selectedCatalogApps.isEmpty {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 42, weight: .light))
                } else {
                    HStack(spacing: 0) {
                        ForEach(selectedCatalogApps.prefix(4)) { app in
                            Image(nsImage: app.icon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 190 / CGFloat(min(selectedCatalogApps.count, 4)), height: 190)
                                .clipped()
                        }
                    }
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }

            Text(draft?.purpose ?? "AI draft")
                .font(.system(size: 11))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 270)
        }
        .frame(width: 330, height: 350)
        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(GraphTheme.stroke(colorScheme)))
    }

    private func onboardingIllustration(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 150, height: 150)
                Circle()
                    .stroke(GraphTheme.stroke(colorScheme), lineWidth: 1)
                    .frame(width: 210, height: 210)
                Image(systemName: symbol)
                    .font(.system(size: 50, weight: .light))
            }
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .multilineTextAlignment(.center)
                .frame(width: 270)
        }
        .frame(width: 330, height: 350)
        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(GraphTheme.stroke(colorScheme)))
    }

    private func choiceToggle(
        title: String,
        detail: String,
        symbol: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(GraphTheme.elevatedSurface(colorScheme), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .padding(10)
        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .frame(width: 104, alignment: .leading)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(GraphTheme.muted(colorScheme))
            Spacer()
        }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(GraphTheme.muted(colorScheme))
    }
}
