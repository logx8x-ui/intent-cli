import AppKit
import ApplicationServices
import IntentCore
import IntentLock
import ScreenCaptureKit
import SwiftUI

@MainActor
final class QuickSelectionController: ObservableObject {
    struct AppItem: Identifiable {
        let app: AllowedApp
        let icon: NSImage
        let pid: pid_t
        var id: String { app.bundleIdentifier }
    }
    struct WindowItem: Identifiable {
        let id: CGWindowID
        let appID: String
        let title: String
        let sourceFrame: CGRect
        var preview: NSImage?
    }
    @Published var apps: [AppItem] = []
    @Published var windows: [WindowItem] = []
    @Published var snapshots: [BrowserTabSnapshot] = []
    @Published var selection = QuickSelection()
    @Published var modificationOrder = QuickSelectionOptionsSection.ordered
    @Published var combinationNotice = false
    @Published var optionsSection: QuickSelectionOptionsSection?
    @Published var message: String?
    @Published var hasPreviewPermission = CGPreflightScreenCaptureAccess()
    @Published var wallpaper: NSImage?
    @Published var expanded = false
    @Published var loading = false
    @Published var closing = false
    @Published var settingsOpen = false
    @Published var explicitBrowserWindow: QuickSelectionBrowserWindow?
    @Published var focusedBrowserWindow: CGWindowID?
    @Published var hoveredTab: BrowserTabItem?
    @Published var tabPreview: NSImage?
    @Published var tabPreviewError: String?
    @Published var tabPreviewLoading = false
    private let workspaceOutlines = WorkspaceOutlineController()
    private var hasStagedSelection = false
    private var onboardingSelectionScope: (selection: QuickSelection, staged: Bool)?
    private var onboardingScopeRestorePending = false
    var onboarding: IntentOnboardingCoordinator { model.onboarding }

    func beginOnboardingSelectionScope() {
        if onboardingSelectionScope != nil {
            // Resuming the same guide during its real run keeps ownership of the
            // temporary selection until the user exits again.
            onboardingScopeRestorePending = false
            return
        }
        guard !model.hasActiveSession else { return }
        onboardingSelectionScope = (selection, hasStagedSelection)
        onboardingScopeRestorePending = false
        markGeneration = UUID(); markTask?.cancel(); markTask = nil
        runMarkedTask?.cancel()
        if panel?.isVisible == true { close() }
        dismissMarkNotice(); hideStagedModifiers(); workspaceOutlines.stop()
        selection = QuickSelection(); hasStagedSelection = false
    }

    func endOnboardingSelectionScope() {
        guard onboardingSelectionScope != nil else { return }
        markGeneration = UUID(); markTask?.cancel(); markTask = nil
        runMarkedTask?.cancel()
        if panel?.isVisible == true { close() }
        dismissMarkNotice(); hideStagedModifiers(); workspaceOutlines.stop()
        onboardingScopeRestorePending = true
        restoreOnboardingSelectionIfPending()
    }

