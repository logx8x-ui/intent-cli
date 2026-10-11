import Foundation
import CoreGraphics

/// A recovery target includes the process birth, never just an app or PID.
public enum PermittedWindowRecoveryPolicy {
    public struct Identity: Equatable, Sendable {
        public var bundleIdentifier: String
        public var pid: Int32
        public var launched: Double
        public var windowID: UInt32
        public init(bundleIdentifier: String, pid: Int32, launched: Double, windowID: UInt32) {
            self.bundleIdentifier = bundleIdentifier; self.pid = pid
            self.launched = launched; self.windowID = windowID
        }
        public var isValid: Bool {
            !bundleIdentifier.isEmpty && pid > 0 && launched.isFinite && windowID > 0
        }
    }

    public static func accepts(expected: Identity, sampled: Identity?, permitted: Bool) -> Bool {
        expected.isValid && permitted && sampled == expected
    }

    public struct Window: Equatable {
        public var identity: Identity
        public var title: String
        public var frame: CGRect
        public init(identity: Identity, title: String, frame: CGRect) {
            self.identity = identity; self.title = title; self.frame = frame
        }
    }
    public static func matches(title: String, frame: CGRect, candidate: Window) -> Bool {
        let values = [frame.minX, frame.minY, frame.width, frame.height,
                      candidate.frame.minX, candidate.frame.minY, candidate.frame.width, candidate.frame.height]
        return candidate.identity.isValid && values.allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && candidate.title == title
            && abs(frame.minX - candidate.frame.minX) < 3 && abs(frame.minY - candidate.frame.minY) < 3
            && abs(frame.width - candidate.frame.width) < 3 && abs(frame.height - candidate.frame.height) < 3
    }
    public static func uniquelyMatches(expected: Identity, title: String, frame: CGRect, native: [Window]) -> Bool {
        guard expected.isValid else { return false }
        let matches = native.filter { row in
            row.identity.pid == expected.pid && row.identity.launched == expected.launched
                && row.identity.bundleIdentifier == expected.bundleIdentifier && self.matches(title: title, frame: frame, candidate: row)
        }
        return matches.count == 1 && matches[0].identity == expected
    }

    public enum Outcome: Equatable { case unavailable, raiseFailed, activationRejected, restored }

    /// Each effect executes inside the caller's session fence and repeats its
    /// exact-window permission check. A failed raise never falls back to an app.
    public static func restore(perform: (() -> Bool) -> Bool?, validate: @escaping () -> Bool,
                               setMain: @escaping () -> Void, raise: @escaping () -> Bool,
                               activationTargetCurrent: @escaping () -> Bool,
                               activate: @escaping () -> Bool) -> Outcome {
        guard perform({ guard validate() else { return false }; setMain(); return true }) == true else { return .unavailable }
        guard let raised = perform({ validate() && raise() }) else { return .unavailable }
        guard raised else { return .raiseFailed }
        guard let activated = perform({ validate() && activationTargetCurrent() && activate() }) else { return .unavailable }
        return activated ? .restored : .activationRejected
    }
}
