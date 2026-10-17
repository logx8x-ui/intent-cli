import Foundation
import CoreGraphics
import IntentCore

/// A fresh, serialized WindowServer sample. Notifications are hints to sample;
/// a screen-saver notification alone never proves that input is protected.
public enum DesktopSessionAvailability {
    private static let lock = NSLock()
    private static var clock = DesktopSessionClock()
    public static var current: DesktopSessionState { snapshot.state }
    public static var snapshot: DesktopSessionObservation {
        lock.lock(); defer { lock.unlock() }
        let state = classify(CGSessionCopyCurrentDictionary() as? [String: Any])
        return clock.observe(state, uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// Require CFBoolean values, never numeric/string truthiness. The lock key
    /// is supplied by WindowServer on supported macOS versions; its absence is
    /// unknown unless the documented on-console key positively says false.
    public static func classify(_ session: [String: Any]?) -> DesktopSessionState {
        guard let session else { return .unknown }
        func boolean(_ value: Any?) -> Bool? {
            guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue((value as! CFBoolean))
        }
        let locked = boolean(session["CGSSessionScreenIsLocked"])
        let onConsole = boolean(session[kCGSessionOnConsoleKey as String])
        if locked == true || onConsole == false { return .secured }
        return locked == false && onConsole == true ? .available : .unknown
    }
}
