import AppKit
import SwiftUI
import IntentCore

@MainActor
final class OverlayWindowController: NSObject, IntentOverlayPresenting {
    private let model: IntentAppModel
    private var panel: NSPanel?
    private var sessionTimerPanel: NSPanel?
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

    func showSessionTimer(name: String, endsAt: Date, position: TimerDisplayPosition) {
        let timerPanel = sessionTimerPanel ?? makeSessionTimerPanel()
        sessionTimerPanel = timerPanel
        timerPanel.contentViewController = NSHostingController(
            rootView: SessionTimerView(name: name, endsAt: endsAt)
        )

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let size = NSSize(width: 184, height: 54)
        timerPanel.setFrame(
            timerFrame(size: size, in: screen.visibleFrame, position: position),
            display: true
        )
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
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func timerFrame(
        size: NSSize,
        in visibleFrame: NSRect,
        position: TimerDisplayPosition
    ) -> NSRect {
        let margin: CGFloat = 20
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topLeading:
            x = visibleFrame.minX + margin
            y = visibleFrame.maxY - size.height - margin
        case .top:
            x = visibleFrame.midX - size.width / 2
            y = visibleFrame.maxY - size.height - margin
        case .topTrailing:
            x = visibleFrame.maxX - size.width - margin
            y = visibleFrame.maxY - size.height - margin
        case .bottomLeading:
            x = visibleFrame.minX + margin
            y = visibleFrame.minY + margin
        case .bottomTrailing:
            x = visibleFrame.maxX - size.width - margin
            y = visibleFrame.minY + margin
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

private struct SessionTimerView: View {
    let name: String
    let endsAt: Date

    @AppStorage("intentAppearance") private var appearance = "dark"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 15)
            .frame(width: 184, height: 54)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
