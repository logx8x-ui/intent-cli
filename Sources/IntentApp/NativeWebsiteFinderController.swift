import AppKit
import SwiftUI
import IntentCore

@MainActor
final class NativeWebsiteFinderController: ObservableObject {
    let target: WebsiteFinderTarget
    @Published private(set) var status = "Opening your browser…"
    @Published private(set) var busy = true
    @Published private(set) var opened = false
    @Published private(set) var controlsFocusRequest: UUID?
    private let client: BrowserFinderClient
    private var task: Task<Void, Never>?
    private var companion: NativeWebsiteFinderCompanionPresentation?
    private var committed = false
    private var finished = false
    private let onCommit: (WebsiteFinderTarget, BrowserTabItem) -> Void
    private let onCancel: () -> Void
    init(target: WebsiteFinderTarget, onCommit: @escaping (WebsiteFinderTarget, BrowserTabItem) -> Void,
         onCancel: @escaping () -> Void) throws {
        self.target = target; client = try BrowserFinderClient(target: target)
        self.onCommit = onCommit; self.onCancel = onCancel
    }
    func start(frame: BrowserWindowFrame) {
        presentCompanion(frame: frame)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await client.open(frame: frame)
                guard !finished, !Task.isCancelled else { return }
                opened = true; busy = false; status = "Browse in this tab, then add it to Intent."
                presentCompanion(frame: receipt.frame ?? frame)
            } catch {
                guard !finished, !Task.isCancelled else { return }
                busy = false; status = error.localizedDescription
                presentCompanion(frame: frame)
            }
        }
    }
    func add() {
        guard opened, !busy, !finished else { return }
        busy = true; status = "Adding this page…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let tab = try await client.commit()
                guard !finished, !Task.isCancelled else { return }
                committed = true; dismiss(); onCommit(target, tab)
            } catch {
                guard !finished, !Task.isCancelled else { return }
                busy = false; status = error.localizedDescription
            }
        }
    }
    func cancel() {
        guard !finished else { return }
        dismiss(); onCancel()
    }
    /// Explicitly reopening Intent should return keyboard access to the finder,
    /// not the overview behind the browser. Initial presentation never calls this.
    @discardableResult
    func focusControls() -> Bool {
        guard !finished else { return false }
        return companion?.focusControls() ?? false
    }
    func dismiss() {
        guard !finished else { return }
        finished = true; task?.cancel(); task = nil
        companion?.dismiss(); companion = nil
        if !committed { client.cancel() }
    }
    private func presentCompanion(frame: BrowserWindowFrame) {
        guard !finished, companion == nil else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.left + frame.width / 2, y: top - frame.top - frame.height / 2)) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? .init(x: frame.left, y: top - frame.top - frame.height, width: frame.width, height: frame.height)
        let width = min(580, available.width - 32)
        let x = min(max(available.minX + 16, frame.left + (frame.width - width) / 2), available.maxX - width - 16)
        let y = max(available.minY + 16, top - frame.top - frame.height - 90)
        let panel = NativeWebsiteFinderPanel(contentRect: .init(x: x, y: y, width: width, height: 76),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Add website to Intent"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NativeWebsiteFinderControls(controller: self))
        let presentation = NativeWebsiteFinderCompanionPresentation(panel: panel) { [weak self] in
            self?.controlsFocusRequest = UUID()
        }
        companion = presentation; presentation.show()
    }
}

/// Keyboard-capable when deliberately chosen, without becoming Intent's main
/// window or activating Intent while the user is typing in their browser.
class NativeWebsiteFinderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns only this companion's presentation. It never activates the application,
/// raises the overview, or schedules a delayed focus correction.
@MainActor
final class NativeWebsiteFinderCompanionPresentation {
    private enum Phase { case fresh, shown, dismissed }
    private var phase = Phase.fresh
    private let panel: NSPanel
    private let notifications: NotificationCenter
    private let isApplicationActive: () -> Bool
    private let onFocusControls: () -> Void
    private var activationObserver: NSObjectProtocol?

    init(panel: NSPanel, notifications: NotificationCenter = .default,
         isApplicationActive: @escaping () -> Bool = { NSApp.isActive },
         onFocusControls: @escaping () -> Void) {
        self.panel = panel; self.notifications = notifications
        self.isApplicationActive = isApplicationActive; self.onFocusControls = onFocusControls
    }

    deinit {
        if let activationObserver { notifications.removeObserver(activationObserver) }
    }

    func show() {
        guard phase == .fresh else { return }
        phase = .shown
        // Only a later app activation transfers typing; presenting while Intent
        // is already active must leave the upcoming browser search untouched.
        activationObserver = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isApplicationActive() else { return }
                    self.focusControls()
                }
            }
        panel.orderFrontRegardless()
    }

    @discardableResult
    func focusControls() -> Bool {
        guard phase == .shown else { return false }
        panel.makeKeyAndOrderFront(nil)
        onFocusControls()
        return true
    }

    func dismiss() {
        guard phase != .dismissed else { return }
        phase = .dismissed
        if let activationObserver {
            notifications.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        panel.orderOut(nil)
    }
}

private struct NativeWebsiteFinderControls: View {
    @ObservedObject var controller: NativeWebsiteFinderController
    private enum Control: Hashable { case cancel, add }
    @FocusState private var focusedControl: Control?
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add from \(controller.target.browserName)").font(.system(size: 12, weight: .semibold))
                Text(controller.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: controller.cancel).buttonStyle(.borderless)
                .focused($focusedControl, equals: .cancel)
                .accessibilityIdentifier("native-website-finder-cancel")
            Button("Add to intention", action: controller.add).buttonStyle(.borderedProminent).tint(.green).disabled(controller.busy || !controller.opened)
                .focused($focusedControl, equals: .add)
                .accessibilityIdentifier("native-website-finder-add")
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16)))
        .preferredColorScheme(.dark)
        .onChange(of: controller.controlsFocusRequest) { _ in
            focusedControl = controller.opened && !controller.busy ? .add : .cancel
        }
    }
}
