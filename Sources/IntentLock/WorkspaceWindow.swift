import AppKit
import ApplicationServices
import IntentCore

/// Public WindowServer IDs stay session-local and are never saved as intentions.
public struct WorkspaceWindow {
    public let id: UInt32
    public let pid: pid_t
    public let bundle: String
    public let title: String
    public let frame: CGRect
    public static func list(onScreen: Bool = true) -> [WorkspaceWindow] {
        let flags: CGWindowListOption = onScreen ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        return list(records: CGWindowListCopyWindowInfo(flags, kCGNullWindowID) as? [[String: Any]] ?? [])
    }
    static func list(records: [[String: Any]]) -> [WorkspaceWindow] {
        records.compactMap { item in
            guard item[kCGWindowLayer as String] as? Int == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 100, frame.height > 80 else { return nil }
            return .init(id: id, pid: pid, bundle: bundle, title: item[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// Closure needs complete identities, not overview preview candidates.
    /// Tiny, minimized and offscreen windows still count; missing process
    /// metadata or a failed WindowServer query means retry, never completion.
    public static func lifetimeInventory(selectedWindows: [String: Set<UInt32>], wholeApps: Set<String>,
        copyInfo: (CGWindowListOption, CGWindowID) -> CFArray? = CGWindowListCopyWindowInfo,
        resolveApplication: (pid_t) -> (bundleIdentifier: String?, isRegular: Bool)? = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
            return (app.bundleIdentifier, app.activationPolicy == .regular)
        }) -> [String: Set<UInt32>]? {
        guard let rows = copyInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var seen: Set<UInt32> = []
        var inventory: [String: Set<UInt32>] = [:]
        let selectedIDs = Set(selectedWindows.values.flatMap { $0 })
        let relevantApps = Set(selectedWindows.keys).union(wholeApps)
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32, id > 0,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid > 0,
                  let layer = row[kCGWindowLayer as String] as? Int,
                  seen.insert(id).inserted else { return nil }
            // A changed or unclassified selected surface is not positive
            // absence, even if it no longer qualifies for an overview card.
            if layer != 0 {
                if selectedIDs.contains(id) { return nil }
                continue
            }
            guard let app = resolveApplication(pid) else { return nil }
            let relevant = selectedIDs.contains(id) || app.bundleIdentifier.map { relevantApps.contains($0) } == true
            guard app.isRegular || relevant else { continue }
            guard let bundle = app.bundleIdentifier, !bundle.isEmpty else { return nil }
            inventory[bundle, default: []].insert(id)
        }
        return inventory
    }

    /// Positive AX standard windows only: CG also contains Chrome auxiliary
    /// backing surfaces. Unreported AX-absent windows are outside this narrowly
    /// observable cohort; the browser bridge still owns all reported windows.
    public struct CoverageObservation: @unchecked Sendable {
        public let inventory: BrowserWindowCoveragePolicy.Inventory
        public let continuousIdentities: Set<BrowserWindowCoveragePolicy.NativeIdentity>
        public let observedAt: TimeInterval
        public let sampledAt: TimeInterval
        fileprivate let anchors: [BrowserWindowCoveragePolicy.NativeIdentity: AXUIElement]
        fileprivate init(inventory: BrowserWindowCoveragePolicy.Inventory,
                         continuousIdentities: Set<BrowserWindowCoveragePolicy.NativeIdentity>, sampledAt: TimeInterval,
                         anchors: [BrowserWindowCoveragePolicy.NativeIdentity: AXUIElement]) {
            self.inventory = inventory; self.continuousIdentities = continuousIdentities
            self.anchors = anchors; self.sampledAt = sampledAt; observedAt = ProcessInfo.processInfo.systemUptime
        }
        func element(for identity: BrowserWindowCoveragePolicy.NativeIdentity) -> AXUIElement? { anchors[identity] }
        var bindings: [(BrowserWindowCoveragePolicy.NativeIdentity, AXUIElement)] { anchors.map { ($0.key, $0.value) } }
    }
    public static func browserCoverageInventory(bundleIdentifier: String, deadline: TimeInterval? = nil) -> BrowserWindowCoveragePolicy.Inventory? {
        browserCoverageObservation(bundleIdentifier: bundleIdentifier, deadline: deadline)?.inventory
    }
    public static func browserCoverageObservation(bundleIdentifier: String, deadline: TimeInterval? = nil,
                                                 prior: CoverageObservation? = nil) -> CoverageObservation? {
        let sampledAt = ProcessInfo.processInfo.systemUptime
        return browserCoverageObservation(bundleIdentifier: bundleIdentifier,
            rows: CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
            sampledAt: sampledAt, deadline: deadline, prior: prior)
    }
    private static func browserCoverageObservation(bundleIdentifier: String, rows: [[String: Any]]?, sampledAt: TimeInterval,
                                           deadline: TimeInterval? = nil, prior: CoverageObservation? = nil) -> CoverageObservation? {
        func hasTime() -> Bool { deadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? true }
        guard hasTime(), AXIsProcessTrusted(), let rows else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
        var native: [BrowserWindowCoveragePolicy.NativeWindow] = []
        var standard: [BrowserWindowCoveragePolicy.StandardWindow] = []
        var standardElements: [AXUIElement] = []
        var minimizedIndices = Set<Int>()
        func failed(_ stage: String) -> CoverageObservation? {
            let comparisons: [[String: Any]] = standard.enumerated().map { index, row in
                let priorIDs = (prior?.anchors ?? [:]).filter { CFEqual($0.value, standardElements[index]) }.map { $0.key }
                return ["index": index, "minimized": minimizedIndices.contains(index),
                    "priorWindowIDs": priorIDs.map { $0.windowID },
                    "axFrame": [row.frame.minX, row.frame.minY, row.frame.width, row.frame.height],
                    "native": native.filter { priorIDs.contains($0.identity) }.map { item in
                        ["id": item.identity.windowID,
                         "titleMatches": BrowserWindowMatching.sameWindowTitle(item.title, row.title),
                         "frame": [item.frame.minX, item.frame.minY, item.frame.width, item.frame.height]] as [String: Any]
                    }]
            }
            let diagnostic: [String: Any] = ["comparisons": comparisons, "stage": stage, "browser": bundleIdentifier,
                "recordedAt": Date().timeIntervalSince1970, "nativeCount": native.count,
                "standardCount": standard.count, "minimizedCount": minimizedIndices.count,
                "candidateCounts": standard.map { BrowserWindowCoveragePolicy.candidates($0, native: native).count }]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                try? data.write(to: ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent()
                    .appendingPathComponent("browser-native-observation-failure.json"), options: .atomic)
            }
            return nil
        }
        for app in apps {
            guard hasTime(), let launched = app.launchDate else { return nil }
            let proof = BrowserProcessIdentity(pid: app.processIdentifier, launched: launched.timeIntervalSinceReferenceDate)
            for row in rows where row[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
                && row[kCGWindowLayer as String] as? Int == 0 {
                guard hasTime(), let id = row[kCGWindowNumber as String] as? UInt32,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), BrowserWindowCoveragePolicy.validFrame(frame) else { return nil }
                native.append(.init(identity: .init(bundleIdentifier: bundleIdentifier, pid: proof.pid, launched: proof.launched, windowID: id),
                    title: row[kCGWindowName as String] as? String ?? "", frame: frame))
            }
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                guard hasTime() else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.025)
                var result: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
            }
            guard let elements = PublicAccessibilityWindowInventory.read(pid: proof.pid,
                deadline: min(deadline ?? ProcessInfo.processInfo.systemUptime + 0.25,
                              ProcessInfo.processInfo.systemUptime + 0.25)) else { return failed("window-enumeration") }
            for element in elements {
                guard hasTime(), let role = attribute(element, kAXRoleAttribute) as? String,
                      let subrole = attribute(element, kAXSubroleAttribute) as? String else { return failed("window-role") }
                guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else { continue }
                var elementPID: pid_t = 0
                guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == proof.pid,
                      let minimized = attribute(element, kAXMinimizedAttribute) as? Bool,
                      let title = attribute(element, kAXTitleAttribute) as? String,
                      let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return failed("window-attributes") }
                var point = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                      AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
                if minimized { minimizedIndices.insert(standard.count) }
                standardElements.append(element)
                var row = BrowserWindowCoveragePolicy.StandardWindow(bundleIdentifier: bundleIdentifier,
                    processIdentity: proof, title: title, frame: CGRect(origin: point, size: dimensions))
                if bundleIdentifier == "com.google.Chrome", BrowserWindowCoveragePolicy.candidates(row, native: native).isEmpty {
                    row.internalURL = PublicAccessibilityWindowInventory.chromeProfilePickerURL(in: element,
                        deadline: min(deadline ?? ProcessInfo.processInfo.systemUptime + 0.08,
                            ProcessInfo.processInfo.systemUptime + 0.08))
                }
                standard.append(row)
            }
        }
        // AX reads and Mission Control animations can overtake the first CG
        // sample. Match against a fresh complete inventory after reading AX.
        guard hasTime(), let currentRows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let visibleRows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              NativeWindowBindingInventory.serverIdentitiesAreComplete(in: currentRows),
              NativeWindowBindingInventory.serverIdentitiesAreComplete(in: visibleRows) else { return failed("post-ax-inventory") }
        native.removeAll()
        for app in apps {
            guard hasTime(), !app.isTerminated, let launched = app.launchDate,
                  let current = NativeWindowBindingInventory.windows(rows: currentRows, pid: app.processIdentifier,
                    bundleIdentifier: bundleIdentifier, requireUsableGeometry: false),
                  current.allSatisfy({ BrowserWindowCoveragePolicy.validFrame($0.frame) }) else { return failed("post-ax-process") }
            for window in current {
                native.append(.init(identity: .init(bundleIdentifier: bundleIdentifier, pid: window.pid,
                    launched: launched.timeIntervalSinceReferenceDate, windowID: window.id), title: window.title, frame: window.frame))
            }
        }
        let offscreen = Set(native.filter {
            NativeWindowBindingInventory.isOffscreen(windowID: $0.identity.windowID, pid: $0.identity.pid,
                allRows: currentRows, onScreenRows: visibleRows) == true
        }.map(\.identity))
        // CFEqual compares the same live accessible object, not its title or
        // frame. Only packets created by a previous successful bidirectional
        // match may anchor a row; the general AX cache is not this authority.
        guard hasTime(), let pinned = BrowserWindowCoveragePolicy.continuingAnchors(native: native, standard: standard,
            previous: prior?.anchors ?? [:], current: standardElements, minimizedIndices: minimizedIndices,
            offscreenIdentities: offscreen, equal: { CFEqual($0, $1) }) else { return failed("window-continuity") }
        guard hasTime(), let identities = BrowserWindowCoveragePolicy.standardIdentityBindings(native: native, standard: standard,
            anchors: pinned, minimizedIndices: minimizedIndices, offscreenIdentities: offscreen) else { return failed("window-identity") }
        let anchors = Dictionary(uniqueKeysWithValues: zip(identities, standardElements))
        return .init(inventory: .init(windows: native, observedStandard: Set(identities)),
            continuousIdentities: Set(pinned.values), sampledAt: sampledAt, anchors: anchors)
    }

    /// A lifetime probe, not a presentation query. Restoration can temporarily
    /// move a live window off screen; that must not be mistaken for closure.
    /// nil means WindowServer could not answer, so a bounded caller can retry.
    public static func exists(id: UInt32, pid: pid_t,
        copyInfo: (CGWindowListOption, CGWindowID) -> CFArray? = CGWindowListCopyWindowInfo) -> Bool? {
        guard let records = copyInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return records.contains {
            $0[kCGWindowNumber as String] as? UInt32 == id &&
                $0[kCGWindowOwnerPID as String] as? pid_t == pid
        }
    }

    public static func focused() -> WorkspaceWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let candidates = list().filter { $0.pid == app.processIdentifier }
        // Outline/blur workers call this too. Never make a synchronous AX
        // request into our own SwiftUI while its field editor is changing.
        // WindowServer ordering is sufficient for our own foreground window.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return candidates.first }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.03)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            let focused = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(focused, 0.03)
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String {
                let matches = candidates.filter { $0.title == title }
                if matches.count == 1 { return matches[0] }
            }
        }
        // WindowServer order is front to back; only use a visible window of
        // the actual foreground application, never an arbitrary background app.
        return candidates.first
    }
    public static func raise(ids: Set<UInt32>, bundle: String, actionGate: DeferredSessionActionGate? = nil,
                             expectedDesktopGeneration: UInt64? = nil) -> Bool {
        func desktopIsCurrent() -> Bool {
            guard let expectedDesktopGeneration else { return true }
            let desktop = DesktopSessionAvailability.snapshot
            return desktop.state != .secured && desktop.generation == expectedDesktopGeneration
        }
        guard desktopIsCurrent(),
              let target = list(onScreen: false).first(where: { ids.contains($0.id) && $0.bundle == bundle }),
              let app = NSRunningApplication(processIdentifier: target.pid),
              let identity = PermittedWindowBinding.identity(window: target, app: app),
              let binding = PermittedWindowBinding.resolve(identity), desktopIsCurrent() else { return false }
        return PermittedWindowRecoveryPolicy.restore(perform: { effect in
            if let actionGate {
                return actionGate.perform(ifCurrent: 0) { desktopIsCurrent() && effect() }
            }
            return desktopIsCurrent() && effect()
        }, validate: {
            desktopIsCurrent() && ids.contains(identity.windowID) && identity.bundleIdentifier == bundle
                && binding.isLive() && desktopIsCurrent()
        }, setMain: {
            guard desktopIsCurrent() else { return }
            AXUIElementSetAttributeValue(binding.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }, raise: {
            desktopIsCurrent() && AXUIElementPerformAction(binding.element, kAXRaiseAction as CFString) == .success
        }, activationTargetCurrent: { binding.isMainWindow() },
            activate: { desktopIsCurrent() && app.activate(options: []) }) == .restored
    }
}

