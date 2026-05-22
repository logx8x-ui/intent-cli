import SwiftUI
import IntentCore

struct IntentionDetailView: View {
    @EnvironmentObject private var model: IntentAppModel
    @State private var draft: Intention
    @State private var selectedColor: Color
    @State private var frictionText: String

    private let symbols = [
        "target", "message.fill", "envelope.fill", "function", "book.closed.fill", "terminal.fill",
        "curlybraces", "play.fill", "person.fill", "archivebox.fill", "clipboard.fill", "shippingbox.fill",
        "cup.and.saucer.fill", "magnifyingglass", "lock.fill", "graduationcap.fill", "flask.fill", "gamecontroller.fill",
        "person.crop.circle.badge.checkmark", "briefcase.fill", "dollarsign", "cart.fill", "gift.fill",
        "airplane", "fork.knife", "apple.logo", "tree.fill", "eyeglasses", "square.grid.3x3.fill"
    ]

    init(intention: Intention) {
        _draft = State(initialValue: intention)
        _selectedColor = State(initialValue: Color(hex: intention.colorHex))
        _frictionText = State(initialValue: Self.frictionText(intention.friction))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusStrip
                intentionSection
                allowedSection
                startupSection
                restrictionsSection
                frictionSection
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .background(AnkiTheme.detailBackground.opacity(0.001))
        .id(draft.id)
        .onChange(of: model.selectedID) { _ in
            if let selected = model.selectedIntention {
                reset(with: selected)
            }
        }
        .onChange(of: selectedColor) { newValue in
            draft.colorHex = newValue.hexString
        }
    }

    private var header: some View {
        HStack(spacing: 22) {
            Image(systemName: draft.icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(selectedColor)
                .frame(width: 74, height: 74)
                .background(AnkiTheme.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(AnkiTheme.softStroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                    Text("Active Intention")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textCase(.uppercase)
                }
                .foregroundStyle(selectedColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selectedColor.opacity(0.12))
                .clipShape(Capsule())

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
            .tint(selectedColor)
        }
        .glassPanel(cornerRadius: 24, padding: 24)
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            MetricTile(title: "Allowed Apps", value: "\(draft.allowedApps.count)", color: selectedColor)
            MetricTile(title: "Allowed Sites", value: "\(draft.allowedWebsites.count)", color: AnkiTheme.accent)
            MetricTile(title: "Startup Chain", value: "\(draft.startupActions.count)", color: .secondary)
        }
    }

    private var intentionSection: some View {
        FormSection("Intention") {
            LabeledRow("Name") {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledRow("Folder") {
                TextField("Folder", text: $draft.folder)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledRow("SF Symbol") {
                Picker("SF Symbol", selection: $draft.icon) {
                    ForEach(symbols, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
                .labelsHidden()
            }
            LabeledRow("Color") {
                ColorPicker("Color", selection: $selectedColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    private var allowedSection: some View {
        FormSection("Allowed") {
            AppSelectionEditor(
                title: "Allowed apps",
                apps: $draft.allowedApps,
                catalog: model.installedApps
            )
            Divider()
            WebsiteEditor(websites: $draft.allowedWebsites)
        }
    }

    private var startupSection: some View {
        FormSection("Startup") {
            StartupActionEditor(
                actions: $draft.startupActions,
                allowedApps: $draft.allowedApps,
                catalog: model.installedApps
            )
        }
    }

    private var restrictionsSection: some View {
        FormSection("Restrictions") {
            Toggle("Block tab switching to unallowed websites", isOn: Binding(
                get: { draft.restrictions.blockBrowserTabSwitching && draft.restrictions.blockBrowserNavigation },
                set: { enabled in
                    draft.restrictions.blockBrowserTabSwitching = enabled
                    draft.restrictions.blockBrowserNavigation = enabled
                    draft.restrictions.blockNewBrowserTabs = enabled
                }
            ))

            Toggle("Block window switching to unallowed applications", isOn: Binding(
                get: { draft.restrictions.blockAppSwitching && draft.restrictions.keepFocused },
                set: { enabled in
                    draft.restrictions.blockAppSwitching = enabled
                    draft.restrictions.blockNewApps = enabled
                    draft.restrictions.keepFocused = enabled
                }
            ))

            Toggle("Allow tab creation for Google searches", isOn: $draft.restrictions.allowGoogleSearchTabs)
        }
    }

    private var frictionSection: some View {
        FormSection("Friction") {
            LabeledRow("Type") {
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
                .labelsHidden()
            }

            if frictionKind != "none" {
                LabeledRow("Value") {
                    TextField("Friction value", text: $frictionText)
                        .textFieldStyle(.roundedBorder)
                }
            }
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
        draft.colorHex = selectedColor.hexString
        setFrictionKind(frictionKind)
        model.updateSelected(draft)
    }

    private func reset(with intention: Intention) {
        draft = intention
        selectedColor = Color(hex: intention.colorHex)
        frictionText = Self.frictionText(intention.friction)
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(AnkiTheme.mutedText)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .ankiPanel()
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(AnkiTheme.mutedText)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18, padding: 14)
    }
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
