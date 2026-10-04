import AppKit
import SwiftUI
import IntentCore

/// Finite, mouse-transparent feedback only. This never activates Intent,
/// requests a key/main window or changes another application's window order.
@MainActor
final class SessionFailureNotice {
    private var policy = SessionFailureNoticePolicy()
    private var panel: SessionNotchPanel?
    private var dismissal: DispatchWorkItem?

    func prepare(occurrenceID: UUID) {
        if policy.prepare(occurrenceID: occurrenceID) { removePanel() }
    }

    func show(occurrenceID: UUID, message: String, screen: NSScreen?) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let canPresent = screen != nil && session != nil
            && session?["CGSSessionScreenIsLocked"] as? Bool != true
            && session?[kCGSessionOnConsoleKey as String] as? Bool != false
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        guard let generation = policy.show(occurrenceID: occurrenceID, canPresent: canPresent), let screen else { return }
        removePanel()
        let frame = SessionFailureNoticePolicy.frame(screen: screen.frame,
            visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
        let notice = Self.makePanel(frame: frame, message: message)
        panel = notice
        notice.orderFrontRegardless() // Only this non-key, nonactivating panel.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.policy.expire(generation: generation) else { return }
            self.removePanel()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionFailureNoticePolicy.duration, execute: work)
    }

    func hide() { policy.hide(); removePanel() }
    func suppressForSecurity() { policy.suppressForSecurity(); removePanel() }
    func resumeRunningSession(occurrenceID: UUID) {
        _ = policy.resume(occurrenceID: occurrenceID, sessionStillRunning: true)
    }

    private func removePanel() {
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil); panel = nil
    }

    static func makePanel(frame: CGRect, message: String) -> SessionNotchPanel {
        let panel = SessionNotchPanel.make()
        panel.title = "Intent — Intention stopped"
        panel.ignoresMouseEvents = true
        panel.collectionBehavior.insert(.ignoresCycle)
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(rootView: SessionFailureNoticeContent(message: message)
            .frame(width: frame.width, height: frame.height))
        return panel
    }
}

struct SessionFailureNoticeContent: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Intention stopped", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.92))
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Text("Open Intent for details").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.13), lineWidth: 1))
            .padding(2).preferredColorScheme(.dark)
            .accessibilityElement(children: .combine)
    }
}
