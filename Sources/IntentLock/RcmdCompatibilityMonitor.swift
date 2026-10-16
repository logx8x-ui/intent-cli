import AppKit
import CoreGraphics
import Darwin
import Foundation
import notify

/// This monitor never runs on an input-tap run loop. Its initial read must
/// complete before Intent installs its head-inserted session tap; subsequent
/// changes invalidate that ordering rather than repeatedly reinstalling taps.
public final class RcmdCompatibilityMonitor {
    private let initialSnapshot: RcmdCompatibilitySnapshot
    private let onSnapshot: (RcmdCompatibilitySnapshot) -> Void
    private let onInvalidated: (RcmdCompatibilityDiagnostic) -> Void
    private let onDiagnostic: (RcmdCompatibilityDiagnostic) -> Void
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

    public init(initialSnapshot: RcmdCompatibilitySnapshot,
        onSnapshot: @escaping (RcmdCompatibilitySnapshot) -> Void,
        onDiagnostic: @escaping (RcmdCompatibilityDiagnostic) -> Void = { _ in },
        onInvalidated: @escaping (RcmdCompatibilityDiagnostic) -> Void) {
        self.initialSnapshot = initialSnapshot
        lastVerified = initialSnapshot
        self.onDiagnostic = onDiagnostic
        self.onSnapshot = onSnapshot; self.onInvalidated = onInvalidated
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
                    let reason: RcmdCompatibilityFailure = name == NSWorkspace.didLaunchApplicationNotification
                        ? .processStarted : .processTerminated
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.invalidate(self.evidence(reason, observed: Self.runningIdentity()))
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
            let current = Self.readCurrent()
            self?.queue.async { [weak self] in self?.completeRead(current) }
        }
    }

    private func completeRead(_ current: RcmdCompatibilitySnapshot) {
        readInFlight = false
        guard isActive, !invalidated else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !readRecovery.expired(now: now) else {
            invalidate(readExpiredEvidence()); return
        }
        if current.retryableFailure, current.processIdentity == initialSnapshot.processIdentity {
            _ = readRecovery.unavailable(now: now)
            var diagnostic = current.diagnostic ?? evidence(.cliCommandFailed, observed: current.processIdentity)
            attachBaseline(to: &diagnostic)
            lastReadFailure = diagnostic
            onDiagnostic(diagnostic)
            // Keep input interception, but disable all mapped activations until
            // the original process, tap topology and configuration are reverified.
            onSnapshot(initialSnapshot.invalidated("rcmd connection is being reverified", now: now))
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

    private func verifyTopology() {
        guard isActive, !invalidated else { return }
        guard let identity = initialSnapshot.processIdentity else {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
                invalidate(evidence(.processStarted, observed: Self.runningIdentity()))
            }
            return
        }
        let actual = Self.runningIdentity()
        guard actual == identity else {
            let absent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
            invalidate(evidence(actual == nil ? (absent ? .processTerminated : .processIdentityUnavailable)
                : .processIdentityChanged, observed: actual))
            return
        }
        let inventory = Self.tapInventory(pid: identity.pid)
        if let failure = inventory.failure { invalidate(evidence(failure, observed: actual, inventory: inventory)); return }
        if inventory.ids != initialSnapshot.tapIDs {
            invalidate(evidence(.tapIDsChanged, observed: actual, inventory: inventory))
        }
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

    public static func readCurrent() -> RcmdCompatibilitySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if apps.isEmpty { return .inactive }
        guard apps.count == 1, let app = apps.first, let identity = runningIdentity(),
              let bundleURL = app.bundleURL else {
            return unavailable(identity: apps.first.map { .init(pid: $0.processIdentifier, launched: -1, version: "unknown") },
                reason: .processIdentityUnavailable, now: now)
        }
        let cli = bundleURL.appendingPathComponent("Contents/SharedSupport/rcmdCLI")
        var inventory: RcmdTapInventory?
        var observedIdentity: RcmdProcessIdentity? = identity
        var expectedTaps: Set<UInt32> = []
        var decoding = false
        do {
            guard identity.version == "3.4.0" else { throw MonitorFailure.typed(.unsupportedVersion) }
            let firstInventory = tapInventory(pid: identity.pid); inventory = firstInventory
            if let failure = firstInventory.failure { throw MonitorFailure.typed(failure) }
            let taps = firstInventory.ids; expectedTaps = taps
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw MonitorFailure.typed(.cliUnavailable) }
            guard let layout = RcmdKeyboardLayoutCache.shared.snapshot else { throw MonitorFailure.keyboardLayoutChanged }
            let status = try boundedCLI(cli, arguments: ["status", "--json"])
            let keys = try boundedCLI(cli, arguments: ["app", "debug", "keys", "--json"])
            let config = try boundedCLI(cli, arguments: ["config", "export", "--json"])
            observedIdentity = runningIdentity()
            guard observedIdentity == identity else {
                let absent = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
                throw MonitorFailure.typed(observedIdentity == nil
                    ? (absent ? .processTerminated : .processIdentityUnavailable) : .processIdentityChanged)
            }
            let finalInventory = tapInventory(pid: identity.pid); inventory = finalInventory
            if let failure = finalInventory.failure { throw MonitorFailure.typed(failure) }
            guard finalInventory.ids == taps else { throw MonitorFailure.typed(.tapIDsChanged) }
            guard RcmdKeyboardLayoutCache.shared.isCurrent(layout.revision) else { throw MonitorFailure.keyboardLayoutChanged }
            decoding = true
            return try RcmdSnapshotDecoder.decode(statusData: status, keysData: keys, configData: config,
                identity: identity, tapIDs: taps, now: ProcessInfo.processInfo.systemUptime,
                keyCodesByCharacter: layout.keyCodesByCharacter).usingKeyboardLayout(revision: layout.revision)
        } catch {
            let reason = Self.failureReason(error, decoding: decoding)
            let retryable = [.cliTimedOut, .cliCommandFailed, .keyboardLayoutChanged].contains(reason)
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
        guard let identity = snapshot.processIdentity else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
        return runningIdentity() == identity && filterTapIDs(pid: identity.pid) == snapshot.tapIDs
    }

    private static func unavailable(identity: RcmdProcessIdentity?, reason: RcmdCompatibilityFailure, now: TimeInterval,
        retryable: Bool = false, diagnostic: RcmdCompatibilityDiagnostic? = nil) -> RcmdCompatibilitySnapshot {
        .init(processIdentity: identity, observedAtUptime: now, isCompatible: false, statusReason: reason.rawValue,
            appTrigger: nil, blockedTriggers: ["rcmd", "ralt", "rctrl", "rshift"].compactMap(RcmdModifierChord.init(description:)),
            appBundlesByKeyCode: [:], tapIDs: [], capturesCommandGrave: true, configurationFingerprint: "unavailable",
            retryableFailure: retryable,
            diagnostic: diagnostic ?? .init(reason: reason, now: now))
    }

    private static func runningIdentity() -> RcmdProcessIdentity? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              let launched = NativeProcessLaunchDate.kernelDate(pid: app.processIdentifier),
              let url = app.bundleURL,
              let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return .init(pid: app.processIdentifier, launched: launched.timeIntervalSince1970, version: version)
    }

    private static func filterTapIDs(pid: Int32) -> Set<UInt32>? {
        let observation = tapInventory(pid: pid)
        return observation.failure == nil ? observation.ids : nil
    }

    private static func tapInventory(pid: Int32) -> RcmdTapInventory {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count <= 512 else { return .init(available: false) }
        if count == 0 { return .init(available: true) }
        var list = Array(repeating: CGEventTapInformation(), count: Int(count) + 16)
        var actual: UInt32 = 0
        guard CGGetEventTapList(UInt32(list.count), &list, &actual) == .success,
              Int(actual) <= list.count else { return .init(available: false) }
        let keyboardMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let relevant = list.prefix(Int(actual)).filter {
            $0.tappingProcess == pid && $0.eventsOfInterest & keyboardMask != 0
                && $0.options != .listenOnly
        }
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
