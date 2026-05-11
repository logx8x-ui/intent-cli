import SwiftUI

@main
struct IntentDesktopApp: App {
    @StateObject private var model = IntentAppModel()
    @AppStorage("intentAppearance") private var appearance = "dark"

    private var preferredColorScheme: ColorScheme? {
        appearance == "light" ? .light : .dark
    }

    var body: some Scene {
        WindowGroup("Intent") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(preferredColorScheme)
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
