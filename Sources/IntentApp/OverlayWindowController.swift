import AppKit
import SwiftUI
import IntentCore

@MainActor
final class OverlayWindowController: NSObject, IntentOverlayPresenting {
    private let model: IntentAppModel
    private var panel: NSPanel?
    private var sessionTimerPanel: NSPanel?
    private var sessionTimerName = ""
    private var sessionTimerEndsAt = Date()
    private var sessionTimerCollapsed = false
    private var targetFrame: NSRect = .zero
    private var isAnimating = false

    init(model: IntentAppModel) {
        self.model = model
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
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        guard animated else { return }
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.isAnimating = false
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

    func showSessionTimer(name: String, endsAt: Date) {
        let timerPanel = sessionTimerPanel ?? makeSessionTimerPanel()
        sessionTimerPanel = timerPanel
        sessionTimerName = name
        sessionTimerEndsAt = endsAt
        sessionTimerCollapsed = false
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
        )
        return panel
    }

    private func makeSessionTimerPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private var sessionTimerSize: NSSize {
        sessionTimerCollapsed
            ? NSSize(width: 38, height: 30)
            : NSSize(width: 204, height: 56)
    }

    private func installSessionTimerContent() {
        sessionTimerPanel?.contentViewController = NSHostingController(
            rootView: SessionTimerView(
                name: sessionTimerName,
                endsAt: sessionTimerEndsAt,
                isCollapsed: sessionTimerCollapsed,
                onToggleCollapsed: { [weak self] in
                    self?.toggleSessionTimerCollapsed()
                }
            )
        )
    }

    private func toggleSessionTimerCollapsed() {
        guard let panel = sessionTimerPanel else { return }
        let oldFrame = panel.frame
        sessionTimerCollapsed.toggle()
        installSessionTimerContent()

        let size = sessionTimerSize
        var frame = NSRect(
            x: oldFrame.midX - size.width / 2,
            y: oldFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        }
        panel.setFrame(frame, display: true, animate: true)
    }
}

private struct SessionTimerView: View {
    let name: String
    let endsAt: Date
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void

    @AppStorage("intentAppearance") private var appearance = "dark"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if isCollapsed {
                    Button(action: onToggleCollapsed) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 38, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Show timer")
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "timer")
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(remainingText(at: context.date))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        Button(action: onToggleCollapsed) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("Hide timer")
                    }
                    .padding(.leading, 15)
                    .padding(.trailing, 8)
                    .frame(width: 204, height: 56)
                }
            }
            .foregroundStyle(Color.primary)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous))
            .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous)
                    .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
            )
        }
        .preferredColorScheme(appearance == "light" ? .light : .dark)
    }

    private func remainingText(at date: Date) -> String {
        let remaining = max(0, Int(endsAt.timeIntervalSince(date).rounded(.up)))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private final class IntentOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
