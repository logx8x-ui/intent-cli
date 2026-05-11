import SwiftUI
import IntentCore

private let browserBundleIdentifiers = [
    "org.mozilla.firefox",
    "com.google.Chrome",
    "com.brave.Browser",
    "com.apple.Safari",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser"
]

struct AppSelectionEditor: View {
    let title: String
    @Binding var apps: [AllowedApp]
    let catalog: [InstalledApp]

    @State private var adding = false
    @State private var query = ""

    private var matches: [InstalledApp] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return catalog
            .filter { app in
                app.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil
                    && !apps.contains { $0.bundleIdentifier == app.bundleIdentifier }
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title) {
                adding.toggle()
                query = ""
            }

            FlowRows {
                ForEach(apps) { app in
                    Token(title: app.name, subtitle: app.bundleIdentifier) {
                        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
                    }
                }
            }

            if adding {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type an app name", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addFirstAppMatch)

                    if !matches.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(matches) { app in
                                Button {
                                    addApp(app)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 18, height: 18)
                                        Text(app.name)
                                        Spacer()
                                        Text(app.bundleIdentifier)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(AnkiTheme.rowBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
    }

    private func addApp(_ app: InstalledApp) {
        apps.append(AllowedApp(name: app.name, bundleIdentifier: app.bundleIdentifier))
        query = ""
        adding = false
    }

    private func addFirstAppMatch() {
        guard let exactOrFirst = matches.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) ?? matches.first else {
            return
        }
        addApp(exactOrFirst)
    }
}

struct WebsiteEditor: View {
    @Binding var websites: [AllowedWebsite]
    @State private var adding = false
    @State private var newWebsite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Allowed websites") {
                adding.toggle()
                newWebsite = ""
            }

            FlowRows {
                ForEach(websites) { website in
                    Token(title: website.displayName, subtitle: website.value) {
                        websites.removeAll { $0.value == website.value }
                    }
                }
            }

            if adding {
                HStack(spacing: 8) {
                    TextField("Paste a website", text: $newWebsite)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWebsite)
                    Button("Add", action: addWebsite)
                }
            }
        }
    }

    private func addWebsite() {
        let website = AllowedWebsite(newWebsite)
        guard !website.value.isEmpty,
              !websites.contains(where: { $0.value == website.value }) else {
            return
        }
        websites.append(website)
        newWebsite = ""
        adding = false
    }
}

struct StartupActionEditor: View {
    @Binding var actions: [StartupAction]
    @Binding var allowedApps: [AllowedApp]
    let catalog: [InstalledApp]

    @State private var addingApp = false
    @State private var appQuery = ""
    @State private var addingWebsite = false
    @State private var startupWebsite = ""
    @State private var selectedBrowserBundleIdentifier = ""

    private var browserApps: [AllowedApp] {
        allowedApps.filter { browserBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    private var appMatches: [InstalledApp] {
        guard !appQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return catalog.filter { app in
            app.name.range(of: appQuery, options: [.caseInsensitive, .anchored]) != nil
                && !actions.contains(.openApp(app.bundleIdentifier))
        }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Startup actions")
                    .font(.headline)
                Spacer()
                Button {
                    addingApp.toggle()
                    appQuery = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add a startup app")

                Button {
                    addingWebsite.toggle()
                    selectedBrowserBundleIdentifier = browserApps.first?.bundleIdentifier ?? ""
                    startupWebsite = ""
                } label: {
                    Image(systemName: "globe.badge.plus")
                }
                .disabled(browserApps.isEmpty)
                .help(browserApps.isEmpty ? "Allow a browser app before adding startup websites" : "Add a startup website")
            }

            VStack(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    StartupActionRow(action: action) {
                        actions.remove(at: index)
                    }
                }
            }

            if addingApp {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type an app name", text: $appQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addFirstStartupAppMatch)

                    ForEach(appMatches) { app in
                        Button {
                            addStartupApp(app)
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(app.name)
                                Spacer()
                                Text(app.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(AnkiTheme.rowBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if addingWebsite {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Browser", selection: $selectedBrowserBundleIdentifier) {
                        ForEach(browserApps) { app in
                            Text(app.name).tag(app.bundleIdentifier)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Paste startup website", text: $startupWebsite)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addStartupWebsite)
                        Button("Add", action: addStartupWebsite)
                    }
                }
            } else if browserApps.isEmpty {
                Text("Allow Firefox, Chrome, Brave, Safari, Edge, or Arc to add startup websites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func appendUnique(_ action: StartupAction) {
        guard !actions.contains(action) else { return }
        actions.append(action)
    }

    private func addStartupApp(_ app: InstalledApp) {
        if !allowedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            allowedApps.append(AllowedApp(name: app.name, bundleIdentifier: app.bundleIdentifier))
        }
        appendUnique(.openApp(app.bundleIdentifier))
        appQuery = ""
        addingApp = false
    }

    private func addFirstStartupAppMatch() {
        guard let exactOrFirst = appMatches.first(where: { $0.name.caseInsensitiveCompare(appQuery) == .orderedSame }) ?? appMatches.first else {
            return
        }
        addStartupApp(exactOrFirst)
    }

    private func addStartupWebsite() {
        let value = AllowedWebsite.normalized(startupWebsite)
        guard !value.isEmpty, !selectedBrowserBundleIdentifier.isEmpty else { return }
        let url = value.contains("://") ? value : "https://\(value)"
        appendUnique(.openURL(url, browserBundleIdentifier: selectedBrowserBundleIdentifier))
        startupWebsite = ""
        addingWebsite = false
    }
}

private struct StartupActionRow: View {
    let action: StartupAction
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(AnkiTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch action {
        case .openApp: "app"
        case .openURL: "globe"
        case .selectSideberyDataSciencePanel: "sidebar.leading"
        case .playSpotifyPlaylist: "music.note"
        }
    }

    private var title: String {
        switch action {
        case .openApp(let bundle): bundle
        case .openURL(let url, _): AllowedWebsite(url).displayName
        case .selectSideberyDataSciencePanel: "Sidebery data science panel"
        case .playSpotifyPlaylist: "Spotify playlist"
        }
    }

    private var subtitle: String {
        switch action {
        case .openApp: "Open application"
        case .openURL(let url, let browser): "\(url) via \(browser)"
        case .selectSideberyDataSciencePanel: "Firefox Sidebery"
        case .playSpotifyPlaylist(let uri): uri
        }
    }
}

struct SectionHeader: View {
    let title: String
    let add: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add")
        }
    }
}

struct Token: View {
    let title: String
    let subtitle: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AnkiTheme.rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct FlowRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
            content
        }
    }
}