/// Mouse-transparent borders on the desktop and Dock's native Mission Control
/// tiles. AX discovery is bounded and runs off the input/main threads.
public final class WorkspaceOutlineController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "intent.workspace-outlines", qos: .utility)
    private let mutex = NSLock()
    private var selection = QuickSelection()
    private var preserveBehindIntentPanels = false
    private var timer: DispatchSourceTimer?
    private var revision = 0
    private struct SnapshotState {
        var context = ""
        var request: WorkspaceOutlineInventory.Request?
        var continuity = WorkspaceOutlineInventory.Continuity()
        var refreshBudget = WorkspaceOutlineInventory.RefreshBudget()
        var observedOwners: [BrowserTabSnapshot]?
    }
    private var snapshotStates: [String: SnapshotState] = [:] // worker queue only
    private var diagnosticsSignature = "" // worker queue only
    private var tabContinuity: [UInt32: TabBlurContinuity] = [:] // worker queue only
    private var missionContinuity = MissionControlOutline.Continuity() // worker queue only
    private var panels: [NSPanel] = [] // main queue only
    private var scanCache: [UInt32: (key: String, at: Date, regions: [CGRect])] = [:] // worker queue
    public init() {}
    public func update(_ selection: QuickSelection, preserveBehindIntentPanels: Bool = false) {
        mutex.lock()
        self.selection = selection
        self.preserveBehindIntentPanels = preserveBehindIntentPanels
        revision += 1
        mutex.unlock()
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.35)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func stop() {
        timer?.cancel(); timer = nil
        mutex.lock(); revision += 1; selection = QuickSelection(); preserveBehindIntentPanels = false; mutex.unlock()
        queue.async { [weak self] in
            self?.snapshotStates.removeAll(); self?.scanCache.removeAll(); self?.tabContinuity.removeAll()
            self?.missionContinuity = MissionControlOutline.Continuity()
        }
        DispatchQueue.main.async { [weak self] in self?.panels.forEach { $0.orderOut(nil) }; self?.panels = [] }
    }
    /// Poll our own read-only discovery receipt before issuing its successor.
    /// A forced idle event can overwrite ordinary inventory with [], so that
    /// inventory is never evidence for clearing a staged mark.
    private func inventory(browser: String, selection: QuickSelection, processes: [BrowserProcessIdentity],
                           now: Date) -> (response: WorkspaceOutlineInventory.Response?, phase: String) {
        guard let expected = selection.browserSessionIDs[browser] else { return (nil, "selection-unpinned") }
        let base = BrowserTabSnapshotStore.fileURL(for: browser)
        let owners = BrowserProfileSnapshots.sessions(base: base, now: now)
        let proof = owners.compactMap { owner in owner.browserProcessIdentity.map { "\(owner.browserSessionID ?? ""):\($0.pid):\($0.launched)" } }.sorted()
        let context = "\(expected):\(proof):\(selection.tabs.filter { $0.browser == browser }.map(\.id).sorted())"
        var state = snapshotStates[browser] ?? SnapshotState()
        if state.context != context { state = SnapshotState(); state.context = context }
        let observationsChanged = state.observedOwners.map {
            !WorkspaceOutlineInventory.observationsMatch($0, owners)
        } ?? true
        state.observedOwners = owners
        if observationsChanged {
            // A newer observation (including removal, focus, frame, guard or
            // profile changes) cannot retain an older green while polling.
            state.continuity = WorkspaceOutlineInventory.Continuity()
        }
        var accepted: WorkspaceOutlineInventory.Response?
        var authoritative = false
        var phase = "query-pending"
        if let request = state.request {
            if !request.isCurrent(owners: owners, processes: processes) {
                state.request = nil; authoritative = true; phase = "owner-changed"
            } else {
                let replies = request.owners.compactMap { owner -> BrowserTabSnapshot? in
                    guard let session = owner.browserSessionID,
                          let data = try? Data(contentsOf: BrowserProfileSnapshots.discoveryPartition(base, session: session)) else { return nil }
                    return try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data)
                }
                if let response = request.resolve(replies: replies, current: owners, processes: processes, now: now) {
                    accepted = response; authoritative = true; state.request = nil
                    phase = (response.snapshot.allTabs ?? []).isEmpty ? "confirmed-empty" : "confirmed"
                } else if now.timeIntervalSince(request.requestedAt) >= 2.4 {
                    state.request = nil; phase = "query-timeout"
                }
            }
        }
        if observationsChanged && accepted == nil { state.request = nil }
        if state.request == nil && state.refreshBudget.needsQuery(observationsChanged: observationsChanged, now: now) {
            if let request = WorkspaceOutlineInventory.Request(browser: browser, expectedSession: expected,
                owners: owners, processes: processes, now: now) {
                do {
                    // Reuse the existing read-only presence mailbox. It cannot
                    // replace a pending user activation or preview command.
                    for command in request.commands {
                        let path = BrowserSelectedTabPresenceCheck.commandFileURL(
                            base: BrowserTabCommandStore.fileURL(for: browser), session: command.browserSessionID!)
                        try JSONEncoder().encode(command).write(to: path, options: .atomic)
                    }
                    state.request = request
                    state.refreshBudget.requested(at: now)
                } catch { phase = "query-write-failed" }
            } else { authoritative = true; accepted = nil; phase = "owner-unavailable" }
        }
        let response = state.continuity.update(accepted, context: context, authoritative: authoritative, now: now,
            maxAge: WorkspaceOutlineInventory.RefreshBudget.maximumConfirmedAge)
        snapshotStates[browser] = state
        return (response, phase)
    }
    private func recordDiagnostics(_ values: [String: Any]) {
        let directory = IntentEnvironment.dataDirectory
        guard ProcessInfo.processInfo.environment["INTENT_QA_OUTLINE_DIAGNOSTICS"] == "1"
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("qa-workspace-outline.enabled").path),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let signature = String(data: data, encoding: .utf8), signature != diagnosticsSignature else { return }
        diagnosticsSignature = signature
        try? data.write(to: directory.appendingPathComponent("workspace-outline-diagnostics.json"), options: .atomic)
    }
    private func refresh() {
        mutex.lock()
        let selection = self.selection; let token = revision
        let preserveBehindIntentPanels = self.preserveBehindIntentPanels
        mutex.unlock()
        let windows = WorkspaceWindow.list(onScreen: false)
        var markedRegions: [UInt32: [CGRect]] = [:]
        var markedWindowIDs = Set<UInt32>()
        var selectedTabCounts: [UInt32: Int] = [:]
        var matchedSelectedTabs = Set<QuickSelectionTab>()
        let focused = WorkspaceWindow.focused()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let presentationID = WorkspaceOutlinePresentation.windowID(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ownPID, focusedWindowID: focused?.id,
            topExternalWindowID: preserveBehindIntentPanels
                ? WorkspaceWindow.list().first(where: { $0.pid != ownPID })?.id : nil,
            preserveBehindIntentPanels: preserveBehindIntentPanels)
        // Resolve against current live windows, not a retained rectangle. A
        // hidden/destroyed mark must never float above the next application.
        let front = windows.first(where: { $0.id == presentationID })
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(32, &displayIDs, &displayCount)
        let displayFrames = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
        let overviewVisible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).contains { row in
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return displayFrames.contains { FocusForegroundPolicy.isMissionControlOverlay(
                ownerName: row[kCGWindowOwnerName as String] as? String,
                layer: row[kCGWindowLayer as String] as? Int, bounds: frame, displayBounds: $0) }
        }
        let missionScan = overviewVisible ? MissionControlOutlineScanner.scan(overlayVisible: true)
            : MissionControlOutline.Scan(status: .complete, present: false, dockIdentity: "", tiles: [])
        let selectedBrowsers = Set(selection.tabs.map(\.browser))
        snapshotStates = snapshotStates.filter { selectedBrowsers.contains($0.key) }
        var inventories: [String: WorkspaceOutlineInventory.Response] = [:]
        var browserProcesses: [String: [BrowserProcessIdentity]] = [:]
        var phases: [String: String] = [:]
        var matchedWindows = 0, completedScans = 0, partialScans = 0, contradictedScans = 0
        for browser in selectedBrowsers {
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: browser).compactMap { app -> BrowserProcessIdentity? in
                guard let launch = app.launchDate else { return nil }
                return BrowserProcessIdentity(pid: app.processIdentifier, launched: launch.timeIntervalSinceReferenceDate)
            }
            browserProcesses[browser] = processes
            let result = inventory(browser: browser, selection: selection, processes: processes, now: Date())
            phases[browser] = result.phase
            if let response = result.response { inventories[browser] = response }
        }
        for window in windows {
            if selection.marksNativeWindow(window.id, app: window.bundle) {
                markedWindowIDs.insert(window.id)
                markedRegions[window.id] = [window.frame]
                continue
            }
            guard QuickSelection.browsers.contains(window.bundle),
                  let response = inventories[window.bundle] else { continue }
            let snapshot = response.snapshot
            guard let process = browserProcesses[window.bundle]?.first(where: { $0.pid == window.pid }),
                  selection.browserSessionIDs[window.bundle] == snapshot.browserSessionID,
                  let id = BrowserWindowMatching.match(title: window.title, tabs: response.tabs(for: process), nativeWindowCount: windows.filter { $0.pid == window.pid }.count, frame: window.frame, isFocused: front?.id == window.id) else { continue }
            matchedWindows += 1
            let tabs = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == id }
            let selectedIDs = Set(selection.tabs.filter { $0.browser == window.bundle }.map(\.id))
            let selectedCount = tabs.filter { selectedIDs.contains($0.id) }.count
            guard selectedCount > 0 else { continue }
            markedWindowIDs.insert(window.id)
            selectedTabCounts[window.id] = selectedCount
            matchedSelectedTabs.formUnion(tabs.filter { selectedIDs.contains($0.id) }
                .map { QuickSelectionTab(browser: window.bundle, id: $0.id) })
            if let whole = selection.browserWindowTabs[.init(browser: window.bundle, id: id)],
               !whole.isEmpty, whole.isSubset(of: selectedIDs), whole == Set(tabs.filter(QuickSelection.isSelectable).map(\.id)) {
                markedRegions[window.id] = [window.frame]
                continue
            }
            // Mission Control represents windows, not tab-strip geometry. Its
            // positively matched native window gets a contour plus tab count,
            // even while the browser's tab AX tree is temporarily unavailable.
            if missionScan.present { continue }
            // Selection/geometry changes refresh immediately; an unchanged tab strip
            // needs no full accessibility traversal on every animation tick.
            let key = "\(window.pid):\(process.launched):\(snapshot.browserSessionID ?? ""): \(window.frame):\(tabs.map { "\($0.id):\($0.index):\($0.title):\($0.active)" }):\(selectedIDs.sorted())"
            if let cached = scanCache[window.id], cached.key == key, Date().timeIntervalSince(cached.at) < 1 {
                markedRegions[window.id] = cached.regions
                continue
            }
            if front?.id != window.id && !overviewVisible {
                markedRegions[window.id] = scanCache[window.id].flatMap { $0.key == key ? $0.regions : nil } ?? []
                continue
            }
            guard let native = response.nativeWindow(id: id, selectedIDs: selectedIDs, process: process) else { continue }
            let scan = WorkspaceTabOutline.scan(window: window, tabs: native.tabs, selected: native.selected)
            if scan.complete { completedScans += 1 } else { partialScans += 1 }
            if scan.identityContradiction {
                contradictedScans += 1
                scanCache.removeValue(forKey: window.id)
                // Requery after the observed reorder/navigation. An already
                // pending request may have sampled before that change too.
                snapshotStates.removeValue(forKey: window.bundle)
                phases[window.bundle] = "native-identity-contradiction"
            }
            // Favicon bytes, page URLs and snapshot timestamps do not identify
            // tab chrome. Reuse the session-pinned layout key so an icon refresh
            // cannot clear a valid outline during a bounded partial AX read.
            let context = key
            var continuity = tabContinuity[window.id] ?? TabBlurContinuity()
            let regions = scan.updateContinuity(&continuity, context: context, now: Date())
            tabContinuity[window.id] = continuity
            markedRegions[window.id] = regions
            if scan.complete { scanCache[window.id] = (key, Date(), regions) }
        }
        scanCache = scanCache.filter { markedRegions[$0.key] != nil }
        tabContinuity = tabContinuity.filter { markedRegions[$0.key] != nil }
        let missionWindows = windows.map { window in
            MissionControlOutline.Window(id: window.id, pid: window.pid,
                launched: NSRunningApplication(processIdentifier: window.pid)?.launchDate?.timeIntervalSinceReferenceDate ?? 0,
                bundle: window.bundle, title: window.title, selected: markedWindowIDs.contains(window.id),
                selectedTabCount: selectedTabCounts[window.id])
        }.sorted { $0.id < $1.id }
        let mission = missionContinuity.update(missionScan, windows: missionWindows, revision: token,
            now: ProcessInfo.processInfo.systemUptime)
        struct RenderRegion {
            let frame: CGRect
            let browser: String?
            let chromeTab: Bool
            let mission: Bool
            let badge: String?
            let summary: String?
        }
        var regions: [RenderRegion]
        if missionScan.present {
            regions = mission.regions.map { .init(frame: $0.frame, browser: $0.window.bundle,
                chromeTab: false, mission: true, badge: $0.badge, summary: nil) }
            let unmatchedTabs = selection.tabs.subtracting(matchedSelectedTabs)
                .filter { selection.wholeBrowserApps?.contains($0.browser) != true }.count
            if mission.unresolvedCount > 0 || unmatchedTabs > 0, let display = displayFrames.first {
                var counts: [String] = []
                if mission.unresolvedCount > 0 { counts.append("\(mission.unresolvedCount) window\(mission.unresolvedCount == 1 ? "" : "s")") }
                if unmatchedTabs > 0 { counts.append("\(unmatchedTabs) tab\(unmatchedTabs == 1 ? "" : "s")") }
                let text = "Selected: " + counts.joined(separator: " · ")
                let width = min(370, display.width - 32)
                regions.append(.init(frame: CGRect(x: display.midX - width / 2, y: display.maxY - 70, width: width, height: 38),
                    browser: nil, chromeTab: false, mission: false, badge: nil, summary: text))
            }
        } else {
            // A full-window border must not float across a covering window.
            // Shape belongs to each represented window, never the frontmost
            // browser left behind while Mission Control owns the screen.
            regions = (front.flatMap { markedRegions[$0.id] } ?? []).map { rect in
                .init(frame: rect, browser: front?.bundle,
                    chromeTab: front?.bundle == "com.google.Chrome" && rect != front?.frame
                        && rect.height < 65 && rect.width > rect.height * 1.5,
                    mission: false, badge: nil, summary: nil)
            }
        }
        recordDiagnostics(["selectedTabCount": selection.tabs.count, "selectedWindowCount": selection.windowIDsByApp.values.reduce(0) { $0 + $1.count },
            "selectedBrowserCount": selectedBrowsers.count, "inventoryPhases": phases, "nativeWindowCount": windows.count,
            "presentationWindowID": presentationID.map { Int($0) } ?? 0, "matchedWindowCount": matchedWindows,
            "completeScanCount": completedScans, "partialScanCount": partialScans, "identityContradictionCount": contradictedScans,
            "missionScanStatus": missionScan.status.rawValue, "missionVisitedCount": missionScan.visitedCount,
            "missionMappedCount": mission.regions.count, "missionUnresolvedCount": mission.unresolvedCount,
            "renderedRegionCount": regions.count])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let current = self.revision == token; self.mutex.unlock()
            guard current else { return }
            while self.panels.count > regions.count { self.panels.removeLast().orderOut(nil) }
            for (index, region) in regions.enumerated() {
                if index == self.panels.count {
                    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true; panel.hasShadow = false; panel.hidesOnDeactivate = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]; panel.level = .screenSaver
                    let view = WorkspaceMarkBorderView()
                    panel.contentView = view; self.panels.append(panel)
                }
                let panel = self.panels[index]
                if let view = panel.contentView as? WorkspaceMarkBorderView {
                    view.color = selection.accessMode == .blacklist ? .systemRed : .systemGreen
                    view.chromeTab = region.chromeTab
                    view.missionControl = region.mission
                    view.badge = region.badge
                    view.summary = region.summary
                    view.needsDisplay = true
                }
                panel.setFrame(FocusBlurPolicy.appKitFrame(region.frame, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height), display: false)
                if !panel.isVisible { panel.orderFrontRegardless() }
            }
        }
    }

}

