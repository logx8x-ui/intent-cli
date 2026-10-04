import Foundation

/// At most one one-shot timer, only while a completed backtick awaits its
/// double-press deadline. Kept separate so the native scheduling path is tested
/// without starting an event tap or interacting with the desktop.
final class QuickMarkExpiryTimer {
    private let now: () -> TimeInterval
    private let makeTimer: (TimeInterval, @escaping (Timer) -> Void) -> Timer
    private let register: (Timer) -> Void
    private var timer: Timer?
    private var deadline: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeTimer: @escaping (TimeInterval, @escaping (Timer) -> Void) -> Timer = {
             Timer(timeInterval: $0, repeats: false, block: $1)
         },
         register: @escaping (Timer) -> Void = { RunLoop.main.add($0, forMode: .common) }) {
        self.now = now
        self.makeTimer = makeTimer
        self.register = register
    }

    func schedule(deadline: TimeInterval?, onExpire: @escaping () -> Void) {
        guard self.deadline != deadline else { return }
        cancel()
        guard let deadline else { return }
        self.deadline = deadline
        let timer = makeTimer(max(0, deadline - now())) { [weak self] fired in
            guard let self, self.timer === fired else { return }
            fired.invalidate()
            // Clear before dispatch so an early timer firing can reschedule
            // the same monotonic deadline after the reducer rechecks uptime.
            self.timer = nil
            self.deadline = nil
            onExpire()
        }
        self.timer = timer
        register(timer)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }

    deinit { timer?.invalidate() }
}
