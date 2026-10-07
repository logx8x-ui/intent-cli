import AppKit
import IntentCore

/// Exercise the production field's queued attachment callback without ordering
/// windows or changing the real app/window/keyboard focus. A recording window
/// supplies the eligibility flags and observes (rather than performs) the one
/// first-responder transfer. Installed typing remains separate live acceptance.
@MainActor
enum WebsiteFinderFocusChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let originalKeyWindow = NSApp.keyWindow
        let originalActive = NSApp.isActive

        let valid = Fixture()
        defer { valid.close() }
        valid.attach()
        try pump()
        try check(valid.window.focusRequests.count == 1 && valid.window.focusRequests.first === valid.field,
            "An attached website address field requests typing once in its already-key overview window")
        valid.field.requestInitialFocus(); valid.field.updateQuery()
        try pump()
        try check(valid.window.focusRequests.count == 1,
            "A finder refresh cannot repeatedly steal focus after its initial address request")

        let cancelled = Fixture()
        defer { cancelled.close() }
        cancelled.attach(); cancelled.finder.cancel()
        try pump()
        try check(cancelled.window.focusRequests.isEmpty,
            "Closing the finder before attachment delivery cancels its pending typing request")

        let stale = Fixture()
        defer { stale.close() }
        stale.attach()
        stale.context.target?.overviewGeneration = UUID()
        try pump()
        try check(stale.window.focusRequests.isEmpty,
            "A queued finder address request cannot focus a replacement overview generation")

        let switched = Fixture()
        defer { switched.close() }
        switched.attach()
        switched.context.target?.browserSessionID = "different-profile"
        try pump()
        try check(switched.window.focusRequests.isEmpty,
            "Changing browser ownership invalidates the old finder address request")

        let detached = Fixture()
        defer { detached.close() }
        detached.attach(); detached.field.removeFromSuperview()
        try pump()
        try check(detached.window.focusRequests.isEmpty,
            "A detached finder field never sends its delayed focus request to its former window")

        let nonKey = Fixture()
        defer { nonKey.close() }
        nonKey.window.reportsKey = false
        nonKey.attach()
        try pump()
        try check(nonKey.window.focusRequests.isEmpty,
            "The finder cannot activate or take typing from a different foreground window")

        let hidden = Fixture()
        defer { hidden.close() }
        hidden.window.reportsVisible = false
        hidden.attach()
        try pump()
        try check(hidden.window.focusRequests.isEmpty,
            "A hidden overview cannot receive a queued finder typing request")

        let dismantled = Fixture()
        defer { dismantled.close() }
        dismantled.attach(); dismantled.field.invalidatePendingFocus()
        try pump()
        try check(dismantled.window.focusRequests.isEmpty,
            "SwiftUI dismantling invalidates a pending field attachment even before physical detachment")

        let captured = Fixture()
        defer { captured.close() }
        captured.attach()
        captured.finder.query = "https://example.org/"
        captured.finder.submit()
        try pump()
        try check(captured.window.focusRequests.isEmpty && captured.context.captures == 1,
            "A result already captured for creation cannot retake address focus")
        try check(NSApp.keyWindow === originalKeyWindow && NSApp.isActive == originalActive,
            "Finder focus regressions do not activate Intent or change the actual key window")
    }

    private static func pump() throws {
        // Drain the actual main-queue attachment callback before asserting.
        // A fixed 30 ms run-loop delay was flaky under the release-build load.
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(2)
        while !drained && Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        guard drained else {
            throw NSError(domain: "WebsiteFinderFocusChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The queued finder focus callback did not drain before the test deadline"])
        }
    }

    @MainActor private final class Context {
        var target: WebsiteFinderTarget? = .init(browserBundleIdentifier: "com.google.Chrome",
            browserSessionID: "finder-focus-qa", browserWindowID: 41, anchorTabID: 7, overviewGeneration: UUID())
        var captures = 0
    }

    @MainActor private final class Fixture {
        let context = Context()
        let finder: WebsiteFinderController
        let field: WebsiteFinderAddressField
        let window = RecordingWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)

        init() {
            let context = self.context
            finder = WebsiteFinderController(target: context.target!, currentTarget: { context.target },
                onCapture: { _, _ in context.captures += 1 })
            field = WebsiteFinderAddressField(controller: finder)
            field.frame = .init(x: 10, y: 10, width: 380, height: 24)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: .init(x: 0, y: 0, width: 420, height: 80))
        }
        func attach() {
            window.contentView?.addSubview(field)
            window.focusRequests = []
        }
        func close() {
            finder.cancel(); field.invalidatePendingFocus(); field.removeFromSuperview()
            window.reportsKey = false; window.reportsVisible = false
            window.close()
        }
    }

    private final class RecordingWindow: NSWindow {
        var reportsKey = true
        var reportsVisible = true
        var focusRequests: [NSResponder] = []
        override var isKeyWindow: Bool { reportsKey }
        override var isVisible: Bool { reportsVisible }
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if let responder { focusRequests.append(responder) }
            return true
        }
    }
}
