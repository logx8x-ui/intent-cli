import SwiftUI
import IntentCore

struct WebsiteFeatureControls: View {
    @Binding var policies: [String: WebsiteFeaturePolicy]?
    let sites: [FocusWebsite]
    let isNewIntention: Bool
    @State private var expanded: FocusWebsite?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sites) { site in
                let policy = policies?[site.rawValue]
                Button {
                    if policy == nil { policies = (policies ?? [:]).merging([site.rawValue: .init(site: site)]) { _, new in new } }
                    expanded = expanded == site ? nil : site
                } label: {
                    HStack {
                        Text("\(site.name) · \(policy?.summary(for: site) ?? "Configure website controls")")
                        Spacer(); Image(systemName: expanded == site ? "chevron.up" : "slider.horizontal.3")
                    }.font(.caption.weight(.medium)).padding(8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                if expanded == site {
                    Text("Allowed on this site").font(.subheadline.weight(.semibold))
                    if site == .youtube { Label("Normal videos", systemImage: "checkmark").font(.caption) }
                    ForEach(site.choices, id: \.id) { choice in
                        Toggle(choice.label, isOn: Binding(get: { policies?[site.rawValue]?.allowedFeatures.contains(choice.id) == true }, set: { allowed in
                            var value = policies?[site.rawValue] ?? .init(site: site)
                            if allowed { value.allowedFeatures.insert(choice.id) } else { value.allowedFeatures.remove(choice.id) }
                            var next = policies ?? [:]; next[site.rawValue] = value; policies = next
                        })).toggleStyle(.checkbox).font(.caption)
                    }
                    Text("Shared across this site's selected tabs in this intention.").font(.caption2).foregroundStyle(.secondary)
                    if policy?.isValid(for: site) == false { Text("Choose at least one allowed area.").font(.caption).foregroundStyle(.orange) }
                }
            }
        }.task(id: sites) { initialize() }
    }
    private func initialize() {
        guard isNewIntention else { return }
        var next = policies ?? [:]
        for site in sites where next[site.rawValue] == nil {
            next[site.rawValue] = .init(site: site)
            if expanded == nil { expanded = site }
        }
        if next != (policies ?? [:]) { policies = next }
    }
}
