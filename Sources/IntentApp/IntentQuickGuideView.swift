import AppKit
import ApplicationServices
import Combine
import SwiftUI
import IntentCore
import IntentLock

/// A compact coach; the full overview remains the actual QuickSelectionView.
struct IntentQuickGuidePresenter: NSViewRepresentable {
    let model: IntentAppModel
    let onFinish: () -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let anchor = GuideAnchorView()
        let owner = context.coordinator
        DispatchQueue.main.async {
            guard owner.active else { return }
            if !model.onboarding.isPresented { model.onboarding.present() }
            let panel = GuidePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Intent · Get started"
            panel.identifier = NSUserInterfaceItemIdentifier("dev.loganmondi.intent.onboarding.guide")
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isOpaque = false; panel.backgroundColor = .clear
            // Keep the coach above the canvas and running controls. A normal
            // floating panel can be obscured when the canvas regains focus.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            owner.panel = panel; owner.dismiss = onDismiss; panel.delegate = owner
            panel.contentView = NSHostingView(rootView: IntentQuickGuideView(model: model, guide: model.onboarding,
                onFinish: onFinish, onDismiss: onDismiss))
            let bounds = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? panel.frame
            let width = min(480, bounds.width - 32), height = min(548, bounds.height - 32)
            panel.setFrame(NSRect(x: bounds.maxX - width - 16, y: bounds.maxY - height - 16, width: width, height: height), display: true)
            owner.visibility = Publishers.CombineLatest4(model.onboarding.$isPresented,
                model.onboarding.$selectionVisible, model.onboarding.$presentationRequest,
                model.onboarding.$permissionHandoffActive)
                .sink { [weak owner] values in
                    // Hide before entering a synchronous macOS permission
                    // request; its alert must not sit beneath this coach.
                    if values.3 { owner?.panel?.orderOut(nil) }
                    // Published values emit before storage changes. Read the
                    // current state on the next turn, after popover dismissal,
                    // so a queued older show cannot cover a newly opened picker.
                    DispatchQueue.main.async { [weak owner] in owner?.updatePresentation() }
                }
            // Finish initial presentation before the purpose field's queued
            // first-responder request checks whether its window is visible.
            owner.updatePresentation()
        }
        return anchor
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.visibility = nil
        coordinator.model.onboarding.exit()
        coordinator.panel?.delegate = nil
        coordinator.panel?.contentView = nil
        coordinator.panel?.close(); coordinator.panel = nil
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: IntentAppModel
        var active = true
        var panel: NSPanel?
        var visibility: AnyCancellable?
        private var presentationPolicy = OnboardingPresentationPolicy()
        var dismiss: (() -> Void)?
        init(model: IntentAppModel) { self.model = model }
        @MainActor func updatePresentation() {
            guard active, let panel else { return }
            let guide = model.onboarding
            switch presentationPolicy.update(isPresented: guide.isPresented,
                selectionVisible: guide.selectionVisible, request: guide.presentationRequest,
                initialEntryFocus: [.welcome, .purpose].contains(guide.state.step),
                permissionHandoffActive: guide.permissionHandoffActive) {
            case .none: break
            case .hide: panel.orderOut(nil)
            case .show: panel.orderFrontRegardless()
            case .showAndFocus:
                // An explicit request also recovers a coach left on a display
                // that is no longer attached. Preserve a user's visible frame.
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }),
                   let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                    let bounds = screen.visibleFrame
                    let size = NSSize(width: min(480, bounds.width - 32), height: min(548, bounds.height - 32))
                    panel.setFrame(NSRect(x: bounds.maxX - size.width - 16, y: bounds.maxY - size.height - 16,
                                          width: size.width, height: size.height), display: true)
                }
                NSApp.activate(ignoringOtherApps: true)
                panel.orderFrontRegardless()
                panel.makeKeyAndOrderFront(nil)
            }
        }
        func windowWillClose(_ notification: Notification) { model.onboarding.exit(); dismiss?() }
    }
}

