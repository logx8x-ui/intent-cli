import Foundation
import IntentCore

func runQuickMarkExpiryTimerSpecs() throws {
    var clock: TimeInterval = 0
    var timers: [(timer: Timer, interval: TimeInterval, fire: (Timer) -> Void)] = []
    var registrations = 0
    var singles = 0
    var gesture = QuickMarkGesture()
    let expiry = QuickMarkExpiryTimer(now: { clock }, makeTimer: { interval, callback in
        let timer = Timer(timeInterval: interval, repeats: false, block: callback)
        timers.append((timer, interval, callback))
        return timer
    }, register: { _ in registrations += 1 })
    func synchronize() {
        expiry.schedule(deadline: gesture.pendingSingleDeadline) {
            if gesture.expire(now: clock) == .single { singles += 1 }
            synchronize()
        }
    }
    @discardableResult
    func key(_ code: Int = 50, down: Bool, at time: TimeInterval) -> QuickMarkGesture.Action? {
        clock = time
        let action = gesture.key(code: code, down: down, modified: false, repeatKey: false, now: clock).action
        if action == .single { singles += 1 }
        synchronize()
        return action
    }
    func fire(_ index: Int, at time: TimeInterval) {
        clock = time
        // Call the stored closure even after invalidation to model a callback
        // already enqueued before cancellation. Timer identity must reject it.
        timers[index].fire(timers[index].timer)
    }

    synchronize()
    try expect(timers.isEmpty && registrations == 0, "Idle Quick Focus creates no polling timer")
    key(down: true, at: 0)
    try expect(timers.isEmpty, "A held prefix creates no expiry timer")
    key(down: false, at: 0.05)
    try expect(timers.count == 1 && abs(timers[0].interval - 0.28) < 0.000001, "One completed press schedules only its remaining double-press window")
    synchronize()
    try expect(timers.count == 1, "Unchanged input/context does not keep recreating the timer")
    fire(0, at: 0.2)
    try expect(singles == 0 && timers.count == 2 && abs(timers[1].interval - 0.13) < 0.000001,
        "An early native timer cannot fire a single early and reschedules only the remaining interval")
    try expect(key(down: true, at: 0.3) == .mark, "A double press wins before the scheduled deadline")
    try expect(!timers[1].timer.isValid, "A double press invalidates its single expiry timer immediately")
    fire(1, at: 0.34)
    try expect(singles == 0, "An already-enqueued cancelled timer cannot emit a stray single")
    key(down: false, at: 0.35)
    try expect(timers.count == 2, "Releasing a double press does not create an idle timer")

    key(down: true, at: 1)
    key(down: false, at: 1.05)
    fire(2, at: 1.34)
    fire(2, at: 1.5)
    try expect(singles == 1 && timers.count == 3 && !timers[2].timer.isValid,
        "A single fires exactly once then leaves no scheduled work")

    key(down: true, at: 2)
    key(down: false, at: 2.05)
    try expect(key(down: true, at: 2.34) == .single, "If the event beats a delayed timer, the reducer still delivers the expired first single")
    fire(3, at: 2.35)
    try expect(singles == 2, "The stale delayed timer cannot duplicate the reducer's recovered single")
    key(down: false, at: 2.36)
    fire(4, at: 2.65)
    try expect(singles == 3, "The second tap outside the double window still gets its own single")

    key(down: true, at: 3)
    key(down: false, at: 3.05)
    key(0, down: true, at: 3.1)
    fire(5, at: 3.34)
    try expect(singles == 3 && !timers[5].timer.isValid, "Continuing to type cancels scheduled expiry")

    key(down: true, at: 4)
    key(down: false, at: 4.05)
    gesture.reset()
    expiry.cancel() // Same reset path used by session/text/Spotlight transitions.
    fire(6, at: 4.34)
    synchronize()
    try expect(singles == 3 && timers.count == 7 && !timers[6].timer.isValid,
        "Context reset cancels queued callbacks and returns to zero idle timers")
    print("One-shot gesture expiry regressions passed (no idle polling, early/deferred timer races and cancellation)")
}
