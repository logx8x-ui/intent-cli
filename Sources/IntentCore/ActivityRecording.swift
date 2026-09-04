import CryptoKit
import Foundation

public enum ActivityRecordingPeriod: String, Codable, CaseIterable, Identifiable {
    case twentyFourHours
    case oneWeek
    case indefinite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .twentyFourHours: "24 hours"
        case .oneWeek: "1 week"
        case .indefinite: "Until I stop it"
        }
    }

    public func endDate(startingAt startDate: Date) -> Date? {
        switch self {
        case .twentyFourHours: startDate.addingTimeInterval(24 * 60 * 60)
        case .oneWeek: startDate.addingTimeInterval(7 * 24 * 60 * 60)
        case .indefinite: nil
        }
    }
}

public enum ActivityRecordingKey {
    private static let separator = "\u{1F}"

    public static func website(browserBundleIdentifier: String, host: String) -> String {
        "\(browserBundleIdentifier)\(separator)\(host.lowercased())"
    }

    public static func websiteComponents(_ key: String) -> (browserBundleIdentifier: String, host: String)? {
        let pieces = key.components(separatedBy: separator)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        return (pieces[0], pieces[1])
    }

    public static func baselineFingerprint(for websiteKey: String) -> String {
        SHA256.hash(data: Data(websiteKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ActivityRecordingState: Codable, Equatable {
    public var id: String
    public var period: ActivityRecordingPeriod
    public var startedAt: Date
    public var endsAt: Date?
    public var completedAt: Date?
    public var isActive: Bool
    public var lastSampleAt: Date
    public var applicationSeconds: [String: TimeInterval]
    public var websiteBaselineCounts: [String: Int]
    public var websiteVisitCounts: [String: Int]

    public init(
        id: String = UUID().uuidString,
        period: ActivityRecordingPeriod,
        startedAt: Date = Date(),
        websiteBaselineCounts: [String: Int] = [:]
    ) {
        self.id = id
        self.period = period
        self.startedAt = startedAt
        endsAt = period.endDate(startingAt: startedAt)
        completedAt = nil
        isActive = true
        lastSampleAt = startedAt
        applicationSeconds = [:]
        self.websiteBaselineCounts = websiteBaselineCounts
        websiteVisitCounts = [:]
    }

    public var totalRecordedSeconds: TimeInterval {
        applicationSeconds.values.reduce(0, +)
    }

    public mutating func recordApplication(bundleIdentifier: String, seconds: TimeInterval) {
        guard isActive, seconds > 0, !Self.excludedBundleIdentifiers.contains(bundleIdentifier) else { return }
        applicationSeconds[bundleIdentifier, default: 0] += seconds
    }

    public mutating func updateWebsiteCounts(_ currentCounts: [String: Int]) {
        guard isActive else { return }
        for (key, currentCount) in currentCounts {
            let baseline = websiteBaselineCounts[
                ActivityRecordingKey.baselineFingerprint(for: key)
            ] ?? 0
            let visitsDuringRecording = max(0, currentCount - baseline)
            if visitsDuringRecording > 0 {
                websiteVisitCounts[key] = visitsDuringRecording
            } else {
                websiteVisitCounts.removeValue(forKey: key)
            }
        }
    }

    public mutating func finish(at date: Date = Date()) {
        isActive = false
        completedAt = date
        lastSampleAt = date
    }

    private static let excludedBundleIdentifiers: Set<String> = [
        "dev.loganmondi.intent",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.systemuiserver"
    ]
}

public final class ActivityRecordingStore {
    public let fileURL: URL

    public init(fileURL: URL = ActivityRecordingStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() -> ActivityRecordingState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ActivityRecordingState.self, from: data)
    }

    public func save(_ state: ActivityRecordingState) throws {
        try IntentLocalDataSecurity.harden(directory: fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("activity-recording.json")
    }
}

public enum ActivitySuggestionBuilder {
    private struct Category {
        let name: String
        let purpose: String
    }

    private struct Bucket {
        var category: Category
        var score: Double = 0
        var applicationScores: [String: Double] = [:]
        var websiteScores: [String: Int] = [:]
    }

    public static func suggestions(
        from state: ActivityRecordingState,
        installedApps: [AllowedApp],
        maximumCount: Int = 7
    ) -> [AIIntentionSuggestion] {
        let maximumCount = min(max(maximumCount, 1), 7)
        let appsByIdentifier = Dictionary(
            uniqueKeysWithValues: installedApps.map { ($0.bundleIdentifier, $0) }
        )
        var buckets: [String: Bucket] = [:]

        for (bundleIdentifier, seconds) in state.applicationSeconds where seconds >= 30 {
            guard let app = appsByIdentifier[bundleIdentifier] else { continue }
            if BrowserApplication.isBrowser(bundleIdentifier) { continue }
            let key = applicationCategoryKey(name: app.name, bundleIdentifier: bundleIdentifier)
                ?? "application:\(bundleIdentifier)"
            let category = category(for: key, fallbackAppName: app.name)
            var bucket = buckets[key] ?? Bucket(category: category)
            bucket.score += seconds
            bucket.applicationScores[bundleIdentifier, default: 0] += seconds
            buckets[key] = bucket
        }

        let browserSeconds = state.applicationSeconds.filter { BrowserApplication.isBrowser($0.key) }
        var browsersWithWebsiteUse = Set<String>()
        for (key, visitCount) in state.websiteVisitCounts where visitCount > 0 {
            guard let website = ActivityRecordingKey.websiteComponents(key),
                  appsByIdentifier[website.browserBundleIdentifier] != nil else { continue }
            browsersWithWebsiteUse.insert(website.browserBundleIdentifier)
            let categoryKey = websiteCategoryKey(host: website.host)
            let category = category(for: categoryKey, fallbackAppName: nil)
            var bucket = buckets[categoryKey] ?? Bucket(category: category)
            let websiteScore = Double(visitCount) * 120
            bucket.score += websiteScore
            bucket.applicationScores[website.browserBundleIdentifier, default: 0] += websiteScore
            bucket.websiteScores[key, default: 0] += visitCount
            buckets[categoryKey] = bucket
        }

        for (browserBundleIdentifier, seconds) in browserSeconds
            where seconds >= 30 && !browsersWithWebsiteUse.contains(browserBundleIdentifier) {
            guard let browser = appsByIdentifier[browserBundleIdentifier] else { continue }
            let key = "browse"
            var bucket = buckets[key] ?? Bucket(category: category(for: key, fallbackAppName: browser.name))
            bucket.score += seconds
            bucket.applicationScores[browserBundleIdentifier, default: 0] += seconds
            buckets[key] = bucket
        }

        return buckets.values
            .filter { !$0.applicationScores.isEmpty }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.category.name.localizedCaseInsensitiveCompare($1.category.name) == .orderedAscending
            }
            .prefix(maximumCount)
            .map { bucket in
                let appIdentifiers = bucket.applicationScores.keys.sorted { left, right in
                    let leftScore = bucket.applicationScores[left] ?? 0
                    let rightScore = bucket.applicationScores[right] ?? 0
                    if leftScore != rightScore { return leftScore > rightScore }
                    return (appsByIdentifier[left]?.name ?? left)
                        .localizedCaseInsensitiveCompare(appsByIdentifier[right]?.name ?? right) == .orderedAscending
                }
                let websites = bucket.websiteScores.keys.sorted { left, right in
                    let leftScore = bucket.websiteScores[left] ?? 0
                    let rightScore = bucket.websiteScores[right] ?? 0
                    if leftScore != rightScore { return leftScore > rightScore }
                    return left < right
                }.prefix(6).compactMap { key -> AIWebsiteSuggestion? in
                    guard let website = ActivityRecordingKey.websiteComponents(key) else { return nil }
                    return AIWebsiteSuggestion(
                        value: website.host,
                        browserBundleIdentifier: website.browserBundleIdentifier
                    )
                }
                let allowsSearches = bucket.category.name == "Browse & Research"
                return AIIntentionSuggestion(
                    name: bucket.category.name,
                    purpose: bucket.category.purpose,
                    appBundleIdentifiers: Array(appIdentifiers.prefix(6)),
                    websites: websites,
                    allowBrowserSearches: allowsSearches,
                    restrictions: allowsSearches ? [.init(kind: .allowBrowserSearches)] : [],
                    frictions: [],
                    accessMode: .whitelist
                )
            }
    }

    private static func applicationCategoryKey(name: String, bundleIdentifier: String) -> String? {
        let value = "\(name) \(bundleIdentifier)".lowercased()
        if containsAny(value, ["mail", "message", "slack", "discord", "teams", "zoom", "outlook"]) {
            return "communication"
        }
        if containsAny(value, ["anki", "remnote", "goodnotes", "kindle", "books", "study"]) {
            return "study"
        }
        if containsAny(value, ["xcode", "cursor", "visual studio", "vscode", "terminal", "iterm", "github desktop"]) {
            return "development"
        }
        if containsAny(value, ["figma", "canva", "photoshop", "illustrator", "final cut", "logic pro", "premiere"]) {
            return "creative"
        }
        if containsAny(value, ["calendar", "reminders", "todoist", "ticktick", "things"]) {
            return "planning"
        }
        if containsAny(value, ["word", "excel", "powerpoint", "pages", "numbers", "keynote", "notion", "obsidian"]) {
            return "work"
        }
        return nil
    }

    private static func websiteCategoryKey(host: String) -> String {
        let value = host.lowercased()
        if containsAny(value, ["mail.google", "outlook", "slack", "discord", "teams.microsoft", "zoom"]) {
            return "communication"
        }
        if containsAny(value, ["hanyang", "canvas", "coursera", "edx", "ankiweb", "remnote", "quizlet", "blackboard"]) {
            return "study"
        }
        if containsAny(value, ["github", "gitlab", "stackoverflow", "developer.", "npmjs", "swift.org"]) {
            return "development"
        }
        if containsAny(value, ["figma", "canva", "adobe"]) {
            return "creative"
        }
        if containsAny(value, ["calendar.google", "todoist", "ticktick", "things"]) {
            return "planning"
        }
        if containsAny(value, ["docs.google", "drive.google", "sheets.google", "office.com", "notion"]) {
            return "work"
        }
        return "browse"
    }

    private static func category(for key: String, fallbackAppName: String?) -> Category {
        switch key {
        case "communication": Category(name: "Messages & Email", purpose: "Handle messages, email, and calls in one focused session.")
        case "study": Category(name: "Study", purpose: "Study with the learning tools and course sites you use most.")
        case "development": Category(name: "Build & Code", purpose: "Work on code with your usual development tools and references.")
        case "creative": Category(name: "Create", purpose: "Do focused creative work with your most-used tools.")
        case "planning": Category(name: "Plan", purpose: "Review your calendar, tasks, and upcoming work.")
        case "work": Category(name: "Focused Work", purpose: "Work with your most-used documents and productivity tools.")
        case "browse": Category(name: "Browse & Research", purpose: "Browse and research using your most-used websites.")
        default:
            Category(
                name: fallbackAppName.map { "Use \($0)" } ?? "Focused Session",
                purpose: fallbackAppName.map { "Focus on your usual \($0) workflow." } ?? "Focus on a frequently used workflow."
            )
        }
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}
