import AppKit
import Carbon
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
    private let onInvalidated: (String) -> Void
    private let queue = DispatchQueue(label: "intent.rcmd.compatibility", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "intent.rcmd.read", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var invalidated = false // worker-owned
    private var readInFlight = false
    private var lastReadStarted: TimeInterval = 0
    private var readRecovery = RcmdReadRecoveryPolicy()
    private var timer: DispatchSourceTimer?
    private var notificationTokens: [Int32] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private static let bundleIdentifier = "com.lowtechguys.rcmd"

    public init(initialSnapshot: RcmdCompatibilitySnapshot,
        onSnapshot: @escaping (RcmdCompatibilitySnapshot) -> Void,
        onInvalidated: @escaping (String) -> Void) {
        self.initialSnapshot = initialSnapshot
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
                    self?.queue.async { [weak self] in self?.invalidate("rcmd process lifetime changed") }
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
            invalidate("rcmd connection could not be reverified within two seconds"); return
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
            invalidate("rcmd connection could not be reverified within two seconds"); return
        }
        if current.retryableFailure, current.processIdentity == initialSnapshot.processIdentity {
            _ = readRecovery.unavailable(now: now)
            // Keep input interception, but disable all mapped activations until
            // the original process, tap topology and configuration are reverified.
            onSnapshot(initialSnapshot.invalidated("rcmd connection is being reverified", now: now))
            return
        }
        guard initialSnapshot.remainsCompatible(with: current) else {
            invalidate(current.statusReason ?? "rcmd configuration or input-tap lifetime changed"); return
        }
        guard readRecovery.verified(now: now) else { return }
        onSnapshot(current)
    }

    private func verifyTopology() {
        guard isActive, !invalidated else { return }
        guard let identity = initialSnapshot.processIdentity else {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
                invalidate("rcmd started after Intent's input tap")
            }
            return
        }
        guard let actual = Self.runningIdentity(), actual == identity,
              Self.filterTapIDs(pid: identity.pid) == initialSnapshot.tapIDs else {
            invalidate("rcmd input-tap topology changed")
            return
        }
    }

    private func invalidate(_ reason: String) {
        guard isActive, !invalidated else { return }
        invalidated = true
        onSnapshot(initialSnapshot.invalidated(reason, now: ProcessInfo.processInfo.systemUptime))
        onInvalidated(reason)
    }

    /// Bounded off-callback discovery. Uses the app's bundled supported CLI,
    /// never legacy defaults, a user shell, or a guessed app/window keymap.
    public static func readCurrent() -> RcmdCompatibilitySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if apps.isEmpty { return .inactive }
        guard apps.count == 1, let app = apps.first, let identity = runningIdentity(),
              let bundleURL = app.bundleURL else {
            return unavailable(identity: apps.first.map { .init(pid: $0.processIdentifier, launched: -1, version: "unknown") },
                reason: "rcmd process identity is unavailable", now: now)
        }
        let cli = bundleURL.appendingPathComponent("Contents/SharedSupport/rcmdCLI")
        do {
            guard identity.version == "3.4.0", let taps = filterTapIDs(pid: identity.pid), !taps.isEmpty,
                  FileManager.default.isExecutableFile(atPath: cli.path) else { throw MonitorFailure.unsupported }
            let status = try boundedCLI(cli, arguments: ["status", "--json"])
            let keys = try boundedCLI(cli, arguments: ["app", "debug", "keys", "--json"])
            let config = try boundedCLI(cli, arguments: ["config", "export", "--json"])
            guard runningIdentity() == identity, filterTapIDs(pid: identity.pid) == taps else { throw MonitorFailure.changed }
            return try RcmdSnapshotDecoder.decode(statusData: status, keysData: keys, configData: config,
                identity: identity, tapIDs: taps, now: ProcessInfo.processInfo.systemUptime,
                keyCodesByCharacter: keyboardKeyCodes())
        } catch {
            let retryable = (error as? MonitorFailure).map { $0 == .timedOut || $0 == .commandFailed } ?? false
            return unavailable(identity: identity, reason: "rcmd compatibility could not be verified (\(error))", now: now,
                retryable: retryable)
        }
    }

    /// Run off-callback immediately after creating Intent's head-inserted tap,
    /// before the session can become ready. This closes the capture/install gap.
    public static func verifyCurrentTopology(_ snapshot: RcmdCompatibilitySnapshot) -> Bool {
        guard snapshot.isCompatible else { return false }
        guard let identity = snapshot.processIdentity else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
        return runningIdentity() == identity && filterTapIDs(pid: identity.pid) == snapshot.tapIDs
    }

    private static func unavailable(identity: RcmdProcessIdentity?, reason: String, now: TimeInterval,
        retryable: Bool = false) -> RcmdCompatibilitySnapshot {
        .init(processIdentity: identity, observedAtUptime: now, isCompatible: false, statusReason: reason,
            appTrigger: nil, blockedTriggers: ["rcmd", "ralt", "rctrl", "rshift"].compactMap(RcmdModifierChord.init(description:)),
            appBundlesByKeyCode: [:], tapIDs: [], capturesCommandGrave: true, configurationFingerprint: "unavailable",
            retryableFailure: retryable)
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
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0, count <= 512 else { return nil }
        var list = Array(repeating: CGEventTapInformation(), count: Int(count) + 16)
        var actual: UInt32 = 0
        guard CGGetEventTapList(UInt32(list.count), &list, &actual) == .success,
              Int(actual) <= list.count else { return nil }
        let keyboardMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let relevant = list.prefix(Int(actual)).filter {
            $0.tappingProcess == pid && $0.eventsOfInterest & keyboardMask != 0
                && $0.options != .listenOnly
        }
        // A HID-level switcher runs before a session tap and cannot be promised
        // preventive interception by this architecture. Do not silently accept it.
        guard !relevant.isEmpty, relevant.allSatisfy({ $0.tapPoint == .cgSessionEventTap && $0.enabled }) else { return nil }
        return Set(relevant.map(\.eventTapID))
    }

    private enum MonitorFailure: Error, Equatable { case unsupported, changed, timedOut, outputTooLarge, commandFailed }

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

    private static func keyboardKeyCodes() -> [String: Int64] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var result: [String: Int64] = [:], ambiguous: Set<String> = []
        for code in UInt16(0)..<128 {
            var dead: UInt32 = 0, actual = 0, text = [UniChar](repeating: 0, count: 4)
            let error = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, text.count, &actual, &text)
            guard error == noErr, actual == 1 else { continue }
            let character = String(utf16CodeUnits: text, count: actual).lowercased()
            guard character.rangeOfCharacter(from: .letters) != nil else { continue }
            if result[character] != nil { ambiguous.insert(character) }
            else { result[character] = Int64(code) }
        }
        for key in ambiguous { result.removeValue(forKey: key) }
        return result
    }
}
