import AppKit
import IntentCore
import ServiceManagement
import SwiftUI

final class IntentAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: IntentStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? IntentLocalDataSecurity.hardenDefaultDirectory()
        NSApp.setActivationPolicy(.accessory)
        LaunchAtLoginController.applySavedPreference()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        IntentRuntime.shared.model.showOverlay()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where IntentRuntime.shared.accountManager.handleAuthCallback(url) {
            IntentRuntime.shared.model.showOverlay()
            return
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = IntentRuntime.shared.model
        guard model.isZeroDriftActive else { return .terminateNow }
        model.errorMessage = "Zero Drift is active. Intent will remain open until its timer finishes."
        model.showOverlay()
        return .terminateCancel
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
    private let statusItem = NSStatusBar.system.statusItem(withLength: 30)

    init(model: IntentAppModel, updateManager: IntentUpdateManager) {
        self.model = model
        self.updateManager = updateManager
        super.init()

        guard let button = statusItem.button else { return }
        statusItem.autosaveName = "Intent"
        statusItem.behavior = [.removalAllowed, .terminationOnRemoval]
        statusItem.isVisible = true
        button.image = IntentMenuBarIcon.makeImage()
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Intent"
        button.setAccessibilityLabel("Intent")
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
            finishItem.isEnabled = model.activeSessionCanFinishManually
            menu.addItem(finishItem)
        }

        if model.isZeroDriftActive {
            let status = model.zeroDriftStatusText.map { "Zero Drift: \($0) remaining" } ?? "Zero Drift: Active"
            let zeroDriftItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            zeroDriftItem.isEnabled = false
            menu.addItem(zeroDriftItem)
        }

        if let shortcutWarning = model.shortcutWarning {
            menu.addItem(.separator())
            let warningItem = NSMenuItem(title: shortcutWarning, action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            menu.addItem(warningItem)
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
        let quitItem = NSMenuItem(title: "Close Intent", action: #selector(closeIntent), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = !model.isZeroDriftActive
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

    @objc private func closeIntent() {
        NSApp.terminate(nil)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

@MainActor
final class IntentRuntime {
    static let shared = IntentRuntime()

    let model: IntentAppModel
    let calendarSync: CalendarSyncManager
    let accountManager: IntentAccountManager
    private let overlayController: OverlayWindowController
    private var hotKeyManager: GlobalHotKeyManager?
    private var showOverlayObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var hasStarted = false

    init() {
        let model = IntentAppModel()
        let calendarSync = CalendarSyncManager(model: model)
        let accountManager = IntentAccountManager()
        calendarSync.attach(model: model)
        accountManager.attach(model: model)
        let controller = OverlayWindowController(
            model: model,
            calendarSync: calendarSync,
            accountManager: accountManager
        )
        model.overlayPresenter = controller

        self.model = model
        self.calendarSync = calendarSync
        self.accountManager = accountManager
        overlayController = controller
        accountManager.onExternalAuthenticationRequested = { [weak controller] url in
            guard let controller else { return false }
            return await controller.handOffExternalAuthentication(to: url)
        }
        accountManager.onPortablePreferencesApplied = { [weak self] in
            self?.reloadPortablePreferences()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        hotKeyManager = GlobalHotKeyManager {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                IntentRuntime.shared.model.toggleOverlay()
            }
        }
        if hotKeyManager?.isRegistered != true {
            model.shortcutWarning = "Shortcut unavailable. Open Intent here and choose another shortcut."
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
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                IntentRuntime.shared.calendarSync.appBecameActive()
                IntentRuntime.shared.accountManager.appBecameActive()
            }
        }

        model.load()
        Task { await accountManager.start() }
        IntentUpdateManager.shared.checkForUpdates()
        if !UserDefaults.standard.bool(forKey: "intentDidCompleteOnboarding")
            || !UserDefaults.standard.bool(forKey: "intentAccountChoiceMade")
            || PurposeModePreference.isEnabled {
            overlayController.showOverlay(animated: false)
        }
    }

    func updateOverlayShortcut(_ candidate: OverlayShortcut) -> String? {
        if candidate == FinishShortcutStore.load() {
            return "Use a different shortcut from the one that finishes an intention."
        }
        if let message = OverlayShortcutConflictChecker.validationMessage(for: candidate) {
            return message
        }
        guard let hotKeyManager else {
            return "Intent's shortcut service is not ready yet."
        }

        let status = hotKeyManager.update(to: candidate)
        guard status == noErr else {
            model.shortcutWarning = "Shortcut unavailable. Open Intent here and choose another shortcut."
            return "\(candidate.displayName) is already being used by macOS or another app."
        }

        model.shortcutWarning = nil
        OverlayShortcutStore.save(candidate)
        return nil
    }

    func updateFinishShortcut(_ candidate: OverlayShortcut) -> String? {
        if candidate == OverlayShortcutStore.load() {
            return "Use a different shortcut from the one that opens Intent."
        }
        if let message = OverlayShortcutConflictChecker.validationMessage(for: candidate) {
            return message
        }
        FinishShortcutStore.save(candidate)
        return nil
    }

    func updateLaunchAtLogin(_ enabled: Bool) -> String? {
        LaunchAtLoginController.setEnabled(enabled)
    }

    private func reloadPortablePreferences() {
        let shortcut = OverlayShortcutStore.load()
        guard let hotKeyManager else { return }
        let status = hotKeyManager.update(to: shortcut)
        model.shortcutWarning = status == noErr
            ? nil
            : "Synced shortcut unavailable on this Mac. Choose another shortcut in Settings."
    }
}

enum LaunchAtLoginController {
    private static let preferenceKey = "intentLaunchAtLogin"

    static var savedPreference: Bool {
        if UserDefaults.standard.object(forKey: preferenceKey) == nil {
            UserDefaults.standard.set(true, forKey: preferenceKey)
        }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static func applySavedPreference() {
        _ = setEnabled(savedPreference)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return enabled
                ? "macOS could not enable Open at Login for this build."
                : "macOS could not disable Open at Login for this build."
        }
    }
}
