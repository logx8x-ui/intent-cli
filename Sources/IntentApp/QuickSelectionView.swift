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
    @Published private(set) var openingApps = Set<String>()
    private var spotlightApps: [String: AllowedApp] = [:]
    var onOverviewClosed: (() -> Void)?
    private var overviewInput = OverviewSearchGesture()
    private var overviewNormalizer = QuickMarkKeyboardNormalizer()
    var ownsOverviewPrefixInput: Bool { panel?.isVisible == true && overviewInput.isHoldingPrefix }
    // WebKit's page responder is not an NSTextView. Treat the finder as an
    // editing surface so digits, Return, X and Space cannot trigger the overview.
    private var isEditingText: Bool { websiteFinder != nil || (NSApp.keyWindow ?? panel)?.firstResponder is NSTextView }
    func prepareForSpotlight() {
        guard panel?.isVisible == true else { return }
        overviewInput = OverviewSearchGesture()
        overviewNormalizer = QuickMarkKeyboardNormalizer()
        closeModification(); settingsOpen = false
        // System hotkeys are handled before AppKit local event monitors. Lower
        // the panel from the global tap, before Spotlight's window is presented.
        panel?.level = .normal
    }
    func openAppleSpotlight() {
        prepareForSpotlight()
        NativeSpotlightKeyboard.open()
    }
    func handleOverviewKey(code: Int, down: Bool, modified: Bool, repeatKey: Bool, capsLockHeld: Bool = false) -> Bool {
        guard panel?.isVisible == true, !nativeFinderOwnsInput else { return false }
        let result = overviewInput.key(code: code, down: down, modified: modified, repeated: repeatKey,
            editing: isEditingText, capsLockHeld: capsLockHeld, browserPickerAvailable: currentWebsiteFinderTarget != nil)
        switch result.action {
        case .close: cancelImmediately()
        case .clear: clearMarks(); cancelImmediately()
        case .modification(let index): openModification(index)
        case .mode: toggleAccessMode()
        case .run: runSelection()
        case .savedSlot(let index): if !settingsOpen && optionsSection == nil { runSavedSlot(index) }
        case .websiteFinder: openWebsiteFinder()
        case nil: break
        }
        return result.consume
    }

    func reportSpotlightFailure(_ text: String) {
        // Leave Apple's results in front so the user can correct the selection.
        message = text
    }
    func spotlightVisibilityChanged(_ visible: Bool) {
        guard !nativeFinderOwnsInput, let panel, panel.isVisible else { return }
        panel.level = visible ? .normal : .popUpMenu
        if !visible { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    }
    func cancelImmediately() {
        overviewInput = OverviewSearchGesture()
        overviewNormalizer = QuickMarkKeyboardNormalizer()
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet); sheet.orderOut(nil) }
        markTask?.cancel(); markTask = nil; markGeneration = UUID()
        let previous = previousApp
        clearMarks()
        close()
        if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { previous?.activate(options: []) }
    }
    private func preserveAddedAppIcons(in items: [WindowItem]) -> [WindowItem] {
        var result = items
        for app in apps where spotlightApps[app.id] != nil && selection.apps.contains(app.id)
            && !result.contains(where: { $0.appID == app.id }) {
            result.append(.init(id: Self.placeholderID(app), appID: app.id, title: app.app.name,
                sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil))
        }
        return result
    }
    private static func placeholderID(_ app: AppItem) -> UInt32 {
        if app.pid > 0 { return UInt32.max - UInt32(app.pid) }
        let hash = app.id.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return 0xF0000000 | (hash & 0x0FFFFFFF)
    }
    func addSpotlightApplication(_ url: URL) {
        guard !model.hasActiveSession, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        if model.alwaysAllowedApps.contains(where: { $0.bundleIdentifier == id }) {
            message = "This app is already always allowed."; spotlightVisibilityChanged(false); return
        }
        if model.alwaysBlockedApps.contains(where: { $0.bundleIdentifier == id }) {
            message = "This app is always blocked. Change its app default in Settings first."; spotlightVisibilityChanged(false); return
        }
        panel?.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(nil)
        dismissBrowserPicker()
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let app = AllowedApp(name: name, bundleIdentifier: id)
        spotlightApps[id] = app; selection.apps.insert(id); hasStagedSelection = true
        selection.windowIDsByApp.removeValue(forKey: id)
        if QuickSelection.browsers.contains(id) {
            selection.wholeBrowserApps = (selection.wholeBrowserApps ?? []).union([id])
            selection.tabs = selection.tabs.filter { $0.browser != id }
        }
        if selection.accessMode == .whitelist {
            selection.startupAppIDs = (selection.startupAppIDs ?? []).union([id])
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                SpotlightAppPreparation.shared.prepare(url) { [weak self] failure in
                    if let failure { self?.message = failure }
                }
            }
        }
        refresh()
        if !windows.contains(where: { $0.appID == id }), let item = apps.first(where: { $0.id == id }) {
            windows.append(.init(id: Self.placeholderID(item), appID: id, title: name,
                sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil))
        }
        refreshStagedOutlines()
        if panel?.isVisible != true { showStagedModifiers() }
    }
    @Published var windows: [WindowItem] = []
    @Published var snapshots: [BrowserTabSnapshot] = []
    @Published var selection = QuickSelection() {
        didSet {
            savedRunTask?.cancel(); savedRunTask = nil
            if !applyingSavedWorkspace {
                restoredRunWorkspace = nil
                savedRestorationTask?.cancel(); savedRestorationTask = nil
                savedRestorationGeneration = UUID(); restoringSavedWorkspace = false
                if let staged = preparedSavedWorkspace,
                   oldValue.apps != selection.apps || oldValue.tabs != selection.tabs || oldValue.windowIDsByApp != selection.windowIDsByApp
                    || oldValue.wholeBrowserApps != selection.wholeBrowserApps {
                    preparedSavedWorkspace = staged.reconcilingSelection(
                        previous: captureWorkspace(selection: oldValue), current: captureWorkspace())
                    replanPreparedWorkspace()
                } else if preparedSavedWorkspace != nil, oldValue.accessMode != selection.accessMode {
                    replanPreparedWorkspace()
                }
            }
            let keep = selection.accessMode == .whitelist ? selection.apps : []
            SpotlightAppPreparation.shared.release(except: keep)
        }
    }
    @Published var savedSlotPage = 0
    @Published var savedSlotCapacity = 6
    struct SaveFlight: Equatable {
        let token = UUID()
        let recordID: UUID
        let savedID: String
    }
    @Published var saveFlight: SaveFlight?
    private var resumeRecord: IntentSessionRecord?
    private var preparedOverviewPending = false
    var visibleSavedSlots: [Intention] {
        let slots = model.savedSlots
        let page = min(savedSlotPage, max(0, (slots.count - 1) / max(1, savedSlotCapacity)))
        return Array(slots.dropFirst(page * savedSlotCapacity).prefix(savedSlotCapacity))
    }
    var savedSlotPages: Int { max(1, (model.savedSlots.count + savedSlotCapacity - 1) / savedSlotCapacity) }
    private var savedRunTask: Task<Void, Never>?
    @Published private(set) var restoringSavedWorkspace = false
    @Published private(set) var pendingSavedTabs: [SessionWorkspace.PendingTab] = []
    private var preparedSavedWorkspace: SessionWorkspace?
    private var preparedSavedIntention: Intention?
    private var restoredRunWorkspace: SessionWorkspace?
    private var profileDiscoveryInFlight = false
    private var browserLaunchesInFlight: Set<String> = []
    private var applyingSavedWorkspace = false
    private var savedRestorationTask: Task<Void, Never>?
    private var savedRestorationGeneration = UUID()
    private let savedRestoreClaims = SavedWorkspaceRestoreClaims()
    var hasRunnableDraft: Bool { !selection.apps.isEmpty || preparedSavedWorkspace != nil }

    private func copySavedConfiguration(_ source: QuickSelection, into draft: inout QuickSelection) {
        draft.name = source.name; draft.sourceIntentionID = source.sourceIntentionID
        draft.accessMode = source.accessMode
        draft.restrictionNodes = source.restrictionNodes; draft.frictionNodes = source.frictionNodes
        draft.websiteFeaturePolicies = source.websiteFeaturePolicies
        draft.wholeBrowserApps = source.wholeBrowserApps
        draft.startupAppIDs = source.startupAppIDs
    }
    private func replanPreparedWorkspace() {
        guard let workspace = preparedSavedWorkspace, let intention = preparedSavedIntention else { return }
        let configuration = selection
        let resolved = savedResolution(workspace, intention: intention, accessMode: configuration.accessMode)
        var draft = resolved.selection
        copySavedConfiguration(configuration, into: &draft)
        if draft.accessMode == .whitelist {
            draft.apps.formUnion(Set(resolved.replayWorkspace.tabs.map(\.browser)).intersection(Set(model.installedApps.map(\.bundleIdentifier))))
        }
        applyingSavedWorkspace = true; selection = draft; applyingSavedWorkspace = false
        preparedSavedWorkspace = resolved.replayWorkspace
        pendingSavedTabs = resolved.pendingTabs
        if resolved.missing > 0 { message = resolved.problems.first ?? "Review the saved resources before running." }
        else if !resolved.pendingTabs.isEmpty { message = "Opens at Run: " + resolved.pendingTabs.map { $0.descriptor.title.isEmpty ? $0.descriptor.url : $0.descriptor.title }.joined(separator: ", ") }
        else { message = "Ready when you are. Review your workspace, then Return." }
    }

    func runSavedSlot(_ index: Int) {
        guard isSelectionSurfaceVisible, !closing, !restoringSavedWorkspace,
              visibleSavedSlots.indices.contains(index) else { return }
        let intention = visibleSavedSlots[index]
        savedRunTask?.cancel()
        savedRunTask = Task { [weak self] in
            // Keep the requested ID, not the position: reordering during loading
            // must never start a different intention.
            while let self, self.loading || !self.openingApps.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled || !self.isSelectionSurfaceVisible { return }
            }
            guard !Task.isCancelled, let self, self.isSelectionSurfaceVisible,
                  let current = self.model.intentions.first(where: { $0.id == intention.id }) else { return }
            let workspace = self.model.journal.workspaces[current.id]
            // Saved-card/digit activation is the explicit Run gesture. The
            // transaction handles closed browsers before requesting inventory.
            self.savedRunTask = nil
            self.prepare(current, workspace: workspace, run: true)
        }
    }
    func removeAddedApplication(_ id: String) {
        preparedSavedWorkspace?.removeResources(for: id)
        pendingSavedTabs.removeAll { $0.descriptor.browser == id }
        savedRunTask?.cancel()
        spotlightApps.removeValue(forKey: id)
        selection.apps.remove(id)
        selection.windowIDsByApp.removeValue(forKey: id)
        selection.tabs = selection.tabs.filter { $0.browser != id }
        selection.wholeBrowserApps?.remove(id)
        selection.startupAppIDs?.remove(id)
        openingApps.remove(id)
        SpotlightAppPreparation.shared.release(except: selection.apps)
        windows.removeAll { $0.appID == id }
        refresh(); refreshStagedOutlines()
    }
    func isAddedApplication(_ id: String) -> Bool { spotlightApps[id] != nil }
    func saveRecent(_ record: IntentSessionRecord) {
        let wasSaved = model.savedIntentionID(for: record) != nil
        guard let id = model.saveRecord(record) else { message = model.errorMessage; return }
        if let index = model.savedSlots.firstIndex(where: { $0.id == id }) { savedSlotPage = index / savedSlotCapacity }
        if !wasSaved { saveFlight = .init(recordID: record.id, savedID: id) }
    }
    private func resetSelectionKeepingName() {
        let name = selection.name; selection = QuickSelection(); selection.name = name
    }
    func toggleSlots() { savedSlotPage = 0; dismissBrowserPicker() }
    private func currentBrowserProfiles() -> [BrowserTabSnapshot] {
        QuickSelection.browsers.sorted().flatMap { browser -> [BrowserTabSnapshot] in
            let profiles = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: browser))
            if !profiles.isEmpty { return profiles }
            return snapshots.filter { $0.browserBundleIdentifier == browser && $0.browserSessionID?.hasPrefix("profiles:") != true }
        }
    }
    private func liveWorkspaceWindows() -> [SessionWorkspace.LiveWindow] {
        WorkspaceWindow.list(onScreen: false).map { window in
            let process = NSRunningApplication(processIdentifier: window.pid)?.launchDate.map {
                BrowserProcessIdentity(pid: window.pid, launched: $0.timeIntervalSinceReferenceDate)
            }
            return .init(id: window.id, app: window.bundle, title: window.title, process: process)
        }
    }
    func captureWorkspace(profiles suppliedProfiles: [BrowserTabSnapshot]? = nil, selection suppliedSelection: QuickSelection? = nil) -> SessionWorkspace {
        let selection = suppliedSelection ?? self.selection
        let native = liveWorkspaceWindows()
        let windows = selection.windowIDsByApp.flatMap { app, ids in
            native.filter { $0.app == app && ids.contains($0.id) }.map {
                SessionWorkspace.Window(app: app, title: $0.title, nativeID: $0.id, process: $0.process)
            }
        }
        let profiles = suppliedProfiles ?? currentBrowserProfiles()
        let tabs = selection.tabs.sorted { ($0.browser, $0.id) < ($1.browser, $1.id) }.compactMap { key -> SessionWorkspace.Tab? in
            let owners = profiles.filter { $0.browserBundleIdentifier == key.browser }
            for owner in owners {
                guard let session = owner.browserSessionID else { continue }
                if let tab = (owner.allTabs ?? owner.tabs).first(where: {
                    (owners.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: $0.id) : $0.id) == key.id
                }) {
                    return .init(browser: key.browser, url: tab.url, title: tab.title, profileID: owner.browserProfileID,
                        sessionID: session, nativeID: tab.id, windowID: tab.windowID, cookieStoreID: tab.cookieStoreID)
                }
            }
            return nil
        }
        return SessionWorkspace(selection: selection, windows: windows, tabs: tabs)
    }
    private func savedResolution(_ workspace: SessionWorkspace, intention: Intention,
                                 profiles: [BrowserTabSnapshot]? = nil, accessMode: IntentionAccessMode? = nil) -> SessionWorkspace.Resolution {
        let mode = accessMode ?? intention.accessMode
        let presets = Set((model.alwaysAllowedApps + model.alwaysBlockedApps).map(\.bundleIdentifier))
        let installed = Set(model.installedApps.map(\.bundleIdentifier)).subtracting(presets)
        // Defaults own these apps in both review and Run; remove their resource
        // descriptors before calculating missing targets or effects.
        var filtered = workspace
        filtered.selection.apps.subtract(presets)
        filtered.selection.tabs = filtered.selection.tabs.filter { !presets.contains($0.browser) }
        filtered.selection.windowIDsByApp = filtered.selection.windowIDsByApp.filter { !presets.contains($0.key) }
        filtered.selection.wholeBrowserApps = filtered.selection.wholeBrowserApps?.subtracting(presets)
        filtered.selection.startupAppIDs = filtered.selection.startupAppIDs?.subtracting(presets)
        filtered.windows.removeAll { presets.contains($0.app) }
        filtered.tabs.removeAll { presets.contains($0.browser) }
        var result = filtered.restorationPlan(runningApps: Set(apps.map(\.id)).union(installed),
            windows: liveWorkspaceWindows(), profiles: profiles ?? currentBrowserProfiles(), accessMode: mode,
            allowLegacyProfileMigration: profiles != nil)
        // A native app with no remaining windows may stage its default workspace only when
        // allowing it. A missing blocked window must never widen into an app.
        for app in intention.allowedApps where mode == .whitelist
            && installed.contains(app.bundleIdentifier) && !QuickSelection.browsers.contains(app.bundleIdentifier)
            && filtered.selection.apps.contains(app.bundleIdentifier)
            && !liveWorkspaceWindows().contains(where: { $0.app == app.bundleIdentifier }) {
            result.selection.apps.insert(app.bundleIdentifier)
            result.selection.windowIDsByApp.removeValue(forKey: app.bundleIdentifier)
            result.missing = max(0, result.missing - filtered.windows.filter { $0.app == app.bundleIdentifier }.count)
            result.replayWorkspace.removeResources(for: app.bundleIdentifier)
            result.replayWorkspace.selection.apps.insert(app.bundleIdentifier)
        }
        return result
    }
    func prepare(_ intention: Intention, workspace: SessionWorkspace?, resume: IntentSessionRecord? = nil, run: Bool = false, profiles: [BrowserTabSnapshot]? = nil) {
        guard !model.hasActiveSession else { return }
        panel?.makeFirstResponder(nil)
        refresh()
        var draft = QuickSelection(); draft.name = intention.name; draft.accessMode = intention.accessMode
        draft.restrictionNodes = intention.restrictionNodes.filter { $0.id != QuickSelection.startupSuppressionID }
        draft.websiteFeaturePolicies = intention.websiteFeaturePolicies
        draft.frictionNodes = intention.frictionNodes
        var missing = 0
        var pending: [SessionWorkspace.PendingTab] = []
        var restorationProblems: [String] = []
        var stagedWorkspace = workspace
        let presets = Set((model.alwaysAllowedApps + model.alwaysBlockedApps).map(\.bundleIdentifier))
        let installed = Set(model.installedApps.map(\.bundleIdentifier)).subtracting(presets)
        if let workspace {
            let resolved = savedResolution(workspace, intention: intention, profiles: profiles)
            draft = resolved.selection; draft.name = intention.name; missing = resolved.missing
            pending = resolved.pendingTabs; restorationProblems = resolved.problems
            stagedWorkspace = resolved.replayWorkspace
            if draft.accessMode == .whitelist {
                // Identity-only placeholders also cover a fully closed browser.
                // No process or website opens until explicit Run below.
                draft.apps.formUnion(Set(workspace.tabs.map(\.browser)).intersection(installed))
            }
        } else {
            // Legacy saved tab setups have no stable replay snapshot. Never turn
            // their old browser allowance into unrestricted whole-browser access.
            for app in intention.allowedApps where !presets.contains(app.bundleIdentifier) {
                if QuickSelection.browsers.contains(app.bundleIdentifier) && !intention.wholeBrowserBundleIdentifiers.contains(app.bundleIdentifier) { missing += 1 }
                else if intention.selectionRequiresTabReselection { missing += 1 }
                else if apps.contains(where: { $0.id == app.bundleIdentifier }) || installed.contains(app.bundleIdentifier) { draft.apps.insert(app.bundleIdentifier) }
                else { missing += 1 }
            }
        }
        // Workspace snapshots own resource identity, not the saved setup’s latest settings.
        draft.applySessionConfiguration(intention)
        draft.apps.subtract(presets)
        draft.tabs = draft.tabs.filter { !presets.contains($0.browser) }
        draft.windowIDsByApp = draft.windowIDsByApp.filter { !presets.contains($0.key) }
        for app in intention.allowedApps where draft.apps.contains(app.bundleIdentifier) && !apps.contains(where: { $0.id == app.bundleIdentifier }) {
            spotlightApps[app.bundleIdentifier] = app
            if draft.accessMode == .whitelist {
                draft.startupAppIDs = (draft.startupAppIDs ?? []).union([app.bundleIdentifier])
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                    SpotlightAppPreparation.shared.prepare(url) { [weak self] failure in
                        if let failure { self?.message = failure }
                    }
                }
            }
        }
        if let seconds = resume?.remainingSeconds {
            draft.restrictionNodes.removeAll { $0.kind == .timer || $0.kind == .endTime }
            draft.restrictionNodes.append(.init(kind: .timer, position: .zero, durationMinutes: max(1, Int(ceil(seconds / 60))), showsRemainingTime: true, locksSessionUntilTimerEnds: true))
        }
        draft.sourceIntentionID = intention.id
        savedRestorationTask?.cancel(); savedRestorationTask = nil
        savedRestorationGeneration = UUID(); restoringSavedWorkspace = false
        applyingSavedWorkspace = true; selection = draft; applyingSavedWorkspace = false
        restoredRunWorkspace = nil
        preparedSavedWorkspace = stagedWorkspace; preparedSavedIntention = stagedWorkspace == nil ? nil : intention
        pendingSavedTabs = pending
        refresh()
        windows = preserveAddedAppIcons(in: windows)
        hasStagedSelection = true; resumeRecord = resume
        preparedOverviewPending = panel?.isVisible != true
        message = missing == 0
            ? (draft.apps.isEmpty ? (draft.accessMode == .blacklist ? "This saved intention has no blocked apps or tabs. Choose what to block, then run and save it again." : "These apps are already covered by your defaults. Choose an additional app or tab.") : "Ready when you are. Review your workspace, then Return.")
            : (restorationProblems.first ?? "\(missing) items need choosing again. Review your apps and tabs before running.")
        if missing == 0, !pending.isEmpty {
            message = "Opens at Run: " + pending.map { $0.descriptor.title.isEmpty ? $0.descriptor.url : $0.descriptor.title }.joined(separator: ", ")
        }
        if let workspace, draft.accessMode == .whitelist {
            let closedBrowsers = workspace.browsersToLaunchOnRun(
                runningApps: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)), installedApps: installed, accessMode: draft.accessMode)
            if !closedBrowsers.isEmpty {
                let names = intention.allowedApps.filter { closedBrowsers.contains($0.bundleIdentifier) }.map(\.name)
                message = "Opens at Run: " + names.joined(separator: ", ") + ". Intent will check the saved browser profile before restoring its websites."
            }
        }
        if run && (missing == 0 || stagedWorkspace != nil) { runSelection() }
    }
    private func prepareRunMetadata() {
        model.pendingWorkspace = restoredRunWorkspace ?? captureWorkspace()
        if var resumed = resumeRecord {
            let oldTasks = resumed.intention.orderedFrictionNodes.flatMap { node -> [String] in if case .taskChecklist(let tasks) = node.friction { return tasks }; return [] }
            let newTasks = selection.frictionNodes.flatMap { node -> [String] in if case .taskChecklist(let tasks) = node.friction { return tasks }; return [] }
            resumed.completedTasks = Set(newTasks.indices.filter { index in
                oldTasks.indices.contains(index) && oldTasks[index] == newTasks[index] && resumed.completedTasks.contains(index)
            })
            let displayed = selection.restrictionNodes.first { $0.kind == .timer }?.durationMinutes
            if selection.restrictionNodes.contains(where: { $0.kind == .endTime }) || displayed != resumed.remainingSeconds.map({ max(1, Int(ceil($0 / 60))) }) {
                resumed.remainingSeconds = nil
            }
            model.pendingResume = resumed
        } else { model.pendingResume = nil }
    }

    @Published var modificationOrder = QuickSelectionOptionsSection.ordered
    @Published var websiteTransfer: (id: UUID, label: String)?
    private var websiteTransferStartedAt: TimeInterval?
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
    @Published var frontWindowByApp: [String: UInt32] = [:]
    @Published var expandedStack: String?
    @Published private(set) var resolvingBrowserWindow = false
    private var windowResolutionTask: Task<Void, Never>?
    private var browserReloadTask: Task<Void, Never>?
    private var windowResolutionID = UUID()
    private var confirmedBrowserWindows: [CGWindowID: (session: String, browser: String, id: Int)] = [:]
    @Published var hoveredTab: BrowserTabItem?
    @Published var tabPreview: NSImage?
    @Published var tabPreviewError: String?
    @Published var tabPreviewLoading = false
    @Published private(set) var websiteFinder: WebsiteFinderController?
    var onNativeFinderInputChanged: ((Bool) -> Void)?
    @Published private(set) var nativeWebsiteFinder: NativeWebsiteFinderController? {
        didSet { onNativeFinderInputChanged?(nativeWebsiteFinder != nil) }
    }
    var nativeFinderOwnsInput: Bool { nativeWebsiteFinder != nil }
    @Published private(set) var creatingWebsiteTab = false
    private var websiteCreationTask: Task<Void, Never>?
    private var websiteCreationID = UUID()
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
    private func launchSavedBrowsersOnRun(_ workspace: SessionWorkspace, mode: IntentionAccessMode,
                                         isCurrent: @escaping @MainActor () -> Bool) async throws -> Set<String> {
        let defaults = Set((model.alwaysAllowedApps + model.alwaysBlockedApps).map(\.bundleIdentifier))
        let installed = Set(model.installedApps.map(\.bundleIdentifier)).subtracting(defaults)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let needed = workspace.browsersToLaunchOnRun(runningApps: running, installedApps: installed, accessMode: mode)
        let launchRequestedAt = Date()
        for browser in needed.sorted() {
            guard isCurrent(), !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
            guard !browserLaunchesInFlight.contains(browser),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else { throw BrowserTabCreationError.changed }
            // Opening the application carries no URL or profile argument. This
            // cannot send a saved website into a guessed/default account.
            browserLaunchesInFlight.insert(browser)
            defer { browserLaunchesInFlight.remove(browser) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.hides = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if application != nil { continuation.resume() }
                    else { continuation.resume(throwing: BrowserTabCreationError.unavailable) }
                }
            }
            guard isCurrent(), !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
        }
        // New browser processes need a bounded chance to start their native
        // host. Presence is not identity proof: the correlated query follows.
        if !needed.isEmpty {
            for _ in 0..<100 {
                guard isCurrent(), !Task.isCancelled else { throw BrowserTabCreationError.cancelled }
                if needed.allSatisfy({ browser in
                    let profiles = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: browser))
                    return !profiles.isEmpty && profiles.allSatisfy { $0.updatedAt >= launchRequestedAt }
                }) { return needed }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BrowserTabCreationError.rejected("The browser opened, but Browser Guard has not connected. Enable Browser Guard in the saved browser profile, then run this intention again.")
        }
        return needed
    }
    private func freshRestorationProfiles(for browsers: Set<String>) async throws -> [BrowserTabSnapshot] {
        guard !browsers.isEmpty else { return [] }
        guard !profileDiscoveryInFlight else { throw BrowserTabCreationError.changed }
        profileDiscoveryInFlight = true
        defer { profileDiscoveryInFlight = false }
        struct Query {
            let owner: BrowserTabSnapshot
            let command: BrowserTabCommand
            let base: URL
        }
        let requestedAt = Date()
        var queries: [Query] = []
        for browser in browsers.sorted() {
            let base = BrowserTabSnapshotStore.fileURL(for: browser)
            let owners = BrowserProfileSnapshots.sessions(base: base)
            guard !owners.isEmpty else {
                throw BrowserTabCreationError.rejected("Open the saved browser profile with Browser Guard connected, then choose this intention again.")
            }
            for owner in owners {
                guard let session = owner.browserSessionID else { throw BrowserTabCreationError.changed }
                let command = BrowserTabCommand(tabID: -1, windowID: -1, action: .snapshot, browserSessionID: session)
                let path = BrowserProfileSnapshots.partition(BrowserTabCommandStore.fileURL(for: browser), session: session)
                try JSONEncoder().encode(command).write(to: path, options: .atomic)
                queries.append(.init(owner: owner, command: command, base: base))
            }
        }
        for _ in 0..<55 {
            try Task.checkCancellation()
            var replies: [BrowserTabSnapshot] = []
            for query in queries {
                let session = query.owner.browserSessionID!
                guard let data = try? Data(contentsOf: BrowserProfileSnapshots.discoveryPartition(query.base, session: session)),
                      let reply = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
                      BrowserProfileSnapshots.isDiscoveryReply(reply, owner: query.owner,
                          requestID: query.command.id, requestedAt: requestedAt) else { continue }
                replies.append(reply)
            }
            if replies.count == queries.count {
                // A profile joining/leaving changes merged public IDs. Never
                // reinterpret a frozen preparation under a different profile set.
                for browser in browsers {
                    let live = BrowserProfileSnapshots.sessions(base: BrowserTabSnapshotStore.fileURL(for: browser))
                    let expected = replies.filter { $0.browserBundleIdentifier == browser }
                    guard live.count == expected.count,
                          BrowserProfileSnapshots.nonce(live) == BrowserProfileSnapshots.nonce(expected),
                          expected.allSatisfy({ reply in live.contains { $0.browserSessionID == reply.browserSessionID
                              && $0.browserProfileID == reply.browserProfileID } }) else { throw BrowserTabCreationError.changed }
                }
                return replies
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BrowserTabCreationError.rejected("Browser Guard did not confirm every profile’s tab list. Keep the saved browser profile open and try this intention again.")
    }
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
    func openModification(_ index: Int) {
        hoverModification(nil)
        guard !model.hasActiveSession, NSApp.modalWindow == nil, modificationOrder.indices.contains(index) else { return }
        if !hasStagedSelection && panel?.isVisible != true { resetSelectionKeepingName() }
        openModification(modificationOrder[index])
    }
    func openModification(_ section: QuickSelectionOptionsSection) {
        guard !model.hasActiveSession, NSApp.modalWindow == nil else { return }
        if section == .checklist { editModification(section); return }
        closeModification()
        if section.enabled(in: selection) {
            section.disable(in: &selection)
            combinationNotice = false
            refreshStagedOutlines()
            if panel?.isVisible != true { showStagedModifiers() }
            return
        }
        enableModification(section, showEditor: false)
    }
    func editModification(_ section: QuickSelectionOptionsSection) {
        guard !model.hasActiveSession, NSApp.modalWindow == nil else { return }
        if optionsSection != section { closeModification() }
        enableModification(section, showEditor: true)
    }
    private func enableModification(_ section: QuickSelectionOptionsSection, showEditor: Bool) {
        let openingGeneration = generation
        hasStagedSelection = true
        if section == .timer || section == .checklist {
            offerExitPasscode()
            // The first-use prompt runs a nested event loop. Escape/clear can
            // close the selection while it is open; never resurrect that draft.
            guard generation == openingGeneration, hasStagedSelection,
                  !closing, !model.hasActiveSession else { return }
        }
        hoverModification(nil)
        section.enable(in: &selection)
        optionsSection = showEditor ? section : nil
        if panel?.isVisible != true {
            showStagedModifiers()
            refreshStagedOutlines()
            // A key nonactivating panel can edit without taking application
            // activation away from the exact desktop window being marked.
            if showEditor { stagedModifiersPanel?.makeKeyAndOrderFront(nil) }
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
        let width = min(1050, screen.visibleFrame.width - 56)
        let notice = Self.makeStagedModifierPanel(frame: CGRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 18, width: width, height: 70))
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hidesOnDeactivate = false
        notice.level = .floating; notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notice.contentView = NSHostingView(rootView: ModificationStrip(controller: self).padding(4).preferredColorScheme(.dark))
        stagedModifiersPanel = notice; notice.orderFrontRegardless()
    }
    func closeModification() {
        let section = optionsSection
        // Clear ownership before resigning first responder: AppKit may deliver
        // the popover-dismiss callback synchronously during that transition.
        optionsSection = nil
        if let section {
            if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, keyWindow.isKeyWindow {
                keyWindow.makeFirstResponder(nil)
            }
            section.dismissEditor(in: &selection)
        }
        if panel?.isVisible != true {
            // A popover may dismiss after overview has closed. Never recreate
            // its strip here: only a new quick mark or shortcut can show it.
            if selection.apps.isEmpty { hideStagedModifiers() }
            // Editing never activates Intent, so dismissal must not activate
            // an app or choose a sibling window as an attempted focus return.
        }
        refreshStagedOutlines()
    }
    private func hideStagedModifiers() {
        hoverModification(nil)
        let section = optionsSection
        optionsSection = nil
        section?.dismissEditor(in: &selection)
        let previousPanel = stagedModifiersPanel
        stagedModifiersPanel = nil
        previousPanel?.orderOut(nil)
    }
    private var modifierHintTask: Task<Void, Never>?
    private var modifierHintPanel: NSPanel?
    func hoverModification(_ section: QuickSelectionOptionsSection?) {
        modifierHintTask?.cancel(); modifierHintTask = nil
        modifierHintPanel?.orderOut(nil); modifierHintPanel = nil
        guard let section, optionsSection == nil, !closing else { return }
        modifierHintTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, !self.closing, self.optionsSection == nil,
                  self.panel?.isVisible == true || self.stagedModifiersPanel?.isVisible == true,
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
            let mouse = NSEvent.mouseLocation
            let tip = NSPanel(contentRect: CGRect(x: min(max(screen.visibleFrame.minX + 8, mouse.x - 120), screen.visibleFrame.maxX - 248), y: min(mouse.y + 24, screen.visibleFrame.maxY - 82), width: 240, height: 74), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            tip.isOpaque = false; tip.backgroundColor = .clear; tip.hasShadow = true
            tip.ignoresMouseEvents = true; tip.level = .popUpMenu
            tip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            tip.contentView = NSHostingView(rootView: Text(section.hint).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(12).frame(width: 240, height: 74).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).preferredColorScheme(.dark))
            self.modifierHintPanel = tip; tip.orderFrontRegardless()
        }
    }
    private func refreshStagedOutlines() {
        guard hasStagedSelection, !selection.apps.isEmpty,
              !model.hasActiveSession, panel?.isVisible != true else {
            workspaceOutlines.stop()
            return
        }
        workspaceOutlines.update(selection, preserveBehindIntentPanels: optionsSection != nil)
    }
    func markForeground(wholeWindow: Bool = false, fromShortcut: Bool = false) {
        guard !model.hasActiveSession, panel?.isVisible != true else { return }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { toggle(); return }
        guard let window = WorkspaceWindow.focused(), window.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if onboarding.isTeaching, !onboarding.purposeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.name = onboarding.purposeName
        }
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
                if !self.hasStagedSelection { self.resetSelectionKeepingName() }
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
                if !self.hasStagedSelection { self.resetSelectionKeepingName() }
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
        guard runMarkedTask == nil, !model.hasActiveSession, openingApps.isEmpty,
              hasStagedSelection || markTask != nil else { return }
        closeModification()
        guard let origin = WorkspaceWindow.focused(), origin.pid != ProcessInfo.processInfo.processIdentifier else { return }
        let originalSnapshot = QuickSelection.browsers.contains(origin.bundle)
            ? BrowserTabSnapshotStore(browserBundleIdentifier: origin.bundle).load(maxAge: 5) : nil
        guard let startAnchor = Self.markedRunAnchor(windowID: origin.id, pid: origin.pid,
            bundle: origin.bundle, title: origin.title, frame: origin.frame,
            nativeWindowCount: WorkspaceWindow.list().filter { $0.bundle == origin.bundle }.count,
            snapshot: originalSnapshot) else {
            showMarkRecovery(for: origin.bundle, fresh: false,
                detail: "Wait for the current tab to finish marking, then run again. Your selections are safe.", offersBrowserSetup: false)
            return
        }
        runMarkedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.runMarkedTask = nil }
            await self.markTask?.value
            guard !self.model.hasActiveSession, self.openingApps.isEmpty, self.hasStagedSelection, !self.selection.apps.isEmpty else { return }
            self.refresh()
            var browsers = Set(self.selection.tabs.map(\.browser))
            if startAnchor.browserTabID != nil { browsers.insert(startAnchor.bundleIdentifier) }
            let fresh = await self.freshSnapshots(for: browsers)
            guard !Task.isCancelled, !self.model.hasActiveSession, self.panel?.isVisible != true else { return }
            guard fresh else {
                self.showMarkRecovery(for: origin.bundle, fresh: false,
                    detail: "Couldn't refresh the marked tabs. Check Browser Guard and try again.", offersBrowserSetup: QuickSelection.browsers.contains(origin.bundle))
                return
            }
            guard self.panel?.isVisible != true else { return }
            let currentOrigin = WorkspaceWindow.focused()
            guard startAnchor.matchesNative(windowID: currentOrigin?.id, pid: currentOrigin?.pid,
                bundleIdentifier: currentOrigin?.bundle),
                startAnchor.matchesBrowserSnapshot(self.snapshots.first { $0.browserBundleIdentifier == startAnchor.bundleIdentifier }) else {
                self.showMarkRecovery(for: origin.bundle, fresh: true,
                    detail: "Your active window or tab changed while preparing. Run again from the one you want.", offersBrowserSetup: false)
                return
            }
            let current = Set(WorkspaceWindow.list(onScreen: false).map(\.id))
            guard self.selection.windowIDsByApp.values.allSatisfy({ $0.isSubset(of: current) }) else {
                self.showMarkRecovery(for: origin.bundle, fresh: true,
                    detail: "A marked window closed. Open ` and review your selection.", offersBrowserSetup: false)
                return
            }
            self.prepareRunMetadata()
            if self.model.startQuickSelection(Self.markedRunSelection(self.selection), apps: self.apps.map(\.app), snapshots: self.snapshots,
                onboardingOrigin: .quickMark, startAnchor: startAnchor) {
                self.workspaceOutlines.stop(); self.hideStagedModifiers()
                // Keep the draft until FocusLock confirms readiness.
            } else {
                self.showMarkRecovery(for: origin.bundle, fresh: true,
                    detail: self.model.errorMessage ?? "The intention couldn't start. Your selections are safe.", offersBrowserSetup: false)
            }
        }
    }
    static func markedRunSelection(_ selection: QuickSelection) -> QuickSelection {
        // DBT uses the already-open workspace, even after visiting overview or
        // loading a saved draft. Do not change that draft's later launch policy.
        var currentSession = selection
        currentSession.startupAppIDs = []
        return currentSession
    }
    static func markedRunAnchor(windowID: UInt32, pid: Int32, bundle: String, title: String,
                                frame: CGRect, nativeWindowCount: Int, snapshot: BrowserTabSnapshot?) -> FocusStartAnchor? {
        guard QuickSelection.browsers.contains(bundle) else {
            return .init(nativeWindowID: windowID, pid: pid, bundleIdentifier: bundle)
        }
        guard let snapshot, snapshot.browserBundleIdentifier == bundle,
              let session = snapshot.browserSessionID, !session.isEmpty,
              let browserWindow = BrowserWindowMatching.match(title: title, tabs: snapshot.allTabs ?? snapshot.tabs,
                nativeWindowCount: nativeWindowCount, frame: frame, isFocused: true) else { return nil }
        let active = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == browserWindow && $0.active }
        guard active.count == 1, let tab = active.first else { return nil }
        return .init(nativeWindowID: windowID, pid: pid, bundleIdentifier: bundle,
            browserWindowID: browserWindow, browserTabID: tab.id, browserSessionID: session)
    }
    static func makeStagedModifierPanel(frame: CGRect) -> NSPanel {
        StagedModifierPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    private var markNoticePanel: NSPanel?
    private var markNoticeDismissal: DispatchWorkItem?
    private func dismissMarkNotice() {
        markNoticeDismissal?.cancel(); markNoticeDismissal = nil
        markNoticePanel?.orderOut(nil); markNoticePanel = nil
    }
    private func showMarkRecovery(for browser: String, fresh: Bool, needsGroupUpdate: Bool = false, detail: String? = nil, offersBrowserSetup: Bool = true) {
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
        case .reconnecting:
            text = IntentEnvironment.isQA
                ? "Intent QA needs its separate test browser connection. Your regular \(name) extension connects to the normal Intent app."
                : "Reconnecting to \(name). Your selections are safe."
        case .ready: text = fresh ? "Couldn’t identify this browser window. Open Intent’s overview to select its tabs, or check Browser Guard in this browser profile." : "\(name) is taking longer to respond. Try marking again."
        } }
        dismissMarkNotice()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = CGRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 24, width: 420, height: 120)
        let notice = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.isOpaque = false; notice.backgroundColor = .clear; notice.hasShadow = true; notice.hidesOnDeactivate = false
        notice.level = .floating; notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        notice.contentView = NSHostingView(rootView: QuickMarkRecoveryNotice(text: text, needsSetup: offersBrowserSetup && (needsGroupUpdate || connection != .ready), setup: { [weak self] in
            self?.dismissMarkNotice(); IntentBrowserSetup.open(browser)
        }, overview: { [weak self] in self?.dismissMarkNotice(); self?.toggle() }, close: { [weak self] in self?.dismissMarkNotice() }))
        markNoticePanel = notice; notice.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissMarkNotice() }
        markNoticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }
    func clearMarks() {
        guard !model.hasActiveSession else { return }
        preparedSavedWorkspace = nil; preparedSavedIntention = nil; pendingSavedTabs = []; restoredRunWorkspace = nil
        dismissMarkNotice()
        hideStagedModifiers()
        markGeneration = UUID()
        markTask?.cancel(); markTask = nil
        runMarkedTask?.cancel()
        SpotlightAppPreparation.shared.release(); openingApps = []; spotlightApps = [:]
        selection = QuickSelection()
        resumeRecord = nil; preparedOverviewPending = false
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
    private let offerExitPasscode: @MainActor () -> Void
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var previewCache: [CGWindowID: WindowItem] = [:]
    private var previewRetry = 0
    private var previewTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var generation = UUID()

    init(model: IntentAppModel, offerExitPasscode: @escaping @MainActor () -> Void = { IntentExitPasscode.offerOnce() }) {
        self.model = model
        self.offerExitPasscode = offerExitPasscode
        model.quickSelectionDidStart = { [weak self] in
            guard let self else { return }
            self.workspaceOutlines.stop(); self.hideStagedModifiers()
            SpotlightAppPreparation.shared.didStart(); self.spotlightApps = [:]; self.openingApps = []
            self.hasStagedSelection = false
            self.selection = QuickSelection(); self.resumeRecord = nil; self.preparedOverviewPending = false
        }
        model.restoreInterruptedWorkspace = { [weak self] intention, workspace in
            self?.prepare(intention, workspace: workspace)
            self?.message = "Restrictions were released. Your draft is here; review it before starting again."
        }
        model.presentWorkspace = { [weak self] in
            guard let self else { return false }
            if self.panel?.isVisible != true { self.toggle() }
            return self.panel?.isVisible == true
        }
    }
    var windowlessApps: [AppItem] {
        guard hasPreviewPermission, !loading else { return [] }
        return apps.filter { app in !windows.contains { $0.appID == app.id } }
    }
    var isSelectionSurfaceVisible: Bool { panel?.isVisible == true }
    var isStagedModifierSurfaceVisible: Bool { stagedModifiersPanel?.isVisible == true }
    func prepareOverviewEntry() {
        // An explicit saved/resume action loads its own configuration. A normal
        // SBT entry is a fresh mode, not a continuation of DBT marks or editors.
        if preparedOverviewPending { preparedOverviewPending = false; return }
        clearMarks()
    }
    func toggle() {
        model.cancelBrowserCoverageStart()
        if panel?.isVisible == true { cancel(); return }
        guard !model.hasActiveSession,
              model.pendingFriction == nil,
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
        prepareOverviewEntry()
        if onboarding.isTeaching, !onboarding.purposeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selection.name = onboarding.purposeName }
        model.pendingPurposeSessionSave = nil
        workspaceOutlines.stop()
        hideStagedModifiers()
        optionsSection = nil; message = nil; expanded = false; closing = false; windows = []; focusedBrowserWindow = nil
        previousApp = NSWorkspace.shared.frontmostApplication
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.panel?.isVisible == true, !self.nativeFinderOwnsInput else { return event }
            if let cgEvent = event.cgEvent,
               let input = self.overviewNormalizer.normalize(type: cgEvent.type, event: cgEvent),
               self.handleOverviewKey(code: input.code, down: input.down, modified: input.modified,
                   repeatKey: input.repeatKey, capsLockHeld: input.capsLockHeld) { return nil }
            guard event.type == .keyDown else { return event }
            if event.keyCode == 53 { self.cancelImmediately(); return nil }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                // Spotlight's panel must be able to appear above the overview.
                self.panel?.level = .normal
                return event
            }
            if self.settingsOpen { return event }
            // Phrase/checklist editing must not switch Allow/Block when typing '/'.
            if self.isEditingText { return event }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if !event.isARepeat { self.toggleSlots() }; return nil
            }
            if event.keyCode == 7, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, self.focusedBrowserWindow != nil {
                if !event.isARepeat { self.toggleAllFocusedTabs() }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { self.runSelection(); return nil }
            if (event.keyCode == 11 || event.charactersIgnoringModifiers == "/"), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
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
        panel?.makeFirstResponder(nil)
        if preparedSavedWorkspace != nil {
            selection.accessMode = selection.accessMode == .whitelist ? .blacklist : .whitelist
            return
        }
        selection.accessMode = selection.accessMode == .whitelist ? .blacklist : .whitelist
        // A whole-browser block has no tab selection; do not silently turn that
        // into an allow-all browser when returning to Allow mode.
        if selection.accessMode == .whitelist {
            for browser in QuickSelection.browsers where !(selection.wholeBrowserApps ?? []).contains(browser) && !selection.tabs.contains(where: { $0.browser == browser }) { selection.apps.remove(browser) }
            selection.startupAppIDs = (selection.startupAppIDs ?? []).union(Set(spotlightApps.keys).intersection(selection.apps))
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
        for (id, app) in spotlightApps where selection.apps.contains(id) && !apps.contains(where: { $0.id == id }) {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            apps.append(.init(app: app, icon: icon ?? NSImage(named: NSImage.applicationIconName)!, pid: 0))
        }
        snapshots = QuickSelection.browsers.sorted().compactMap { browser in
            guard apps.contains(where: { $0.id == browser }),
                  BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).supports(.quickSelection, maxAge: 5) else { return nil }
            if !profileDiscoveryInFlight {
                try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
            }
            return BrowserTabSnapshotStore(browserBundleIdentifier: browser).load()
        }
    }
    func reloadBrowserTabs(_ browser: String) {
        browserReloadTask?.cancel()
        let focused = focusedBrowserWindow
        browserReloadTask = Task { [weak self] in
            guard let self, !Task.isCancelled, let focused,
                  self.focusedBrowserWindow == focused else { return }
            _ = await self.freshSnapshots(for: [browser])
        }
    }
    // Equal titles and geometry cannot identify a native window. Ask each
    // browser window to focus its existing active tab, then confirm both
    // native and extension focus before retaining the session-local pairing.
    private func resolveBrowserWindow(_ window: WindowItem) {
        windowResolutionTask?.cancel()
        let resolutionID = UUID()
        windowResolutionID = resolutionID
        let token = generation
        windowResolutionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.windowResolutionID == resolutionID,
                  self.focusedBrowserWindow == window.id else { return }
            self.resolvingBrowserWindow = true
            defer {
                if self.generation == token, self.windowResolutionID == resolutionID {
                    self.resolvingBrowserWindow = false
                    let foreground = NSWorkspace.shared.frontmostApplication
                    let stillInPicker = foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                        || foreground?.bundleIdentifier == window.appID
                    if !self.closing, self.panel?.isVisible == true, stillInPicker {
                        NSApp.activate(ignoringOtherApps: true)
                        self.panel?.makeKeyAndOrderFront(nil)
                    }
                }
            }
            guard await self.freshSnapshots(for: [window.appID]), !Task.isCancelled,
                  self.generation == token, self.browserWindowID(for: window) == nil,
                  let snapshot = self.snapshots.first(where: { $0.browserBundleIdentifier == window.appID }),
                  let session = snapshot.browserSessionID else { return }
            let activeTabs = (snapshot.allTabs ?? snapshot.tabs).filter(\.active)
            let titled = activeTabs.filter { BrowserWindowMatching.sameWindowTitle(window.title, $0.title) }
            let titledWindows = Set(titled.map(\.windowID))
            // Preview titles can age while a page loads. Prioritize likely
            // matches without excluding a target whose current title changed.
            let candidates = titled + activeTabs.filter { !titledWindows.contains($0.windowID) }
            // Firefox's windows.update(focused:) can reorder its windows without
            // activating its macOS application. The confirmation below requires
            // actual native/browser focus, so explicitly activate the existing
            // process behind our floating overview before asking it to focus.
            // Never launch a browser merely to resolve a preview.
            let foreground = NSWorkspace.shared.frontmostApplication
            guard !Task.isCancelled, self.windowResolutionID == resolutionID,
                  !self.closing, self.panel?.isVisible == true, self.focusedBrowserWindow == window.id,
                  foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    || foreground?.bundleIdentifier == window.appID else { return }
            guard let nativeWindow = WorkspaceWindow.list(onScreen: false).first(where: { $0.id == window.id && $0.bundle == window.appID }),
                  let browser = NSRunningApplication(processIdentifier: nativeWindow.pid),
                  !browser.isTerminated else { return }
            browser.activate(options: [])
            for tab in candidates {
                guard !Task.isCancelled, self.generation == token, !self.closing,
                      self.focusedBrowserWindow == window.id else { return }
                let requestedAt = Date()
                try? BrowserTabCommandStore(browserBundleIdentifier: window.appID).write(
                    .init(tabID: tab.id, windowID: tab.windowID, browserSessionID: session))
                // Do not confuse a fresh snapshot taken before activation with
                // an acknowledgement that this particular window was focused.
                for _ in 0..<20 {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard self.generation == token, !self.closing,
                          let current = BrowserTabSnapshotStore(browserBundleIdentifier: window.appID).load(),
                          current.browserSessionID == session, current.updatedAt >= requestedAt,
                          let native = WorkspaceWindow.focused(), native.bundle == window.appID,
                          (current.allTabs ?? current.tabs).contains(where: {
                              $0.windowID == tab.windowID && $0.active && $0.windowFocused == true
                          }) else { continue }
                    guard BrowserWindowMatching.match(title: native.title, tabs: current.allTabs ?? current.tabs,
                        nativeWindowCount: candidates.count, frame: native.frame, isFocused: true) == tab.windowID else { continue }
                    self.confirmedBrowserWindows[native.id] = (session, window.appID, tab.windowID)
                    self.snapshots.removeAll { $0.browserBundleIdentifier == window.appID }
                    self.snapshots.append(current)
                    break
                }
                if self.browserWindowID(for: window) != nil { return }
            }
        }
    }
    func browserWindowID(for window: WindowItem) -> Int? {
        guard let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == window.appID }) else { return nil }
        if let confirmed = confirmedBrowserWindows[window.id], confirmed.browser == window.appID,
           confirmed.session == snapshot.browserSessionID,
           (snapshot.allTabs ?? snapshot.tabs).contains(where: { $0.windowID == confirmed.id }) { return confirmed.id }
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
        // The window is the location of the selected tabs, not an assertion
        // that every tab is allowed. A partial selection still marks its owner.
        return selectable.contains { isTabSelected($0.id, browser: window.appID) }
    }
    func selectWindow(_ window: WindowItem) {
        guard !closing else { return }
        panel?.makeFirstResponder(nil)
        // Picker visibility follows the most recent explicit target click,
        // independently of the browser tabs already selected for the draft.
        dismissBrowserPicker()
        if let app = apps.first(where: { $0.id == window.appID }), window.id == Self.placeholderID(app),
           spotlightApps[window.appID] != nil && selection.apps.contains(window.appID) {
            selection.toggleApp(window.appID, snapshots: snapshots); return
        }
        if let app = apps.first(where: { $0.id == window.appID }), window.id == Self.placeholderID(app),
           !QuickSelection.browsers.contains(window.appID) {
            message = "No selectable window is available for this app. Open its window, then reopen the overview."
            return
        }
        frontWindowByApp[window.appID] = window.id
        if QuickSelection.browsers.contains(window.appID) {
            expandedStack = nil
            guard !browserLists(for: window.appID).isEmpty else {
                focusedBrowserWindow = window.id
                reloadBrowserTabs(window.appID)
                message = unavailableTabsMessage(for: window.appID); return
            }
            explicitBrowserWindow = nil
            focusedBrowserWindow = window.id
            hoveredTab = nil; tabPreview = nil; tabPreviewError = nil
            resolveBrowserWindow(window)
            message = nil
        } else { selection.toggleWindow(window.id, app: window.appID) }
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
        panel?.makeFirstResponder(nil)
        message = nil
        guard ensureSelectionSession(browser) else { return }
        guard let window = windows.first(where: { $0.id == focusedBrowserWindow }), window.appID == browser else { return }
        selection.selectTab(.init(browser: browser, id: tab.id), windowID: tab.windowID,
                            displayedTabs: tabs(for: window), extendingRange: extendingRange)
        if hasStagedSelection { refreshStagedOutlines() }
    }
    func toggleAllFocusedTabs() {
        panel?.makeFirstResponder(nil)
        guard let window = windows.first(where: { $0.id == focusedBrowserWindow }),
              let id = displayedBrowserWindowID(for: window) else { return }
        guard ensureSelectionSession(window.appID) else { return }
        selection.toggleBrowserWindow(browser: window.appID, windowID: id, snapshots: snapshots)
    }
    func selectApp(_ app: AppItem) {
        panel?.makeFirstResponder(nil)
        dismissBrowserPicker()
        if app.app.isBrowser && selection.accessMode == .whitelist {
            message = "Select website tabs above a Chrome or Firefox window."; return
        }
        if selection.apps.contains(app.id) {
            preparedSavedWorkspace?.removeResources(for: app.id)
            pendingSavedTabs.removeAll { $0.descriptor.browser == app.id }
        }
        message = nil; selection.toggleApp(app.id, snapshots: snapshots)
    }
    func dismissBrowserPicker() {
        closeWebsiteFinder()
        browserReloadTask?.cancel(); browserReloadTask = nil
        windowResolutionID = UUID()
        windowResolutionTask?.cancel(); windowResolutionTask = nil
        resolvingBrowserWindow = false
        hoverTask?.cancel(); hoverTask = nil
        focusedBrowserWindow = nil; explicitBrowserWindow = nil
        hoveredTab = nil; tabPreview = nil; tabPreviewError = nil; tabPreviewLoading = false
    }
    var currentWebsiteFinderTarget: WebsiteFinderTarget? {
        guard !model.hasActiveSession, !closing, panel?.isVisible == true,
              let window = windows.first(where: { $0.id == focusedBrowserWindow }),
              let windowID = displayedBrowserWindowID(for: window),
              let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == window.appID }),
              let session = snapshot.browserSessionID else { return nil }
        let tabs = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == windowID }
        let previousAnchor = nativeWebsiteFinder?.target.anchorTabID ?? websiteFinder?.target.anchorTabID
        guard let anchor = tabs.first(where: { $0.id == previousAnchor }) ?? tabs.first(where: \.active) ?? tabs.first else { return nil }
        let target = WebsiteFinderTarget(browserBundleIdentifier: window.appID, browserSessionID: session,
            browserWindowID: windowID, anchorTabID: anchor.id, overviewGeneration: generation)
        return target.isValid ? target : nil
    }
    func openWebsiteFinder() {
        guard nativeWebsiteFinder == nil, websiteFinder == nil, !creatingWebsiteTab, !restoringSavedWorkspace,
              let target = currentWebsiteFinderTarget else { return }
        windowResolutionID = UUID(); windowResolutionTask?.cancel(); windowResolutionTask = nil
        resolvingBrowserWindow = false; closeModification()
        hoverTask?.cancel(); hoverTask = nil; tabPreviewLoading = false
        overviewInput = OverviewSearchGesture(); overviewNormalizer = QuickMarkKeyboardNormalizer()
        do {
            let finder = try NativeWebsiteFinderController(target: target, onCommit: { [weak self] target, tab in
                self?.completeNativeWebsiteFinder(target: target, tab: tab)
            }, onCancel: { [weak self] in self?.closeWebsiteFinder() }, onTransfer: { [weak self] url in
                guard let self, self.generation == target.overviewGeneration, !self.closing else { return }
                self.websiteTransfer = (UUID(), url ?? "Website")
                self.websiteTransferStartedAt = ProcessInfo.processInfo.systemUptime
                self.panel?.level = .popUpMenu
                self.panel?.orderFrontRegardless()
            }, onTransferFailed: { [weak self] in
                self?.websiteTransfer = nil
                self?.panel?.level = .normal
            })
            nativeWebsiteFinder = finder; message = nil
            // The user's real browser must own address-bar typing and Return.
            // Preserve the entire overview draft behind it, without raising it.
            panel?.makeFirstResponder(nil); panel?.level = .normal; panel?.ignoresMouseEvents = true
            let width = min(760, max(480, displayFrame.width - 80))
            let height = min(560, max(360, displayFrame.height - 200))
            finder.start(frame: .init(left: displayFrame.midX - width / 2,
                top: displayFrame.midY - height / 2 - 30, width: width, height: height))
        } catch { message = error.localizedDescription }
    }
    private func completeNativeWebsiteFinder(target: WebsiteFinderTarget, tab: BrowserTabItem) {
        guard nativeWebsiteFinder?.target == target, generation == target.overviewGeneration else {
            return
        }
        creatingWebsiteTab = true
        let requestID = UUID(); websiteCreationID = requestID
        websiteCreationTask = Task { [weak self] in
            guard let self else { return }
            let refreshed = await self.freshSnapshots(for: [target.browserBundleIdentifier])
            if let started = self.websiteTransferStartedAt {
                let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.6
                let remaining = duration - (ProcessInfo.processInfo.systemUptime - started)
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            BrowserFinderCompletion.performIfCurrent(requestID: requestID, currentRequestID: self.websiteCreationID,
                target: target, currentTarget: self.nativeWebsiteFinder?.target,
                cancelled: Task.isCancelled || self.generation != target.overviewGeneration) {
                guard refreshed, self.currentWebsiteFinderTarget == target,
                      let snapshot = self.snapshots.first(where: { $0.browserBundleIdentifier == target.browserBundleIdentifier }),
                      snapshot.browserSessionID == target.browserSessionID,
                      let created = (snapshot.allTabs ?? snapshot.tabs).first(where: { $0.id == tab.id && $0.windowID == target.browserWindowID }) else {
                    self.message = "The page was added to your browser. Refresh its tabs to select it."; self.closeWebsiteFinder(); return
                }
                if !self.isTabSelected(created.id, browser: target.browserBundleIdentifier) {
                    self.selectTab(created, browser: target.browserBundleIdentifier, extendingRange: false)
                }
                self.closeWebsiteFinder()
            }
        }
    }
    func closeWebsiteFinder() {
        websiteTransfer = nil
        websiteTransferStartedAt = nil
        let hadNativeFinder = nativeWebsiteFinder != nil
        nativeWebsiteFinder?.dismiss(); nativeWebsiteFinder = nil
        if hadNativeFinder { panel?.ignoresMouseEvents = false }
        if hadNativeFinder, panel?.isVisible == true, !closing {
            panel?.level = .popUpMenu
            NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        }
        websiteCreationID = UUID()
        websiteCreationTask?.cancel(); websiteCreationTask = nil
        creatingWebsiteTab = false
        websiteFinder?.cancel(); websiteFinder = nil
    }
    private func createWebsiteTab(target: WebsiteFinderTarget, url: URL) {
        guard !creatingWebsiteTab, currentWebsiteFinderTarget == target else { return }
        creatingWebsiteTab = true
        let requestID = UUID(); websiteCreationID = requestID
        websiteCreationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.websiteCreationID == requestID {
                    self.creatingWebsiteTab = false; self.websiteCreationTask = nil
                }
            }
            do {
                let tab = try await BrowserTabCreationService.create(target: target, url: url, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.websiteCreationID == requestID && self.currentWebsiteFinderTarget == target
                })
                guard !Task.isCancelled, self.websiteCreationID == requestID,
                      self.currentWebsiteFinderTarget == target else { return }
                guard await self.freshSnapshots(for: [target.browserBundleIdentifier]),
                      !Task.isCancelled, self.websiteCreationID == requestID,
                      self.currentWebsiteFinderTarget == target,
                      let snapshot = self.snapshots.first(where: { $0.browserBundleIdentifier == target.browserBundleIdentifier }),
                      snapshot.browserSessionID == target.browserSessionID,
                      let created = (snapshot.allTabs ?? snapshot.tabs).first(where: { $0.id == tab.id && $0.windowID == target.browserWindowID }) else {
                    self.message = "The background tab was created, but its fresh tab list is still unavailable. Refresh tabs to select it."
                    self.closeWebsiteFinder()
                    return
                }
                // Select only the receipt's real tab in the original profile.
                // Never retry creation, activate the browser, or substitute IDs.
                if !self.isTabSelected(created.id, browser: target.browserBundleIdentifier) {
                    self.selectTab(created, browser: target.browserBundleIdentifier, extendingRange: false)
                }
                self.closeWebsiteFinder()
            } catch {
                guard !Task.isCancelled, self.websiteCreationID == requestID,
                      self.currentWebsiteFinderTarget == target else { return }
                self.message = error.localizedDescription
                self.closeWebsiteFinder()
            }
        }
    }
    func runSelection() {
        guard !nativeFinderOwnsInput, !closing, !loading, !creatingWebsiteTab, !restoringSavedWorkspace, openingApps.isEmpty, hasRunnableDraft else { return }
        closeModification()
        if let workspace = preparedSavedWorkspace, let intention = preparedSavedIntention {
            runPreparedSavedWorkspace(workspace, intention: intention)
            return
        }
        refresh()
        for (key, policy) in selection.websiteFeaturePolicies ?? [:] {
            guard let site = FocusWebsite(rawValue: key), policy.isValid(for: site) else {
                message = "Choose at least one allowed area for each website."; return
            }
        }
        do { _ = try selection.makeIntention(apps: apps.map(\.app), snapshots: snapshots) }
        catch { message = error.localizedDescription; return }
        dismissForRun()
    }
    private func runPreparedSavedWorkspace(_ workspace: SessionWorkspace, intention: Intention) {
        guard savedRestorationTask == nil, !model.hasActiveSession else { return }
        let token = UUID(); savedRestorationGeneration = token
        let overview = generation
        let configuration = selection
        restoringSavedWorkspace = true
        message = "Preparing your saved workspace…"
        savedRestorationTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.savedRestorationGeneration == token && self.generation == overview
                    && !self.model.hasActiveSession && !self.closing && !self.nativeFinderOwnsInput && self.panel?.isVisible == true
            }
            defer {
                if self.savedRestorationGeneration == token {
                    self.restoringSavedWorkspace = false; self.savedRestorationTask = nil
                }
            }
            do {
                let defaults = Set((self.model.alwaysAllowedApps + self.model.alwaysBlockedApps).map(\.bundleIdentifier))
                let browsers = Set(workspace.tabs.map(\.browser)).subtracting(defaults)
                let launchedBrowsers = try await self.launchSavedBrowsersOnRun(workspace, mode: configuration.accessMode, isCurrent: isCurrent)
                let initialProfiles = try await self.freshRestorationProfiles(for: browsers)
                guard isCurrent() else { throw BrowserTabCreationError.cancelled }
                let resolved = self.savedResolution(workspace, intention: intention, profiles: initialProfiles, accessMode: configuration.accessMode)
                guard resolved.missing == 0 else {
                    self.message = resolved.problems.first ?? "A saved window is unavailable. Review the selected apps before running."
                    return
                }
                var draft = resolved.selection
                self.copySavedConfiguration(configuration, into: &draft)
                // These processes have already been started once without URLs.
                draft.startupAppIDs?.subtract(launchedBrowsers)
                // Claim every effect before the first create. Repeated Run, a
                // lost receipt, or an app restart cannot mint replacement IDs.
                let requests = try self.savedRestoreClaims.begin(sourceID: intention.id, tabs: resolved.pendingTabs)
                for (pending, request) in zip(resolved.pendingTabs, requests) {
                    guard isCurrent(), configuration.accessMode == .whitelist else { throw BrowserTabCreationError.cancelled }
                    let profiles = initialProfiles.filter { $0.browserBundleIdentifier == pending.descriptor.browser }
                    guard let nonce = BrowserProfileSnapshots.nonce(profiles),
                          profiles.contains(where: { $0.browserSessionID == pending.ownerSessionID
                              && (pending.descriptor.profileID == nil || $0.browserProfileID == pending.descriptor.profileID) }),
                          let url = WebsiteFinderPolicy.validatedURL(pending.descriptor.url) else { throw BrowserTabCreationError.changed }
                    let target = WebsiteFinderTarget(browserBundleIdentifier: pending.descriptor.browser, browserSessionID: nonce,
                        browserWindowID: profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: pending.ownerSessionID, id: pending.windowID) : pending.windowID,
                        anchorTabID: profiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: pending.ownerSessionID, id: pending.anchorTabID) : pending.anchorTabID,
                        overviewGeneration: token)
                    let tab = try await BrowserTabCreationService.create(target: target, url: url, requestID: request.requestID, isCurrent: isCurrent)
                    guard isCurrent(), draft.pinBrowserSession(pending.descriptor.browser, sessionID: nonce) else { throw BrowserTabCreationError.changed }
                    draft.toggleTab(.init(browser: pending.descriptor.browser, id: tab.id), browserSessionID: nonce)
                }
                let finalProfiles = try await self.freshRestorationProfiles(for: browsers)
                guard isCurrent() else { throw BrowserTabCreationError.cancelled }
                for browser in browsers {
                    let initial = initialProfiles.filter { $0.browserBundleIdentifier == browser }
                    let final = finalProfiles.filter { $0.browserBundleIdentifier == browser }
                    guard BrowserProfileSnapshots.nonce(initial) == BrowserProfileSnapshots.nonce(final),
                          initial.allSatisfy({ owner in final.contains { $0.browserSessionID == owner.browserSessionID
                              && $0.browserProfileID == owner.browserProfileID } }) else { throw BrowserTabCreationError.changed }
                }
                self.refresh()
                self.snapshots.removeAll { browsers.contains($0.browserBundleIdentifier) }
                self.snapshots.append(contentsOf: Dictionary(grouping: finalProfiles, by: \.browserBundleIdentifier).values.compactMap { BrowserProfileSnapshots.merged($0) })
                _ = try draft.makeIntention(apps: self.apps.map(\.app), snapshots: self.snapshots)
                // The receipt's IDs, not a possibly redirected URL/title, own
                // this run. Save refreshed replay bindings before retiring claims.
                self.applyingSavedWorkspace = true; self.selection = draft; self.applyingSavedWorkspace = false
                let captured = self.captureWorkspace(profiles: finalProfiles)
                guard captured.tabs.count == draft.tabs.count,
                      captured.windows.count == draft.windowIDsByApp.values.reduce(0, { $0 + $1.count }) else { throw BrowserTabCreationError.changed }
                let previous = self.model.journal.workspaces[intention.id]
                self.model.journal.workspaces[intention.id] = captured
                guard self.model.persistJournal() else {
                    self.model.journal.workspaces[intention.id] = previous
                    throw BrowserTabCreationError.rejected("Could not save the restored workspace. Its tabs are open; review them before retrying.")
                }
                try self.savedRestoreClaims.complete(sourceID: intention.id)
                self.restoredRunWorkspace = captured
                self.preparedSavedWorkspace = nil; self.preparedSavedIntention = nil; self.pendingSavedTabs = []
                self.restoringSavedWorkspace = false; self.savedRestorationTask = nil
                guard isCurrent() else { return }
                self.runSelection()
            } catch {
                guard self.savedRestorationGeneration == token, self.generation == overview else { return }
                self.message = error.localizedDescription
            }
        }
    }
    func cancel() { cancelImmediately() }
    private func dismissForRun() {
        closing = true
        let token = generation
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduced ? nil : .easeInOut(duration: 0.24)) { expanded = false }
        Task { [weak self] in
            if !reduced { try? await Task.sleep(nanoseconds: 240_000_000) }
            guard let self, self.generation == token else { return }
            self.refresh()
            self.prepareRunMetadata()
            guard self.model.startQuickSelection(self.selection, apps: self.apps.map(\.app), snapshots: self.snapshots, onboardingOrigin: .overview) else {
                self.message = self.model.errorMessage; self.closing = false
                withAnimation(.easeOut(duration: 0.2)) { self.expanded = true }; return
            }
            self.workspaceOutlines.stop()
            // Readiness, rather than accepting an asynchronous start, clears the draft.
            self.close()
            if self.model.pendingFriction != nil || self.model.pendingEndTimeRequest != nil { self.model.showOverlay() }
        }
    }
    private func close() {
        closing = true
        savedRestorationGeneration = UUID()
        savedRestorationTask?.cancel(); savedRestorationTask = nil; restoringSavedWorkspace = false
        onOverviewClosed?()
        savedRunTask?.cancel(); savedRunTask = nil
        settingsOpen = false; saveFlight = nil
        dismissBrowserPicker()
        overviewInput = OverviewSearchGesture()
        overviewNormalizer = QuickMarkKeyboardNormalizer()
        expandedStack = nil
        hideStagedModifiers()
        hoverModification(nil)
        optionsSection = nil
        hoverTask?.cancel(); hoverTask = nil; hoveredTab = nil; tabPreview = nil; tabPreviewLoading = false
        for browser in QuickSelection.browsers { try? FileManager.default.removeItem(at: BrowserTabPreview.fileURL(browser: browser)) }
        generation = UUID(); previewTask?.cancel(); previewTask = nil
        windowResolutionTask?.cancel(); windowResolutionTask = nil
        resolvingBrowserWindow = false; confirmedBrowserWindows = [:]
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
        guard websiteFinder == nil, nativeWebsiteFinder == nil else { return }
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
                let appByPID = Dictionary(uniqueKeysWithValues: self.apps.filter { $0.pid > 0 }.map { ($0.pid, $0.id) })
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
                // Install the complete geometry once. Captures replace only pixels,
                // never append/repack cards as individual windows finish loading.
                var items: [WindowItem] = candidates.compactMap { window in
                    guard let pid = window.owningApplication?.processID, let appID = appByPID[pid] else { return nil }
                    let cached = self.previewCache[window.windowID]
                    return WindowItem(id: window.windowID, appID: appID, title: window.title ?? "",
                        sourceFrame: window.frame, preview: cached?.title == (window.title ?? "") ? cached?.preview : nil)
                }
                for app in self.apps where !items.contains(where: { $0.appID == app.id }) {
                    items.append(.init(id: Self.placeholderID(app), appID: app.id, title: app.app.name,
                        sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil))
                }
                self.windows = self.preserveAddedAppIcons(in: items)
                self.expanded = true
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
                    guard !Task.isCancelled, self.generation == token, !self.closing else { return }
                    for captured in batch {
                        guard let index = items.firstIndex(where: { $0.id == captured.id }) else { continue }
                        if let image = captured.preview { items[index].preview = image }
                    }
                    self.windows = self.preserveAddedAppIcons(in: items)
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
                    items.append(.init(id: Self.placeholderID(app), appID: app.id, title: app.app.name,
                        sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil))
                }
                self.windows = self.preserveAddedAppIcons(in: items); self.loading = false; self.refresh()
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
                    .init(id: Self.placeholderID(app), appID: app.id, title: app.app.name,
                          sourceFrame: CGRect(x: 0, y: 0, width: 640, height: 420), preview: nil)
                }
                self.expanded = true
                self.message = "Windows are temporarily unavailable. Reopen the overview to try again; browser tabs can still be selected."
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

