import SwiftUI

struct IntentBrowserSetupView: View {
    let profiles: () -> [IntentLocalBrowserProfile]
    let preferredBrowser: IntentSetupBrowser?
    let configuration: IntentBrowserSetupReleaseConfiguration
    let openProfile: (IntentLocalBrowserProfile, String) -> String?
    let close: () -> Void
    @State private var discovered: [IntentLocalBrowserProfile] = []
    @State private var queue = IntentBrowserProfileSetupQueue()
    @State private var notice: String?

    private var selected: [IntentLocalBrowserProfile] { queue.selected(from: discovered) }
    private var next: IntentLocalBrowserProfile? { queue.next(from: discovered) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your browser profiles").font(.system(size: 24, weight: .semibold))
                Text("Extensions belong to browser profiles, rather than the accounts signed into websites. Choose the profiles you use with Intent.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Select all") { queue.selectAll(discovered) }
                Button("Clear selection") { queue.clear() }
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
                                ForEach(rows) { profile in
                                    profileRow(profile)
                                }
                            }
                        }
                    }
                    if discovered.isEmpty {
                        Text("No existing Chrome or Firefox profiles were found. Open the browser you want to use once, then choose Refresh.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 22)
                    }
                }.padding(.vertical, 2)
            }
            Text("Your browser asks you to confirm each installation. We’ll open setup for your selected profiles one at a time. Intent checks the connection when you return; an installed extension alone isn’t a connection check.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if configuration.development {
                Text("Private development build: Chrome uses Load unpacked and Firefox uses a temporary add-on. Those steps are excluded from the launch version.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(notice)
            }
            HStack {
                Text("\(selected.count) profile\(selected.count == 1 ? "" : "s") selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                Button(queue.attempted.isEmpty ? "Start setup" : "Next profile") { if let next { performSetup(next) } }
                    .buttonStyle(.borderedProminent).disabled(next == nil)
            }
        }
        .padding(24).frame(minWidth: 620, idealWidth: 640, minHeight: 540)
        .onAppear {
            refresh()
            queue = IntentBrowserProfileSetupQueue(profiles: discovered, preferredBrowser: preferredBrowser)
        }
    }

    private func profileRow(_ profile: IntentLocalBrowserProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(get: { queue.selection.contains(profile.id) }, set: { selected in
                queue.setSelected(profile.id, selected: selected)
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.body.weight(.medium)).lineLimit(1)
                    if let account = profile.account { Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(profile.guardStatus.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }.toggleStyle(.checkbox)
            Spacer(minLength: 8)
            Button(profile.guardStatus.isMatching ? "Open" : "Set up") { performSetup(profile) }
                .disabled(!queue.selection.contains(profile.id))
        }
        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func refresh() {
        discovered = profiles()
        queue.refresh(discovered)
    }

    private func performSetup(_ profile: IntentLocalBrowserProfile) {
        switch configuration.destination(for: profile) {
        case .pending(let message): notice = message
        case .ready(let destination):
            notice = openProfile(profile, destination)
        }
        queue.didAttempt(profile.id)
    }
}
