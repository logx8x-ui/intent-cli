import Foundation

/// Two or three stable indirect contacts. Vertical scrolling, four-finger
/// gestures and replacement fingers cannot accidentally change the overview page.
public struct OverviewPageSwipe {
    public enum Direction: Equatable { case left, right }
    private var origins: [Int: CGPoint] = [:]
    private var tracking = false
    private var finished = false

    public init() {}
    public mutating func reset() { origins = [:]; tracking = false; finished = false }

    public mutating func update(contacts: [Int: CGPoint], cancelled: Bool = false) -> Direction? {
        if cancelled { finished = true; tracking = false; return nil }
        if contacts.isEmpty { reset(); return nil }
        guard !finished else { return nil }
        guard contacts.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            finished = true; return nil
        }
        if !tracking {
            if contacts.count > 3 { finished = true; return nil }
            guard (2...3).contains(contacts.count) else { return nil }
            origins = contacts; tracking = true; return nil
        }
        // Fingers can land in successive events. Accept a third arriving before
        // movement begins, without inheriting displacement from a two-finger scroll.
        if origins.count == 2, contacts.count == 3,
           Set(origins.keys).isSubset(of: Set(contacts.keys)),
           origins.allSatisfy({ id, origin in
               guard let point = contacts[id] else { return false }
               return abs(point.x - origin.x) <= 0.04 && abs(point.y - origin.y) <= 0.04
           }) {
            origins = contacts; return nil
        }
        guard Set(contacts.keys) == Set(origins.keys) else {
            finished = true; return nil
        }
        let movement = contacts.map { id, point in
            CGPoint(x: point.x - origins[id]!.x, y: point.y - origins[id]!.y)
        }
        let x = movement.reduce(0) { $0 + $1.x } / CGFloat(movement.count)
        let y = movement.reduce(0) { $0 + $1.y } / CGFloat(movement.count)
        if abs(y) > 0.12 && abs(y) >= abs(x) { finished = true; return nil }
        guard abs(x) >= 0.18, abs(x) > abs(y) * 2,
              movement.allSatisfy({ abs($0.x) >= 0.10 && $0.x * x > 0 }) else { return nil }
        finished = true
        return x < 0 ? .left : .right
    }
}
