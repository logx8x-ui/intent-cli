import AppKit
import CoreGraphics
import Darwin
import Foundation
import notify

struct RcmdObservedProcess {
    let identity: RcmdProcessIdentity
    let bundleURL: URL
}

enum RcmdKernelProcessObservation {
    case running(RcmdObservedProcess), absent, otherProcess, unavailable
}

enum RcmdProcessObservation {
    case running(RcmdObservedProcess), absent
    case failure(RcmdCompatibilityFailure, observed: RcmdProcessIdentity?)
}

/// AppKit's application list can momentarily be empty when its Launch Services
/// connection is interrupted. It discovers candidates; it cannot prove that a
/// previously verified kernel process has exited. Keep that exact PID/birth/path
/// independently verifiable, including while processing stale workspace notices.
struct RcmdProcessInspector {
    static let bundleIdentifier = "com.lowtechguys.rcmd"
    let applicationPIDs: () -> [Int32]
    let kernelProcess: (Int32) -> RcmdKernelProcessObservation
    let tapOwnerPIDs: () -> [Int32]?

    init(applicationPIDs: @escaping () -> [Int32],
         kernelProcess: @escaping (Int32) -> RcmdKernelProcessObservation,
         tapOwnerPIDs: @escaping () -> [Int32]? = { [] }) {
        self.applicationPIDs = applicationPIDs; self.kernelProcess = kernelProcess; self.tapOwnerPIDs = tapOwnerPIDs
    }

    func observe(expected: RcmdProcessIdentity?, notificationPID: Int32? = nil) -> RcmdProcessObservation {
        let listed = applicationPIDs()
        guard listed.count <= 16 else { return .failure(.processIdentityUnavailable, observed: nil) }
        // A second copy must not disappear along with AppKit's cached list. The
        // complete keyboard-tap owner inventory independently discovers copies
        // capable of intercepting input, including when startup sees no apps.
        guard let tapping = tapOwnerPIDs(), tapping.count <= 512 else {
            return .failure(.tapInventoryUnavailable, observed: nil)
        }
        var candidates = Set(listed)
        candidates.formUnion(tapping.filter { $0 > 0 })
        if let expected { candidates.insert(expected.pid) }
        if let notificationPID { candidates.insert(notificationPID) }
        var running: [RcmdObservedProcess] = []
        var unknown = false, expectedAbsent = false, expectedReplaced = false
        for pid in candidates.sorted() {
            switch kernelProcess(pid) {
            case .running(let process): running.append(process)
            case .unavailable: unknown = true
            case .absent: if pid == expected?.pid { expectedAbsent = true }
            case .otherProcess: if pid == expected?.pid { expectedReplaced = true }
            }
        }
        if let expected {
            if let other = running.first(where: { $0.identity != expected }) {
                return .failure(.processIdentityChanged, observed: other.identity)
            }
            if expectedReplaced { return .failure(.processIdentityChanged, observed: nil) }
            if expectedAbsent { return .failure(.processTerminated, observed: nil) }
        }
        guard !unknown else { return .failure(.processIdentityUnavailable, observed: nil) }
        guard running.count <= 1 else { return .failure(.processIdentityUnavailable, observed: nil) }
        if let process = running.first { return .running(process) }
        return expected == nil ? .absent : .failure(.processIdentityUnavailable, observed: nil)
    }

