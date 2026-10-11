import Foundation

/// Reasons are deliberately content-free: no application, window, intention or tab names.
public enum FocusLockSafetyStopCause: String, Codable, Equatable {
    case requested
    case emergencyShortcut
    case inputTapTimeout
    case inputTapDisabled
    case selectedWindowRecoveryUnavailable
    case browserWindowEnforcementFailure
    case browserWindowCoverageFailure
    case nativeWindowEnforcementFailure
    case accessibilityPermissionRequired
    case inputTapUnavailable
}

public struct FocusEnforcementHealth: Codable, Equatable {
    public enum Phase: String, Codable { case prepared, starting, enforcing, stopped }
    public enum Finish: String, Codable { case manual, expiry, safety, completed }
    public var schemaVersion = 1
    public var phase: Phase = .prepared
    public var accessMode: String
    public var requiresEnforcement: Bool
    public var hideDistractions: Bool
    public var selectedWindowGroupCount: Int
    public var startedAt: Date?
    public var updatedAt: Date
    public var becameReady = false
    public var inputTapInstalled = false
    public var inputTapTimeoutCount = 0
    public var inputTapDisabledCount = 0
    public var blockedActivationCount = 0
    public var blockedClickCount = 0
    public var finish: Finish?
    public var safetyStopCause: FocusLockSafetyStopCause?

    public init(accessMode: String, requiresEnforcement: Bool, hideDistractions: Bool,
                selectedWindowGroupCount: Int, now: Date = Date()) {
        self.accessMode = accessMode
        self.requiresEnforcement = requiresEnforcement
        self.hideDistractions = hideDistractions
        self.selectedWindowGroupCount = selectedWindowGroupCount
        updatedAt = now
    }

    public enum Event {
        case starting, inputTapInstalled, ready, blockedActivation, blockedClick
        case finished(Finish)
        case safetyStopped(FocusLockSafetyStopCause)
        case completed
    }

    public mutating func apply(_ event: Event, now: Date = Date()) {
        // Late input/ready work cannot resurrect a finished occurrence.
        if phase == .stopped {
            if case .completed = event { updatedAt = now }
            return
        }
        updatedAt = now
        switch event {
        case .starting: phase = .starting; startedAt = now
        case .inputTapInstalled: inputTapInstalled = true
        case .ready: becameReady = true; phase = .enforcing
        case .blockedActivation: blockedActivationCount = min(1_000_000, blockedActivationCount + 1)
        case .blockedClick: blockedClickCount = min(1_000_000, blockedClickCount + 1)
        case .finished(let reason): finish = reason; phase = .stopped
        case .safetyStopped(let cause):
            safetyStopCause = cause; finish = .safety; phase = .stopped
            if cause == .inputTapTimeout { inputTapTimeoutCount += 1 }
            if cause == .inputTapDisabled { inputTapDisabledCount += 1 }
        case .completed: finish = .completed; phase = .stopped
        }
    }
}

/// Coalesces writes off the input callback and rejects delayed work from an old lock.
/// Only the newest occurrence is retained; output is limited to this fixed schema.
public final class FocusEnforcementDiagnosticSink: @unchecked Sendable {
    private let mutex = NSLock()
    private let queue = DispatchQueue(label: "intent.enforcement-health", qos: .utility)
    private let fileURL: URL?
    private var owner: UUID?
    private var health: FocusEnforcementHealth?
    private var writeScheduled = false

    public init(fileURL: URL? = nil) { self.fileURL = fileURL }

    @discardableResult public func begin(_ health: FocusEnforcementHealth) -> UUID {
        mutex.lock(); defer { mutex.unlock() }
        let token = UUID(); owner = token; self.health = health
        scheduleWriteLocked()
        return token
    }

    public func record(_ event: FocusEnforcementHealth.Event, owner token: UUID) {
        mutex.lock(); defer { mutex.unlock() }
        guard owner == token else { return }
        health?.apply(event)
        scheduleWriteLocked()
    }

    public func snapshot() -> FocusEnforcementHealth? {
        mutex.lock(); defer { mutex.unlock() }; return health
    }

    private func scheduleWriteLocked() {
        guard fileURL != nil, !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.writeLatest() }
    }

    private func writeLatest() {
        mutex.lock()
        let snapshot = health
        writeScheduled = false
        mutex.unlock()
        guard let fileURL, let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        // All file effects share one serial queue. Never hold the state mutex
        // during I/O: record() is also used by the input callback. A change
        // during this write schedules the newer snapshot behind it.
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
