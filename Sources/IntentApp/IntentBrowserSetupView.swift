import SwiftUI

struct IntentBrowserSetupView: View {
    let profiles: () -> [IntentLocalBrowserProfile]
    let preferredBrowser: IntentSetupBrowser?
    let configuration: IntentBrowserSetupReleaseConfiguration
    let openProfile: (IntentLocalBrowserProfile, String) -> String?
    let openBrowser: (IntentSetupBrowser) -> Void
    let firefoxOwner: (URL) -> Int32?
    let verificationRoot: URL
    let close: () -> Void
    @State private var discovered: [IntentLocalBrowserProfile] = []
    @State private var preferences = IntentBrowserOnboardingPreferences.load()
    @State private var selection = Set<String>()
    @State private var awaitingInstallation = Set<String>()
    @State private var notice: String?
    @StateObject private var connection = IntentBrowserSetupConnectionMonitor()
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selected: [IntentLocalBrowserProfile] { discovered.filter { selection.contains($0.id) } }
    private var next: IntentLocalBrowserProfile? { selected.first { !connection.connectedProfileIDs.contains($0.id) } }
    private var missingSelections: Set<String> { selection.subtracting(Set(discovered.map(\.id))) }
    private var missingBrowsers: [IntentSetupBrowser] { preferences.missingBrowsers(profiles: discovered) }
    private var allConnected: Bool { preferences.canComplete(profiles: discovered, connected: connection.connectedProfileIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your browsers").font(.system(size: 24, weight: .semibold))
                Text("Choose the profiles you use. A browser profile can contain several signed-in accounts; each selected profile needs Browser Guard once.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Select all") { selection.formUnion(discovered.map(\.id)); saveSelection(); refresh() }
                Button("Clear selection") { selection = []; saveSelection(); refresh() }
                Spacer()
                Button("Refresh") { refresh() }
            }.buttonStyle(.borderless)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(IntentSetupBrowser.allCases) { browser in
                        let rows = discovered.filter { $0.browser == browser }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(browser.name).font(.headline)
                                ForEach(rows) { profile in profileRow(profile) }
                            }
                        }
                    }
                    ForEach(missingSelections.sorted(), id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected profile unavailable").font(.headline)
                                Text("Open this profile and retry. It stays selected until you remove it.").font(.caption).foregroundStyle(.secondary)
                                Text(URL(fileURLWithPath: String(id.split(separator: "|", maxSplits: 1).last ?? "")).lastPathComponent).font(.caption)
                            }
                            Spacer()
                            Button("Remove") { selection.remove(id); saveSelection(); refresh() }
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(missingBrowsers) { browser in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(browser.name) setup is still needed").font(.headline)
                            Text("You chose \(browser.name), but its profiles are not available yet. Open it once, then return here.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Open \(browser.name)") { openBrowser(browser) }
                                if preferences.browsers == .both {
                                    Button("Continue without \(browser.name)") {
                                        preferences.browsers = browser == .chrome ? .firefox : .chrome
                                        selection = Set(selection.filter { !$0.hasPrefix(browser.rawValue + "|") })
                                        saveSelection(); refresh()
                                    }
                                }
                            }
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(preferences.browsersNeedingSelection.filter { !missingBrowsers.contains($0) }) { browser in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a \(browser.name) profile").font(.headline)
                            Text("\(browser.name) is available now. Choose its profiles above before completing your browser setup.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Select \(browser.name) profiles") {
                                    selection.formUnion(discovered.filter { $0.browser == browser }.map(\.id))
                                    saveSelection(); refresh()
                                }
                                if preferences.browsers == .both {
                                    Button("Continue without \(browser.name)") {
                                        preferences.browsers = browser == .chrome ? .firefox : .chrome
                                        saveSelection(); refresh()
                                    }
                                }
                            }
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if discovered.isEmpty {
                        Text("Open Chrome or Firefox once, then return here. Your browser profiles will appear automatically.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 22)
                    }
                }.padding(.vertical, 2)
            }
            Text("Approve your browser’s extension prompt, then return here. Intent checks each selected profile’s connection automatically. You can pause and return without repeating completed steps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if configuration.development {
                Text("Private development build: Chrome uses Load unpacked and Firefox uses a temporary add-on. The launch version uses permanent extensions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(notice)
            }
            HStack {
                Text("\(selection.intersection(connection.connectedProfileIDs).count) of \(selection.count) profiles connected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Continue later") { saveSelection(markIncomplete: false); close() }
                if allConnected {
                    Button("Done") {
                        guard allConnected else { refresh(); return }
                        preferences.completed = true; preferences.save(); close()
                    }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect next profile") { if let next { performSetup(next) } }
                        .buttonStyle(.borderedProminent).disabled(next == nil)
                }
            }
            if selection.isEmpty {
                Button("Use app windows only for now") {
                    preferences.selectedProfileIDs = []; preferences.completed = true; preferences.save(); close()
                }.buttonStyle(.plain).font(.caption)
            }
        }
        .padding(24).frame(minWidth: 620, idealWidth: 640, minHeight: 540)
        .onAppear {
            preferences = .load()
            discovered = profiles()
            selection = preferences.initialSelection(profiles: discovered, preferredBrowser: preferredBrowser)
            saveSelection(markIncomplete: false)
            refresh()
        }
        .onReceive(refreshTimer) { _ in refresh() }
        .onDisappear { connection.cancel() }
    }

    private func profileRow(_ profile: IntentLocalBrowserProfile) -> some View {
        let connected = connection.connectedProfileIDs.contains(profile.id)
        return HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(get: { selection.contains(profile.id) }, set: { selected in
                if selected { selection.insert(profile.id) } else { selection.remove(profile.id) }
                saveSelection(); refresh()
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.body.weight(.medium)).lineLimit(1)
                    if let account = profile.account { Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(connected ? "Connected to Intent" : profile.guardStatus.label)
                        .font(.caption).foregroundStyle(connected ? Color.green : Color.secondary).lineLimit(2)
                }
            }.toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Connection verified") }
            else {
                Button(profile.guardStatus.isMatching ? "Check connection" : "Set up") { performSetup(profile) }
                    .disabled(!selection.contains(profile.id))
            }
        }
        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func saveSelection(markIncomplete: Bool = true) {
        if markIncomplete || preferences.selectedProfileIDs != nil || !selection.isEmpty {
            preferences.selectedProfileIDs = selection
        }
        if markIncomplete { preferences.completed = false }
        preferences.save()
    }
    private func refresh() {
        discovered = profiles()
        if preferences.selectedProfileIDs == nil { selection = preferences.initialSelection(profiles: discovered, preferredBrowser: preferredBrowser) }
        saveSelection(markIncomplete: false)
        for profile in selected where profile.guardStatus.isMatching && awaitingInstallation.remove(profile.id) != nil {
            beginVerification(profile)
        }
        connection.refresh(profiles: selected, preferences: preferences, requiredVersion: configuration.requiredVersion, firefoxOwner: firefoxOwner) { id, identity in
            preferences.profileIdentities[id] = identity
            preferences.save()
        }
    }
    private func beginVerification(_ profile: IntentLocalBrowserProfile) {
        do {
            let page = try connection.prepareVerification(for: profile, root: verificationRoot)
            preferences.profileIdentities.removeValue(forKey: profile.id)
            preferences.completed = false; preferences.save()
            notice = openProfile(profile, page.absoluteString)
        } catch {
            notice = "The connection check couldn’t open. Your browser profiles are unchanged; choose Check connection to retry."
        }
    }
    private func performSetup(_ profile: IntentLocalBrowserProfile) {
        if profile.guardStatus.isMatching { beginVerification(profile); refresh(); return }
        switch configuration.destination(for: profile) {
        case .pending(let message): notice = message
        case .ready(let destination):
            awaitingInstallation.insert(profile.id)
            notice = openProfile(profile, destination)
        }
    }
}
