import Foundation

public struct IntentPortablePreferences: Codable, Equatable, Sendable {
    public var appearance: String
    public var welcomeTitle: String
    public var backgroundSelection: String
    public var didCompleteOnboarding: Bool
    public var zeroDriftWarningSuppressed: Bool
    public var purposeModeEnabled: Bool
    public var requireManualFinishBeforeSwitching: Bool
    public var overlayShortcutData: Data?
    public var finishShortcutData: Data?

    public init(
        appearance: String = "dark",
        welcomeTitle: String = "Welcome to my desktop",
        backgroundSelection: String = "none",
        didCompleteOnboarding: Bool = false,
        zeroDriftWarningSuppressed: Bool = false,
        purposeModeEnabled: Bool = false,
        requireManualFinishBeforeSwitching: Bool = true,
        overlayShortcutData: Data? = nil,
        finishShortcutData: Data? = nil
    ) {
        self.appearance = appearance
        self.welcomeTitle = welcomeTitle
        self.backgroundSelection = backgroundSelection
        self.didCompleteOnboarding = didCompleteOnboarding
        self.zeroDriftWarningSuppressed = zeroDriftWarningSuppressed
        self.purposeModeEnabled = purposeModeEnabled
        self.requireManualFinishBeforeSwitching = requireManualFinishBeforeSwitching
        self.overlayShortcutData = overlayShortcutData
        self.finishShortcutData = finishShortcutData
    }

    private enum CodingKeys: String, CodingKey {
        case appearance
        case welcomeTitle
        case backgroundSelection
        case didCompleteOnboarding
        case zeroDriftWarningSuppressed
        case purposeModeEnabled
        case requireManualFinishBeforeSwitching
        case overlayShortcutData
        case finishShortcutData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "dark"
        welcomeTitle = try container.decodeIfPresent(String.self, forKey: .welcomeTitle) ?? "Welcome to my desktop"
        backgroundSelection = try container.decodeIfPresent(String.self, forKey: .backgroundSelection) ?? "none"
        didCompleteOnboarding = try container.decodeIfPresent(Bool.self, forKey: .didCompleteOnboarding) ?? false
        zeroDriftWarningSuppressed = try container.decodeIfPresent(Bool.self, forKey: .zeroDriftWarningSuppressed) ?? false
        purposeModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .purposeModeEnabled) ?? false
        requireManualFinishBeforeSwitching = try container.decodeIfPresent(
            Bool.self,
            forKey: .requireManualFinishBeforeSwitching
        ) ?? true
        overlayShortcutData = try container.decodeIfPresent(Data.self, forKey: .overlayShortcutData)
        finishShortcutData = try container.decodeIfPresent(Data.self, forKey: .finishShortcutData)
    }
}

public struct IntentAccountWorkspace: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var intentions: [Intention]
    public var schedules: [IntentSchedule]
    public var preferences: IntentPortablePreferences
    public var customBackgroundPNG: Data?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        intentions: [Intention] = [],
        schedules: [IntentSchedule] = [],
        preferences: IntentPortablePreferences = .init(),
        customBackgroundPNG: Data? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.intentions = intentions
        self.schedules = schedules
        self.preferences = preferences
        self.customBackgroundPNG = customBackgroundPNG
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case intentions
        case schedules
        case preferences
        case customBackgroundPNG
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        intentions = try container.decodeIfPresent([Intention].self, forKey: .intentions) ?? []
        schedules = try container.decodeIfPresent([IntentSchedule].self, forKey: .schedules) ?? []
        preferences = try container.decodeIfPresent(
            IntentPortablePreferences.self,
            forKey: .preferences
        ) ?? .init()
        customBackgroundPNG = try container.decodeIfPresent(Data.self, forKey: .customBackgroundPNG)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public enum IntentWorkspaceResolution: Equatable {
    case createEmpty
    case uploadLocal
    case useRemote
    case unchanged
}

public enum IntentAccountCallbackKind: Equatable {
    case authentication
    case passwordReset

    public static func classify(_ url: URL) -> IntentAccountCallbackKind? {
        guard url.scheme?.lowercased() == "intent" else { return nil }

        switch url.host?.lowercased() {
        case "auth-callback":
            return .authentication
        case "password-reset":
            return .passwordReset
        default:
            return nil
        }
    }
}

public enum IntentWorkspaceResolver {
    public static func resolve(
        local: IntentAccountWorkspace?,
        remote: IntentAccountWorkspace?
    ) -> IntentWorkspaceResolution {
        switch (local, remote) {
        case let (.some(local), .some(remote)) where local.updatedAt > remote.updatedAt:
            return .uploadLocal
        case let (.some(local), .some(remote)) where remote.updatedAt > local.updatedAt:
            return .useRemote
        case (.some, .some):
            return .unchanged
        case (.some, .none):
            return .uploadLocal
        case (.none, .some):
            return .useRemote
        case (.none, .none):
            return .createEmpty
        }
    }
}

public enum IntentOfflineAccountPolicy {
    public static func canActivate(cachedWorkspace: IntentAccountWorkspace?) -> Bool {
        cachedWorkspace != nil
    }
}

public enum IntentProfilePaths {
    public static func rootDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".intent", isDirectory: true)
    }

    public static func guestDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        rootDirectory(homeDirectory: homeDirectory)
    }

    public static func accountDirectory(
        userID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(safePathComponent(userID), isDirectory: true)
    }

    public static func intentionsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("intentions.json")
    }

    public static func schedulesURL(in directory: URL) -> URL {
        directory.appendingPathComponent("schedules.json")
    }

    public static func customBackgroundURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent("backgrounds", isDirectory: true)
            .appendingPathComponent("custom-background.png")
    }

    public static func portablePreferencesURL(in directory: URL) -> URL {
        directory.appendingPathComponent("portable-preferences.json")
    }

    public static func workspaceCacheURL(in directory: URL) -> URL {
        directory.appendingPathComponent("account-workspace.json")
    }

    private static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(result)
    }
}
