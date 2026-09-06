import Foundation

public enum AIWorkspaceSessionStatus: String, Codable, Equatable {
    case draft
    case applied
}

public struct AIWorkspaceMessage: Identifiable, Codable, Equatable {
    public var id: String
    public var role: Role
    public var content: String
    public var createdAt: Date

    public enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct AIWorkspaceSession: Identifiable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [AIWorkspaceMessage]
    public var draft: Intention?
    public var targetIntentionID: String?
    public var status: AIWorkspaceSessionStatus
    public var finalisedAt: Date?
    public var schemaVersion: Int

    public init(
        id: String = UUID().uuidString,
        title: String = "New draft",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AIWorkspaceMessage] = [],
        draft: Intention? = nil,
        targetIntentionID: String? = nil,
        status: AIWorkspaceSessionStatus = .draft,
        finalisedAt: Date? = nil,
        schemaVersion: Int = AIWorkspaceSession.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.draft = draft
        self.targetIntentionID = targetIntentionID
        self.status = status
        self.finalisedAt = finalisedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, draft
        case targetIntentionID, status, finalisedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled draft"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messages = try container.decodeIfPresent([AIWorkspaceMessage].self, forKey: .messages) ?? []
        draft = try container.decodeIfPresent(Intention.self, forKey: .draft)
        targetIntentionID = try container.decodeIfPresent(String.self, forKey: .targetIntentionID)
        status = try container.decodeIfPresent(AIWorkspaceSessionStatus.self, forKey: .status) ?? .draft
        finalisedAt = try container.decodeIfPresent(Date.self, forKey: .finalisedAt)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public mutating func touch(at date: Date = Date()) {
        updatedAt = date
    }

    public mutating func refreshTitle() {
        if let name = draft?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            title = name
            return
        }
        if let firstUser = messages.first(where: { $0.role == .user })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            title = String(firstUser.prefix(48))
            return
        }
        title = "New draft"
    }
}

public struct AIHistoryFile: Codable, Equatable {
    public var schemaVersion: Int
    public var sessions: [AIWorkspaceSession]

    public init(schemaVersion: Int = AIWorkspaceSession.currentSchemaVersion, sessions: [AIWorkspaceSession] = []) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }
}

public final class AIHistoryStore {
    public let fileURL: URL
    public private(set) var didRecoverFromCorruption = false