    func restoreOnboardingSelectionIfPending() {
        guard onboardingScopeRestorePending, !model.hasActiveSession,
              let prior = onboardingSelectionScope else { return }
        selection = prior.selection; hasStagedSelection = prior.staged
        onboardingSelectionScope = nil; onboardingScopeRestorePending = false
        if hasStagedSelection, !selection.apps.isEmpty {
            refreshStagedOutlines(); showStagedModifiers()
        }
    }
    private var markGeneration = UUID()
    private var markTask: Task<Void, Never>?
    private var markSequence = 0
    private var runMarkedTask: Task<Void, Never>?
    private func freshSnapshots(for browsers: Set<String>) async -> Bool {
        guard !browsers.isEmpty else { return true }
        let requestedAt = Date()
        // Reconnects and a busy native host must get a bounded chance to recover.
        // Resend lost discovery commands, but never accept an old cached snapshot.
        for attempt in 0..<60 {
            guard !Task.isCancelled else { return false }
            var allReady = true
            for browser in browsers {
                let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).heartbeat()
                switch QuickMarkRecovery.connection(heartbeat) {
                case .updateRequired: return false
                case .reconnecting: allReady = false
                case .ready:
                    if attempt % 20 == 0 || attempt == 1 {
                        try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
                    }
                }
            }
            let current = browsers.compactMap { BrowserTabSnapshotStore(browserBundleIdentifier: $0).load() }
            if allReady, current.count == browsers.count, current.allSatisfy({ QuickMarkRecovery.accepts($0, requestedAt: requestedAt) }) {
                snapshots.removeAll { browsers.contains($0.browserBundleIdentifier) }
                snapshots.append(contentsOf: current)
                return true
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
        return false
    }
    private var stagedModifiersPanel: NSPanel?
    private var stagedPreviousApp: NSRunningApplication?
    func openModification(_ index: Int) {
        guard !model.hasActiveSession, modificationOrder.indices.contains(index) else { return }
        if !hasStagedSelection && panel?.isVisible != true { selection = QuickSelection(); hasStagedSelection = true }
        openModification(modificationOrder[index])
    }
    func openModification(_ section: QuickSelectionOptionsSection) {
        if panel?.isVisible != true, let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            stagedPreviousApp = frontmost
        }
        section.enable(in: &selection)
        optionsSection = section
        if panel?.isVisible != true {
            showStagedModifiers()
            NSApp.activate(ignoringOtherApps: true); stagedModifiersPanel?.makeKeyAndOrderFront(nil)
        }
        if QuickSelectionOptionsSection.timer.enabled(in: selection), QuickSelectionOptionsSection.checklist.enabled(in: selection),
           !UserDefaults.standard.bool(forKey: "explainedTimerChecklist") {
            combinationNotice = true
            UserDefaults.standard.set(true, forKey: "explainedTimerChecklist")
        }
    }
    func acknowledgeCombination() { combinationNotice = false }
    func swapModification(_ source: String, with target: QuickSelectionOptionsSection) {
        guard let a = modificationOrder.firstIndex(where: { $0.rawValue == source }), let b = modificationOrder.firstIndex(of: target) else { return }
        modificationOrder.swapAt(a, b)
        UserDefaults.standard.set(modificationOrder.map(\.rawValue), forKey: "quickModificationOrder")
    }
    private func showStagedModifiers() {
        // A retained draft can have no targets after the last mark is toggled
        // off. Keep its settings, but only show controls for actual targets or
        // an explicitly opened modifier editor.
        guard !model.hasActiveSession, panel?.isVisible != true, hasStagedSelection,
              !selection.apps.isEmpty || optionsSection != nil else {
            hideStagedModifiers()
            return
        }
        guard stagedModifiersPanel == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let width = min(880, screen.visibleFrame.width - 56)
        let notice = SelectionPanel(contentRect: CGRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 18, width: width, height: 58), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hidesOnDeactivate = false
        notice.level = .floating; notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notice.contentView = NSHostingView(rootView: ModificationStrip(controller: self).padding(4).preferredColorScheme(.dark))
        stagedModifiersPanel = notice; notice.orderFrontRegardless()
    }
    func closeModification() {
        optionsSection = nil
        if panel?.isVisible != true {
            showStagedModifiers()
            stagedPreviousApp?.activate(options: [.activateIgnoringOtherApps])
            stagedPreviousApp = nil
        }
    }
    private func hideStagedModifiers() {
        optionsSection = nil
        let previousPanel = stagedModifiersPanel
        stagedModifiersPanel = nil
        previousPanel?.orderOut(nil)
    }
    private func refreshStagedOutlines() {
        guard hasStagedSelection, !selection.apps.isEmpty,
              !model.hasActiveSession, panel?.isVisible != true else {
            workspaceOutlines.stop()
            return
        }
        workspaceOutlines.update(selection)
    }
    func markForeground(wholeWindow: Bool = false, fromShortcut: Bool = false) {
        guard !model.hasActiveSession, panel?.isVisible != true else { return }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { toggle(); return }
        guard let window = WorkspaceWindow.focused(), window.pid != ProcessInfo.processInfo.processIdentifier else { return }
        let markToken = markGeneration
        let previous = markTask
        markSequence += 1
        markTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.markGeneration == markToken, !self.model.hasActiveSession, self.panel?.isVisible != true else { return }
            self.refresh()
            let beforeApps = self.selection.apps
            let beforeTabs = self.selection.tabs
            let beforeWindows = self.selection.windowIDsByApp
            if QuickSelection.browsers.contains(window.bundle) {
                let fresh = await self.freshSnapshots(for: [window.bundle])
                guard !Task.isCancelled, self.markGeneration == markToken, !self.model.hasActiveSession, self.panel?.isVisible != true else { return }
                let stillFocused = WorkspaceWindow.focused()
                guard QuickMarkRecovery.matchesTarget(originalID: window.id, originalPID: window.pid,
                                                      currentID: stillFocused?.id, currentPID: stillFocused?.pid) else { return }
                guard fresh, let snapshot = self.snapshots.first(where: { $0.browserBundleIdentifier == window.bundle }),
                      let browserWindow = BrowserWindowMatching.match(title: stillFocused?.title ?? window.title, tabs: snapshot.allTabs ?? snapshot.tabs,
                          nativeWindowCount: WorkspaceWindow.list().filter { $0.bundle == window.bundle }.count, frame: stillFocused?.frame ?? window.frame, isFocused: true) else {
                    self.showMarkRecovery(for: window.bundle, fresh: fresh)
                    return
                }
                guard !self.model.hasActiveSession, self.panel?.isVisible != true else { return }
                if !self.hasStagedSelection { self.selection = QuickSelection() }
                guard self.ensureSelectionSession(window.bundle) else {
                    self.showMarkRecovery(for: window.bundle, fresh: fresh, detail: self.message)
                    return
                }
                if wholeWindow {
                    guard (snapshot.allTabs ?? snapshot.tabs).contains(where: { $0.windowID == browserWindow && QuickSelection.isSelectable($0) }) else { return }
                    self.selection.toggleBrowserWindow(browser: window.bundle, windowID: browserWindow, snapshots: self.snapshots, outlineWholeWindow: true)
                } else {
                    guard BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: window.bundle)).supports(.nativeTabGroups, maxAge: 5),
                          self.selection.toggleNativeTabGroup(browser: window.bundle, windowID: browserWindow, snapshot: snapshot) else {
                        self.showMarkRecovery(for: window.bundle, fresh: fresh, needsGroupUpdate: true)
                        return
                    }
                }
            } else {
                if !self.hasStagedSelection { self.selection = QuickSelection() }
                self.selection.toggleWindow(window.id, app: window.bundle)
            }
            self.dismissMarkNotice()
            self.hasStagedSelection = true
            self.refreshStagedOutlines()
            if self.selection.apps.isEmpty { self.hideStagedModifiers() }
            else { self.showStagedModifiers() }
            if !self.selection.apps.isEmpty,
               beforeApps != self.selection.apps || beforeTabs != self.selection.tabs || beforeWindows != self.selection.windowIDsByApp {
                self.onboarding.record(.quickMarkChanged)
                if fromShortcut && !wholeWindow { self.onboarding.record(.quickMarkShortcut) }
            }
        }
    }
    func runMarked() {
        if panel?.isVisible == true { runSelection(); return }
        guard runMarkedTask == nil else { return }
        runMarkedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.runMarkedTask = nil }
            await self.markTask?.value
            guard !self.model.hasActiveSession, self.hasStagedSelection, !self.selection.apps.isEmpty else { return }
            self.refresh()
            let fresh = await self.freshSnapshots(for: Set(self.selection.tabs.map(\.browser)))
            guard !Task.isCancelled, !self.model.hasActiveSession, self.panel?.isVisible != true else { return }
            guard fresh else {
                self.model.errorMessage = "Couldn't refresh the marked tabs. Check Browser Guard and try again."; self.model.showOverlay(); return
            }
            guard self.panel?.isVisible != true else { return }
            let current = Set(WorkspaceWindow.list(onScreen: false).map(\.id))
            guard self.selection.windowIDsByApp.values.allSatisfy({ $0.isSubset(of: current) }) else {
                self.model.errorMessage = "A marked window closed. Open ` and review your selection."; self.model.showOverlay(); return
            }
            if self.model.startQuickSelection(self.selection, apps: self.apps.map(\.app), snapshots: self.snapshots, onboardingOrigin: .quickMark) {
                self.workspaceOutlines.stop(); self.hasStagedSelection = false; self.hideStagedModifiers()
            } else { self.model.showOverlay() }
        }
    }
    private var markNoticePanel: NSPanel?
    private var markNoticeDismissal: DispatchWorkItem?
    private func dismissMarkNotice() {
        markNoticeDismissal?.cancel(); markNoticeDismissal = nil
        markNoticePanel?.orderOut(nil); markNoticePanel = nil
    }
    private func showMarkRecovery(for browser: String, fresh: Bool, needsGroupUpdate: Bool = false, detail: String? = nil) {
        // A failed quick mark must never open the dashboard or a blocking alert.
        let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).heartbeat()
        let connection = QuickMarkRecovery.connection(heartbeat)
        let name = browser == "com.google.Chrome" ? "Chrome" : "Firefox"
        let text: String
        if let detail { text = detail }
        else if needsGroupUpdate {
            text = "Update \(name) Browser Guard to read all selected tabs. No part of this group was marked."
        } else { switch connection {
        case .updateRequired: text = "\(name) Browser Guard needs an update to select tabs."
        case .reconnecting: text = "\(name) Browser Guard is disconnected. Your selections are safe."
        case .ready: text = fresh ? "Couldn’t identify this browser window. Open Intent’s overview to select its tabs, or check Browser Guard in this browser profile." : "\(name) is taking longer to respond. Try marking again."
        } }
        dismissMarkNotice()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = CGRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 24, width: 420, height: 120)
        let notice = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hasShadow = true; notice.hidesOnDeactivate = false
        notice.level = .floating; notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        notice.contentView = NSHostingView(rootView: QuickMarkRecoveryNotice(text: text, needsSetup: needsGroupUpdate || connection != .ready, setup: { [weak self] in
            self?.dismissMarkNotice(); IntentBrowserSetup.open(browser)
        }, overview: { [weak self] in self?.dismissMarkNotice(); self?.toggle() }, close: { [weak self] in self?.dismissMarkNotice() }))
        markNoticePanel = notice; notice.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissMarkNotice() }
        markNoticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }
    func clearMarks() {
        guard !model.hasActiveSession else { return }
        dismissMarkNotice()
        hideStagedModifiers()
        markGeneration = UUID()
        markTask?.cancel(); markTask = nil
        overviewOpenTask?.cancel(); overviewOpenTask = nil
        runMarkedTask?.cancel()
        selection.clearTargets()
        hasStagedSelection = false
        workspaceOutlines.stop()
    }
    func toggleMarkedMode() {
        guard !model.hasActiveSession else { return }
        if !hasStagedSelection, panel?.isVisible != true { selection = QuickSelection(); hasStagedSelection = true }
        toggleAccessMode(); refreshStagedOutlines()
        if panel?.isVisible != true { showStagedModifiers() }
    }
    private var hoverTask: Task<Void, Never>?
    private(set) var displayFrame = CGRect.zero
    private(set) var topSafeInset: CGFloat = 0
    let model: IntentAppModel
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var previewCache: [CGWindowID: WindowItem] = [:]
    private var previewRetry = 0
    private var previewTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var wasOverlayVisible = false
    private var generation = UUID()

    init(model: IntentAppModel) { self.model = model }
    var windowlessApps: [AppItem] {
        guard hasPreviewPermission, !loading else { return [] }
        return apps.filter { app in !windows.contains { $0.appID == app.id } }
    }
    var isSelectionSurfaceVisible: Bool { panel?.isVisible == true }
    private var overviewOpenTask: Task<Void, Never>?
    func toggle() {
        // Finish a pending mark before presenting a surface that changes focus.
        if markTask != nil, panel?.isVisible != true {
            guard overviewOpenTask == nil else { return }
            overviewOpenTask = Task { [weak self] in
                guard let self else { return }
                while let pending = self.markTask {
                    let sequence = self.markSequence
                    await pending.value
                    guard !Task.isCancelled else { return }
                    if self.markSequence == sequence { break }
                }
                self.overviewOpenTask = nil
                self.markTask = nil
                self.toggle()
            }
            return
        }
        if panel?.isVisible == true { cancel(); return }
        guard !model.hasActiveSession, !model.isZeroDriftActive,
              model.pendingPurposeSessionSave == nil, model.pendingFriction == nil,
              model.pendingEndTimeRequest == nil else {
            model.errorMessage = "Finish the current intention and save or dismiss its result before opening the field of view."
            model.showOverlay(); return
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            let screenMissing = !CGPreflightScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = screenMissing ? "One step before `: show your windows" : "One step before `: allow Accessibility"
            alert.informativeText = "In System Settings, turn on Intent. If it is missing, use + and choose Intent from Applications. Return here and press ` again. If macOS asks to quit and reopen, accept it. Your selections and saved intentions stay safe."
            alert.addButton(withTitle: "Open System Settings"); alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if screenMissing { _ = CGRequestScreenCaptureAccess() }
            else { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (screenMissing ? "Privacy_ScreenCapture" : "Privacy_Accessibility"))!)
            return
        }
        if !hasStagedSelection { selection = QuickSelection() }
        workspaceOutlines.stop()
        hideStagedModifiers()
        optionsSection = nil; message = nil; expanded = false; closing = false; windows = []; focusedBrowserWindow = nil
        previousApp = NSWorkspace.shared.frontmostApplication
        wasOverlayVisible = model.overlayPresenter?.isOverlayVisible == true
        refresh(); generation = UUID(); previewRetry = 0
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        // Capture coordinates are top-left; AppKit screens are bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        displayFrame = CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        topSafeInset = screen.safeAreaInsets.top
        wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Intent"
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false
        let content = NSHostingView(rootView: QuickSelectionView(controller: self))
        // The desktop is the viewport. Intrinsic SwiftUI content must never
        // grow a borderless panel beyond it or push its controls off-screen.
        content.sizingOptions = []
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        self.panel = panel
        model.overlayPresenter?.hideOverlay(animated: false)
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        onboarding.selectionVisible = panel.isVisible
        if panel.isVisible { onboarding.record(.overviewOpened) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if self.settingsOpen { return event }
            if event.keyCode == 53 {
                if self.optionsSection != nil { self.optionsSection = nil } else { self.cancel() }
                return nil
            }
            // Phrase/checklist editing must not switch Allow/Block when typing '/'.
            if self.panel?.firstResponder is NSTextView { return event }
            if event.keyCode == 7, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, self.focusedBrowserWindow != nil {
                if !event.isARepeat { self.toggleAllFocusedTabs() }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { self.runSelection(); return nil }
            if event.charactersIgnoringModifiers == "/", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if !event.isARepeat { self.toggleAccessMode() }
                return nil
            }
            return event
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        loadPreviews()
    }
    func toggleAccessMode() {
        guard !closing else { return }
        selection.accessMode = selection.accessMode == .whitelist ? .blacklist : .whitelist
        // A whole-browser block has no tab selection; do not silently turn that
        // into an allow-all browser when returning to Allow mode.
        if selection.accessMode == .whitelist {
            for browser in QuickSelection.browsers where !selection.tabs.contains(where: { $0.browser == browser }) { selection.apps.remove(browser) }
        }
        message = nil
    }
    func refresh() {
        if model.hasActiveSession, panel?.isVisible == true, !closing { close(); return }
        var seen: Set<String> = []
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AppItem(app: .init(name: app.localizedName ?? id, bundleIdentifier: id),
                           icon: app.icon ?? NSImage(named: NSImage.applicationIconName)!, pid: app.processIdentifier)
        }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        snapshots = QuickSelection.browsers.sorted().compactMap { browser in
            guard apps.contains(where: { $0.id == browser }),
                  BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).supports(.quickSelection, maxAge: 5) else { return nil }
            try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
            return BrowserTabSnapshotStore(browserBundleIdentifier: browser).load()
        }
    }
    func reloadBrowserTabs(_ browser: String) async {
        _ = await freshSnapshots(for: [browser])
    }
    func browserWindowID(for window: WindowItem) -> Int? {
        guard let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == window.appID }) else { return nil }
        let siblings = windows.filter { $0.appID == window.appID }
        guard let id = BrowserWindowMatching.match(title: window.title, tabs: snapshot.allTabs ?? snapshot.tabs, nativeWindowCount: siblings.count, frame: window.sourceFrame) else { return nil }
        // Never attach the same tab strip to two windows with ambiguous titles.
        guard siblings.filter({ BrowserWindowMatching.match(title: $0.title, tabs: snapshot.allTabs ?? snapshot.tabs, nativeWindowCount: siblings.count, frame: $0.sourceFrame) == id }).count == 1 else { return nil }
        return id
    }
    func unavailableTabsMessage(for browser: String) -> String {
        let store = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
        if store.isFresh(maxAge: 5), !store.supports(.quickSelection, maxAge: 5) {
            return "Browser Guard update required · connected version cannot select tabs"
        }
        if store.supports(.quickSelection, maxAge: 5) { return "Waiting for tabs · reopen ` if this persists" }
        return "Tabs unavailable · connect Browser Guard"
    }
    func browserLists(for browser: String) -> [(id: Int, title: String)] {
        let all = snapshots.first { $0.browserBundleIdentifier == browser }.map { $0.allTabs ?? $0.tabs } ?? []
        return Dictionary(grouping: all, by: \.windowID).sorted { $0.key < $1.key }.enumerated().map { offset, group in
            let title = group.value.first(where: \.active)?.displayTitle ?? "Browser window"
            return (group.key, "Window \(offset + 1) · \(title) · \(group.value.count) tabs")
        }
    }
    func displayedBrowserWindowID(for window: WindowItem) -> Int? {
        if window.id == focusedBrowserWindow, explicitBrowserWindow?.browser == window.appID { return explicitBrowserWindow?.id }
        return browserWindowID(for: window)
    }
    func tabs(for window: WindowItem) -> [BrowserTabItem] {
        guard let id = displayedBrowserWindowID(for: window) else { return [] }
        return (snapshots.first { $0.browserBundleIdentifier == window.appID }.map { $0.allTabs ?? $0.tabs } ?? []).filter { $0.windowID == id }.sorted { $0.index < $1.index }
    }
    func isSelected(_ window: WindowItem) -> Bool {
        guard QuickSelection.browsers.contains(window.appID) else { return selection.windowIDsByApp[window.appID].map { $0.contains(window.id) } ?? selection.apps.contains(window.appID) }
        if selection.accessMode == .blacklist, selection.apps.contains(window.appID), !selection.tabs.contains(where: { $0.browser == window.appID }) { return true }
        // An explicitly chosen browser list is not proof that its native preview
        // is this ambiguous window, so never outline the wrong preview.
        guard let id = browserWindowID(for: window) else { return false }
        let selectable = (snapshots.first { $0.browserBundleIdentifier == window.appID }.map { $0.allTabs ?? $0.tabs } ?? [])
            .filter { $0.windowID == id && QuickSelection.isSelectable($0) }
        return !selectable.isEmpty && selectable.allSatisfy { isTabSelected($0.id, browser: window.appID) }
    }
    func selectWindow(_ window: WindowItem) {
        guard !closing else { return }
        if QuickSelection.browsers.contains(window.appID) {
            guard !browserLists(for: window.appID).isEmpty else {
                focusedBrowserWindow = window.id
                Task { await reloadBrowserTabs(window.appID) }
                message = unavailableTabsMessage(for: window.appID); return
            }
            explicitBrowserWindow = nil
            focusedBrowserWindow = window.id
            hoveredTab = nil; tabPreview = nil; tabPreviewError = nil
            Task { await reloadBrowserTabs(window.appID) }
            message = nil
        } else if selection.windowIDsByApp[window.appID] != nil { selection.toggleWindow(window.id, app: window.appID) }
        else if let app = apps.first(where: { $0.id == window.appID }) { selectApp(app) }
    }
    private func ensureSelectionSession(_ browser: String) -> Bool {
        guard BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).supports(.tabSessionIdentity, maxAge: 5),
              let nonce = snapshots.first(where: { $0.browserBundleIdentifier == browser })?.browserSessionID else {
            message = "Update Browser Guard to select tabs safely across browser restarts."; return false
        }
        guard selection.pinBrowserSession(browser, sessionID: nonce) else {
            message = "The browser restarted. Press ` + Esc to clear the old selection, then select your tabs again."; return false
        }
        return true
    }
    func isTabSelected(_ id: Int, browser: String) -> Bool {
        selection.browserSessionIDs[browser] == snapshots.first(where: { $0.browserBundleIdentifier == browser })?.browserSessionID
            && selection.tabs.contains(.init(browser: browser, id: id))
    }
    func selectTab(_ tab: BrowserTabItem, browser: String, extendingRange: Bool) {
        message = nil
        guard ensureSelectionSession(browser) else { return }
        guard let window = windows.first(where: { $0.id == focusedBrowserWindow }), window.appID == browser else { return }
        selection.selectTab(.init(browser: browser, id: tab.id), windowID: tab.windowID,
                            displayedTabs: tabs(for: window), extendingRange: extendingRange)
        if hasStagedSelection { refreshStagedOutlines() }
    }
    func toggleAllFocusedTabs() {
        guard let window = windows.first(where: { $0.id == focusedBrowserWindow }),
              let id = displayedBrowserWindowID(for: window) else { return }
        guard ensureSelectionSession(window.appID) else { return }
        selection.toggleBrowserWindow(browser: window.appID, windowID: id, snapshots: snapshots)
    }
    func selectApp(_ app: AppItem) {
        if app.app.isBrowser && selection.accessMode == .whitelist {
            message = "Select website tabs above a Chrome or Firefox window."; return
        }
        message = nil; selection.toggleApp(app.id, snapshots: snapshots)
    }
    func runSelection() {
        guard !closing, !loading, !selection.apps.isEmpty else { return }
        refresh()
        do { _ = try selection.makeIntention(apps: apps.map(\.app), snapshots: snapshots) }
        catch { message = error.localizedDescription; return }
        dismissAnimated(start: true)
    }
    func cancel() { if !closing { dismissAnimated(start: false) } }
    private func dismissAnimated(start: Bool) {
        closing = true
        let token = generation
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduced ? nil : .easeInOut(duration: 0.24)) { expanded = false }
        Task { [weak self] in
            if !reduced { try? await Task.sleep(nanoseconds: 240_000_000) }
            guard let self, self.generation == token else { return }
            if start {
                self.refresh()
                guard self.model.startQuickSelection(self.selection, apps: self.apps.map(\.app), snapshots: self.snapshots, onboardingOrigin: .overview) else {
                    self.message = self.model.errorMessage; self.closing = false
                    withAnimation(.easeOut(duration: 0.2)) { self.expanded = true }; return
                }
                self.hasStagedSelection = false; self.workspaceOutlines.stop()
                self.close()
                if self.model.pendingFriction != nil || self.model.pendingEndTimeRequest != nil { self.model.showOverlay() }
            } else {
                self.close()
                if self.hasStagedSelection { self.refreshStagedOutlines(); self.showStagedModifiers() }
                if self.wasOverlayVisible { self.model.showOverlay() } else { self.previousApp?.activate(options: []) }
            }
        }
    }
    private func close() {
        optionsSection = nil
        hoverTask?.cancel(); hoverTask = nil; hoveredTab = nil; tabPreview = nil; tabPreviewLoading = false
        for browser in QuickSelection.browsers { try? FileManager.default.removeItem(at: BrowserTabPreview.fileURL(browser: browser)) }
        generation = UUID(); previewTask?.cancel(); previewTask = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil); panel = nil
        onboarding.selectionVisible = false
        windows = []; apps = []; snapshots = []; wallpaper = nil; loading = false; closing = false
    }
    func enablePreviews() {
        hasPreviewPermission = CGRequestScreenCaptureAccess()
        if hasPreviewPermission { loadPreviews() }
        else {
            panel?.orderOut(nil)
            onboarding.selectionVisible = false
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            message = "Turn on Intent in Screen Recording, then reopen `."
        }
    }
    func hoverTab(_ tab: BrowserTabItem, browser: String, entered: Bool) {
        hoverTask?.cancel(); hoveredTab = nil; tabPreview = nil; tabPreviewError = nil
        guard entered else { return }
        let expectedBrowserSessionID = snapshots.first(where: { $0.browserBundleIdentifier == browser })?.browserSessionID
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, !self.closing, self.panel?.isVisible == true else { return }
            self.hoveredTab = tab
            guard QuickSelection.hasWebURL(tab), tab.discarded != true else {
                self.tabPreviewError = "This tab can be selected. Its content preview is unavailable because it is an internal, local, blank or sleeping tab."
                return
            }
            let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
            guard heartbeat.supports(.tabPreview, maxAge: 5) else {
                self.tabPreviewError = "Reload Browser Guard to enable tab previews."; return
            }
            self.tabPreviewLoading = true
            defer { self.tabPreviewLoading = false }
            guard let expectedBrowserSessionID, !expectedBrowserSessionID.isEmpty,
                  self.snapshots.first(where: { $0.browserBundleIdentifier == browser })?.browserSessionID == expectedBrowserSessionID else {
                self.tabPreviewError = "The browser changed. Refresh the tab list and try again."
                return
            }
            let command = BrowserTabCommand(tabID: tab.id, windowID: tab.windowID, action: .preview, browserSessionID: expectedBrowserSessionID)
            let url = BrowserTabPreview.fileURL(browser: browser)
            try? FileManager.default.removeItem(at: url)
            try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(command)
            for _ in 0..<40 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard !self.closing else { return }
                if let data = try? Data(contentsOf: url),
                   let result = try? JSONDecoder().decode(BrowserTabPreview.self, from: data), result.requestID == command.id {
                    try? FileManager.default.removeItem(at: url)
                    if let encoded = result.image?.split(separator: ",", maxSplits: 1).last,
                       let imageData = Data(base64Encoded: String(encoded)), let image = NSImage(data: imageData) {
                        self.tabPreview = image
                    } else { self.tabPreviewError = result.error ?? "This tab’s title and website are shown below." }
                    return
                }
            }
            self.tabPreviewError = "Preview timed out. Try hovering again."
        }
    }
    private func loadPreviews() {
        guard !loading, !closing else { return }
        hasPreviewPermission = CGPreflightScreenCaptureAccess()
        guard hasPreviewPermission else { return }

        let token = generation
        loading = true
        previewTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                // Capture only the desktop behind all ordinary windows. A private
                // background-layer window can be transparent/black when captured alone.
                if #available(macOS 14.0, *), self.wallpaper == nil, let display = content.displays.first(where: { $0.frame == self.displayFrame }) {
                    let config = SCStreamConfiguration()
                    config.width = Int(self.displayFrame.width); config.height = Int(self.displayFrame.height)
                    config.showsCursor = false
                    let excluded = content.windows.filter { window in
                        let owner = window.owningApplication?.bundleIdentifier ?? ""
                        return window.windowLayer >= 0 || owner == "com.apple.finder"
                            || owner == "com.apple.notificationcenterui" || owner.localizedCaseInsensitiveContains("widget")
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), self.generation == token {
                        self.wallpaper = NSImage(cgImage: image, size: .zero)
                    }
                }
                let appByPID = Dictionary(uniqueKeysWithValues: self.apps.map { ($0.pid, $0.id) })
                let invisibleIDs = Set((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { entry -> CGWindowID? in
                    guard let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 else { return nil }
                    return entry[kCGWindowNumber as String] as? CGWindowID
                })
                var seenWindowIDs = Set<CGWindowID>()
                let candidates = content.windows.filter {
                    !invisibleIDs.contains($0.windowID) && $0.windowLayer == 0 && $0.frame.width > 140 && $0.frame.height > 140
                        && seenWindowIDs.insert($0.windowID).inserted
                        && ($0.isOnScreen || !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        && $0.owningApplication.flatMap { appByPID[$0.processID] } != nil
                }.sorted {
                    let rowA = Int($0.frame.midY / 120), rowB = Int($1.frame.midY / 120)
                    if rowA != rowB { return rowA < rowB }
                    if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
                    return $0.windowID < $1.windowID
                }
                var items: [WindowItem] = []
                // Bound capture concurrency: avoid serial per-window latency without
                // flooding WindowServer or changing the stable overview ordering.
                for offset in stride(from: 0, to: candidates.count, by: 3) {
                    guard !Task.isCancelled, self.generation == token else { return }
                    let batch = await withTaskGroup(of: (Int, WindowItem?).self) { group in
                        for index in offset..<min(offset + 3, candidates.count) {
                            let window = candidates[index]
                            guard let pid = window.owningApplication?.processID, let appID = appByPID[pid] else { continue }
                            group.addTask { (index, await Self.captureWindow(window, appID: appID)) }
                        }
                        var results: [(Int, WindowItem?)] = []
                        for await result in group { results.append(result) }
                        return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
                    }
                    items.append(contentsOf: batch)
                }
                guard !Task.isCancelled, self.generation == token else { return }
                let liveIDs = Set(content.windows.map(\.windowID))
                self.previewCache = self.previewCache.filter { liveIDs.contains($0.key) }
                for index in items.indices {
                    let item = items[index]
                    if item.preview != nil { self.previewCache[item.id] = item }
                    else if let cached = self.previewCache[item.id], cached.appID == item.appID, cached.title == item.title {
                        items[index].preview = cached.preview
                    }
                }
                for app in self.apps where !items.contains(where: { $0.appID == app.id }) {
                    items.append(.init(id: UInt32.max - UInt32(app.pid), appID: app.id, title: app.app.name,
                        sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil))
                }
                self.windows = items; self.loading = false; self.refresh()
                if items.contains(where: { $0.preview == nil && liveIDs.contains($0.id) }), self.previewRetry < 2 {
                    self.previewRetry += 1
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        guard let self, self.generation == token, !self.closing else { return }
                        self.loadPreviews()
                    }
                }
                // Mount the captured windows before fading in the overview.
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard self.generation == token, !self.closing else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1)) { self.expanded = true }
            } catch {
                guard let self, self.generation == token else { return }
                self.loading = false
                self.windows = self.apps.map { app in
                    .init(id: UInt32.max - UInt32(app.pid), appID: app.id, title: app.app.name,
                          sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil)
                }
                self.expanded = true
                self.message = "Window images are temporarily unavailable. You can still choose your apps."
            }
        }
    }
    private static func captureWindow(_ window: SCWindow, appID: String) async -> WindowItem? {
        guard !Task.isCancelled else { return nil }
        var image: CGImage?
        if #available(macOS 14.0, *) {
            let config = SCStreamConfiguration()
            let scale = min(1, 1000 / max(window.frame.width, window.frame.height))
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if image.map(Self.hasVisiblePixels) != true, !Task.isCancelled {
                image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        }
        if image.map(Self.hasVisiblePixels) != true {
            image = CGWindowListCreateImage(.null, .optionIncludingWindow, window.windowID, [.boundsIgnoreFraming, .bestResolution])
        }
        if let captured = image, !Self.hasVisiblePixels(captured) { image = nil }
        guard !Task.isCancelled else { return nil }
        return .init(id: window.windowID, appID: appID, title: window.title ?? "", sourceFrame: window.frame,
                     preview: image.map { NSImage(cgImage: $0, size: .zero) })
    }
    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        // Some WindowServer surfaces report success but return transparent pixels.
        // Treat those as failed captures, so retry/fallback can recover them.
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return stride(from: 3, to: buffer.count, by: 4).filter { buffer[$0] > 16 }.count > 8
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct QuickSelectionView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject private var onboarding: IntentOnboardingCoordinator
    @State private var hoveredWindow: CGWindowID?
    @ObservedObject private var model: IntentAppModel
    @AppStorage("overviewShowClock") private var showClock = true
    @AppStorage("overviewShowTitles") private var showTitles = true
    init(controller: QuickSelectionController) {
        self.controller = controller
        model = controller.model
        onboarding = controller.onboarding
    }
    private var accent: Color { controller.selection.accessMode == .blacklist ? .red : .green }
    var body: some View {
        GeometryReader { geometry in
            let presetIDs = Set((model.alwaysAllowedApps + model.alwaysBlockedApps).map(\.bundleIdentifier))
            let visibleWindows = controller.windows.filter { !presetIDs.contains($0.appID) }
            let focused = visibleWindows.first { $0.id == controller.focusedBrowserWindow }
            let tabWidth: CGFloat = focused == nil ? 0 : min(440, geometry.size.width * 0.38)
            let header = controller.topSafeInset + 48 + (onboarding.isTeaching ? 60 : 0)
            let footer: CGFloat = controller.message == nil ? 140 : 210
            let area = CGRect(x: 28, y: header + 12, width: max(1, geometry.size.width - 56 - tabWidth), height: max(1, geometry.size.height - header - footer - 12))
            let frames = FieldOfViewLayout.frames(sourceFrames: visibleWindows.map(\.sourceFrame), in: area, tabHeight: 0)
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = controller.wallpaper { Image(nsImage: image).resizable().scaledToFill() }
                    else { Color.black }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped().allowsHitTesting(false)
                Color.black.opacity(0.12).allowsHitTesting(false)
                ForEach(Array(visibleWindows.enumerated()), id: \.element.id) { index, window in
                    if index < frames.count { windowCard(window, frame: frames[index]) }
                }
                VStack {
                    HStack {
                        Spacer()
                        if showClock { TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(context.date, style: .time).monospacedDigit().font(.system(size: 14, weight: .medium)).frame(minWidth: 80)
                        } }
                    }.overlay {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("ı").overlay(alignment: .top) { Text(verbatim: "`").font(.system(size: 17, weight: .bold)).offset(x: 1, y: -4) }
                            Text("ntent")
                        }.font(.system(size: 27, weight: .medium, design: .serif)).accessibilityElement(children: .ignore).accessibilityLabel("Intent")
                    }.padding(.horizontal, 28).frame(height: 48).padding(.top, controller.topSafeInset)
                    if onboarding.isTeaching {
                        OnboardingSelectionHint(coordinator: controller.onboarding)
                            .frame(height: 60).padding(.horizontal, 28)
                    }
                }.frame(width: geometry.size.width)
                VStack(spacing: 8) {
                    ModificationStrip(controller: controller).frame(maxWidth: 880).padding(.horizontal, 28)
                    if let message = controller.message {
                        Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
                            .padding(8).frame(maxWidth: geometry.size.width - 56).frame(height: 52)
                            .background(.regularMaterial, in: Capsule()).help(message)
                    }
                    HStack {
                        AppPresetStatusStrip(model: model) { controller.settingsOpen = true }
                        Spacer(minLength: 16)
                    }.padding(.horizontal, 28).frame(height: 26)
                    HStack {
                        Button("Close · ` / Esc") { controller.cancel() }.buttonStyle(.plain)
                        Spacer()
                        Button(controller.selection.accessMode == .blacklist ? "Block selected · /" : "Allow selected · /") { controller.toggleAccessMode() }.buttonStyle(.plain).foregroundStyle(accent)
                        Spacer()
                        Button("Run · Return ↵") { controller.runSelection() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                            .disabled(controller.selection.apps.isEmpty || controller.loading || controller.closing)
                        Button { controller.settingsOpen.toggle() } label: {
                            Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("Overview settings").help("Settings and app presets")
                            .popover(isPresented: $controller.settingsOpen, arrowEdge: .top) {
                                OverviewSettingsView(model: model).frame(width: 380).padding(20).preferredColorScheme(.dark)
                            }
                    }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 28).frame(height: 52)
                }.frame(width: geometry.size.width, height: footer, alignment: .bottom)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - footer / 2)
                if controller.loading {
                    ProgressView("Gathering your apps…").padding(18).background(.regularMaterial, in: Capsule())
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                if let focused {
                    tabGrid(focused).frame(width: tabWidth - 20, height: area.height)
                        .position(x: geometry.size.width - tabWidth / 2 - 12, y: area.midY)
                }
                RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.8), lineWidth: 3).padding(3)
                    .shadow(color: accent.opacity(0.65), radius: 10).allowsHitTesting(false)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped().foregroundStyle(.white).preferredColorScheme(.dark)
                .onChange(of: presetIDs) { ids in
                    for id in ids where controller.selection.apps.contains(id) {
                        controller.selection.toggleApp(id, snapshots: controller.snapshots)
                    }
                    if let focused, ids.contains(focused.appID) { controller.focusedBrowserWindow = nil }
                }
        }.ignoresSafeArea()
    }
    private func windowCard(_ window: QuickSelectionController.WindowItem, frame: CGRect) -> some View {
        let app = controller.apps.first { $0.id == window.appID }
        let selected = controller.isSelected(window)
        let browser = QuickSelection.browsers.contains(window.appID)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty || title == "()" ? (app?.app.name ?? window.appID) : title
        let hovered = hoveredWindow == window.id
        let captionWidth = max(FieldOfViewLayout.minimumCaptionWidth, frame.width)
        let captionHeight = FieldOfViewLayout.captionHeight
        let radius = min(10, min(frame.width, frame.height) / 8)
        return VStack(spacing: 6) {
            Button { controller.selectWindow(window) } label: {
                ZStack {
                    if let image = window.preview {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
                        if let app {
                            Image(nsImage: app.icon).resizable().scaledToFit()
                                .frame(width: min(84, frame.width * 0.45), height: min(84, frame.height * 0.65))
                        }
                    }
                }.frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .stroke(selected ? accent : .white.opacity(hovered ? 0.8 : 0.2), lineWidth: selected ? 3 : 1))
                    .shadow(color: selected ? accent.opacity(0.4) : .black.opacity(0.35), radius: hovered ? 12 : 7, y: 3)
                    .contentShape(RoundedRectangle(cornerRadius: radius))
            }.buttonStyle(.plain)
                .accessibilityLabel("\(app?.app.name ?? window.appID): \(label), \(selected ? "selected" : "not selected")")
            HStack(spacing: 5) {
                Button { controller.selectWindow(window) } label: {
                    HStack(spacing: 5) {
                        if let app { Image(nsImage: app.icon).resizable().frame(width: 16, height: 16) }
                        Text(showTitles ? label : (app?.app.name ?? label)).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, minHeight: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(app?.app.name ?? window.appID): \(label), \(selected ? "selected" : "not selected")")
                if browser {
                    Button {
                        controller.explicitBrowserWindow = nil
                        controller.focusedBrowserWindow = controller.focusedBrowserWindow == window.id ? nil : window.id
                    } label: {
                        Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 5).frame(height: 20)
                    }.buttonStyle(.plain).accessibilityLabel("Show tabs for \(label)").help("Choose browser tabs")
                }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 5)
                .frame(maxWidth: captionWidth, minHeight: 20, maxHeight: 20)
                .background(.black.opacity(hovered || selected ? 0.5 : 0.25), in: Capsule())
        }.frame(width: captionWidth, height: frame.height + captionHeight, alignment: .top)
            .onHover { hoveredWindow = $0 ? window.id : (hoveredWindow == window.id ? nil : hoveredWindow) }
            .help("\(app?.app.name ?? window.appID) — \(label)")
            .opacity(controller.expanded ? 1 : 0).allowsHitTesting(controller.expanded && !controller.closing)
            // Keep hover/help hit regions on the card's bounds. Position expands
            // its layout wrapper to the canvas; attaching interaction after it
            // lets later cards intercept clicks intended for earlier previews.
            .position(x: frame.midX, y: frame.midY + captionHeight / 2)
    }
    private func tabGrid(_ window: QuickSelectionController.WindowItem) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(controller.apps.first { $0.id == window.appID }?.app.name ?? "Browser tabs").font(.headline)
                    Spacer()
                    Button { controller.focusedBrowserWindow = nil; controller.hoveredTab = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close tabs")
                }
                if controller.tabs(for: window).isEmpty {
                    Label("Connect Browser Guard in this window’s browser profile to see its tabs.", systemImage: "puzzlepiece.extension")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh tabs") { Task { await controller.reloadBrowserTabs(window.appID) } }
                        .buttonStyle(.bordered)
                }
                Toggle(isOn: Binding(get: {
                    let shown = controller.tabs(for: window)
                    return !shown.isEmpty && shown.allSatisfy { controller.isTabSelected($0.id, browser: window.appID) }
                }, set: { _ in controller.toggleAllFocusedTabs() })) {
                    HStack { Text("Select all"); Spacer(); Text("X").font(.caption.monospaced()).foregroundStyle(.secondary) }
                }.toggleStyle(.checkbox).tint(accent)
                Text("Click to select · Shift-click for a range").font(.caption2).foregroundStyle(.secondary)
                let tabs = controller.tabs(for: window)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            let key = QuickSelectionTab(browser: window.appID, id: tab.id)
                            let selected = controller.isTabSelected(key.id, browser: window.appID)
                            Button { controller.selectTab(tab, browser: window.appID, extendingRange: NSEvent.modifierFlags.contains(.shift)) } label: {
                                HStack(spacing: 10) {
                                    TabSiteIcon(url: tab.faviconURL)
                                    Text(tab.displayTitle).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                    if tab.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                                    if selected { Image(systemName: "checkmark").foregroundStyle(accent) }
                                }.padding(.horizontal, 10).frame(height: 38).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(selected ? accent.opacity(0.15) : .white.opacity(tab.active ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? accent : .clear, lineWidth: 1.5))
                            }.buttonStyle(.plain)
                                .onHover { controller.hoverTab(tab, browser: window.appID, entered: $0) }
                                .help("\(tab.displayTitle) · Shift-click to select a range.\(QuickSelection.hasWebURL(tab) ? "" : " Content preview is unavailable; tab selection and native access control still apply.")")
                                .accessibilityLabel("Tab: \(tab.displayTitle), \(selected ? "selected" : "not selected")")
                        }
                    }.padding(2)
                }.frame(height: max(60, (geometry.size.height - 94) / 2))
                Divider()
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.12))
                    if let image = controller.tabPreview { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
                    else if controller.tabPreviewLoading { ProgressView("Loading preview…") }
                    else {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle").font(.title2)
                            Text(controller.tabPreviewError ?? "Hover a tab to preview it").font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let tab = controller.hoveredTab { Text(tab.title).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            }.padding(16)
        }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TabSiteIcon: View {
    let url: String?
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }.frame(width: 18, height: 18).task(id: url) {
            icon = nil
            guard let url, let address = URL(string: url) else { return }
            if address.scheme == "data", let encoded = url.split(separator: ",", maxSplits: 1).last,
               let data = Data(base64Encoded: String(encoded)) { icon = NSImage(data: data); return }
            guard ["https", "http"].contains(address.scheme ?? "") else { return }
            var request = URLRequest(url: address); request.timeoutInterval = 5
            if let (data, _) = try? await URLSession.shared.data(for: request), data.count < 1_000_000, !Task.isCancelled {
                icon = NSImage(data: data)
            }
        }
    }
}

