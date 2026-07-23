import AppKit
import SwiftUI
import IntentCore

struct IntentionEditorMenu: View {
    @Binding var intention: Intention
    let catalog: [InstalledApp]
    let onDelete: () -> Void
    let onAddRestriction: () -> Void
    let onAddFriction: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var appQuery = ""
    @State private var websiteDrafts: [String: String] = [:]
    @FocusState private var nameFocused: Bool

    private var matches: [InstalledApp] {
        let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return catalog
            .filter { app in
                app.matchesSearch(query, anchored: true)
                    && !intention.allowedApps.contains { $0.bundleIdentifier == app.bundleIdentifier }
            }
            .prefix(7)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                editorHeader("Intention", symbol: "square", onSave: onSave)

                fieldLabel("Name")
                TextField("Intention name", text: $intention.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)

                fieldLabel("Allowed apps")
                tokenFlow

                TextField("Search installed apps", text: $appQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFirstMatch)

                if !matches.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(matches) { app in
                            Button {
                                add(app)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    Text(app.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(app.bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(GraphTheme.muted(colorScheme))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(GraphTheme.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }

                browserWebsiteEditors

                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete intention", systemImage: "trash")
                }
                .buttonStyle(.plain)

                Divider()
                fieldLabel("Add connected shape")
                HStack(spacing: 12) {
                    quickAddButton(
                        title: "Restriction",
                        symbol: "circle",
                        action: onAddRestriction
                    )
                    quickAddButton(
                        title: "Friction",
                        symbol: "triangle",
                        action: onAddFriction
                    )
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(width: 320)
        .frame(maxHeight: 470)
        .graphMenuPanel(colorScheme: colorScheme)
        .onAppear {
            guard intention.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private var tokenFlow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(intention.allowedApps) { app in
                HStack(spacing: 8) {
                    appIcon(app)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.system(size: 12, weight: .medium))
                        Text(app.bundleIdentifier)
                            .font(.caption2)
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                    Spacer()
                    Button {
                        remove(app)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Remove app")
                }
                .padding(.horizontal, 9)
                .frame(height: 40)
                .background(GraphTheme.surface(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var browserWebsiteEditors: some View {
        let browsers = intention.allowedApps.filter(\.isBrowser)
        if browsers.isEmpty {
            Text("Add a browser before adding websites.")
                .font(.caption)
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .padding(.top, 3)
        } else {
            ForEach(browsers) { browser in
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("\(browser.name) websites")
                    if !["org.mozilla.firefox", "com.google.Chrome"].contains(browser.bundleIdentifier) {
                        Label("Browser locking is currently available in Firefox and Chrome.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    ForEach(intention.websites(for: browser.bundleIdentifier)) { website in
                        HStack {
                            Image(systemName: "globe")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(website.displayName).font(.system(size: 12, weight: .medium))
                                Text(website.value)
                                    .font(.caption2)
                                    .foregroundStyle(GraphTheme.muted(colorScheme))
                            }
                            Spacer()
                            Button {
                                remove(website)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 39)
                        .background(GraphTheme.surface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 7) {
                        TextField(
                            "Paste a website",
                            text: Binding(
                                get: { websiteDrafts[browser.bundleIdentifier, default: ""] },
                                set: { websiteDrafts[browser.bundleIdentifier] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addWebsite(for: browser) }

                        Button {
                            addWebsite(for: browser)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .help("Add website")
                    }
                }
            }
        }
    }

    private func appIcon(_ app: AllowedApp) -> some View {
        Group {
            if let installed = catalog.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                Image(nsImage: installed.icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: app.isBrowser ? "globe" : "app")
            }
        }
        .frame(width: 23, height: 23)
    }

    private func add(_ app: InstalledApp) {
        intention.allowedApps.append(.init(name: app.name, bundleIdentifier: app.bundleIdentifier))
        appQuery = ""
    }

    private func addFirstMatch() {
        guard let app = matches.first(where: { $0.name.caseInsensitiveCompare(appQuery) == .orderedSame })
            ?? matches.first else {
            return
        }
        add(app)
    }

    private func remove(_ app: AllowedApp) {
        let websiteIDs = Set(intention.websites(for: app.bundleIdentifier).map(\.resourceID))
        intention.allowedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        intention.allowedWebsites.removeAll { $0.browserBundleIdentifier == app.bundleIdentifier }
        intention.restrictionNodes = intention.restrictionNodes.map { node in
            var updated = node
            updated.excludedResourceIDs.removeAll {
                $0 == app.resourceID || websiteIDs.contains($0)
            }
            return updated
        }
    }

    private func addWebsite(for browser: AllowedApp) {
        let raw = websiteDrafts[browser.bundleIdentifier, default: ""]
        let website = AllowedWebsite(raw, browserBundleIdentifier: browser.bundleIdentifier)
        guard !website.value.isEmpty,
              !intention.allowedWebsites.contains(where: { $0.id == website.id }) else {
            return
        }
        intention.allowedWebsites.append(website)
        websiteDrafts[browser.bundleIdentifier] = ""
    }

    private func remove(_ website: AllowedWebsite) {
        intention.allowedWebsites.removeAll { $0.id == website.id }
        intention.restrictionNodes = intention.restrictionNodes.map { node in
            var updated = node
            updated.excludedResourceIDs.removeAll { $0 == website.resourceID }
            return updated
        }
    }

    private func quickAddButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(GraphTheme.surface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(GraphTheme.stroke(colorScheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Add a connected \(title.lowercased())")
    }
}

struct RestrictionEditorMenu: View {
    @Binding var node: RestrictionNode
    let intention: Intention
    let onDelete: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var lastResourceSelectionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorHeader("Restriction", symbol: "circle", onSave: onSave)

            fieldLabel("Type")
            Picker("Restriction type", selection: $node.kind) {
                ForEach(RestrictionKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()

            switch node.kind {
            case .allowBrowserSearches:
                Text("Allows new tabs and Google result pages, while links to websites outside this intention stay blocked.")
                    .font(.caption)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            case .dontStartUp:
                fieldLabel("Keep closed when starting")
                if intention.allowedApps.isEmpty && intention.allowedWebsites.isEmpty {
                    Text("Add apps or websites to the intention first.")
                        .font(.caption)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                resourceToggles
            case .coolDown:
                durationEditor(
                    title: "Wait before using again",
                    detail: "Starts when this intention ends. It cannot run again until the cooldown finishes.",
                    defaultMinutes: 30
                )
                remainingTimeToggle("Show cooldown on intention")
            case .timer:
                durationEditor(
                    title: "Session limit",
                    detail: "Automatically ends this intention when the timer reaches zero.",
                    defaultMinutes: 25
                )
                remainingTimeToggle("Show timer while running")
                if node.showsRemainingTime ?? true {
                    fieldLabel("Timer position")
                    Picker(
                        "Timer position",
                        selection: Binding(
                            get: { node.timerDisplayPosition ?? .topTrailing },
                            set: { node.timerDisplayPosition = $0 }
                        )
                    ) {
                        ForEach(TimerDisplayPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .labelsHidden()
                }
            }

            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete restriction", systemImage: "trash")
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .graphMenuPanel(colorScheme: colorScheme)
    }

    private func remainingTimeToggle(_ title: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { node.showsRemainingTime ?? true },
                set: { node.showsRemainingTime = $0 }
            )
        )
        .toggleStyle(.checkbox)
        .font(.system(size: 12, weight: .medium))
    }

    private func durationEditor(
        title: String,
        detail: String,
        defaultMinutes: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(title)
            Stepper(
                value: Binding(
                    get: { max(1, node.durationMinutes ?? defaultMinutes) },
                    set: { node.durationMinutes = max(1, $0) }
                ),
                in: 1...1_440
            ) {
                HStack {
                    Text("\(max(1, node.durationMinutes ?? defaultMinutes))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("minutes")
                        .font(.system(size: 12))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .onAppear {
            if node.durationMinutes == nil {
                node.durationMinutes = defaultMinutes
            }
        }
    }

    private var resourceToggles: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !resources.isEmpty {
                resourceToggle(
                    id: nil,
                    title: allResourcesSelected ? "Deselect all" : "Select all",
                    subtitle: "All allowed apps and websites",
                    index: nil
                )
                Divider()
            }

            ForEach(Array(resources.enumerated()), id: \.offset) { index, resource in
                resourceToggle(
                    id: resource.id,
                    title: resource.title,
                    subtitle: resource.subtitle,
                    index: index
                )
            }
        }
    }

    private var resources: [RestrictionResource] {
        intention.allowedApps.map {
            RestrictionResource(id: $0.resourceID, title: $0.name, subtitle: "Application")
        } + intention.allowedWebsites.map {
            RestrictionResource(id: $0.resourceID, title: $0.displayName, subtitle: $0.value)
        }
    }

    private var allResourcesSelected: Bool {
        !resources.isEmpty && resources.allSatisfy { node.excludedResourceIDs.contains($0.id) }
    }

    private func resourceToggle(
        id: String?,
        title: String,
        subtitle: String,
        index: Int?
    ) -> some View {
        let selected = id.map { node.excludedResourceIDs.contains($0) } ?? allResourcesSelected

        return Button {
            if let id, let index {
                toggleResource(id: id, at: index, extendRange: NSEvent.modifierFlags.contains(.shift))
            } else {
                toggleAllResources()
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.caption2).foregroundStyle(GraphTheme.muted(colorScheme))
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleResource(id: String, at index: Int, extendRange: Bool) {
        if extendRange, let anchor = lastResourceSelectionIndex {
            let lower = min(anchor, index)
            let upper = max(anchor, index)
            for resource in resources[lower...upper] where !node.excludedResourceIDs.contains(resource.id) {
                node.excludedResourceIDs.append(resource.id)
            }
        } else if node.excludedResourceIDs.contains(id) {
            node.excludedResourceIDs.removeAll { $0 == id }
        } else {
            node.excludedResourceIDs.append(id)
        }
        lastResourceSelectionIndex = index
    }

    private func toggleAllResources() {
        let resourceIDs = Set(resources.map(\.id))
        if allResourcesSelected {
            node.excludedResourceIDs.removeAll { resourceIDs.contains($0) }
        } else {
            for id in resourceIDs where !node.excludedResourceIDs.contains(id) {
                node.excludedResourceIDs.append(id)
            }
        }
        lastResourceSelectionIndex = nil
    }
}

struct FrictionEditorMenu: View {
    @Binding var node: FrictionNode
    let onDelete: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorHeader("Friction", symbol: "triangle", onSave: onSave)
            fieldLabel("Type")
            Picker("Friction type", selection: frictionKind) {
                ForEach(FrictionKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()

            frictionSettings

            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete friction", systemImage: "trash")
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .graphMenuPanel(colorScheme: colorScheme)
    }

    @ViewBuilder
    private var frictionSettings: some View {
        switch node.friction {
        case .none:
            EmptyView()
        case .typedPhrase(let phrase):
            fieldLabel("Phrase")
            TextField("Commitment phrase", text: Binding(
                get: { phrase },
                set: { node.friction = .typedPhrase($0) }
            ))
            .textFieldStyle(.roundedBorder)
        case .countdown(let seconds):
            fieldLabel("Seconds")
            Stepper(value: Binding(
                get: { seconds },
                set: { node.friction = .countdown(seconds: max(1, $0)) }
            ), in: 1...300) {
                Text("\(seconds) seconds")
            }
        case .reasonPrompt(let prompt):
            fieldLabel("Prompt")
            TextField("What are you here to do?", text: Binding(
                get: { prompt },
                set: { node.friction = .reasonPrompt($0) }
            ))
            .textFieldStyle(.roundedBorder)
        case .taskChecklist(let tasks):
            fieldLabel("Tasks, one per line")
            TextEditor(text: Binding(
                get: { tasks.joined(separator: "\n") },
                set: { value in
                    node.friction = .taskChecklist(value.lines)
                }
            ))
            .font(.system(size: 12))
            .frame(height: 90)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(GraphTheme.stroke(colorScheme)))
        case .timeBudget(let minutes):
            fieldLabel("Minutes")
            Stepper(value: Binding(
                get: { minutes },
                set: { node.friction = .timeBudget(minutes: max(1, $0)) }
            ), in: 1...240) {
                Text("\(minutes) minutes")
            }
        }
    }

    private var frictionKind: Binding<FrictionKind> {
        Binding(
            get: { FrictionKind(node.friction) },
            set: { kind in node.friction = kind.defaultFriction }
        )
    }
}

private enum FrictionKind: CaseIterable {
    case typedPhrase
    case countdown
    case reasonPrompt
    case taskChecklist
    case timeBudget

    init(_ friction: Friction) {
        switch friction {
        case .none, .typedPhrase: self = .typedPhrase
        case .countdown: self = .countdown
        case .reasonPrompt: self = .reasonPrompt
        case .taskChecklist: self = .taskChecklist
        case .timeBudget: self = .timeBudget
        }
    }

    var title: String {
        switch self {
        case .typedPhrase: "Typed phrase"
        case .countdown: "Countdown"
        case .reasonPrompt: "Write a reason"
        case .taskChecklist: "Task checklist"
        case .timeBudget: "Time budget"
        }
    }

    var defaultFriction: Friction {
        switch self {
        case .typedPhrase: .typedPhrase("I want to do this right now")
        case .countdown: .countdown(seconds: 10)
        case .reasonPrompt: .reasonPrompt("What are you here to do?")
        case .taskChecklist: .taskChecklist(["Complete the task"])
        case .timeBudget: .timeBudget(minutes: 10)
        }
    }
}

private struct RestrictionResource: Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

private func editorHeader(
    _ title: String,
    symbol: String,
    onSave: @escaping () -> Void
) -> some View {
    HStack {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button(action: onSave) {
            Text("SAVE (S)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.green.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Save and close this editor (S)")
    }
}

private func fieldLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(.secondary)
}

private extension String {
    var lines: [String] {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
