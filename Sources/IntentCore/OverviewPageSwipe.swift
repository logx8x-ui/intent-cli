import Foundation

/// Exactly two stable indirect contacts. Page motion follows the gesture;
/// navigation commits on release so a reversed/abandoned swipe springs back.
public struct OverviewPageSwipe {
    public enum Direction: Equatable { case left, right }
    public private(set) var progress: CGFloat = 0
    private var origins: [Int: CGPoint] = [:]
    private var finished = false
    private var tracking = false

    public init() {}
    public mutating func reset() { origins = [:]; tracking = false; finished = false; progress = 0 }

    public mutating func update(contacts: [Int: CGPoint], cancelled: Bool = false) -> Direction? {
        if cancelled { finished = true; progress = 0; return nil }
        if contacts.isEmpty {
            let result: Direction? = !finished && abs(progress) >= 0.30 ? (progress > 0 ? .left : .right) : nil
            reset()
            return result
        }
        guard !finished else { return nil }
        guard contacts.count <= 2, contacts.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            finished = true; progress = 0; return nil
        }
        if !tracking {
            guard contacts.count == 2 else { return nil }
            origins = contacts; tracking = true; return nil
        }
        // A normal sequential finger lift retains the final translation. Any
        // replacement or additional contact cancels this entire gesture.
        if contacts.count == 1, Set(contacts.keys).isSubset(of: Set(origins.keys)) { return nil }
        guard Set(contacts.keys) == Set(origins.keys) else {
            finished = true; progress = 0; return nil
        }
        let movement = contacts.map { id, point in
            CGPoint(x: point.x - origins[id]!.x, y: point.y - origins[id]!.y)
        }
        let x = movement.reduce(0) { $0 + $1.x } / CGFloat(movement.count)
        let y = movement.reduce(0) { $0 + $1.y } / CGFloat(movement.count)
        if abs(y) > 0.08 && abs(y) >= abs(x) { finished = true; progress = 0; return nil }
        guard abs(x) > abs(y) * 2, movement.allSatisfy({ abs($0.x) >= 0.02 && $0.x * x > 0 }) else {
            progress = 0; return nil
        }
        // Keep the user-confirmed direction reversal; positive contact movement
        // reveals the Tasks page from the right, moving the content to the left.
        progress = max(-1, min(1, x / 0.6))
        return nil
    }
}
