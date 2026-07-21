import SwiftUI
import IntentCore

struct AIIntentionBuilderView: View {
    let catalog: [InstalledApp]
    let onAdd: ([AIIntentionSuggestion]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var activities = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var drafts: [AIEditableDraft] = []
    @State private var selectedDraftID: UUID?
    @State private var appQuery = ""
    @State private var websiteDraft = ""
    @State private var websiteBrowserIdentifier = ""
    @State private var didAutoGenerate = false

    private let service = IntentAIService()

    init(
        catalog: [InstalledApp],
        initialActivities: String = "",
        onAdd: @escaping ([AIIntentionSuggestion]) -> Void
    ) {
        self.catalog = catalog
        self.onAdd = onAdd
        _activities = State(initialValue: initialActivities)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if drafts.isEmpty {
                describeStep
            } else {
                reviewStep
            }
        }
        .frame(width: 820, height: 590)
        .background(GraphTheme.background(colorScheme).opacity(0.97))
        .foregroundStyle(GraphTheme.text(colorScheme))
        .tint(GraphTheme.editBlue)
        .task {
            guard !didAutoGenerate,
                  !activities.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            didAutoGenerate = true
            generate()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(GraphTheme.editBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Build with AI")
                    .font(.system(size: 16, weight: .semibold))
                Text(drafts.isEmpty ? "Tell Intent what your computer is for" : "Check what each intention needs")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var describeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you do on this Mac?")
                    .font(.system(size: 24, weight: .semibold))
                Text("Mention your work, study, communication, and the things you come here to finish.")
                    .font(.system(size: 13))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            TextEditor(text: $activities)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 190)
                .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(GraphTheme.stroke(colorScheme)))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Text("Your description and installed app names are sent securely to Intent AI.")
                    .font(.system(size: 10))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Spacer()
                Button {
                    generate()
                } label: {
                    HStack(spacing: 7) {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGenerating ? "Thinking" : "Suggest intentions")
                    }
                    .frame(minWidth: 132)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isGenerating
                    || activities.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(28)
    }

