import AppKit
import ApplicationServices
import Foundation
import IntentCore

public enum FocusLockError: Error, CustomStringConvertible {
    case accessibilityPermissionRequired
    case eventTapUnavailable
    case unableToOpen(String)
    case quickSelectionStartChanged
    case browserWindowEnforcementFailed(BrowserWindowEnforcementPolicy.Failure)
    case browserWindowCoverageFailed(BrowserWindowCoveragePolicy.Failure)

    public var description: String {
        switch self {
        case .accessibilityPermissionRequired:
            return "Intent needs Accessibility permission. Open System Settings > Privacy & Security > Accessibility and enable Intent, then start the intention again."
        case .eventTapUnavailable:
            return "Intent could not start the keyboard lock. Enable Accessibility/Input Monitoring for Intent, then start the intention again."
        case .unableToOpen(let name):
            return "Intent could not open \(name)."
        case .quickSelectionStartChanged:
            return "Your Run window or tab changed while Intent was preparing. Run again from the window you want."
        case .browserWindowCoverageFailed(let failure):
            return failure.message
        case .browserWindowEnforcementFailed(let failure):
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
        guard let bundleIdentifier, bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
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
    private let permittedWindowRecovery = PermittedWindowRecovery()
    private var eventTap: CFMachPort?
    private var suppressedTabButtons: Set<Int64> = []
    private var runLoopSource: CFRunLoopSource?
    private var focusTimer: Timer?
    private var spotifyTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var pendingSpaceRecovery: DispatchWorkItem?
    private var baselinePids = Set<pid_t>()
    private var returnApplication: NSRunningApplication?
    private var lastPermittedApplication: NSRunningApplication?
    private var didBecomeReady = false
    private var systemSwitcherGraceUntil: Date = .distantPast

    public var onManualFinishRequest: (@Sendable () -> Void)?

    public init(spec: FocusSessionSpec) {
        self.spec = spec
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
        visibilityController.enforcementIsCurrent = { [weak self] in self?.isStopRequested == false }
    }

    public func stop() {
        stopStateLock.lock()
        shouldStop = true
        stopStateLock.unlock()
        cancelPendingFocusActions()
        visibilityController.stop()
    }

    private var suppressReturnActivation = false

    public func stopForExpiry() {
        stopStateLock.lock()
        suppressReturnActivation = true
        shouldStop = true
        stopStateLock.unlock()
        cancelPendingFocusActions()
        visibilityController.stop()
    }

    public func updateFinishShortcut(_ shortcut: FocusKeyboardShortcut) {
        stopStateLock.lock()
        currentFinishShortcut = shortcut
        stopStateLock.unlock()
    }

    private var finishShortcut: FocusKeyboardShortcut {
        stopStateLock.lock()
        defer { stopStateLock.unlock() }
        return currentFinishShortcut
    }

    public func stopForSafety(failure: FocusLockError? = nil) {
        stopStateLock.lock()
        // A delayed failure must not turn manual/expiry completion into an
        // error, nor affect a replacement occurrence. Never hold this mutex
        // while synchronously entering the main-thread visibility controller.
        if failure != nil && shouldStop { stopStateLock.unlock(); return }
        if let failure { safetyFailure = failure; suppressReturnActivation = true }
        safetyStop = true
        shouldStop = true
        stopStateLock.unlock()
        cancelPendingFocusActions()
        // Quit can terminate the process before run-loop cleanup executes.
        // Release owned visibility synchronously before returning to AppKit.
        visibilityController.stop(restorationPolicyOverride: .automatic)
    }

    private func cancelPendingFocusActions() {
        // Do this at the stop request, not up to one run-loop turn later in
        // cleanup: queued Cmd-Tab and AX work can otherwise steal focus
        // after the session has already ended.
        focusActions.invalidate()
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
            throw FocusLockError.accessibilityPermissionRequired
        }
        guard !isStopped else { return }
        try validateStartupAnchor()

        baselinePids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        defer { cleanup() }

        // Leisure is a launch-only session. It must not install a blocking input tap.
        if spec.requiresEnforcement {
            try installEventTap()
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
            if !isStopped { didBecomeReady = true; onReady?() }
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
            if let app = NSWorkspace.shared.frontmostApplication { permittedWindowRecovery.remember(app) }
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

        return focusActions.perform(ifCurrent: 0) {
            _ = app.activate(options: [.activateIgnoringOtherApps])
            return app.isActive
        } ?? false
    }

    @discardableResult
    private func activateApp(processIdentifier: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }

        return focusActions.perform(ifCurrent: 0) {
            app.activate(options: [.activateIgnoringOtherApps])
        } ?? false
    }

    private func installEventTap() throws {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDragged, .scrollWheel,
                                   .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let lock = Unmanaged<FocusLock>.fromOpaque(userInfo).takeUnretainedValue()
            return lock.handle(type: type, event: event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            throw FocusLockError.eventTapUnavailable
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            throw FocusLockError.eventTapUnavailable
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never repeatedly re-enable an input tap that macOS disabled as unhealthy.
            stopForSafety()
            return Unmanaged.passUnretained(event)
        }
        if isStopped { return Unmanaged.passUnretained(event) }
        if type == .scrollWheel {
            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let wholeWindowBlocked = nativeTabClickGuard.blocksForegroundWindow(foregroundPID)
            // Do not intercept normal tab/sidebar scrolling or scroll over a
            // different window. shouldBlock also exempts registered controls.
            let pointerBlocked = wholeWindowBlocked && nativeTabClickGuard.shouldBlock(event.location, frontmostPID: foregroundPID,
                targetWindowID: UInt32(clamping: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)))
            if NativeTabClickPolicy.blocksScroll(wholeWindowBlocked: wholeWindowBlocked,
                pointerBlocked: pointerBlocked, missionControl: pointerBlocked && isMissionControlActive()) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) {
            if suppressedTabButtons.remove(event.getIntegerValueField(.mouseEventButtonNumber)) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDragged {
            if suppressedTabButtons.contains(0) { return nil }
            nativeTabClickGuard.invalidateDuringDrag()
            return Unmanaged.passUnretained(event)
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            guard spec.requiresEnforcement else { return Unmanaged.passUnretained(event) }
            let missionControl = isMissionControlActive()
            nativeTabClickGuard.recordMouseDown(missionControl: missionControl)
            if missionControl {
                let target = clickTarget(at: event.location, inMissionControl: true)
                guard FocusClickTargetPolicy.shouldAllowMissionControlClick(
                    ownerBundleIdentifier: target.ownerBundleIdentifier,
                    representedBundleIdentifier: target.representedBundleIdentifier,
                    controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
                    accessMode: spec.accessMode,
                    isSpaceNavigation: target.isSpaceNavigation
                ) else {
                    // Keep Mission Control open; a known forbidden tile is a no-op.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            if IntentInteractivePanelRegions.shared.contains(event.location) {
                return Unmanaged.passUnretained(event)
            }

            if nativeTabClickGuard.shouldBlock(event.location, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                targetWindowID: UInt32(clamping: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))) {
                // A forbidden native tab is a no-op: do not activate it and bounce afterward.
                suppressedTabButtons.insert(event.getIntegerValueField(.mouseEventButtonNumber))
                return nil
            }

            if spec.blockFirefoxChromeClicks,
               isFirefoxFrontmost(),
               isProtectedFirefoxChromeClick(event.location) {
                refocus()
                return nil
            }

            guard shouldAllowMouseDown(at: event.location) else {
                refocus()
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            if allowedAppSwitcher.isVisible,
               !event.flags.contains(.maskCommand) {
                allowedAppSwitcher.commit()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)

        if command && control && option && keyCode == KeyCode.escape {
            stopForSafety()
            return nil
        }

        switch FocusSystemShortcutPolicy.tabRoute(keyCode: keyCode, command: command, control: control,
            restrictApplicationSwitching: spec.blockAppSwitching || spec.keepFocused) {
        case .allowedApplications:
            allowedAppSwitcher.advance(reverse: shift)
            return nil
        case .nativeBrowser:
            // Native Control-Tab/Control-Shift-Tab, including key repeats, goes
            // directly to the browser. Guard keeps the destination policy.
            return Unmanaged.passUnretained(event)
        case .ordinary:
            break
        }

        if keyCode == KeyCode.escape,
           allowedAppSwitcher.isVisible {
            allowedAppSwitcher.cancel()
            return nil
        }

        if finishShortcut.matches(
            keyCode: keyCode,
            command: command,
            shift: shift,
            control: control,
            option: option
        ) {
            if let onManualFinishRequest { onManualFinishRequest() }
            else if spec.allowsManualFinish {
                stop()
            }
            return nil
        }

        if command && shouldBlockSystemCommand && isBlockedSystemCommand(keyCode) {
            refocus()
            return nil
        }

        if control,
           shouldBlockSystemCommand,
           FocusSystemShortcutPolicy.isSpaceNavigationKey(keyCode) {
            systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 1.5)
            return Unmanaged.passUnretained(event)
        }

        // A browser with no permitted tab cannot redirect an already-open or
        // internal page. Keep its content inert without closing anything. The
        // stop/switcher routes above and Intent's grave-key controls stay usable.
        if keyCode != KeyCode.grave,
           !(keyCode == KeyCode.tab && (command || control)),
           !(control && FocusSystemShortcutPolicy.isSpaceNavigationKey(keyCode)),
           !FocusBrowserShortcutPolicy.createsSearchSurface(keyCode: keyCode, command: command, control: control,
                option: option, shift: shift, allowGoogleSearchTabs: spec.allowGoogleSearchTabs),
           !IntentInteractivePanelRegions.shared.hasKeyboardFocus,
           nativeTabClickGuard.blocksForegroundWindow(NSWorkspace.shared.frontmostApplication?.processIdentifier) {
            return nil
        }

        if [Int64(36), Int64(76)].contains(keyCode),
           !IntentInteractivePanelRegions.shared.hasKeyboardFocus,
           nativeTabClickGuard.blocksAddressSubmission(NSWorkspace.shared.frontmostApplication?.processIdentifier) {
            return nil
        }

        if spec.accessMode == .whitelist,
           spec.blockBrowserTabEscape && isSupportedBrowserFrontmost() {
            if isBlockedBrowserCommand(keyCode: keyCode, command: command, control: control, option: option, shift: shift) {
                refocus()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
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
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }

            self.handleActivated(app)
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
        permittedWindowRecovery.noteSpaceChange()
        systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 0.15)
        pendingSpaceRecovery?.cancel()
        recoverSpace(attempt: 0)
    }

    private func recoverSpace(attempt: Int) {
        guard !isStopped else { return }
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
        // An empty Space activates its desktop shell. It is not an attempt to
        // open a blocked Finder window, and must not pull the user back.
        if FocusForegroundPolicy.shouldLeaveEmptyDesktopAlone(
            visibleBundleIdentifier: PermittedWindowRecovery.visibleApplication()?.bundleIdentifier,
            foregroundBundleIdentifier: app.bundleIdentifier
        ) {
            return
        }
        if let id = app.bundleIdentifier, spec.selectedWindowIDsByApp[id] != nil,
           let window = WorkspaceWindow.focused(), window.bundle == id,
           !spec.permitsWindow(window.id, bundleIdentifier: id) {
            // Let the window-scoped focus pass restore a permitted target; never
            // remember this blocked window as our recovery destination.
            return
        }
        if let id = app.bundleIdentifier, app.activationPolicy == .regular,
           spec.permitsApplication(id),
           id != "com.spotify.client" || spec.allowSpotifyForeground || spec.accessMode == .blacklist {
            lastPermittedApplication = app
            permittedWindowRecovery.remember(app)
            allowedAppSwitcher.recordActivation(bundleIdentifier: id)
            return
        }

        if FocusForegroundPolicy.shouldImmediatelyReject(
            bundleIdentifier: app.bundleIdentifier,
            accessMode: spec.accessMode,
            controlledBundleIdentifiers: spec.applicationWideControlledBundleIdentifiers,
            isRegularApplication: app.activationPolicy == .regular
        ) {
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

        if let bundle = frontmost.bundleIdentifier, spec.selectedWindowIDsByApp[bundle] != nil,
           let window = WorkspaceWindow.focused(), !spec.permitsWindow(window.id, bundleIdentifier: bundle) {
            let candidates: Set<UInt32>
            if spec.accessMode == .whitelist { candidates = spec.selectedWindowIDsByApp[bundle] ?? [] }
            else { candidates = Set(WorkspaceWindow.list().filter { $0.bundle == bundle && spec.permitsWindow($0.id, bundleIdentifier: bundle) }.map(\.id)) }
            if WorkspaceWindow.raise(ids: candidates, bundle: bundle, actionGate: focusActions) { return }
            // A blacklist may exclude the only window in this application.
            // Recover to another permitted application without ending the lock.
            if let fallback = WorkspaceWindow.list(onScreen: false).first(where: {
                $0.bundle != Bundle.main.bundleIdentifier && $0.id != window.id
                    && spec.permitsWindow($0.id, bundleIdentifier: $0.bundle)
            }), WorkspaceWindow.raise(ids: [fallback.id], bundle: fallback.bundle, actionGate: focusActions) { return }
            // No usable destination: release instead of trapping the computer.
            stopForSafety()
            return
        }

        if spec.strictSingleApp {
            guard frontmost.bundleIdentifier == spec.fallbackBundleIdentifier else {
                refocus()
                return
            }
            permittedWindowRecovery.remember(frontmost)
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
        permittedWindowRecovery.remember(frontmost)
        allowedAppSwitcher.recordActivation(bundleIdentifier: bundleIdentifier)
    }

    private func refocus(ignoreSystemTransitionGrace: Bool = false, restoreWindow: Bool = false) {
        guard !isStopped else { return }
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
                ? representedTarget(startingAt: element, owner: ownerBundleIdentifier) : (nil, false)
            return (ownerBundleIdentifier, represented.0, represented.1)
        }

        return (windowOwnerBundleIdentifier(at: point), nil, false)
    }

    private func representedTarget(startingAt element: AXUIElement, owner: String?) -> (String?, Bool) {
        var current: AXUIElement? = element
        var ancestry: [AXUIElement] = []
        var labels: [String] = []
        var representedBundle: String?
        let deadline = Date(timeIntervalSinceNow: 0.06)

        for _ in 0..<8 {
            guard Date() < deadline, let currentElement = current else { break }
            AXUIElementSetMessagingTimeout(currentElement, 0.006)

            if let identifier = accessibilityString(currentElement, attribute: kAXIdentifierAttribute),
               FocusClickTargetPolicy.isMissionControlSpaceNavigation(ownerBundleIdentifier: owner,
                    ancestorIdentifiers: [identifier]) {
                return (nil, true)
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

        var applicationNames: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let name = application.localizedName
                ?? application.bundleURL.map { FileManager.default.displayName(atPath: $0.path) }
                ?? bundleIdentifier
            applicationNames[bundleIdentifier] = name.replacingOccurrences(of: ".app", with: "")
        }
        return (representedBundle ?? FocusClickTargetPolicy.representedBundleIdentifier(
            labels: labels,
            applicationNamesByBundleIdentifier: applicationNames
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

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

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
