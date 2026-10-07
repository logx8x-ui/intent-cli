import AppKit

/// Exercises the production companion's activation lifetime without ordering a
/// window, posting input, launching a browser, or changing the real key window.
@MainActor
enum NativeWebsiteFinderCompanionChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let originalKeyWindow = NSApp.keyWindow
        let originalActive = NSApp.isActive
        let notifications = NotificationCenter()
        let context = Context()
        let panel = RecordingPanel(contentRect: .init(x: 10, y: 10, width: 580, height: 76),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let presentation = NativeWebsiteFinderCompanionPresentation(panel: panel,
            notifications: notifications, isApplicationActive: { context.active },
            onFocusControls: { context.focusRequests += 1 })
        try check(panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel),
            "The actual finder panel permits keyboard access without becoming main or activating Intent")
        try check(!presentation.focusControls() && panel.events.isEmpty,
            "An unpresented finder cannot intercept an explicit reopen")

        context.active = true
        presentation.show(); presentation.show()
        try check(panel.events == ["show"] && context.focusRequests == 0,
            "Initial and repeated presentation never take typing, even when Intent initially owns focus")

        context.active = false
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try check(panel.events == ["show"] && context.focusRequests == 0,
            "A stale activation notification while the browser is foreground cannot take typing")

        context.active = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try check(panel.events == ["show", "focus"] && context.focusRequests == 1,
            "Deliberately activating Intent focuses this finder companion instead of its overview")
        try check(presentation.focusControls() && panel.events == ["show", "focus", "focus"] && context.focusRequests == 2,
            "Explicit reopen also reaches the controls when Intent was already active")

        presentation.dismiss()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        presentation.show(); presentation.dismiss()
        try check(!presentation.focusControls() && panel.events == ["show", "focus", "focus", "hide"] && context.focusRequests == 2,
            "Dismissal removes activation ownership and stale show/reopen work cannot resurrect the finder")

        let releasedPanel = RecordingPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        releasedPanel.isReleasedWhenClosed = false
        defer { releasedPanel.close() }
        var released: NativeWebsiteFinderCompanionPresentation? = .init(panel: releasedPanel,
            notifications: notifications, isApplicationActive: { true }, onFocusControls: {})
        weak var weakPresentation = released
        released?.show(); released = nil
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try check(weakPresentation == nil && releasedPanel.events == ["show"],
            "Activation observation cannot retain a released finder or focus its former window")
        try check(NSApp.keyWindow === originalKeyWindow && NSApp.isActive == originalActive,
            "Companion regressions leave the real desktop and keyboard focus unchanged")
    }

    @MainActor private final class Context {
        var active = false
        var focusRequests = 0
    }

    private final class RecordingPanel: NativeWebsiteFinderPanel {
        var events: [String] = []
        override func orderFrontRegardless() { events.append("show") }
        override func makeKeyAndOrderFront(_ sender: Any?) { events.append("focus") }
        override func orderOut(_ sender: Any?) { events.append("hide") }
    }
}
