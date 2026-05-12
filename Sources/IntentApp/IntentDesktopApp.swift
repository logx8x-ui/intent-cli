import SwiftUI

@main
struct IntentDesktopApp: App {
    @StateObject private var model: IntentAppModel
    @AppStorage("intentAppearance") private var appearance = "dark"
    private let hotKeyManager: GlobalHotKeyManager

    private var preferredColorScheme: ColorScheme? {
        appearance == "light" ? .light : .dark
    }

    init() {
        let appModel = IntentAppModel()
        _model = StateObject(wrappedValue: appModel)
        hotKeyManager = GlobalHotKeyManager {
            Task { @MainActor in
                appModel.showRunner()
            }
        }
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
