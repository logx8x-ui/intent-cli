import ApplicationServices
import Foundation

public struct AccessibilityAuthorizationGate {
    private let isTrusted: () -> Bool
    private let requestPrompt: () -> Void
    private let pause: () -> Void

    public init(
        isTrusted: @escaping () -> Bool,
        requestPrompt: @escaping () -> Void,
        pause: @escaping () -> Void
    ) {
        self.isTrusted = isTrusted
        self.requestPrompt = requestPrompt
        self.pause = pause
    }

    public func waitForTrust(maxPolls: Int = 80) -> Bool {
        if isTrusted() {
            return true
        }

        requestPrompt()

        for _ in 0..<maxPolls {
            pause()
            if isTrusted() {
                return true
            }
        }

        return false
    }

    public static func system() -> AccessibilityAuthorizationGate {
        AccessibilityAuthorizationGate(
            isTrusted: {
                AXIsProcessTrusted()
            },
            requestPrompt: {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [promptKey: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            pause: {
                pollingPause()
            }
        )
    }

    public static func pollingPause(duration: TimeInterval = 0.25) {
        Thread.sleep(forTimeInterval: duration)
    }
}