    static let live = Self(applicationPIDs: {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier)
    }, kernelProcess: readKernelProcess, tapOwnerPIDs: {
        keyboardTaps().map { Array(Set($0.map(\.tappingProcess))) }
    })

    fileprivate static func keyboardTaps() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count <= 512 else { return nil }
        if count == 0 { return [] }
        var list = Array(repeating: CGEventTapInformation(), count: Int(count) + 16)
        var actual: UInt32 = 0
        guard CGGetEventTapList(UInt32(list.count), &list, &actual) == .success,
              Int(actual) < list.count, actual <= 512 else { return nil }
        let keyboardMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        return list.prefix(Int(actual)).filter { $0.eventsOfInterest & keyboardMask != 0 && $0.options != .listenOnly }
    }

    private static func readKernelProcess(_ pid: Int32) -> RcmdKernelProcessObservation {
        guard pid > 0 else { return .unavailable }
        guard let before = NativeProcessLaunchDate.kernelDate(pid: pid) else {
            // ESRCH is positive absence. Permission/read errors are not exits.
            errno = 0
            return kill(pid, 0) == -1 && errno == ESRCH ? .absent : .unavailable
        }
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard length > 0, let path = String(validatingUTF8: bytes), path.hasPrefix("/") else { return .unavailable }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Unbundled command-line tools and helper tap owners are positively not
        // this supported app executable. Missing metadata for an actual app is
        // uncertainty, not evidence that the known rcmd process disappeared.
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              bundleURL.pathExtension == "app" else {
            return NativeProcessLaunchDate.kernelDate(pid: pid) == before ? .otherProcess : .unavailable
        }
        // Bundle caches Info.plist, which can hide a replaced version on disk.
        // Read a bounded fresh dictionary and never retain arbitrary metadata.
        guard let metadata = readBundleMetadata(bundleURL), let observedBundle = metadata["CFBundleIdentifier"] as? String else { return .unavailable }
        guard observedBundle == bundleIdentifier else {
            return NativeProcessLaunchDate.kernelDate(pid: pid) == before ? .otherProcess : .unavailable
        }
        guard let name = metadata["CFBundleExecutable"] as? String, name == executable.lastPathComponent,
              !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              let version = metadata["CFBundleShortVersionString"] as? String, !version.isEmpty,
              NativeProcessLaunchDate.kernelDate(pid: pid) == before else { return .unavailable }
        return .running(.init(identity: .init(pid: pid, launched: before.timeIntervalSince1970,
            version: version, executablePath: executable.path), bundleURL: bundleURL))
    }

    static func readBundleMetadata(_ bundleURL: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: bundleURL.appendingPathComponent("Contents/Info.plist")) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_145), data.count <= 262_144 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// This monitor never runs on an input-tap run loop. Its initial read must
