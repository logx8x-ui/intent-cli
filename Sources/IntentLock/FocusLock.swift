import AppKit
import ApplicationServices
import Foundation
import IntentCore

public enum FocusLockError: Error, CustomStringConvertible {
    case accessibilityPermissionRequired
    case eventTapUnavailable
    case unableToOpen(String)

    public var description: String {
        switch self {
        case .accessibilityPermissionRequired:
            return "Intent needs Accessibility permission. Open System Settings > Privacy & Security > Accessibility and enable Intent, then start the intention again."
        case .eventTapUnavailable:
            return "Intent could not start the keyboard lock. Enable Accessibility/Input Monitoring for Intent, then start the intention again."
        case .unableToOpen(let name):
            return "Intent could not open \(name)."
        }
    }
}

public enum FocusForegroundPolicy {
    public static func shouldImmediatelyReject(
        bundleIdentifier: String?,
        accessMode: IntentionAccessMode,
        controlledBundleIdentifiers: Set<String>
    ) -> Bool {
        guard accessMode == .blacklist, let bundleIdentifier else { return false }
        return controlledBundleIdentifiers.contains(bundleIdentifier)
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
    private let stopStateLock = NSLock()
    private let allowedAppSwitcher: AllowedAppSwitcher
    private let allowedBrowserTabSwitcher = AllowedBrowserTabSwitcher()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var focusTimer: Timer?
    private var spotifyTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var baselinePids = Set<pid_t>()
    private var returnApplication: NSRunningApplication?
    private var lastPermittedApplication: NSRunningApplication?
    private var systemSwitcherGraceUntil: Date = .distantPast

    public init(spec: FocusSessionSpec) {
        self.spec = spec
        allowedAppSwitcher = AllowedAppSwitcher(
            allowedBundleIdentifiers: spec.allowedBundleIdentifiers,
            accessMode: spec.accessMode
        )
    }

    public func stop() {
        stopStateLock.lock()
        shouldStop = true
        stopStateLock.unlock()
    }

    public func run() throws {
        returnApplication = NSWorkspace.shared.frontmostApplication
        if let returnApplication,
           let bundleIdentifier = returnApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier) {
            lastPermittedApplication = returnApplication
        }
        allowedAppSwitcher.recordActivation(bundleIdentifier: returnApplication?.bundleIdentifier)

        guard requestAccessibilityIfNeeded() else {
            throw FocusLockError.accessibilityPermissionRequired
        }

        baselinePids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))

        try installEventTap()
        installLaunchObserver()
        installActivationObserver()
        installActiveSpaceObserver()
        startFocusTimer()
        startSpotifyTimerIfNeeded()

        do {
            try runStartupSteps()
            while !isStopped {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
            }
        } catch {
            cleanup()
            throw error
        }

        cleanup()
        if spec.restorePreviousApplicationOnStop {
            returnApplication?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        AccessibilityAuthorizationGate.system().waitForTrust()
    }

    private func runStartupSteps() throws {
        for step in spec.startupSteps {
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

        guard !spec.fallbackBundleIdentifier.isEmpty else { return }

        let deadline = Date(timeIntervalSinceNow: 6)
        while Date() < deadline {
            if activateFallbackApp() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
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
                if let tab = snapshotStore.load(maxAge: 2)?.tabs.first(where: {
                    Self.urlsRepresentSameStartupSite($0.url, url)
                }) {
                    try? BrowserTabCommandStore(browserBundleIdentifier: bundleIdentifier).write(
                        BrowserTabCommand(tabID: tab.id, windowID: tab.windowID)
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

        _ = app.activate(options: [.activateIgnoringOtherApps])
        return app.isActive
    }

    @discardableResult
    private func activateApp(processIdentifier: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }

        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func installEventTap() throws {
        let mask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
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
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            if isMissionControlActive() {
                let target = clickTarget(at: event.location)
                guard FocusClickTargetPolicy.shouldAllowMissionControlClick(
                    ownerBundleIdentifier: target.ownerBundleIdentifier,
                    representedBundleIdentifier: target.representedBundleIdentifier,
                    controlledBundleIdentifiers: spec.allowedBundleIdentifiers,
                    accessMode: spec.accessMode
                ) else {
                    refocus(ignoreSystemTransitionGrace: true)
                    return nil
                }
                systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 1.5)
                return Unmanaged.passUnretained(event)
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
            if allowedBrowserTabSwitcher.isVisible,
               !event.flags.contains(.maskControl) {
                allowedBrowserTabSwitcher.commit()
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

        if command && keyCode == KeyCode.tab && (spec.blockAppSwitching || spec.keepFocused) {
            allowedBrowserTabSwitcher.cancel()
            allowedAppSwitcher.advance(reverse: shift)
            return nil
        }

        if control,
           keyCode == KeyCode.tab,
           spec.blockBrowserTabEscape,
           let browserBundleIdentifier = supportedFrontmostBrowserBundleIdentifier() {
            let didShowSwitcher = allowedBrowserTabSwitcher.advance(
                browserBundleIdentifier: browserBundleIdentifier,
                reverse: shift
            )
            if didShowSwitcher {
                allowedAppSwitcher.cancel()
                return nil
            }

            // Older, disconnected, or sleeping Browser Guard builds may not
            // have published a tab snapshot. Preserve native Ctrl+Tab rather
            // than swallowing the shortcut with no visible result.
            return Unmanaged.passUnretained(event)
        }

        if keyCode == KeyCode.escape,
           allowedAppSwitcher.isVisible || allowedBrowserTabSwitcher.isVisible {
            allowedAppSwitcher.cancel()
            allowedBrowserTabSwitcher.cancel()
            return nil
        }

        if spec.finishShortcut.matches(
            keyCode: keyCode,
            command: command,
            shift: shift,
            control: control,
            option: option
        ) {
            if spec.allowsManualFinish {
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
            self?.systemSwitcherGraceUntil = Date(timeIntervalSinceNow: 1.0)
        }
    }

    private func handleLaunched(_ app: NSRunningApplication) {
        guard spec.blockNewApps else { return }
        guard let bundleIdentifier = app.bundleIdentifier else { return }
        guard !spec.permitsApplication(bundleIdentifier) else { return }
        guard app.activationPolicy == .regular else { return }
        guard !baselinePids.contains(app.processIdentifier) else { return }

        app.terminate()
        refocus()
    }

    private func handleActivated(_ app: NSRunningApplication) {
        guard spec.blockAppSwitching || spec.keepFocused else { return }

        if FocusForegroundPolicy.shouldImmediatelyReject(
            bundleIdentifier: app.bundleIdentifier,
            accessMode: spec.accessMode,
            controlledBundleIdentifiers: spec.allowedBundleIdentifiers
        ) {
            refocus(ignoreSystemTransitionGrace: true)
            return
        }

        if FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
            bundleIdentifier: app.bundleIdentifier,
            isRegularApplication: app.activationPolicy == .regular,
            controlledBundleIdentifiers: spec.allowedBundleIdentifiers,
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
        guard spec.blockAppSwitching || spec.keepFocused else { return }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            if shouldWaitForSystemSwitcher(bundleIdentifier: nil) {
                return
            }
            refocus()
            return
        }

        if FocusForegroundPolicy.shouldImmediatelyReject(
            bundleIdentifier: frontmost.bundleIdentifier,
            accessMode: spec.accessMode,
            controlledBundleIdentifiers: spec.allowedBundleIdentifiers
        ) {
            refocus(ignoreSystemTransitionGrace: true)
            return
        }

        if FocusClickTargetPolicy.shouldAllowAuxiliaryApplication(
            bundleIdentifier: frontmost.bundleIdentifier,
            isRegularApplication: frontmost.activationPolicy == .regular,
            controlledBundleIdentifiers: spec.allowedBundleIdentifiers,
            accessMode: spec.accessMode
        ) {
            return
        }

        if shouldWaitForSystemSwitcher(bundleIdentifier: frontmost.bundleIdentifier) {
            return
        }

        if spec.strictSingleApp {
            guard frontmost.bundleIdentifier == spec.fallbackBundleIdentifier else {
                refocus()
                return
            }
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
        allowedAppSwitcher.recordActivation(bundleIdentifier: bundleIdentifier)
    }

    private func refocus(ignoreSystemTransitionGrace: Bool = false) {
        if !ignoreSystemTransitionGrace,
           shouldWaitForSystemSwitcher(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            return
        }

        if spec.strictSingleApp {
            activateFallbackApp()
            return
        }

        if let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier) {
            return
        }

        if spec.accessMode == .blacklist {
            activateBestPermittedApplication()
        } else {
            activateFallbackApp()
        }
    }

    private func activateBestPermittedApplication() {
        if let lastPermittedApplication,
           let bundleIdentifier = lastPermittedApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier),
           !lastPermittedApplication.isTerminated {
            _ = lastPermittedApplication.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let returnApplication,
           let bundleIdentifier = returnApplication.bundleIdentifier,
           spec.permitsApplication(bundleIdentifier),
           !returnApplication.isTerminated {
            _ = returnApplication.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return $0.activationPolicy == .regular
                && !$0.isTerminated
                && spec.permitsApplication(bundleIdentifier)
        }) else { return }
        _ = application.activate(options: [.activateIgnoringOtherApps])
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
               controlledBundleIdentifiers: spec.allowedBundleIdentifiers,
               accessMode: spec.accessMode
           ) {
            return true
        }
        return FocusClickTargetPolicy.shouldAllow(
            ownerBundleIdentifier: target.ownerBundleIdentifier,
            representedBundleIdentifier: target.representedBundleIdentifier,
            allowedBundleIdentifiers: spec.allowedBundleIdentifiers,
            intentBundleIdentifier: Bundle.main.bundleIdentifier,
            accessMode: spec.accessMode,
            isMenuBarClick: isMenuBarClick(point)
        )
    }

    private func clickTarget(at point: CGPoint) -> (
        ownerBundleIdentifier: String?,
        representedBundleIdentifier: String?
    ) {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
           let element {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let ownerBundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? windowOwnerBundleIdentifier(at: point)
            return (
                ownerBundleIdentifier,
                representedBundleIdentifier(startingAt: element)
            )
        }

        return (windowOwnerBundleIdentifier(at: point), nil)
    }

    private func representedBundleIdentifier(startingAt element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        var labels: [String] = []

        for _ in 0..<8 {
            guard let currentElement = current else { break }

            if let url = accessibilityURL(currentElement),
               let bundleIdentifier = ApplicationBundleIdentifierResolver.resolve(from: url) {
                return bundleIdentifier
            }

            for attribute in [
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
                kAXRoleDescriptionAttribute
            ] {
                if let value = accessibilityString(currentElement, attribute: attribute) {
                    labels.append(value)
                }
            }

            current = accessibilityElement(currentElement, attribute: kAXParentAttribute)
        }

        var applicationNames: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let name = application.localizedName
                ?? application.bundleURL.map { FileManager.default.displayName(atPath: $0.path) }
                ?? bundleIdentifier
            applicationNames[bundleIdentifier] = name.replacingOccurrences(of: ".app", with: "")
        }
        return FocusClickTargetPolicy.representedBundleIdentifier(
            labels: labels,
            applicationNamesByBundleIdentifier: applicationNames
        )
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
                  layer == 0,
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
        allowedAppSwitcher.cancel()
        allowedBrowserTabSwitcher.cancel()
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

        if spec.accessMode == .whitelist, spec.closeSessionResourcesOnFinish {
            closeSessionResources()
        }
    }

    private func closeSessionResources() {
        for browserBundleIdentifier in spec.allowedWebsitesByBrowser.keys {
            let snapshot = BrowserTabSnapshotStore(
                browserBundleIdentifier: browserBundleIdentifier
            ).load(maxAge: 3)
            for tab in snapshot?.tabs ?? [] {
                let store = BrowserTabCommandStore(browserBundleIdentifier: browserBundleIdentifier)
                try? store.write(
                    BrowserTabCommand(
                        tabID: tab.id,
                        windowID: tab.windowID,
                        action: .close
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
            .reduce(CGRect.null) { partialResult, frame in
                partialResult.union(frame)
            }

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

            return FocusForegroundPolicy.isMissionControlOverlay(
                ownerName: window[kCGWindowOwnerName as String] as? String,
                layer: window[kCGWindowLayer as String] as? Int,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                displayBounds: displayBounds
            )
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
