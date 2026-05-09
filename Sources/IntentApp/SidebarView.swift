import SwiftUI
import IntentCore

struct SidebarView: View {
    @EnvironmentObject private var model: IntentAppModel

    var groupedIntentions: [(String, [Intention])] {
        Dictionary(grouping: model.intentions, by: \.folder)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(groupedIntentions, id: \.0) { folder, intentions in
                Section(folder) {
                    ForEach(intentions) { intention in
                        Label(intention.name, systemImage: intention.icon)
                            .tag(Optional(intention.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let activeSessionName = model.activeSessionName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(activeSessionName)
                        .font(.headline)
                    Text("Press Cmd+Shift+M to finish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }
}