    private var reviewStep: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach($drafts) { $draft in
                            Button {
                                selectedDraftID = draft.id
                                appQuery = ""
                                websiteDraft = ""
                            } label: {
                                HStack(spacing: 9) {
                                    Toggle("", isOn: $draft.isIncluded)
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(draft.suggestion.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text("\(draft.suggestion.appBundleIdentifiers.count) apps")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(GraphTheme.muted(colorScheme))
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(
                                    selectedDraftID == draft.id
                                        ? GraphTheme.elevatedSurface(colorScheme)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    drafts = []
                    selectedDraftID = nil
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(14)
            .frame(width: 220)
            .background(GraphTheme.surface(colorScheme).opacity(0.72))

            Divider()

            if let selectedIndex {
                draftEditor(index: selectedIndex)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 26, weight: .light))
                    Text("Select an intention")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Every suggestion remains editable on the canvas.")
                    .font(.system(size: 10))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Spacer()
                Button("Add \(readyDrafts.count) intentions") {
                    onAdd(readyDrafts.map(\.suggestion))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(readyDrafts.isEmpty)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func draftEditor(index: Int) -> some View {
        let suggestion = $drafts[index].suggestion
        let selectedIdentifiers = Set(drafts[index].suggestion.appBundleIdentifiers)
        let matchingApps = catalog.filter {
            !selectedIdentifiers.contains($0.bundleIdentifier)
            && (appQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(appQuery))
        }.prefix(6)
        let selectedBrowsers = catalog.filter {
            selectedIdentifiers.contains($0.bundleIdentifier)
            && BrowserApplication.isBrowser($0.bundleIdentifier)
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("NAME")
                    TextField("Intention name", text: suggestion.name)
                        .textFieldStyle(.roundedBorder)
                    Text(drafts[index].suggestion.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("ALLOWED APPS")
                    ForEach(selectedApps(for: index)) { app in
                        HStack(spacing: 9) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).font(.system(size: 12, weight: .medium))
                                Text(app.bundleIdentifier)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(GraphTheme.muted(colorScheme))
                            }
                            Spacer()
                            Button {
                                removeApp(app.bundleIdentifier, from: index)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    }

                    TextField("Search installed apps", text: $appQuery)
                        .textFieldStyle(.roundedBorder)
                    if !appQuery.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(Array(matchingApps)) { app in
                                Button {
                                    addApp(app.bundleIdentifier, to: index)
                                } label: {
                                    HStack {
                                        Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                                        Text(app.name).font(.system(size: 11))
                                        Spacer()
                                        Image(systemName: "plus")
                                    }
                                    .padding(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !selectedBrowsers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("ALLOWED WEBSITES")
                        ForEach(Array(drafts[index].suggestion.websites.enumerated()), id: \.offset) { websiteIndex, website in
                            HStack {
                                Image(systemName: "globe")
                                Text(website.value).font(.system(size: 11))
                                Spacer()
                                Button {
                                    drafts[index].suggestion.websites.remove(at: websiteIndex)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(GraphTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                        }

                        HStack(spacing: 8) {
                            TextField("example.com/path", text: $websiteDraft)
                                .textFieldStyle(.roundedBorder)
                            Picker("Browser", selection: $websiteBrowserIdentifier) {
                                ForEach(selectedBrowsers) { browser in
                                    Text(browser.name).tag(browser.bundleIdentifier)
                                }
                            }
                            .frame(width: 130)
                            Button {
                                addWebsite(to: index, fallbackBrowser: selectedBrowsers.first?.bundleIdentifier)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            .disabled(websiteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Toggle("Allow browser searches", isOn: suggestion.allowBrowserSearches)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                }

                if drafts[index].suggestion.appBundleIdentifiers.isEmpty {
                    Label("Choose at least one app", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if websiteBrowserIdentifier.isEmpty {
                websiteBrowserIdentifier = selectedBrowsers.first?.bundleIdentifier ?? ""
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedDraftID else { return drafts.indices.first }
        return drafts.firstIndex { $0.id == selectedDraftID }
    }

    private var readyDrafts: [AIEditableDraft] {
        drafts.filter {
            $0.isIncluded
            && !$0.suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.suggestion.appBundleIdentifiers.isEmpty
        }
    }

    private func selectedApps(for index: Int) -> [InstalledApp] {
        let selected = Set(drafts[index].suggestion.appBundleIdentifiers)
        return catalog.filter { selected.contains($0.bundleIdentifier) }
    }

    private func generate() {
        let installed = catalog.map { AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }

        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let plan = try await service.generate(
                    description: activities,
                    installedApps: installed
                ).validated(against: installed)
                await MainActor.run {
                    drafts = plan.intentions.map(AIEditableDraft.init)
                    selectedDraftID = drafts.first?.id
                    isGenerating = false
                    if drafts.isEmpty {
                        errorMessage = "No usable intentions were returned. Add more detail and try again."
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }

    private func addApp(_ bundleIdentifier: String, to index: Int) {
        guard !drafts[index].suggestion.appBundleIdentifiers.contains(bundleIdentifier) else { return }
        drafts[index].suggestion.appBundleIdentifiers.append(bundleIdentifier)
        appQuery = ""
        if BrowserApplication.isBrowser(bundleIdentifier), websiteBrowserIdentifier.isEmpty {
            websiteBrowserIdentifier = bundleIdentifier
        }
    }

    private func removeApp(_ bundleIdentifier: String, from index: Int) {
        drafts[index].suggestion.appBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        drafts[index].suggestion.websites.removeAll { $0.browserBundleIdentifier == bundleIdentifier }
        if websiteBrowserIdentifier == bundleIdentifier {
            websiteBrowserIdentifier = selectedApps(for: index)
                .first(where: { BrowserApplication.isBrowser($0.bundleIdentifier) })?
                .bundleIdentifier ?? ""
        }
    }

    private func addWebsite(to index: Int, fallbackBrowser: String?) {
        let browser = websiteBrowserIdentifier.isEmpty ? fallbackBrowser : websiteBrowserIdentifier
        guard let browser, !browser.isEmpty else { return }
        let normalized = AllowedWebsite.normalized(websiteDraft)
        guard !normalized.isEmpty else { return }
        drafts[index].suggestion.websites.append(.init(
            value: normalized,
            browserBundleIdentifier: browser
        ))
        websiteDraft = ""
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(GraphTheme.muted(colorScheme))
    }
}

private struct AIEditableDraft: Identifiable {
    let id = UUID()
    var isIncluded = true
    var suggestion: AIIntentionSuggestion

    init(_ suggestion: AIIntentionSuggestion) {
        self.suggestion = suggestion
    }
}
