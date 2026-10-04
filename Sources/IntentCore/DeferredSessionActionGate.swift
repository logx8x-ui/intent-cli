import Foundation

/// A generation fence for deferred session UI work. Cancellation waits for an
/// already-running synchronous effect, so no old effect can begin after it
/// returns. Keep each effect bounded; never hold the fence across an await or
/// a synchronous dispatch to another queue. Recursive locking permits AppKit's
/// synchronous notifications to cancel their own originating action.
public final class DeferredSessionActionGate: @unchecked Sendable {
    private let lock: NSRecursiveLock
    private var generation: UInt64 = 0

    public init(lock: NSRecursiveLock = NSRecursiveLock()) { self.lock = lock }

    public var token: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    @discardableResult public func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    @discardableResult public func perform<Value>(ifCurrent token: UInt64, _ effect: () throws -> Value) rethrows -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return nil }
        return try effect()
    }
}
