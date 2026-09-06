import SwiftUI
import IntentCore

enum PromptAutocompleteWebsiteSource {
    static let supportedBrowserBundleIdentifiers = [
        "org.mozilla.firefox",
        "com.google.Chrome"
    ]

    static func load(intentions: [Intention]) -> [String: [PurposeKnownWebsite]] {
        Dictionary(uniqueKeysWithValues: supportedBrowserBundleIdentifiers.map { browserID in
            var result = PurposeWebsiteHistoryStore.frequentKnownWebsites(
                browserBundleIdentifier: browserID
            )
            result.append(contentsOf: intentions.flatMap { intention in
                intention.websites(for: browserID).map { website in
                    PurposeKnownWebsite(
                        name: website.displayName.capitalized,
                        value: website.value,
                        aliases: [website.displayName]
                    )
                }
            })
            result.append(contentsOf: PurposeWebsiteCatalog.common)

            var seen = Set<String>()
            return (browserID, result.filter { seen.insert($0.value).inserted })
        })
    }
}

struct PromptAutocompleteMenu: View {
    let state: PromptAutocompleteState
    let selectedIndex: Int
    let colorScheme: ColorScheme
    let accent: Color
    let catalog: [InstalledApp]
    let intentions: [Intention]
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(header)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                Spacer()
                Text("↑↓  TAB")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .opacity(0.72)
            }
            .foregroundStyle(GraphTheme.muted(colorScheme))
            .padding(.horizontal, 10)
            .padding(.top, 7)

            ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 9) {
                        candidateIcon(candidate)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(candidate.subtitle)
                                .font(.system(size: 9.5, weight: .medium))
                                .opacity(0.68)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                    }
                    .foregroundStyle(index == selectedIndex ? Color.white : GraphTheme.text(colorScheme))
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(
                        index == selectedIndex ? accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(maxWidth: 460, alignment: .leading)
        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.58), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.24), radius: 16, y: 8)
    }

    private var header: String {
        guard let first = state.candidates.first else { return "SUGGESTIONS" }
        switch first.kind {
        case .intention:
            return "SAVED INTENTIONS"
        case .application:
            return "APPLICATIONS"
        case .website(let browserBundleIdentifier, _):
            let browserName = catalog.first {
                $0.bundleIdentifier == browserBundleIdentifier
            }?.name ?? "BROWSER"
            return "WEBSITES FOR \(browserName.uppercased())"
        }
    }

    @ViewBuilder
    private func candidateIcon(_ candidate: PromptAutocompleteCandidate) -> some View {
        switch candidate.kind {
        case .intention(let id):
            Image(systemName: intentions.first(where: { $0.id == id })?.icon ?? "scope")
                .font(.system(size: 13, weight: .semibold))
        case .application(let bundleIdentifier):
            if let app = catalog.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
            }
        case .website:
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
        }
    }
}
