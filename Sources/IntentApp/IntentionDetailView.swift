import SwiftUI
import IntentCore

struct IntentionDetailView: View {
    @EnvironmentObject private var model: IntentAppModel
    @State private var draft: Intention
    @State private var allowedAppsText: String
    @State private var allowedWebsitesText: String
    @State private var startupActionsText: String
    @State private var frictionText: String

    init(intention: Intention) {
        _draft = State(initialValue: intention)
        _allowedAppsText = State(initialValue: Self.appsText(intention.allowedApps))
        _allowedWebsitesText = State(initialValue: intention.allowedWebsites.map(\.value).joined(separator: "\n"))
        _startupActionsText = State(initialValue: Self.startupText(intention.startupActions))
        _frictionText = State(initialValue: Self.frictionText(intention.friction))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                allowedSection
                startupSection
                restrictionsSection
                frictionSection
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .id(draft.id)
        .onChange(of: model.selectedID) { _ in
            if let selected = model.selectedIntention {
                reset(with: selected)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: draft.icon)
                .font(.system(size: 32))
                .frame(width: 54, height: 54)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.name)
                    .font(.largeTitle.weight(.semibold))
                Text("Manual intention builder")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Save") {
                saveDraft()
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Start") {
                saveDraft()
                model.requestStart(draft)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var identitySection: some View {
        FormSection("Identity") {
            TextField("Name", text: $draft.name)
            TextField("Folder", text: $draft.folder)
            TextField("SF Symbol", text: $draft.icon)
            TextField("Color hex", text: $draft.colorHex)
        }
    }

    private var allowedSection: some View {
        FormSection("Allowed Targets") {
            VStack(alignment: .leading) {
                Text("Allowed apps")
                    .font(.headline)
                Text("One per line: App name | bundle.id")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $allowedAppsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
            }

            VStack(alignment: .leading) {
                Text("Allowed websites")
                    .font(.headline)
                Text("One domain/path per line, e.g. github.com or instagram.com/direct")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $allowedWebsitesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
            }
        }
    }

    private var startupSection: some View {
        FormSection("Startup Actions") {
            Text("One per line: app:bundle.id, url:https://example.com, sidebery:data-science, spotify:playlist-uri")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $startupActionsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
        }
    }

    private var restrictionsSection: some View {
        FormSection("Restrictions") {
            Toggle("Block app/window switching outside allowed apps", isOn: $draft.restrictions.blockAppSwitching)
            Toggle("Block launching non-allowed apps", isOn: $draft.restrictions.blockNewApps)
            Toggle("Block browser tab switching", isOn: $draft.restrictions.blockBrowserTabSwitching)
            Toggle("Block browser navigation outside allowed sites", isOn: $draft.restrictions.blockBrowserNavigation)
            Toggle("Block new browser tabs/windows", isOn: $draft.restrictions.blockNewBrowserTabs)
            Toggle("Keep the intention focused", isOn: $draft.restrictions.keepFocused)
        }
    }

    private var frictionSection: some View {
        FormSection("Friction") {
            Picker("Type", selection: Binding(
                get: { frictionKind },
                set: { setFrictionKind($0) }
            )) {
                Text("None").tag("none")
                Text("Typed phrase").tag("phrase")
                Text("Countdown").tag("countdown")
                Text("Reason prompt").tag("reason")
                Text("Task checklist").tag("checklist")
                Text("Time budget").tag("budget")
            }
            TextField("Friction value", text: $frictionText)
        }
    }

    private var frictionKind: String {
        switch draft.friction {
        case .none: "none"
        case .typedPhrase: "phrase"
        case .countdown: "countdown"
        case .reasonPrompt: "reason"
        case .taskChecklist: "checklist"
        case .timeBudget: "budget"
        }
    }

    private func setFrictionKind(_ kind: String) {
        switch kind {
        case "phrase":
            draft.friction = .typedPhrase(frictionText.isEmpty ? "I want to use this right now" : frictionText)
        case "countdown":
            draft.friction = .countdown(seconds: Int(frictionText) ?? 10)
        case "reason":
            draft.friction = .reasonPrompt(frictionText.isEmpty ? "What are you here to do?" : frictionText)
        case "checklist":
            draft.friction = .taskChecklist(frictionText.lines)
        case "budget":
            draft.friction = .timeBudget(minutes: Int(frictionText) ?? 10)
        default:
            draft.friction = .none
        }
    }

    private func saveDraft() {
        draft.allowedApps = parseApps(allowedAppsText)
        draft.allowedWebsites = allowedWebsitesText.lines.map(AllowedWebsite.init)
        draft.startupActions = parseStartupActions(startupActionsText)
        setFrictionKind(frictionKind)
        model.updateSelected(draft)
    }

    private func reset(with intention: Intention) {
        draft = intention
        allowedAppsText = Self.appsText(intention.allowedApps)
        allowedWebsitesText = intention.allowedWebsites.map(\.value).joined(separator: "\n")
        startupActionsText = Self.startupText(intention.startupActions)
        frictionText = Self.frictionText(intention.friction)
    }

    private static func appsText(_ apps: [AllowedApp]) -> String {
        apps.map { "\($0.name) | \($0.bundleIdentifier)" }.joined(separator: "\n")
    }

    private static func startupText(_ actions: [StartupAction]) -> String {
        actions.map { action in
            switch action {
            case .openApp(let bundle): "app:\(bundle)"
            case .openURL(let url, _): "url:\(url)"
            case .selectSideberyDataSciencePanel: "sidebery:data-science"
            case .playSpotifyPlaylist(let uri): "spotify:\(uri)"
            }
        }.joined(separator: "\n")
    }

    private static func frictionText(_ friction: Friction) -> String {
        switch friction {
        case .none: ""
        case .typedPhrase(let value): value
        case .countdown(let seconds): "\(seconds)"
        case .reasonPrompt(let prompt): prompt
        case .taskChecklist(let tasks): tasks.joined(separator: "\n")
        case .timeBudget(let minutes): "\(minutes)"
        }
    }

    private func parseApps(_ text: String) -> [AllowedApp] {
        text.lines.compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            return AllowedApp(name: parts[0], bundleIdentifier: parts[1])
        }
    }

    private func parseStartupActions(_ text: String) -> [StartupAction] {
        text.lines.compactMap { line in
            if line.hasPrefix("app:") {
                return .openApp(String(line.dropFirst(4)))
            }
            if line.hasPrefix("url:") {
                return .openURL(String(line.dropFirst(4)), browserBundleIdentifier: "org.mozilla.firefox")
            }
            if line == "sidebery:data-science" {
                return .selectSideberyDataSciencePanel
            }
            if line.hasPrefix("spotify:") {
                return .playSpotifyPlaylist(String(line))
            }
            return nil
        }
    }
}

private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