private struct QuickMarkRecoveryNotice: View {
    let text: String
    let needsSetup: Bool
    let setup: () -> Void
    let overview: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Open tab picker", action: overview)
                    Button("Browser Guard setup", action: setup)
                }.buttonStyle(.plain).foregroundStyle(.green)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
        }.padding(16).frame(width: 420, height: 120).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .preferredColorScheme(.dark)
    }
}

private struct ModificationStrip: View {
    @ObservedObject var controller: QuickSelectionController
    private var accent: Color { controller.selection.accessMode == .blacklist ? .red : .green }
    @State private var dragged: QuickSelectionOptionsSection?
    @State private var dragOffset: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 12) {
            ForEach(Array(controller.modificationOrder.enumerated()), id: \.element) { index, section in
                let enabled = section.enabled(in: controller.selection)
                Button { controller.openModification(section) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: section.icon)
                        Text(section.rawValue)
                        Text("` + \(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        if enabled { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                    }.font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(enabled ? accent.opacity(0.8) : .white.opacity(0.2)))
                }.buttonStyle(.plain).help(section.hint + " Hold and drag to swap positions.")
                    .offset(x: dragged == section ? dragOffset : 0).zIndex(dragged == section ? 1 : 0)
                    .highPriorityGesture(DragGesture(minimumDistance: 10)
                        .onChanged { value in dragged = section; dragOffset = value.translation.width }
                        .onEnded { value in
                            let slot = (geometry.size.width + 12) / CGFloat(controller.modificationOrder.count)
                            let destination = min(controller.modificationOrder.count - 1, max(0, index + Int((value.translation.width / slot).rounded())))
                            controller.swapModification(section.rawValue, with: controller.modificationOrder[destination])
                            dragged = nil; dragOffset = 0
                        })
                    .popover(isPresented: Binding(get: { controller.optionsSection == section }, set: { if !$0, controller.optionsSection == section { controller.closeModification() } }), arrowEdge: .bottom) {
                        VStack(spacing: 0) {
                            if controller.combinationNotice {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Timer + Checklist", systemImage: "info.circle").font(.headline)
                                    Text("Whichever finishes first ends your intention: all tasks checked or time up. Normal finish is disabled; Safety Stop remains available.").font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Button("Got it") { controller.acknowledgeCombination() }.buttonStyle(.bordered)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.green.opacity(0.08))
                                Divider()
                            }
                            QuickSelectionOptionsView(selection: $controller.selection, section: section) { controller.closeModification() }
                                .frame(height: section == .checklist ? 360 : 300)
                        }.frame(width: 360)
                    }
            }
        }
        }.frame(height: 44)
    }
}
