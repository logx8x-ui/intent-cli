import AppKit
import IntentCore

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
        try runControllerLifecycleChecks(check)
    }

    /// Drive the production asynchronous controller with a recorded companion
    /// and profile client. No desktop windows or browser mailboxes are touched.
    private static func runControllerLifecycleChecks(_ check: (Bool, String) throws -> Void) throws {
        let target = WebsiteFinderTarget(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "qa-finder-profile",
            browserWindowID: 4, anchorTabID: 7, overviewGeneration: UUID())
        let frame = BrowserWindowFrame(left: 100, top: 120, width: 760, height: 560)
        let originalKeyWindow = NSApp.keyWindow, originalActive = NSApp.isActive
        let panels = (0..<8).map { _ in
            let panel = RecordingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            return panel
        }
        defer { panels.forEach { $0.close() } }
        func makeController(client: RecordingClient, panel: RecordingPanel,
                            onCommit: @escaping (WebsiteFinderTarget, BrowserTabItem) -> Void = { _, _ in },
                            onCancel: @escaping () -> Void) throws -> NativeWebsiteFinderController {
            try .init(target: target, onCommit: onCommit, onCancel: onCancel, client: client,
                companionFactory: { _ in .init(panel: panel, notifications: NotificationCenter(), isApplicationActive: { false }, onFocusControls: {}) },
                observationDelayNanoseconds: 1_000_000)
        }
        let closedClient = RecordingClient(observation: .value(.closed))
        var inputOwned = true, cancelCallbacks = 0
        let closed = try makeController(client: closedClient, panel: panels[0]) {
            inputOwned = false; cancelCallbacks += 1
        }
        closed.start(frame: frame)
        try check(waitUntil { cancelCallbacks == 1 }, "An authenticated externally closed finder reaches the real asynchronous Cancel path")
        try check(!inputOwned && closedClient.cancelCount == 1 && panels[0].events == ["show", "hide"],
            "Closing the browser releases overview ownership, dismisses controls, and sends one exact-owner cancellation")
        closed.cancel(); closed.start(frame: frame)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try check(cancelCallbacks == 1 && closedClient.openCount == 1 && panels[0].events == ["show", "hide"],
            "A finished finder cannot reopen or dismiss a replacement")

        let notOpenedClient = RecordingClient(observation: .pending)
        var earlyCancel = 0
        let notOpened = try makeController(client: notOpenedClient, panel: panels[5]) { earlyCancel += 1 }
        notOpened.start(frame: frame); notOpened.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try check(notOpenedClient.openCount == 0 && earlyCancel == 1 && panels[5].events == ["show", "hide"],
            "Cancel before the first actor turn prevents the queued open from reaching the browser client")

        let recoverableClient = RecordingClient(observation: .failure(.rejected("Temporary browser query failed")))
        var recoverableCancel = 0
        let recoverable = try makeController(client: recoverableClient, panel: panels[1]) { recoverableCancel += 1 }
        recoverable.start(frame: frame)
        try check(waitUntil { recoverable.status == "Choose Add to intention when your page is ready." },
            "A generic observation failure retains recovery controls instead of inventing terminal closure")
        try check(recoverableCancel == 0 && recoverableClient.cancelCount == 0 && recoverable.opened && !recoverable.busy
            && recoverable.focusControls(), "An unconfirmed failure keeps Add and explicit Cancel available")
        recoverable.cancel()
        try check(recoverableCancel == 1 && recoverableClient.cancelCount == 1,
            "Explicit Cancel still releases the finder after a recoverable observation failure")

        let recoveredClient = RecordingClient(observation: .failureThenClosed)
        var recoveredCancel = 0
        let recovered = try makeController(client: recoveredClient, panel: panels[4]) { recoveredCancel += 1 }
        recovered.start(frame: frame)
        try check(waitUntil { recoveredCancel == 1 }, "A browser close after a transient query failure still releases finder ownership")
        try check(recoveredClient.observeCount == 2 && recoveredClient.cancelCount == 1,
            "Observation resumes after transient failure and stops immediately on confirmed closure")

        let failedCommitClient = RecordingClient(observation: .closedAfterFailedCommit)
        var failedCommitCancel = 0
        let failedCommit = try makeController(client: failedCommitClient, panel: panels[6]) { failedCommitCancel += 1 }
        failedCommit.start(frame: frame)
        try check(waitUntil { failedCommit.opened }, "The finder opens before testing a failed manual Add")
        failedCommit.add()
        try check(waitUntil { failedCommitCancel == 1 }, "A failed Add resumes observation so a later browser close releases ownership")
        try check(failedCommitClient.commitCount == 1 && failedCommitClient.cancelCount == 1,
            "Commit failure cannot strand input or repeat the Add effect")

        let cancelledCommitClient = RecordingClient(observation: .pendingCommit)
        var cancelledCommitCallbacks = 0, commitCallbacks = 0
        let cancelledCommit = try makeController(client: cancelledCommitClient, panel: panels[7],
            onCommit: { _, _ in commitCallbacks += 1 }) { cancelledCommitCallbacks += 1 }
        cancelledCommit.start(frame: frame)
        try check(waitUntil { cancelledCommit.opened }, "The finder opens before testing cancellation during Add")
        cancelledCommit.add()
        try check(waitUntil { cancelledCommitClient.pendingCommit != nil }, "The real controller enters an in-flight commit")
        cancelledCommit.cancel(); cancelledCommitClient.resolveCommit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try check(cancelledCommitCallbacks == 1 && commitCallbacks == 0 && cancelledCommitClient.cancelCount == 1,
            "A late commit after cancellation cannot select a tab or resurrect the old draft")

        let oldClient = RecordingClient(observation: .pending)
        var oldCancel = 0, replacementCancel = 0
        let old = try makeController(client: oldClient, panel: panels[2]) { oldCancel += 1 }
        old.start(frame: frame)
        try check(waitUntil { oldClient.pendingObservation != nil }, "The old finder can be paused inside an in-flight observation")
        old.cancel()
        let replacementClient = RecordingClient(observation: .pending)
        let replacement = try makeController(client: replacementClient, panel: panels[3]) { replacementCancel += 1 }
        replacement.start(frame: frame)
        try check(waitUntil { replacementClient.pendingObservation != nil }, "T can create a new finder for the same target after cancellation")
        oldClient.resolve(.closed)
        _ = waitUntil { oldClient.pendingObservation == nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try check(oldCancel == 1 && replacementCancel == 0 && replacementClient.cancelCount == 0 && replacement.focusControls(),
            "A late closed response from the old finder cannot cancel or take input from its replacement")
        replacement.cancel(); replacementClient.resolve(.closed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        try check(replacementCancel == 1 && replacementClient.cancelCount == 1,
            "Replacement cancellation remains exact-once even when its observation finishes late")
        try check(NSApp.keyWindow === originalKeyWindow && NSApp.isActive == originalActive,
            "Controller lifecycle regressions never change the real foreground or launch a browser")
    }

    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return condition()
    }

    @MainActor private final class RecordingClient: NativeWebsiteFinderClient {
        enum Observation {
            case value(BrowserFinderObservation)
            case failure(BrowserTabCreationError)
            case failureThenClosed
            case closedAfterFailedCommit
            case pendingCommit
            case pending
        }
        let supportsAutomaticSelection = true
        let observation: Observation
        var openCount = 0, cancelCount = 0, observeCount = 0, commitCount = 0
        var pendingObservation: CheckedContinuation<BrowserFinderObservation, Swift.Error>?
        var pendingCommit: CheckedContinuation<BrowserTabItem, Swift.Error>?
        init(observation: Observation) { self.observation = observation }
        func open(frame: BrowserWindowFrame) async throws -> BrowserFinderReceipt {
            openCount += 1
            let row: [String: Any] = ["requestID": UUID().uuidString, "finderID": UUID().uuidString, "action": "open",
                "browserSessionID": "qa-finder-profile", "originalWindowID": 4, "anchorTabID": 7, "windowID": 10, "tabID": 20,
                "frame": ["left": frame.left, "top": frame.top, "width": frame.width, "height": frame.height]]
            return try JSONDecoder().decode(BrowserFinderReceipt.self, from: JSONSerialization.data(withJSONObject: row))
        }
        func observeState() async throws -> BrowserFinderObservation {
            observeCount += 1
            switch observation {
            case .value(let value): return value
            case .failure(let error): throw error
            case .failureThenClosed:
                if observeCount == 1 { throw BrowserTabCreationError.rejected("Temporary browser query failed") }
                return .closed
            case .closedAfterFailedCommit: return commitCount == 0 ? .waiting : .closed
            case .pendingCommit: return .waiting
            case .pending: return try await withCheckedThrowingContinuation { pendingObservation = $0 }
            }
        }
        func resolve(_ result: BrowserFinderObservation) {
            let pending = pendingObservation; pendingObservation = nil
            pending?.resume(returning: result)
        }
        func commit(expectedURL: String?) async throws -> BrowserTabItem {
            commitCount += 1
            if case .pendingCommit = observation {
                return try await withCheckedThrowingContinuation { pendingCommit = $0 }
            }
            throw BrowserTabCreationError.uncertain
        }
        func resolveCommit() {
            let pending = pendingCommit; pendingCommit = nil
            pending?.resume(returning: .init(id: 20, windowID: 4, index: 1, title: "QA", url: "https://example.test", active: true))
        }
        func cancel() { cancelCount += 1 }
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
