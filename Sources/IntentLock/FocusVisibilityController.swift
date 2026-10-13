import AppKit
import ApplicationServices
import Darwin
import IntentCore

/// Owns only reversible visibility changes. Never closes a process or window.
public final class FocusVisibilityController: @unchecked Sendable {
    private struct Entry: Codable, Equatable {
        var pid: pid_t
        var launched: Date
        var bundle: String
        var window: UInt32? // nil means this controller hid the whole app
        var browserSessionID: String?
        var intentionSessionID: String?
        var browserWindowID: Int?
        var parking: Bool?
        var bootstrapEffectID: String?
        var nativeCoverage: Bool?
        var accessibilityApplicationHide: Bool?
        // nil decodes old journals with their existing automatic semantics.
        var restorationPolicy: HiddenWorkspaceRestorationPolicy?
        var controllerOwnershipID: String?
    }
    private struct WindowIdentity: Hashable {
        var pid: pid_t
        var launched: Date
        var window: UInt32
    }
    private struct AccessibleNativeWindow {
        var element: AXUIElement
        var role: String
        var subrole: String
        var title: String
        var frame: CGRect
    }
    private static let file = ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("hidden-workspace.json")
    private static let browsers: Set<String> = ["org.mozilla.firefox", "com.google.Chrome"]
    // Main-thread generation prevents a recovery retry from touching a newer session.
    private static var recoveryGeneration = 0
    private static var recoverySource: DispatchSourceFileSystemObject?
    private static var recoveryTerminationObserver: NSObjectProtocol?
    private static var recoveryWork: DispatchWorkItem?
    private static var recoveryFingerprint: [String] = []
    private static var accessibilityWindows: [WindowIdentity: AXUIElement] = [:]
    private static var diagnosticEvents: [[String: Any]] = []
    private let spec: FocusSessionSpec
    private let controllerOwnershipID = UUID().uuidString
    private let visibilityCache: BrowserWindowVisibilityRecordCache?
    private var enforcementPolicy: BrowserWindowEnforcementPolicy?
    /// Main-thread callback. Parking capture receipts are intentionally separate.
    public var onCoverageFailure: ((BrowserWindowCoveragePolicy.Failure) -> Void)?
    public var onNativeCoverageFailure: ((NativeVisibilityCoveragePolicy.Failure) -> Void)?
    public var onEnforcementFailure: ((BrowserWindowEnforcementPolicy.Failure) -> Void)?
    /// The lock's thread-safe stop gate also fences a main-thread AX pass while
    /// another thread is waiting for synchronous visibility cleanup.
    public var enforcementIsCurrent: (() -> Bool)?
    private var mayEnforce: Bool { !stopped && (enforcementIsCurrent?() ?? true) }
    // AppKit visibility requests must run on the application main thread.
    // A background unhide can fail even after hide succeeded.
    private let queue = DispatchQueue.main
    private var timer: DispatchSourceTimer?
    private var entries: [Entry] = []
    private var stopped = false
    private var started = false
    private var initialVisibilityApplied = false
    private var nativeCoverage: NativeVisibilityCoveragePolicy
    private var nativeStartupWindows: [NativeVisibilityCoveragePolicy.Target: WorkspaceWindow] = [:]
    private var nativeStartupBindings: [NativeVisibilityCoveragePolicy.Target: AXUIElement] = [:]
    private var nativeDiagnosticTargets: [NativeVisibilityCoveragePolicy.Target: [String: Any]] = [:]
    private var nativeDiagnosticSelections: [[String: Any]] = []
    private var nativeKnownUserWindows: Set<NativeVisibilityCoveragePolicy.Target> = []
    private var nativeKnownDocumentWindows: Set<NativeVisibilityCoveragePolicy.Target> = []
    private let auxiliaryProofLock = NSLock()
    private var auxiliaryProofs: [NativeVisibilityCoveragePolicy.Target: TimeInterval] = [:]
    private var observedAuxiliaryProofs: [NativeVisibilityCoveragePolicy.Target: TimeInterval] = [:]
    /// Derived utility permission stays separate from the frozen work selection.
    /// This lookup performs no AX read or visibility effect and expires quickly.
    public func permitsAuxiliaryWindow(id: UInt32, pid: pid_t, bundleIdentifier: String, launched: Date?) -> Bool {
        guard let launched else { return false }
        let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: bundleIdentifier, pid: pid,
            launched: launched.timeIntervalSinceReferenceDate, windowID: id)
        auxiliaryProofLock.lock(); defer { auxiliaryProofLock.unlock() }
        guard let observedAt = auxiliaryProofs[target] else { return false }
        return NativeVisibilityCoveragePolicy.auxiliaryProofIsFresh(observedAt: observedAt, now: ProcessInfo.processInfo.systemUptime)
    }
    private func publishAuxiliaryProofs(_ proofs: [NativeVisibilityCoveragePolicy.Target: TimeInterval]) {
        auxiliaryProofLock.lock(); auxiliaryProofs = proofs; auxiliaryProofLock.unlock()
    }
    private struct CoverageRequest {
        var id: String
        var began: TimeInterval
        var targets: Set<BrowserWindowCoveragePolicy.NativeIdentity>
        var witnessed: Set<BrowserWindowCoveragePolicy.NativeIdentity>
        var snapshots: [BrowserTabSnapshot]?
        var receiptAt: TimeInterval?
        var reported: Set<BrowserWindowCoveragePolicy.ReportedIdentity>
        var expectedProfiles: Set<String>
    }
    private final class CoverageState {
        var known: Set<BrowserWindowCoveragePolicy.NativeIdentity>
        var profiles: Set<String>
        var coverage: BrowserWindowCoveragePolicy.Coverage
        var observation: WorkspaceWindow.CoverageObservation?
        var cohort: BrowserWindowCoverageCohort
        var request: CoverageRequest?
        var inventoryFailureSince: TimeInterval?
        var pendingReported: Set<BrowserWindowCoveragePolicy.ReportedIdentity> = []
        init(_ coverage: BrowserWindowCoveragePolicy.Coverage, observation: WorkspaceWindow.CoverageObservation?, allowsLater: Bool) {
            self.coverage = coverage; self.observation = observation
            known = coverage.observableIdentities; profiles = coverage.knownProfiles
            cohort = .init(windows: coverage.unreported, allowsLaterWindows: allowsLater)
        }
    }
    private var coverageStates: [String: CoverageState] = [:]
    private static let coverageQueue = DispatchQueue(label: "intent.browser-coverage", qos: .userInitiated)
    private var coverageSweepInFlight = false
    private var coverageSweepGeneration = 0
    private struct CoverageSample {
        var browser: String
        var observation: WorkspaceWindow.CoverageObservation?
    }
    private let coverageReadyLock = NSLock()
    private var initialCoverageReady = true
    public var isInitialCoverageReady: Bool {
        coverageReadyLock.lock(); defer { coverageReadyLock.unlock() }; return initialCoverageReady
    }
    private func updateCoverageReady() {
        coverageReadyLock.lock()
        initialCoverageReady = nativeCoverage.initialResolved && coverageStates.values.allSatisfy { $0.cohort.initialResolved }
        coverageReadyLock.unlock()
    }
    public init(spec: FocusSessionSpec) {
        self.spec = spec
        nativeCoverage = .init(required: spec.hideDistractions && spec.requiresEnforcement)
        for coverage in spec.browserWindowCoverage where spec.hideDistractions && spec.requiresEnforcement {
            coverageStates[coverage.browserBundleIdentifier] = CoverageState(coverage, observation: spec.browserCoverageObservations[coverage.browserBundleIdentifier], allowsLater: spec.coverageAllowsLaterWindows)
        }
        initialCoverageReady = nativeCoverage.initialResolved && coverageStates.values.allSatisfy { $0.cohort.initialResolved }
        visibilityCache = spec.nativeWindowVisibilitySessionID.map {
            BrowserWindowVisibilityRecordCache(intentionSessionID: $0)
        }
        enforcementPolicy = spec.nativeWindowVisibilitySessionID.map {
            BrowserWindowEnforcementPolicy(intentionSessionID: $0)
        }
    }

    public func start() {
        onMain {
            guard mayEnforce else { return }
            started = true
            Self.diagnosticEvents = []
            Self.recoveryGeneration &+= 1
            Self.stopRecoveryWatcher()
            RestorationFocusGuard.cancel()
            // An anchored DBT start must not replay an old legacy visibility
            // effect before it has even established its work destination.
            // Normal quiet-owned entries already carry their durable policy.
            entries = spec.startupWindowAnchor == nil ? Self.restore() : Self.loadEntries()
            guard spec.hideDistractions && spec.requiresEnforcement, !stopped, timer == nil else {
                if spec.startupWindowAnchor == nil, Self.needsRecoveryObservation(entries, parkingOnly: true) {
                    Self.startRecoveryWatcher(generation: Self.recoveryGeneration, parkingOnly: true)
                }
                return
            }
            nativeCoverage.begin(now: ProcessInfo.processInfo.systemUptime)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop(restorationPolicyOverride: HiddenWorkspaceRestorationPolicy? = nil) {
        onMain {
            guard !stopped else { return }
            publishAuxiliaryProofs([:])
            nativeCoverage.stop()
            enforcementPolicy?.stop()
            for entry in Self.loadEntries() where entry.intentionSessionID == spec.nativeWindowVisibilitySessionID {
                Self.cancelPreparedBootstrap(entry)
            }
            // Capture registrations even when finish beats the next refresh.
            if started, let visibilityCache {
                entries = Self.captureParking(records: visibilityCache.records(forceRefresh: true), entries: Self.loadEntries(),
                    restorationPolicy: spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: controllerOwnershipID)
            }
            stopped = true
            timer?.cancel(); timer = nil
            guard started else { return }
            entries = Self.beginRecovery(policy: restorationPolicyOverride ?? spec.hiddenWorkspaceRestorationOnStop,
                                         controllerOwnershipID: controllerOwnershipID)
        }
    }
    public static func restoreInterruptedSession() {
        if Thread.isMainThread { _ = beginRecovery(policy: .restoreOwnedWorkspace) }
        else { DispatchQueue.main.sync { _ = beginRecovery(policy: .restoreOwnedWorkspace) } }
    }
    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }

    @discardableResult private static func beginRecovery(policy: HiddenWorkspaceRestorationPolicy = .automatic,
                                                        controllerOwnershipID: String? = nil) -> [Entry] {
        recoveryGeneration &+= 1
        stopRecoveryWatcher()
        let generation = recoveryGeneration
        var saved = loadEntries()
        if policy == .onUserReveal || policy == .restoreOwnedWorkspace || controllerOwnershipID != nil {
            RestorationFocusGuard.cancel()
            for index in saved.indices {
                saved[index].restorationPolicy = (saved[index].restorationPolicy ?? .automatic).atStop(
                    requested: policy, ownsEntry: controllerOwnershipID != nil && saved[index].controllerOwnershipID == controllerOwnershipID)
            }
            // Never fall back to revealing windows when durable deferral could
            // not be written. Retain ownership; no effect has been dispatched.
            guard save(saved) else { return saved }
        }
        var restoringPIDs = Set(saved.map(\.pid))
        // Browser Guard restores parked tabs after the shared rules clear.
        for app in NSWorkspace.shared.runningApplications where
            ["org.mozilla.firefox", "com.google.Chrome"].contains(app.bundleIdentifier ?? "") {
            restoringPIDs.insert(app.processIdentifier)
        }
        let onlyDeferredOwnership = !saved.isEmpty && saved.allSatisfy {
            ($0.restorationPolicy ?? .automatic) == .onUserReveal
        }
        RestorationFocusGuard.begin(restoringPIDs: restoringPIDs,
            observationOnly: policy == .onUserReveal || onlyDeferredOwnership)
        // Only bound native ownership can survive finish. Uncaptured holding
        // windows have not been ACKed, so JS has not moved any user tabs there.
        if needsRecoveryObservation(saved) { startRecoveryWatcher(generation: generation) }
        let pending = restore()
        RestorationFocusGuard.preserveCurrent()
        if pending.contains(where: { ($0.restorationPolicy ?? .automatic) == .automatic }) {
            retryRecovery(generation: generation, attempts: 4)
        }
        if !needsRecoveryObservation(pending) { stopRecoveryWatcher() }
        return pending
    }
    private static func retryRecovery(generation: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard generation == recoveryGeneration else { return }
            // unhide() may report false while the visibility request is still in flight.
            // Re-read macOS state before discarding ownership, or retry if it really failed.
            let pending = restore()
            if pending.contains(where: { ($0.restorationPolicy ?? .automatic) == .automatic }) && attempts > 1 {
                retryRecovery(generation: generation, attempts: attempts - 1)
            } else if !needsRecoveryObservation(pending) { stopRecoveryWatcher() }
        }
    }

    private func refresh() {
        guard mayEnforce else { return }
        let initialApps = initialVisibilityApplied ? nil : spec.initialAllowedApps
        let serverRows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let windows = WorkspaceWindow.list(records: serverRows ?? [])
        // The presentation list can omit a still-live minimized window. Retain
        // its exact AX binding unless the unfiltered lifetime probe proves loss.
        let missingCached = Self.accessibilityWindows.keys.filter { identity in
            !windows.contains { $0.id == identity.window && $0.pid == identity.pid }
        }
        if !missingCached.isEmpty {
            let inventory = serverRows
            Self.accessibilityWindows = Self.accessibilityWindows.filter { identity, _ in
                guard missingCached.contains(identity), let inventory else { return true }
                return inventory.contains { $0[kCGWindowNumber as String] as? UInt32 == identity.window
                    && $0[kCGWindowOwnerPID as String] as? pid_t == identity.pid }
            }
        }
        let records: [BrowserWindowVisibilityRecord]
        if let session = spec.nativeWindowVisibilitySessionID,
           let rules = Self.currentRules(), rules.active, rules.hideDistractions,
           rules.nativeWindowVisibility, rules.isFresh(), rules.startupSessionID == session {
            records = visibilityCache?.records() ?? []
        } else {
            records = []
        }
        // An older intention's explicit orphan reveal can arrive during a newer
        // one. Only historical parking ownership is released here, never normal
        // windows hidden for this current session.
        if spec.startupWindowAnchor == nil, entries.contains(where: { $0.parking == true || $0.bootstrapEffectID != nil }) {
            entries = Self.restore(parkingOnly: true)
        }
        reconcileBrowserWindows(records: records, windows: windows)
        refreshBrowserCoverage()
        guard mayEnforce else { return }
        var observations: [NativeVisibilityCoveragePolicy.Target: NativeVisibilityCoveragePolicy.Outcome] = [:]
        var nativeInventoryAvailable = serverRows != nil
        var unidentifiedPIDs: [pid_t] = [], missingIdentityPIDs: [pid_t] = []
        nativeDiagnosticTargets.removeAll()
        nativeDiagnosticSelections.removeAll()
        observedAuxiliaryProofs.removeAll()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard mayEnforce else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            guard let bundle = app.bundleIdentifier else {
                nativeInventoryAvailable = false; unidentifiedPIDs.append(app.processIdentifier); continue
            }
            if let selected = spec.selectedWindowIDsByApp[bundle] {
                nativeDiagnosticSelections.append(["pid": app.processIdentifier, "selectedWindows": Array(selected.sorted().prefix(60)),
                    "presentationWindows": Array(windows.filter { $0.pid == app.processIdentifier }.map(\.id).sorted().prefix(60))])
            }
            let excludedWindows = windows.filter { window in coverageStates[bundle] == nil && window.pid == app.processIdentifier
                && (!spec.permitsWindow(window.id, bundleIdentifier: bundle)
                    || (initialApps != nil && spec.initialSelectedWindows[bundle].map { !$0.contains(window.id) } == true)) }
            let action = NativeVisibilityCoveragePolicy.applicationAction(
                isCaptureTool: FocusSystemToolPolicy.isScreenshotApplication(bundle),
                alwaysAllowed: spec.presetAllowedBundleIdentifiers.contains(bundle),
                explicitlyBlocked: spec.presetBlockedBundleIdentifiers.contains(bundle),
                applicationExcluded: spec.shouldHideApplication(bundle, initialAllowedApps: initialApps),
                excludedWindowIDs: Set(excludedWindows.map(\.id)))
            guard action.requiresProcessIdentity else { continue }
            guard let launched = app.intentVisibilityLaunchDate else {
                nativeInventoryAvailable = false; missingIdentityPIDs.append(app.processIdentifier); continue
            }
            if action == .hideApplication {
                let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: bundle,
                    pid: app.processIdentifier, launched: launched.timeIntervalSinceReferenceDate)
                observations[target] = hideNativeApplication(app, target: target)
            } else {
                for window in excludedWindows {
                    guard mayEnforce else { return }
                    let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: bundle, pid: window.pid,
                        launched: launched.timeIntervalSinceReferenceDate, windowID: window.id)
                    if !nativeCoverage.initialResolved { nativeStartupWindows[target] = window }
                    observations[target] = hideNativeWindow(window, app: app, launched: launched)
                }
            }
        }
        // A presentation list can omit a minimized or closing window. Omission
        // cannot satisfy startup: re-read the exact cached AX binding or prove
        // its WindowServer/process lifetime ended, without touching replacements.
        if !nativeCoverage.initialResolved {
            for target in nativeCoverage.targets where observations[target] == nil {
                guard mayEnforce else { return }
                observations[target] = observePendingNativeTarget(target, serverRows: serverRows)
            }
            guard mayEnforce else { return }
            let packet = nativeInventoryAvailable ? observations.map {
                NativeVisibilityCoveragePolicy.Observation(target: $0.key, outcome: $0.value)
            } : nil
            let failure = nativeCoverage.update(packet, now: ProcessInfo.processInfo.systemUptime)
            writeNativeCoverageDiagnostics(observations: observations, inventoryAvailable: nativeInventoryAvailable,
                unidentifiedPIDs: unidentifiedPIDs, missingIdentityPIDs: missingIdentityPIDs, failure: failure)
            if let failure {
                guard mayEnforce else { return }
                onNativeCoverageFailure?(failure)
            }
            if nativeCoverage.initialResolved {
                initialVisibilityApplied = true
                nativeStartupWindows.removeAll()
                nativeStartupBindings.removeAll()
            }
        }
        publishAuxiliaryProofs(mayEnforce ? observedAuxiliaryProofs : [:])
        updateCoverageReady()
    }

    private func hideNativeApplication(_ app: NSRunningApplication,
                                       target: NativeVisibilityCoveragePolicy.Target) -> NativeVisibilityCoveragePolicy.Outcome {
        var detail: [String: Any] = ["stage": "applicationHide"]
        var readCount = 0
        func isCurrent() -> Bool {
            self.mayEnforce && !app.isTerminated && app.bundleIdentifier == target.bundleIdentifier
                && app.intentVisibilityLaunchDate?.timeIntervalSinceReferenceDate == target.launched
        }
        let outcome = NativeVisibilityCoverageEffects.hideWithFallback(isCurrent: isCurrent, readHidden: {
            guard !app.isTerminated, app.bundleIdentifier == target.bundleIdentifier,
                  app.intentVisibilityLaunchDate?.timeIntervalSinceReferenceDate == target.launched else { return nil }
            readCount += 1
            let axOwned = self.entries.contains { $0.pid == target.pid && $0.launched.timeIntervalSinceReferenceDate == target.launched
                && $0.window == nil && $0.accessibilityApplicationHide == true }
            let state = Self.applicationHidden(app, accessibilityHideOwned: axOwned)
            let hidden = state.hidden
            detail[readCount == 1 ? "hiddenBefore" : "hiddenAfter"] = hidden.map { $0 as Any } ?? NSNull()
            detail["accessibilityHiddenReadStatus"] = state.status.rawValue
            return hidden
        }, saveOwnership: {
            // Persist this controller's ownership before asking macOS to hide.
            let saved = self.acquireVisibleOwnership(Entry(pid: target.pid,
                launched: Date(timeIntervalSinceReferenceDate: target.launched), bundle: target.bundleIdentifier, window: nil,
                restorationPolicy: self.spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: self.controllerOwnershipID))
            detail["ownershipSaved"] = saved; return saved
        }, dispatchPrimary: { detail["requestAccepted"] = app.hide() }, saveFallbackOwnership: {
            let element = AXUIElementCreateApplication(target.pid)
            guard isCurrent(), Self.isSettable(element, kAXHiddenAttribute), Self.boolean(element, kAXHiddenAttribute).value != nil else {
                detail["accessibilityHiddenSettable"] = false; return false
            }
            detail["accessibilityHiddenSettable"] = true
            // Mark the AX path durably before dispatch so recovery cannot
            // retire this entry using a contradictory NS isHidden=false.
            let saved = self.acquireVisibleOwnership(Entry(pid: target.pid,
                launched: Date(timeIntervalSinceReferenceDate: target.launched), bundle: target.bundleIdentifier, window: nil,
                accessibilityApplicationHide: true, restorationPolicy: self.spec.hiddenWorkspaceRestorationOnStop,
                controllerOwnershipID: self.controllerOwnershipID))
            detail["fallbackOwnershipSaved"] = saved; return saved
        }, dispatchFallback: {
            guard isCurrent() else { return }
            let element = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(element, 0.025)
            detail["accessibilityHiddenRequestStatus"] = AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, kCFBooleanTrue).rawValue
        })
        if outcome == .unresolved, isCurrent() {
            let windowOutcome = minimizeExcludedApplicationWindows(app, target: target, detail: &detail)
            nativeDiagnosticTargets[target] = detail
            return windowOutcome
        }
        nativeDiagnosticTargets[target] = detail
        return outcome
    }

    /// Some apps reject both whole-app hide APIs. Cover their complete actual
    /// AX window cohort through the same exact, durably owned minimize path.
    /// Unknown, unbound, visible auxiliary, or unsettable windows stay pending.
    private func minimizeExcludedApplicationWindows(_ app: NSRunningApplication, target: NativeVisibilityCoveragePolicy.Target,
                                                    detail: inout [String: Any]) -> NativeVisibilityCoveragePolicy.Outcome {
        guard mayEnforce, !app.isTerminated, app.bundleIdentifier == target.bundleIdentifier,
              app.intentVisibilityLaunchDate?.timeIntervalSinceReferenceDate == target.launched,
              let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let accessible = Self.completeAccessibilityWindows(pid: target.pid, deadline: ProcessInfo.processInfo.systemUptime + 0.25, detail: &detail),
              let native = Self.nativeWindows(rows: rows, app: app),
              let bindings = Self.nativeBindings(accessible: accessible, native: native) else {
            detail["windowFallbackInventoryComplete"] = false; return .unresolved
        }
        detail["windowFallbackInventoryComplete"] = true; detail["windowFallbackCount"] = bindings.count
        guard !bindings.isEmpty else { return .unresolved }
        let launched = Date(timeIntervalSinceReferenceDate: target.launched)
        var outcomes: [NativeVisibilityCoveragePolicy.Outcome] = []
        for (accessibleWindow, window) in bindings {
            guard mayEnforce, !app.isTerminated, app.intentVisibilityLaunchDate == launched, app.bundleIdentifier == target.bundleIdentifier else { return .unresolved }
            let identity = WindowIdentity(pid: target.pid, launched: launched, window: window.id)
            Self.accessibilityWindows[identity] = accessibleWindow.element
            outcomes.append(hideNativeWindow(window, app: app, launched: launched))
        }
        let boundIDs = Set(bindings.map { $0.1.id })
        var hasUnclassifiedSurfaces = false
        for window in native where !boundIDs.contains(window.id) && window.frame.width > 100 && window.frame.height > 80 {
            var auxiliaryDetail: [String: Any] = [:]
            if !classifyNonUserSurface(window, app: app, launched: launched, detail: &auxiliaryDetail) { hasUnclassifiedSurfaces = true }
        }
        let allCovered = NativeVisibilityCoveragePolicy.windowFallbackIsCovered(outcomes, hasUnclassifiedSurfaces: hasUnclassifiedSurfaces)
        detail["windowFallbackCovered"] = allCovered
        // This outcome represents positively hidden windows, not NS hide API
        // acceptance. Whole-app and per-window journals retain separate ownership.
        return allCovered && mayEnforce && !app.isTerminated && app.intentVisibilityLaunchDate == launched
            && app.bundleIdentifier == target.bundleIdentifier ? .hidden : .unresolved
    }

    private func hideNativeWindow(_ window: WorkspaceWindow, app: NSRunningApplication,
                                  launched: Date) -> NativeVisibilityCoveragePolicy.Outcome {
        guard mayEnforce else { return .unresolved }
        // Already-hidden user apps need no new minimize or recovery ownership.
        let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: window.bundle, pid: window.pid,
            launched: launched.timeIntervalSinceReferenceDate, windowID: window.id)
        if !window.title.isEmpty { nativeKnownUserWindows.insert(target) }
        if Self.applicationHidden(app, accessibilityHideOwned: false).hidden == true {
            nativeDiagnosticTargets[target] = ["stage": "applicationAlreadyHidden"]; return .hidden
        }
        guard let element = nativeStartupBindings[target] ?? Self.element(window, launched: launched) else {
            var detail: [String: Any] = ["stage": "accessibilityWindowUnavailable"]
            let nonUserSurface = classifyNonUserSurface(window, app: app, launched: launched, detail: &detail)
            if nonUserSurface { detail["stage"] = "confirmedNonUserSurface" }
            nativeDiagnosticTargets[target] = detail
            return nonUserSurface ? .nonUserSurface : .unresolved
        }
        var detail: [String: Any] = ["stage": "windowMinimize"]
        let role = Self.attribute(element, kAXRoleAttribute)
        let subrole = Self.attribute(element, kAXSubroleAttribute)
        detail["role"] = Self.diagnosticAXType(role.value as? String)
        detail["subrole"] = Self.diagnosticAXType(subrole.value as? String)
        detail["roleStatus"] = role.status.rawValue; detail["subroleStatus"] = subrole.status.rawValue
        let minimizeCapability = Self.settable(element, kAXMinimizedAttribute)
        detail["minimizeSettableStatus"] = minimizeCapability.status.rawValue
        detail["minimizeSettable"] = minimizeCapability.value.map { $0 as Any } ?? NSNull()
        if subrole.value as? String == kAXStandardWindowSubrole { nativeKnownDocumentWindows.insert(target) }
        if permittedAuxiliaryWindow(element, window: window, app: app, launched: launched,
            role: role.value as? String, subrole: subrole.value as? String, detail: &detail) {
            detail["stage"] = "permittedAuxiliaryWindow"
            nativeDiagnosticTargets[target] = detail
            observedAuxiliaryProofs[target] = ProcessInfo.processInfo.systemUptime
            return .permittedAuxiliary
        }
        nativeKnownUserWindows.insert(target)
        if !nativeCoverage.initialResolved { nativeStartupBindings[target] = element }
        var readCount = 0
        let outcome = NativeVisibilityCoverageEffects.hide(isCurrent: { self.mayEnforce }, readHidden: {
            guard !app.isTerminated, app.intentVisibilityLaunchDate == launched, app.bundleIdentifier == window.bundle else { return nil }
            readCount += 1
            let minimized = Self.applicationHidden(app, accessibilityHideOwned: false).hidden == true
                ? (status: AXError.success, value: Optional(true)) : Self.boolean(element, kAXMinimizedAttribute)
            detail[readCount == 1 ? "readBeforeStatus" : "readAfterStatus"] = minimized.status.rawValue
            if let hidden = minimized.value { detail[readCount == 1 ? "hiddenBefore" : "hiddenAfter"] = hidden }
            return minimized.value
        }, saveOwnership: {
            guard self.historicalDeferredVisibility(id: window.id, pid: window.pid, launched: launched, isHidden: false) != .unresolved,
                  !self.entries.contains(where: { $0.pid == window.pid && $0.launched == launched && $0.window == window.id
                      && ($0.parking == true || $0.bootstrapEffectID != nil || $0.nativeCoverage == true) }) else {
                detail["ownershipConflict"] = true; return false
            }
            let saved = self.acquireVisibleOwnership(Entry(pid: window.pid, launched: launched, bundle: window.bundle, window: window.id,
                restorationPolicy: self.spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: self.controllerOwnershipID))
            detail["ownershipSaved"] = saved; return saved
        }, dispatch: {
            let status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            detail["requestStatus"] = status.rawValue; return status == .success
        })
        nativeDiagnosticTargets[target] = detail
        return outcome
    }

    private func permittedAuxiliaryWindow(_ element: AXUIElement, window: WorkspaceWindow, app: NSRunningApplication,
                                          launched: Date, role: String?, subrole: String?, detail: inout [String: Any]) -> Bool {
        let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: window.bundle, pid: window.pid,
            launched: launched.timeIntervalSinceReferenceDate, windowID: window.id)
        let applicationPermitted = spec.permitsApplication(window.bundle)
            && !spec.shouldHideApplication(window.bundle, initialAllowedApps: initialVisibilityApplied ? nil : spec.initialAllowedApps)
            && !spec.presetBlockedBundleIdentifiers.contains(window.bundle)
        let explicitlyBlockedWindow = spec.accessMode == .blacklist && spec.selectedWindowIDsByApp[window.bundle]?.contains(window.id) == true
        guard role == kAXWindowRole, subrole == kAXSystemDialogSubrole || subrole == kAXFloatingWindowSubrole,
              applicationPermitted, !explicitlyBlockedWindow, !nativeKnownDocumentWindows.contains(target),
              mayEnforce, !app.isTerminated, app.bundleIdentifier == window.bundle, app.intentVisibilityLaunchDate == launched else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let native = Self.nativeWindows(rows: rows, app: app),
              let accessible = Self.completeAccessibilityWindows(pid: window.pid, deadline: deadline, detail: &detail),
              let bindings = Self.nativeBindings(accessible: accessible, native: native),
              bindings.contains(where: { $0.1.id == window.id && CFEqual($0.0.element, element) }) else {
            detail["auxiliaryExactNativeBinding"] = false; return false
        }
        detail["auxiliaryExactNativeBinding"] = true
        let liveWork = bindings.contains { accessibleWindow, nativeWindow in
            accessibleWindow.role == kAXWindowRole && accessibleWindow.subrole == kAXStandardWindowSubrole
                && spec.permitsWindow(nativeWindow.id, bundleIdentifier: window.bundle)
        }
        detail["auxiliaryLivePermittedNativeWork"] = liveWork
        let applicationElement = AXUIElementCreateApplication(window.pid)
        var node = element, visited: [AXUIElement] = [element]
        var windowAncestor = false, ancestorPermitted = true, exactApplicationParent = false
        for _ in 0..<8 {
            guard mayEnforce, ProcessInfo.processInfo.systemUptime < deadline else { detail["auxiliaryParentStage"] = "deadline"; return false }
            let parentValue = Self.attribute(node, kAXParentAttribute)
            guard let value = parentValue.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                detail["auxiliaryParentStage"] = "parentUnavailable"; detail["auxiliaryParentStatus"] = parentValue.status.rawValue; return false
            }
            let parent = unsafeBitCast(value, to: AXUIElement.self)
            guard !visited.contains(where: { CFEqual($0, parent) }) else { detail["auxiliaryParentStage"] = "parentCycle"; return false }
            visited.append(parent)
            var parentPID: pid_t = 0
            guard AXUIElementGetPid(parent, &parentPID) == .success, parentPID == window.pid else {
                detail["auxiliaryParentStage"] = "processMismatch"; return false
            }
            let parentRole = Self.attribute(parent, kAXRoleAttribute)
            detail["auxiliaryParentRole"] = Self.diagnosticAXType(parentRole.value as? String)
            switch parentRole.value as? String {
            case kAXApplicationRole:
                exactApplicationParent = CFEqual(parent, applicationElement)
            case kAXWindowRole:
                windowAncestor = true
                guard let parentWindow = Self.accessibleWindow(parent, pid: window.pid, deadline: deadline, detail: &detail),
                      let parentBindings = Self.nativeBindings(accessible: [parentWindow], native: native),
                      let nativeParent = parentBindings.first?.1 else {
                    detail["auxiliaryParentStage"] = "windowBindingUnavailable"; return false
                }
                detail["auxiliaryParentNativeWindow"] = nativeParent.id
                ancestorPermitted = ancestorPermitted && spec.permitsWindow(nativeParent.id, bundleIdentifier: window.bundle)
            case kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole:
                break
            default:
                detail["auxiliaryParentStage"] = "unknownParentRole"; return false
            }
            if parentRole.value as? String == kAXApplicationRole { break }
            node = parent
        }
        detail["auxiliaryHasWindowAncestor"] = windowAncestor
        detail["auxiliaryAncestorPermitted"] = windowAncestor && ancestorPermitted
        detail["auxiliaryExactApplicationParent"] = exactApplicationParent
        guard mayEnforce, !app.isTerminated, app.bundleIdentifier == window.bundle, app.intentVisibilityLaunchDate == launched else { return false }
        return NativeVisibilityCoveragePolicy.permitsAuxiliary(role: role, subrole: subrole, applicationPermitted: applicationPermitted,
            exactProcessParent: exactApplicationParent, hasWindowAncestor: windowAncestor,
            ancestorBoundToPermittedWindow: windowAncestor && ancestorPermitted, livePermittedNativeWork: liveWork,
            previouslyStandardWindow: nativeKnownDocumentWindows.contains(target), explicitlyBlockedWindow: explicitlyBlockedWindow)
    }

    private func classifyNonUserSurface(_ window: WorkspaceWindow, app: NSRunningApplication, launched: Date,
                                        detail: inout [String: Any]) -> Bool {
        let target = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: window.bundle, pid: window.pid,
            launched: launched.timeIntervalSinceReferenceDate, windowID: window.id)
        let previousUserWindow = nativeKnownUserWindows.contains(target)
            || Self.accessibilityWindows[.init(pid: window.pid, launched: launched, window: window.id)] != nil
        detail["untitled"] = window.title.isEmpty
        detail["previouslyIdentifiedUserWindow"] = previousUserWindow
        guard mayEnforce, !previousUserWindow, window.title.isEmpty, AXIsProcessTrusted(),
              !app.isTerminated, app.intentVisibilityLaunchDate == launched, app.bundleIdentifier == window.bundle else { return false }
        // kCGWindowIsOnscreen is optional in optionAll rows. A successful
        // optionOnScreenOnly snapshot proves absence without guessing its value.
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              Self.validServerIdentities(onScreen) else {
            detail["onScreenInventoryAvailable"] = false; return false
        }
        let visible = onScreen.contains { $0[kCGWindowNumber as String] as? UInt32 == window.id
            && $0[kCGWindowOwnerPID as String] as? pid_t == window.pid }
        detail["onScreenInventoryAvailable"] = true; detail["onScreen"] = visible
        guard !visible, mayEnforce else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let accessible = Self.completeAccessibilityWindows(pid: window.pid, deadline: deadline, detail: &detail,
            requiresPrimaryEnumeration: true) else {
            detail["accessibilityInventoryComplete"] = false; return false
        }
        let matchingGeometry = accessible.contains { Self.sameFrame($0.frame, window.frame) }
        detail["accessibilityInventoryComplete"] = true
        detail["accessibilityWindowCount"] = accessible.count
        detail["accessibilityGeometryMatch"] = matchingGeometry
        guard !matchingGeometry, mayEnforce,
              let fresh = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let native = Self.nativeWindows(rows: fresh, app: app),
              let same = native.first(where: { $0.id == window.id && $0.pid == window.pid }) else { return false }
        let stable = same.title.isEmpty && Self.sameFrame(same.frame, window.frame)
        detail["serverIdentityStable"] = stable
        let candidates = accessible.map { accessibleWindow in
            Set(native.filter { $0.title == accessibleWindow.title && Self.sameFrame($0.frame, accessibleWindow.frame) }.map(\.id))
        }
        let allBoundElsewhere = NativeVisibilityCoveragePolicy.allUserWindowsBoundElsewhere(candidates: candidates, excluding: window.id)
        detail["allUserWindowsBoundElsewhere"] = allBoundElsewhere
        // No exemption is cached: if this surface later becomes visible or AX
        // readable, every refresh resumes the normal strict minimize path.
        guard mayEnforce, !app.isTerminated, app.intentVisibilityLaunchDate == launched, app.bundleIdentifier == window.bundle else { return false }
        return NativeVisibilityCoveragePolicy.isNonUserSurface(isUntitled: true, serverIdentityStable: stable, isOnScreen: visible,
            accessibilityInventoryComplete: true, accessibilityGeometryMatch: matchingGeometry,
            previouslyIdentifiedUserWindow: previousUserWindow, allUserWindowsBoundElsewhere: allBoundElsewhere)
    }

    private func observePendingNativeTarget(_ target: NativeVisibilityCoveragePolicy.Target,
                                           serverRows: [[String: Any]]?) -> NativeVisibilityCoveragePolicy.Outcome {
        guard mayEnforce else { return .unresolved }
        if kill(target.pid, 0) == -1 { return errno == ESRCH ? .closed : .unresolved }
        guard let app = NSRunningApplication(processIdentifier: target.pid), let launched = app.intentVisibilityLaunchDate else { return .unresolved }
        guard !app.isTerminated else { return .closed }
        guard app.bundleIdentifier == target.bundleIdentifier,
              launched.timeIntervalSinceReferenceDate == target.launched else { return .closed }
        guard let windowID = target.windowID else { return hideNativeApplication(app, target: target) }
        guard let serverRows else { return .unresolved }
        if Self.applicationHidden(app, accessibilityHideOwned: false).hidden == true { return .hidden }
        let rowExists = serverRows.contains { $0[kCGWindowNumber as String] as? UInt32 == windowID
            && $0[kCGWindowOwnerPID as String] as? pid_t == target.pid }
        if let element = nativeStartupBindings[target] {
            let minimized = Self.boolean(element, kAXMinimizedAttribute)
            if minimized.value == true { return .hidden }
            // A live AX row can outlast its presentation/backing entry. Keep
            // retrying rather than treating that omission as window closure.
            if !rowExists { return minimized.status == .invalidUIElement ? .closed : .unresolved }
        } else if !rowExists { return .closed }
        guard let window = nativeStartupWindows[target] else { return .unresolved }
        return hideNativeWindow(window, app: app, launched: launched)
    }

    private func writeNativeCoverageDiagnostics(
        observations: [NativeVisibilityCoveragePolicy.Target: NativeVisibilityCoveragePolicy.Outcome], inventoryAvailable: Bool,
        unidentifiedPIDs: [pid_t], missingIdentityPIDs: [pid_t], failure: NativeVisibilityCoveragePolicy.Failure?) {
        let targets = observations.sorted { ($0.key.pid, $0.key.windowID ?? 0) < ($1.key.pid, $1.key.windowID ?? 0) }
        let summaries: [[String: Any]] = targets.prefix(60).map { target, outcome in
            var value = nativeDiagnosticTargets[target] ?? [:]
            value["pid"] = target.pid
            value["kind"] = target.windowID == nil ? "application" : "window"
            if let window = target.windowID { value["window"] = window }
            switch outcome { case .hidden: value["outcome"] = "hidden"
            case .closed: value["outcome"] = "closed"
            case .nonUserSurface: value["outcome"] = "nonUserSurface"
            case .permittedAuxiliary: value["outcome"] = "permittedAuxiliary"
            case .unresolved: value["outcome"] = "unresolved" }
            return value
        }
        var value: [String: Any] = ["schemaVersion": 1, "updatedAt": Date().timeIntervalSinceReferenceDate,
            "phase": failure != nil ? "failed" : nativeCoverage.initialResolved ? "resolved" : "pending",
            "inventoryAvailable": inventoryAvailable, "targetCount": targets.count,
            "unresolvedCount": observations.values.filter { $0 == .unresolved }.count,
            "unidentifiedPIDs": Array(unidentifiedPIDs.prefix(60)), "missingIdentityPIDs": Array(missingIdentityPIDs.prefix(60)),
            "targets": summaries, "selections": Array(nativeDiagnosticSelections.prefix(60))]
        if let failure { value["failureReason"] = failure.reason.rawValue }
        let url = Self.file.deletingLastPathComponent().appendingPathComponent("native-visibility-diagnostics.json")
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Called only after positive visible-state observation and before a new
    /// hide/minimize. Never inherit another controller's cleanup responsibility.
    private func acquireVisibleOwnership(_ entry: Entry) -> Bool {
        var next = entries
        if let index = next.firstIndex(where: { $0.pid == entry.pid && $0.launched == entry.launched && $0.window == entry.window }) {
            var replacement = entry
            if next[index].accessibilityApplicationHide == true { replacement.accessibilityApplicationHide = true }
            next[index] = replacement
        } else { next.append(entry) }
        guard Self.save(next) else { return false }
        entries = next
        return true
    }

    private enum HistoricalDeferredVisibility: Equatable { case absent, alreadyHidden, retired, unresolved }
    private func historicalDeferredVisibility(id: UInt32, pid: pid_t, launched: Date,
                                              isHidden: @autoclosure () -> Bool?) -> HistoricalDeferredVisibility {
        guard let index = entries.firstIndex(where: { $0.pid == pid && $0.launched == launched && $0.window == id
            && $0.controllerOwnershipID != controllerOwnershipID && $0.restorationPolicy == .onUserReveal
            && $0.parking != true && $0.bootstrapEffectID == nil }) else { return .absent }
        switch HiddenWorkspaceRestorationPolicy.onUserReveal.historicalDeferredVisibility(isHidden: isHidden()) {
        case .alreadyHidden: return .alreadyHidden
        case .unresolved: return .unresolved
        case .retireForCurrentOwnership:
            // A user-revealed window no longer belongs to the old occurrence.
            // Persist retirement before the normal new ownership/effect path.
            var next = entries; next.remove(at: index)
            guard Self.save(next) else { return .unresolved }
            entries = next
            return .retired
        }
    }
    private func refreshBrowserCoverage() {
        guard !coverageStates.isEmpty, coverageIsCurrent() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let active = coverageStates.filter { !spec.coverageAllowsLaterWindows || !$0.value.cohort.initialResolved
            || !$0.value.pendingReported.isEmpty || $0.value.request != nil }
        for (browser, state) in active {
            if let failure = state.cohort.expiredFailure(now: now) { onCoverageFailure?(failure); return }
            if let request = state.request, now - request.began >= 3 {
                onCoverageFailure?(.init(browserBundleIdentifier: browser, reason: .discoveryUnavailable)); return
            }
            if let began = state.inventoryFailureSince, now - began >= 3 {
                onCoverageFailure?(.init(browserBundleIdentifier: browser, reason: .inventoryUnavailable)); return
            }
            if let request = state.request, request.snapshots == nil {
                let snapshots = BrowserProfileSnapshots.coverageSnapshots(base: BrowserTabSnapshotStore.fileURL(for: browser), requestID: request.id)
                let profiles = Set(snapshots.compactMap(\.browserSessionID))
                if request.expectedProfiles.isSubset(of: profiles), !snapshots.isEmpty,
                   BrowserWindowCoveragePolicy.reportedWindows(snapshots: snapshots) != nil {
                    state.request?.snapshots = snapshots
                    state.request?.receiptAt = ProcessInfo.processInfo.systemUptime
                }
            }
        }
        guard !active.isEmpty, !coverageSweepInFlight else { return }
        for state in active.values { state.cohort.beginPendingObservation(now: now) }
        coverageSweepInFlight = true; coverageSweepGeneration &+= 1
        let generation = coverageSweepGeneration, browsers = Array(active.keys), deadline = now + 2.5
        let previous = active.compactMapValues(\.observation)
        Self.coverageQueue.async { [weak self] in
            var samples: [CoverageSample] = []
            for browser in browsers {
                let observation = WorkspaceWindow.browserCoverageObservation(bundleIdentifier: browser,
                    deadline: deadline, prior: previous[browser])
                samples.append(.init(browser: browser, observation: observation))
            }
            let completedSamples = samples
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.coverageSweepGeneration else { return }
                self.coverageSweepInFlight = false
                guard self.coverageIsCurrent() else { return }
                for sample in completedSamples {
                    guard self.coverageIsCurrent() else { return }
                    let observation = ProcessInfo.processInfo.systemUptime < deadline ? sample.observation : nil
                    if let observation {
                        for (identity, element) in observation.bindings {
                            Self.accessibilityWindows[.init(pid: identity.pid,
                                launched: Date(timeIntervalSinceReferenceDate: identity.launched), window: identity.windowID)] = element
                        }
                    }
                    self.applyBrowserCoverage(browser: sample.browser, observation: observation, began: now)
                }
                self.updateCoverageReady()
            }
        }
    }
    private func coverageIsCurrent() -> Bool {
        guard mayEnforce, let occurrence = spec.nativeWindowVisibilitySessionID,
              let rules = Self.currentRules() else { return false }
        return rules.active && rules.isFresh() && rules.startupSessionID == occurrence
    }
    private func applyBrowserCoverage(browser: String, observation: WorkspaceWindow.CoverageObservation?, began: TimeInterval) {
        guard coverageIsCurrent(), let occurrence = spec.nativeWindowVisibilitySessionID, let state = coverageStates[browser] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let observation else {
            for target in state.cohort.targets {
                _ = state.cohort.observe(target.identity, outcome: .unresolved, now: began)
                if let failure = state.cohort.observe(target.identity, outcome: .unresolved, now: now) {
                    onCoverageFailure?(failure); return
                }
            }
            let firstFailure = state.inventoryFailureSince ?? began; state.inventoryFailureSince = firstFailure
            if now - firstFailure >= 3 { onCoverageFailure?(.init(browserBundleIdentifier: browser, reason: .inventoryUnavailable)) }
            return
        }
        if let failure = state.cohort.expiredFailure(now: now) { onCoverageFailure?(failure); return }
        let inventory = observation.inventory
        state.observation = observation
        state.coverage = state.coverage.retainingContinuous(observation.continuousIdentities)
        state.request?.witnessed.formIntersection(observation.continuousIdentities)
        state.inventoryFailureSince = nil
        if !spec.coverageAllowsLaterWindows || !state.pendingReported.isEmpty || state.request != nil {
            let current = Set(inventory.windows.map(\.identity))
            state.known.formIntersection(current)
            let unknown = inventory.observedStandard.subtracting(state.known)
            if state.request == nil, BrowserWindowCoveragePolicy.needsDiscovery(native: unknown, reported: state.pendingReported) {
                let command = BrowserTabCommand(tabID: -1, windowID: -1, action: .snapshot)
                state.request = .init(id: command.id, began: now, targets: unknown, witnessed: inventory.observedStandard,
                    reported: state.pendingReported, expectedProfiles: state.profiles.union(state.pendingReported.map(\.browserSessionID)))
                // Exactly one discovery request per newly observed cohort;
                // a failed send is pending until its bounded deadline.
                try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(command)
            }
            if let request = state.request, let snapshots = request.snapshots,
               let receiptAt = request.receiptAt, BrowserWindowCoveragePolicy.isPostReceiptObservation(receiptAt: receiptAt,
                    sampledAt: observation.sampledAt, now: now, deadline: request.began + 3) {
                if now - request.began >= 3 {
                    onCoverageFailure?(.init(browserBundleIdentifier: browser, reason: .discoveryUnavailable)); return
                }
                let profiles = Set(snapshots.compactMap(\.browserSessionID))
                let base = BrowserTabSnapshotStore.fileURL(for: browser)
                if !snapshots.allSatisfy({ BrowserProfileSnapshots.isCoverageSnapshotCurrent($0, base: base) }) {
                    // The latched receipt became contradicted while AX was
                    // sampled. Start a new query AFTER this observation; never
                    // substitute a newer sidecar under an older native scan.
                    let command = BrowserTabCommand(tabID: -1, windowID: -1, action: .snapshot)
                    var retry = request
                    retry.id = command.id; retry.snapshots = nil; retry.receiptAt = nil
                    retry.witnessed = inventory.observedStandard
                    retry.expectedProfiles = state.profiles.union(state.pendingReported.map(\.browserSessionID))
                    state.request = retry
                    try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(command)
                } else if request.expectedProfiles.isSubset(of: profiles), let reports = BrowserWindowCoveragePolicy.reportedWindows(snapshots: snapshots),
                   case .complete(let coverage) = BrowserWindowCoveragePolicy.evaluate(browserBundleIdentifier: browser,
                        native: inventory.windows, observedStandard: inventory.observedStandard, reported: reports, knownProfiles: profiles,
                        priorCoverage: state.coverage, continuousIdentities: observation.continuousIdentities,
                        witnessedBeforeSnapshot: request.witnessed) {
                    let disappeared = request.targets.subtracting(current)
                    let resolved = coverage.observableIdentities.union(disappeared)
                    if request.targets.isSubset(of: resolved),
                       request.reported.intersection(state.pendingReported).isSubset(of: Set(coverage.matches.keys)) {
                        for target in coverage.unreported where request.targets.contains(target.identity) {
                            state.cohort.enroll(target)
                            _ = state.cohort.observe(target.identity, outcome: .unresolved, now: request.began)
                        }
                        state.known.formUnion(request.targets.subtracting(disappeared)); state.known.formUnion(coverage.matches.values)
                        state.profiles = profiles; state.coverage = coverage; state.request = nil
                        state.pendingReported.subtract(coverage.matches.keys)
                    }
                }
                if state.request != nil && now - request.began >= 3 {
                    onCoverageFailure?(.init(browserBundleIdentifier: browser, reason: .discoveryUnavailable)); return
                }
            }
        }
        for target in state.cohort.targets {
            guard mayEnforce else { return }
            // Ownership transferred to an exact current browser claim remains
            // the same journal entry, now verified by the browser bridge.
            if entries.contains(where: { $0.pid == target.identity.pid && $0.launched.timeIntervalSinceReferenceDate == target.identity.launched
                && $0.window == target.identity.windowID && $0.intentionSessionID == occurrence
                && $0.browserSessionID != nil && $0.nativeCoverage != true && $0.parking == false }) {
                state.cohort.release(target.identity); continue
            }
            let outcome = minimizeCoverageWindow(target.identity, inventory: inventory, occurrence: occurrence)
            if let failure = state.cohort.observe(target.identity, outcome: outcome, now: now) {
                guard mayEnforce else { return }; onCoverageFailure?(failure); return
            }
        }
    }

    private func minimizeCoverageWindow(_ identity: BrowserWindowCoveragePolicy.NativeIdentity,
                                       inventory: BrowserWindowCoveragePolicy.Inventory,
                                       occurrence: String) -> BrowserWindowCoverageCohort.Outcome {
        guard mayEnforce else { return .unresolved }
        if kill(identity.pid, 0) == -1 { return errno == ESRCH ? .closed : .unresolved }
        guard let app = NSRunningApplication(processIdentifier: identity.pid), let launched = app.intentVisibilityLaunchDate else { return .unresolved }
        if launched.timeIntervalSinceReferenceDate != identity.launched || app.bundleIdentifier != identity.bundleIdentifier { return .closed }
        guard let current = inventory.windows.first(where: { $0.identity == identity }) else {
            return WorkspaceWindow.exists(id: identity.windowID, pid: identity.pid) == false ? .closed : .unresolved
        }
        guard inventory.observedStandard.contains(identity) else { return .unresolved }
        let window = WorkspaceWindow(id: identity.windowID, pid: identity.pid, bundle: identity.bundleIdentifier, title: current.title, frame: current.frame)
        guard let element = Self.element(window, launched: launched) else { return .unresolved }
        switch historicalDeferredVisibility(id: identity.windowID, pid: identity.pid, launched: launched,
                                             isHidden: Self.boolean(element, kAXMinimizedAttribute).value) {
        case .alreadyHidden: return .minimized
        case .unresolved: return .unresolved
        case .absent, .retired: break
        }
        if let previous = entries.first(where: { $0.pid == identity.pid && $0.launched == launched && $0.window == identity.windowID }) {
            guard previous.nativeCoverage == true, previous.intentionSessionID == occurrence,
                  previous.parking != true, previous.bootstrapEffectID == nil else { return .unresolved }
        }
        return BrowserWindowCoverageEffects.minimize(isCurrent: {
            guard self.mayEnforce, let current = Self.currentRules() else { return false }
            return current.active && current.isFresh() && current.startupSessionID == occurrence
        }, readMinimized: { Self.boolean(element, kAXMinimizedAttribute).value }, saveOwnership: {
            if self.entries.contains(where: { $0.pid == identity.pid && $0.launched == launched && $0.window == identity.windowID }) { return true }
            var next = self.entries
            next.append(Entry(pid: identity.pid, launched: launched, bundle: identity.bundleIdentifier, window: identity.windowID,
                intentionSessionID: occurrence, parking: false, nativeCoverage: true,
                restorationPolicy: self.spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: self.controllerOwnershipID))
            guard Self.save(next) else { return false }; self.entries = next; return true
        }, dispatch: {
            let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            Self.observe("coverageMinimize", pid: identity.pid, window: identity.windowID, status: result)
        })
    }

    private func adoptCoverageOwnership(id: UInt32, pid: pid_t, launched: Date,
                                        record: BrowserWindowVisibilityRecord, claim: BrowserWindowVisibilityWindow) -> Bool {
        guard let index = entries.firstIndex(where: { $0.pid == pid && $0.launched == launched && $0.window == id && $0.nativeCoverage == true }) else { return true }
        let previous = entries[index]
        guard let occurrence = previous.intentionSessionID, previous.parking != true, previous.bootstrapEffectID == nil,
              let proof = record.browserProcessIdentity else { return false }
        let ownedIdentity = BrowserWindowCoveragePolicy.NativeIdentity(bundleIdentifier: previous.bundle, pid: previous.pid,
            launched: previous.launched.timeIntervalSinceReferenceDate, windowID: id)
        return BrowserWindowCoverageEffects.transfer(.init(native: ownedIdentity, intentionSessionID: occurrence),
            native: .init(bundleIdentifier: record.browserBundleIdentifier, pid: proof.pid, launched: proof.launched, windowID: id),
            intentionSessionID: record.plan.intentionSessionID, browserSessionID: record.browserSessionID, browserWindowID: claim.windowID,
            isCurrent: {
                guard self.mayEnforce, Self.isFreshClaim(record, pid: pid, launched: launched), let current = Self.currentRules() else { return false }
                return current.active && current.isFresh() && current.startupSessionID == record.plan.intentionSessionID
            }, persist: { updated in
                var next = self.entries
                next[index].browserSessionID = updated.browserSessionID; next[index].browserWindowID = updated.browserWindowID
                next[index].nativeCoverage = updated.isNativeCoverage
                guard Self.save(next) else { return false }; self.entries = next; return true
            })
    }

    /// A profile-local browser ID may use its earlier uniquely proven mapping
    /// only while the coverage packet still owns the exact live AX binding.
    private func coverageBinding(record: BrowserWindowVisibilityRecord, claim: BrowserWindowVisibilityWindow) -> UInt32? {
        guard record.plan.intentionSessionID == spec.nativeWindowVisibilitySessionID,
              let state = coverageStates[record.browserBundleIdentifier], let observation = state.observation,
              let identity = state.coverage.matches[.init(bundleIdentifier: record.browserBundleIdentifier,
                  browserSessionID: record.browserSessionID, windowID: claim.windowID)],
              let proof = record.browserProcessIdentity, identity.pid == proof.pid, identity.launched == proof.launched,
              observation.inventory.observedStandard.contains(identity), let element = observation.element(for: identity),
              Self.isFreshClaim(record, pid: identity.pid, launched: Date(timeIntervalSinceReferenceDate: identity.launched)),
              Self.liveProcessIdentity(record) == proof,
              WorkspaceWindow.exists(id: identity.windowID, pid: identity.pid) == true else { return nil }
        Self.accessibilityWindows[.init(pid: identity.pid, launched: Date(timeIntervalSinceReferenceDate: identity.launched), window: identity.windowID)] = element
        return identity.windowID
    }

    private func reconcileBrowserWindows(records: [BrowserWindowVisibilityRecord], windows: [WorkspaceWindow]) {
        // A newly connected profile can report an already-observed native-only
        // window. Its native ID is not new, but its report identity still needs
        // the same bounded, correlated discovery before normal enforcement.
        for (browser, state) in coverageStates {
            state.pendingReported = Set(records.filter { $0.browserBundleIdentifier == browser }.flatMap { record in
                record.plan.windows.filter { !record.closedParkingWindowIDs.contains($0.windowID) }.map {
                    BrowserWindowCoveragePolicy.ReportedIdentity(bundleIdentifier: browser, browserSessionID: record.browserSessionID, windowID: $0.windowID)
                }
            }).filter { state.coverage.matches[$0] == nil && !state.coverage.invalidatedMatches.contains($0) }
        }
        // Registration ACK has a short deadline. Bind holding windows before
        // potentially slow AX calls into unrelated blocked browser windows.
        let resolved = Self.matches(records: records, windows: windows).sorted { $0.isParking && !$1.isParking }
        for match in resolved where match.isParking {
            guard mayEnforce, let app = NSRunningApplication(processIdentifier: match.candidate.pid),
                  app.bundleIdentifier == match.record.browserBundleIdentifier, let launched = app.intentVisibilityLaunchDate else { continue }
            entries = Self.captureParkingMatch(match, launched: launched, entries: entries,
                restorationPolicy: spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: controllerOwnershipID)
        }
        var observations: [BrowserWindowEnforcementPolicy.Observation] = []
        for record in records {
            let liveIdentity = Self.liveProcessIdentity(record)
            for claim in record.plan.windows where !record.closedParkingWindowIDs.contains(claim.windowID) {
                guard mayEnforce else { return }
                var outcome: BrowserWindowEnforcementPolicy.Outcome = .unresolved(.windowIdentityUnavailable)
                if let liveIdentity, liveIdentity == record.browserProcessIdentity {
                    // A wholly blocked browser is hidden by the application
                    // ownership path below. Its windows need no profile-local
                    // identity guess (two profiles can have identical titles
                    // and bounds). This is live readback, never a desired plan
                    // or cached receipt, and is unavailable to allowed browsers.
                    if !spec.permitsApplication(record.browserBundleIdentifier),
                       NSRunningApplication(processIdentifier: liveIdentity.pid)?.isHidden == true {
                        observations.append(.init(record: record, windowID: claim.windowID,
                            liveProcessIdentity: liveIdentity, outcome: .verifiedApplicationHidden))
                        continue
                    }
                    // A bound identity survives navigation and geometry changes.
                    // Never replace it with a new title-based candidate.
                    let owned = entries.first {
                        $0.parking == false && $0.bundle == record.browserBundleIdentifier
                            && $0.browserSessionID == record.browserSessionID
                            && $0.intentionSessionID == record.plan.intentionSessionID
                            && $0.browserWindowID == claim.windowID && $0.pid == liveIdentity.pid
                            && $0.launched.timeIntervalSinceReferenceDate == liveIdentity.launched
                    }
                    let matched = resolved.first {
                        !$0.isParking && $0.record.browserBundleIdentifier == record.browserBundleIdentifier
                            && $0.record.browserSessionID == record.browserSessionID
                            && $0.window.windowID == claim.windowID
                    }
                    let fallback = matched.flatMap { match -> UInt32? in
                        guard let state = coverageStates[record.browserBundleIdentifier] else { return match.candidate.id }
                        let identity = BrowserWindowCoveragePolicy.ReportedIdentity(bundleIdentifier: record.browserBundleIdentifier,
                            browserSessionID: record.browserSessionID, windowID: claim.windowID)
                        let candidate = BrowserWindowCoveragePolicy.NativeIdentity(bundleIdentifier: match.candidate.bundle,
                            pid: match.candidate.pid, launched: liveIdentity.launched, windowID: match.candidate.id)
                        return BrowserWindowCoveragePolicy.permitsReportedCandidate(identity, candidate: candidate,
                            coverage: state.coverage) ? candidate.windowID : nil
                    }
                    let id = owned?.window ?? coverageBinding(record: record, claim: claim) ?? fallback
                    if let id = owned?.window, WorkspaceWindow.exists(id: id, pid: liveIdentity.pid) == false {
                        outcome = .noLongerExists
                    } else if let id {
                        let window = windows.first(where: { $0.id == id && $0.pid == liveIdentity.pid })
                        outcome = minimizeNormalWindow(window, id: id, pid: liveIdentity.pid, record: record, claim: claim,
                            launched: Date(timeIntervalSinceReferenceDate: liveIdentity.launched), owned: owned != nil)
                    }
                }
                observations.append(.init(record: record, windowID: claim.windowID,
                    liveProcessIdentity: liveIdentity, outcome: outcome))
            }
        }
        // Persist real effect confirmation independently of durable plan ACKs.
        // The store rejects an observation if a newer desired plan overtook it.
        if mayEnforce, let current = Self.currentRules(), current.active, current.isFresh(),
           current.startupSessionID == spec.nativeWindowVisibilitySessionID {
            for record in records {
                let verified = observations.filter { observation in
                    observation.record == record && (observation.outcome == .verifiedMinimized
                        || observation.outcome == .verifiedApplicationHidden || observation.outcome == .noLongerExists)
                }.map(\.windowID)
                _ = try? BrowserWindowVisibilityStore().writeVerification(for: record, windowIDs: verified)
            }
        }
        // AX calls can take time. Recheck the active occurrence immediately
        // before a failure callback; a stop/new session cannot be resurrected.
        let rules = Self.currentRules()
        let currentSession = rules.flatMap { $0.active && $0.hideDistractions && $0.nativeWindowVisibility && $0.isFresh() ? $0.startupSessionID : nil }
        var nextPolicy = enforcementPolicy
        let failure = nextPolicy?.update(observations,
            activeIntentionSessionID: currentSession, now: ProcessInfo.processInfo.systemUptime)
        if let failure {
            // A later plan may have omitted this window while AX was answering.
            // Keep the old clock, but retry a changed plan instead of delivering
            // stale failure. Do not commit the policy's one-shot failed state.
            guard mayEnforce, currentSession == spec.nativeWindowVisibilitySessionID,
                  let record = records.first(where: { $0.browserBundleIdentifier == failure.browserBundleIdentifier
                      && $0.browserSessionID == failure.browserSessionID }),
                  let latest = BrowserWindowVisibilityStore().record(browserBundleIdentifier: failure.browserBundleIdentifier,
                      browserSessionID: failure.browserSessionID, intentionSessionID: failure.intentionSessionID),
                  latest.browserProcessIdentity == record.browserProcessIdentity,
                  latest.plan.windows.first(where: { $0.windowID == failure.windowID })
                    == record.plan.windows.first(where: { $0.windowID == failure.windowID }),
                  Self.liveProcessIdentity(record) == record.browserProcessIdentity,
                  let current = Self.currentRules(), current.active, current.isFresh(),
                  current.hideDistractions, current.nativeWindowVisibility,
                  current.startupSessionID == currentSession else { return }
            enforcementPolicy = nextPolicy
            // Keep the exact failure category locally; the user-facing safety
            // message deliberately contains no window titles or browsing data.
            let diagnostic: [String: Any] = [
                "browser": failure.browserBundleIdentifier,
                "windowID": failure.windowID,
                "reason": failure.reason.rawValue,
                "recordedAt": Date().timeIntervalSince1970
            ]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                try? data.write(to: Self.file.deletingLastPathComponent()
                    .appendingPathComponent("browser-enforcement-failure.json"), options: .atomic)
            }
            onEnforcementFailure?(failure)
        } else {
            enforcementPolicy = nextPolicy
        }
        // Plan omission is not a reveal: Add As You Go leaves initial
        // distractions hidden until completion.
    }

    private func minimizeNormalWindow(_ window: WorkspaceWindow?, id: UInt32, pid: pid_t,
                                      record: BrowserWindowVisibilityRecord,
                                      claim: BrowserWindowVisibilityWindow, launched: Date,
                                      owned: Bool) -> BrowserWindowEnforcementPolicy.Outcome {
        let historical = historicalDeferredVisibility(id: id, pid: pid, launched: launched,
            isHidden: (Self.accessibilityWindows[.init(pid: pid, launched: launched, window: id)]
                ?? window.flatMap { Self.element($0, launched: launched) }).flatMap { Self.boolean($0, kAXMinimizedAttribute).value })
        switch historical {
        case .alreadyHidden: return .verifiedMinimized
        case .unresolved: return .unresolved(.minimizeNotConfirmed)
        case .absent, .retired: break
        }
        guard adoptCoverageOwnership(id: id, pid: pid, launched: launched, record: record, claim: claim) else { return .unresolved(.ownershipNotSaved) }
        var owned = (owned && historical != .retired) || entries.contains { $0.pid == pid && $0.launched == launched && $0.window == id
            && $0.browserSessionID == record.browserSessionID && $0.intentionSessionID == record.plan.intentionSessionID && $0.browserWindowID == claim.windowID }
        if let index = entries.firstIndex(where: { $0.pid == pid && $0.launched == launched && $0.window == id && $0.bootstrapEffectID != nil }) {
            let pending = entries[index]
            guard pending.intentionSessionID == record.plan.intentionSessionID,
                  pending.browserSessionID == record.browserSessionID else { return .unresolved(.minimizeNotConfirmed) }
            switch Self.bootstrapDisposition(pending) {
            case .pending: return .unresolved(.minimizeNotConfirmed)
            case .noEffect:
                var next = entries; next.remove(at: index)
                guard Self.save(next) else { return .unresolved(.ownershipNotSaved) }
                entries = next; owned = false
            case .nativeConfirmation: owned = true
            }
        }
        let boundElement = owned ? Self.accessibilityWindows[.init(pid: pid, launched: launched, window: id)] : nil
        guard let element = boundElement ?? window.flatMap({ Self.element($0, launched: launched) }) else {
            if !owned, let window, Self.missingFromSuccessfulAXEnumeration(window),
               prepareFirefoxBootstrap(window, record: record, claim: claim, launched: launched) {
                return .unresolved(.minimizeNotConfirmed)
            }
            return .unresolved(.accessibilityUnavailable)
        }
        let before = Self.boolean(element, kAXMinimizedAttribute)
        if before.value == true {
            guard takeOverBootstrap(pid: pid, launched: launched, id: id) else { return .unresolved(.ownershipNotSaved) }
            return .verifiedMinimized // Unowned user-minimized windows stay unowned.
        }
        guard before.value == false else { return .unresolved(.accessibilityUnavailable) }
        if !owned {
            guard window != nil, Self.isFreshClaim(record, pid: pid, launched: launched),
                  !entries.contains(where: { $0.pid == pid && $0.launched == launched && $0.window == id }) else {
                return .unresolved(.windowIdentityUnavailable)
            }
            entries.append(Entry(pid: pid, launched: launched, bundle: record.browserBundleIdentifier, window: id,
                browserSessionID: record.browserSessionID, intentionSessionID: record.plan.intentionSessionID,
                browserWindowID: claim.windowID, parking: false,
                restorationPolicy: spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: controllerOwnershipID))
            guard Self.save(entries) else { entries.removeLast(); return .unresolved(.ownershipNotSaved) }
        }
        guard mayEnforce else { return .unresolved(.minimizeNotConfirmed) }
        let status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        Self.observe("browserMinimize", pid: pid, window: id, status: status)
        guard Self.boolean(element, kAXMinimizedAttribute).value == true else { return .unresolved(.minimizeNotConfirmed) }
        guard takeOverBootstrap(pid: pid, launched: launched, id: id) else { return .unresolved(.ownershipNotSaved) }
        return .verifiedMinimized
    }

    private func takeOverBootstrap(pid: pid_t, launched: Date, id: UInt32) -> Bool {
        guard let index = entries.firstIndex(where: { $0.pid == pid && $0.launched == launched && $0.window == id && $0.bootstrapEffectID != nil }) else { return true }
        guard Self.bootstrapDisposition(entries[index]) == .nativeConfirmation else { return false }
        var next = entries; next[index].bootstrapEffectID = nil
        guard Self.save(next) else { return false }
        entries = next; return true
    }

    private func prepareFirefoxBootstrap(_ window: WorkspaceWindow, record: BrowserWindowVisibilityRecord,
                                         claim: BrowserWindowVisibilityWindow, launched: Date) -> Bool {
        guard mayEnforce, record.browserBundleIdentifier == "org.mozilla.firefox", ["normal", "maximized"].contains(claim.state),
              AXIsProcessTrusted(), Self.isFreshClaim(record, pid: window.pid, launched: launched),
              !WorkspaceWindow.list().contains(where: { $0.id == window.id && $0.pid == window.pid }),
              !entries.contains(where: { $0.pid == window.pid && $0.launched == launched && $0.window == window.id }),
              let latest = BrowserWindowVisibilityStore().record(browserBundleIdentifier: record.browserBundleIdentifier,
                  browserSessionID: record.browserSessionID, intentionSessionID: record.plan.intentionSessionID),
              latest.plan == record.plan, latest.browserProcessIdentity == record.browserProcessIdentity,
              !latest.bootstrapEffects.contains(where: { $0.descriptor.windowID == claim.windowID }) else { return false }
        let effect = BrowserWindowMinimizeBootstrap(nativeWindowID: window.id, planRevision: record.plan.revision,
            expiresAtUnixMS: Date().timeIntervalSince1970 * 1000 + 2_500, descriptor: claim)
        let entry = Entry(pid: window.pid, launched: launched, bundle: record.browserBundleIdentifier, window: window.id,
            browserSessionID: record.browserSessionID, intentionSessionID: record.plan.intentionSessionID,
            browserWindowID: claim.windowID, parking: false, bootstrapEffectID: effect.effectID,
            restorationPolicy: spec.hiddenWorkspaceRestorationOnStop, controllerOwnershipID: controllerOwnershipID)
        entries.append(entry)
        guard Self.save(entries) else { entries.removeLast(); return false }
        func discardUnpublishedEntry() {
            let next = entries.filter { $0.bootstrapEffectID != effect.effectID }
            // Only this new, definitely unpublished entry can be retired. A
            // failed journal save retains its in-memory recovery ownership.
            if Self.save(next) { entries = next }
        }
        return BrowserWindowBootstrapRecovery.publishAfterJournal(mayEnforce: { self.mayEnforce }, publish: {
            try BrowserWindowVisibilityStore().prepareBootstrap(effect, for: latest)
        }, retireUnpublished: discardUnpublishedEntry)
    }

    private static func bootstrapDisposition(_ entry: Entry) -> BrowserWindowMinimizeBootstrap.Disposition {
        guard let effectID = entry.bootstrapEffectID, let profile = entry.browserSessionID,
              let intention = entry.intentionSessionID, let native = entry.window,
              let browserWindow = entry.browserWindowID else { return .pending }
        let record = BrowserWindowVisibilityStore().record(browserBundleIdentifier: entry.bundle,
            browserSessionID: profile, intentionSessionID: intention)
        return BrowserWindowBootstrapRecovery.disposition(record: record, browser: entry.bundle,
            profile: profile, intention: intention,
            process: .init(pid: entry.pid, launched: entry.launched.timeIntervalSinceReferenceDate),
            effectID: effectID, nativeWindowID: native, browserWindowID: browserWindow)
    }

    private static func cancelPreparedBootstrap(_ entry: Entry) {
        guard let effect = entry.bootstrapEffectID, let profile = entry.browserSessionID, let intention = entry.intentionSessionID else { return }
        try? BrowserWindowVisibilityStore().cancelPreparedBootstrap(effectID: effect, browserBundleIdentifier: entry.bundle,
            browserSessionID: profile, intentionSessionID: intention,
            browserProcessIdentity: .init(pid: entry.pid, launched: entry.launched.timeIntervalSinceReferenceDate))
    }

    /// Generic nil AX lookup is insufficient: permission errors and ambiguous
    /// matches must not grant a browser effect. Every enumerated AX window must
    /// be readable and this uniquely CG-bound target must be absent.
    private static func missingFromSuccessfulAXEnumeration(_ window: WorkspaceWindow) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let inventory = PublicAccessibilityWindowInventory.readObservation(pid: window.pid,
            deadline: ProcessInfo.processInfo.systemUptime + 0.25),
              !inventory.primaryWasSupplemented, !inventory.primaryWindows.isEmpty else { return false }
        // Only the original primary enumeration can supply this negative
        // evidence. Newly discovered public roots prove it was incomplete.
        let elements = inventory.primaryWindows
        for element in elements {
            guard let title = value(element, kAXTitleAttribute) as? String,
                  let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return false }
            if BrowserWindowMatching.sameWindowTitle(title, window.title), abs(point.x - window.frame.minX) <= 3,
               abs(point.y - window.frame.minY) <= 3, abs(dimensions.width - window.frame.width) <= 3,
               abs(dimensions.height - window.frame.height) <= 3 { return false }
        }
        return true
    }

    private static func liveProcessIdentity(_ record: BrowserWindowVisibilityRecord) -> BrowserProcessIdentity? {
        guard let proof = record.browserProcessIdentity, proof.isValid, kill(proof.pid, 0) == 0,
              let app = NSRunningApplication(processIdentifier: proof.pid), !app.isTerminated,
              app.bundleIdentifier == record.browserBundleIdentifier, let launched = app.intentVisibilityLaunchDate else { return nil }
        return .init(pid: proof.pid, launched: launched.timeIntervalSinceReferenceDate)
    }

    private static func currentRules() -> ActiveBrowserRules? {
        guard let data = try? Data(contentsOf: ActiveBrowserRulesStore.defaultFileURL()) else { return nil }
        return try? JSONDecoder().decode(ActiveBrowserRules.self, from: data)
    }
    private static func recoveryRecords(entries: [Entry]) -> [BrowserWindowVisibilityRecord] {
        let store = BrowserWindowVisibilityStore()
        var seen: Set<URL> = []
        return entries.compactMap { entry in
            guard entry.parking == true, let browserSession = entry.browserSessionID,
                  let session = entry.intentionSessionID else { return nil }
            let file = store.fileURL(browserBundleIdentifier: entry.bundle, browserSessionID: browserSession,
                intentionSessionID: session)
            guard seen.insert(file).inserted else { return nil }
            return store.record(browserBundleIdentifier: entry.bundle, browserSessionID: browserSession,
                intentionSessionID: session)
        }
    }
    private static func matches(records: [BrowserWindowVisibilityRecord], windows: [WorkspaceWindow]) -> [BrowserWindowVisibilityMatching.Match] {
        BrowserWindowVisibilityMatching.matches(records: records, candidates: windows.map {
            .init(id: $0.id, pid: $0.pid, bundle: $0.bundle, title: $0.title, frame: $0.frame)
        })
    }
    private static func captureParking(records: [BrowserWindowVisibilityRecord], entries: [Entry],
                                       restorationPolicy: HiddenWorkspaceRestorationPolicy, controllerOwnershipID: String) -> [Entry] {
        var result = entries
        for match in matches(records: records, windows: WorkspaceWindow.list(onScreen: false)) where match.isParking {
            guard let app = NSRunningApplication(processIdentifier: match.candidate.pid),
                  app.bundleIdentifier == match.record.browserBundleIdentifier, let launched = app.intentVisibilityLaunchDate else { continue }
            result = captureParkingMatch(match, launched: launched, entries: result,
                restorationPolicy: restorationPolicy, controllerOwnershipID: controllerOwnershipID)
        }
        return result
    }
    private static func captureParkingMatch(_ match: BrowserWindowVisibilityMatching.Match, launched: Date, entries: [Entry],
                                            restorationPolicy: HiddenWorkspaceRestorationPolicy, controllerOwnershipID: String) -> [Entry] {
        guard !match.record.closedParkingWindowIDs.contains(match.window.windowID) else { return entries }
        var result = entries
        if let previous = entries.first(where: { $0.pid == match.candidate.pid && $0.launched == launched && $0.window == match.candidate.id }) {
            // Do not transfer a native identity between profile-local claims.
            guard previous.parking == true, previous.browserSessionID == match.record.browserSessionID,
                  previous.intentionSessionID == match.record.plan.intentionSessionID,
                  previous.browserWindowID == match.window.windowID else { return entries }
        } else {
            guard isFreshClaim(match.record, pid: match.candidate.pid, launched: launched) else { return entries }
            // A capture receipt with no remaining native ownership means this
            // exact holding window was already restored/closed, not a new claim.
            if BrowserWindowVisibilityStore().capturedWindowIDs(for: match.record).contains(match.window.windowID) { return entries }
            result.append(Entry(pid: match.candidate.pid, launched: launched, bundle: match.candidate.bundle,
                window: match.candidate.id, browserSessionID: match.record.browserSessionID,
                intentionSessionID: match.record.plan.intentionSessionID, browserWindowID: match.window.windowID, parking: true,
                restorationPolicy: restorationPolicy, controllerOwnershipID: controllerOwnershipID))
        }
        // Host ACK is not granted until this native identity is durably owned.
        // A failed receipt write is retried from the retained journal on refresh.
        guard save(result) else { return entries }
        let receipt = BrowserWindowVisibilityCaptureReceipt(browserBundleIdentifier: match.record.browserBundleIdentifier,
            browserSessionID: match.record.browserSessionID, intentionSessionID: match.record.plan.intentionSessionID,
            windowIDs: [match.window.windowID])
        _ = try? BrowserWindowVisibilityStore().writeCaptureReceipt(receipt)
        return result
    }
    private static func isFreshClaim(_ record: BrowserWindowVisibilityRecord, pid: pid_t, launched: Date) -> Bool {
        let age = Date().timeIntervalSince(record.receivedAt)
        guard age >= -1 && age <= 30 && launched <= record.receivedAt else { return false }
        // New hosts attest their verified browser ancestor. Never bind another
        // same-bundle process just because its window title and frame match.
        // Decode compatibility is not new ownership authority. This bridge's
        // first production release always requires a verified host process.
        guard let proof = record.browserProcessIdentity else { return false }
        return proof.pid == pid && proof.launched == launched.timeIntervalSinceReferenceDate
    }
    private static func parkingDisposition(_ entry: Entry, record: BrowserWindowVisibilityRecord?) -> BrowserWindowVisibilityRestorationPolicy.Disposition {
        guard let record else { return .retain }
        return BrowserWindowVisibilityRestorationPolicy.parkingDisposition(
            expectedIdentity: .init(pid: entry.pid, launched: entry.launched.timeIntervalSinceReferenceDate),
            expectedBundleIdentifier: entry.bundle, browserSessionID: entry.browserSessionID,
            intentionSessionID: entry.intentionSessionID, browserWindowID: entry.browserWindowID,
            nativeWindowID: entry.window, isParking: entry.parking == true, record: record)
    }
    private static func latestParkingDisposition(_ entry: Entry) -> BrowserWindowVisibilityRestorationPolicy.Disposition {
        guard let profile = entry.browserSessionID, let intention = entry.intentionSessionID else { return .retain }
        return parkingDisposition(entry, record: BrowserWindowVisibilityStore().record(
            browserBundleIdentifier: entry.bundle, browserSessionID: profile, intentionSessionID: intention))
    }

    private static func loadEntries() -> [Entry] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    @discardableResult private static func save(_ entries: [Entry]) -> Bool {
        if loadEntries() == entries && FileManager.default.fileExists(atPath: file.path) { return true }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }
    private static func restore(parkingOnly: Bool = false) -> [Entry] {
        let entries = loadEntries()
        let records = recoveryRecords(entries: entries)
        // Retire browser-confirmed closures before any CG/AX lookup. Chrome can
        // retain a native CG window after its extension window ID is gone.
        let remaining = entries.filter { entry in
            !records.contains { record in
                parkingDisposition(entry, record: record) == .discard
            }
        }
        if !entries.isEmpty && remaining.isEmpty {
            guard save([]) else { return entries }
            accessibilityWindows.removeAll()
            return []
        }
        // Restoration resolves exact owned native identities, including small
        // real dialogs. The overview's presentation-size filter is not an
        // ownership/lifetime inventory and cannot drop these journal entries.
        let restorationRows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        var pending: [Entry] = []
        let rules = currentRules()
        let activeSession = rules.flatMap { $0.active && $0.isFresh() ? $0.startupSessionID : nil }
        for entry in remaining {
            let historicalBootstrap = entry.bootstrapEffectID != nil && entry.intentionSessionID != activeSession
            if parkingOnly && entry.parking != true && !historicalBootstrap { pending.append(entry); continue }
            // AppKit can temporarily lack an application or its launch metadata.
            // Only positive death/reuse evidence may discard durable ownership.
            let app = NSRunningApplication(processIdentifier: entry.pid)
            let observed = app?.intentVisibilityLaunchDate.map {
                BrowserProcessIdentity(pid: entry.pid, launched: $0.timeIntervalSinceReferenceDate)
            }
            let processState: BrowserWindowVisibilityRestorationPolicy.ProcessState
            if entry.pid <= 0 {
                processState = .unknown
            } else if kill(entry.pid, 0) == 0 {
                processState = .running(identity: observed, bundleIdentifier: app?.bundleIdentifier)
            } else {
                processState = errno == ESRCH ? .missing : .unknown
            }
            switch BrowserWindowVisibilityRestorationPolicy.disposition(
                expectedIdentity: .init(pid: entry.pid, launched: entry.launched.timeIntervalSinceReferenceDate),
                expectedBundleIdentifier: entry.bundle, processState: processState) {
            case .discard: continue
            case .retain: pending.append(entry); continue
            case .restore: break
            }
            guard let app else { pending.append(entry); continue }
            if let id = entry.window {
                switch WorkspaceWindow.exists(id: id, pid: entry.pid) {
                case false?: continue
                case nil: pending.append(entry); continue
                case true?: break
                }
                if entry.bootstrapEffectID != nil {
                    cancelPreparedBootstrap(entry)
                    switch bootstrapDisposition(entry) {
                    case .pending: pending.append(entry); continue
                    case .noEffect: continue
                    case .nativeConfirmation: break
                    }
                }
                if entry.parking == true {
                    switch latestParkingDisposition(entry) {
                    case .discard: continue
                    case .retain: pending.append(entry); continue
                    case .restore: break
                    }
                }
                guard let restorationRows, let windows = nativeWindows(rows: restorationRows, app: app),
                      let window = windows.first(where: { $0.id == id && $0.pid == entry.pid }),
                      let element = element(window, launched: entry.launched) else { pending.append(entry); continue }
                let before = boolean(element, kAXMinimizedAttribute)
                if before.value == false { continue }
                // A late settled effect cannot reveal under a newer policy.
                // The colliding new claim remains unresolved and safety-stops.
                if (entry.bootstrapEffectID != nil || entry.nativeCoverage != nil),
                   !BrowserWindowCoverageEffects.mayRestore(ownershipSessionID: entry.intentionSessionID, activeSessionID: activeSession) {
                    pending.append(entry); continue
                }
                guard before.value == true else {
                    if before.status == .invalidUIElement { accessibilityWindows.removeValue(forKey: .init(pid: entry.pid, launched: entry.launched, window: id)) }
                    pending.append(entry); continue
                }
                guard (entry.restorationPolicy ?? .automatic).action(isHidden: before.value) == .reveal else {
                    pending.append(entry); continue
                }
                if entry.nativeCoverage != nil && entry.parking != true {
                    let restored = BrowserWindowCoverageEffects.restore(ownershipSessionID: entry.intentionSessionID,
                        activeSessionID: activeSession, readMinimized: {
                        boolean(element, kAXMinimizedAttribute).value
                    }, dispatch: {
                        let status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        observe("restore", pid: entry.pid, window: id, status: status)
                        RestorationFocusGuard.preserveAfterOwnedVisibilityChange()
                    })
                    if !restored { pending.append(entry) }
                    RestorationFocusGuard.preserveCurrent()
                    continue
                }
                let status: AXError
                if entry.parking == true {
                    // AX reads can block. Revalidate under the same scoped lock
                    // as closure writes and hold it through bounded dispatch, so
                    // no old reveal can dispatch after a closure was accepted.
                    // LOCK_NB keeps a busy host writer from stalling the app UI.
                    guard let profile = entry.browserSessionID, let intention = entry.intentionSessionID else {
                        pending.append(entry); continue
                    }
                    var disposition: BrowserWindowVisibilityRestorationPolicy.Disposition = .retain
                    var dispatched: AXError?
                    do {
                        try BrowserWindowVisibilityStore().withLockedRecordForRestoration(
                            browserBundleIdentifier: entry.bundle, browserSessionID: profile, intentionSessionID: intention
                        ) { record in
                            disposition = parkingDisposition(entry, record: record)
                            if disposition == .restore {
                                dispatched = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                            }
                        }
                    } catch { pending.append(entry); continue }
                    if disposition == .discard { continue }
                    guard let dispatched else { pending.append(entry); continue }
                    status = dispatched
                } else {
                    status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                observe("restore", pid: entry.pid, window: id, status: status)
                RestorationFocusGuard.preserveAfterOwnedVisibilityChange()
                // Successful dispatch is not completion. A request that timed
                // out may also have completed by the time this read succeeds.
                if boolean(element, kAXMinimizedAttribute).value != false { pending.append(entry) }
            } else {
                func sameLifetime() -> Bool {
                    !app.isTerminated && app.processIdentifier == entry.pid && app.bundleIdentifier == entry.bundle && app.intentVisibilityLaunchDate == entry.launched
                }
                let restored = NativeVisibilityCoverageEffects.restoreWithFallback(isCurrent: sameLifetime, readHidden: {
                    applicationHidden(app, accessibilityHideOwned: entry.accessibilityApplicationHide == true).hidden
                }, shouldReveal: {
                    (entry.restorationPolicy ?? .automatic).action(isHidden: true) == .reveal
                }, dispatchPrimary: {
                    _ = app.unhide()
                    RestorationFocusGuard.preserveAfterOwnedVisibilityChange()
                }, dispatchFallback: {
                    guard sameLifetime() else { return }
                    let element = AXUIElementCreateApplication(entry.pid)
                    guard isSettable(element, kAXHiddenAttribute), sameLifetime() else { return }
                    AXUIElementSetMessagingTimeout(element, 0.025)
                    _ = AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, kCFBooleanFalse)
                    RestorationFocusGuard.preserveAfterOwnedVisibilityChange()
                })
                if !restored { pending.append(entry) }
            }
            RestorationFocusGuard.preserveCurrent()
        }
        // Failed persistence cannot make the watcher forget durable ownership.
        guard save(pending) else { return entries }
        let identities = Set(pending.compactMap { entry in entry.window.map { WindowIdentity(pid: entry.pid, launched: entry.launched, window: $0) } })
        accessibilityWindows = accessibilityWindows.filter { identities.contains($0.key) }
        RestorationFocusGuard.preserveCurrent()
        return pending
    }
    private static func needsRecoveryObservation(_ entries: [Entry], parkingOnly: Bool = false) -> Bool {
        entries.contains {
            (!parkingOnly || $0.parking == true || $0.bootstrapEffectID != nil)
                && ($0.restorationPolicy ?? .automatic).needsRecoveryObservation(isParking: $0.parking == true)
        }
    }
    private static func startRecoveryWatcher(generation: Int, parkingOnly: Bool = false) {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        recoveryFingerprint = planFingerprint()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            guard generation == recoveryGeneration, recoverySource != nil else { return }
            recoveryWork?.cancel()
            let work = DispatchWorkItem {
                guard generation == recoveryGeneration, recoverySource != nil else { return }
                let fingerprint = planFingerprint()
                guard fingerprint != recoveryFingerprint else { return }
                recoveryFingerprint = fingerprint
                let pending = restore(parkingOnly: parkingOnly)
                if !needsRecoveryObservation(pending, parkingOnly: parkingOnly) { stopRecoveryWatcher() }
            }
            recoveryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        recoverySource = source
        source.resume()
        recoveryTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            guard generation == recoveryGeneration, recoverySource != nil else { return }
            let pending = restore(parkingOnly: parkingOnly)
            if !needsRecoveryObservation(pending, parkingOnly: parkingOnly) { stopRecoveryWatcher() }
        }
    }
    private static func stopRecoveryWatcher() {
        recoveryWork?.cancel(); recoveryWork = nil
        recoverySource?.cancel(); recoverySource = nil
        if let observer = recoveryTerminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        recoveryTerminationObserver = nil
        recoveryFingerprint = []
    }
    private static func planFingerprint() -> [String] {
        let directory = file.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        // Browser snapshots/heartbeats also reveal a closed holding window after
        // a long tab restore, even if its last durable plan is unchanged. Never
        // wake on our own journal/diagnostics and never add an idle polling loop.
        return files.filter {
            let name = $0.lastPathComponent
            return $0.pathExtension == "json" && (name.hasPrefix("browser-window-visibility-") ||
                name.hasPrefix("browser-tabs-") || name.hasPrefix("browser-guard-heartbeat"))
        }.map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(file.lastPathComponent):\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0):\(values?.fileSize ?? 0)"
        }.sorted()
    }
    private static func observe(_ action: String, pid: pid_t, window: UInt32, status: AXError) {
        guard diagnosticEvents.count < 80 else { return }
        diagnosticEvents.append(["action": action, "pid": pid, "window": window, "status": status.rawValue])
        let url = file.deletingLastPathComponent().appendingPathComponent("window-visibility-diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: diagnosticEvents) { try? data.write(to: url, options: .atomic) }
    }
    private static func boolean(_ element: AXUIElement, _ key: String) -> (status: AXError, value: Bool?) {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
        if status == .invalidUIElement {
            accessibilityWindows = accessibilityWindows.filter { !CFEqual($0.value, element) }
        }
        return (status, status == .success ? result as? Bool : nil)
    }
    private static func applicationHidden(_ app: NSRunningApplication, accessibilityHideOwned: Bool) -> (hidden: Bool?, status: AXError) {
        if app.isHidden { return (true, .success) }
        let observed = boolean(AXUIElementCreateApplication(app.processIdentifier), kAXHiddenAttribute)
        return (NativeVisibilityCoveragePolicy.applicationHidden(nativeHidden: false, accessibilityHidden: observed.value,
            accessibilityHideOwned: accessibilityHideOwned), observed.status)
    }
    private static func isSettable(_ element: AXUIElement, _ key: String) -> Bool {
        settable(element, key).value == true
    }
    private static func settable(_ element: AXUIElement, _ key: String) -> (status: AXError, value: Bool?) {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, key as CFString, &settable)
        return (status, status == .success ? settable.boolValue : nil)
    }
    private static func diagnosticAXType(_ value: String?) -> String {
        guard let value, value.hasPrefix("AX"), value.count <= 64,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return "unknown" }
        return value
    }
    private static func sameFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 3 && abs(first.minY - second.minY) <= 3
            && abs(first.width - second.width) <= 3 && abs(first.height - second.height) <= 3
    }
    /// Positive public AX roots include dialogs and readable minimized windows.
    /// This is not proof that every native window was exposed: callers retain
    /// unmatched native obligations even after successful AX enumeration.
    private static func completeAccessibilityWindows(pid: pid_t, deadline: TimeInterval, detail: inout [String: Any],
                                                      requiresPrimaryEnumeration: Bool = false) -> [AccessibleNativeWindow]? {
        guard let inventory = PublicAccessibilityWindowInventory.readObservation(pid: pid, deadline: deadline) else {
            detail["geometryFailureStage"] = "publicWindowsInventory"; return nil
        }
        // Classification supplies negative absence evidence, unlike exact
        // positive bindings. Never let supplemental roots earn that authority.
        guard !requiresPrimaryEnumeration || !inventory.primaryWasSupplemented else {
            detail["geometryFailureStage"] = "primaryWindowsOmittedExposedRoot"; return nil
        }
        let elements = requiresPrimaryEnumeration ? inventory.primaryWindows : inventory.windows
        var windows: [AccessibleNativeWindow] = []
        for (index, element) in elements.enumerated() {
            guard let window = accessibleWindow(element, pid: pid, deadline: deadline, detail: &detail) else {
                detail["geometryFailureIndex"] = index; detail["geometryInventoryCount"] = elements.count; return nil
            }
            windows.append(window)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { detail["geometryFailureStage"] = "deadline"; return nil }
        return windows
    }
    private static func accessibleWindow(_ element: AXUIElement, pid: pid_t, deadline: TimeInterval,
                                         detail: inout [String: Any]) -> AccessibleNativeWindow? {
        func fail(_ stage: String, status: AXError? = nil) -> AccessibleNativeWindow? {
            detail["geometryFailureStage"] = stage
            if let status { detail["geometryFailureStatus"] = status.rawValue }
            return nil
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("deadline") }
        var elementPID: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &elementPID)
        guard pidStatus == .success, elementPID == pid else { return fail("processIdentity", status: pidStatus) }
        let role = attribute(element, kAXRoleAttribute)
        detail["geometryRole"] = diagnosticAXType(role.value as? String)
        guard let roleValue = role.value as? String, roleValue == kAXWindowRole else { return fail("role", status: role.status) }
        let subrole = attribute(element, kAXSubroleAttribute)
        detail["geometrySubrole"] = diagnosticAXType(subrole.value as? String)
        guard let subroleValue = subrole.value as? String else { return fail("subrole", status: subrole.status) }
        let title = attribute(element, kAXTitleAttribute)
        guard let titleValue = title.value as? String else { return fail("title", status: title.status) }
        let position = attribute(element, kAXPositionAttribute)
        guard let positionValue = position.value, CFGetTypeID(positionValue) == AXValueGetTypeID() else { return fail("position", status: position.status) }
        let size = attribute(element, kAXSizeAttribute)
        guard let sizeValue = size.value, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return fail("size", status: size.status) }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &dimensions),
              NativeVisibilityCoveragePolicy.usableOwnedWindowGeometry(x: Double(point.x), y: Double(point.y),
                  width: Double(dimensions.width), height: Double(dimensions.height)) else { return fail("geometry") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("deadline") }
        return .init(element: element, role: roleValue, subrole: subroleValue, title: titleValue, frame: CGRect(origin: point, size: dimensions))
    }
    private static func validServerIdentities(_ rows: [[String: Any]]) -> Bool {
        var identities: [(pid: Int32, windowID: UInt32)] = []
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t else { return false }
            identities.append((pid: pid, windowID: id))
        }
        return NativeVisibilityCoveragePolicy.serverIdentitiesAreComplete(identities)
    }
    private static func nativeWindows(rows: [[String: Any]], app: NSRunningApplication) -> [WorkspaceWindow]? {
        guard validServerIdentities(rows), let bundle = app.bundleIdentifier else { return nil }
        var result: [WorkspaceWindow] = []
        for row in rows where row[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier {
            guard let layer = row[kCGWindowLayer as String] as? Int else { return nil }
            guard layer == 0 else { continue }
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  NativeVisibilityCoveragePolicy.usableOwnedWindowGeometry(x: Double(frame.minX), y: Double(frame.minY),
                    width: Double(frame.width), height: Double(frame.height)) else { return nil }
            result.append(.init(id: id, pid: app.processIdentifier, bundle: bundle, title: row[kCGWindowName as String] as? String ?? "", frame: frame))
        }
        guard Set(result.map(\.id)).count == result.count else { return nil }
        return result
    }
    private static func nativeBindings(accessible: [AccessibleNativeWindow], native: [WorkspaceWindow]) -> [(AccessibleNativeWindow, WorkspaceWindow)]? {
        var result: [(AccessibleNativeWindow, WorkspaceWindow)] = []
        for window in accessible {
            let matches = native.filter { $0.title == window.title && sameFrame($0.frame, window.frame) }
            guard matches.count == 1, !result.contains(where: { $0.1.id == matches[0].id }) else { return nil }
            result.append((window, matches[0]))
        }
        return result
    }
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        attribute(element, key).value
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> (status: AXError, value: CFTypeRef?) {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
        return (status, status == .success ? result : nil)
    }
    private static func element(_ window: WorkspaceWindow, launched: Date) -> AXUIElement? {
        let identity = WindowIdentity(pid: window.pid, launched: launched, window: window.id)
        if let cached = accessibilityWindows[identity] { return cached }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated,
              app.bundleIdentifier == window.bundle, app.intentVisibilityLaunchDate == launched,
              let elements = PublicAccessibilityWindowInventory.read(pid: window.pid, deadline: deadline),
              let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let native = nativeWindows(rows: rows, app: app) else { return nil }
        func sameTitle(_ first: String, _ second: String) -> Bool {
            browsers.contains(window.bundle) ? BrowserWindowMatching.sameWindowTitle(first, second) : first == second
        }
        var matches: [AXUIElement] = []
        for element in elements {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let title = value(element, kAXTitleAttribute) as? String else { return nil }
            guard sameTitle(title, window.title) else { continue }
            guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
            let frame = CGRect(origin: point, size: dimensions)
            guard sameFrame(frame, window.frame) else { continue }
            let counterparts = native.filter { sameTitle(title, $0.title) && sameFrame(frame, $0.frame) }
            guard counterparts.count == 1, counterparts[0].id == window.id else { return nil }
            matches.append(element)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, matches.count == 1,
              !app.isTerminated, app.intentVisibilityLaunchDate == launched, app.bundleIdentifier == window.bundle else { return nil }
        accessibilityWindows[identity] = matches[0]
        return matches[0]
    }
}
