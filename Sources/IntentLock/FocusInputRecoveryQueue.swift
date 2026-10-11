import Foundation

/// Reject input immediately, then coalesce potentially blocking focus recovery
/// outside the event callback. The action must also fence its individual effects.
public final class FocusInputRecoveryQueue: @unchecked Sendable {
    private let mutex = NSLock()
    private var pending = false
    private var stopped = false
    private let enqueue: (@escaping () -> Void) -> Void

    public init(enqueue: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.enqueue = enqueue
    }

    public func request(_ recovery: @escaping () -> Void) {
        mutex.lock()
        guard !pending, !stopped else { mutex.unlock(); return }
        pending = true; mutex.unlock()
        enqueue { [weak self] in
            guard let self else { return }
            self.mutex.lock()
            self.pending = false
            let shouldRun = !self.stopped
            self.mutex.unlock()
            if shouldRun { recovery() }
        }
    }

    public func stop() { mutex.lock(); stopped = true; mutex.unlock() }
}
