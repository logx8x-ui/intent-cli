import Foundation

/// The caller supplies elapsed time from a continuous clock and civil time from
/// Date independently: changing the system clock must not shorten a duration.
public struct SessionExpiryPolicy {
    public enum Cause: Equatable { case duration, endTime }
    public let occurrenceID: UUID
    public let duration: TimeInterval?
    public let absoluteEnd: Date?
    private var finished = false

    public init(occurrenceID: UUID = UUID(), duration: TimeInterval?, absoluteEnd: Date?) {
        self.occurrenceID = occurrenceID
        self.duration = duration.map { max(0, $0) }
        self.absoluteEnd = absoluteEnd
    }

    public var hasDeadline: Bool { duration != nil || absoluteEnd != nil }

    public func remaining(elapsed: TimeInterval, now: Date) -> TimeInterval? {
        let candidates = [duration.map { $0 - max(0, elapsed) }, absoluteEnd.map { $0.timeIntervalSince(now) }].compactMap { $0 }
        return candidates.min().map { max(0, $0) }
    }

    public mutating func expire(elapsed: TimeInterval, now: Date) -> Cause? {
        guard !finished else { return nil }
        let durationExpired = duration.map { elapsed >= $0 } ?? false
        let clockExpired = absoluteEnd.map { now >= $0 } ?? false
        guard durationExpired || clockExpired else { return nil }
        finished = true
        return clockExpired ? .endTime : .duration
    }

    public mutating func cancel() { finished = true }
}

/// State refreshes for an existing run cannot undo a user's visibility choice.
public struct SessionOverlayPolicy {
    public private(set) var occurrenceID: UUID?
    public private(set) var eligible = false
    public private(set) var expanded = false
    public init() {}

    public mutating func update(occurrenceID: UUID, hasTimer: Bool, hasChecklist: Bool) {
        let isNewRun = self.occurrenceID != occurrenceID
        self.occurrenceID = occurrenceID
        eligible = hasTimer || hasChecklist
        if isNewRun { expanded = eligible }
        else if !eligible { expanded = false }
    }

    @discardableResult
    public mutating func collapse() -> Bool {
        guard eligible && expanded else { return false }
        expanded = false
        return true
    }

    public mutating func toggle() {
        guard eligible else { return }
        expanded.toggle()
    }

    public mutating func end() { self = Self() }
}
