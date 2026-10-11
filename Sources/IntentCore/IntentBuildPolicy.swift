/// Features shipped in a binary, rather than preferences a user can toggle.
/// Both channels keep the same intention/session format. Development builds are
/// compiled explicitly with `-D INTENT_DEVELOPMENT`; unmarked builds are launch.
public enum IntentBuildChannel: String, Equatable, Sendable {
    case development
    case launch

    public static var current: Self {
        #if INTENT_DEVELOPMENT
        return .development
        #else
        return .launch
        #endif
    }
}

public struct IntentBuildPolicy: Equatable, Sendable {
    public let channel: IntentBuildChannel

    public init(channel: IntentBuildChannel) { self.channel = channel }

    public static var current: Self { .init(channel: .current) }

    /// Only the experimental T website-adding workflow is withheld. Selecting
    /// existing tabs, Tab searches and saved-intention website restoration stay
    /// available in both channels.
    public var includesWebsiteAdder: Bool { channel == .development }
}
