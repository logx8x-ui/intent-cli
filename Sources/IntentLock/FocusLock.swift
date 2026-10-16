import AppKit
import ApplicationServices
import Foundation
import IntentCore

public enum FocusLockError: Error, CustomStringConvertible {
    case accessibilityPermissionRequired
    case eventTapUnavailable
    case inputProtectionInterrupted(FocusLockSafetyStopCause)
    case unableToOpen(String)
    case quickSelectionStartChanged
    case browserWindowEnforcementFailed(BrowserWindowEnforcementPolicy.Failure)
    case browserWindowCoverageFailed(BrowserWindowCoveragePolicy.Failure)
    case nativeWindowEnforcementFailed(NativeVisibilityCoveragePolicy.Failure)

    public var description: String {
        switch self {
        case .accessibilityPermissionRequired:
            return IntentPermissionInstructions.current.accessibility
        case .eventTapUnavailable:
            return IntentPermissionInstructions.current.keyboardLock
        case .inputProtectionInterrupted:
            return "This intention stopped because macOS interrupted its input protection. Intent has released its restrictions. Start the intention again to continue."
        case .unableToOpen(let name):
            return "Intent could not open \(name)."
        case .quickSelectionStartChanged:
            return "Your Run window or tab changed while Intent was preparing. Run again from the window you want."
        case .browserWindowCoverageFailed(let failure):
            return failure.message
        case .browserWindowEnforcementFailed(let failure):
            return failure.message
        case .nativeWindowEnforcementFailed(let failure):
            return failure.message
        }
    }
}

public enum FocusForegroundPolicy {
    public static func shouldLeaveEmptyDesktopAlone(visibleBundleIdentifier: String?,
                                                    foregroundBundleIdentifier: String?) -> Bool {
        guard visibleBundleIdentifier == nil else { return false }
        // Finder is the desktop shell, even in a single-app intention. This
        // exception never applies when a Finder or other app window is visible.
        guard let foregroundBundleIdentifier else { return true }
        return ["com.apple.finder", "com.apple.dock", "com.apple.WindowManager"].contains(foregroundBundleIdentifier)
    }

