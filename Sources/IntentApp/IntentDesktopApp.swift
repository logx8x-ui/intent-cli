import AppKit
import SwiftUI

final class IntentAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: IntentStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        IntentRuntime.shared.start()
        statusItemController = IntentStatusItemController(
            model: IntentRuntime.shared.model,
            updateManager: IntentUpdateManager.shared
        )
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.title == "Intent Settings" }
                .forEach { $0.close() }
        }
    }
}

@main
struct IntentDesktopApp: App {
    @NSApplicationDelegateAdaptor(IntentAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class IntentStatusItemController: NSObject {
    private let model: IntentAppModel
    private let updateManager: IntentUpdateManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(model: IntentAppModel, updateManager: IntentUpdateManager) {
        self.model = model
        self.updateManager = updateManager
        super.init()

        guard let button = statusItem.button else { return }
        let bundledIcon = Bundle.main.url(forResource: "Intent", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
        if let icon = (bundledIcon ?? NSApp.applicationIconImage)?.copy() as? NSImage {
            icon.size = NSSize(width: 19, height: 19)
            icon.isTemplate = false
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Intent")
        }
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = "Intent"
        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(relativeTo: sender)
        } else {
            model.toggleOverlay()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "Open Intent", action: #selector(openIntent), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        if let activeSessionName = model.activeSessionName {
            let activeItem = NSMenuItem(title: "Active: \(activeSessionName)", action: nil, keyEquivalent: "")
            activeItem.isEnabled = false
            menu.addItem(activeItem)

            let finishItem = NSMenuItem(title: "Finish Intention", action: #selector(finishIntention), keyEquivalent: "")
            finishItem.target = self
            menu.addItem(finishItem)
        }

        menu.addItem(.separator())
        if let release = updateManager.availableRelease {
            let updateItem = NSMenuItem(
                title: "Install Intent \(release.version)",
                action: #selector(installUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            updateItem.isEnabled = !updateManager.isInstalling
            menu.addItem(updateItem)
        } else {
            let checkItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
            checkItem.target = self
            checkItem.isEnabled = !updateManager.isChecking
            menu.addItem(checkItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Intent", action: #selector(quitIntent), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func openIntent() {
        model.showOverlay()
    }

    @objc private func finishIntention() {
        model.endActiveSession()
    }

    @objc private func checkForUpdates() {
        updateManager.checkForUpdates(force: true)
    }

    @objc private func installUpdate() {
        updateManager.installAvailableUpdate()
    }

    @objc private func quitIntent() {
        NSApp.terminate(nil)
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
        IntentUpdateManager.shared.checkForUpdates()
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
