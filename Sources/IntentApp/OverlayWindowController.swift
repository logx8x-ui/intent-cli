import AppKit
import Combine
import SwiftUI
import IntentCore
import IntentLock

@MainActor
final class OverlayWindowController: NSObject, IntentOverlayPresenting {
    private let model: IntentAppModel
    private let calendarSync: CalendarSyncManager
    private let accountManager: IntentAccountManager
    private var panel: NSPanel?
    private var sessionTimerPanel: NSPanel?
    private var sessionOverlayState = SessionOverlayPolicy()
    private var sessionScreenID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private let completionLight = SessionCompletionLight()
    private let failureNotice = SessionFailureNotice()
    private var sessionSecurityObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var targetFrame: NSRect = .zero
    private var isAnimating = false
    private var presentationGeneration = 0
    private var permissionHandoffObserver: AnyCancellable?

    var isOverlayVisible: Bool {
        panel?.isVisible == true
    }

    init(
        model: IntentAppModel,
        calendarSync: CalendarSyncManager,
        accountManager: IntentAccountManager
    ) {
        self.model = model
        self.calendarSync = calendarSync
        self.accountManager = accountManager
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.layoutSessionControls() }
            }
        permissionHandoffObserver = model.onboarding.$permissionHandoffActive.sink { [weak self] active in
            // This also wins over a currently running open animation. Its
            // completion below must not bring an ordered-out canvas back.
            if active { self?.panel?.orderOut(nil) }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionSecurityObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelTransientFeedbackForSecurity() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelTransientFeedbackForSecurity() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            sessionSecurityObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFeedbackForRunningSession() }
            })
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFeedbackForRunningSession() }
        }
    }

    func toggleOverlay() {
        if panel?.isVisible == true {
            hideOverlay(animated: true)
        } else {
            showOverlay(animated: true)
        }
    }

    func showOverlay(animated: Bool) {
        guard !isAnimating, !model.onboarding.permissionHandoffActive else { return }
        let needsOnboarding = !UserDefaults.standard.bool(forKey: "intentDidCompleteOnboarding")
            && !UserDefaults.standard.bool(forKey: IntentOnboardingCoordinator.deferredKey)
        let needsUtility = model.settingsPresentationRequest != nil || model.pendingFriction != nil
            || model.pendingEndTimeRequest != nil
            || model.errorMessage != nil || needsOnboarding || model.onboarding.isPresented
            || accountManager.phase == .loading || accountManager.phase == .choosing || accountManager.isPresentingAccount
        guard needsUtility else {
            panel?.orderOut(nil)
            if model.hasActiveSession { model.toggleSessionControls() }
            else { _ = model.presentWorkspace?() }
            return
        }
        presentationGeneration += 1
        let generation = presentationGeneration
        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        // The panel includes a transparent perimeter so edit mode can cast its
        // blue aura outside the visible overlay while preserving a 30pt gap.
        let size = NSSize(width: min(560, screen.visibleFrame.width), height: min(740, screen.visibleFrame.height))
        targetFrame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let startFrame = targetFrame.insetBy(dx: 9, dy: 7)
        panel.setFrame(animated ? startFrame : targetFrame, display: true)
        panel.alphaValue = animated ? 0 : 1
        focusOverlay(panel)

        guard animated else { return }
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.isAnimating = false
            if let panel = self.panel, panel.isVisible { self.focusOverlay(panel) }
        }
    }

    func hideOverlay(animated: Bool) {
        guard let panel else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        // Completion and Escape must win over an in-flight opening animation.
        guard animated, panel.isVisible, !isAnimating else {
            panel.orderOut(nil)
            isAnimating = false
            return
        }

        isAnimating = true
        let endFrame = targetFrame.insetBy(dx: 8, dy: 6)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, self.presentationGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            panel?.setFrame(self.targetFrame, display: false)
            self.isAnimating = false
        }
    }

    func handOffExternalAuthentication(to url: URL) async -> Bool {
        // Leave the redirect state on screen long enough to read before Intent
        // performs its normal close animation and activates the default browser.
        try? await Task.sleep(nanoseconds: 650_000_000)
        hideOverlay(animated: true)
        try? await Task.sleep(nanoseconds: 220_000_000)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let didOpen = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(url, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }

        if !didOpen {
            showOverlay(animated: true)
        }
        return didOpen
    }

    func prepareSessionPresentation(occurrenceID: UUID) {
        failureNotice.prepare(occurrenceID: occurrenceID)
    }

    func showSessionControls(occurrenceID: UUID) {
        let newOccurrence = sessionOverlayState.occurrenceID != occurrenceID
        sessionOverlayState.update(occurrenceID: occurrenceID, hasTimer: model.activeSessionEndsAt != nil, hasChecklist: !model.activeChecklist.isEmpty, hasStopwatch: model.stopwatchStarted != nil)
        guard sessionOverlayState.eligible else { hideSessionTimer(); return }
        let timerPanel = sessionTimerPanel ?? makeSessionTimerPanel()
        sessionTimerPanel = timerPanel
        if newOccurrence {
            completionLight.hide()
            sessionScreenID = workingScreen()?.intentDisplayID
        }
        layoutSessionControls()
        if sessionOverlayState.visible { timerPanel.orderFrontRegardless() }
        else { timerPanel.orderOut(nil) }
    }

    func hideSessionTimer() {
        sessionTimerPanel?.orderOut(nil)
        sessionOverlayState.end()
        sessionScreenID = nil
    }

    var isSessionControlsExpanded: Bool { !model.activeChecklist.isEmpty && sessionOverlayState.expanded && sessionTimerPanel?.isVisible == true }

    @discardableResult
    func collapseSessionControlsIfExpanded() -> Bool {
        guard !model.activeChecklist.isEmpty, sessionOverlayState.collapse() else { return false }
        resizeSessionControls()
        return true
    }


    func hideSessionExpiry() {
        completionLight.hide()
        failureNotice.hide()
    }

    private func cancelTransientFeedbackForSecurity() {
        completionLight.hide()
        failureNotice.suppressForSecurity()
    }

    private func resumeFeedbackForRunningSession() {
        guard let occurrence = model.resumableSessionFeedbackOccurrenceID else { return }
        failureNotice.resumeRunningSession(occurrenceID: occurrence)
    }

    func showSessionCompletion(occurrenceID: UUID, mode: IntentionAccessMode) {
        guard let screen = workingScreen() else { return }
        completionLight.show(occurrenceID: occurrenceID, mode: mode, screen: screen)
    }

    func showSessionFailure(occurrenceID: UUID, message: String) {
        guard !model.hasActiveSession else { return }
        failureNotice.show(occurrenceID: occurrenceID, message: message, screen: workingScreen())
    }

    private func workingScreen() -> NSScreen? {
        // Prefer the display holding the foreground app; the pointer can be on
        // another display while the user is typing.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let dictionary = window[kCGWindowBounds as String] as? [String: Any],
           let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let native = CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
            if let match = NSScreen.screens.max(by: { left, right in
                let a = left.frame.intersection(native), b = right.frame.intersection(native)
                return max(0, a.width) * max(0, a.height) < max(0, b.width) * max(0, b.height)
            }), match.frame.intersects(native) { return match }
        }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func makePanel() -> NSPanel {
        let panel = IntentOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentViewController = NSHostingController(
            rootView: IntentUtilityView()
                .environmentObject(model)
                .environmentObject(calendarSync)
                .environmentObject(accountManager)
        )
        return panel
    }

    private func focusOverlay(_ panel: NSPanel) {
        guard !model.onboarding.permissionHandoffActive else { panel.orderOut(nil); return }
        // Reopening the canvas must not steal purpose-entry keyboard focus
        // from its own guide, including the delayed activation below.
        if onboardingOwnsEntryFocus {
            panel.orderFrontRegardless()
            return
        }
        NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps
        ])
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, !self.onboardingOwnsEntryFocus,
                  !self.model.onboarding.permissionHandoffActive else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(nil)
        }
    }

    private var onboardingOwnsEntryFocus: Bool {
        model.onboarding.isPresented && !model.onboarding.selectionVisible
            && [.welcome, .purpose].contains(model.onboarding.state.step)
    }

    private func makeSessionTimerPanel() -> NSPanel {
        SessionNotchPanel.make()
    }

    func toggleSessionControls() {
        guard model.hasActiveSession, let occurrence = model.activeSessionOccurrenceID else { return }
        if !model.hasEligibleSessionControls {
            hideOverlay(animated: false)
            return
        }
        if sessionOverlayState.occurrenceID != occurrence { showSessionControls(occurrenceID: occurrence); return }
        sessionOverlayState.toggleVisibility()
        if sessionOverlayState.visible { showSessionControls(occurrenceID: occurrence) }
        else { sessionTimerPanel?.orderOut(nil) }
    }

    func toggleSessionControlsExpansion() {
        guard sessionOverlayState.eligible, !model.activeChecklist.isEmpty else { return }
        sessionOverlayState.toggle()
        resizeSessionControls()
    }

    private func resizeSessionControls() {
        layoutSessionControls()
    }

    private func layoutSessionControls() {
        guard sessionOverlayState.eligible, let panel = sessionTimerPanel,
              let screen = NSScreen.screens.first(where: { $0.intentDisplayID == sessionScreenID }) ?? workingScreen() else { return }
        sessionScreenID = screen.intentDisplayID
        let layout = screen.intentNotchLayout(checklistCount: model.activeChecklist.count, expanded: sessionOverlayState.expanded)
        panel.setFrame(layout.frame, display: true)
        // Timer-only HUDs cannot intercept a menu-bar click or become a text editor.
        panel.ignoresMouseEvents = model.activeChecklist.isEmpty
        panel.contentViewController = NSHostingController(rootView: SessionNotchView(model: model, layout: layout))
        if sessionOverlayState.visible { panel.orderFrontRegardless() }
    }

}

private final class IntentOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
