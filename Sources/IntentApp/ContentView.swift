import SwiftUI
import IntentCore

struct ContentView: View {
    @EnvironmentObject private var model: IntentAppModel
    @AppStorage("intentAppearance") private var appearance = "dark"

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 260)

            VStack(spacing: 0) {
                topBar

                ZStack(alignment: .topLeading) {
                    Circle()
                        .fill(AnkiTheme.accent.opacity(0.13))
                        .frame(width: 240, height: 240)
                        .blur(radius: 70)
                        .offset(x: 60, y: 8)

                    if let intention = model.selectedIntention {
                        IntentionDetailView(intention: intention)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AnkiTheme.detailBackground)
        .overlay(WindowBackgroundController(appearance: appearance).frame(width: 0, height: 0))
        .tint(AnkiTheme.accent)
        .sheet(item: $model.pendingFriction) { pending in
            FrictionSheet(pending: pending)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isRunnerPresented) {
            IntentRunnerView()
                .environmentObject(model)
        }
        .alert("Intent", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Text("Intent")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Spacer()

            Label("Cmd+Shift+K", systemImage: "command")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AnkiTheme.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AnkiTheme.rowBackground)
                .clipShape(Capsule())

            Picker("Appearance", selection: $appearance) {
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 122)

            Button {
                model.createIntention()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .help("Create intention")

            if let intention = model.selectedIntention {
                Button {
                    model.requestStart(intention)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: intention.colorHex))
                .help("Start intention")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(AnkiTheme.detailBackground.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AnkiTheme.softStroke)
                .frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "target")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No intentions")
                .font(.title2.weight(.semibold))
            Text("Create an intention to begin.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