    public init(fileURL: URL = AIHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() -> [AIWorkspaceSession] {
        didRecoverFromCorruption = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                return []
            }
            return try decodeSessions(from: data)
        } catch {
            didRecoverFromCorruption = true
            backupCorruptFile()
            return []
        }
    }

    public func save(_ sessions: [AIWorkspaceSession]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = AIHistoryFile(
            schemaVersion: AIWorkspaceSession.currentSchemaVersion,
            sessions: sessions.sorted { $0.updatedAt > $1.updatedAt }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }

    public func upsert(_ session: AIWorkspaceSession, into sessions: inout [AIWorkspaceSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: String, from sessions: inout [AIWorkspaceSession]) {
        sessions.removeAll { $0.id == id }
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".intent", isDirectory: true)
            .appendingPathComponent("ai-history.json")
    }

    private func decodeSessions(from data: Data) throws -> [AIWorkspaceSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let file = try? decoder.decode(AIHistoryFile.self, from: data) {
            return migrate(file.sessions)
        }
        if let sessions = try? decoder.decode([AIWorkspaceSession].self, from: data) {
            return migrate(sessions)
        }
        throw SpecDecodeError.invalidHistory
    }

    private func migrate(_ sessions: [AIWorkspaceSession]) -> [AIWorkspaceSession] {
        sessions.map { session in
            var migrated = session
            if migrated.schemaVersion < AIWorkspaceSession.currentSchemaVersion {
                migrated.schemaVersion = AIWorkspaceSession.currentSchemaVersion
            }
            migrated.refreshTitle()
            return migrated
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func backupCorruptFile() {
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: fileURL, to: backup)
    }
}

private enum SpecDecodeError: Error {
    case invalidHistory
}

public enum AIIntentionMention: Equatable {
    case resolved(intentionID: String, displayName: String)
    case missing(intentionID: String, displayName: String)
    case ambiguous([Intention])
}

public enum AIIntentionMentionResolver {
    public static let tokenPattern = #"[@*]\[([^\]]+)\]\(([0-9a-fA-F-]{36}|[A-Za-z0-9._-]+)\)"#

    public static func mentions(in text: String) -> [(range: Range<String.Index>, intentionID: String, displayName: String)] {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range, in: text) else {
                return nil
            }
            return (fullRange, String(text[idRange]), String(text[nameRange]))
        }
    }

    public static func encodeMention(displayName: String, intentionID: String) -> String {
        "*[\(displayName)](\(intentionID))"
    }

    public static func resolvePrimaryTarget(
        in text: String,
        intentions: [Intention]
    ) -> AIIntentionMention? {
        let encoded = mentions(in: text)
        if !encoded.isEmpty {
            let uniqueIDs = Array(Set(encoded.map(\.intentionID)))
            if uniqueIDs.count > 1 {
                let matched = uniqueIDs.compactMap { id in intentions.first { $0.id == id } }
                if matched.count > 1 {
                    return .ambiguous(matched)
                }
            }
            let first = encoded[0]
            if let intention = intentions.first(where: { $0.id == first.intentionID }) {
                return .resolved(intentionID: intention.id, displayName: intention.name)
            }
            return .missing(intentionID: first.intentionID, displayName: first.displayName)
        }

        let queryMatches = typeahead(query: extractStarQuery(from: text) ?? "", intentions: intentions)
        if queryMatches.count > 1, text.contains("*") {
            // Incomplete typeahead — not a finished mention.
            return nil
        }

        let nameHits = intentions
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.count > $1.name.count }
            .filter { intention in
                let escaped = NSRegularExpression.escapedPattern(for: intention.name)
                let pattern = "(?<![\\p{L}\\p{N}])\\*\\s*\(escaped)(?![\\p{L}\\p{N}])"
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }

        let unique = Dictionary(grouping: nameHits, by: \.id).compactMap(\.value.first)
        if unique.count > 1 {
            return .ambiguous(unique)
        }
        if let only = unique.first {
            return .resolved(intentionID: only.id, displayName: only.name)
        }
        return nil
    }

    public static func typeahead(query: String, intentions: [Intention]) -> [Intention] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = intentions.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !trimmed.isEmpty else {
            return named.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return named
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted {
                let leftPrefix = $0.name.lowercased().hasPrefix(trimmed.lowercased())
                let rightPrefix = $1.name.lowercased().hasPrefix(trimmed.lowercased())
                if leftPrefix != rightPrefix { return leftPrefix }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public static func extractAtQuery(from text: String) -> String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: atIndex)...]
        if after.contains("]") { return nil }
        if after.first == "[" { return nil }
        let query = String(after)
        if query.contains(where: { $0.isWhitespace || $0 == "\n" }) { return nil }
        return query
    }

    public static func extractStarQuery(from text: String) -> String? {
        guard let markerIndex = text.lastIndex(of: "*") else { return nil }
        let after = text[text.index(after: markerIndex)...]
        if after.contains("]") { return nil }
        if after.first == "[" { return nil }
        let query = String(after)
        if query.contains("\n")
            || query.rangeOfCharacter(from: CharacterSet(charactersIn: ".,;:!?()[]{}")) != nil {
            return nil
        }
        return query.trimmingCharacters(in: .whitespaces)
    }

    public static func displayText(for stored: String, intentions: [Intention]) -> String {
        var result = stored
        for mention in mentions(in: stored).reversed() {
            if let intention = intentions.first(where: { $0.id == mention.intentionID }) {
                result.replaceSubrange(mention.range, with: "* \(intention.name)")
            } else {
                result.replaceSubrange(mention.range, with: "* \(mention.displayName)")
            }
        }
        return result
    }

    public static func promptForAI(stored: String, intentions: [Intention]) -> String {
        var result = stored
        for mention in mentions(in: stored).reversed() {
            if let intention = intentions.first(where: { $0.id == mention.intentionID }) {
                result.replaceSubrange(
                    mention.range,
                    with: "* \(intention.name) [intention-id:\(intention.id)]"
                )
            } else {
                result.replaceSubrange(
                    mention.range,
                    with: "* \(mention.displayName) [missing-intention-id:\(mention.intentionID)]"
                )
            }
        }
        return result
    }
}
