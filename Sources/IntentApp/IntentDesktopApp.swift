import SwiftUI

@main
struct IntentDesktopApp: App {
    @StateObject private var model = IntentAppModel()

    var body: some Scene {
        WindowGroup("Intent") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    model.load()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Intention") {
                    model.createIntention()
                }
                .keyboardShortcut("n")
            }
        }
    }
}
