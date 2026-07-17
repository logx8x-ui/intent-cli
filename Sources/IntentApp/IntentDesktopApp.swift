import AppKit
import SwiftUI

final class IntentAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct IntentDesktopApp: App {
    @NSApplicationDelegateAdaptor(IntentAppDelegate.self) private var appDelegate
    @StateObject private var model: IntentAppModel
    @AppStorage("intentAppearance") private var appearance = "dark"
    private let overlayController: OverlayWindowController
    private let hotKeyManager: GlobalHotKeyManager

    init() {
        let appModel = IntentAppModel()
        let controller = OverlayWindowController(model: appModel)
        let shouldShowFirstRunGuide = !UserDefaults.standard.bool(forKey: "intentDidCompleteOnboarding")
        appModel.overlayPresenter = controller
        _model = StateObject(wrappedValue: appModel)
        overlayController = controller
        hotKeyManager = GlobalHotKeyManager {
            Task { @MainActor in
                appModel.toggleOverlay()
            }
        }

        Task { @MainActor in
            appModel.load()
            if shouldShowFirstRunGuide {
                controller.showOverlay(animated: false)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Open Intent") {
                model.showOverlay()
            }
            .keyboardShortcut("o")

            if let activeSessionName = model.activeSessionName {
                Divider()
                Text("Active: \(activeSessionName)")
                Button("End Intention") {
                    model.endActiveSession()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            Divider()
            Menu("Appearance") {
                Button("Dark") { appearance = "dark" }
                Button("Light") { appearance = "light" }
            }
            Divider()
            Button("Quit Intent") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label("Intent", systemImage: model.activeSessionName == nil ? "scope" : "scope.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}
