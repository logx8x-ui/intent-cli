import AppKit
import SwiftUI
import IntentCore

struct IntentQuickGuideView: View {
    let catalog: [InstalledApp]
    let onAdd: ([AIIntentionSuggestion]) -> Void
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var purposeFocused: Bool
    @State private var page = 0
    @State private var purpose = ""
    @State private var drafts: [OnboardingDraft] = []
    @State private var selectedDraftID: UUID?
    @State private var appQuery = ""
    @State private var isGenerating = false
    @State private var splittingID: UUID?
    @State private var errorMessage: String?

    private let service = IntentAIService()

    var body: some View {
        ZStack {
            GraphTheme.background(colorScheme)
            switch page {
            case 0: questionPage
            case 1: intentionListPage
            default: reviewPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(GraphTheme.text(colorScheme))
        .tint(GraphTheme.editBlue)
        .onExitCommand {
            if page > 0 {
                withAnimation(.easeOut(duration: 0.18)) { page -= 1 }
            } else {
                onFinish()
            }
        }
    }

    private var questionPage: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("When you sit down at your computer, what do you use your computer for?")
                .font(.system(size: 34, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820)

            Spacer().frame(height: 46)

            HStack(spacing: 12) {
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                TextField("Reply here", text: $purpose)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($purposeFocused)
                    .onSubmit(generateStarterSet)
                Button(action: generateStarterSet) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(GraphTheme.editBlue, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || cleanPurpose.isEmpty)
                .opacity(cleanPurpose.isEmpty ? 0.45 : 1)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(maxWidth: 760, minHeight: 54)
            .background(GraphTheme.elevatedSurface(colorScheme), in: Capsule())
            .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme)))

            Text("For example: reply to people, play games, study, complete work")
                .font(.system(size: 11.5))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .padding(.top, 13)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.top, 14)
            }
            Spacer()
        }
        .padding(.horizontal, 44)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                purposeFocused = true
            }
        }
    }

    private var intentionListPage: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                eyebrow: "YOUR STARTING SET",
                title: "Does this look like your computer life?",
                detail: "Keep the intentions you want. If one still feels too broad, let Intent split it into smaller choices."
            )
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                    ForEach($drafts) { $draft in
                        starterCard(draft: $draft)
                    }
                }
                .padding(.horizontal, 42)
                .padding(.vertical, 22)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 42)
                    .padding(.bottom, 8)
            }

            HStack {
                Button("Start again") {
                    drafts = []
                    purpose = ""
                    errorMessage = nil
                    withAnimation(.easeOut(duration: 0.18)) { page = 0 }
                }
                .buttonStyle(.plain)
                .foregroundStyle(GraphTheme.muted(colorScheme))
                Spacer()
                Text("You can change every suggestion next")
                    .font(.system(size: 10.5))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Button("Review \(includedDrafts.count) intentions") {
                    selectedDraftID = includedDrafts.first?.id
                    appQuery = ""
                    withAnimation(.easeOut(duration: 0.18)) { page = 2 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(includedDrafts.isEmpty)
            }
            .padding(.horizontal, 42)
            .frame(height: 70)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func starterCard(draft: Binding<OnboardingDraft>) -> some View {
        let value = draft.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Button { draft.wrappedValue.isIncluded.toggle() } label: {
                    Image(systemName: value.isIncluded ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(value.isIncluded ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(value.suggestion.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if value.suggestion.isLeisure {
                            Text("LEISURE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(GraphTheme.stroke(colorScheme).opacity(0.7), in: Capsule())
                        }
                    }
                    Text(value.suggestion.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(apps(for: value.suggestion).prefix(5)) { app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if value.suggestion.isLeisure && value.suggestion.appBundleIdentifiers.isEmpty {
                    Image(systemName: "sun.max")
                        .frame(width: 28, height: 28)
                        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                if !value.suggestion.isLeisure {
                    Button { split(value) } label: {
                        HStack(spacing: 5) {
                            if splittingID == value.id {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.branch")
                            }
                            Text("Split further")
                        }
                        .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .disabled(splittingID != nil)
                }
            }
        }
        .padding(16)
        .frame(minHeight: 128)
        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(GraphTheme.stroke(colorScheme)))
        .opacity(value.isIncluded ? 1 : 0.48)
    }

    private var reviewPage: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                eyebrow: "FINAL CHECK",
                title: "Make each intention yours",
                detail: "Intent has suggested the apps and guardrails. Remove anything you do not want before building your desktop."
            )
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(includedDrafts) { draft in
                            Button {
                                selectedDraftID = draft.id
                                appQuery = ""
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: draft.suggestion.isLeisure ? "sun.max" : "square.fill")
                                        .font(.system(size: 10))
                                    Text(draft.suggestion.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 38)
                                .background(
                                    selectedDraftID == draft.id ? GraphTheme.elevatedSurface(colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 220)
                .background(GraphTheme.surface(colorScheme).opacity(0.62))
                Divider()
                if let index = selectedIndex {
                    draftEditor(index: index)
                } else {
                    Text("Select an intention")
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            HStack {
                Button("Back") { withAnimation(.easeOut(duration: 0.18)) { page = 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Spacer()
                Text("This creates your main Intent desktop")
                    .font(.system(size: 10.5))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Button("Build my desktop") {
                    onAdd(includedDrafts.map(\.suggestion))
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allIncludedDraftsAreReady)
            }
            .padding(.horizontal, 30)
            .frame(height: 64)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func draftEditor(index: Int) -> some View {
        let suggestion = $drafts[index].suggestion
        let value = drafts[index].suggestion
        let selected = Set(value.appBundleIdentifiers)
        let matchingApps = catalog.filter {
            !selected.contains($0.bundleIdentifier) && !appQuery.isEmpty && $0.matchesSearch(appQuery)
        }.prefix(6)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("INTENTION")
                    TextField("Name", text: suggestion.name).textFieldStyle(.roundedBorder)
                    Text(value.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }

                if value.isLeisure {
                    Label("Leisure keeps the computer open instead of locking it to selected apps.", systemImage: "sun.max")
                        .font(.system(size: 11))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 9) {
                    fieldLabel(value.isLeisure ? "STARTUP APPS (OPTIONAL)" : "ALLOWED APPS")
                    appChips(for: index)
                    TextField("Search installed apps", text: $appQuery).textFieldStyle(.roundedBorder)
                    if !matchingApps.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(Array(matchingApps)) { app in
                                Button { addApp(app.bundleIdentifier, to: index) } label: {
                                    HStack(spacing: 9) {
                                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                                        Text(app.name).font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Image(systemName: "plus")
                                    }
                                    .padding(8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                    }
                }

                if !value.websites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("ALLOWED WEBSITES")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 7)],
                            alignment: .leading,
                            spacing: 7
                        ) {
                            ForEach(Array(value.websites.enumerated()), id: \.offset) { websiteIndex, website in
                                HStack(spacing: 7) {
                                    Image(systemName: "globe")
                                    Text(website.value)
                                    Button { drafts[index].suggestion.websites.remove(at: websiteIndex) } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.system(size: 10))
                                .padding(.horizontal, 9)
                                .frame(height: 32)
                                .background(GraphTheme.surface(colorScheme), in: Capsule())
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("SUGGESTED GUARDRAILS")
                    guardrailToggle(
                        title: "Timer",
                        detail: "Useful when this activity can run longer than intended.",
                        isOn: restrictionBinding(.timer, index: index)
                    )
                    if value.appBundleIdentifiers.contains(where: BrowserApplication.isBrowser) {
                        guardrailToggle(
                            title: "Allow browser searches",
                            detail: "Search results work while other websites remain blocked.",
                            isOn: restrictionBinding(.allowBrowserSearches, index: index)
                        )
                    }
                    guardrailToggle(
                        title: "5 second countdown",
                        detail: "Adds a short pause before entering this intention.",
                        isOn: frictionBinding(.countdown, index: index)
                    )
                    guardrailToggle(
                        title: "Write a reason",
                        detail: "State what you came to finish before the intention starts.",
                        isOn: frictionBinding(.reasonPrompt, index: index)
                    )
                }

                if !value.isLeisure && value.appBundleIdentifiers.isEmpty {
                    Label("Choose at least one app for this intention.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func onboardingHeader(eyebrow: String, title: String, detail: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(GraphTheme.editBlue)
                Text(title).font(.system(size: 25, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            Spacer()
        }
        .padding(.horizontal, 42)
        .padding(.top, 32)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func appChips(for index: Int) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(apps(for: drafts[index].suggestion)) { app in
                HStack(spacing: 7) {
                    Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                    Text(app.name).font(.system(size: 10.5, weight: .medium))
                    Button { removeApp(app.bundleIdentifier, from: index) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func guardrailToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
    }

    private func restrictionBinding(_ kind: RestrictionKind, index: Int) -> Binding<Bool> {
        Binding(
            get: { drafts[index].suggestion.restrictions.contains { $0.kind == kind } },
            set: { enabled in
                drafts[index].suggestion.restrictions.removeAll { $0.kind == kind }
                if enabled {
                    drafts[index].suggestion.restrictions.append(.init(
                        kind: kind,
                        durationMinutes: kind == .timer ? 30 : 0
                    ))
                }
                if kind == .allowBrowserSearches {
                    drafts[index].suggestion.allowBrowserSearches = enabled
                }
            }
        )
    }

    private func frictionBinding(_ kind: AIFrictionKind, index: Int) -> Binding<Bool> {
        Binding(
            get: { drafts[index].suggestion.frictions.contains { $0.kind == kind } },
            set: { enabled in
                drafts[index].suggestion.frictions.removeAll { $0.kind == kind }
                guard enabled else { return }
                switch kind {
                case .countdown:
                    drafts[index].suggestion.frictions.append(.init(kind: .countdown, seconds: 5))
                case .reasonPrompt:
                    drafts[index].suggestion.frictions.append(.init(
                        kind: .reasonPrompt,
                        text: "What are you here to finish?"
                    ))
                default:
                    break
                }
            }
        )
    }

    private var cleanPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var includedDrafts: [OnboardingDraft] {
        drafts.filter(\.isIncluded)
    }

    private var selectedIndex: Int? {
        guard let selectedDraftID else { return drafts.firstIndex(where: \.isIncluded) }
        return drafts.firstIndex { $0.id == selectedDraftID && $0.isIncluded }
    }

    private var allIncludedDraftsAreReady: Bool {
        !includedDrafts.isEmpty && includedDrafts.allSatisfy {
            !$0.suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ($0.suggestion.isLeisure || !$0.suggestion.appBundleIdentifiers.isEmpty)
        }
    }

    private func apps(for suggestion: AIIntentionSuggestion) -> [InstalledApp] {
        let selected = Set(suggestion.appBundleIdentifiers)
        return catalog.filter { selected.contains($0.bundleIdentifier) }
    }

    private func generateStarterSet() {
        guard !isGenerating, !cleanPurpose.isEmpty else { return }
        purposeFocused = false
        isGenerating = true
        errorMessage = nil
        let installed = catalog.map { AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }

        Task {
            do {
                let plan = try await service.generate(
                    description: cleanPurpose,
                    installedApps: installed,
                    mode: .onboarding
                ).validated(against: installed)
                await MainActor.run {
                    drafts = ensureLeisure(in: plan.intentions).map(OnboardingDraft.init)
                    isGenerating = false
                    if drafts.isEmpty {
                        errorMessage = "Tell Intent a little more about the apps or websites you use."
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { page = 1 }
                    }
                }
            } catch {
                await MainActor.run {
                    drafts = fallbackSuggestions().map(OnboardingDraft.init)
                    isGenerating = false
                    errorMessage = "Intent AI took too long, so these suggestions were made on this Mac. You can edit all of them."
                    withAnimation(.easeOut(duration: 0.2)) { page = 1 }
                }
            }
        }
    }

    private func split(_ draft: OnboardingDraft) {
        guard splittingID == nil else { return }
        splittingID = draft.id
        errorMessage = nil
        let installed = catalog.map { AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }
        let description = "The person said: \(cleanPurpose)\nSplit this broad intention into smaller choices: \(draft.suggestion.name) — \(draft.suggestion.purpose)"

        Task {
            do {
                let plan = try await service.generate(
                    description: description,
                    installedApps: installed,
                    mode: .split
                ).validated(against: installed)
                await MainActor.run {
                    let replacements = plan.intentions.filter { !$0.isLeisure }
                    guard replacements.count >= 2,
                          let index = drafts.firstIndex(where: { $0.id == draft.id }) else {
                        errorMessage = "That intention is already fairly specific."
                        splittingID = nil
                        return
                    }
                    drafts.replaceSubrange(index...index, with: replacements.map(OnboardingDraft.init))
                    splittingID = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Intent could not split that suggestion just now. You can still rename it during review."
                    splittingID = nil
                }
            }
        }
    }

    private func ensureLeisure(in suggestions: [AIIntentionSuggestion]) -> [AIIntentionSuggestion] {
        let focused = suggestions.filter { !$0.isLeisure }
        let leisure = suggestions.first(where: \.isLeisure) ?? AIIntentionSuggestion(
            name: "Leisure",
            purpose: "Use the computer freely when you are not entering a focused session.",
            appBundleIdentifiers: [],
            websites: [],
            allowBrowserSearches: false,
            isLeisure: true
        )
        return Array(focused.prefix(7)) + [leisure]
    }

    private func fallbackSuggestions() -> [AIIntentionSuggestion] {
        var suggestions: [AIIntentionSuggestion] = []
        let lower = cleanPurpose.lowercased()
        if lower.contains("reply") || lower.contains("message") || lower.contains("people") || lower.contains("email") {
            suggestions.append(.init(
                name: "Reply to people",
                purpose: "Catch up on messages and email without drifting into other tasks.",
                appBundleIdentifiers: identifiers(namedLike: ["Messages", "WhatsApp", "Mail"]),
                websites: [],
                allowBrowserSearches: false
            ))
        }
        if lower.contains("study") || lower.contains("uni") || lower.contains("school") {
            suggestions.append(.init(
                name: "Work on assignments",
                purpose: "Use the tools needed to make progress on coursework.",
                appBundleIdentifiers: identifiers(namedLike: ["RStudio", "RemNote", "Anki", "Notes"]),
                websites: [],
                allowBrowserSearches: false
            ))
            suggestions.append(.init(
                name: "Review notes",
                purpose: "Revise existing material without opening unrelated work.",
                appBundleIdentifiers: identifiers(namedLike: ["RemNote", "Anki", "Notes"]),
                websites: [],
                allowBrowserSearches: false
            ))
        }
        if lower.contains("game") || lower.contains("play") {
            suggestions.append(.init(
                name: "Play games",
                purpose: "Enjoy a deliberate gaming session with a clear stopping point.",
                appBundleIdentifiers: identifiers(namedLike: ["Roblox", "Steam"]),
                websites: [],
                allowBrowserSearches: false,
                restrictions: [.init(kind: .timer, durationMinutes: 60)],
                frictions: [.init(kind: .countdown, seconds: 5)]
            ))
        }
        if lower.contains("work") || lower.contains("complete") || lower.contains("code") {
            suggestions.append(.init(
                name: "Complete focused work",
                purpose: "Open the main tools needed to finish a piece of work.",
                appBundleIdentifiers: identifiers(namedLike: ["Cursor", "Codex", "Visual Studio Code", "Notes"]),
                websites: [],
                allowBrowserSearches: false
            ))
        }
        if suggestions.isEmpty, let first = catalog.first {
            suggestions.append(.init(
                name: "Focused session",
                purpose: cleanPurpose,
                appBundleIdentifiers: [first.bundleIdentifier],
                websites: [],
                allowBrowserSearches: false
            ))
        }
        return ensureLeisure(in: suggestions)
    }

    private func identifiers(namedLike names: [String]) -> [String] {
        Array(Set(names.compactMap { name in
            catalog.first { $0.name.localizedCaseInsensitiveContains(name) }?.bundleIdentifier
        }))
    }

    private func addApp(_ identifier: String, to index: Int) {
        guard !drafts[index].suggestion.appBundleIdentifiers.contains(identifier) else { return }
        drafts[index].suggestion.appBundleIdentifiers.append(identifier)
        appQuery = ""
    }

    private func removeApp(_ identifier: String, from index: Int) {
        drafts[index].suggestion.appBundleIdentifiers.removeAll { $0 == identifier }
        drafts[index].suggestion.websites.removeAll { $0.browserBundleIdentifier == identifier }
        if !drafts[index].suggestion.appBundleIdentifiers.contains(where: BrowserApplication.isBrowser) {
            drafts[index].suggestion.allowBrowserSearches = false
            drafts[index].suggestion.restrictions.removeAll { $0.kind == .allowBrowserSearches }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(GraphTheme.muted(colorScheme))
    }
}

private struct OnboardingDraft: Identifiable {
    let id = UUID()
    var isIncluded = true
    var suggestion: AIIntentionSuggestion

    init(_ suggestion: AIIntentionSuggestion) {
        self.suggestion = suggestion
    }
}
