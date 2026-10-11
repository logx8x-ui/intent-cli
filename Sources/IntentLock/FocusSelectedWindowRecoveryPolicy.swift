import Foundation

/// A failed AX raise is not evidence that selected work has closed. Keep the
/// existing input rules while retrying, and leave confirmed resource exhaustion
/// to the session's ordinary lifetime monitor. No replacement is authorized here.
public final class FocusSelectedWindowRecoveryPolicy: @unchecked Sendable {
    public enum ResourcePresence: Equatable { case present, unknown, closed }
    public enum FailureDecision: Equatable { case retryLater, awaitNormalCompletion, safetyStop, cancelled }

    private let mutex = NSLock()
    private let retryInterval: TimeInterval
    private let recoveryWindow: TimeInterval
    private var beganAt: TimeInterval?
    private var nextAttemptAt: TimeInterval = 0
    private var stopped = false

    public init(retryInterval: TimeInterval = 0.15, recoveryWindow: TimeInterval = 3) {
        self.retryInterval = max(0.05, retryInterval)
        self.recoveryWindow = max(self.retryInterval, recoveryWindow)
    }

    public func beginAttempt(now: TimeInterval) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard !stopped, now >= nextAttemptAt else { return false }
        if beganAt == nil { beganAt = now }
        nextAttemptAt = now + retryInterval
        return true
    }

    public func failed(now: TimeInterval, resources: ResourcePresence) -> FailureDecision {
        mutex.lock(); defer { mutex.unlock() }
        guard !stopped else { return .cancelled }
        // All selected work being closed is normal completion, not an AX
        // failure. The existing monitor makes that completion decision.
        if resources == .closed { return .awaitNormalCompletion }
        return now - (beganAt ?? now) >= recoveryWindow ? .safetyStop : .retryLater
    }

    public func recovered() {
        mutex.lock(); defer { mutex.unlock() }
        guard !stopped else { return }
        beganAt = nil; nextAttemptAt = 0
    }

    public func stop() { mutex.lock(); stopped = true; mutex.unlock() }
}
