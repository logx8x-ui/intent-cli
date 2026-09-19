import AppKit
import SwiftUI
import IntentCore
import IntentLock

@MainActor
final class OverlayWindowController: NSObject, IntentOverlayPresenting, NSWindowDelegate {
    private let model: IntentAppModel
    private let calendarSync: CalendarSyncManager
    private let accountManager: IntentAccountManager
    private var panel: NSPanel?
    private var sessionTimerPanel: NSPanel?
    private var sessionOverlayState = SessionOverlayPolicy()
    private var expiryPanel: NSPanel?
    private var expiryDismissal: DispatchWorkItem?
    private var lastExpiryOccurrence: UUID?
    private var sessionSecurityObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var targetFrame: NSRect = .zero
    private var isAnimating = false

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
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionSecurityObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.hideSessionExpiry() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideSessionExpiry() }
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
        guard !isAnimating else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        // The panel includes a transparent perimeter so edit mode can cast its
        // blue aura outside the visible overlay while preserving a 30pt gap.
        targetFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
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
            self?.isAnimating = false
            if let panel = self?.panel {
                self?.focusOverlay(panel)
            }
        }
    }

    func hideOverlay(animated: Bool) {
        guard let panel, panel.isVisible, !isAnimating else { return }
        guard animated else {
            panel.orderOut(nil)
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
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            if let targetFrame = self?.targetFrame {
                panel?.setFrame(targetFrame, display: false)
            }
            self?.isAnimating = false
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

    func showSessionControls(occurrenceID: UUID) {
        let newOccurrence = sessionOverlayState.occurrenceID != occurrenceID
        sessionOverlayState.update(occurrenceID: occurrenceID, hasTimer: model.activeSessionEndsAt != nil, hasChecklist: !model.activeChecklist.isEmpty)
        guard sessionOverlayState.eligible else { hideSessionTimer(); return }
        let timerPanel = sessionTimerPanel ?? makeSessionTimerPanel()
        sessionTimerPanel = timerPanel
        if newOccurrence { installSessionTimerContent() }

        let screen = workingScreen()
        guard let screen else { return }
        let size = sessionTimerSize
        var frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
        if let saved = UserDefaults.standard.string(forKey: "intentSessionControlsFrame") {
            let previous = NSRectFromString(saved)
            if let savedScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(CGPoint(x: previous.midX, y: previous.midY)) }) {
                frame.origin.x = min(max(previous.minX, savedScreen.visibleFrame.minX), savedScreen.visibleFrame.maxX - size.width)
                frame.origin.y = min(max(previous.maxY - size.height, savedScreen.visibleFrame.minY), savedScreen.visibleFrame.maxY - size.height)
            }
        }
        if newOccurrence { timerPanel.setFrame(frame, display: true) }
        if sessionOverlayState.expanded { timerPanel.orderFrontRegardless() }
    }

    func hideSessionTimer() {
        sessionTimerPanel?.orderOut(nil)
        sessionOverlayState.end()
    }

    var isSessionControlsExpanded: Bool { sessionOverlayState.expanded && sessionTimerPanel?.isVisible == true }

    @discardableResult
    func collapseSessionControlsIfExpanded() -> Bool {
        guard sessionOverlayState.collapse() else { return false }
        sessionTimerPanel?.orderOut(nil)
        return true
    }

    func showSessionExpiry(occurrenceID: UUID, name: String) {
        guard lastExpiryOccurrence != occurrenceID else { return }
        lastExpiryOccurrence = occurrenceID
        hideSessionExpiry()
        // A locked or inactive login session must not receive a stale notice on
        // unlock; expiry still ends restrictions in the runtime immediately.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              session["kCGSSessionOnConsoleKey"] as? Bool != false,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow",
              let screen = workingScreen() else { return }
        let size = NSSize(width: min(360, screen.visibleFrame.width - 32), height: 112)
        let notice = SessionExpiryPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2 + 60, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.level = .statusBar
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hasShadow = true
        notice.hidesOnDeactivate = false; notice.isReleasedWhenClosed = false
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        notice.contentView = NSHostingView(rootView: SessionExpiryView(name: name) { [weak self] in self?.hideSessionExpiry() })
        expiryPanel = notice
        notice.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.hideSessionExpiry() }
        expiryDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }

    func hideSessionExpiry() {
        expiryDismissal?.cancel(); expiryDismissal = nil
        expiryPanel?.orderOut(nil); expiryPanel = nil
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

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSPanel, moved === sessionTimerPanel else { return }
        UserDefaults.standard.set(NSStringFromRect(moved.frame), forKey: "intentSessionControlsFrame")
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
            rootView: IntentGraphView()
                .environmentObject(model)
                .environmentObject(calendarSync)
                .environmentObject(accountManager)
        )
        return panel
    }

    private func focusOverlay(_ panel: NSPanel) {
        NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps
        ])
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)

        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(nil)
        }
    }

    private func makeSessionTimerPanel() -> NSPanel {
        let panel = IntentInteractivePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        return panel
    }

    func toggleSessionControls() {
        guard model.hasEligibleSessionControls, let occurrence = model.activeSessionOccurrenceID else { return }
        if sessionOverlayState.occurrenceID != occurrence { showSessionControls(occurrenceID: occurrence); return }
        if isSessionControlsExpanded { _ = collapseSessionControlsIfExpanded() }
        else { sessionOverlayState.toggle(); sessionTimerPanel?.orderFrontRegardless() }
    }

    private var sessionTimerSize: NSSize {
        let timerHeight: CGFloat = model.activeSessionEndsAt == nil ? 0 : (model.activeSessionAbsoluteEndTime == nil ? 54 : 74)
        let checklistHeight: CGFloat = model.activeChecklist.isEmpty ? 0 : 28 + min(230, CGFloat(model.activeChecklist.count) * 36)
        return NSSize(width: 336, height: 86 + timerHeight + checklistHeight)
    }

    private func installSessionTimerContent() {
        sessionTimerPanel?.contentViewController = NSHostingController(rootView: SessionControlsView(model: model))
    }

}

