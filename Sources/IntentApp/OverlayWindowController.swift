import AppKit
import SwiftUI
import IntentCore

@MainActor
final class OverlayWindowController: NSObject, IntentOverlayPresenting {
    private let model: IntentAppModel
    private let calendarSync: CalendarSyncManager
    private let accountManager: IntentAccountManager
    private var panel: NSPanel?
    private var sessionTimerPanel: NSPanel?
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

    func showSessionTimer(name: String, endsAt: Date, displaysEndTime: Bool) {
        let timerPanel = sessionTimerPanel ?? makeSessionTimerPanel()
        sessionTimerPanel = timerPanel
        installSessionTimerContent()

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let size = sessionTimerSize
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
        timerPanel.setFrame(frame, display: true)
        timerPanel.orderFrontRegardless()
    }

    func hideSessionTimer() {
        sessionTimerPanel?.orderOut(nil)
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
        let panel = NSPanel(
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
        return panel
    }

    func toggleSessionControls() {
        guard model.hasActiveSession else { return }
        if sessionTimerPanel?.isVisible == true { sessionTimerPanel?.orderOut(nil) }
        else { sessionTimerPanel?.orderFrontRegardless() }
    }

    private var sessionTimerSize: NSSize {
        NSSize(width: 300, height: model.activeChecklist.isEmpty ? 115 : min(440, 140 + CGFloat(model.activeChecklist.count) * 38))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { ZStack(alignment: .leading) { Text(model.activeSessionName ?? "Intent").font(.headline).lineLimit(1).allowsHitTesting(false); SessionTimerDragRegion() }.frame(height: 24); Spacer(); Button { model.toggleSessionControls() } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain) }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    if let end = model.activeSessionEndsAt { Text(SessionTimerFormatter.countdownText(until: end, now: context.date)).monospacedDigit() }
                    Spacer()
                    Text(context.date, style: .time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !model.activeChecklist.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.activeChecklist.enumerated()), id: \.offset) { index, task in
                            Toggle(task, isOn: Binding(get: { model.completedChecklist.contains(index) }, set: { model.setTaskCompleted(index, completed: $0) }))
                                .toggleStyle(.checkbox).strikethrough(model.completedChecklist.contains(index)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Text(verbatim: "` hide · ~ finish · ⌘⇧` finish & save").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15))).preferredColorScheme(.dark)
    }
}