private final class GuidePanel: IntentInteractivePanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting a separate coach window must not cover the real canvas with an
/// invisible view: saved intentions underneath remain directly clickable.
private final class GuideAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct IntentQuickGuideView: View {
    @ObservedObject var model: IntentAppModel
    @ObservedObject var guide: IntentOnboardingCoordinator
    let onFinish: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var accessibilityReady = AXIsProcessTrusted()
    @State private var previewsReady = CGPreflightScreenCaptureAccess()
    @State private var nextAfterStop: IntentOnboardingStep?
    @State private var error: String?
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var step: IntentOnboardingStep { guide.state.step }
    private var purpose: String { guide.purposeName }
    private var purposeLabel: String { purpose.count > 100 ? String(purpose.prefix(97)) + "…" : purpose }
    private var overviewKey: String { OverlayShortcut.quickSelectionShortcut.displayName }
    private var finishKey: String { FinishShortcutStore.load().displayName }
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Intent" }
    private var permissionsReady: Bool { accessibilityReady && previewsReady }
    private var hasRun: Bool { guide.state.evidence.contains(.overviewRun) || guide.state.evidence.contains(.quickMarkRun) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Intent").font(.system(size: 23, weight: .medium, design: .serif))
                Spacer()
                if guide.state.startedAt != nil { OnboardingCountdown(guide: guide) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if ![.welcome, .purpose].contains(step) {
                        HStack(alignment: .top) {
                            Text(purpose).font(.callout.weight(.medium)).lineLimit(2).help(purpose)
                            Spacer(minLength: 8)
                            Button("Edit") { guide.editPurpose() }.buttonStyle(.plain).font(.caption)
                        }.foregroundStyle(.secondary)
                    }
                    switch step {
                    case .welcome: welcome
                    case .purpose: question
                    case .overview: overview
                    case .quickMark: quickMark
                    case .save: save
                    case .ready: ready
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }
            if step != .welcome {
                Divider().opacity(0.4)
                HStack {
                    if step != .purpose { Button("Back", action: goBack).buttonStyle(.plain) }
                    Spacer()
                    Button(model.hasActiveSession ? "Keep working · close guide" : "Continue later") { leave() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.regularMaterial) } }
            .tint(.green)
            .onReceive(permissionTimer) { _ in refreshPermissions() }
            .onAppear { refreshPermissions() }
            .onChange(of: step) { _ in error = nil; refreshPermissions() }
            .onChange(of: model.hasActiveSession) { running in
                if !running, let nextAfterStop { self.nextAfterStop = nil; guide.move(to: nextAfterStop) }
            }
            .onChange(of: model.errorMessage) { message in if guide.isTeaching { error = message } }
            .onExitCommand { leave() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Make room for what you came to do.")
            Text("Set up one real intention, learn two ways to start, and save it if you want.")
                .foregroundStyle(.secondary)
            Text("Start on this Mac; an account is optional.").font(.caption).foregroundStyle(.secondary)
            Label("Around 3 minutes. Take the time you need.", systemImage: "clock").font(.callout)
            primary("Let’s begin") { guide.begin() }
            Button("Not now") { leave() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
    private var question: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("What do you want to do on your Mac right now?")
            OnboardingPurposeInput(text: Binding(get: { guide.state.purpose }, set: { guide.setPurpose($0) }), submit: { guide.submitPurpose() })
                .frame(height: 42).padding(.horizontal, 12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Text("Reply to friends, make something, watch a film… your words are enough.").font(.callout).foregroundStyle(.secondary)
            primary("Choose my setup") { guide.submitPurpose() }.disabled(purpose.isEmpty)
            Text("This names your intention before you choose anything; you can edit it later.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("1 OF 3 · CHOOSE YOUR SETUP")
            if model.hasActiveSession {
                runFeedback(.overview)
                primary("Let me get to work") { guide.finish(); onFinish() }
                Text("Learn quick marking later in Settings → Quick guide.").font(.caption).foregroundStyle(.secondary)
            } else if guide.state.evidence.contains(.overviewRun) {
                success("Your first setup ran.")
                Text("You’ve prepared the space; finishing your actual task is up to you.").foregroundStyle(.secondary)
                primary("Keep this setup for next time") { guide.move(to: .save) }
                Button("Done for now") { guide.finish(); onFinish() }
            } else if !permissionsReady {
                title("Let Intent work with your windows.")
                Text("macOS needs your approval before the real picker can open; your answer and the clock will stay here.").font(.callout).foregroundStyle(.secondary)
                permissionRows
                Button("Skip this skill for now") { guide.skip() }.buttonStyle(.plain).font(.caption)
            } else {
                title("Press \(overviewKey) once.")
                Text("Click the apps or windows you need for “\(purposeLabel)”. Click a browser to choose its tabs.")
                detail("Allow selected", "Only your selected items stay available.")
                detail("Block selected", "Only your selected items are restricted; switch with / in the overview.")
                detail("Modifications", "They’re along the bottom. Timer can set a duration or a finish time; leave it off for a quick first try.")
                Text("Return starts real restrictions on your Mac. To end a plain run, press \(finishKey); Safety Stop always releases restrictions.").font(.caption).foregroundStyle(.secondary)
                Button("Open the picker instead") { IntentRuntime.shared.toggleQuickFocus() }.buttonStyle(.bordered)
                Text("Using the button is fine; we’ll only record the shortcut as learned after you actually press it.").font(.caption).foregroundStyle(.secondary)
                browserSetup
                Button("Skip this skill for now") { guide.skip() }.buttonStyle(.plain).font(.caption)
            }
        }
    }
    private var quickMark: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("2 OF 3 · SELECT WHERE YOU ARE")
            if model.hasActiveSession {
                runFeedback(.quickMark)
                primary("See how to save this setup") { guide.move(to: .save) }
            } else if guide.state.evidence.contains(.quickMarkRun) {
                success("Your quick selection ran.")
                primary("Save it for next time") { guide.move(to: .save) }
            } else if !permissionsReady {
                title("Quick selection uses the same permissions.")
                permissionRows
                Button("Skip this skill for now") { guide.skip() }.buttonStyle(.plain).font(.caption)
            } else {
                title("Click a window, then double-tap `.")
                Text("In Chrome or Firefox, this marks the current tab—or the tabs you selected together. In other apps, it marks the window.")
                detail("Look for the outline", "Green means allow; red means block. Double-tap again to remove the same selection.")
                Text(verbatim: "Hold ` and press Return to run. Hold ` and press B to switch Allow / Block.").font(.callout.weight(.medium))
                Text(verbatim: "Need a whole browser window? Hold ` and press Tab. To clear marks, hold ` and press Esc.")
                    .font(.caption).foregroundStyle(.secondary)
                if guide.state.evidence.contains(.quickMarkChanged) { success("Selection detected—now hold ` and press Return.") }
                Text("Starting applies real restrictions; closing this guide will leave your run going.").font(.caption).foregroundStyle(.secondary)
                browserSetup
                Button("Skip this skill for now") { guide.skip() }.buttonStyle(.plain).font(.caption)
            }
        }
    }
    private var save: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("3 OF 3 · KEEP A USEFUL SETUP")
            title("Make next time one less decision.")
            if let id = guide.state.savedIntentionID, let existing = model.intentions.first(where: { $0.id == id }) {
                success("A saved setup is already on your canvas.")
                Text(existing.name).font(.headline).lineLimit(2).help(existing.name)
                if hasRun, let draft = guide.lastIntention, draft.id != existing.id || existing.name != purpose {
                    Text("You can keep that setup, or replace it with your current selections named “\(purposeLabel)”. Updating a running setup also ends this run.").font(.callout).foregroundStyle(.secondary)
                    primary(model.hasActiveSession ? "Finish & update saved setup" : "Update saved setup") {
                        if !model.saveOnboardingIntention(replaceExisting: true) { error = model.errorMessage ?? "The setup couldn’t be updated yet." }
                    }.disabled(model.hasActiveSession && !model.activeSessionCanFinishManually)
                    lockedExplanation
                    Button("Keep existing · show on canvas") { guide.showSavedOnCanvas() }.buttonStyle(.plain)
                } else {
                    Text("Open Intent with \(OverlayShortcutStore.load().displayName), then double-click its card to run it again.")
                    primary("Show it on my canvas") { guide.showSavedOnCanvas() }
                }
            } else if hasRun, guide.lastIntention != nil {
                Text("Save this setup as “\(purposeLabel)” on your existing Intent canvas.")
                if model.hasActiveSession {
                    Text("\(OverlayShortcut.finishAndSaveShortcut.displayName) finishes and saves. This ends the current run; choose Keep working if you want to carry on.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                primary(model.hasActiveSession ? "Finish & save to canvas" : "Save to canvas") {
                    if !model.saveOnboardingIntention() { error = model.errorMessage ?? "The setup couldn’t be saved yet. Try again." }
                }.disabled(model.hasActiveSession && !model.activeSessionCanFinishManually)
                lockedExplanation
            } else {
                Text("There’s no completed setup to save yet. You can return to either selection skill, or keep this guide optional.").foregroundStyle(.secondary)
                Button("Go to the picker skill") { guide.move(to: .overview) }.buttonStyle(.bordered)
            }
            Button(guide.state.savedIntentionID == nil ? "No thanks—keep it a one-off" : "Continue without another save") { guide.skip() }.buttonStyle(.plain)
        }
    }
    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            title(model.hasActiveSession ? "Your space is ready." : "Start with what you came to do.")
            Text("When I sit down to use my Mac, I press \(overviewKey) and name what I came to do.")
                .font(.title3.weight(.medium))
            Text("That’s a small action to repeat—not a habit you have to perfect today.").foregroundStyle(.secondary)
            if guide.state.evidence.contains(.reused) { success("You ran your saved intention again.") }
            if !guide.state.skipped.isEmpty { Text("Skipped skills are still available in Settings → Quick guide; they aren’t marked as learned.").font(.caption).foregroundStyle(.secondary) }
            if let id = guide.state.savedIntentionID, let intention = model.intentions.first(where: { $0.id == id }), !model.hasActiveSession {
                if intention.selectionRequiresTabReselection {
                    Text("This setup includes temporary browser tabs; choose the current tabs again before running it.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose current tabs") { IntentRuntime.shared.toggleQuickFocus() }.buttonStyle(.bordered)
                } else {
                    Button("Run my saved intention") { model.requestStart(intentionID: intention.id) }.buttonStyle(.bordered)
                }
                Text("Or double-click its card on the canvas next time.").font(.caption).foregroundStyle(.secondary)
            }
            primary(model.hasActiveSession ? "Let me do my thing" : "Done for now") { guide.finish(); onFinish() }
            if !model.hasActiveSession { Button("Replay the guide") { guide.replay() }.buttonStyle(.plain).font(.caption) }
        }
    }
    @ViewBuilder private func runFeedback(_ expected: IntentOnboardingStep) -> some View {
        if guide.state.evidence.contains(expected == .overview ? .overviewRun : .quickMarkRun) {
            success("Your intention is running.")
            Text("“\(purposeLabel)” has its space. You can keep working now or continue learning.")
        } else {
            title("An intention is already running.")
            Text("Finish it normally before trying another selection mode; the guide won’t stop it for you.").foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var lockedExplanation: some View {
        if model.hasActiveSession && !model.activeSessionCanFinishManually {
            Text("Finish the checklist or wait for the timer first. Your guide progress is saved; Safety Stop is available if anything goes wrong.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            permission("Accessibility", ready: accessibilityReady, explanation: "Lets Intent use your focus shortcuts and protect your chosen setup.", pane: "Privacy_Accessibility")
            permission("Screen & System Audio Recording", ready: previewsReady, explanation: "Lets Intent show local window previews and blur; this guide doesn’t record or upload your screen.", pane: "Privacy_ScreenCapture")
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 32, height: 32)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .accessibilityLabel("Drag \(appName) into the permission list")
                Text("Turn on \(appName). If it’s missing, drag this icon into the list, or use + and choose this app; macOS may require your password and a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("The guide waits while Settings is open. Return to Intent when you’re done.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Safety Stop: Control + Option + Command + Esc. Also available from Intent’s menu-bar menu.").font(.caption.weight(.medium))
        }
    }
    private func permission(_ title: String, ready: Bool, explanation: String, pane: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle").font(.callout.weight(.medium))
                Spacer()
                if !ready { Button("Open Settings") { openPermission(pane) } }
            }
            Text(ready ? "Ready" : explanation).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
    private var browserSetup: some View {
        DisclosureGroup("Using Chrome or Firefox tabs?") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Browser Guard must be connected; without it, try a normal app window or skip this skill.").font(.caption).foregroundStyle(.secondary)
                ForEach(["com.google.Chrome", "org.mozilla.firefox"], id: \.self) { id in
                    let connected = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: id)).supports(.tabSessionIdentity, maxAge: 5)
                    HStack {
                        Label(id == "com.google.Chrome" ? "Chrome" : "Firefox", systemImage: connected ? "checkmark.circle.fill" : "circle")
                        Spacer()
                        if !connected { Button("Connect") { guide.connectBrowser(id) } }
                    }.font(.caption)
                }
                if guide.setupBrowser != nil {
                    Text("Waiting for Browser Guard; the guide clock keeps running.").font(.caption).foregroundStyle(.secondary)
                    Button("Continue with app windows") { guide.continueWithAppWindows() }.font(.caption)
                }
            }.padding(.top, 8)
        }.font(.callout)
    }
    private func openPermission(_ pane: String) {
        guide.beginPermissionHandoff()
        if pane == "Privacy_Accessibility" { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        else { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"), NSWorkspace.shared.open(url) { return }
        guide.resumePermissionHandoff()
    }
    private func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted(); previewsReady = CGPreflightScreenCaptureAccess()
        if let browser = guide.setupBrowser, BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).supports(.tabSessionIdentity, maxAge: 5) {
            guide.continueWithAppWindows()
        }
        guide.setSetupInProgress([.overview, .quickMark].contains(step) && (!permissionsReady || guide.setupBrowser != nil))
    }
    private func continueAfterRun(to next: IntentOnboardingStep) {
        guard model.hasActiveSession else { guide.move(to: next); return }
        guard model.activeSessionCanFinishManually else { return }
        nextAfterStop = next
        model.endActiveSession()
    }
    private func leave() { guide.exit(); onDismiss() }
    private func goBack() {
        switch step {
        case .overview: guide.editPurpose()
        case .quickMark: guide.move(to: .overview)
        case .save: guide.move(to: .quickMark)
        case .ready: guide.move(to: .save)
        default: break
        }
    }
    private func title(_ text: String) -> some View { Text(text).font(.system(size: 25, weight: .semibold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader) }
    private func eyebrow(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
    private func primary(_ text: String, action: @escaping () -> Void) -> some View { Button(text, action: action).buttonStyle(.borderedProminent).controlSize(.large).fixedSize(horizontal: false, vertical: true) }
    private func success(_ text: String) -> some View { Label(text, systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
    private func detail(_ title: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.callout.weight(.semibold)); Text(text).font(.callout).foregroundStyle(.secondary) } }
}

struct OnboardingSelectionHint: View {
    @ObservedObject var coordinator: IntentOnboardingCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose what you need for “\(coordinator.purposeName.count > 100 ? String(coordinator.purposeName.prefix(97)) + "…" : coordinator.purposeName)”").font(.callout.weight(.semibold)).lineLimit(1)
                Text("/ switches Allow / Block · Modifications are below · Return starts real restrictions")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            OnboardingCountdown(guide: coordinator)
        }.padding(.horizontal, 16).padding(.vertical, 8)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                }
            }
            .accessibilityElement(children: .contain)
    }
}

private struct OnboardingCountdown: View {
    @ObservedObject var guide: IntentOnboardingCoordinator
    var body: some View {
        Button {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: "Guide timer: \(guide.state.countdownText). Take your time.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(guide.state.countdownText).monospacedDigit().font(.system(size: 13, weight: .medium))
                Text("Take your time").font(.system(size: 9)).foregroundStyle(.secondary)
            }.accessibilityHidden(true)
        }.buttonStyle(.plain).accessibilityLabel("Read guide timer; there is no time limit")
    }
}

/// AppKit owns composition and Return; committing an IME candidate cannot submit
/// the tutorial or replace the marked range during a SwiftUI refresh.
private struct OnboardingPurposeInput: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "For example, reply to friends"
        field.isBordered = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 18); field.focusRingType = .default
        field.setAccessibilityLabel("What do you want to do on your Mac right now?")
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            if field.window?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                field.window?.makeKeyAndOrderFront(nil)
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OnboardingPurposeInput
        init(_ parent: OnboardingPurposeInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            parent.text = (control as? NSTextField)?.stringValue ?? parent.text
            parent.submit(); return true
        }
    }
}
