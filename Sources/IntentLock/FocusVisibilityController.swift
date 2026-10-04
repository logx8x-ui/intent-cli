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
    // AppKit visibility requests must run on the application main thread.
    // A background unhide can fail even after hide succeeded.
    private let queue = DispatchQueue.main
    private var timer: DispatchSourceTimer?
    private var entries: [Entry] = []
    private var stopped = false
    private var started = false
    private var initialVisibilityApplied = false
    public init(spec: FocusSessionSpec) {
        self.spec = spec
        visibilityCache = spec.nativeWindowVisibilitySessionID.map {
            BrowserWindowVisibilityRecordCache(intentionSessionID: $0)
        }
    }

    public func start() {
        onMain {
            guard !stopped else { return }
            started = true
            Self.diagnosticEvents = []
            Self.recoveryGeneration &+= 1
            Self.stopRecoveryWatcher()
            RestorationFocusGuard.cancel()
            entries = Self.restore()
            guard spec.hideDistractions && spec.requiresEnforcement, !stopped, timer == nil else {
                if entries.contains(where: { $0.parking == true }) {
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
        guard !stopped else { return }
        let initialApps = initialVisibilityApplied ? nil : spec.initialAllowedApps
        defer { initialVisibilityApplied = true }
        let windows = WorkspaceWindow.list(onScreen: false)
        Self.accessibilityWindows = Self.accessibilityWindows.filter { identity, _ in
            windows.contains { $0.id == identity.window && $0.pid == identity.pid }
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
        if entries.contains(where: { $0.parking == true }) {
            entries = Self.restore(parkingOnly: true, currentRecords: records)
        }
        reconcileBrowserWindows(records: records, windows: windows)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, let launched = app.launchDate else { continue }
            if !spec.permitsApplication(bundle) || initialApps.map({ !$0.contains(bundle) }) == true {
                guard !app.isHidden else { continue }
                let entry = Entry(pid: app.processIdentifier, launched: launched, bundle: bundle, window: nil)
                if !entries.contains(where: { $0.pid == entry.pid && $0.window == nil }) {
                    entries.append(entry)
                    guard Self.save(entries) else { entries.removeLast(); continue }
                }
                _ = app.hide()
            } else {
                for window in windows where window.pid == app.processIdentifier && (!spec.permitsWindow(window.id, bundleIdentifier: bundle) || (initialApps != nil && spec.initialSelectedWindows[bundle].map { !$0.contains(window.id) } == true)) {
                    guard let element = Self.element(window, launched: launched), Self.boolean(element, kAXMinimizedAttribute).value == false else { continue }
                    if !entries.contains(where: { $0.pid == window.pid && $0.window == window.id }) {
                        entries.append(Entry(pid: window.pid, launched: launched, bundle: bundle, window: window.id))
                        guard Self.save(entries) else { entries.removeLast(); continue }
                    }
                    _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
    }
    private func reconcileBrowserWindows(records: [BrowserWindowVisibilityRecord], windows: [WorkspaceWindow]) {
        // Registration ACK has a short deadline. Bind holding windows before
        // potentially slow AX calls into unrelated blocked browser windows.
        let resolved = Self.matches(records: records, windows: windows).sorted { $0.isParking && !$1.isParking }
        for match in resolved {
            guard !stopped, let app = NSRunningApplication(processIdentifier: match.candidate.pid),
                  app.bundleIdentifier == match.record.browserBundleIdentifier, let launched = app.launchDate,
                  let window = windows.first(where: { $0.id == match.candidate.id && $0.pid == match.candidate.pid }) else { continue }
            if match.isParking {
                entries = Self.captureParkingMatch(match, launched: launched, entries: entries)
                continue
            }
            guard let element = Self.element(window, launched: launched),
                  Self.boolean(element, kAXMinimizedAttribute).value == false else { continue }
            // Never adopt a pre-minimized user window. Existing ownership can
            // be re-enforced only while the exact current plan still lists it.
            if !entries.contains(where: { $0.pid == window.pid && $0.launched == launched && $0.window == window.id }) {
                guard Self.isFreshClaim(match.record, pid: window.pid, launched: launched) else { continue }
                entries.append(Entry(pid: window.pid, launched: launched, bundle: window.bundle, window: window.id,
                    browserSessionID: match.record.browserSessionID, intentionSessionID: match.record.plan.intentionSessionID,
                    browserWindowID: match.window.windowID, parking: false))
                guard Self.save(entries) else { entries.removeLast(); continue }
            }
            let status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            Self.observe("browserMinimize", pid: window.pid, window: window.id, status: status)
        }
        // Plan omission is not a reveal: Add As You Go leaves initial
        // distractions hidden until completion.
    }

    private static func currentRules() -> ActiveBrowserRules? {
        guard let data = try? Data(contentsOf: ActiveBrowserRulesStore.defaultFileURL()) else { return nil }
        return try? JSONDecoder().decode(ActiveBrowserRules.self, from: data)
    }
    private static func recoveryRecords(entries: [Entry], currentRecords: [BrowserWindowVisibilityRecord]) -> [BrowserWindowVisibilityRecord] {
        let store = BrowserWindowVisibilityStore()
        var seen: Set<URL> = []
        return entries.compactMap { entry in
            guard entry.parking == true, let browserSession = entry.browserSessionID,
                  let session = entry.intentionSessionID else { return nil }
            let file = store.fileURL(browserBundleIdentifier: entry.bundle, browserSessionID: browserSession,
                intentionSessionID: session)
            guard seen.insert(file).inserted else { return nil }
            if let record = currentRecords.first(where: {
                $0.browserBundleIdentifier == entry.bundle && $0.browserSessionID == browserSession
                    && $0.plan.intentionSessionID == session
            }) { return record }
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
    private static func parkingMayReveal(_ entry: Entry, records: [BrowserWindowVisibilityRecord]) -> Bool {
        guard entry.parking == true, let browserSession = entry.browserSessionID,
              let session = entry.intentionSessionID, let window = entry.browserWindowID else { return false }
        return records.contains {
            $0.browserBundleIdentifier == entry.bundle && $0.browserSessionID == browserSession &&
                $0.plan.intentionSessionID == session && $0.registeredParkingWindows.contains { $0.windowID == window } &&
                $0.requestedRevealWindowIDs.contains(window)
        }
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
    private static func restore(parkingOnly: Bool = false, currentRecords: [BrowserWindowVisibilityRecord] = []) -> [Entry] {
        let entries = loadEntries()
        let windows = WorkspaceWindow.list(onScreen: false)
        let records = recoveryRecords(entries: entries, currentRecords: currentRecords)
        var pending: [Entry] = []
        for entry in entries {
            if parkingOnly && entry.parking != true { pending.append(entry); continue }
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
                if entry.parking == true && !parkingMayReveal(entry, records: records) { pending.append(entry); continue }
                guard let window = windows.first(where: { $0.id == id && $0.pid == entry.pid }),
                      let element = element(window, launched: entry.launched) else { pending.append(entry); continue }
                let before = boolean(element, kAXMinimizedAttribute)
                if before.value == false { continue }
                guard before.value == true else {
                    if before.status == .invalidUIElement { accessibilityWindows.removeValue(forKey: .init(pid: entry.pid, launched: entry.launched, window: id)) }
                    pending.append(entry); continue
                }
                let status = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                observe("restore", pid: entry.pid, window: id, status: status)
                // Successful dispatch is not completion. A request that timed
                // out may also have completed by the time this read succeeds.
                if boolean(element, kAXMinimizedAttribute).value != false { pending.append(entry) }
            } else if app.isHidden {
                _ = app.unhide()
                if app.isHidden { pending.append(entry) }
            }
            RestorationFocusGuard.preserveCurrent()
        }
        _ = save(pending)
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
                if parkingOnly ? !pending.contains(where: { $0.parking == true }) : pending.isEmpty { stopRecoveryWatcher() }
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
            if parkingOnly ? !pending.contains(where: { $0.parking == true }) : pending.isEmpty { stopRecoveryWatcher() }
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
