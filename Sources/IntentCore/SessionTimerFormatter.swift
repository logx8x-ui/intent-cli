import Foundation

public enum SessionTimerFormatter {
    /// With both modifiers, show the absolute clock only when it is the deadline
    /// that will actually finish the session; otherwise show the shorter timer.
    public static func showsAbsoluteEnd(_ absoluteEnd: Date?, effectiveEnd: Date?) -> Bool {
        guard let absoluteEnd, let effectiveEnd else { return false }
        return absoluteEnd <= effectiveEnd.addingTimeInterval(1)
    }

    public static func countdownText(until endDate: Date, now: Date) -> String {
        let remaining = max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
        return countdownText(seconds: remaining)
    }

    public static func countdownText(seconds: Int) -> String {
        let remaining = max(0, seconds)
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
