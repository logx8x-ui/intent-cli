import AppKit
import ApplicationServices
import Foundation

enum FocusLockError: Error, CustomStringConvertible {
    case accessibilityPermissionRequired
    case eventTapUnavailable
    case unableToOpen(String)

    var description: String {
        switch self {
        case .accessibilityPermissionRequired:
            return "Intent needs Accessibility permission. Open System Settings > Privacy & Security > Accessibility, enable your terminal app, then run Intent again."
        case .eventTapUnavailable:
            return "Intent could not start the keyboard lock. Enable Accessibility/Input Monitoring for your terminal app, then run Intent again."
        case .unableToOpen(let name):
            return "Intent could not open \(name)."
        }
    }
}

final class FocusLock {
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
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var focusTimer: Timer?
    private var spotifyTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var baselinePids = Set<pid_t>()
    private var returnApplication: NSRunningApplication?

    init(spec: FocusSessionSpec) {
        self.spec = spec
    }

    func run() throws {
        returnApplication = NSWorkspace.shared.frontmostApplication

        guard requestAccessibilityIfNeeded() else {
            throw FocusLockError.accessibilityPermissionRequired
        }

        baselinePids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))

        try runStartupSteps()
        try installEventTap()
        installLaunchObserver()
        startFocusTimer()
        startSpotifyTimerIfNeeded()

        while !shouldStop {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }

        cleanup()
        returnApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func runStartupSteps() throws {
        for step in spec.startupSteps {
            switch step {
            case .openBundle(let bundleIdentifier):
                try open(arguments: ["-b", bundleIdentifier], label: bundleIdentifier)
            case .openURL(let url, let bundleIdentifier):
                try open(arguments: ["-b", bundleIdentifier, url], label: url)
            case .selectSideberyDataSciencePanel:
                selectSideberyDataSciencePanel()
            case .playSpotifyPlaylist(let uri):
                try playSpotifyPlaylist(uri)
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.45))
        }

        let deadline = Date(timeIntervalSinceNow: 6)
        while Date() < deadline {
            if activateFallbackApp() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        throw FocusLockError.unableToOpen(spec.displayName)
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

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @discardableResult
    private func activateApp(processIdentifier: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func installEventTap() throws {
        let mask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
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
            if spec.blockFirefoxChromeClicks,
               isFirefoxFrontmost(),
               isProtectedFirefoxChromeClick(event.location) {
                refocus()
                return nil
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

        if command && shift && keyCode == KeyCode.m {
            shouldStop = true
            return nil
        }

        if command && isBlockedSystemCommand(keyCode) {
            refocus()
            return nil
        }

        if control && isSpaceSwitchKey(keyCode) {
            refocus()
            return nil
        }

        if spec.blockBrowserTabEscape && isFirefoxFrontmost() {
            if isBlockedBrowserCommand(keyCode: keyCode, command: command, control: control, option: option) {
                refocus()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func isBlockedSystemCommand(_ keyCode: Int64) -> Bool {
        [
            KeyCode.tab,
            KeyCode.space,
            KeyCode.q,
            KeyCode.h,
            KeyCode.m,
            KeyCode.grave
        ].contains(keyCode)
    }

    private func isBlockedBrowserCommand(keyCode: Int64, command: Bool, control: Bool, option: Bool) -> Bool {
        if control && keyCode == KeyCode.tab {
            return true
        }

        if command && option && [KeyCode.leftArrow, KeyCode.rightArrow].contains(keyCode) {
            return true
        }

        if command && browserCommandKeys.contains(keyCode) {
            return true
        }

        return false
    }

    private var browserCommandKeys: Set<Int64> {
        [
            KeyCode.zero,
            KeyCode.one,
            KeyCode.two,
            KeyCode.three,
            KeyCode.four,
            KeyCode.five,
            KeyCode.six,
            KeyCode.seven,
            KeyCode.eight,
            KeyCode.nine,
            KeyCode.leftBracket,
            KeyCode.rightBracket,
            KeyCode.leftArrow,
            KeyCode.rightArrow,
            KeyCode.l,
            KeyCode.n,
            KeyCode.o,
            KeyCode.r,
            KeyCode.t,
            KeyCode.w
        ]
    }

    private func isSpaceSwitchKey(_ keyCode: Int64) -> Bool {
        [
            KeyCode.leftArrow,
            KeyCode.rightArrow,
            KeyCode.upArrow,
            KeyCode.downArrow
        ].contains(keyCode)
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

    private func handleLaunched(_ app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return }
        guard !spec.allowedBundleIdentifiers.contains(bundleIdentifier) else { return }
        guard app.activationPolicy == .regular else { return }
        guard !baselinePids.contains(app.processIdentifier) else { return }

        app.terminate()
        refocus()
    }

    private func startFocusTimer() {
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
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
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            refocus()
            return
        }

        if spec.strictSingleApp {
            guard frontmost.bundleIdentifier == spec.fallbackBundleIdentifier else {
                refocus()
                return
            }
            return
        }

        if frontmost.bundleIdentifier == "com.spotify.client", !spec.allowSpotifyForeground {
            refocus()
            return
        }

        guard let bundleIdentifier = frontmost.bundleIdentifier,
              spec.allowedBundleIdentifiers.contains(bundleIdentifier) else {
            refocus()
            return
        }
    }

    private func refocus() {
        if spec.strictSingleApp {
            activateFallbackApp()
            return
        }

        if let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           spec.allowedBundleIdentifiers.contains(bundleIdentifier) {
            return
        }

        activateFallbackApp()
    }

    private func isFirefoxFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "org.mozilla.firefox"
    }

    private func isSpotifyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client"
    }

    private func cleanup() {
        focusTimer?.invalidate()
        focusTimer = nil

        spotifyTimer?.invalidate()
        spotifyTimer = nil

        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
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

        guard point.x >= bounds.x,
              point.x <= bounds.maxX,
              point.y >= bounds.y,
              point.y <= bounds.maxY else {
            return false
        }

        let localX = point.x - bounds.x
        let localY = point.y - bounds.y

        let topChromeHeight: CGFloat = 105
        let sideberyToolbarWidth: CGFloat = 470
        let sideberyBottomToolbarHeight: CGFloat = 74

        if localY <= topChromeHeight {
            return true
        }

        if localX <= sideberyToolbarWidth && localY >= bounds.height - sideberyBottomToolbarHeight {
            return true
        }

        return false
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

private enum KeyCode {
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
