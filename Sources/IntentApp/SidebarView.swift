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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Intentions")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AnkiTheme.accent)
                Text("Deep Work Engine")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textCase(.uppercase)
                    .foregroundStyle(AnkiTheme.mutedText.opacity(0.65))
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 34)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groupedIntentions, id: \.0) { folder, intentions in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(folder)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .textCase(.uppercase)
                                .foregroundStyle(AnkiTheme.mutedText.opacity(0.65))
                                .padding(.horizontal, 22)

                            ForEach(intentions) { intention in
                                SidebarRow(
                                    intention: intention,
                                    isSelected: model.selectedID == intention.id
                                ) {
                                    model.selectedID = intention.id
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }

            Spacer(minLength: 0)

            Button {
                model.createIntention()
            } label: {
                Label("Create Intention", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AnkiTheme.accent)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)

            if let activeSessionName = model.activeSessionName {
                activeSession(activeSessionName)
            }
        }
        .background(AnkiTheme.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AnkiTheme.softStroke)
                .frame(width: 1)
        }
    }

    private func activeSession(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Active Intention")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(AnkiTheme.accent)
            Text(name)
                .font(.headline)
                .lineLimit(1)
            Text("Cmd+Shift+M to finish")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AnkiTheme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AnkiTheme.softStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

private struct SidebarRow: View {
    let intention: Intention
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: intention.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: intention.colorHex))
                    .frame(width: 22)
                Text(intention.name)
                    .lineLimit(1)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isSelected ? Color(hex: intention.colorHex).opacity(0.18) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Color(hex: intention.colorHex) : .clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
