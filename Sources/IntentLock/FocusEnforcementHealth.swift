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
    public enum Phase: String, Codable { case prepared, starting, enforcing, recovering, stopped }
    public enum Finish: String, Codable { case manual, expiry, safety, completed }
    public var schemaVersion = 2
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
    // Optional fields retain decoding compatibility with older diagnostic receipts.
    public var inputRecoveryAttempts: Int? = 0
    public var inputRecoverySuccesses: Int? = 0
    public var inputCallbackCount: Int? = 0
    public var maxCallbackMicroseconds: Double? = 0
    public var maxSnapshotAgeMilliseconds: Double? = 0
    public var maxInputSchedulingDelayMilliseconds: Double? = 0
    public var maxPendingInputActions: Int? = 0
    public var coalescedInputActions: Int? = 0
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
        case inputTapRecoveryBegan, inputTapRecoverySucceeded
        case inputSample(durationMicroseconds: Double, snapshotAgeMilliseconds: Double)
        case inputQueueDepth(Int), inputWorkCoalesced
        case inputBatch(samples: Int, maxDurationMicroseconds: Double, maxSnapshotAgeMilliseconds: Double, maxPendingActions: Int, coalescedActions: Int, schedulingDelayMilliseconds: Double)
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
        case .ready: becameReady = true; if phase != .recovering { phase = .enforcing }
        case .blockedActivation: blockedActivationCount = min(1_000_000, blockedActivationCount + 1)
        case .blockedClick: blockedClickCount = min(1_000_000, blockedClickCount + 1)
        case .inputTapRecoveryBegan:
            guard phase != .recovering else { return }
            phase = .recovering
            inputTapTimeoutCount = min(1_000_000, inputTapTimeoutCount + 1)
            inputRecoveryAttempts = min(1_000_000, (inputRecoveryAttempts ?? 0) + 1)
        case .inputTapRecoverySucceeded:
            guard phase == .recovering else { return }
            phase = becameReady ? .enforcing : .starting
            inputRecoverySuccesses = min(1_000_000, (inputRecoverySuccesses ?? 0) + 1)
        case .inputSample(let duration, let age):
            inputCallbackCount = min(1_000_000_000, (inputCallbackCount ?? 0) + 1)
            if duration.isFinite && duration >= 0 {
                maxCallbackMicroseconds = max(maxCallbackMicroseconds ?? 0, min(duration, 60_000_000))
            }
            if age.isFinite && age >= 0 {
                maxSnapshotAgeMilliseconds = max(maxSnapshotAgeMilliseconds ?? 0, min(age, 60_000))
            }
        case .inputBatch(let samples, let duration, let age, let pending, let coalesced, let delay):
            inputCallbackCount = min(1_000_000_000, (inputCallbackCount ?? 0) + min(1_000_000_000, max(0, samples)))
            if duration.isFinite && duration >= 0 { maxCallbackMicroseconds = max(maxCallbackMicroseconds ?? 0, min(duration, 60_000_000)) }
            if age.isFinite && age >= 0 { maxSnapshotAgeMilliseconds = max(maxSnapshotAgeMilliseconds ?? 0, min(age, 60_000)) }
            if delay.isFinite && delay >= 0 { maxInputSchedulingDelayMilliseconds = max(maxInputSchedulingDelayMilliseconds ?? 0, min(delay, 60_000)) }
            maxPendingInputActions = max(maxPendingInputActions ?? 0, min(1_000_000, max(0, pending)))
            coalescedInputActions = min(1_000_000_000, (coalescedInputActions ?? 0) + min(1_000_000_000, max(0, coalesced)))
        case .inputQueueDepth(let depth):
            maxPendingInputActions = max(maxPendingInputActions ?? 0, min(1_000_000, max(0, depth)))
        case .inputWorkCoalesced:
            coalescedInputActions = min(1_000_000_000, (coalescedInputActions ?? 0) + 1)
        case .finished(let reason): finish = reason; phase = .stopped
        case .safetyStopped(let cause):
            let alreadyRecordedTimeout = phase == .recovering
            safetyStopCause = cause; finish = .safety; phase = .stopped
            if cause == .inputTapTimeout && !alreadyRecordedTimeout { inputTapTimeoutCount += 1 }
            if cause == .inputTapDisabled { inputTapDisabledCount += 1 }
        case .completed: finish = .completed; phase = .stopped
        }
    }
}

/// Coalesces writes off the input callback and rejects delayed work from an old lock.
/// A bounded history retains each occurrence; output is limited to this fixed schema.
public final class FocusEnforcementDiagnosticSink: @unchecked Sendable {
    private let mutex = NSLock()
    private let queue = DispatchQueue(label: "intent.enforcement-health", qos: .utility)
    private let fileURL: URL?
    private var owner: UUID?
    private var health: FocusEnforcementHealth?
    private var writeScheduled = false
    private struct HistoryEntry: Codable {
        let occurrenceID: UUID
        let health: FocusEnforcementHealth
    }
    // Queue-owned; never loaded or written while holding the callback-facing mutex.
    private var history: [HistoryEntry]?
    private let historyLimit = 20

    public init(fileURL: URL? = nil) { self.fileURL = fileURL }

    @discardableResult public func begin(_ health: FocusEnforcementHealth) -> UUID {
        mutex.lock(); defer { mutex.unlock() }
        if let previousOwner = owner, let previousHealth = self.health {
            queue.async { [weak self] in self?.archive(owner: previousOwner, health: previousHealth) }
        }
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
        let snapshotOwner = owner
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
        if let snapshotOwner { archive(owner: snapshotOwner, health: snapshot) }
    }

    private func archive(owner: UUID, health: FocusEnforcementHealth) {
        guard let fileURL else { return }
        let historyURL = fileURL.deletingPathExtension().appendingPathExtension("history.json")
        if history == nil {
            // Never ingest an unbounded or unrecognized diagnostic history.
            let size = (try? historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 256 * 1024, let data = try? Data(contentsOf: historyURL),
               let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                history = Array(decoded.suffix(historyLimit))
            } else { history = [] }
        }
        history?.removeAll { $0.occurrenceID == owner }
        history?.append(HistoryEntry(occurrenceID: owner, health: health))
        if let entries = history { history = Array(entries.suffix(historyLimit)) }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: historyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
}
