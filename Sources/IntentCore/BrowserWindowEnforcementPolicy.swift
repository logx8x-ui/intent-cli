import Foundation

/// Outcome tracking only: this policy never resolves identity or authorizes an
/// effect. Use monotonic uptime and confine an instance to the visibility queue.
public struct BrowserWindowEnforcementPolicy {
    public enum Reason: String, Equatable {
        case windowIdentityUnavailable
        case accessibilityUnavailable
        case ownershipNotSaved
        case minimizeNotConfirmed
    }
    public enum Outcome: Equatable {
        case verifiedMinimized
        case noLongerExists
        case unresolved(Reason)
    }
    public struct Observation {
        public var record: BrowserWindowVisibilityRecord
        public var windowID: Int
        public var liveProcessIdentity: BrowserProcessIdentity?
        public var outcome: Outcome

        public init(record: BrowserWindowVisibilityRecord, windowID: Int,
                    liveProcessIdentity: BrowserProcessIdentity?, outcome: Outcome) {
            self.record = record; self.windowID = windowID
            self.liveProcessIdentity = liveProcessIdentity; self.outcome = outcome
        }
    }
    public struct Failure: Equatable {
        public var browserBundleIdentifier: String
        public var browserSessionID: String
        public var intentionSessionID: String
        public var windowID: Int
        public var reason: Reason

        public var message: String {
            let browser = browserBundleIdentifier == "org.mozilla.firefox" ? "Firefox" : "Chrome"
            return "The intention stopped because Intent could not safely hide a blocked \(browser) window. Window restrictions could not be confirmed, so Intent is releasing this intention and restoring its workspace."
        }
    }
    private struct Claim: Hashable {
        var browser: String
        var profile: String
        var window: Int
        var pid: Int32
        var launched: Double
    }
    private struct Pending {
        var began: TimeInterval
        var failure: Failure
    }
    private let intentionSessionID: String
    private let grace: TimeInterval
    private var pending: [Claim: Pending] = [:]
    private var stopped = false

    public init(intentionSessionID: String, grace: TimeInterval = 3) {
        self.intentionSessionID = intentionSessionID
        self.grace = grace.isFinite && grace >= 0 ? grace : 3
    }

    public mutating func stop() { stopped = true; pending.removeAll() }

    /// Missing/stale process proof is not success and cannot accuse a later
    /// browser lifetime. Only currently verified claims contribute to failure.
    /// Revision, title and geometry changes cannot restart an unresolved claim's
    /// clock. Omission, actual success, proven closure or ending clears it.
    public mutating func update(_ observations: [Observation], activeIntentionSessionID: String?,
                                now: TimeInterval) -> Failure? {
        if let activeIntentionSessionID, activeIntentionSessionID != intentionSessionID { stop() }
        guard !stopped, activeIntentionSessionID == intentionSessionID, now.isFinite else {
            pending.removeAll(); return nil
        }
        var next: [Claim: Pending] = [:]
        for observation in observations {
            let record = observation.record
            guard record.isValid, record.plan.intentionSessionID == intentionSessionID,
                  record.plan.windows.contains(where: { $0.windowID == observation.windowID }),
                  let proof = record.browserProcessIdentity, proof.isValid,
                  proof == observation.liveProcessIdentity else { continue }
            guard case .unresolved(let reason) = observation.outcome else { continue }
            let claim = Claim(browser: record.browserBundleIdentifier, profile: record.browserSessionID,
                window: observation.windowID, pid: proof.pid, launched: proof.launched)
            next[claim] = Pending(began: pending[claim]?.began ?? now,
                failure: Failure(browserBundleIdentifier: record.browserBundleIdentifier,
                    browserSessionID: record.browserSessionID, intentionSessionID: intentionSessionID,
                    windowID: observation.windowID, reason: reason))
        }
        pending = next
        let expired = next.values.filter { now - $0.began >= grace }.sorted {
            ($0.began, $0.failure.browserBundleIdentifier, $0.failure.browserSessionID, $0.failure.windowID)
                < ($1.began, $1.failure.browserBundleIdentifier, $1.failure.browserSessionID, $1.failure.windowID)
        }
        guard let failure = expired.first?.failure else { return nil }
        stop() // A callback cannot repeatedly stop or resurrect this occurrence.
        return failure
    }
}