private struct SessionTimerDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private final class IntentOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct SessionControlsView: View {
    @ObservedObject var model: IntentAppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                ZStack(alignment: .leading) {
                    Text(model.activeSessionName ?? "Intent").font(.system(size: 14, weight: .semibold)).lineLimit(1).allowsHitTesting(false)
                    SessionTimerDragRegion()
                }.frame(height: 22)
                Button { model.collapseSessionControlsIfExpanded() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Hide controls · `").accessibilityLabel("Hide running controls")
            }
            if model.activeSessionEndsAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        if let end = model.activeSessionEndsAt {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(SessionTimerFormatter.countdownText(until: end, now: context.date))
                                    .font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
                                Text("remaining").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        if let end = model.activeSessionAbsoluteEndTime {
                            Text("Ends at \(end.formatted(date: .omitted, time: .shortened))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.activeChecklist.isEmpty {
                HStack {
                    Text("TASKS").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text("\(model.completedChecklist.count) / \(model.activeChecklist.count)").font(.system(size: 11)).monospacedDigit()
                }.foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.activeChecklist.enumerated()), id: \.offset) { index, task in
                            Toggle(task, isOn: Binding(get: { model.completedChecklist.contains(index) }, set: { model.setTaskCompleted(index, completed: $0) }))
                                .toggleStyle(.checkbox).font(.system(size: 13)).strikethrough(model.completedChecklist.contains(index))
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text(verbatim: "` hide controls").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.13)) } else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) } }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18)))
            .tint(.green).preferredColorScheme(.dark)
    }
}

private final class SessionExpiryPanel: IntentInteractivePanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SessionExpiryView: View {
    let name: String
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 31)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 5) {
                Text("Time’s up").font(.system(size: 19, weight: .semibold))
                Text(name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss timer notification")
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if reduceTransparency { RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.13)) } else { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) } }
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.20)))
            .preferredColorScheme(.dark)
    }
}
