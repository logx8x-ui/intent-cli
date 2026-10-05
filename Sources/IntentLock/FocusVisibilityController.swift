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
    }
    private struct WindowIdentity: Hashable {
        var pid: pid_t
        var launched: Date
        var window: UInt32
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
    private let visibilityCache: BrowserWindowVisibilityRecordCache?
    private var enforcementPolicy: BrowserWindowEnforcementPolicy?
    /// Main-thread callback. Parking capture receipts are intentionally separate.
    public var onCoverageFailure: ((BrowserWindowCoveragePolicy.Failure) -> Void)?
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
        initialCoverageReady = coverageStates.values.allSatisfy { $0.cohort.initialResolved }
        coverageReadyLock.unlock()
    }
    public init(spec: FocusSessionSpec) {
        self.spec = spec
        for coverage in spec.browserWindowCoverage where spec.hideDistractions && spec.requiresEnforcement {
            coverageStates[coverage.browserBundleIdentifier] = CoverageState(coverage, observation: spec.browserCoverageObservations[coverage.browserBundleIdentifier], allowsLater: spec.coverageAllowsLaterWindows)
        }
        initialCoverageReady = coverageStates.values.allSatisfy { $0.cohort.initialResolved }
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
            entries = Self.restore()
            guard spec.hideDistractions && spec.requiresEnforcement, !stopped, timer == nil else {
                if entries.contains(where: { $0.parking == true || $0.bootstrapEffectID != nil }) {
                    Self.startRecoveryWatcher(generation: Self.recoveryGeneration, parkingOnly: true)
                }
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop() {
        onMain {
            guard !stopped else { return }
            enforcementPolicy?.stop()
            for entry in Self.loadEntries() where entry.intentionSessionID == spec.nativeWindowVisibilitySessionID {
                Self.cancelPreparedBootstrap(entry)
            }
            // Capture registrations even when finish beats the next refresh.
            if started, let visibilityCache {
                entries = Self.captureParking(records: visibilityCache.records(forceRefresh: true), entries: Self.loadEntries())
            }
            stopped = true
            timer?.cancel(); timer = nil
            guard started else { return }
            entries = Self.beginRecovery()
        }
    }
    public static func restoreInterruptedSession() {
        if Thread.isMainThread { _ = beginRecovery() }
        else { DispatchQueue.main.sync { _ = beginRecovery() } }
    }
    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }

    @discardableResult private static func beginRecovery() -> [Entry] {
        recoveryGeneration &+= 1
        stopRecoveryWatcher()
        let generation = recoveryGeneration
        let saved = loadEntries()
        var restoringPIDs = Set(saved.map(\.pid))
        // Browser Guard restores parked tabs after the shared rules clear.
        for app in NSWorkspace.shared.runningApplications where
            ["org.mozilla.firefox", "com.google.Chrome"].contains(app.bundleIdentifier ?? "") {
            restoringPIDs.insert(app.processIdentifier)
        }
        RestorationFocusGuard.begin(restoringPIDs: restoringPIDs)
        // Only bound native ownership can survive finish. Uncaptured holding
        // windows have not been ACKed, so JS has not moved any user tabs there.
        if !saved.isEmpty { startRecoveryWatcher(generation: generation) }
        let pending = restore()
        RestorationFocusGuard.preserveCurrent()
        if !pending.isEmpty { retryRecovery(generation: generation, attempts: 4) }
        if pending.isEmpty { stopRecoveryWatcher() }
        return pending
    }
    private static func retryRecovery(generation: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard generation == recoveryGeneration else { return }
            // unhide() may report false while the visibility request is still in flight.
            // Re-read macOS state before discarding ownership, or retry if it really failed.
            let pending = restore()
            if !pending.isEmpty && attempts > 1 {
                retryRecovery(generation: generation, attempts: attempts - 1)
            } else if pending.isEmpty { stopRecoveryWatcher() }
        }
    }

    private func refresh() {
        guard mayEnforce else { return }
        let initialApps = initialVisibilityApplied ? nil : spec.initialAllowedApps
        defer { initialVisibilityApplied = true }
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
        if entries.contains(where: { $0.parking == true || $0.bootstrapEffectID != nil }) {
            entries = Self.restore(parkingOnly: true)
        }
        reconcileBrowserWindows(records: records, windows: windows)
        refreshBrowserCoverage()
        guard mayEnforce else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard mayEnforce else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, let launched = app.launchDate else { continue }
            if !spec.permitsApplication(bundle) || initialApps.map({ !$0.contains(bundle) }) == true {
                guard !app.isHidden else { continue }
                let entry = Entry(pid: app.processIdentifier, launched: launched, bundle: bundle, window: nil)
                if !entries.contains(where: { $0.pid == entry.pid && $0.window == nil }) {
                    entries.append(entry)
                    guard Self.save(entries) else { entries.removeLast(); continue }
                }
                guard mayEnforce else { return }
                _ = app.hide()
            } else {
                for window in windows where coverageStates[bundle] == nil && window.pid == app.processIdentifier && (!spec.permitsWindow(window.id, bundleIdentifier: bundle) || (initialApps != nil && spec.initialSelectedWindows[bundle].map { !$0.contains(window.id) } == true)) {
                    guard mayEnforce else { return }
                    guard !entries.contains(where: { $0.pid == window.pid && $0.window == window.id && ($0.bootstrapEffectID != nil || $0.nativeCoverage == true) }) else { continue }
                    guard let element = Self.element(window, launched: launched), Self.boolean(element, kAXMinimizedAttribute).value == false else { continue }
                    if !entries.contains(where: { $0.pid == window.pid && $0.window == window.id }) {
                        entries.append(Entry(pid: window.pid, launched: launched, bundle: bundle, window: window.id))
                        guard Self.save(entries) else { entries.removeLast(); continue }
                    }
                    guard mayEnforce else { return }
                    _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
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
        guard let app = NSRunningApplication(processIdentifier: identity.pid), let launched = app.launchDate else { return .unresolved }
        if launched.timeIntervalSinceReferenceDate != identity.launched || app.bundleIdentifier != identity.bundleIdentifier { return .closed }
        guard let current = inventory.windows.first(where: { $0.identity == identity }) else {
            return WorkspaceWindow.exists(id: identity.windowID, pid: identity.pid) == false ? .closed : .unresolved
        }
        guard inventory.observedStandard.contains(identity) else { return .unresolved }
        let window = WorkspaceWindow(id: identity.windowID, pid: identity.pid, bundle: identity.bundleIdentifier, title: current.title, frame: current.frame)
        guard let element = Self.element(window, launched: launched) else { return .unresolved }
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
                intentionSessionID: occurrence, parking: false, nativeCoverage: true))
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
                  app.bundleIdentifier == match.record.browserBundleIdentifier, let launched = app.launchDate else { continue }
            entries = Self.captureParkingMatch(match, launched: launched, entries: entries)
        }
        var observations: [BrowserWindowEnforcementPolicy.Observation] = []
        for record in records {
            let liveIdentity = Self.liveProcessIdentity(record)
            for claim in record.plan.windows where !record.closedParkingWindowIDs.contains(claim.windowID) {
                guard mayEnforce else { return }
                var outcome: BrowserWindowEnforcementPolicy.Outcome = .unresolved(.windowIdentityUnavailable)
                if let liveIdentity, liveIdentity == record.browserProcessIdentity {
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
                    observation.record == record && (observation.outcome == .verifiedMinimized || observation.outcome == .noLongerExists)
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
        guard adoptCoverageOwnership(id: id, pid: pid, launched: launched, record: record, claim: claim) else { return .unresolved(.ownershipNotSaved) }
        var owned = owned || entries.contains { $0.pid == pid && $0.launched == launched && $0.window == id
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
                browserWindowID: claim.windowID, parking: false))
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
            browserWindowID: claim.windowID, parking: false, bootstrapEffectID: effect.effectID)
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
        let app = AXUIElementCreateApplication(window.pid)
        guard let elements = value(app, kAXWindowsAttribute) as? [AXUIElement], !elements.isEmpty else { return false }
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
              app.bundleIdentifier == record.browserBundleIdentifier, let launched = app.launchDate else { return nil }
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
    private static func captureParking(records: [BrowserWindowVisibilityRecord], entries: [Entry]) -> [Entry] {
        var result = entries
        for match in matches(records: records, windows: WorkspaceWindow.list(onScreen: false)) where match.isParking {
            guard let app = NSRunningApplication(processIdentifier: match.candidate.pid),
                  app.bundleIdentifier == match.record.browserBundleIdentifier, let launched = app.launchDate else { continue }
            result = captureParkingMatch(match, launched: launched, entries: result)
        }
        return result
    }
    private static func captureParkingMatch(_ match: BrowserWindowVisibilityMatching.Match, launched: Date, entries: [Entry]) -> [Entry] {
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
                intentionSessionID: match.record.plan.intentionSessionID, browserWindowID: match.window.windowID, parking: true))
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
        let windows = WorkspaceWindow.list(onScreen: false)
        var pending: [Entry] = []
        let rules = currentRules()
        let activeSession = rules.flatMap { $0.active && $0.isFresh() ? $0.startupSessionID : nil }
        for entry in remaining {
            let historicalBootstrap = entry.bootstrapEffectID != nil && entry.intentionSessionID != activeSession
            if parkingOnly && entry.parking != true && !historicalBootstrap { pending.append(entry); continue }
            // AppKit can temporarily lack an application or its launch metadata.
            // Only positive death/reuse evidence may discard durable ownership.
            let app = NSRunningApplication(processIdentifier: entry.pid)
            let observed = app?.launchDate.map {
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
                guard let window = windows.first(where: { $0.id == id && $0.pid == entry.pid }),
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
            } else if app.isHidden {
                _ = app.unhide()
                RestorationFocusGuard.preserveAfterOwnedVisibilityChange()
                if app.isHidden { pending.append(entry) }
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
                if parkingOnly ? !pending.contains(where: { $0.parking == true || $0.bootstrapEffectID != nil }) : pending.isEmpty { stopRecoveryWatcher() }
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
            if parkingOnly ? !pending.contains(where: { $0.parking == true || $0.bootstrapEffectID != nil }) : pending.isEmpty { stopRecoveryWatcher() }
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
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private static func element(_ window: WorkspaceWindow, launched: Date) -> AXUIElement? {
        let identity = WindowIdentity(pid: window.pid, launched: launched, window: window.id)
        if let cached = accessibilityWindows[identity] { return cached }
        let app = AXUIElementCreateApplication(window.pid)
        guard let elements = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let matches = elements.filter { element in
            guard let title = value(element, kAXTitleAttribute) as? String,
                  (browsers.contains(window.bundle) ? BrowserWindowMatching.sameWindowTitle(title, window.title) : title == window.title),
                  let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
            var point = CGPoint.zero, dimensions = CGSize.zero
            return AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
                && AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
                && abs(point.x - window.frame.minX) <= 3 && abs(point.y - window.frame.minY) <= 3
                && abs(dimensions.width - window.frame.width) <= 3 && abs(dimensions.height - window.frame.height) <= 3
        }
        guard matches.count == 1 else { return nil }
        accessibilityWindows[identity] = matches[0]
        return matches[0]
    }
}
