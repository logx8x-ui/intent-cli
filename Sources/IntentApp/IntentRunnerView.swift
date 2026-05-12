import AppKit
import SwiftUI
import IntentCore

struct IntentRunnerView: View {
    @EnvironmentObject private var model: IntentAppModel
    @State private var menu = IntentionRunnerMenu(intentions: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            switch menu.screen {
            case .folders:
                optionList(
                    title: "Choose a folder",
                    rows: menu.folderOptions.enumerated().map { index, folder in
                        RunnerRow(number: index + 1, title: folder.name, subtitle: "\(folder.intentions.count) intentions")
                    }
                )

            case .intentions(let folder):
                optionList(
                    title: folder,
                    rows: menu.intentionOptions.enumerated().map { index, intention in
                        RunnerRow(number: index + 1, title: intention.name, subtitle: intention.folder, icon: intention.icon, colorHex: intention.colorHex)
                    }
                )
            }

            footer
        }
        .padding(22)
        .frame(width: 520)
        .background(AnkiTheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AnkiTheme.stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            RunnerKeyCapture { input in
                handle(input)
            }
        )
        .onAppear {
            menu = IntentionRunnerMenu(intentions: model.intentions)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(AnkiTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Intent Runner")
                    .font(.title2.weight(.semibold))
                Text("Cmd+Shift+K opens this. Cmd+Shift+M ends a running intention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.isRunnerPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private func optionList(title: String, rows: [RunnerRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                Button {
                    handle("\(row.number)")
                } label: {
                    HStack(spacing: 12) {
                        Text("\(row.number)")
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(AnkiTheme.rowBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        if let icon = row.icon, let colorHex = row.colorHex {
                            Image(systemName: icon)
                                .foregroundStyle(Color(hex: colorHex))
                                .frame(width: 18)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.body.weight(.semibold))
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(AnkiTheme.rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Press a number to select")
            Spacer()
            Text("Esc/B = back")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func handle(_ input: String) {
        let action = menu.handle(input)
        switch action {
        case .none, .showFolders, .showIntentions:
            break
        case .start(let intentionID):
            model.isRunnerPresented = false
            DispatchQueue.main.async {
                model.requestStart(intentionID: intentionID)
            }
        }
    }
}

private struct RunnerRow: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let subtitle: String
    var icon: String?
    var colorHex: String?
}

private struct RunnerKeyCapture: NSViewRepresentable {
    let onKey: (String) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var onKey: ((String) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onKey?("\u{1B}")
                return
            }

            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
                onKey?(characters)
            }
        }
    }
}
