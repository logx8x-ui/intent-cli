import AppKit
import SwiftUI
import IntentCore
import UniformTypeIdentifiers

struct IntentionEditorMenu: View {
    @Binding var intention: Intention
    let catalog: [InstalledApp]
    let onDelete: () -> Void
    let onAddRestriction: () -> Void
    let onAddFriction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var appQuery = ""
    @State private var websiteDrafts: [String: String] = [:]
    @State private var isIconDropTarget = false
    @State private var iconImportError: String?
    @State private var lastQuickAppIndex: Int?
    @State private var lastQuickWebsiteIndexByBrowser: [String: Int] = [:]
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

    private var quickApps: [InstalledApp] {
        let preferredBundleIdentifiers = [
            "com.apple.MobileSMS",
            "org.mozilla.firefox",
            "com.google.Chrome",
            "com.apple.mail",
            "com.apple.iCal",
            "com.apple.Notes",
            "com.apple.reminders",
            "com.openai.codex",
            "com.spotify.client",
            "net.ankiweb.dtop",
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "com.rstudio.desktop",
            "io.remnote",
            "com.remnote.desktop",
            "net.whatsapp.WhatsApp",
            "com.hnc.Discord",
            "com.tinyspeck.slackmacgap",
            "us.zoom.xos"
        ]
        let appsByIdentifier = Dictionary(
            catalog.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return preferredBundleIdentifiers.compactMap { appsByIdentifier[$0] }
    }

    private var quickPickColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 38), spacing: 8),
            count: 6
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                editorHeader("Intention", symbol: "square")

                fieldLabel("Name")
                TextField("Intention name", text: $intention.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)

                intentionArtworkEditor

                fieldLabel("Allowed apps")
                tokenFlow

                TextField("Search installed apps", text: $appQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFirstMatch)

                quickAppGrid

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
                fieldLabel("When finished")
                Toggle(
                    "Close session resources",
                    isOn: $intention.closeSessionResourcesOnFinish
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
                Text("Closes this intention's allowed apps and website tabs when it ends.")
                    .font(.caption)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

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

    private var intentionArtworkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Intention artwork")
            Picker(
                "Intention artwork",
                selection: Binding(
                    get: { intention.usesCustomIcon ? "icon" : "apps" },
                    set: { intention.usesCustomIcon = $0 == "icon" }
                )
            ) {
                Text("App logos").tag("apps")
                Text("One icon").tag("icon")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if intention.usesCustomIcon {
                HStack(spacing: 7) {
                    ForEach(["target", "scope", "sparkles", "bolt.fill", "brain.head.profile", "graduationcap.fill"], id: \.self) { symbol in
                        Button {
                            intention.icon = symbol
                            intention.customIconData = nil
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 34, height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(GraphTheme.surface(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    intention.customIconData == nil && intention.icon == symbol
                                        ? GraphTheme.editBlue
                                        : GraphTheme.stroke(colorScheme),
                                    lineWidth: intention.customIconData == nil && intention.icon == symbol ? 1.5 : 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        chooseIconImage()
                    } label: {
                        Label("Choose image", systemImage: "photo")
                    }
                    Button {
                        pasteIconImage()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                    Text("Drop an image here")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(isIconDropTarget ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(GraphTheme.surface(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isIconDropTarget ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrop(
                    of: [UTType.fileURL.identifier, UTType.image.identifier],
                    isTargeted: $isIconDropTarget,
                    perform: importIconFromDrop
                )

                if let iconImportError {
                    Text(iconImportError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
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
    private var quickAppGrid: some View {
        if !quickApps.isEmpty {
            LazyVGrid(
                columns: quickPickColumns,
                spacing: 8
            ) {
                ForEach(Array(quickApps.enumerated()), id: \.element.id) { index, app in
                    let isSelected = intention.allowedApps.contains {
                        $0.bundleIdentifier == app.bundleIdentifier
                    }
                    Button {
                        handleQuickAppClick(app, at: index)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, GraphTheme.editBlue)
                                    .offset(x: 3, y: -3)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .contentShape(Rectangle())
                        .background(GraphTheme.surface(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(
                                    isSelected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help(app.name)
                    .accessibilityLabel("\(isSelected ? "Remove" : "Add") \(app.name)")
                }
            }
            .padding(.vertical, 2)
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

                    quickWebsiteGrid(for: browser)
                }
            }
        }
    }

    private func quickWebsiteGrid(for browser: AllowedApp) -> some View {
        LazyVGrid(
            columns: quickPickColumns,
            spacing: 8
        ) {
            ForEach(Array(QuickWebsitePreset.common.enumerated()), id: \.element.id) { index, preset in
                let website = AllowedWebsite(
                    preset.value,
                    browserBundleIdentifier: browser.bundleIdentifier
                )
                let isSelected = intention.allowedWebsites.contains { $0.id == website.id }
                Button {
                    handleQuickWebsiteClick(
                        preset,
                        for: browser,
                        at: index
                    )
                } label: {
                    ZStack(alignment: .topTrailing) {
                        websiteIcon(named: preset.iconResource)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, GraphTheme.editBlue)
                                .offset(x: 3, y: -3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .contentShape(Rectangle())
                    .background(GraphTheme.surface(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                isSelected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel("\(isSelected ? "Remove" : "Add") \(preset.name)")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func websiteIcon(named resourceName: String) -> some View {
        if let image = WebsiteIconLibrary.image(named: resourceName) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GraphTheme.muted(colorScheme))
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
        guard !intention.allowedApps.contains(where: {
            $0.bundleIdentifier == app.bundleIdentifier
        }) else {
            return
        }
        intention.allowedApps.append(.init(name: app.name, bundleIdentifier: app.bundleIdentifier))
        appQuery = ""
    }

    private func handleQuickAppClick(_ app: InstalledApp, at index: Int) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = lastQuickAppIndex {
            let range = min(anchor, index)...max(anchor, index)
            for quickApp in quickApps[range] {
                add(quickApp)
            }
        } else if intention.allowedApps.contains(where: {
            $0.bundleIdentifier == app.bundleIdentifier
        }) {
            remove(.init(name: app.name, bundleIdentifier: app.bundleIdentifier))
        } else {
            add(app)
        }
        lastQuickAppIndex = index
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

    private func handleQuickWebsiteClick(
        _ preset: QuickWebsitePreset,
        for browser: AllowedApp,
        at index: Int
    ) {
        let modifiers = NSEvent.modifierFlags
        let anchor = lastQuickWebsiteIndexByBrowser[browser.bundleIdentifier]
        if modifiers.contains(.shift), let anchor {
            let range = min(anchor, index)...max(anchor, index)
            for quickWebsite in QuickWebsitePreset.common[range] {
                addQuickWebsite(quickWebsite, for: browser)
            }
        } else {
            let website = AllowedWebsite(
                preset.value,
                browserBundleIdentifier: browser.bundleIdentifier
            )
            if intention.allowedWebsites.contains(where: { $0.id == website.id }) {
                remove(website)
            } else {
                addQuickWebsite(preset, for: browser)
            }
        }
        lastQuickWebsiteIndexByBrowser[browser.bundleIdentifier] = index
    }

    private func addQuickWebsite(_ preset: QuickWebsitePreset, for browser: AllowedApp) {
        let website = AllowedWebsite(
            preset.value,
            browserBundleIdentifier: browser.bundleIdentifier
        )
        guard !intention.allowedWebsites.contains(where: { $0.id == website.id }) else {
            return
        }
        intention.allowedWebsites.append(website)
    }

    private func remove(_ website: AllowedWebsite) {
        intention.allowedWebsites.removeAll { $0.id == website.id }
        intention.restrictionNodes = intention.restrictionNodes.map { node in
            var updated = node
            updated.excludedResourceIDs.removeAll { $0 == website.resourceID }
            return updated
        }
    }

    private func chooseIconImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            iconImportError = "That file is not a readable image."
            return
        }
        saveIconImage(image)
    }

    private func pasteIconImage() {
        guard let image = NSImage(pasteboard: .general) else {
            iconImportError = "Copy an image first."
            return
        }
        saveIconImage(image)
    }

    private func importIconFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let raw = String(data: data, encoding: .utf8),
                      let url = URL(string: raw),
                      let image = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { saveIconImage(image) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { saveIconImage(image) }
        }
        return true
    }

    private func saveIconImage(_ image: NSImage) {
        let target = NSImage(size: NSSize(width: 512, height: 512))
        target.lockFocus()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 512, height: 512),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            iconImportError = "Intent could not prepare that image."
            return
        }
        intention.customIconData = png
        intention.usesCustomIcon = true
        iconImportError = nil
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

private struct QuickWebsitePreset: Identifiable {
    let name: String
    let value: String
    let iconResource: String

    var id: String { value }

    static let common = [
        QuickWebsitePreset(name: "YouTube", value: "youtube.com", iconResource: "youtube"),
        QuickWebsitePreset(name: "Gmail", value: "mail.google.com", iconResource: "gmail"),
        QuickWebsitePreset(name: "Instagram", value: "instagram.com", iconResource: "instagram"),
        QuickWebsitePreset(name: "GitHub", value: "github.com", iconResource: "github"),
        QuickWebsitePreset(name: "ChatGPT", value: "chatgpt.com", iconResource: "chatgpt"),
        QuickWebsitePreset(name: "Notion", value: "notion.so", iconResource: "notion"),
        QuickWebsitePreset(name: "Reddit", value: "reddit.com", iconResource: "reddit"),
        QuickWebsitePreset(name: "LinkedIn", value: "linkedin.com", iconResource: "linkedin"),
        QuickWebsitePreset(name: "X", value: "x.com", iconResource: "x"),
        QuickWebsitePreset(name: "Google Calendar", value: "calendar.google.com", iconResource: "google-calendar"),
        QuickWebsitePreset(name: "Google Drive", value: "drive.google.com", iconResource: "google-drive"),
        QuickWebsitePreset(name: "Spotify", value: "open.spotify.com", iconResource: "spotify")
    ]
}

private enum WebsiteIconLibrary {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let image = cache[name] {
            return image
        }
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "WebsiteIcons"
        ) ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache[name] = image
        return image
    }
}

struct RestrictionEditorMenu: View {
    @Binding var node: RestrictionNode
    let intention: Intention
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var lastResourceSelectionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorHeader("Restriction", symbol: "circle")

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
                Toggle(
                    "Keep intention running until timer ends",
                    isOn: Binding(
                        get: { node.locksSessionUntilTimerEnds ?? true },
                        set: { node.locksSessionUntilTimerEnds = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            case .endTime:
                Toggle(
                    "Use preset end time",
                    isOn: Binding(
                        get: { node.usesPresetEndTime ?? false },
                        set: { enabled in
                            node.usesPresetEndTime = enabled
                            if enabled {
                                setDefaultEndTimeIfNeeded()
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
                if node.usesPresetEndTime ?? false {
                    fieldLabel("Preset finish time")
                    LocalTimeEditor(selection: endTimeSelection)
                    Text("Uses this Mac's local time. If it has passed today, Intent uses tomorrow.")
                        .font(.caption)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                } else {
                    Text("Choose the finish time each time this intention starts.")
                        .font(.caption)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                Toggle(
                    "Keep intention running until end time",
                    isOn: Binding(
                        get: { node.locksSessionUntilTimerEnds ?? true },
                        set: { node.locksSessionUntilTimerEnds = $0 }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            }

            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete restriction", systemImage: "trash")
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .graphMenuPanel(colorScheme: colorScheme)
        .onChange(of: node.kind) { kind in
            switch kind {
            case .timer:
                if node.durationMinutes == nil { node.durationMinutes = 25 }
                if node.locksSessionUntilTimerEnds == nil {
                    node.locksSessionUntilTimerEnds = true
                }
            case .endTime:
                setDefaultEndTimeIfNeeded()
            default:
                break
            }
        }
        .onAppear {
            if node.kind == .endTime {
                setDefaultEndTimeIfNeeded()
            }
        }
    }

    private var endTimeSelection: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.autoupdatingCurrent
                return calendar.date(
                    bySettingHour: min(max(node.endTimeHour ?? 17, 0), 23),
                    minute: min(max(node.endTimeMinute ?? 0, 0), 59),
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                node.endTimeHour = components.hour
                node.endTimeMinute = components.minute
            }
        )
    }

    private func setDefaultEndTimeIfNeeded() {
        if node.usesPresetEndTime == nil {
            node.usesPresetEndTime = false
        }
        if node.endTimeHour == nil || node.endTimeMinute == nil {
            let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: Date())
            node.endTimeHour = components.hour
            node.endTimeMinute = components.minute
        }
        if node.locksSessionUntilTimerEnds == nil {
            node.locksSessionUntilTimerEnds = true
        }
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
            HourMinuteFields(totalMinutes: Binding(
                get: { max(1, node.durationMinutes ?? defaultMinutes) },
                set: { node.durationMinutes = max(1, $0) }
            ))
            Text(detail)
                .font(.caption)
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .onAppear {
            if node.durationMinutes == nil {
                node.durationMinutes = defaultMinutes
            }
            if node.kind == .timer, node.locksSessionUntilTimerEnds == nil {
                node.locksSessionUntilTimerEnds = true
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorHeader("Friction", symbol: "triangle")
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
            fieldLabel("Time budget")
            HourMinuteFields(totalMinutes: Binding(
                get: { minutes },
                set: { node.friction = .timeBudget(minutes: max(1, $0)) }
            ))
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
    symbol: String
) -> some View {
    HStack {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
        Spacer()
    }
}

private func fieldLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(.secondary)
}

private struct HourMinuteFields: View {
    @Binding var totalMinutes: Int

    var body: some View {
        HStack(spacing: 10) {
            durationField(
                label: "Hours",
                value: Binding(
                    get: { max(0, totalMinutes) / 60 },
                    set: { hours in
                        totalMinutes = max(1, min(999, hours) * 60 + max(0, totalMinutes) % 60)
                    }
                )
            )
            durationField(
                label: "Minutes",
                value: Binding(
                    get: { max(0, totalMinutes) % 60 },
                    set: { minutes in
                        totalMinutes = max(1, (max(0, totalMinutes) / 60) * 60 + min(59, max(0, minutes)))
                    }
                )
            )
        }
    }

    private func durationField(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 86)
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
