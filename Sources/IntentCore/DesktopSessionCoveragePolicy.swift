import Foundation

/// Only positive WindowServer evidence establishes a protected desktop.
/// An unavailable session dictionary is not proof that the desktop is locked.
public enum DesktopSessionState: Equatable, Sendable {
    case available, secured, unknown
}

public struct DesktopSessionObservation: Equatable, Sendable {
    public let state: DesktopSessionState
    public let generation: UInt64
    /// Changes only when a positively secured interval begins.
    public let securedGeneration: UInt64
    /// Real monotonic time, used for AX deadlines and receipt freshness.
    public let uptime: TimeInterval
    /// Monotonic time excluding positively observed secured intervals only.
    public let activeUptime: TimeInterval
}

/// An effect/ownership transaction cannot survive a protected desktop or a
/// transition away and back while AX is answering. Retry from a new snapshot.
public struct DesktopSessionEffectFence: Sendable {
    private let generation: UInt64
    private let admitted: Bool
    public init(_ observation: DesktopSessionObservation) {
        generation = observation.generation; admitted = observation.state != .secured
    }
    public func permits(_ observation: DesktopSessionObservation) -> Bool {
        admitted && observation.state != .secured && observation.generation == generation
    }
}

/// Shared by the platform sampler and deterministic visibility regressions.
/// Unknown samples charge time normally; they cannot indefinitely suspend a
/// failure deadline. State changes fence observations already in flight.
public struct DesktopSessionClock {
    private var previous: DesktopSessionObservation?
    public init() {}
    public mutating func observe(_ state: DesktopSessionState, uptime: TimeInterval) -> DesktopSessionObservation {
        let now = uptime.isFinite ? max(previous?.uptime ?? 0, uptime) : (previous?.uptime ?? 0)
        let effectiveState: DesktopSessionState = uptime.isFinite ? state : .unknown
        let active = previous.map { $0.activeUptime + ($0.state == .secured ? 0 : now - $0.uptime) } ?? now
        let generation = (previous?.generation ?? 0) &+ (previous?.state == effectiveState ? 0 : 1)
        let securedGeneration = (previous?.securedGeneration ?? 0)
            &+ (effectiveState == .secured && previous?.state != .secured ? 1 : 0)
        let result = DesktopSessionObservation(state: effectiveState, generation: generation,
            securedGeneration: securedGeneration, uptime: now, activeUptime: active)
        previous = result
        return result
    }
}

/// The production visibility boundary: retains unresolved ages through lock,
/// requires a fresh complete pass on return, and rejects pre-transition replies.
/// It never changes restrictions, ownership, or process/window identities.
public struct DesktopSessionCoveragePolicy {
    public enum Domain: Hashable, Sendable {
        case native, reported, browser(String)
    }
    public static func requiredDomains(enforcesVisibility: Bool, hasReportedWindowSession: Bool,
                                       browsers: Set<String>) -> Set<Domain> {
        guard enforcesVisibility else { return [] }
        var result: Set<Domain> = [.native]
        if hasReportedWindowSession { result.insert(.reported) }
        result.formUnion(browsers.map(Domain.browser))
        return result
    }
    private let required: Set<Domain>
    private let requiresInitialVerification: Bool
    private var pending: [Domain: TimeInterval] = [:]
    // Existing native/browser policies own ordinary-runtime pending ages.
    // This additional deadline begins only for fresh post-secure verification.
    private var revalidationBegan: TimeInterval?
    private var verified: Set<Domain> = []
    private var revalidationRequired = false
    private var stopped = false
    public private(set) var observation: DesktopSessionObservation?
    public init(required: Set<Domain>, requiresInitialVerification: Bool = false) {
        self.required = required; self.requiresInitialVerification = requiresInitialVerification
    }

    /// Returns true when cached proofs and asynchronous work must be withdrawn.
    @discardableResult public mutating func update(_ current: DesktopSessionObservation) -> Bool {
        guard !stopped, current.uptime >= (observation?.uptime ?? 0) else { return false }
        let first = observation == nil
        let protectedTransition = first ? current.state == .secured
            : observation?.securedGeneration != current.securedGeneration
        let changed = observation?.generation != current.generation
        if changed { verified.removeAll() }
        if protectedTransition || (first && requiresInitialVerification) {
            if !revalidationRequired { revalidationBegan = current.activeUptime }
            revalidationRequired = !required.isEmpty
            for domain in required where pending[domain] == nil {
                pending[domain] = revalidationBegan ?? current.activeUptime
            }
        }
        observation = current
        return changed
    }
    public var canObserve: Bool { !stopped && observation != nil && observation?.state != .secured }
    public var isReady: Bool { canObserve && required.isSubset(of: verified) }
    public var hasPendingVerification: Bool { !stopped && revalidationRequired }
    public var isRevalidationReady: Bool { canObserve && (!revalidationRequired || isReady) }
    public func accepts(generation: UInt64) -> Bool { canObserve && observation?.generation == generation }
    public mutating func record(_ domain: Domain, resolved: Bool, generation: UInt64) {
        guard accepts(generation: generation), required.contains(domain), let current = observation else { return }
        if resolved {
            verified.insert(domain); pending.removeValue(forKey: domain)
            if required.isSubset(of: verified) { revalidationRequired = false; revalidationBegan = nil; pending.removeAll() }
        } else {
            verified.remove(domain)
            if revalidationRequired, pending[domain] == nil { pending[domain] = revalidationBegan ?? current.activeUptime }
        }
    }
    public func expiredDomain(grace: TimeInterval = 3) -> Domain? {
        guard canObserve, revalidationRequired, let current = observation else { return nil }
        return pending.filter { current.activeUptime - $0.value >= grace }.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return String(describing: $0.key) < String(describing: $1.key)
        }.first?.key
    }
    public mutating func stop() {
        stopped = true; revalidationRequired = false
        verified.removeAll(); pending.removeAll(); revalidationBegan = nil
    }
}
