import SwiftUI
import IntentCore

struct ContentView: View {
    @EnvironmentObject private var model: IntentAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let intention = model.selectedIntention {
                IntentionDetailView(intention: intention)
            } else {
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
                .background(AnkiTheme.detailBackground)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.createIntention()
                } label: {
                    Label("New", systemImage: "plus")
                }

                if let intention = model.selectedIntention {
                    Button {
                        model.requestStart(intention)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(item: $model.pendingFriction) { pending in
            FrictionSheet(pending: pending)
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
}