    public static func shouldRestoreVisibleWindow(visibleBundleIdentifier: String?, accessMode: IntentionAccessMode,
                                                   controlledBundleIdentifiers: Set<String>, missionControlActive: Bool) -> Bool {
        guard !missionControlActive else { return false }
        guard !FocusSystemToolPolicy.isScreenshotApplication(visibleBundleIdentifier) else { return false }
        // No visible application is a valid empty desktop. Do not pull a
        // remembered window (and its Space) back merely because it is empty.
        guard let visibleBundleIdentifier else { return false }
        return accessMode == .whitelist ? !controlledBundleIdentifiers.contains(visibleBundleIdentifier)
            : controlledBundleIdentifiers.contains(visibleBundleIdentifier)
    }
    public static func shouldImmediatelyReject(
        bundleIdentifier: String?,
        accessMode: IntentionAccessMode,
        controlledBundleIdentifiers: Set<String>,
        isRegularApplication: Bool = true
    ) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != Bundle.main.bundleIdentifier,
              !FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) else { return false }
        switch accessMode {
        case .blacklist: return controlledBundleIdentifiers.contains(bundleIdentifier)
        case .whitelist: return isRegularApplication && !shouldDeferRefocus(bundleIdentifier: bundleIdentifier)
            && !controlledBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    public static func shouldHonorSystemTransitionGrace(
        bundleIdentifier: String?,
        graceUntil: Date,
        now: Date
    ) -> Bool {
        shouldDeferRefocus(bundleIdentifier: bundleIdentifier) || now < graceUntil
    }

    public static func shouldDeferRefocus(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) { return true }
        return [
            "com.apple.dock",
            "com.apple.Spotlight",
            "com.apple.WindowManager",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.notificationcenterui",
            "com.apple.TextInputMenuAgent"
        ].contains(bundleIdentifier)
    }

    public static func shouldRecoverAfterSpaceChange(
        bundleIdentifier: String?,
        accessMode: IntentionAccessMode,
        controlledBundleIdentifiers: Set<String>
    ) -> Bool {
        guard let bundleIdentifier else { return true }
        if FocusSystemToolPolicy.isScreenshotApplication(bundleIdentifier) { return false }
        switch accessMode {
        case .whitelist:
            return !controlledBundleIdentifiers.contains(bundleIdentifier)
        case .blacklist:
            return controlledBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    public static func isMissionControlOverlay(
        ownerName: String?,
        layer: Int?,
        bounds: CGRect,
        displayBounds: CGRect
    ) -> Bool {
        guard ownerName == "Dock",
              let layer,
              [18, 20].contains(layer),
              !displayBounds.isNull,
              displayBounds.width > 0,
              displayBounds.height > 0 else {
            return false
        }

        return bounds.width >= displayBounds.width * 0.9 &&
            bounds.height >= displayBounds.height * 0.9
    }
}

public final class FocusLock {
    private struct WindowBounds {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var maxX: CGFloat { x + width }
        var maxY: CGFloat { y + height }
    }

    private let spec: FocusSessionSpec
    private static let healthDiagnostics = FocusEnforcementDiagnosticSink(fileURL:
        ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("focus-enforcement-diagnostics.json"))
    private let healthOwner: UUID
    private var shouldStop = false
    private var safetyStop = false
    private var safetyFailure: FocusLockError?
    private var currentFinishShortcut: FocusKeyboardShortcut
    public var didStopForSafety: Bool {
        stopStateLock.lock()
        defer { stopStateLock.unlock() }
        return safetyStop
    }
    private let stopStateLock = NSLock()
    private let focusActions = DeferredSessionActionGate()
    private let allowedAppSwitcher: AllowedAppSwitcher
    private let nativeTabClickGuard = NativeBrowserTabClickGuard()
    private let visibilityController: FocusVisibilityController
    private lazy var blurController = FocusBlurController(spec: spec, tabGuard: nativeTabClickGuard)
    private let permittedWindowRecovery: PermittedWindowRecovery
    private let inputLifecycleLock = NSLock()
    private var inputDriver: FocusInputTapDriver?
    private let inputPolicyQueue = DispatchQueue(label: "intent.input-policy", qos: .userInteractive)
    private var inputPolicyTimer: DispatchSourceTimer?
    private var rcmdMonitor: RcmdCompatibilityMonitor?
    // Owned by inputPolicyQueue after initial installation.
    private var rcmdSnapshot = RcmdCompatibilitySnapshot.inactive
    private var focusTimer: Timer?
    private var spotifyTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var pendingSpaceRecovery: DispatchWorkItem?
    private let inputRecovery = FocusInputRecoveryQueue()
    private let selectedWindowRecovery = FocusSelectedWindowRecoveryPolicy()
    private var baselinePids = Set<pid_t>()
    private var returnApplication: NSRunningApplication?
    private var lastPermittedApplication: NSRunningApplication?
    private var didBecomeReady = false
    private var systemSwitcherGraceUntil: Date = .distantPast

    public var onManualFinishRequest: (@Sendable () -> Void)?

    public func acknowledgeManualFinishRequest() {
        inputComponents().driver?.acknowledgeManualFinishRequest()
    }

    private func inputComponents(remove: Bool = false) -> (driver: FocusInputTapDriver?, timer: DispatchSourceTimer?, monitor: RcmdCompatibilityMonitor?) {
        inputLifecycleLock.lock(); defer { inputLifecycleLock.unlock() }
        let result = (inputDriver, inputPolicyTimer, rcmdMonitor)
        if remove { inputDriver = nil; inputPolicyTimer = nil; rcmdMonitor = nil }
        return result
    }

    public init(spec: FocusSessionSpec) {
        RcmdCompatibilityMonitor.prepareKeyboardLayout()
        self.spec = spec
        permittedWindowRecovery = PermittedWindowRecovery(spec: spec)
        healthOwner = Self.healthDiagnostics.begin(.init(accessMode: spec.accessMode.rawValue,
            requiresEnforcement: spec.requiresEnforcement, hideDistractions: spec.hideDistractions,
            selectedWindowGroupCount: spec.selectedWindowIDsByApp.count))
        visibilityController = FocusVisibilityController(spec: spec)
        currentFinishShortcut = spec.finishShortcut
        allowedAppSwitcher = AllowedAppSwitcher(
            allowedBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            accessMode: spec.accessMode
        )
        visibilityController.onEnforcementFailure = { [weak self] failure in
            self?.stopForSafety(failure: .browserWindowEnforcementFailed(failure))
        }
        visibilityController.onCoverageFailure = { [weak self] failure in
            self?.stopForSafety(failure: .browserWindowCoverageFailed(failure))
        }
        visibilityController.onNativeCoverageFailure = { [weak self] failure in
            self?.stopForSafety(failure: .nativeWindowEnforcementFailed(failure))
        }
        visibilityController.enforcementIsCurrent = { [weak self] in self?.isStopRequested == false }
        allowedAppSwitcher.activateSelection = { [weak self] pid in _ = self?.activateApp(processIdentifier: pid) }

    }

    public func stop() {
        stopStateLock.lock()
        shouldStop = true
        recordHealth(.finished(.manual))
        stopStateLock.unlock()
        cancelPendingFocusActions()
        visibilityController.stop()
    }

    private var suppressReturnActivation = false

    public func stopForExpiry() {
        stopStateLock.lock()
        suppressReturnActivation = true
        shouldStop = true
        recordHealth(.finished(.expiry))
        stopStateLock.unlock()
        cancelPendingFocusActions()
        visibilityController.stop()
    }

    public func updateFinishShortcut(_ shortcut: FocusKeyboardShortcut) {
        stopStateLock.lock()
        currentFinishShortcut = shortcut
        stopStateLock.unlock()
        inputPolicyQueue.async { [weak self] in self?.refreshInputPolicy() }

    }

    private var finishShortcut: FocusKeyboardShortcut {
        stopStateLock.lock()
        defer { stopStateLock.unlock() }
        return currentFinishShortcut
    }

    public func stopForSafety(failure: FocusLockError? = nil, cause: FocusLockSafetyStopCause = .requested) {
        requestSafetyStop(failure: failure, cause: cause, releaseSynchronously: true)
    }

    private func requestSafetyStop(failure: FocusLockError?, cause: FocusLockSafetyStopCause,
                                   releaseSynchronously: Bool) {
        stopStateLock.lock()
        // A delayed failure must not turn manual/expiry completion into an
        // error, nor affect a replacement occurrence. Never hold this mutex
        // while synchronously entering the main-thread visibility controller.
        if shouldStop { stopStateLock.unlock(); return }
        if let failure { safetyFailure = failure; suppressReturnActivation = true }
        safetyStop = true
        shouldStop = true
        let resolvedCause: FocusLockSafetyStopCause
        switch failure {
        case .browserWindowEnforcementFailed?: resolvedCause = .browserWindowEnforcementFailure
        case .browserWindowCoverageFailed?: resolvedCause = .browserWindowCoverageFailure
        case .nativeWindowEnforcementFailed?: resolvedCause = .nativeWindowEnforcementFailure
        default: resolvedCause = cause
        }
        recordHealth(.safetyStopped(resolvedCause))
        stopStateLock.unlock()
        cancelPendingFocusActions()
        // Quit can terminate the process before run-loop cleanup executes.
        // Release owned visibility synchronously before returning to AppKit.
        if releaseSynchronously { visibilityController.stop(restorationPolicyOverride: .automatic) }
        else {
            // The input callback must return before AppKit/AX cleanup, which can
            // otherwise block it long enough for macOS to disable the tap again.
            DispatchQueue.main.async { [visibilityController] in
                visibilityController.stop(restorationPolicyOverride: .automatic)
            }
        }
    }

    private func recordHealth(_ event: FocusEnforcementHealth.Event) {
        Self.healthDiagnostics.record(event, owner: healthOwner)
    }

    private func scheduleInputRefocus() {
        inputRecovery.request { [weak self] in
            guard let self else { return }
            // Rejection happened synchronously. Only activation/AX recovery is
            // deferred, and the existing stop gate fences every resulting effect.
            guard !self.isStopped else { return }
            self.refocus()
        }
    }

    private func cancelPendingFocusActions() {
        // Do this at the stop request, not up to one run-loop turn later in
        // cleanup: queued Cmd-Tab and AX work can otherwise steal focus
        // after the session has already ended.
        let input = inputComponents()
        input.driver?.stop()
        input.timer?.cancel()
        input.monitor?.stop()
        focusActions.invalidate()
        inputRecovery.stop()
        selectedWindowRecovery.stop()
        permittedWindowRecovery.stop()
        allowedAppSwitcher.stop()
    }

    public var isStopRequested: Bool { isStopped }

    private func throwSafetyFailureIfNeeded() throws {
        stopStateLock.lock()
        let failure = safetyFailure
        stopStateLock.unlock()
        if let failure { throw failure }
    }

    public func run(onReady: (@Sendable () -> Void)? = nil) throws {
        recordHealth(.starting)
        defer { recordHealth(.completed) }
        try throwSafetyFailureIfNeeded()
        guard !isStopped else { return }
        try validateStartupAnchor()
        if Thread.isMainThread { RestorationFocusGuard.cancel() }
        else { DispatchQueue.main.sync { RestorationFocusGuard.cancel() } }
        returnApplication = NSWorkspace.shared.frontmostApplication
        if let returnApplication,
           let bundleIdentifier = returnApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier) {
            lastPermittedApplication = returnApplication
        }
        allowedAppSwitcher.recordActivation(bundleIdentifier: returnApplication?.bundleIdentifier)

        guard !spec.requiresEnforcement || requestAccessibilityIfNeeded() else {
            recordHealth(.safetyStopped(.accessibilityPermissionRequired))
            throw FocusLockError.accessibilityPermissionRequired
        }
        guard !isStopped else { return }
        try validateStartupAnchor()

        baselinePids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        defer { cleanup() }

        // Leisure is a launch-only session. It must not install a blocking input tap.
        if spec.requiresEnforcement {
            do { try installEventTap(); recordHealth(.inputTapInstalled) }
            catch { recordHealth(.safetyStopped(.inputTapUnavailable)); throw error }
            installLaunchObserver()
            installActivationObserver()
            installActiveSpaceObserver()
            startFocusTimer()
            nativeTabClickGuard.start()
            blurController.start()
            visibilityController.start()
            startSpotifyTimerIfNeeded()
        }

        do {
            try runStartupSteps()
            while !isStopped && !visibilityController.isInitialCoverageReady {
                if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            if !isStopped { didBecomeReady = true; recordHealth(.ready); onReady?() }
            while !isStopped {
                if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2)) {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        } catch {
            throw error
        }

        stopStateLock.lock()
        let shouldRestore = spec.restorePreviousApplicationOnStop && !suppressReturnActivation
        stopStateLock.unlock()
        try throwSafetyFailureIfNeeded()
        if shouldRestore {
            returnApplication?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        AccessibilityAuthorizationGate.system().waitForTrust()
    }

    private func runStartupSteps() throws {
        if spec.startupWindowAnchor != nil {
            try validateStartupAnchor()
            // DBT starts in place, never by replaying launches or activating a
            // fallback. Model validation rejects excluded current resources.
            return
        }
        for step in spec.startupSteps {
            guard !isStopped else { return }
            switch step {
            case .openBundle(let bundleIdentifier):
                try open(arguments: ["-b", bundleIdentifier], label: bundleIdentifier)
            case .openURL(let url, let bundleIdentifier):
                try openURLOrActivateExisting(url, bundleIdentifier: bundleIdentifier)
            case .selectSideberyDataSciencePanel:
                selectSideberyDataSciencePanel()
            case .playSpotifyPlaylist(let uri):
                try playSpotifyPlaylist(uri)
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.45))
        }

        let currentWindow = spec.preservesCurrentWindowOnStart ? WorkspaceWindow.focused() : nil
        if spec.shouldPreserveCurrentWindowOnStart(windowID: currentWindow?.id,
            bundleIdentifier: currentWindow?.bundle, controllerBundleIdentifier: Bundle.main.bundleIdentifier) {
            // Do not call NSRunningApplication.activate for an already-active
            // browser: macOS may select a different window in the same process.
            if let app = NSWorkspace.shared.frontmostApplication { permittedWindowRecovery.remember(app, verifiedWindow: currentWindow) }
            return
        }
        guard !spec.fallbackBundleIdentifier.isEmpty else { return }

        let deadline = Date(timeIntervalSinceNow: 6)
        while Date() < deadline {
            guard !isStopped else { return }
            if activateFallbackApp() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func validateStartupAnchor() throws {
        guard let anchor = spec.startupWindowAnchor else { return }
        guard anchor.isValid else { throw FocusLockError.quickSelectionStartChanged }
        let current = WorkspaceWindow.focused()
        guard spec.startupSteps.isEmpty,
              anchor.matchesNative(windowID: current?.id, pid: current?.pid, bundleIdentifier: current?.bundle),
              spec.permitsWindow(anchor.nativeWindowID, bundleIdentifier: anchor.bundleIdentifier),
              anchor.matchesBrowserSnapshot(BrowserTabSnapshotStore(browserBundleIdentifier: anchor.bundleIdentifier).load(maxAge: 5)) else {
            throw FocusLockError.quickSelectionStartChanged
        }
    }

    private func openURLOrActivateExisting(_ url: String, bundleIdentifier: String) throws {
        let browserIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
        if browserIsRunning {
            let snapshotStore = BrowserTabSnapshotStore(browserBundleIdentifier: bundleIdentifier)
            let deadline = Date(timeIntervalSinceNow: 0.8)
            repeat {
                guard !isStopped else { return }
                if let snapshot = snapshotStore.load(maxAge: 2),
                   let browserSessionID = snapshot.browserSessionID, !browserSessionID.isEmpty,
                   let tab = snapshot.tabs.first(where: {
                    Self.urlsRepresentSameStartupSite($0.url, url)
                }) {
                    try? BrowserTabCommandStore(browserBundleIdentifier: bundleIdentifier).write(
                        BrowserTabCommand(tabID: tab.id, windowID: tab.windowID, browserSessionID: browserSessionID)
                    )
                    _ = activateApp(bundleIdentifier: bundleIdentifier)
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
                    return
                }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.08))
            } while Date() < deadline
        }

        try open(
            arguments: BrowserLaunchPlanner.openArguments(
                bundleIdentifier: bundleIdentifier,
                url: url,
                isRunning: browserIsRunning
            ),
            label: url
        )
    }

    private static func urlsRepresentSameStartupSite(_ existing: String, _ requested: String) -> Bool {
        guard let existingURL = URL(string: existing),
              let requestedURL = URL(string: requested),
              normalizedHost(existingURL.host) == normalizedHost(requestedURL.host) else {
            return false
        }

        let requestedPath = normalizedPath(requestedURL.path)
        let existingPath = normalizedPath(existingURL.path)
        return requestedPath == "/" ||
            existingPath == requestedPath ||
            existingPath.hasPrefix("\(requestedPath)/")
    }

    private static func normalizedHost(_ host: String?) -> String {
        let value = (host ?? "").lowercased()
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let trimmed = path.last == "/" && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.lowercased()
    }

    private func open(arguments: [String], label: String) throws {
        guard !isStopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FocusLockError.unableToOpen(label)
        }
    }

    private func playSpotifyPlaylist(_ uri: String) throws {
        guard !isStopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"Spotify\" to open location \"\(uri)\"",
            "-e",
            "delay 0.5",
            "-e",
            "tell application \"Spotify\" to play"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FocusLockError.unableToOpen(uri)
        }
    }

    @discardableResult
    private func activateFallbackApp() -> Bool {
        return activateApp(bundleIdentifier: spec.fallbackBundleIdentifier)
    }

    @discardableResult
    private func activateApp(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return false
        }

        return activateApp(processIdentifier: app.processIdentifier)
    }

    @discardableResult
    private func activateApp(processIdentifier: pid_t) -> Bool {
        guard !isStopped, let app = NSRunningApplication(processIdentifier: processIdentifier), !app.isTerminated,
              let bundle = app.bundleIdentifier, spec.permitsApplication(bundle) else {
            return false
        }

        if spec.selectedWindowIDsByApp[bundle] != nil {
            let candidates = Set(WorkspaceWindow.list(onScreen: false).filter {
                $0.pid == processIdentifier && $0.bundle == bundle && spec.permitsWindow($0.id, bundleIdentifier: bundle)
            }.map(\.id))
            // A remembered app or startup fallback cannot bypass window scope.
            return WorkspaceWindow.raise(ids: candidates, bundle: bundle, actionGate: focusActions)
        }

        return focusActions.perform(ifCurrent: 0) {
            app.activate(options: [.activateIgnoringOtherApps])
        } ?? false
    }

    private func installEventTap() throws {
        rcmdSnapshot = RcmdCompatibilityMonitor.readCurrent()
        guard rcmdSnapshot.isCompatible else { throw FocusLockError.eventTapUnavailable }
        let configuration = FocusInputConfiguration(restrictSwitching: spec.blockAppSwitching || spec.keepFocused,
            blockSystemCommands: shouldBlockSystemCommand,
            blockBrowserEscape: spec.accessMode == .whitelist && spec.blockBrowserTabEscape,
            protectFirefoxChrome: spec.blockFirefoxChromeClicks, allowGoogleSearchTabs: spec.allowGoogleSearchTabs)
        let driver = FocusInputTapDriver(snapshot: makeInputSnapshot(), configuration: configuration,
            onEffects: { [weak self] actions, isCurrent in self?.applyInputEffects(actions, isCurrent: isCurrent) },
            onControl: { [weak self] in self?.handleInputControl($0) },
            onMetrics: { [weak self] sample in
                self?.recordHealth(.inputBatch(samples: sample.samples,
                    maxDurationMicroseconds: sample.maxDurationMicroseconds,
                    maxSnapshotAgeMilliseconds: sample.maxSnapshotAgeMilliseconds,
                    maxPendingActions: sample.maxPendingActions, coalescedActions: sample.coalescedActions,
                    schedulingDelayMilliseconds: sample.schedulingDelayMilliseconds))
            })
        inputLifecycleLock.lock(); inputDriver = driver; inputLifecycleLock.unlock()
        try driver.start()
        guard RcmdCompatibilityMonitor.verifyCurrentTopology(rcmdSnapshot) else {
            driver.stop(); throw FocusLockError.eventTapUnavailable
        }
        guard !isStopped else { driver.stop(); return }
        let timer = DispatchSource.makeTimerSource(queue: inputPolicyQueue)
        timer.schedule(deadline: .now(), repeating: 0.04, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.refreshInputPolicy() }
        inputLifecycleLock.lock(); inputPolicyTimer = timer; inputLifecycleLock.unlock()
        timer.resume()
        let monitor = RcmdCompatibilityMonitor(initialSnapshot: rcmdSnapshot,
            onSnapshot: { [weak self] snapshot in
                guard let self else { return }
                self.inputPolicyQueue.async { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.rcmdSnapshot = snapshot; self.refreshInputPolicy()
                }
            }, onInvalidated: { [weak self] _ in
                self?.requestSafetyStop(failure: .inputProtectionInterrupted(.inputTapUnavailable),
                    cause: .inputTapUnavailable, releaseSynchronously: false)
            })
        inputLifecycleLock.lock(); rcmdMonitor = monitor; inputLifecycleLock.unlock()
        monitor.start()
    }

    private func refreshInputPolicy() {
        guard !isStopped else { return }
        let snapshot = makeInputSnapshot()
        guard !isStopped else { return }
        inputComponents().driver?.publish(snapshot)
    }

    /// Only this producer performs platform discovery. An AX timeout cannot
    /// stall input delivery or queue another scan while this scan is in flight.
    private func makeInputSnapshot() -> FocusInputPolicySnapshot {
        var snapshot = FocusInputPolicySnapshot()
        snapshot.observedAt = ProcessInfo.processInfo.systemUptime
        let foreground = NSWorkspace.shared.frontmostApplication
        let applications = NSWorkspace.shared.runningApplications
        let appsByPID = Dictionary(applications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = NSScreen.screens.map { screen -> (CGRect, CGFloat) in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let rect = number.map(CGDisplayBounds) ?? screen.frame
            return (rect, max(30, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        snapshot.menuBars = displays.map { CGRect(x: $0.0.minX, y: $0.0.minY, width: $0.0.width, height: $0.1) }
        snapshot.missionControl = records.contains { row in
            guard let value = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: value as CFDictionary) else { return false }
            return displays.contains { FocusForegroundPolicy.isMissionControlOverlay(
                ownerName: row[kCGWindowOwnerName as String] as? String,
                layer: row[kCGWindowLayer as String] as? Int, bounds: rect, displayBounds: $0.0) }
        }
        var foregroundWindowID: UInt32 = 0
        for row in records {
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let layer = row[kCGWindowLayer as String] as? Int, layer >= 0,
                  let value = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: value as CFDictionary),
                  let app = appsByPID[pid], let bundle = app.bundleIdentifier else { continue }
            if layer == 0, pid == foreground?.processIdentifier, foregroundWindowID == 0 { foregroundWindowID = id }
            if layer == 0, pid == foreground?.processIdentifier, bundle == "org.mozilla.firefox", snapshot.firefoxBounds == nil {
                snapshot.firefoxBounds = rect
            }
            let auxiliary = FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(bundleIdentifier: bundle,
                isRegularApplication: app.activationPolicy == .regular,
                controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers, accessMode: spec.accessMode)
            let verifiedAuxiliary = visibilityController.permitsAuxiliaryWindow(id: id, pid: pid,
                bundleIdentifier: bundle, launched: app.launchDate) == true
            let permitted = bundle == Bundle.main.bundleIdentifier || FocusSystemToolPolicy.isScreenshotApplication(bundle)
                || auxiliary || verifiedAuxiliary || spec.permitsWindow(id, bundleIdentifier: bundle)
            snapshot.windows.append(.init(id: id, bounds: rect, permitted: permitted))
        }
        let panels = IntentInteractivePanelRegions.shared.inputSnapshot()
        snapshot.panelRegions = panels.regions; snapshot.panelKeyboardFocus = panels.hasKeyboardFocus
        snapshot.screenshotActive = FocusSystemToolPolicy.isScreenshotApplication(foreground?.bundleIdentifier)
        snapshot.firefoxFrontmost = foreground?.bundleIdentifier == "org.mozilla.firefox"
        snapshot.browserFrontmost = ["org.mozilla.firefox", "com.google.Chrome"].contains(foreground?.bundleIdentifier ?? "")
            && !spec.presetAllowedBundleIdentifiers.contains(foreground?.bundleIdentifier ?? "")
        snapshot.foregroundRejected = FocusForegroundPolicy.shouldImmediatelyReject(bundleIdentifier: foreground?.bundleIdentifier,
            accessMode: spec.accessMode, controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            isRegularApplication: foreground?.activationPolicy == .regular)
        if let app = foreground, let bundle = app.bundleIdentifier {
            let verifiedAuxiliary = visibilityController.permitsAuxiliaryWindow(id: foregroundWindowID,
                pid: app.processIdentifier, bundleIdentifier: bundle, launched: app.launchDate) == true
            snapshot.foregroundRejected = snapshot.foregroundRejected || FocusInputForegroundPolicy.rejectsWindow(
                hasWindowScope: spec.selectedWindowIDsByApp[bundle] != nil, foregroundWindowID: foregroundWindowID,
                windowPermitted: spec.permitsWindow(foregroundWindowID, bundleIdentifier: bundle),
                auxiliaryVerified: verifiedAuxiliary)
        }
        let tab = nativeTabClickGuard.inputSnapshot()
        if tab.pid == foreground?.processIdentifier, tab.remainingValidity > 0, tab.windowID == foregroundWindowID, foregroundWindowID != 0 {
            snapshot.tabWindowID = tab.windowID; snapshot.tabRegions = tab.rectangles
            snapshot.nativeWindowBlocked = tab.foregroundBlocked; snapshot.addressSubmissionBlocked = tab.addressBlocked
            snapshot.tabRegionsValidUntil = ProcessInfo.processInfo.systemUptime + tab.remainingValidity
        }
        if let point = CGEvent(source: nil)?.location {
            let target = clickTarget(at: point, inMissionControl: snapshot.missionControl)
            snapshot.pointerProbe = point
            if snapshot.missionControl {
                snapshot.pointerPermitted = FocusClickTargetPolicy.shouldAllowMissionControlClick(
                    ownerBundleIdentifier: target.ownerBundleIdentifier, representedBundleIdentifier: target.representedBundleIdentifier,
                    controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers, accessMode: spec.accessMode,
                    isSpaceNavigation: target.isSpaceNavigation)
            } else {
                let owner = applications.first { $0.bundleIdentifier == target.ownerBundleIdentifier }
                snapshot.pointerPermitted = FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
                    bundleIdentifier: target.ownerBundleIdentifier, isRegularApplication: owner?.activationPolicy == .regular,
                    controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers, accessMode: spec.accessMode)
                    || FocusClickTargetPolicy.shouldAllow(ownerBundleIdentifier: target.ownerBundleIdentifier,
                        representedBundleIdentifier: target.representedBundleIdentifier,
                        allowedBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
                        intentBundleIdentifier: Bundle.main.bundleIdentifier, accessMode: spec.accessMode,
                        isMenuBarClick: snapshot.menuBars.contains { $0.contains(point) })
            }
        }
        snapshot.finishShortcut = finishShortcut
        snapshot.accessibilityTrusted = AXIsProcessTrusted()
        let coverage = visibilityController.inputRecoveryCoverage
        snapshot.coverageVerifiedAt = coverage.verifiedAtUptime; snapshot.coverageResolved = coverage.resolved
        snapshot.allowedSwitchingBundles = Set(applications.compactMap { app in
            guard let bundle = app.bundleIdentifier, app.activationPolicy == .regular,
                  !app.isTerminated, spec.permitsApplication(bundle) else { return nil }
            return bundle
        })
        snapshot.rcmd = rcmdSnapshot
        snapshot.stopped = isStopped
        return snapshot
    }

    private func applyInputEffects(_ actions: [FocusInputAction], isCurrent: () -> Bool) {
        for action in actions {
            guard !isStopped, isCurrent() else { return }
            switch action {
            case .refocus: scheduleInputRefocus()
            case .switcherAdvance(let steps): allowedAppSwitcher.advance(steps: steps)
            case .switcherCommit: allowedAppSwitcher.commit()
            case .switcherCancel: allowedAppSwitcher.cancel()
            case .activate(let bundle): _ = activateApp(bundleIdentifier: bundle)
            case .spaceNavigation: systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 1.5)
            case .drag: nativeTabClickGuard.invalidateDuringDrag()
            case .mouseDown(let mission): nativeTabClickGuard.recordMouseDown(missionControl: mission)
            case .blockedClick: recordHealth(.blockedClick)
            case .manualFinish, .emergencyStop: break // Separate priority control worker owns these.
            }
        }
    }

    private func handleInputControl(_ control: FocusInputTapDriver.Control) {
        guard !isStopped else { return }
        switch control {
        case .recoveryBegan:
            recordHealth(.inputTapRecoveryBegan)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.allowedAppSwitcher.cancel()
                self.visibilityController.refreshAfterWorkspaceTransition()
            }
            inputPolicyQueue.async { [weak self] in self?.refreshInputPolicy() }
        case .recoverySucceeded: recordHealth(.inputTapRecoverySucceeded)
        case .failed(let cause):
            requestSafetyStop(failure: .inputProtectionInterrupted(cause), cause: cause, releaseSynchronously: false)
        case .emergencyStop:
            requestSafetyStop(failure: nil, cause: .emergencyShortcut, releaseSynchronously: false)
        case .manualFinish:
            if let onManualFinishRequest { onManualFinishRequest() }
            else if spec.allowsManualFinish {
                // Main-thread restoration must not delay delivery of another input.
                DispatchQueue.main.async { [weak self] in
                    self?.stop(); self?.acknowledgeManualFinishRequest()
                }
            } else { acknowledgeManualFinishRequest() }
        }
    }

    private func isBlockedSystemCommand(_ keyCode: Int64) -> Bool {
        FocusSystemShortcutPolicy.shouldBlock(keyCode: keyCode)
    }

    private var shouldBlockSystemCommand: Bool {
        spec.accessMode == .whitelist && (spec.blockAppSwitching || spec.blockNewApps || spec.keepFocused)
    }

    private func isBlockedBrowserCommand(keyCode: Int64, command: Bool, control: Bool, option: Bool, shift: Bool) -> Bool {
        FocusBrowserShortcutPolicy.shouldBlock(
            keyCode: keyCode,
            command: command,
            control: control,
            option: option,
            shift: shift,
            allowGoogleSearchTabs: spec.allowGoogleSearchTabs
        )
    }

    private func installLaunchObserver() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }

            self.handleLaunched(app)
        }
    }

    private func installActivationObserver() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] is NSRunningApplication
            else {
                return
            }

            // Notification bursts from switchers collapse into one current
            // foreground check; never replay a stale activation after a finish.
            self.inputRecovery.request { [weak self] in
                guard let self, !self.isStopped,
                      let current = NSWorkspace.shared.frontmostApplication else { return }
                self.handleActivated(current)
            }
        }
    }

    private func installActiveSpaceObserver() {
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSpaceRecovery()
        }
    }

    private func scheduleSpaceRecovery() {
        guard !isStopped else { return }
        visibilityController.refreshAfterWorkspaceTransition()
        permittedWindowRecovery.noteSpaceChange()
        systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 0.15)
        pendingSpaceRecovery?.cancel()
        recoverSpace(attempt: 0)
    }

    private func recoverSpace(attempt: Int) {
        guard !isStopped,
              !FocusSystemToolPolicy.isScreenshotApplication(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        let visible = PermittedWindowRecovery.visibleApplication()
        guard FocusForegroundPolicy.shouldRestoreVisibleWindow(visibleBundleIdentifier: visible?.bundleIdentifier,
            accessMode: spec.accessMode, controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            missionControlActive: isMissionControlActive()) else { return }
        refocus(ignoreSystemTransitionGrace: true, restoreWindow: true)
        guard attempt < 8 else { return }
        let recovery = DispatchWorkItem { [weak self] in
            self?.recoverSpace(attempt: attempt + 1)
        }
        pendingSpaceRecovery = recovery
        // The first attempt is immediate; bounded retries cover the OS transition
        // settling after an activation request. Never synthesize reverse gestures.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: recovery)
    }

    private func handleLaunched(_ app: NSRunningApplication) {
        guard !isStopped, spec.blockNewApps else { return }
        guard let bundleIdentifier = app.bundleIdentifier else { return }
        guard !spec.permitsApplication(bundleIdentifier) else { return }
        guard app.activationPolicy == .regular else { return }
        guard !baselinePids.contains(app.processIdentifier) else { return }

        if !spec.hideDistractions, spec.accessMode != .blacklist, !spec.presetBlockedBundleIdentifiers.contains(bundleIdentifier) {
            focusActions.perform(ifCurrent: 0) { app.terminate() }
        }
        refocus()
    }

    private func handleActivated(_ app: NSRunningApplication) {
        guard !isStopped, spec.blockAppSwitching || spec.keepFocused else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if FocusSystemToolPolicy.isScreenshotApplication(app.bundleIdentifier) { return }
        // An empty Space activates its desktop shell. It is not an attempt to
        // open a blocked Finder window, and must not pull the user back.
        if FocusForegroundPolicy.shouldLeaveEmptyDesktopAlone(
            visibleBundleIdentifier: PermittedWindowRecovery.visibleApplication()?.bundleIdentifier,
            foregroundBundleIdentifier: app.bundleIdentifier
        ) {
            return
        }
        let verifiedWindow = WorkspaceWindow.focused()
        if let window = verifiedWindow, window.pid == app.processIdentifier, window.bundle == app.bundleIdentifier,
           visibilityController.permitsAuxiliaryWindow(id: window.id, pid: window.pid,
                bundleIdentifier: window.bundle, launched: app.launchDate) == true {
            // Utility permission is derived and short-lived. Do not remember
            // the panel as selected work or change the normal recovery target.
            return
        }
        if let id = app.bundleIdentifier, spec.selectedWindowIDsByApp[id] != nil {
            guard let window = verifiedWindow, window.bundle == id, window.pid == app.processIdentifier,
                  spec.permitsWindow(window.id, bundleIdentifier: id) else {
                // Let the window-scoped focus pass restore a permitted target;
                // never remember a blocked or unknown sibling.
                return
            }
        }
        if let id = app.bundleIdentifier, app.activationPolicy == .regular,
           spec.permitsApplication(id),
           id != "com.spotify.client" || spec.allowSpotifyForeground || spec.accessMode == .blacklist {
            lastPermittedApplication = app
            permittedWindowRecovery.remember(app, verifiedWindow: verifiedWindow)
            allowedAppSwitcher.recordActivation(bundleIdentifier: id)
            return
        }

        if FocusForegroundPolicy.shouldImmediatelyReject(
            bundleIdentifier: app.bundleIdentifier,
            accessMode: spec.accessMode,
            controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            isRegularApplication: app.activationPolicy == .regular
        ) {
            recordHealth(.blockedActivation)
            refocus(ignoreSystemTransitionGrace: true)
            return
        }

        if FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
            bundleIdentifier: app.bundleIdentifier,
            isRegularApplication: app.activationPolicy == .regular,
            controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            accessMode: spec.accessMode
        ) {
            return
        }

        if shouldWaitForSystemSwitcher(bundleIdentifier: app.bundleIdentifier) {
            return
        }

        guard let bundleIdentifier = app.bundleIdentifier else {
            refocus()
            return
        }

        if spec.strictSingleApp {
            guard bundleIdentifier == spec.fallbackBundleIdentifier else {
                refocus()
                return
            }
            return
        }

        guard spec.permitsApplication(bundleIdentifier) else {
            refocus()
            return
        }

        lastPermittedApplication = app
        allowedAppSwitcher.recordActivation(bundleIdentifier: bundleIdentifier)
    }

    private func startFocusTimer() {
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.enforceFocus()
        }
        RunLoop.current.add(focusTimer!, forMode: .common)
    }

    private func startSpotifyTimerIfNeeded() {
        guard spec.spotifyPlaylistURI != nil else { return }

        spotifyTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isSpotifyFrontmost(), !self.spec.allowSpotifyForeground {
                self.refocus()
            }
        }
        RunLoop.current.add(spotifyTimer!, forMode: .common)
    }

    private func enforceFocus() {
        guard !isStopped, spec.blockAppSwitching || spec.keepFocused else { return }

        let foreground = NSWorkspace.shared.frontmostApplication
        if FocusSystemToolPolicy.isScreenshotApplication(foreground?.bundleIdentifier) { return }
        let visible = PermittedWindowRecovery.visibleApplication()
        if FocusForegroundPolicy.shouldLeaveEmptyDesktopAlone(visibleBundleIdentifier: visible?.bundleIdentifier,
            foregroundBundleIdentifier: foreground?.bundleIdentifier) { return }

        guard let frontmost = foreground else {
            if shouldWaitForSystemSwitcher(bundleIdentifier: nil) {
                return
            }
            refocus()
            return
        }

        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        // Space swipes can leave NSWorkspace reporting the old permitted app while
        // a forbidden window is visibly occupying the new Space.
        if let visible,
           FocusForegroundPolicy.shouldRestoreVisibleWindow(visibleBundleIdentifier: visible.bundleIdentifier,
                accessMode: spec.accessMode, controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
                missionControlActive: isMissionControlActive()) {
            refocus(ignoreSystemTransitionGrace: true, restoreWindow: true)
            return
        }

        if FocusForegroundPolicy.shouldImmediatelyReject(
            bundleIdentifier: frontmost.bundleIdentifier,
            accessMode: spec.accessMode,
            controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            isRegularApplication: frontmost.activationPolicy == .regular
        ) {
            refocus(ignoreSystemTransitionGrace: true)
            return
        }

        if FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
            bundleIdentifier: frontmost.bundleIdentifier,
            isRegularApplication: frontmost.activationPolicy == .regular,
            controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            accessMode: spec.accessMode
        ) {
            return
        }

        if shouldWaitForSystemSwitcher(bundleIdentifier: frontmost.bundleIdentifier) {
            return
        }

        let selectedScopeBundle = frontmost.bundleIdentifier.flatMap {
            spec.selectedWindowIDsByApp[$0] != nil ? $0 : nil
        }
        let focusedScopeWindow = selectedScopeBundle != nil ? WorkspaceWindow.focused() : nil
        if let bundle = selectedScopeBundle {
            // A different foreground sample is a transition, not evidence that
            // this app is showing an excluded window or has recovered already.
            guard let window = focusedScopeWindow, window.bundle == bundle else { return }
            if window.pid == frontmost.processIdentifier,
               visibilityController.permitsAuxiliaryWindow(id: window.id, pid: window.pid,
                    bundleIdentifier: bundle, launched: frontmost.launchDate) == true {
                selectedWindowRecovery.recovered()
                return
            }
            if !spec.permitsWindow(window.id, bundleIdentifier: bundle) {
                // AX/WindowServer reads can disagree briefly during a transition.
                // Coalesce retries without changing which windows are permitted.
                guard selectedWindowRecovery.beginAttempt(now: ProcessInfo.processInfo.systemUptime) else { return }
                let candidates: Set<UInt32>
                if spec.accessMode == .whitelist { candidates = spec.selectedWindowIDsByApp[bundle] ?? [] }
                else { candidates = Set(WorkspaceWindow.list().filter { $0.bundle == bundle && spec.permitsWindow($0.id, bundleIdentifier: bundle) }.map(\.id)) }
                if WorkspaceWindow.raise(ids: candidates, bundle: bundle, actionGate: focusActions) {
                    selectedWindowRecovery.recovered(); return
                }
                // A blacklist may exclude the only window in this application.
                // Recover to another permitted application without ending the lock.
                if let fallback = WorkspaceWindow.list(onScreen: false).first(where: {
                    $0.bundle != Bundle.main.bundleIdentifier && $0.id != window.id
                        && spec.permitsWindow($0.id, bundleIdentifier: $0.bundle)
                }), WorkspaceWindow.raise(ids: [fallback.id], bundle: fallback.bundle, actionGate: focusActions) {
                    selectedWindowRecovery.recovered(); return
                }
                // A single timeout or title/position mismatch must not release a
                // valid intention. Unknown inventory does not establish closure.
                let decision = selectedWindowRecovery.failed(now: ProcessInfo.processInfo.systemUptime,
                    resources: selectedNativeResourcePresence())
                if decision == .safetyStop { stopForSafety(cause: .selectedWindowRecoveryUnavailable) }
                return
            }
        }
        selectedWindowRecovery.recovered()

        if spec.strictSingleApp {
            guard frontmost.bundleIdentifier == spec.fallbackBundleIdentifier else {
                refocus()
                return
            }
            permittedWindowRecovery.remember(frontmost, verifiedWindow: focusedScopeWindow ?? WorkspaceWindow.focused())
            return
        }

        if spec.accessMode == .whitelist,
           frontmost.bundleIdentifier == "com.spotify.client", !spec.allowSpotifyForeground {
            refocus()
            return
        }

        guard let bundleIdentifier = frontmost.bundleIdentifier,
              spec.permitsApplication(bundleIdentifier) else {
            refocus()
            return
        }

        lastPermittedApplication = frontmost
        permittedWindowRecovery.remember(frontmost, verifiedWindow: focusedScopeWindow ?? WorkspaceWindow.focused())
        allowedAppSwitcher.recordActivation(bundleIdentifier: bundleIdentifier)
    }

    private func selectedNativeResourcePresence() -> FocusSelectedWindowRecoveryPolicy.ResourcePresence {
        guard spec.accessMode == .whitelist else { return .unknown }
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .unknown
        }
        let windows = WorkspaceWindow.list(records: rows)
        let liveWindows = Dictionary(grouping: windows, by: \.bundle).mapValues { Set($0.map(\.id)) }
        // A still-present selected WindowServer row which cannot be resolved
        // into this inventory is uncertainty, not positive window closure.
        let selectedIDs = Set(spec.selectedWindowIDsByApp.values.flatMap { $0 })
        let observedIDs = Set(windows.map(\.id))
        if rows.contains(where: {
            guard let id = $0[kCGWindowNumber as String] as? UInt32 else { return false }
            return selectedIDs.contains(id) && !observedIDs.contains(id)
        }) { return .unknown }
        let browsers = Set(spec.allowedWebsitesByBrowser.keys)
        let wholeApps = SelectedResourceLifetime.wholeAppSelections(
            allowedAppIDs: spec.allowedBundleIdentifiers,
            presetAppIDs: spec.presetAllowedBundleIdentifiers.union(spec.presetBlockedBundleIdentifiers),
            windowSelectionAppIDs: Set(spec.selectedWindowIDsByApp.keys), tabSelectionAppIDs: browsers)
        let browserPresence = Dictionary(uniqueKeysWithValues: browsers.map { ($0, SelectedResourceLifetime.BrowserPresence.unknown) })
        if SelectedResourceLifetime.shouldFinish(restrictive: true,
            selectedWindows: spec.selectedWindowIDsByApp, wholeApps: wholeApps,
            liveWindows: liveWindows, browsers: browserPresence) { return .closed }
        if wholeApps.contains(where: { !(liveWindows[$0] ?? []).isEmpty })
            || spec.selectedWindowIDsByApp.contains(where: { !($0.value.isDisjoint(with: liveWindows[$0.key] ?? [])) }) {
            return .present
        }
        return .unknown
    }

    private func refocus(ignoreSystemTransitionGrace: Bool = false, restoreWindow: Bool = false) {
        guard !isStopped,
              !FocusSystemToolPolicy.isScreenshotApplication(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        if !ignoreSystemTransitionGrace,
           shouldWaitForSystemSwitcher(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            return
        }

        if restoreWindow, permittedWindowRecovery.restore() { return }

        if spec.strictSingleApp {
            if permittedWindowRecovery.restore() { return }
            activateFallbackApp()
            return
        }

        if let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier) {
            return
        }

        activateBestPermittedApplication()
    }

    private func activateBestPermittedApplication() {
        guard !isStopped else { return }
        if permittedWindowRecovery.restore() { return }
        if let lastPermittedApplication,
           let bundleIdentifier = lastPermittedApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier),
           !lastPermittedApplication.isTerminated,
           !lastPermittedApplication.isHidden {
            _ = activateApp(processIdentifier: lastPermittedApplication.processIdentifier)
            return
        }

        if let returnApplication,
           let bundleIdentifier = returnApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier),
           !returnApplication.isTerminated {
            _ = activateApp(processIdentifier: returnApplication.processIdentifier)
            return
        }

        if activateFallbackApp() { return }
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular
                && !$0.isTerminated
                && spec.permitsApplication(bundleIdentifier)
        }) else { return }
        _ = activateApp(processIdentifier: application.processIdentifier)
    }

    private func shouldAllowMouseDown(at point: CGPoint) -> Bool {
        guard spec.blockAppSwitching || spec.keepFocused else {
            return true
        }

        let target = clickTarget(at: point)
        if let ownerBundleIdentifier = target.ownerBundleIdentifier,
           let owner = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == ownerBundleIdentifier
           }),
           FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
               bundleIdentifier: ownerBundleIdentifier,
               isRegularApplication: owner.activationPolicy == .regular,
               controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
               accessMode: spec.accessMode
           ) {
            return true
        }
        return FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: target.ownerBundleIdentifier,
            representedBundleIdentifier: target.representedBundleIdentifier,
            allowedBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            intentBundleIdentifier: Bundle.main.bundleIdentifier,
            accessMode: spec.accessMode,
            isMenuBarClick: isMenuBarClick(point)
        )
    }

    private func clickTarget(at point: CGPoint, inMissionControl: Bool = false) -> (
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?,
        isSpaceNavigation: Bool
    ) {
        if !inMissionControl, let owner = windowOwnerBundleIdentifier(at: point),
           !["com.apple.dock", "com.apple.WindowManager"].contains(owner) {
            return (owner, nil, false)
        }
        // Dock owns transformed Mission Control tiles. Looking at ordinary CG
        // window ownership first can instead identify the app behind a Space.
        let systemWide = inMissionControl
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
                .map { AXUIElementCreateApplication($0.processIdentifier) } ?? AXUIElementCreateSystemWide()
            : AXUIElementCreateSystemWide()
        // Bound synchronous accessibility work in the input callback. A hung app
        // must not hold every mouse click while the default AX timeout elapses.
        AXUIElementSetMessagingTimeout(systemWide, 0.01)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
           let element {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let ownerBundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? windowOwnerBundleIdentifier(at: point)
            let represented = ["com.apple.dock", "com.apple.WindowManager"].contains(ownerBundleIdentifier)
                ? representedTarget(startingAt: element, owner: ownerBundleIdentifier, inMissionControl: inMissionControl) : (nil, false)
            return (ownerBundleIdentifier, represented.0, represented.1)
        }

        return (windowOwnerBundleIdentifier(at: point), nil, false)
    }

    private func representedTarget(startingAt element: AXUIElement, owner: String?, inMissionControl: Bool) -> (String?, Bool) {
        var current: AXUIElement? = element
        var ancestry: [AXUIElement] = []
        var labels: [String] = []
        var representedBundle: String?
        let deadline = Date(timeIntervalSinceNow: 0.06)

        for _ in 0..<8 {
            guard Date() < deadline, let currentElement = current else { break }
            AXUIElementSetMessagingTimeout(currentElement, 0.006)

            let identifier = accessibilityString(currentElement, attribute: kAXIdentifierAttribute)
            if let identifier, FocusClickTargetPolicy.isMissionControlSpaceNavigation(ownerBundleIdentifier: owner,
                    ancestorIdentifiers: [identifier]) {
                return (nil, true)
            }
            if inMissionControl, FocusClickTargetPolicy.isMissionControlRepresentationBoundary(
                role: accessibilityString(currentElement, attribute: kAXRoleAttribute), identifier: identifier) {
                break
            }

            ancestry.append(currentElement)
            if Date() < deadline { current = accessibilityElement(currentElement, attribute: kAXParentAttribute) }
        }

        // Determine Space ancestry before asking for app URLs or labels. Those
        // reads can otherwise use the entire tap budget on a thumbnail's child.
        guard Date() < deadline else { return (nil, false) }
        for currentElement in ancestry {
            guard Date() < deadline else { break }

            if representedBundle == nil, let url = accessibilityURL(currentElement),
               let bundleIdentifier = ApplicationBundleIdentifierResolver.resolve(from: url) {
                representedBundle = bundleIdentifier
            }

            guard !inMissionControl else { continue }
            for attribute in [
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
                kAXRoleDescriptionAttribute
            ] {
                guard Date() < deadline else { break }
                if let value = accessibilityString(currentElement, attribute: attribute) {
                    labels.append(value)
                }
            }
        }

        if inMissionControl {
            return (FocusClickTargetPolicy.representedBundleIdentifier(labels: [], applicationNamesByBundleIdentifier: [:],
                verifiedApplicationBundleIdentifier: representedBundle, isMissionControl: true), false)
        }

        var applicationNames: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let name = application.localizedName
                ?? application.bundleURL.map { FileManager.default.displayName(atPath: $0.path) }
                ?? bundleIdentifier
            applicationNames[bundleIdentifier] = name.replacingOccurrences(of: ".app", with: "")
        }
        return (FocusClickTargetPolicy.representedBundleIdentifier(
            labels: labels,
            applicationNamesByBundleIdentifier: applicationNames,
            verifiedApplicationBundleIdentifier: representedBundle
        ), false)
    }

    private func isMenuBarClick(_ point: CGPoint) -> Bool {
        var displayID = CGDirectDisplayID()
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount) == .success,
              displayCount > 0 else {
            return false
        }
        let displayBounds = CGDisplayBounds(displayID)
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
        let menuBarHeight = max(
            30,
            screen.map { max(0, $0.frame.maxY - $0.visibleFrame.maxY) } ?? 0
        )
        return point.y >= displayBounds.minY
            && point.y <= displayBounds.minY + menuBarHeight
    }

    private func accessibilityURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else {
            return nil
        }
        if let url = value as? URL {
            return url
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    private func accessibilityString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func windowOwnerBundleIdentifier(at point: CGPoint) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer >= 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return nil
    }

    private func shouldWaitForSystemSwitcher(bundleIdentifier: String?) -> Bool {
        if FocusForegroundPolicy.shouldDeferRefocus(bundleIdentifier: bundleIdentifier) {
            systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 1.5)
            return true
        }

        return FocusForegroundPolicy.shouldHonorSystemTransitionGrace(
            bundleIdentifier: bundleIdentifier,
            graceUntil: systemSwitcherGraceUntil,
            now: Date()
        )
    }

    private func isSupportedBrowserFrontmost() -> Bool {
        supportedFrontmostBrowserBundleIdentifier() != nil
    }

    private func supportedFrontmostBrowserBundleIdentifier() -> String? {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !spec.presetAllowedBundleIdentifiers.contains(bundleIdentifier),
              ["org.mozilla.firefox", "com.google.Chrome"].contains(bundleIdentifier) else {
            return nil
        }
        return bundleIdentifier
    }

    private func isFirefoxFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "org.mozilla.firefox"
    }

    private func isSpotifyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client"
    }

    private func cleanup() {
        cancelPendingFocusActions()
        blurController.stop()
        nativeTabClickGuard.stop()
        permittedWindowRecovery.stop()
        pendingSpaceRecovery?.cancel()
        pendingSpaceRecovery = nil
        allowedAppSwitcher.cancel()
        focusTimer?.invalidate()
        focusTimer = nil

        spotifyTimer?.invalidate()
        spotifyTimer = nil

        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }

        let input = inputComponents(remove: true)
        input.driver?.stop()
        input.timer?.cancel()
        input.monitor?.stop()

        // Errors before readiness are not successful completion. Release this
        // attempted session's visibility changes; previously deferred windows
        // remain owned by their earlier occurrence and are not reopened.
        visibilityController.stop(restorationPolicyOverride: didBecomeReady ? nil : .automatic)
        if !spec.hideDistractions, !didStopForSafety, spec.accessMode == .whitelist, spec.closeSessionResourcesOnFinish {
            closeSessionResources()
        }
    }

    private func closeSessionResources() {
        for browserBundleIdentifier in spec.allowedWebsitesByBrowser.keys {
            let snapshot = BrowserTabSnapshotStore(
                browserBundleIdentifier: browserBundleIdentifier
            ).load(maxAge: 3)
            guard let browserSessionID = snapshot?.browserSessionID, !browserSessionID.isEmpty else { continue }
            for tab in snapshot?.tabs ?? [] {
                let store = BrowserTabCommandStore(browserBundleIdentifier: browserBundleIdentifier)
                try? store.write(
                    BrowserTabCommand(
                        tabID: tab.id,
                        windowID: tab.windowID,
                        action: .close,
                        browserSessionID: browserSessionID
                    )
                )
                let deadline = Date(timeIntervalSinceNow: 1)
                while FileManager.default.fileExists(atPath: store.fileURL.path), Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
            }
        }

        for application in NSWorkspace.shared.runningApplications where
            spec.allowedBundleIdentifiers.contains(application.bundleIdentifier ?? "") {
            application.terminate()
        }
    }

    private var isStopped: Bool {
        stopStateLock.lock()
        defer { stopStateLock.unlock() }
        return shouldStop
    }

    private func isMissionControlActive() -> Bool {
        let displayBounds = NSScreen.screens
            .map(\.frame)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let x = bounds["X"] as? CGFloat,
                let y = bounds["Y"] as? CGFloat,
                let width = bounds["Width"] as? CGFloat,
                let height = bounds["Height"] as? CGFloat
            else {
                return false
            }

            return displayBounds.contains { display in FocusForegroundPolicy.isMissionControlOverlay(
                ownerName: window[kCGWindowOwnerName as String] as? String,
                layer: window[kCGWindowLayer as String] as? Int,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                displayBounds: display
            ) }
        }
    }

    private func selectSideberyDataSciencePanel() {
        guard activateApp(bundleIdentifier: "org.mozilla.firefox") else { return }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.35))
        guard let bounds = windowBounds(for: "org.mozilla.firefox") else { return }

        // Sidebery panel dropdown sits in the bottom-left toolbar in this setup.
        click(x: bounds.x + 182, y: bounds.maxY - 32)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        click(x: bounds.x + 275, y: bounds.maxY - 560)
    }

    private func isProtectedFirefoxChromeClick(_ point: CGPoint) -> Bool {
        guard let bounds = windowBounds(for: "org.mozilla.firefox") else {
            return false
        }

        return FirefoxClickProtection.isProtected(
            point: point,
            windowBounds: FirefoxWindowBounds(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height),
            protectTopChrome: !spec.allowGoogleSearchTabs
        )
    }

    private func windowBounds(for bundleIdentifier: String) -> WindowBounds? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == app.processIdentifier,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let x = bounds["X"] as? CGFloat,
                let y = bounds["Y"] as? CGFloat,
                let width = bounds["Width"] as? CGFloat,
                let height = bounds["Height"] as? CGFloat
            else {
                continue
            }

            return WindowBounds(x: x, y: y, width: width, height: height)
        }

        return nil
    }

    private func click(x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

enum KeyCode {
    static let escape: Int64 = 53
    static let q: Int64 = 12
    static let w: Int64 = 13
    static let r: Int64 = 15
    static let t: Int64 = 17
    static let one: Int64 = 18
    static let two: Int64 = 19
    static let three: Int64 = 20
    static let four: Int64 = 21
    static let six: Int64 = 22
    static let five: Int64 = 23
    static let nine: Int64 = 25
    static let seven: Int64 = 26
    static let eight: Int64 = 28
    static let zero: Int64 = 29
    static let o: Int64 = 31
    static let leftBracket: Int64 = 33
    static let rightBracket: Int64 = 30
    static let l: Int64 = 37
    static let h: Int64 = 4
    static let n: Int64 = 45
    static let m: Int64 = 46
    static let tab: Int64 = 48
    static let space: Int64 = 49
    static let grave: Int64 = 50
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124
    static let downArrow: Int64 = 125
    static let upArrow: Int64 = 126
}