/// Thin, inset contours follow the tab chrome instead of boxing its hit target.
private final class WorkspaceMarkBorderView: NSView {
    var color: NSColor = .systemGreen
    var chromeTab = false
    var missionControl = false
    var badge: String?
    var summary: String?
    override func draw(_ dirtyRect: NSRect) {
        if let summary {
            drawLabel(summary, in: bounds.insetBy(dx: 1, dy: 1), summary: true)
            return
        }
        let inset: CGFloat = missionControl ? 2 : 1.25
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let path: NSBezierPath
        if chromeTab {
            let r = min(9, rect.height / 3)
            path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.curve(to: NSPoint(x: rect.minX + r, y: rect.minY + r), controlPoint1: NSPoint(x: rect.minX + r, y: rect.minY), controlPoint2: NSPoint(x: rect.minX + r, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY - r))
            path.curve(to: NSPoint(x: rect.minX + 2*r, y: rect.maxY), controlPoint1: NSPoint(x: rect.minX + r, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX + r, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - 2*r, y: rect.maxY))
            path.curve(to: NSPoint(x: rect.maxX - r, y: rect.maxY - r), controlPoint1: NSPoint(x: rect.maxX - r, y: rect.maxY), controlPoint2: NSPoint(x: rect.maxX - r, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY + r))
            path.curve(to: NSPoint(x: rect.maxX, y: rect.minY), controlPoint1: NSPoint(x: rect.maxX - r, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX - r, y: rect.minY))
            path.close()
        } else {
            path = NSBezierPath(roundedRect: rect, xRadius: min(8, rect.height / 4), yRadius: min(8, rect.height / 4))
        }
        color.setStroke(); path.lineWidth = missionControl ? 3 : 1.5; path.stroke()
        if let badge {
            let height: CGFloat = 22
            // Even a tiny thumbnail retains its visible contour. The badge
            // shortens to the count if there is insufficient room for words.
            let text = bounds.width < 125 ? badge.components(separatedBy: " ").first ?? badge : badge
            let width = min(bounds.width - 8, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 16)
            if width > 12, bounds.height >= height + 6 {
                drawLabel(text, in: CGRect(x: bounds.midX - width / 2, y: 4, width: width, height: height), summary: false)
            }
        }
    }
    private func drawLabel(_ text: String, in rect: CGRect, summary: Bool) {
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(10, rect.height / 2), yRadius: min(10, rect.height / 2)).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: summary ? 12 : 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: summary ? NSColor.white : color, .paragraphStyle: style]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: CGRect(x: rect.minX + 5, y: rect.midY - height / 2, width: max(0, rect.width - 10), height: height), withAttributes: attributes)
    }
}