private final class StagedModifierPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickSelectionView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject private var onboarding: IntentOnboardingCoordinator
    @State private var hoveredWindow: CGWindowID?
    @ObservedObject private var model: IntentAppModel
    @AppStorage("overviewShowClock") private var showClock = true
    @AppStorage("overviewShowTitles") private var showTitles = true
    @AppStorage("overviewNotesX") private var notesX = 1.0
    @AppStorage("overviewNotesY") private var notesY = 0.0
    @State private var notesDrag = CGSize.zero
    @State private var intentionFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = controller.wallpaper { Image(nsImage: image).resizable().scaledToFill() }
                    else { Color.black }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped().allowsHitTesting(false)
                Color.black.opacity(0.12).allowsHitTesting(false)
                OverviewChromeLayout {
                    VStack {
                        HStack {
                            Spacer()
                            if showClock { TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(context.date, style: .time).monospacedDigit().font(.system(size: 14, weight: .medium)).frame(minWidth: 80)
                            } }
                        }.overlay {
                            IntentOptionalNameBar(name: $controller.selection.name).frame(width: min(520, max(180, geometry.size.width - 240)))
                        }.padding(.horizontal, 28).frame(height: 48).padding(.top, controller.topSafeInset)
                        if !model.savedSlots.isEmpty {
                            IntentSavedSlotsView(controller: controller, model: model).frame(height: 94)
                        }
                        if onboarding.isTeaching {
                            OnboardingSelectionHint(coordinator: controller.onboarding)
                                .frame(height: 60).padding(.horizontal, 28)
                        }
                    }.frame(width: geometry.size.width).fixedSize(horizontal: false, vertical: true)
                    GeometryReader { workspace in
                        let area = CGRect(x: 28, y: 0, width: max(0, workspace.size.width - 56 - tabWidth), height: workspace.size.height)
                        let notesSize = CGSize(width: 240, height: min(260, area.height * 0.45))
                        let notesFrame = FieldOfViewLayout.panel(origin: CGPoint(
                            x: area.minX + (area.width - notesSize.width) * notesX + notesDrag.width,
                            y: area.minY + (area.height - notesSize.height) * notesY + notesDrag.height), size: notesSize, in: area)
                        // The panel follows the pointer immediately; previews reflow only on
                        // release. Repacking every pointer event flips between competing
                        // layouts and creates distracting rapid movement.
                        let settledNotesFrame = FieldOfViewLayout.panel(origin: CGPoint(
                            x: area.minX + (area.width - notesSize.width) * notesX,
                            y: area.minY + (area.height - notesSize.height) * notesY), size: notesSize, in: area)
                        ZStack(alignment: .topLeading) {
                            AppStackOverview(items: visibleWindows.map { .init(id: $0.id, app: $0.appID, source: $0.sourceFrame, tabCount: controller.tabs(for: $0).count) },
                                             area: area, obstacle: focused == nil ? settledNotesFrame : nil,
                                             selected: Set(visibleWindows.filter { controller.isSelected($0) }.map(\.id)),
                                             names: Dictionary(uniqueKeysWithValues: controller.apps.map { ($0.id, $0.app.name) }),
                                             fronts: $controller.frontWindowByApp, expanded: $controller.expandedStack, hovered: hoveredWindow) { id, frame, captionFrame, showsCaption in
                                Group { if let window = visibleWindows.first(where: { $0.id == id }) { windowCard(window, frame: frame, captionFrame: captionFrame, showsCaption: showsCaption) } }
                            }
                            if controller.loading && visibleWindows.isEmpty {
                                OverviewLoadingSkeleton().frame(width: area.width, height: area.height)
                                    .position(x: area.midX, y: area.midY).allowsHitTesting(false)
                            }
                            if let focused {
                                tabGrid(focused).frame(width: tabWidth - 20, height: area.height)
                                    .intentionFrame("website-menu")
                                    .position(x: geometry.size.width - tabWidth / 2 - 12, y: area.midY)
                            }
                            if focused == nil {
                                VStack(spacing: 0) {
                                    HStack {
                                        Image(systemName: "hand.draw"); Text("Recent intentions"); Spacer()
                                        Image(systemName: "line.3.horizontal")
                                    }.font(.caption.weight(.medium)).padding(12).contentShape(Rectangle())
                                        .help("Drag to move; your apps make room")
                                        .accessibilityLabel("Move recent intentions")
                                        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                            .onChanged { notesDrag = $0.translation }
                                            .onEnded { value in
                                                let final = FieldOfViewLayout.panel(origin: CGPoint(
                                                    x: area.minX + (area.width - notesSize.width) * notesX + value.translation.width,
                                                    y: area.minY + (area.height - notesSize.height) * notesY + value.translation.height), size: notesSize, in: area)
                                                notesX = (final.minX - area.minX) / max(1, area.width - notesSize.width)
                                                notesY = (final.minY - area.minY) / max(1, area.height - notesSize.height)
                                                notesDrag = .zero
                                            })
                                        .contextMenu { Button("Reset position") { notesX = 1; notesY = 0; notesDrag = .zero } }
                                    IntentSessionNotesView(controller: controller, model: model)
                                }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                                    .frame(width: notesFrame.width, height: notesFrame.height)
                                    .position(x: notesFrame.midX, y: notesFrame.midY)
                            }
                        }.frame(width: workspace.size.width, height: workspace.size.height, alignment: .topLeading)
                            // Old placements are clipped immediately while the
                            // asynchronous packer adapts to newly sized chrome.
                            .clipped()
                    }
                    OverviewFooter(controller: controller, model: model)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(width: geometry.size.width, height: geometry.size.height)
                if !reduceMotion, let flight = controller.saveFlight,
                   let source = intentionFrames["record:" + flight.recordID.uuidString],
                   let target = intentionFrames["slot:" + flight.savedID] {
                    SavedIntentionFlight(source: source, target: target).id(flight.token)
                }
                if let transfer = controller.websiteTransfer, let menu = intentionFrames["website-menu"] {
                    WebsiteSelectionFlight(label: transfer.label,
                        source: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 - 200),
                        target: CGPoint(x: menu.midX, y: menu.minY + 110)).id(transfer.id)
                }
                RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.8), lineWidth: 3).padding(3)
                    .shadow(color: accent.opacity(0.65), radius: 10).allowsHitTesting(false)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped().foregroundStyle(.white).preferredColorScheme(.dark)
                .coordinateSpace(name: "IntentOverview")
                .onPreferenceChange(IntentionFramePreference.self) { intentionFrames = $0 }
                .onAppear { controller.savedSlotCapacity = min(9, max(1, Int((geometry.size.width - 150) / 160))) }
                .onChange(of: geometry.size.width) { width in
                    controller.savedSlotCapacity = min(9, max(1, Int((width - 150) / 160)))
                    controller.savedSlotPage = min(controller.savedSlotPage, controller.savedSlotPages - 1)
                }
                .onChange(of: controller.saveFlight) { flight in
                    guard let flight else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 850_000_000)
                        if controller.saveFlight?.token == flight.token { controller.saveFlight = nil }
                    }
                }
                .onChange(of: presetIDs) { ids in
                    for id in ids where controller.selection.apps.contains(id) && controller.selection.windowIDsByApp[id] == nil {
                        controller.selection.toggleApp(id, snapshots: controller.snapshots)
                    }
                    if let focused, ids.contains(focused.appID) { controller.dismissBrowserPicker() }
                }
        }.ignoresSafeArea().onExitCommand { controller.cancelImmediately() }
    }
    private func windowCard(_ window: QuickSelectionController.WindowItem, frame: CGRect, captionFrame: CGRect, showsCaption: Bool) -> some View {
        let app = controller.apps.first { $0.id == window.appID }
        let selected = controller.isSelected(window)
        let browser = QuickSelection.browsers.contains(window.appID)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty || title == "()" ? (app?.app.name ?? window.appID) : title
        let hovered = hoveredWindow == window.id
        let captionWidth = captionFrame.width
        let cardBounds = showsCaption ? frame.union(captionFrame) : frame
        let radius = min(10, min(frame.width, frame.height) / 8)
        return ZStack(alignment: .topLeading) {
            Button { controller.selectWindow(window) } label: {
                ZStack {
                    if controller.openingApps.contains(window.appID) {
                        ProgressView().controlSize(.small).accessibilityLabel("Opening in background")
                    } else if let image = window.preview {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
                        if controller.loading {
                            WindowLoadingSkeleton().padding(12)
                        } else if let app {
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
                .overlay(alignment: .topTrailing) {
                    if controller.isAddedApplication(window.appID) {
                        Button { controller.removeAddedApplication(window.appID) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .frame(width: 24, height: 24).background(.regularMaterial, in: Circle())
                        }.buttonStyle(.plain).padding(5)
                            .accessibilityLabel("Remove added app \(app?.app.name ?? label)")
                            .help("Remove this addition and cancel its opening")
                    }
                }
                .position(x: frame.midX - cardBounds.minX, y: frame.midY - cardBounds.minY)
            if showsCaption { HStack(spacing: 5) {
                Button { controller.selectWindow(window) } label: {
                    HStack(spacing: 5) {
                        if let app { Image(nsImage: app.icon).resizable().frame(width: 16, height: 16) }
                        Text(showTitles ? label : (app?.app.name ?? label))
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, minHeight: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(app?.app.name ?? window.appID): \(label), \(selected ? "selected" : "not selected")")
                if browser {
                    Button {
                        controller.explicitBrowserWindow = nil
                        if controller.focusedBrowserWindow == window.id { controller.dismissBrowserPicker() }
                        else { controller.selectWindow(window) }
                    } label: {
                        Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 5).frame(height: 20)
                    }.buttonStyle(.plain).accessibilityLabel("Show tabs for \(label)").help("Choose browser tabs")
                }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 5)
                .frame(width: captionWidth, height: captionFrame.height)
                .foregroundStyle(.white)
                .position(x: captionFrame.midX - cardBounds.minX, y: captionFrame.midY - cardBounds.minY)
            }
        }.frame(width: cardBounds.width, height: cardBounds.height, alignment: .topLeading)
            .onHover { hoveredWindow = $0 ? window.id : (hoveredWindow == window.id ? nil : hoveredWindow) }
            .help("\(app?.app.name ?? window.appID) — \(label)")
            .opacity(controller.expanded ? 1 : 0).allowsHitTesting(controller.expanded && !controller.closing)
            // Keep hover/help hit regions on the card's bounds. Position expands
            // its layout wrapper to the canvas; attaching interaction after it
            // lets later cards intercept clicks intended for earlier previews.
            .position(x: cardBounds.midX, y: cardBounds.midY)
    }
    private func tabGrid(_ window: QuickSelectionController.WindowItem) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(controller.apps.first { $0.id == window.appID }?.app.name ?? "Browser tabs").font(.headline)
                    Spacer()
                    Button { controller.openWebsiteFinder() } label: {
                        Image(systemName: "plus"); Text("T").font(.caption.monospaced())
                    }.buttonStyle(.plain).accessibilityLabel("Add a website, T")
                        .disabled(controller.currentWebsiteFinderTarget == nil || controller.creatingWebsiteTab)
                    Button { controller.dismissBrowserPicker() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close tabs")
                }
                if controller.tabs(for: window).isEmpty {
                    Label(controller.resolvingBrowserWindow ? "Finding this window’s tabs…" : controller.unavailableTabsMessage(for: window.appID), systemImage: "puzzlepiece.extension")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh tabs") { controller.reloadBrowserTabs(window.appID) }
                        .buttonStyle(.bordered)
                }
                Toggle(isOn: Binding(get: {
                    let shown = controller.tabs(for: window)
                    return !shown.isEmpty && shown.allSatisfy { controller.isTabSelected($0.id, browser: window.appID) }
                }, set: { _ in controller.toggleAllFocusedTabs() })) {
                    HStack { Text("Select all"); Spacer(); Text("X").font(.caption.monospaced()).foregroundStyle(.secondary) }
                }.toggleStyle(.checkbox).tint(accent)
                Text("Click to select · Shift-click for a range").font(.caption2).foregroundStyle(.secondary)
                if controller.selection.accessMode == .whitelist {
                ScrollView {
                WebsiteFeatureControls(policies: $controller.selection.websiteFeaturePolicies,
                    sites: FocusWebsite.allCases.filter { site in
                        controller.snapshots.contains { snapshot in
                            (snapshot.allTabs ?? snapshot.tabs).contains { tab in
                                controller.isTabSelected(tab.id, browser: snapshot.browserBundleIdentifier) && FocusWebsite.matching(tab.url) == site
                            }
                        }
                    }, isNewIntention: controller.selection.sourceIntentionID == nil)
                }.frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
                }
                let tabs = controller.tabs(for: window)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            let key = QuickSelectionTab(browser: window.appID, id: tab.id)
                            let selected = controller.isTabSelected(key.id, browser: window.appID)
                            Button { controller.selectTab(tab, browser: window.appID, extendingRange: NSEvent.modifierFlags.contains(.shift)) } label: {
                                HStack(spacing: 10) {
                                    TabSiteIcon(url: tab.faviconURL, pageURL: tab.url,
                                        identity: "\(window.appID):\(controller.snapshots.first(where: { $0.browserBundleIdentifier == window.appID })?.browserSessionID ?? ""):\(tab.id)")
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
                }.frame(height: max(80, min(240, (geometry.size.height - 94) / 2)))
                Divider()
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.12))
                    if let finder = controller.websiteFinder {
                        WebsiteFinderView(controller: finder, onClose: controller.closeWebsiteFinder)
                            .overlay {
                                if controller.creatingWebsiteTab {
                                    ZStack {
                                        Color.black.opacity(0.7)
                                        ProgressView("Adding background tab…")
                                    }.clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                            }
                    }
                    else if let image = controller.tabPreview { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)) }
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


/// Shared by the overview and isolated rendering checks; no fixed outer height.
struct OverviewFooter: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    private var accent: Color { controller.selection.accessMode == .blacklist ? .red : .green }
    var body: some View {
        VStack(spacing: 8) {
            ModificationStrip(controller: controller).frame(maxWidth: 1050).padding(.horizontal, 28)
            if let message = controller.message {
                Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
                    .padding(8).frame(maxWidth: .infinity).frame(height: 52)
                    .background(.regularMaterial, in: Capsule()).padding(.horizontal, 28).help(message)
            }
            HStack {
                AppPresetStatusStrip(model: model) { controller.settingsOpen = true }
                Spacer(minLength: 16)
            }.padding(.horizontal, 28).frame(height: 26)
            HStack {
                Button("Close · Esc") { controller.cancel() }.buttonStyle(.plain)
                Button("Apple Spotlight · ⌘Space") { controller.openAppleSpotlight() }.buttonStyle(.plain)
                Button("Saved · 1–9") { controller.toggleSlots() }.buttonStyle(.plain)
                Spacer()
                Button(controller.selection.accessMode == .blacklist ? "Block selected · B" : "Allow selected · B") { controller.toggleAccessMode() }.buttonStyle(.plain).foregroundStyle(accent)
                Spacer()
                Button("Run · Return ↵") { controller.runSelection() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    .disabled(!controller.hasRunnableDraft || controller.loading || controller.closing || controller.restoringSavedWorkspace || !controller.openingApps.isEmpty)
                Button { controller.settingsOpen.toggle() } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Overview settings").help("Settings and app presets")
                    .popover(isPresented: $controller.settingsOpen, arrowEdge: .top) {
                        OverviewSettingsView(model: model).frame(width: 380).padding(20).preferredColorScheme(.dark)
                    }
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 28).frame(height: 52)
        }
    }
}

private struct ModificationStrip: View {
    @ObservedObject var controller: QuickSelectionController
    private var accent: Color { controller.selection.accessMode == .blacklist ? .red : .green }
    @State private var dragged: QuickSelectionOptionsSection?
    @State private var dragOffset: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(controller.modificationOrder.enumerated()), id: \.element) { index, section in
                let enabled = section.enabled(in: controller.selection)
                VStack(spacing: 0) {
                    Button { controller.openModification(section) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: section.icon)
                            Text(section.rawValue).lineLimit(1).minimumScaleFactor(0.8)
                            Text("` + \(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            if enabled { Circle().fill(accent).frame(width: 5, height: 5) }
                        }.font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(enabled ? accent.opacity(0.8) : .white.opacity(0.2)))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(section.rawValue), \(enabled ? "on" : "off"), backtick plus \(index + 1)")
                    if let duration = section.durationSummary(in: controller.selection) {
                        Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 3)
                        Button { controller.editModification(section) } label: {
                            Text(duration).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                                .padding(.horizontal, 13).frame(height: 20)
                                .background(Color(white: 0.10), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.18)))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Edit \(section.rawValue.lowercased()), \(duration)")
                    } else { Color.clear.frame(height: 23).allowsHitTesting(false) }
                }.frame(maxWidth: .infinity)
                    .onHover { controller.hoverModification($0 ? section : nil) }
                    .onDisappear { controller.hoverModification(nil) }
                    .offset(x: dragged == section ? dragOffset : 0).zIndex(dragged == section ? 1 : 0)
                    .highPriorityGesture(DragGesture(minimumDistance: 10)
                        .onChanged { value in controller.hoverModification(nil); dragged = section; dragOffset = value.translation.width }
                        .onEnded { value in
                            let slot = (geometry.size.width + 8) / CGFloat(controller.modificationOrder.count)
                            let destination = min(controller.modificationOrder.count - 1, max(0, index + Int((value.translation.width / slot).rounded())))
                            controller.swapModification(section.rawValue, with: controller.modificationOrder[destination])
                            dragged = nil; dragOffset = 0
                        })
                    .popover(isPresented: Binding(get: { controller.optionsSection == section }, set: { if !$0, controller.optionsSection == section { controller.closeModification() } }), arrowEdge: .top) {
                        QuickSelectionOptionsView(selection: $controller.selection, section: section) { controller.closeModification() }
                    }
            }
        }
        }.frame(height: 60)
    }
}
