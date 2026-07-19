import AppKit
import SwiftUI

final class IntentAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        IntentRuntime.shared.start()
    }
}

@main
struct IntentDesktopApp: App {
    @NSApplicationDelegateAdaptor(IntentAppDelegate.self) private var appDelegate
    @StateObject private var model: IntentAppModel
    @AppStorage("intentAppearance") private var appearance = "dark"

    init() {
        _model = StateObject(wrappedValue: IntentRuntime.shared.model)
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

@MainActor
final class IntentRuntime {
    static let shared = IntentRuntime()

    let model: IntentAppModel
    private let overlayController: OverlayWindowController
    private var hotKeyManager: GlobalHotKeyManager?
    private var showOverlayObserver: NSObjectProtocol?
    private var hasStarted = false

    init() {
        let model = IntentAppModel()
        let controller = OverlayWindowController(model: model)
        model.overlayPresenter = controller

        self.model = model
        overlayController = controller
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        hotKeyManager = GlobalHotKeyManager {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                IntentRuntime.shared.model.toggleOverlay()
            }
        }
        showOverlayObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.loganmondi.intent.showOverlay"),
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                IntentRuntime.shared.model.showOverlay()
            }
        }

        model.load()
        if !UserDefaults.standard.bool(forKey: "intentDidCompleteOnboarding") {
            overlayController.showOverlay(animated: false)
        }
    }

    func updateOverlayShortcut(_ candidate: OverlayShortcut) -> String? {
        if let message = OverlayShortcutConflictChecker.validationMessage(for: candidate) {
            return message
        }
        guard let hotKeyManager else {
            return "Intent's shortcut service is not ready yet."
        }

        let status = hotKeyManager.update(to: candidate)
        guard status == noErr else {
            return "\(candidate.displayName) is already being used by macOS or another app."
        }

        OverlayShortcutStore.save(candidate)
        return nil
    }
}
