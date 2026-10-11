/// Permission guidance always names the binary whose macOS identity needs trust.
/// In particular, granting Intent does not grant the separate Test Intent app.
public struct IntentPermissionInstructions: Sendable {
    public let channel: IntentBuildChannel
    public init(channel: IntentBuildChannel) { self.channel = channel }
    public static var current: Self { .init(channel: .current) }
    public var appName: String { channel.appName }

    public var overview: String {
        "In System Settings, turn on \(appName). If it is missing, use + and choose \(appName).app. Return here and press ` again. If macOS asks to quit and reopen, accept it. Your selections and saved intentions stay safe."
    }
    public var accessibility: String {
        "\(appName) needs Accessibility permission. Open System Settings > Privacy & Security > Accessibility and enable \(appName), then start the intention again."
    }
    public var keyboardLock: String {
        "\(appName) could not start the keyboard lock. Enable Accessibility/Input Monitoring for \(appName), then start the intention again."
    }
    public var screenRecording: String { "Turn on \(appName) in Screen Recording, then reopen `." }
    public var speechRecognition: String { "Allow Speech Recognition for \(appName) in System Settings to use voice." }
    public var microphone: String { "Allow Microphone access for \(appName) in System Settings to use voice." }
    public var onboardingAccessibility: String { "Lets \(appName) use your focus shortcuts and protect your chosen setup." }
    public var onboardingPreviews: String { "Lets \(appName) show local window previews and blur; this guide doesn’t record or upload your screen." }
    public var onboardingReturn: String { "The guide waits while Settings is open. Return to \(appName) when you’re done." }
}
