import Foundation

public struct BrowserWindowFrame: Codable, Equatable {
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double
    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left; self.top = top; self.width = width; self.height = height
    }
    public var rect: CGRect { CGRect(x: left, y: top, width: width, height: height) }
}

public struct BrowserTabItem: Codable, Equatable, Identifiable {
    public var id: Int
    public var windowID: Int
    public var index: Int
    public var title: String
    public var url: String
    public var active: Bool
    public var faviconURL: String?
    /// Native multi-selection is independent from the one active tab. Nil means an older bridge.
    public var highlighted: Bool?
    public var pinned: Bool?
    public var discarded: Bool?
    public var groupID: Int?
    public var windowFrame: BrowserWindowFrame?
    public var windowFocused: Bool?

    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return url.isEmpty ? "New tab" : url
    }

    public init(
        id: Int,
        windowID: Int,
        index: Int,
        title: String,
        url: String,
        active: Bool,
        faviconURL: String? = nil,
        highlighted: Bool? = nil,
        pinned: Bool? = nil,
        discarded: Bool? = nil,
        groupID: Int? = nil,
        windowFrame: BrowserWindowFrame? = nil,
        windowFocused: Bool? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.title = title
        self.url = url
        self.active = active
        self.faviconURL = faviconURL
        self.highlighted = highlighted
        self.pinned = pinned
        self.discarded = discarded
        self.groupID = groupID
        self.windowFrame = windowFrame
        self.windowFocused = windowFocused
    }
}

public struct BrowserTabSnapshot: Codable, Equatable {
    public var browserBundleIdentifier: String
    public var browserSessionID: String?
    public var tabs: [BrowserTabItem]
    public var allTabs: [BrowserTabItem]?
    public var updatedAt: Date

    public init(
        browserBundleIdentifier: String,
        browserSessionID: String? = nil,
        tabs: [BrowserTabItem],
        updatedAt: Date = Date(),
        allTabs: [BrowserTabItem]? = nil
    ) {
        self.browserBundleIdentifier = browserBundleIdentifier
        self.browserSessionID = browserSessionID
        self.tabs = tabs
        self.allTabs = allTabs
        self.updatedAt = updatedAt
    }
}

public struct BrowserTabCommand: Codable, Equatable, Identifiable {
    public var id: String
    public var tabID: Int
    public var windowID: Int
    public var createdAt: Date
    public var action: BrowserTabCommandAction?
    public var browserSessionID: String?

    public init(
        id: String = UUID().uuidString,
        tabID: Int,
        windowID: Int,
        createdAt: Date = Date(),
        action: BrowserTabCommandAction = .activate,
        browserSessionID: String? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.windowID = windowID
        self.createdAt = createdAt
        self.action = action
        self.browserSessionID = browserSessionID
    }
}

public enum BrowserTabCommandAction: String, Codable, Equatable {
    case activate
    case close
    case snapshot
    case preview
}

public struct BrowserTabPreview: Codable, Sendable {
    public var requestID: String
    public var image: String?
    public var error: String?
    public static func fileURL(browser: String) -> URL {
        intentDirectory.appendingPathComponent("browser-preview-\(safeBrowserFileComponent(browser)).json")
    }
}

public final class BrowserTabSnapshotStore {
    public let fileURL: URL
    private let browserBundleIdentifier: String?

    public init(browserBundleIdentifier: String) {
        fileURL = Self.fileURL(for: browserBundleIdentifier)
        self.browserBundleIdentifier = browserBundleIdentifier
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        browserBundleIdentifier = nil
    }

    public func write(_ snapshot: BrowserTabSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    public func load(maxAge: TimeInterval = 3, now: Date = Date()) -> BrowserTabSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data) else {
            return nil
        }
        if now.timeIntervalSince(snapshot.updatedAt) <= maxAge {
            return snapshot
        }

        // Snapshots are event-driven. An unchanged tab list can remain valid while the
        // native connection heartbeat proves that Browser Guard is still listening.
        guard let browserBundleIdentifier,
              snapshot.browserBundleIdentifier == browserBundleIdentifier,
              BrowserGuardHeartbeatStore(
                fileURL: BrowserGuardHeartbeatStore.fileURL(for: browserBundleIdentifier)
              ).isFresh(maxAge: 5, now: now) else {
            return nil
        }
        return snapshot
    }

    public static func fileURL(for browserBundleIdentifier: String) -> URL {
        intentDirectory.appendingPathComponent(
            "browser-tabs-\(safeBrowserFileComponent(browserBundleIdentifier)).json"
        )
    }
}

public final class BrowserTabCommandStore {
    public let fileURL: URL

    public init(browserBundleIdentifier: String) {
        fileURL = Self.fileURL(for: browserBundleIdentifier)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func write(_ command: BrowserTabCommand) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(command).write(to: fileURL, options: .atomic)
    }

    public func take() -> BrowserTabCommand? {
        guard let data = try? Data(contentsOf: fileURL),
              let command = try? JSONDecoder().decode(BrowserTabCommand.self, from: data) else {
            return nil
        }
        try? FileManager.default.removeItem(at: fileURL)
        return command
    }

    public static func fileURL(for browserBundleIdentifier: String) -> URL {
        intentDirectory.appendingPathComponent(
            "browser-tab-command-\(safeBrowserFileComponent(browserBundleIdentifier)).json"
        )
    }
}

private var intentDirectory: URL { IntentEnvironment.dataDirectory }

private func safeBrowserFileComponent(_ value: String) -> String {
    value.map { character in
        character.isLetter || character.isNumber ? character : "-"
    }.reduce(into: "") { $0.append($1) }
}
