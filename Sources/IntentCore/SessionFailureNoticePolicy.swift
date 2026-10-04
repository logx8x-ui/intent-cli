import Foundation

/// A transient failure notification, independent of timer visibility. Callers
/// arm the actual run occurrence, never a saved intention's reusable identity.
public struct SessionFailureNoticePolicy {
    public static let duration: TimeInterval = 12
    public private(set) var occurrenceID: UUID?
    public private(set) var visible = false
    private var presented = false
    private var securitySuppressed = false
    private var generation: UInt64 = 0

    public init() {}

    @discardableResult public mutating func prepare(occurrenceID: UUID) -> Bool {
        guard self.occurrenceID != occurrenceID else { return false }
        hide()
        self.occurrenceID = occurrenceID
        presented = false
        securitySuppressed = false
        return true
    }

    /// Security suppression consumes this attempt. Unlock/wake must not replay
    /// a notification from a session which ended while the user was away.
    public mutating func show(occurrenceID: UUID, canPresent: Bool) -> UInt64? {
        guard self.occurrenceID == occurrenceID, !presented else { return nil }
        presented = true
        hide()
        guard canPresent, !securitySuppressed else { return nil }
        visible = true
        return generation
    }

    public mutating func hide() { generation &+= 1; visible = false }

    public mutating func suppressForSecurity() { securitySuppressed = true; hide() }

    /// Only the model's exact, still-running lock can rearm after sleep. A
    /// displayed/suppressed failure attempt remains consumed; it never replays.
    @discardableResult public mutating func resume(occurrenceID: UUID, sessionStillRunning: Bool) -> Bool {
        guard self.occurrenceID == occurrenceID, sessionStillRunning,
              securitySuppressed, !presented else { return false }
        securitySuppressed = false
        hide()
        return true
    }

    @discardableResult public mutating func expire(generation expected: UInt64) -> Bool {
        guard visible, expected == generation else { return false }
        hide()
        return true
    }

    public static func frame(screen: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect {
        let width = min(440, max(1, visibleFrame.width - 24))
        let height = min(148, max(1, visibleFrame.height - 24))
        let top = min(visibleFrame.maxY, screen.maxY - max(0, safeAreaTop)) - 8
        return CGRect(x: visibleFrame.midX - width / 2,
            y: max(visibleFrame.minY + 12, top - height), width: width, height: height)
    }
}
