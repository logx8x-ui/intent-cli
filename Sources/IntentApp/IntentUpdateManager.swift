import AppKit
import IntentCore
import Sparkle

struct IntentGitHubRelease: Equatable {
    let version: String
}

/// Sparkle verifies every archive against the release public key embedded in this app.
@MainActor
final class IntentUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = IntentUpdateManager()
    @Published private(set) var availableRelease: IntentGitHubRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var errorMessage: String?
    private var controller: SPUStandardUpdaterController?
    private var deferredInstall: (() -> Void)?
    private var resumeTimer: Timer?
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    private var sessionNeedsFinishing: Bool {
        let model = IntentRuntime.shared.model
        return model.hasActiveSession || model.isZeroDriftActive || model.pendingPurposeSessionSave != nil
    }
    func startAutomaticChecks() {
        guard !IntentEnvironment.isQA else { return }
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.automaticallyChecksForUpdates = true
        controller?.updater.automaticallyDownloadsUpdates = true
        controller?.updater.updateCheckInterval = 3600
        controller?.updater.checkForUpdatesInBackground()
    }
    func appBecameActive() { startAutomaticChecks() }
    func checkForUpdates(force: Bool = false) {
        guard !IntentEnvironment.isQA else {
            errorMessage = "Updates are disabled in the isolated QA app."
            return
        }
        startAutomaticChecks()
        errorMessage = nil
        if force { controller?.checkForUpdates(nil) }
        else { controller?.updater.checkForUpdatesInBackground() }
    }
    func installAvailableUpdate() { checkForUpdates(force: true) }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableRelease = .init(version: item.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isInstalling = false
        errorMessage = error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard sessionNeedsFinishing else { return false }
        deferredInstall = installHandler
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.sessionNeedsFinishing else { return }
                self.resumeTimer?.invalidate(); self.resumeTimer = nil
                let install = self.deferredInstall; self.deferredInstall = nil
                install?()
            }
        }
        return true
    }
}