/// complete before Intent installs its head-inserted session tap; subsequent
/// changes invalidate that ordering rather than repeatedly reinstalling taps.
public final class RcmdCompatibilityMonitor {
    private let initialSnapshot: RcmdCompatibilitySnapshot
    private let onSnapshot: (RcmdCompatibilitySnapshot) -> Void
    private let onInvalidated: (RcmdCompatibilityDiagnostic) -> Void
    private let onDiagnostic: (RcmdCompatibilityDiagnostic) -> Void
    private let processInspector: RcmdProcessInspector
    private let inventoryReader: (Int32) -> RcmdTapInventory
    private let snapshotReader: (RcmdProcessIdentity?) -> RcmdCompatibilitySnapshot
    private let queue = DispatchQueue(label: "intent.rcmd.compatibility", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "intent.rcmd.read", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var invalidated = false // worker-owned
    private var readInFlight = false
    private var lastReadStarted: TimeInterval = 0
    private var readRecovery = RcmdReadRecoveryPolicy()
    private var lastVerified: RcmdCompatibilitySnapshot
    private var lastReadFailure: RcmdCompatibilityDiagnostic?
    private var timer: DispatchSourceTimer?
    private var notificationTokens: [Int32] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private static let bundleIdentifier = "com.lowtechguys.rcmd"

    public convenience init(initialSnapshot: RcmdCompatibilitySnapshot,
        onSnapshot: @escaping (RcmdCompatibilitySnapshot) -> Void,
        onDiagnostic: @escaping (RcmdCompatibilityDiagnostic) -> Void = { _ in },
        onInvalidated: @escaping (RcmdCompatibilityDiagnostic) -> Void) {
        self.init(initialSnapshot: initialSnapshot, onSnapshot: onSnapshot,
            onDiagnostic: onDiagnostic, onInvalidated: onInvalidated,
            processInspector: .live, inventoryReader: Self.tapInventory,
            snapshotReader: { Self.readCurrent(expected: $0) })
    }

    init(initialSnapshot: RcmdCompatibilitySnapshot,
        onSnapshot: @escaping (RcmdCompatibilitySnapshot) -> Void,
        onDiagnostic: @escaping (RcmdCompatibilityDiagnostic) -> Void,
        onInvalidated: @escaping (RcmdCompatibilityDiagnostic) -> Void,
        processInspector: RcmdProcessInspector,
        inventoryReader: @escaping (Int32) -> RcmdTapInventory,
        snapshotReader: @escaping (RcmdProcessIdentity?) -> RcmdCompatibilitySnapshot) {
        self.initialSnapshot = initialSnapshot
        lastVerified = initialSnapshot
        self.onDiagnostic = onDiagnostic
        self.onSnapshot = onSnapshot; self.onInvalidated = onInvalidated
        self.processInspector = processInspector; self.inventoryReader = inventoryReader
        self.snapshotReader = snapshotReader
    }

    public func start() {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true; lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isActive else { return }
            // Notifications are registered after Intent's tap is installed.
            for name in ["com.apple.coregraphics.eventTapAdded", "com.apple.coregraphics.eventTapRemoved"] {
                var token: Int32 = 0
                if notify_register_dispatch(name, &token, self.queue, { [weak self] _ in
                    self?.verifyTopology()
                }) == NOTIFY_STATUS_OK { self.notificationTokens.append(token) }
            }
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
                    [weak self] notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == Self.bundleIdentifier else { return }
                    let notifiedPID = app.processIdentifier
                    self?.queue.async { [weak self] in
                        self?.verifyTopology(notificationPID: notifiedPID)
                    }
                }
                self.workspaceObservers.append(observer)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [weak self] in self?.tearDown() }
    }

    deinit {
        timer?.cancel()
        for token in notificationTokens { notify_cancel(token) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }

    private func tearDown() {
        timer?.cancel(); timer = nil
        for token in notificationTokens { notify_cancel(token) }
        notificationTokens.removeAll()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private func refresh() {
        guard isActive, !invalidated else { return }
        verifyTopology()
        guard isActive, !invalidated else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if readRecovery.expired(now: now) {
            invalidate(readExpiredEvidence()); return
        }
        guard !readInFlight, now - lastReadStarted >= 1 else { return }
        // The absent case needs no CLI and keeps no third-party mappings alive.
        if initialSnapshot.processIdentity == nil { onSnapshot(.inactive); return }
        readInFlight = true; lastReadStarted = now
        readQueue.async { [weak self] in
            guard let self else { return }
            let current = self.snapshotReader(self.initialSnapshot.processIdentity)
            self.queue.async { [weak self] in self?.completeRead(current) }
        }
    }

    func completeRead(_ current: RcmdCompatibilitySnapshot) {
        readInFlight = false
        guard isActive, !invalidated else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !readRecovery.expired(now: now) else {
            invalidate(readExpiredEvidence()); return
        }
        // A snapshot completed on the reader queue before a newer uncertain
        // observation cannot undo that suspension when its callback arrives.
        guard verifyTopology(), !invalidated else { return }
        if let failure = lastReadFailure, current.observedAtUptime < failure.observedAtUptime { return }
        if current.retryableFailure, current.processIdentity == initialSnapshot.processIdentity {
            var diagnostic = current.diagnostic ?? evidence(.cliCommandFailed, observed: current.processIdentity)
            attachBaseline(to: &diagnostic)
            suspendVerification(diagnostic, now: now)
            return
        }
        guard initialSnapshot.remainsCompatible(with: current) else {
            var diagnostic = current.diagnostic ?? evidence(
                initialSnapshot.incompatibilityReason(with: current) ?? .schemaUnsupported,
                observed: current.processIdentity, inventory: .init(available: true, ids: current.tapIDs))
            attachBaseline(to: &diagnostic)
            invalidate(diagnostic); return
        }
        guard readRecovery.verified(now: now) else { return }
        lastVerified = current; lastReadFailure = nil
        onSnapshot(current)
    }

    // Internal so the isolated regression can exercise the same notification
    // and polling path with controlled kernel/list observations, without taps.
    @discardableResult
    func verifyTopology(notificationPID: Int32? = nil) -> Bool {
        guard isActive, !invalidated else { return false }
        let observation = processInspector.observe(expected: initialSnapshot.processIdentity, notificationPID: notificationPID)
        switch observation {
        case .absent: return true
        case .failure(let reason, let observed):
            let diagnostic = evidence(reason, observed: observed)
            if reason == .processIdentityUnavailable, initialSnapshot.processIdentity != nil {
                suspendVerification(diagnostic, now: ProcessInfo.processInfo.systemUptime)
            } else { invalidate(diagnostic) }
            return false
        case .running(let process):
            guard let identity = initialSnapshot.processIdentity else {
                invalidate(evidence(.processStarted, observed: process.identity)); return false
            }
            let inventory = inventoryReader(identity.pid)
            if let failure = inventory.failure {
                invalidate(evidence(failure, observed: process.identity, inventory: inventory)); return false
            }
            if inventory.ids != initialSnapshot.tapIDs {
                invalidate(evidence(.tapIDsChanged, observed: process.identity, inventory: inventory))
                return false
            }
            return true
        }
    }

    private func suspendVerification(_ diagnostic: RcmdCompatibilityDiagnostic, now: TimeInterval) {
        guard readRecovery.unavailable(now: now) else { invalidate(readExpiredEvidence()); return }
        lastReadFailure = diagnostic
        onDiagnostic(diagnostic)
        // Retain interception and suspend mapped activations until a complete
        // read verifies the same process, tap topology, configuration and layout.
        onSnapshot(initialSnapshot.invalidated("rcmd connection is being reverified", now: now))
    }

    private func evidence(_ reason: RcmdCompatibilityFailure, observed: RcmdProcessIdentity? = nil,
                          inventory: RcmdTapInventory? = nil) -> RcmdCompatibilityDiagnostic {
        var result = RcmdCompatibilityDiagnostic(reason: reason, now: ProcessInfo.processInfo.systemUptime,
            expectedTapIDs: initialSnapshot.tapIDs, inventory: inventory)
        result.observedPID = observed?.pid; result.observedLaunch = observed?.launched
        attachBaseline(to: &result)
        return result
    }

    private func attachBaseline(to diagnostic: inout RcmdCompatibilityDiagnostic) {
        diagnostic.expectedPID = initialSnapshot.processIdentity?.pid
        diagnostic.expectedLaunch = initialSnapshot.processIdentity?.launched
        diagnostic.expectedTapCount = initialSnapshot.tapIDs.count
        diagnostic.expectedTapIDs = Array(initialSnapshot.tapIDs.sorted().prefix(16))
        diagnostic.lastVerifiedAtUptime = lastVerified.observedAtUptime
        diagnostic.keyboardLayoutRevision = lastVerified.keyboardLayoutRevision
    }

    private func readExpiredEvidence() -> RcmdCompatibilityDiagnostic {
        var result = evidence(.readVerificationExpired, observed: lastVerified.processIdentity)
        result.precedingReason = lastReadFailure?.reason
        return result
    }

    private func invalidate(_ diagnostic: RcmdCompatibilityDiagnostic) {
        guard isActive, !invalidated else { return }
        invalidated = true
        onSnapshot(initialSnapshot.invalidated(diagnostic.reason.rawValue, now: ProcessInfo.processInfo.systemUptime))
        onInvalidated(diagnostic)
    }

    /// Bounded off-callback discovery. Uses the app's bundled supported CLI,
    /// never legacy defaults, a user shell, or a guessed app/window keymap.
    public static func prepareKeyboardLayout() {
        RcmdKeyboardLayoutCache.shared.prepare()
    }

    public static func readCurrent() -> RcmdCompatibilitySnapshot { readCurrent(expected: nil) }

    static func readCurrent(expected: RcmdProcessIdentity?, processInspector: RcmdProcessInspector = .live,
                            inventoryReader: (Int32) -> RcmdTapInventory = tapInventory,
                            cliReader: (URL, [String]) throws -> Data = boundedCLI) -> RcmdCompatibilitySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let process: RcmdObservedProcess
        switch processInspector.observe(expected: expected) {
        case .absent: return .inactive
        case .running(let value): process = value
        case .failure(let reason, let observed):
            var diagnostic = RcmdCompatibilityDiagnostic(reason: reason, now: now)
            diagnostic.observedPID = observed?.pid; diagnostic.observedLaunch = observed?.launched
            return unavailable(identity: expected ?? observed, reason: reason, now: now,
                retryable: reason == .processIdentityUnavailable && expected != nil, diagnostic: diagnostic)
        }
        let identity = process.identity
        let cli = process.bundleURL.appendingPathComponent("Contents/SharedSupport/rcmdCLI")
        var inventory: RcmdTapInventory?
        var observedIdentity: RcmdProcessIdentity? = identity
        var expectedTaps: Set<UInt32> = []
        var decoding = false
        do {
            guard identity.version == "3.4.0" else { throw MonitorFailure.typed(.unsupportedVersion) }
            let firstInventory = inventoryReader(identity.pid); inventory = firstInventory
            if let failure = firstInventory.failure { throw MonitorFailure.typed(failure) }
            let taps = firstInventory.ids; expectedTaps = taps
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw MonitorFailure.typed(.cliUnavailable) }
            guard let layout = RcmdKeyboardLayoutCache.shared.snapshot else { throw MonitorFailure.keyboardLayoutChanged }
            let status = try cliReader(cli, ["status", "--json"])
            let keys = try cliReader(cli, ["app", "debug", "keys", "--json"])
            let config = try cliReader(cli, ["config", "export", "--json"])
            switch processInspector.observe(expected: identity) {
            case .running(let current): observedIdentity = current.identity
            case .absent:
                observedIdentity = nil; throw MonitorFailure.typed(.processTerminated)
            case .failure(let reason, let current):
                observedIdentity = current; throw MonitorFailure.typed(reason)
            }
            let finalInventory = inventoryReader(identity.pid); inventory = finalInventory
            if let failure = finalInventory.failure { throw MonitorFailure.typed(failure) }
            guard finalInventory.ids == taps else { throw MonitorFailure.typed(.tapIDsChanged) }
            guard RcmdKeyboardLayoutCache.shared.isCurrent(layout.revision) else { throw MonitorFailure.keyboardLayoutChanged }
            decoding = true
            return try RcmdSnapshotDecoder.decode(statusData: status, keysData: keys, configData: config,
                identity: identity, tapIDs: taps, now: ProcessInfo.processInfo.systemUptime,
                keyCodesByCharacter: layout.keyCodesByCharacter).usingKeyboardLayout(revision: layout.revision)
        } catch {
            let reason = Self.failureReason(error, decoding: decoding)
            let retryable = [.cliTimedOut, .cliCommandFailed, .keyboardLayoutChanged, .processIdentityUnavailable].contains(reason)
            var diagnostic = RcmdCompatibilityDiagnostic(reason: reason, now: ProcessInfo.processInfo.systemUptime,
                expectedTapIDs: expectedTaps, inventory: inventory)
            diagnostic.expectedPID = identity.pid; diagnostic.expectedLaunch = identity.launched
            diagnostic.observedPID = observedIdentity?.pid; diagnostic.observedLaunch = observedIdentity?.launched
            return unavailable(identity: identity, reason: reason, now: now, retryable: retryable, diagnostic: diagnostic)
        }
    }

    /// Run off-callback immediately after creating Intent's head-inserted tap,
    /// before the session can become ready. This closes the capture/install gap.
    public static func verifyCurrentTopology(_ snapshot: RcmdCompatibilitySnapshot) -> Bool {
        guard snapshot.isCompatible,
              snapshot.keyboardLayoutRevision.map({ RcmdKeyboardLayoutCache.shared.isCurrent($0) }) != false else { return false }
        switch RcmdProcessInspector.live.observe(expected: snapshot.processIdentity) {
        case .absent: return snapshot.processIdentity == nil
        case .failure: return false
        case .running(let process):
            return snapshot.processIdentity == process.identity && filterTapIDs(pid: process.identity.pid) == snapshot.tapIDs
        }
    }

    private static func unavailable(identity: RcmdProcessIdentity?, reason: RcmdCompatibilityFailure, now: TimeInterval,
        retryable: Bool = false, diagnostic: RcmdCompatibilityDiagnostic? = nil) -> RcmdCompatibilitySnapshot {
        .init(processIdentity: identity, observedAtUptime: now, isCompatible: false, statusReason: reason.rawValue,
            appTrigger: nil, blockedTriggers: ["rcmd", "ralt", "rctrl", "rshift"].compactMap(RcmdModifierChord.init(description:)),
            appBundlesByKeyCode: [:], tapIDs: [], capturesCommandGrave: true, configurationFingerprint: "unavailable",
            retryableFailure: retryable,
            diagnostic: diagnostic ?? .init(reason: reason, now: now))
    }

    private static func filterTapIDs(pid: Int32) -> Set<UInt32>? {
        let observation = tapInventory(pid: pid)
        return observation.failure == nil ? observation.ids : nil
    }

    private static func tapInventory(pid: Int32) -> RcmdTapInventory {
        guard let taps = RcmdProcessInspector.keyboardTaps() else { return .init(available: false) }
        let relevant = taps.filter { $0.tappingProcess == pid }
        // A HID-level switcher runs before a session tap and cannot be promised
        // preventive interception by this architecture. Do not silently accept it.
        return .init(available: true, ids: Set(relevant.map(\.eventTapID)),
            disabled: Set(relevant.filter { !$0.enabled }.map(\.eventTapID)),
            unsupported: Set(relevant.filter { $0.tapPoint != .cgSessionEventTap }.map(\.eventTapID)))
    }

    private enum MonitorFailure: Error { case typed(RcmdCompatibilityFailure), timedOut, outputTooLarge, commandFailed, keyboardLayoutChanged }

    private static func failureReason(_ error: Error, decoding: Bool) -> RcmdCompatibilityFailure {
        if let error = error as? MonitorFailure {
            switch error {
            case .typed(let reason): return reason
            case .timedOut: return .cliTimedOut
            case .outputTooLarge: return .cliOutputTooLarge
            case .commandFailed: return .cliCommandFailed
            case .keyboardLayoutChanged: return .keyboardLayoutChanged
            }
        }
        if let error = error as? RcmdSnapshotDecoder.Failure {
            switch error {
            case .malformed: return .schemaMalformed
            case .unsupported: return .schemaUnsupported
            case .identityChanged: return .schemaIdentityMismatch
            case .ambiguousKey: return .ambiguousKeys
            }
        }
        return decoding ? .schemaMalformed : .cliLaunchFailed
    }

    private static func boundedCLI(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        let originalFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        defer { try? output.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.45
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var amount: Int = 0
            repeat {
                amount = read(fd, &buffer, buffer.count)
                if amount > 0 { result.append(contentsOf: buffer.prefix(amount)) }
                if result.count > 262_144 { terminateCLI(process); throw MonitorFailure.outputTooLarge }
            } while amount > 0
            if !process.isRunning {
                // A last write may race the preceding EAGAIN and exit check.
                repeat {
                    amount = read(fd, &buffer, buffer.count)
                    if amount > 0 { result.append(contentsOf: buffer.prefix(amount)) }
                    if result.count > 262_144 { throw MonitorFailure.outputTooLarge }
                } while amount > 0
                guard process.terminationStatus == 0 else { throw MonitorFailure.commandFailed }
                return result
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { terminateCLI(process); throw MonitorFailure.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 10)
        }
    }

    private static func terminateCLI(_ process: Process) {
        // This PID belongs to the child CLI we created, never the rcmd app.
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(2_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

}
