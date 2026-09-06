import Foundation

public enum SessionTimerFormatter {
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
