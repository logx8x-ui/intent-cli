import Foundation

public struct BrowserTabItem: Codable, Equatable, Identifiable {
    public var id: Int
    public var windowID: Int
    public var index: Int
    public var title: String
    public var url: String
    public var active: Bool

    public init(
        id: Int,
        windowID: Int,
        index: Int,
        title: String,
        url: String,
        active: Bool
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.title = title
        self.url = url
        self.active = active
    }
}

public struct BrowserTabSnapshot: Codable, Equatable {
    public var browserBundleIdentifier: String
    public var tabs: [BrowserTabItem]
    public var updatedAt: Date

    public init(
        browserBundleIdentifier: String,
        tabs: [BrowserTabItem],
        updatedAt: Date = Date()
    ) {
        self.browserBundleIdentifier = browserBundleIdentifier
        self.tabs = tabs
        self.updatedAt = updatedAt
    }
}

public struct BrowserTabCommand: Codable, Equatable, Identifiable {
    public var id: String
    public var tabID: Int
    public var windowID: Int
    public var createdAt: Date
    public var action: BrowserTabCommandAction?

    public init(
        id: String = UUID().uuidString,
        tabID: Int,
        windowID: Int,
        createdAt: Date = Date(),
        action: BrowserTabCommandAction = .activate
    ) {
        self.id = id
        self.tabID = tabID
        self.windowID = windowID
        self.createdAt = createdAt
        self.action = action
    }
}

public enum BrowserTabCommandAction: String, Codable, Equatable {
    case activate
    case close
}

public final class BrowserTabSnapshotStore {
    public let fileURL: URL

    public init(browserBundleIdentifier: String) {
        fileURL = Self.fileURL(for: browserBundleIdentifier)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
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
              let snapshot = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
              now.timeIntervalSince(snapshot.updatedAt) <= maxAge else {
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

private var intentDirectory: URL {
    FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".intent", isDirectory: true)
}

private func safeBrowserFileComponent(_ value: String) -> String {
    value.map { character in
        character.isLetter || character.isNumber ? character : "-"
    }.reduce(into: "") { $0.append($1) }
}
