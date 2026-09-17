import Foundation

/// Distinguishes a recoverable reconnect from an extension that cannot mark tabs.
public enum QuickMarkRecovery {
    public enum Connection: Equatable { case ready, reconnecting, updateRequired }
    public static func connection(_ heartbeat: BrowserGuardHeartbeat?, now: Date = Date()) -> Connection {
        guard let heartbeat, now.timeIntervalSince(heartbeat.lastSeenAt) <= 5 else { return .reconnecting }
        return heartbeat.supports(.quickSelection) ? .ready : .updateRequired
    }
    public static func accepts(_ snapshot: BrowserTabSnapshot, requestedAt: Date) -> Bool {
        // Idle state updates may publish an empty snapshot while a discovery
        // request is in flight. Wait for actual window/tab data, not just a date.
        snapshot.updatedAt >= requestedAt && snapshot.tabs.contains(where: { $0.active })
    }
    public static func matchesTarget(originalID: UInt32, originalPID: Int32, currentID: UInt32?, currentPID: Int32?) -> Bool {
        // Document titles can change during navigation or when unread counts change.
        // Window identity, not exact title text, determines whether focus moved.
        originalID == currentID && originalPID == currentPID
    }
}
