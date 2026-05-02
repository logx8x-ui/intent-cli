import Foundation

public enum IntentScreen: Equatable {
    case root
    case shallow
    case deep
}

public enum ShallowTask: String, CaseIterable, Equatable {
    case imessages
    case instagramReplies = "instagram replies"
    case emails

    public var displayName: String {
        switch self {
        case .imessages: "Imessages"
        case .instagramReplies: "Instagram replies"
        case .emails: "Emails"
        }
    }

    public var appName: String {
        switch self {
        case .imessages: "Messages"
        case .instagramReplies, .emails: "Firefox"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .imessages: "com.apple.MobileSMS"
        case .instagramReplies, .emails: "org.mozilla.firefox"
        }
    }

    public var menuNumber: String {
        switch self {
        case .imessages: "1"
        case .instagramReplies: "2"
        case .emails: "3"
        }
    }

    public var confirmationPhrase: String? {
        switch self {
        case .instagramReplies: "I want to use instagram right now"
        case .imessages, .emails: nil
        }
    }
}

public enum DeepTask: String, CaseIterable, Equatable {
    case dataScience = "data science"

    public var displayName: String {
        switch self {
        case .dataScience: "Data science"
        }
    }

    public var menuNumber: String {
        switch self {
        case .dataScience: "1"
        }
    }
}

public enum IntentWorkTask: Equatable {
    case shallow(ShallowTask)
    case deep(DeepTask)

    public var displayName: String {
        switch self {
        case .shallow(let task): task.displayName
        case .deep(let task): task.displayName
        }
    }
}

public enum IntentAction: Equatable {
    case showRoot
    case showShallow
    case showDeep
    case start(IntentWorkTask)
    case invalid
}

public struct IntentMenu {
    public private(set) var screen: IntentScreen

    public init(screen: IntentScreen = .root) {
        self.screen = screen
    }

    public static func routeRootInput(_ input: String) -> IntentScreen? {
        switch normalize(input) {
        case "s": .shallow
        case "d": .deep
        default: nil
        }
    }

    @discardableResult
    public mutating func handle(_ input: String) -> IntentAction {
        if input == "\u{1B}" {
            screen = .root
            return .showRoot
        }

        switch screen {
        case .root:
            switch Self.routeRootInput(input) {
            case .shallow:
                screen = .shallow
                return .showShallow
            case .deep:
                screen = .deep
                return .showDeep
            case .root, .none:
                return .invalid
            }

        case .deep:
            let normalized = Self.normalize(input)
            if normalized == "b" {
                screen = .root
                return .showRoot
            }
            if let task = Self.matchDeepTask(normalized) {
                return .start(.deep(task))
            }
            return .invalid

        case .shallow:
            let normalized = Self.normalize(input)
            if normalized == "b" {
                screen = .root
                return .showRoot
            }
            if let task = Self.matchShallowTask(normalized) {
                return .start(.shallow(task))
            }
            return .invalid
        }
    }

    private static func matchShallowTask(_ normalized: String) -> ShallowTask? {
        ShallowTask.allCases.first {
            normalized == $0.menuNumber || normalized == $0.rawValue
        }
    }

    private static func matchDeepTask(_ normalized: String) -> DeepTask? {
        DeepTask.allCases.first {
            normalized == $0.menuNumber || normalized == $0.rawValue
        }
    }

    public static func normalize(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public enum IntentCompleter {
    public static func complete<T: RawRepresentable>(_ input: String, in options: [T]) -> String?
    where T.RawValue == String {
        let normalizedInput = normalizeForCompletion(input)
        guard !normalizedInput.isEmpty else { return nil }

        let matches = options
            .map(\.rawValue)
            .filter { normalizeForCompletion($0).hasPrefix(normalizedInput) }

        if matches.count == 1 {
            return matches[0]
        }

        return nil
    }

    private static func normalizeForCompletion(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
